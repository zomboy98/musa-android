use mornye_core::media::probe_quality;
use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};

const OPUS_RATE: i64 = 48_000;
const OGG_TAIL: u64 = 65_536;

pub(super) fn measured_duration_ms(file: &mut (impl Read + Seek)) -> Option<i64> {
    file.seek(SeekFrom::Start(0)).ok()?;
    let mut head = vec![0u8; 4096];
    let count = read_up_to(file, &mut head)?;
    head.truncate(count);
    let duration = if head.starts_with(b"OggS") {
        opus_duration_ms(file, &head)
    } else if head.starts_with(b"fLaC")
        || head.starts_with(b"ID3")
        || head.get(4..8) == Some(b"ftyp".as_slice())
    {
        container_duration_ms(file)
    } else {
        None
    };
    duration.filter(|ms| *ms > 0)
}

fn read_up_to(file: &mut impl Read, buffer: &mut [u8]) -> Option<usize> {
    let mut length = 0;
    while length < buffer.len() {
        match file.read(&mut buffer[length..]) {
            Ok(0) => break,
            Ok(count) => length += count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
    Some(length)
}

fn container_duration_ms(file: &mut (impl Read + Seek)) -> Option<i64> {
    let quality = probe_quality(file, &|| Ok(())).ok()?;
    if quality.total_samples > 0 && quality.sample_rate > 0 {
        return quality
            .total_samples
            .checked_mul(1000)
            .map(|scaled| scaled / quality.sample_rate);
    }
    quality.duration.checked_mul(1000)
}

fn opus_duration_ms(file: &mut (impl Read + Seek), head: &[u8]) -> Option<i64> {
    let start = head.windows(8).position(|window| window == b"OpusHead")?;
    let pre_skip = i64::from(u16::from_le_bytes(
        head.get(start + 10..start + 12)?.try_into().ok()?,
    ));
    let size = file.seek(SeekFrom::End(0)).ok()?;
    file.seek(SeekFrom::Start(size.saturating_sub(OGG_TAIL)))
        .ok()?;
    let mut tail = vec![0u8; usize::try_from(size.min(OGG_TAIL)).ok()?];
    let count = read_up_to(file, &mut tail)?;
    tail.truncate(count);
    let granule = (0..tail.len().saturating_sub(26))
        .rev()
        .find_map(|offset| {
            let page = &tail[offset..];
            if &page[..4] != b"OggS" || page[4] != 0 || page[5] > 7 {
                return None;
            }
            let header = 27 + usize::from(page[26]);
            let payload: usize = page
                .get(27..header)?
                .iter()
                .map(|size| usize::from(*size))
                .sum();
            (page.len() >= header + payload)
                .then(|| i64::from_le_bytes(page[6..14].try_into().expect("fixed header")))
        })?;
    (granule > pre_skip).then(|| (granule - pre_skip) * 1000 / OPUS_RATE)
}

pub(super) fn duration_mismatch_ms(expected_ms: i64, result: &Value) -> Option<i64> {
    let actual = result["actual_duration_ms"].as_i64().filter(|ms| *ms > 0)?;
    if expected_ms <= 0 {
        return None;
    }
    let tolerance = 3000.max(expected_ms * 3 / 200);
    let difference = actual - expected_ms;
    (difference.abs() > tolerance).then_some(difference)
}

pub(super) fn duration_mismatch_message(
    provider: &str,
    expected_ms: i64,
    difference_ms: i64,
) -> String {
    format!(
        "duration_mismatch: provider {provider} returned audio of {:.1} s but the catalog expects {:.1} s (difference {:+.1} s)",
        (expected_ms + difference_ms) as f64 / 1000.0,
        expected_ms as f64 / 1000.0,
        difference_ms as f64 / 1000.0,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Cursor;

    fn flac(samples: u64, rate: u64) -> Vec<u8> {
        let mut bytes = b"fLaC\x80\0\0\x22".to_vec();
        let mut info = [0u8; 34];
        let packed = (rate << 44) | (1 << 41) | (15 << 36) | samples;
        info[10..18].copy_from_slice(&packed.to_be_bytes());
        bytes.extend_from_slice(&info);
        bytes
    }

    fn ogg_page(flags: u8, granule: i64, sequence: u32, payload: &[u8]) -> Vec<u8> {
        let mut page = b"OggS\0".to_vec();
        page.push(flags);
        page.extend_from_slice(&granule.to_le_bytes());
        page.extend_from_slice(&1u32.to_le_bytes());
        page.extend_from_slice(&sequence.to_le_bytes());
        page.extend_from_slice(&[0; 4]);
        page.push(1);
        page.push(payload.len() as u8);
        page.extend_from_slice(payload);
        page
    }

    fn opus(pre_skip: u16, granule: i64) -> Vec<u8> {
        let mut head = b"OpusHead\x01\x02".to_vec();
        head.extend_from_slice(&pre_skip.to_le_bytes());
        head.extend_from_slice(&48_000u32.to_le_bytes());
        head.extend_from_slice(&[0, 0, 0]);
        let mut bytes = ogg_page(2, 0, 0, &head);
        bytes.extend(ogg_page(0, 0, 1, b"OpusTags"));
        bytes.extend(ogg_page(0, granule / 2, 2, &[0; 20]));
        bytes.extend(ogg_page(4, granule, 3, &[0; 20]));
        bytes
    }

    #[test]
    fn flac_duration_comes_from_total_samples() {
        let bytes = flac(44_100 * 201, 44_100);
        assert_eq!(measured_duration_ms(&mut Cursor::new(bytes)), Some(201_000));
    }

    #[test]
    fn opus_duration_is_final_granule_minus_pre_skip_at_48_khz() {
        let granule = 48_000 * 180 + 312;
        let bytes = opus(312, granule);
        assert_eq!(measured_duration_ms(&mut Cursor::new(bytes)), Some(180_000));
    }

    #[test]
    fn unknown_or_empty_bytes_have_no_duration() {
        assert_eq!(
            measured_duration_ms(&mut Cursor::new(b"<html>".to_vec())),
            None
        );
        assert_eq!(measured_duration_ms(&mut Cursor::new(Vec::new())), None);
        assert_eq!(
            measured_duration_ms(&mut Cursor::new(flac(0, 44_100))),
            None
        );
    }

    #[test]
    fn sped_up_file_is_rejected_with_the_difference() {
        let result = json!({"actual_duration_ms": 180_000});
        assert_eq!(duration_mismatch_ms(201_000, &result), Some(-21_000));
        let message = duration_mismatch_message("amazon", 201_000, -21_000);
        assert!(message.starts_with("duration_mismatch:"));
        assert!(message.contains("-21.0 s"));
    }

    #[test]
    fn tolerance_is_the_larger_of_three_seconds_and_one_and_a_half_percent() {
        let within = |expected, actual| {
            duration_mismatch_ms(expected, &json!({"actual_duration_ms": actual})).is_none()
        };
        assert!(within(100_000, 102_900));
        assert!(!within(100_000, 103_100));
        assert!(within(300_000, 304_400));
        assert!(!within(300_000, 304_600));
        assert!(within(300_000, 295_600));
        assert!(!within(300_000, 295_400));
    }

    #[test]
    fn missing_expected_or_measured_duration_never_blocks() {
        assert_eq!(
            duration_mismatch_ms(0, &json!({"actual_duration_ms": 180_000})),
            None
        );
        assert_eq!(duration_mismatch_ms(201_000, &json!({})), None);
        assert_eq!(
            duration_mismatch_ms(201_000, &json!({"actual_duration_ms": null})),
            None
        );
    }
}
