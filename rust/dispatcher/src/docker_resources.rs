//! Best-effort project-container telemetry; never blocks the UI thread.
use super::{BackendStderrFile, ResourceSample};
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

pub(super) struct DockerSampler {
    stop: Arc<AtomicBool>,
    samples: mpsc::Receiver<(Instant, Option<ResourceSample>)>,
    latest: Option<ResourceSample>,
    sampled_at: Option<Instant>,
}

impl DockerSampler {
    pub(super) fn new(scope: PathBuf) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let (sender, samples) = mpsc::sync_channel(1);
        thread::spawn(move || {
            while !worker_stop.load(Ordering::Relaxed) {
                let sample = collect(&scope, &worker_stop).ok().flatten();
                if matches!(
                    sender.try_send((Instant::now(), sample)),
                    Err(mpsc::TrySendError::Disconnected(_))
                ) {
                    break;
                }
                // Poll stop frequently without keeping the renderer waiting on Drop.
                for _ in 0..20 {
                    if worker_stop.load(Ordering::Relaxed) {
                        return;
                    }
                    thread::sleep(Duration::from_millis(100));
                }
            }
        });
        Self {
            stop,
            samples,
            latest: None,
            sampled_at: None,
        }
    }

    pub(super) fn poll(&mut self) -> (Option<ResourceSample>, bool) {
        let mut changed = false;
        while let Ok((at, sample)) = self.samples.try_recv() {
            self.latest = sample;
            self.sampled_at = Some(at);
            changed = true;
        }
        if self
            .sampled_at
            .is_some_and(|at| at.elapsed() > Duration::from_secs(8))
        {
            self.latest = None;
        }
        (self.latest, changed)
    }
}

impl Drop for DockerSampler {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

pub(super) fn is_docker_phase(title: &str) -> bool {
    title.starts_with("docker-") || title.starts_with("karate-docker-")
}

fn compose_probe(scope: &str) -> Option<Command> {
    let mut lines = scope.lines();
    let cwd = lines.next()?;
    let executable = lines.next()?;
    if cwd.is_empty() || !matches!(executable, "docker" | "docker-compose") {
        return None;
    }
    let mut command = Command::new(executable);
    command.current_dir(cwd).args(lines).args(["ps", "-q"]);
    Some(command)
}

fn collect(scope: &Path, stop: &AtomicBool) -> io::Result<Option<ResourceSample>> {
    let content = fs::read_to_string(scope)?;
    let Some(probe) = compose_probe(&content) else {
        return Ok(None);
    };
    let ids = bounded_output(probe, stop)?;
    let ids = container_ids(&ids);
    if ids.is_empty() {
        return Ok(None);
    }
    let mut stats = Command::new("docker");
    stats.args(["stats", "--no-stream", "--format", "{{json .}}"]);
    stats.args(&ids);
    let output = bounded_output(stats, stop)?;
    Ok(parse_stats(&output, ids.len()))
}

fn container_ids(output: &str) -> Vec<&str> {
    output
        .lines()
        .map(str::trim)
        .filter(|id| (12..=64).contains(&id.len()) && id.bytes().all(|c| c.is_ascii_hexdigit()))
        .collect()
}

fn bounded_output(mut command: Command, stop: &AtomicBool) -> io::Result<String> {
    let temporary = BackendStderrFile::new().map_err(io::Error::other)?;
    let file = File::create(temporary.path())?;
    let mut child = command
        .stdout(file.try_clone()?)
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .process_group(0)
        .spawn()?;
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if stop.load(Ordering::Relaxed) || started.elapsed() > Duration::from_secs(3) {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.wait();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "container telemetry timed out",
            ));
        }
        thread::sleep(Duration::from_millis(25));
    };
    if !status.success() {
        return Err(io::Error::other("container telemetry unavailable"));
    }
    let file = File::open(temporary.path())?;
    let mut output = String::new();
    // Bounded file read even if a broken CLI produces excessive output.
    file.take(1024 * 1024).read_to_string(&mut output)?;
    Ok(output)
}

fn parse_stats(output: &str, expected: usize) -> Option<ResourceSample> {
    let samples: Option<Vec<_>> = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(parse_stats_row)
        .collect();
    let samples = samples?;
    if samples.is_empty() || samples.len() != expected {
        return None;
    }
    Some(ResourceSample {
        cpu_percent: samples.iter().map(|sample| sample.cpu_percent).sum(),
        rss_kb: samples.iter().map(|sample| sample.rss_kb).sum(),
    })
}

fn parse_stats_row(line: &str) -> Option<ResourceSample> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let cpu: f32 = value
        .get("CPUPerc")?
        .as_str()?
        .trim()
        .strip_suffix('%')?
        .parse()
        .ok()?;
    if !cpu.is_finite() || cpu < 0.0 {
        return None;
    }
    let memory = value.get("MemUsage")?.as_str()?.split('/').next()?.trim();
    Some(ResourceSample {
        cpu_percent: cpu,
        rss_kb: memory_kib(memory)?,
    })
}

fn memory_kib(text: &str) -> Option<u64> {
    let index = text.find(|c: char| c.is_alphabetic())?;
    let number: f64 = text[..index].trim().parse().ok()?;
    const UNITS: &[(&str, f64)] = &[
        ("B", 1.0),
        ("kB", 1000.0),
        ("KB", 1000.0),
        ("KiB", 1024.0),
        ("MB", 1_000_000.0),
        ("MiB", 1_048_576.0),
        ("GB", 1_000_000_000.0),
        ("GiB", 1_073_741_824.0),
        ("TB", 1_000_000_000_000.0),
        ("TiB", 1_099_511_627_776.0),
    ];
    let multiplier = UNITS.iter().find(|(unit, _)| *unit == &text[index..])?.1;
    if !number.is_finite() || number < 0.0 {
        return None;
    }
    Some((number * multiplier / 1024.0).round() as u64)
}

#[cfg(test)]
#[path = "docker_resources_test.rs"]
mod tests;
