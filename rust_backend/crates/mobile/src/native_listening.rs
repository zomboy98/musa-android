//! Stateless, bounded shadow replay. The caller owns calendar boundaries and storage.
//! Errors never contain request values. No listening data is logged.
//! Step requests and responses use protocol version 2; their embedded state
//! uses snapshot version 1. Track keys are opaque and bounded at this bridge.
use musa_listening::{ListeningEngine, Segment, Snapshot};
use serde_json::{Value, json};

// Bound the whole replay, not just each individual advance batch.
const MAX_SEGMENTS: usize = 4096;

pub(crate) fn execute(
    request: &Value,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    run_events(request, check, ListeningEngine::new(), false)
}

pub(crate) fn execute_step(
    request: &Value,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    if request.get("version").and_then(Value::as_u64) != Some(2) {
        return Err("Invalid listening request".into());
    }
    let state = request.get("state").ok_or("Invalid listening state")?;
    let track = match state.get("track") {
        Some(Value::Null) => None,
        Some(Value::String(s)) if s.len() <= 1024 => Some(s.clone()),
        _ => return Err("Invalid listening state".into()),
    };
    let snapshot = Snapshot {
        version: state
            .get("version")
            .and_then(Value::as_u64)
            .and_then(|v| u8::try_from(v).ok())
            .ok_or("Invalid listening state")?,
        track,
        playing: state
            .get("playing")
            .and_then(Value::as_bool)
            .ok_or("Invalid listening state")?,
        enabled: state
            .get("enabled")
            .and_then(Value::as_bool)
            .ok_or("Invalid listening state")?,
        session_ms: state
            .get("session_ms")
            .and_then(Value::as_i64)
            .ok_or("Invalid listening state")?,
        counted: state
            .get("counted")
            .and_then(Value::as_bool)
            .ok_or("Invalid listening state")?,
    };
    let engine = ListeningEngine::from_snapshot(snapshot).map_err(str::to_owned)?;
    run_events(request, check, engine, true)
}

fn run_events(
    request: &Value,
    check: &dyn Fn() -> Result<(), String>,
    mut engine: ListeningEngine,
    step: bool,
) -> Result<Value, String> {
    let events = request
        .get("events")
        .and_then(Value::as_array)
        .ok_or("Invalid listening request")?;
    if events.len() > 4096 {
        return Err("Too many listening events".into());
    }
    let mut batches = Vec::new();
    let mut segment_count = 0usize;
    for event in events {
        check()?;
        match event.get("type").and_then(Value::as_str) {
            Some("update") => {
                let key = match event.get("track") {
                    Some(Value::Null) => None,
                    Some(Value::String(s)) if s.len() <= 1024 => Some(s.clone()),
                    _ => return Err("Invalid listening event".into()),
                };
                let playing = event
                    .get("playing")
                    .and_then(Value::as_bool)
                    .ok_or("Invalid listening event")?;
                let ended = event
                    .get("ended")
                    .and_then(Value::as_bool)
                    .ok_or("Invalid listening event")?;
                engine.update(key, playing, ended);
            }
            Some("enabled") => engine.set_enabled(
                event
                    .get("value")
                    .and_then(Value::as_bool)
                    .ok_or("Invalid listening event")?,
            ),
            Some("reset") => engine.reset_session(),
            Some("advance") => {
                let values = event
                    .get("segments")
                    .and_then(Value::as_array)
                    .ok_or("Invalid listening event")?;
                segment_count = segment_count
                    .checked_add(values.len())
                    .ok_or("Too many listening segments")?;
                if segment_count > MAX_SEGMENTS {
                    return Err("Too many listening segments".into());
                }
                let mut segments = Vec::with_capacity(values.len());
                for value in values {
                    check()?;
                    let day = value
                        .get("day")
                        .and_then(Value::as_str)
                        .filter(|s| s.len() <= 32)
                        .ok_or("Invalid listening segment")?;
                    let milliseconds = value
                        .get("milliseconds")
                        .and_then(Value::as_i64)
                        .ok_or("Invalid listening segment")?;
                    segments.push(Segment {
                        day: day.to_owned(),
                        milliseconds,
                    });
                }
                let deltas = engine
                    .advance(&segments)
                    .map_err(|_| "Invalid listening advance")?;
                let mut batch = Vec::with_capacity(deltas.len());
                for d in deltas {
                    check()?;
                    batch.push(json!({"day":d.day,"track":d.track_key,"milliseconds":d.milliseconds,"plays":d.plays}));
                }
                batches.push(batch);
            }
            _ => return Err("Invalid listening event".into()),
        }
    }
    check()?;
    if step {
        let state = engine.snapshot();
        Ok(
            json!({"version":2,"state":{"version":state.version,"track":state.track,"playing":state.playing,"enabled":state.enabled,"session_ms":state.session_ms,"counted":state.counted},"batches":batches}),
        )
    } else {
        Ok(json!({"version": 1, "batches": batches}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn incremental_snapshot_round_trip_and_validation() {
        let state = json!({"version":1,"track":null,"playing":false,"enabled":true,"session_ms":0,"counted":false});
        let first = json!({"version":2,"state":state,"events":[
            {"type":"update","track":"x","playing":true,"ended":false},
            {"type":"advance","segments":[{"day":"d","milliseconds":29000}]}
        ]});
        let a = execute_step(&first, &|| Ok(())).unwrap();
        assert_eq!(a["batches"][0][0]["plays"], 0);
        let second = json!({"version":2,"state":a["state"],"events":[
            {"type":"advance","segments":[{"day":"d","milliseconds":1000}]}
        ]});
        let b = execute_step(&second, &|| Ok(())).unwrap();
        assert_eq!(b["batches"][0][0]["plays"], 1);
        assert_eq!(execute_step(&second, &|| Ok(())).unwrap(), b);
        let third = json!({"version":2,"state":b["state"],"events":[{"type":"advance","segments":[{"day":"d","milliseconds":1}]}]});
        assert_eq!(
            execute_step(&third, &|| Ok(())).unwrap()["batches"][0][0]["plays"],
            0
        );
        let mut invalid = first.clone();
        invalid["state"]["counted"] = json!(true);
        assert!(execute_step(&invalid, &|| Ok(())).is_err());
        invalid = first.clone();
        invalid["events"][0]["playing"] = json!("private");
        assert!(
            !execute_step(&invalid, &|| Ok(()))
                .unwrap_err()
                .contains("private")
        );
    }

    #[test]
    fn incremental_rejects_unreachable_states_and_overflow_atomically() {
        let valid = json!({"version":1,"track":"secret","playing":true,"enabled":true,"session_ms":0,"counted":false});
        for changes in [
            json!({"version":2}),
            json!({"session_ms":-1}),
            json!({"session_ms":30000}),
            json!({"counted":true}),
            json!({"track":null,"session_ms":1}),
            json!({"track":42}),
        ] {
            let mut state = valid.clone();
            for (key, value) in changes.as_object().unwrap() {
                state[key] = value.clone();
            }
            let error = execute_step(&json!({"version":2,"state":state,"events":[]}), &|| Ok(()))
                .unwrap_err();
            assert_eq!(error, "Invalid listening state");
        }
        let mut state = valid;
        state["session_ms"] = json!(i64::MAX);
        state["counted"] = json!(true);
        let request = json!({"version":2,"state":state,"events":[{"type":"advance","segments":[{"day":"secret","milliseconds":1}]}]});
        assert_eq!(
            execute_step(&request, &|| Ok(())).unwrap_err(),
            "Invalid listening advance"
        );
        assert_eq!(
            execute_step(&request, &|| Ok(())).unwrap_err(),
            "Invalid listening advance"
        );
        assert_eq!(
            execute_step(&request, &|| Err("cancelled".into())).unwrap_err(),
            "cancelled"
        );
    }

    #[test]
    fn exported_data_job_routes_incremental_step() {
        let request = json!({"operation":"musa_listening_step_v2","version":2,
            "state":{"version":1,"track":null,"playing":true,"enabled":true,"session_ms":0,"counted":false},"events":[]});
        let result = crate::run_native_data_job(request.to_string(), vec![], None).unwrap();
        let result: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(result["state"]["playing"], true);
        assert_eq!(result["version"], 2);
    }

    #[test]
    fn independent_snapshots_and_new_playback_instance() {
        let initial = json!({"version":1,"track":null,"playing":false,"enabled":true,"session_ms":0,"counted":false});
        let start = |track: &str, ms: i64| {
            execute_step(
                &json!({"version":2,"state":initial,"events":[
                    {"type":"update","track":track,"playing":true,"ended":false},
                    {"type":"advance","segments":[{"day":"d","milliseconds":ms}]}
                ]}),
                &|| Ok(()),
            )
            .unwrap()
        };
        let a = start("instance-a", 29000);
        let b = start("instance-b", 1000);
        let advance = |state: &Value, ms: i64| {
            execute_step(
                &json!({"version":2,"state":state,"events":[
                    {"type":"advance","segments":[{"day":"d","milliseconds":ms}]}
                ]}),
                &|| Ok(()),
            )
            .unwrap()
        };
        assert_eq!(advance(&a["state"], 1000)["batches"][0][0]["plays"], 1);
        assert_eq!(advance(&b["state"], 1000)["batches"][0][0]["plays"], 0);
        let reset = execute_step(
            &json!({"version":2,"state":a["state"],"events":[
                {"type":"update","track":"instance-a-next","playing":true,"ended":false},
                {"type":"advance","segments":[{"day":"d","milliseconds":1000}]}
            ]}),
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(reset["state"]["session_ms"], 1000);
        assert_eq!(reset["batches"][0][0]["plays"], 0);
    }

    #[test]
    fn late_failure_and_mid_batch_cancellation_leave_retry_input_unchanged() {
        let state = json!({"version":1,"track":"x","playing":true,"enabled":true,"session_ms":29000,"counted":false});
        let mut request = json!({"version":2,"state":state,"events":[
            {"type":"advance","segments":[{"day":"d","milliseconds":1000}]},
            {"type":"advance","segments":[{"day":"private","milliseconds":0}]}
        ]});
        assert_eq!(
            execute_step(&request, &|| Ok(())).unwrap_err(),
            "Invalid listening advance"
        );
        request["events"].as_array_mut().unwrap().pop();
        let result = execute_step(&request, &|| Ok(())).unwrap();
        assert_eq!(result["batches"][0][0]["plays"], 1);
        assert_eq!(result["state"]["session_ms"], 30000);
        let many = json!({"version":2,"state":state,"events":[{"type":"advance","segments":
            vec![json!({"day":"d","milliseconds":1}); 100]}]});
        let checks = Cell::new(0);
        let cancelled = execute_step(&many, &|| {
            checks.set(checks.get() + 1);
            if checks.get() == 10 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(cancelled.unwrap_err(), "cancelled");
        assert_eq!(checks.get(), 10);
        assert_eq!(
            execute_step(&many, &|| Ok(())).unwrap()["state"]["session_ms"],
            29100
        );
    }

    #[test]
    fn same_track_new_instance_resets_via_public_job() {
        let state = json!({"version":1,"track":null,"playing":false,"enabled":true,"session_ms":0,"counted":false});
        let call = |state: Value, events: Value| {
            let request = json!({"operation":"musa_listening_step_v2","version":2,"state":state,"events":events});
            let result = crate::run_native_data_job(request.to_string(), vec![], None).unwrap();
            serde_json::from_str::<Value>(&result).unwrap()
        };
        let first = call(
            state,
            json!([
                {"type":"update","track":"A","playing":true,"ended":false},
                {"type":"advance","segments":[{"day":"d","milliseconds":30000}]}
            ]),
        );
        let second = call(
            first["state"].clone(),
            json!([
                {"type":"reset"},
                {"type":"update","track":"A","playing":true,"ended":false},
                {"type":"advance","segments":[{"day":"d","milliseconds":30000}]}
            ]),
        );
        assert_eq!(first["batches"][0][0]["plays"], 1);
        assert_eq!(second["batches"][0][0]["plays"], 1);
    }

    #[test]
    fn bridge_bounds_track_keys_in_utf8_bytes() {
        let key_1024 = "é".repeat(512);
        let key_1025 = format!("{}a", key_1024);
        assert_eq!(key_1024.len(), 1024);
        assert_eq!(key_1025.len(), 1025);
        let state = json!({"version":1,"track":null,"playing":false,"enabled":true,"session_ms":0,"counted":false});
        let request = |track: &str| {
            json!({"version":2,"state":state,"events":[
                {"type":"update","track":track,"playing":true,"ended":false}
            ]})
        };
        let accepted = execute_step(&request(&key_1024), &|| Ok(())).unwrap();
        assert_eq!(
            execute_step(&request(&key_1025), &|| Ok(())).unwrap_err(),
            "Invalid listening event"
        );
        let mut state_request = json!({"version":2,"state":accepted["state"],"events":[]});
        assert!(execute_step(&state_request, &|| Ok(())).is_ok());
        state_request["state"]["track"] = json!(key_1025);
        assert_eq!(
            execute_step(&state_request, &|| Ok(())).unwrap_err(),
            "Invalid listening state"
        );
    }

    #[test]
    fn bounds_segments_across_batches() {
        let segment = json!({"day":"2026-03-07", "milliseconds":1});
        let batch = vec![segment.clone(); MAX_SEGMENTS / 2];
        let mut request = json!({"events":[
            {"type":"advance", "segments":batch},
            {"type":"advance", "segments":vec![segment.clone(); MAX_SEGMENTS / 2]}
        ]});
        assert!(execute(&request, &|| Ok(())).is_ok());
        request["events"][1]["segments"]
            .as_array_mut()
            .unwrap()
            .push(segment);
        assert_eq!(
            execute(&request, &|| Ok(())).unwrap_err(),
            "Too many listening segments"
        );
    }

    #[test]
    fn cancellation_is_checked_inside_segment_loop() {
        let request = json!({"events":[{"type":"advance", "segments":
            vec![json!({"day":"2026-03-07", "milliseconds":1}); 100]
        }]});
        let checks = Cell::new(0);
        let result = execute(&request, &|| {
            checks.set(checks.get() + 1);
            if checks.get() == 10 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(result.unwrap_err(), "cancelled");
        assert_eq!(checks.get(), 10);
    }
    #[test]
    fn replays_segments_and_rejects_bad_batches_without_leaking_values() {
        let request = json!({"events":[
            {"type":"update","track":"private","playing":true,"ended":false},
            {"type":"advance","segments":[{"day":"2026-03-07","milliseconds":29000},{"day":"2026-03-08","milliseconds":1000}]}
        ]});
        let result = execute(&request, &|| Ok(())).unwrap();
        assert_eq!(result["batches"][0][0]["plays"], 0);
        assert_eq!(result["batches"][0][1]["plays"], 1);
        let bad =
            json!({"events":[{"type":"advance","segments":[{"day":"secret","milliseconds":0}]}]});
        assert!(!execute(&bad, &|| Ok(())).unwrap_err().contains("secret"));
        assert!(execute(&request, &|| Err("cancelled".into())).is_err());
    }

    #[test]
    fn exported_data_job_routes_to_listening_engine() {
        let request = json!({"operation":"musa_listening_replay_v1", "events":[
            {"type":"update","track":"x","playing":true,"ended":false},
            {"type":"advance","segments":[{"day":"2026-11-01","milliseconds":30000}]}
        ]});
        let result = crate::run_native_data_job(request.to_string(), vec![], None).unwrap();
        let result: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(result["batches"][0][0]["plays"], 1);
    }
}
