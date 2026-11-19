//! Isolated integrity experiments. No download path calls this module.

use md5::{Digest, Md5};
use mornye_providers::resolver::Check;
use std::io::{Read, Seek, SeekFrom};

fn validate_source(source: &mut cap_std::fs::File, check: &Check<'_>) -> Result<(), String> {
    let invalid = || "invalid or incomplete FLAC source".to_owned();
    source.seek(SeekFrom::Start(0)).map_err(|_| invalid())?;
    let mut reader =
        claxon::FlacReader::new(std::io::BufReader::new(source)).map_err(|_| invalid())?;
    let info = reader.streaminfo();
    let expected = info
        .samples
        .and_then(|count| count.checked_mul(u64::from(info.channels)))
        .filter(|count| *count != 0)
        .ok_or("FLAC STREAMINFO is missing a valid sample count")?;
    let sample_width = usize::try_from(info.bits_per_sample.div_ceil(8)).map_err(|_| invalid())?;
    if !(1..=4).contains(&sample_width) {
        return Err(invalid());
    }
    // STREAMINFO is source-provided. A matching digest and sample count detect
    // truncation/corruption but do not authenticate a producer or CENC payload.
    let mut checksum = (info.md5sum != [0; 16]).then(Md5::new);
    let limit = u64::from(info.sample_rate) * u64::from(info.channels) * 6 * 3600;
    let mut count = 0u64;
    for sample in reader.samples() {
        if count.is_multiple_of(4096) {
            check()?;
        }
        let sample = sample.map_err(|_| invalid())?;
        if let Some(checksum) = checksum.as_mut() {
            checksum.update(&sample.to_le_bytes()[..sample_width]);
        }
        count += 1;
        if count > limit {
            return Err(invalid());
        }
    }
    if count != expected || checksum.is_some_and(|value| value.finalize().as_slice() != info.md5sum)
    {
        return Err(invalid());
    }
    check()
}

fn ogg_crc(header: &[u8], segments: &[u8], payload: &[u8]) -> u32 {
    let mut crc = 0u32;
    for &byte in header.iter().chain(segments).chain(payload) {
        crc ^= u32::from(byte) << 24;
        for _ in 0..8 {
            crc = if crc & (1 << 31) == 0 {
                crc << 1
            } else {
                (crc << 1) ^ 0x04c11db7
            };
        }
    }
    crc
}

fn verify_ogg_opus(file: &mut impl Read, check: &Check<'_>) -> Result<(), String> {
    let invalid = || "Opus output has an invalid or incomplete Ogg stream".to_owned();
    let mut serial = [0u8; 4];
    let mut sequence = 0u32;
    let mut pre_skip = 0u16;
    let mut continued = false;
    let mut complete_packets = 0usize;
    let mut payload = vec![0u8; 255 * 255];
    loop {
        check()?;
        let mut header = [0u8; 27];
        file.read_exact(&mut header).map_err(|_| invalid())?;
        if &header[..5] != b"OggS\0"
            || header[5] & !7 != 0
            || (header[5] & 1 != 0) != continued
            || header[18..22] != sequence.to_le_bytes()
        {
            return Err(invalid());
        }
        let mut segments = [0u8; 255];
        let segments = &mut segments[..usize::from(header[26])];
        file.read_exact(segments).map_err(|_| invalid())?;
        let size = segments.iter().map(|size| usize::from(*size)).sum();
        let payload = &mut payload[..size];
        file.read_exact(payload).map_err(|_| invalid())?;
        let expected_crc = u32::from_le_bytes(header[22..26].try_into().expect("fixed header"));
        header[22..26].fill(0);
        if expected_crc != ogg_crc(&header, segments, payload) || segments.is_empty() {
            return Err(invalid());
        }
        continued = segments.last() == Some(&255);
        complete_packets += segments.iter().filter(|size| **size != 255).count();
        if sequence == 0 {
            if header[5] != 2
                || segments.len() != 1
                || continued
                || payload.len() < 19
                || &payload[..8] != b"OpusHead"
            {
                return Err(invalid());
            }
            serial.copy_from_slice(&header[14..18]);
            pre_skip = u16::from_le_bytes([payload[10], payload[11]]);
        } else if header[14..18] != serial || header[5] & 2 != 0 {
            return Err(invalid());
        }
        if sequence == 1 && !payload.starts_with(b"OpusTags") {
            return Err(invalid());
        }
        if header[5] & 4 != 0 {
            let granule = i64::from_le_bytes(header[6..14].try_into().expect("fixed header"));
            if complete_packets < 3
                || continued
                || granule <= i64::from(pre_skip)
                || file.read(&mut [0]).map_err(|_| invalid())? != 0
            {
                return Err(invalid());
            }
            return Ok(());
        }
        sequence = sequence.checked_add(1).ok_or_else(invalid)?;
    }
}

#[test]
fn requires_complete_flac_count_and_checks_streaminfo_md5() {
    use std::process::Command;
    let work = tempfile::tempdir().unwrap();
    let source = work.path().join("source.flac");
    assert!(
        Command::new("ffmpeg")
            .args([
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "anullsrc=r=44100:cl=stereo",
                "-t",
                "0.4",
                "-c:a",
                "flac",
                "-sample_fmt",
                "s16"
            ])
            .arg(&source)
            .status()
            .unwrap()
            .success()
    );
    let bytes = std::fs::read(&source).unwrap();
    let validate = |data: &[u8]| {
        std::fs::write(&source, data).unwrap();
        let mut file = cap_std::fs::File::from_std(std::fs::File::open(&source).unwrap());
        validate_source(&mut file, &|| Ok(()))
    };
    assert!(validate(&bytes).is_ok());
    assert_ne!(&bytes[26..42], &[0; 16]);
    let mut no_md5 = bytes.clone();
    no_md5[26..42].fill(0);
    assert!(validate(&no_md5).is_ok());
    let mut wrong_md5 = bytes.clone();
    wrong_md5[26] ^= 1;
    let mut unknown_count = bytes.clone();
    unknown_count[21] &= 0xf0;
    unknown_count[22..26].fill(0);
    let mut boundary = None;
    for length in (bytes.len().saturating_sub(256)..bytes.len()).rev() {
        let mut reader = claxon::FlacReader::new(&bytes[..length]).unwrap();
        if let Ok(samples) = reader.samples().collect::<Result<Vec<_>, _>>()
            && !samples.is_empty()
        {
            boundary = Some(length);
            break;
        }
    }
    let boundary = boundary.expect("fixture has multiple complete FLAC frames");
    let mut failures = Vec::new();
    if validate(&bytes[..boundary]).is_ok() {
        failures.push("truncated at frame boundary");
    }
    if validate(&wrong_md5).is_ok() {
        failures.push("wrong MD5");
    }
    if validate(&unknown_count).is_ok() {
        failures.push("unknown sample count");
    }
    if validate(&bytes[..bytes.len() - 1]).is_ok() {
        failures.push("truncated frame");
    }
    assert!(failures.is_empty(), "accepted {failures:?}");
}

#[test]
fn requires_ogg_crc_and_complete_eos() {
    use std::process::Command;
    let work = tempfile::tempdir().unwrap();
    let target = work.path().join("target.opus");
    assert!(
        Command::new("ffmpeg")
            .args([
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "anullsrc=r=48000:cl=mono",
                "-t",
                "0.2",
                "-c:a",
                "libopus"
            ])
            .arg(&target)
            .status()
            .unwrap()
            .success()
    );
    let opus = std::fs::read(&target).unwrap();
    let validate = |mut bytes: &[u8]| verify_ogg_opus(&mut bytes, &|| Ok(()));
    assert!(validate(&opus).is_ok());
    let final_page = opus.windows(4).rposition(|part| part == b"OggS").unwrap();
    for flags in [0u8, 5] {
        let mut malformed = opus.clone();
        let page = &mut malformed[final_page..];
        // Missing EOS or a continuation without a prior partial packet.
        page[5] = flags;
        page[22..26].fill(0);
        let segments_end = 27 + usize::from(page[26]);
        let crc = ogg_crc(&page[..27], &page[27..segments_end], &page[segments_end..]);
        page[22..26].copy_from_slice(&crc.to_le_bytes());
        assert!(
            validate(&malformed).is_err(),
            "accepted flags {flags} with a valid CRC"
        );
    }
    let mut bad_crc = opus.clone();
    *bad_crc.last_mut().unwrap() ^= 1;
    assert!(
        validate(&bad_crc).is_err(),
        "accepted altered packet with stale CRC"
    );
    assert!(
        validate(&opus[..opus.len() - 1]).is_err(),
        "accepted truncated EOS packet"
    );
}
