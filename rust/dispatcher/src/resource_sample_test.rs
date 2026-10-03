use super::parse_ps_resource_sample;

#[test]
fn sums_root_and_descendants_independent_of_row_order() {
    let sample = parse_ps_resource_sample(
        10,
        true,
        "30 20 1,5 300\n99 1 80.0 9000\n20 10 2.0 200\n10 1 0.5 100\n",
    );

    assert_eq!(sample.cpu_percent, 4.0);
    assert_eq!(sample.rss_kb, 600);
}

#[test]
fn ignores_malformed_rows_and_unrelated_processes() {
    let sample = parse_ps_resource_sample(
        10,
        true,
        "incomplete\nnope 10 1.0 10\n20 nope 1.0 10\n20 10 nope 10\n20 10 1.0 nope\n99 1 50.0 9000\n10 1 2.5 125\n",
    );

    assert_eq!(sample.cpu_percent, 2.5);
    assert_eq!(sample.rss_kb, 125);
}

#[test]
fn missing_root_has_zero_metrics() {
    let sample = parse_ps_resource_sample(10, true, "99 1 50.0 9000\n");

    assert_eq!(sample.cpu_percent, 0.0);
    assert_eq!(sample.rss_kb, 0);
}

#[test]
fn failed_ps_command_has_zero_metrics() {
    let sample = parse_ps_resource_sample(10, false, "10 1 2.5 125\n");

    assert_eq!(sample.cpu_percent, 0.0);
    assert_eq!(sample.rss_kb, 0);
}

#[test]
fn sampler_cache_is_keyed_by_backend_pid() {
    let mut sampler = super::ResourceSampler::new();
    sampler.last_pid = Some(u32::MAX);
    sampler.last_sample_at = Some(std::time::Instant::now());
    sampler.last_sample = Some(super::ResourceSample {
        cpu_percent: 9876.0,
        rss_kb: u64::MAX,
    });
    let pid = std::process::id();
    let sample = sampler.sample(pid).unwrap().unwrap();
    assert_eq!(sampler.last_pid, Some(pid));
    assert_ne!(sample.cpu_percent, 9876.0);
    assert_ne!(sample.rss_kb, u64::MAX);
    assert_eq!(sampler.revision(), 1);
    let cached = sampler.sample(pid).unwrap().unwrap();
    assert_eq!(cached.cpu_percent, sample.cpu_percent);
    assert_eq!(cached.rss_kb, sample.rss_kb);
    assert_eq!(sampler.revision(), 1);
    assert!(sampler.sample(0).unwrap().is_none());
    assert!(sampler.last_sample.is_none());
    assert!(sampler.last_sample_at.is_none());
}
