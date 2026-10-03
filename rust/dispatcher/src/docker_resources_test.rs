use super::*;

#[test]
fn parses_container_samples_and_aggregates_cpu_and_memory() {
    let sample = parse_stats("{\"CPUPerc\":\"12.5%\",\"MemUsage\":\"1MiB / 8GiB\"}\n{\"CPUPerc\":\"0.5%\",\"MemUsage\":\"2MiB / 8GiB\"}\n", 2).unwrap();
    assert_eq!(sample.cpu_percent, 13.0);
    assert_eq!(sample.rss_kb, 3072);
}

#[test]
fn absent_partial_and_invalid_samples_are_unavailable_not_zero() {
    for text in [
        "",
        "garbage",
        "{}",
        "{\"CPUPerc\":\"NaN%\",\"MemUsage\":\"1MiB\"}",
        "{\"CPUPerc\":\"-1%\",\"MemUsage\":\"1MiB\"}",
        "{\"CPUPerc\":\"1%\",\"MemUsage\":\"invalid\"}",
    ] {
        assert!(parse_stats(text, 1).is_none());
    }
    assert!(parse_stats("{\"CPUPerc\":\"0%\",\"MemUsage\":\"0B\"}", 2).is_none());
    assert_eq!(
        parse_stats("{\"CPUPerc\":\"0%\",\"MemUsage\":\"0B\"}", 1)
            .unwrap()
            .cpu_percent,
        0.0
    );
}

#[test]
fn memory_units_are_explicit_and_invalid_values_rejected() {
    for (text, expected) in [
        ("1024B", 1),
        ("1KiB", 1),
        ("1kB", 1),
        ("1KB", 1),
        ("1MB", 977),
        ("1MiB", 1024),
        ("1GB", 976563),
        ("1GiB", 1048576),
        ("1TB", 976562500),
        ("1TiB", 1073741824),
    ] {
        assert_eq!(memory_kib(text), Some(expected));
    }
    for text in ["", "abc", "-1MiB", "NaNMiB", "1XB", "10"] {
        assert!(memory_kib(text).is_none());
    }
}

#[test]
fn scope_uses_backend_resolved_compose_files_and_preserves_spaces() {
    let command = compose_probe(
        "/repo with spaces\ndocker\ncompose\n-f\n/repo with spaces/custom.yml\n-f\n/override.yml\n",
    )
    .unwrap();
    assert_eq!(
        command.get_current_dir().unwrap(),
        Path::new("/repo with spaces")
    );
    let args: Vec<_> = command
        .get_args()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        args,
        [
            "compose",
            "-f",
            "/repo with spaces/custom.yml",
            "-f",
            "/override.yml",
            "ps",
            "-q"
        ]
    );
    assert_eq!(
        compose_probe("/repo\ndocker-compose\n-f\n/custom.yml\n")
            .unwrap()
            .get_program(),
        "docker-compose"
    );
    for invalid in ["", "/repo\n", "\ndocker\n", "/repo\nsh\n-c\n"] {
        assert!(compose_probe(invalid).is_none());
    }
    assert_eq!(
        container_ids("0123456789ab\nwarning\n-fedcba98765\n"),
        ["0123456789ab"]
    );
}

#[test]
fn phase_detection_excludes_maven_and_composite_wrappers() {
    for title in ["docker-up", "docker-ps-required", "karate-docker-down"] {
        assert!(is_docker_phase(title));
    }
    for title in ["verify", "karate-all", "karate-test", "run-app-bg"] {
        assert!(!is_docker_phase(title));
    }
}

#[test]
fn bounded_commands_read_output_and_report_failures_and_cancellation() {
    let stop = AtomicBool::new(false);
    let mut command = Command::new("printf");
    command.arg("sample");
    assert_eq!(bounded_output(command, &stop).unwrap(), "sample");
    assert!(bounded_output(Command::new("false"), &stop).is_err());
    assert!(bounded_output(Command::new("makevn-nonexistent-telemetry-program"), &stop).is_err());
    stop.store(true, Ordering::Relaxed);
    let mut command = Command::new("sleep");
    command.arg("5");
    let start = Instant::now();
    assert!(bounded_output(command, &stop).is_err());
    assert!(start.elapsed() < Duration::from_secs(2));
}

#[test]
fn missing_scope_worker_is_nonblocking_and_reports_unavailable() {
    let mut sampler = DockerSampler::new(PathBuf::from("/nonexistent/makevn-test.resources"));
    let start = Instant::now();
    let (sample, mut changed) = sampler.poll();
    assert!(sample.is_none());
    assert!(start.elapsed() < Duration::from_millis(50));
    let deadline = Instant::now() + Duration::from_secs(4);
    while !changed {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
        changed = sampler.poll().1;
    }
    assert!(sampler.poll().0.is_none());
    assert!(collect(
        Path::new("/nonexistent/makevn-test.resources"),
        &AtomicBool::new(false)
    )
    .is_err());
}

#[test]
fn collects_only_compose_project_ids_with_fake_docker_cli() {
    use std::os::unix::fs::PermissionsExt;
    let _lock = crate::tests::ENV_LOCK.lock().unwrap();
    let directory =
        std::env::temp_dir().join(format!("makevn-container-scope-{}", std::process::id()));
    fs::create_dir_all(&directory).unwrap();
    let executable = directory.join("docker");
    fs::write(&executable, "#!/bin/sh\nif [ \"$1\" = compose ]; then printf '0123456789ab\\n'; else\n case \"$*\" in *0123456789ab*) printf '%s\\n' '{\"CPUPerc\":\"7.5%\",\"MemUsage\":\"4MiB / 8GiB\"}';; *) exit 8;; esac\nfi\n").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::set_var(
        "PATH",
        format!("{}:{}", directory.display(), path.to_string_lossy()),
    );
    let scope = directory.join("scope");
    fs::write(
        &scope,
        format!("{}\ndocker\ncompose\n-f\ncustom.yml\n", directory.display()),
    )
    .unwrap();
    let stop = AtomicBool::new(false);
    let sample = collect(&scope, &stop).unwrap().unwrap();
    assert_eq!(sample.cpu_percent, 7.5);
    assert_eq!(sample.rss_kb, 4096);
    // Replace the inode instead of rewriting an executable that Linux may still
    // have mapped after the previous child exits (ETXTBSY under llvm-cov).
    let replacement = directory.join("docker-next");
    fs::write(&replacement, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&replacement, fs::Permissions::from_mode(0o755)).unwrap();
    fs::rename(&replacement, &executable).unwrap();
    assert!(collect(&scope, &stop).unwrap().is_none());
    fs::write(&scope, "invalid\ncommand\n").unwrap();
    assert!(collect(&scope, &stop).unwrap().is_none());
    std::env::set_var("PATH", path);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn poll_expires_stale_samples_and_records_new_results() {
    let (sender, samples) = mpsc::channel();
    let mut sampler = DockerSampler {
        stop: Arc::new(AtomicBool::new(false)),
        samples,
        latest: Some(ResourceSample {
            cpu_percent: 2.0,
            rss_kb: 1024,
        }),
        sampled_at: Some(Instant::now() - Duration::from_secs(9)),
    };
    assert!(sampler.poll().0.is_none());
    sender
        .send((
            Instant::now(),
            Some(ResourceSample {
                cpu_percent: 5.0,
                rss_kb: 2048,
            }),
        ))
        .unwrap();
    let (sample, changed) = sampler.poll();
    assert!(changed);
    assert_eq!(sample.unwrap().cpu_percent, 5.0);
    sender.send((Instant::now(), None)).unwrap();
    assert!(sampler.poll().0.is_none());
}
