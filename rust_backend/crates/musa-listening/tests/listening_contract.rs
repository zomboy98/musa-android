use musa_listening::{AdvanceError, ListeningEngine, Segment};

fn segment(day: &str, milliseconds: i64) -> Segment {
    Segment {
        day: day.into(),
        milliseconds,
    }
}
fn active() -> ListeningEngine {
    let mut engine = ListeningEngine::new();
    engine.update(Some("A".into()), true, false);
    engine
}
fn advance(engine: &mut ListeningEngine, ms: i64) -> i64 {
    engine.advance(&[segment("2026-10-02", ms)]).unwrap()[0].plays
}

#[test]
fn threshold_is_counted_once_and_on_crossing_segment() {
    let mut engine = active();
    assert_eq!(advance(&mut engine, 29_999), 0);
    assert_eq!(advance(&mut engine, 1), 1);
    assert_eq!(advance(&mut engine, 30_000), 0);
}

#[test]
fn pauses_and_disabling_preserve_session() {
    let mut engine = active();
    assert_eq!(advance(&mut engine, 20_000), 0);
    engine.update(Some("A".into()), false, false);
    assert!(engine
        .advance(&[segment("2026-10-02", 600_000)])
        .unwrap()
        .is_empty());
    engine.update(Some("A".into()), true, false);
    engine.set_enabled(false);
    assert!(engine
        .advance(&[segment("2026-10-02", 60_000)])
        .unwrap()
        .is_empty());
    engine.set_enabled(true);
    engine.update(Some("A".into()), true, false);
    assert_eq!(advance(&mut engine, 10_000), 1);
}

#[test]
fn ended_track_change_and_explicit_reset_restart_session() {
    let mut engine = active();
    assert_eq!(advance(&mut engine, 35_000), 1);
    engine.update(Some("A".into()), true, true);
    assert!(engine.advance(&[segment("d", 1)]).unwrap().is_empty());
    engine.update(Some("A".into()), true, false);
    assert_eq!(advance(&mut engine, 35_000), 1);
    engine.update(Some("B".into()), true, false);
    assert_eq!(advance(&mut engine, 10_000), 0);
    engine.reset_session();
    assert_eq!(advance(&mut engine, 30_000), 1);
}

#[test]
fn caller_supplied_days_and_track_keys_are_preserved() {
    let mut engine = active();
    let deltas = engine
        .advance(&[segment("2026-10-01", 10_000), segment("2026-10-02", 30_000)])
        .unwrap();
    assert_eq!(
        deltas
            .iter()
            .map(|d| (
                d.day.as_str(),
                d.track_key.as_str(),
                d.milliseconds,
                d.plays
            ))
            .collect::<Vec<_>>(),
        vec![
            ("2026-10-01", "A", 10_000, 0),
            ("2026-10-02", "A", 30_000, 1)
        ]
    );
    engine.update(Some("file://a/../b".into()), true, false);
    assert_eq!(
        engine.advance(&[segment("opaque", 1)]).unwrap()[0].track_key,
        "file://a/../b"
    );
}

#[test]
fn null_track_and_invalid_batches_do_not_mutate_state() {
    let mut engine = ListeningEngine::new();
    engine.update(None, true, false);
    assert!(engine.advance(&[segment("d", 60_000)]).unwrap().is_empty());
    assert_eq!(
        engine.advance(&[segment("d", 0)]),
        Err(AdvanceError::NonPositiveDuration)
    );
    let mut engine = active();
    assert_eq!(
        engine.advance(&[segment("d", 29_999), segment("d", -1)]),
        Err(AdvanceError::NonPositiveDuration)
    );
    assert_eq!(advance(&mut engine, 1), 0);
    assert_eq!(advance(&mut engine, 29_999), 1);
}

#[test]
fn overflow_rejects_the_whole_batch_without_counting() {
    let mut engine = active();
    assert_eq!(
        engine.advance(&[segment("d", i64::MAX), segment("d", 1)]),
        Err(AdvanceError::SessionOverflow)
    );
    assert_eq!(advance(&mut engine, 30_000), 1);
    assert_eq!(
        engine.advance(&[segment("d", i64::MAX)]),
        Err(AdvanceError::SessionOverflow)
    );
    assert_eq!(advance(&mut engine, 1), 0);
}
