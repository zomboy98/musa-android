use musa_listening::{ListeningEngine, Segment};

// Injected local-midnight instants for America/New_York, 2026. The engine
// deliberately knows nothing about time zones; this is a test adapter only.
const MIDNIGHTS: &[(i64, &str)] = &[
    (1_772_859_600_000, "2026-03-07"),
    (1_772_946_000_000, "2026-03-08"),
    (1_773_028_800_000, "2026-03-09"),
    (1_773_115_200_000, "2026-03-10"),
    (1_793_505_600_000, "2026-11-01"),
    (1_793_595_600_000, "2026-11-02"),
    (1_793_682_000_000, "2026-11-03"),
];

fn split(start: i64, duration: i64, calendar: &[(i64, &str)]) -> Vec<Segment> {
    let end = start.checked_add(duration).unwrap();
    let mut cursor = start;
    let mut segments = Vec::new();
    while cursor < end {
        let index = calendar
            .windows(2)
            .position(|w| w[0].0 <= cursor && cursor < w[1].0)
            .expect("fixture calendar must cover interval");
        let next = end.min(calendar[index + 1].0);
        segments.push(Segment {
            day: calendar[index].1.into(),
            milliseconds: next - cursor,
        });
        cursor = next;
    }
    segments
}

#[test]
fn injected_calendar_matches_shared_dst_vectors() {
    for line in include_str!("dst_vectors.txt")
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
    {
        let fields: Vec<_> = line.split('|').collect();
        let segments = split(
            fields[1].parse().unwrap(),
            fields[2].parse().unwrap(),
            MIDNIGHTS,
        );
        let mut engine = ListeningEngine::new();
        engine.update(Some("A".into()), true, false);
        let actual = engine
            .advance(&segments)
            .unwrap()
            .iter()
            .map(|d| format!("{}:{}:{}", d.day, d.milliseconds, d.plays))
            .collect::<Vec<_>>()
            .join(";");
        assert_eq!(actual, fields[3], "{}", fields[0]);
    }
}
