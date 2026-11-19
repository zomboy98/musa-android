//! Line protocol for differential tests only. Not linked into any host.
use musa_listening::{ListeningEngine, Segment};
use std::io::{self, BufRead, Write};

fn decode(s: &str) -> Result<String, ()> {
    if s.len() % 2 != 0 {
        return Err(());
    }
    let bytes = (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2).ok_or(())?, 16).map_err(|_| ()))
        .collect::<Result<Vec<_>, _>>()?;
    String::from_utf8(bytes).map_err(|_| ())
}
fn encode(s: &str) -> String {
    s.as_bytes().iter().map(|b| format!("{b:02x}")).collect()
}

fn main() {
    let mut engine = ListeningEngine::new();
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let parts: Vec<_> = line.split('\t').collect();
        let response = match parts.as_slice() {
            ["update", key, playing, ended]
                if matches!(*playing, "0" | "1") && matches!(*ended, "0" | "1") =>
            {
                let key = if *key == "-" {
                    Ok(None)
                } else {
                    decode(key).map(Some)
                };
                match key {
                    Ok(key) => {
                        engine.update(key, *playing == "1", *ended == "1");
                        "ok".to_string()
                    }
                    Err(_) => "error\tinvalid".to_string(),
                }
            }
            ["enabled", enabled] if matches!(*enabled, "0" | "1") => {
                engine.set_enabled(*enabled == "1");
                "ok".to_string()
            }
            ["reset"] => {
                engine.reset_session();
                "ok".to_string()
            }
            ["advance", rest @ ..] => {
                let parsed = rest
                    .iter()
                    .map(|s| {
                        let (day, ms) = s.split_once(':').ok_or(())?;
                        Ok(Segment {
                            day: decode(day)?,
                            milliseconds: ms.parse().map_err(|_| ())?,
                        })
                    })
                    .collect::<Result<Vec<_>, ()>>();
                match parsed {
                    Err(_) => "error\tinvalid".to_string(),
                    Ok(segments) => match engine.advance(&segments) {
                        Err(e) => format!("error\t{e:?}"),
                        Ok(deltas) => {
                            let mut out = "ok".to_string();
                            for d in deltas {
                                out.push_str(&format!(
                                    "\t{}:{}:{}:{}",
                                    encode(&d.day),
                                    encode(&d.track_key),
                                    d.milliseconds,
                                    d.plays
                                ));
                            }
                            out
                        }
                    },
                }
            }
            _ => "error\tinvalid".to_string(),
        };
        println!("{response}");
        if io::stdout().flush().is_err() {
            break;
        }
    }
}
