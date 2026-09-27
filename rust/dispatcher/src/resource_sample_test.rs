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
