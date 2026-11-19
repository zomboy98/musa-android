use musa_listening::{ListeningEngine, Segment};
use std::collections::BTreeMap;

#[test]
fn shared_vectors() {
    for line in include_str!("vectors.txt")
        .lines()
        .filter(|line| !line.starts_with('#') && !line.is_empty())
    {
        let fields: Vec<_> = line.split('|').collect();
        let mut engine = ListeningEngine::new();
        let mut actual: BTreeMap<String, (i64, i64)> = BTreeMap::new();
        for event in fields[1].split(',') {
            let parts: Vec<_> = event.split(':').collect();
            match parts[0] {
                "u" => engine.update(
                    (parts[1] != "-").then(|| parts[1].to_string()),
                    parts[2] == "1",
                    false,
                ),
                "x" => engine.update(Some(parts[1].to_string()), false, true),
                "e" => engine.set_enabled(parts[1] == "1"),
                "t" => {
                    for delta in engine
                        .advance(&[Segment {
                            day: "2026-10-02".into(),
                            milliseconds: parts[1].parse().unwrap(),
                        }])
                        .unwrap()
                    {
                        let total = actual.entry(delta.track_key).or_default();
                        total.0 += delta.milliseconds;
                        total.1 += delta.plays;
                    }
                }
                _ => panic!("unknown event"),
            }
        }
        let expected: BTreeMap<String, (i64, i64)> = if fields[2] == "-" {
            BTreeMap::new()
        } else {
            fields[2]
                .split(',')
                .map(|v| {
                    let p: Vec<_> = v.split(':').collect();
                    (
                        p[0].to_string(),
                        (p[1].parse().unwrap(), p[2].parse().unwrap()),
                    )
                })
                .collect()
        };
        assert_eq!(actual, expected, "{}", fields[0]);
    }
}
