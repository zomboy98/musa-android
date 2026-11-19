use musa_listening::{ListeningEngine, Segment};
use std::collections::BTreeMap;

// Test adapter: October 1 and 2 in this fixture have ordinary 24-hour days.
// Production calendar handling and DST remain the Dart adapter's responsibility.
#[test]
fn shared_day_and_flush_vectors() {
    for line in include_str!("batch_vectors.txt")
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
    {
        let p: Vec<_> = line.split('|').collect();
        let mut engine = ListeningEngine::new();
        let mut now: i64 = p[1].parse().unwrap();
        let mut previous = now;
        let mut pending: BTreeMap<(String, String), (i64, i64)> = BTreeMap::new();
        let mut batches = Vec::new();
        for event in p[2].split(',') {
            let fields: Vec<_> = event.split(':').collect();
            if fields[0] == "t" {
                now += fields[1].parse::<i64>().unwrap();
                continue;
            }
            let mut cursor = previous;
            let mut segments = Vec::new();
            while cursor < now {
                let boundary = ((cursor / 86_400_000) + 1) * 86_400_000;
                let end = now.min(boundary);
                segments.push(Segment {
                    day: format!("2026-10-{:02}", 1 + cursor / 86_400_000),
                    milliseconds: end - cursor,
                });
                cursor = end;
            }
            previous = now;
            for delta in engine.advance(&segments).unwrap() {
                let entry = pending.entry((delta.day, delta.track_key)).or_default();
                entry.0 += delta.milliseconds;
                entry.1 += delta.plays;
            }
            match fields[0] {
                "u" => engine.update(Some(fields[1].into()), fields[2] == "1", false),
                "c" => (),
                "f" => {
                    if !pending.is_empty() {
                        batches.push(
                            pending
                                .iter()
                                .map(|((day, track), (ms, plays))| {
                                    format!("{day}:{track}:{ms}:{plays}")
                                })
                                .collect::<Vec<_>>()
                                .join(";"),
                        );
                        pending.clear();
                    }
                }
                _ => panic!("unknown event"),
            }
        }
        assert_eq!(batches.join("/"), p[3], "{}", p[0]);
    }
}
