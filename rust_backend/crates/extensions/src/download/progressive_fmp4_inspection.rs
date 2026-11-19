//! Experimental fMP4 signal inspection, not a DRM or clear-media proof.
//! No production admission or provider path calls this module. It examines
//! bounded initialization metadata and one complete `moof` at a time; callers
//! must re-inspect every fragment and stop on unsupported or protected data.

#![allow(dead_code)]

const MAX_METADATA: usize = 256 * 1024;
const MAX_DEPTH: usize = 12;
const MAX_BOXES: usize = 4096;

#[derive(Debug, PartialEq, Eq)]
enum Inspection { NoExplicitProtectionSeen }

#[derive(Debug, PartialEq, Eq)]
enum Reject { Truncated, Invalid, Protected, Unsupported, Limit }

#[derive(Clone, Copy)]
enum Phase { Ftyp, Moov, MoofOrIndex, MdatHeader, Mdat { end: u64 }, Done }

/// Tracks only box metadata. The resulting prefix is provisional: it means no
/// explicit protection was observed in boxes inspected so far, not that media
/// is decrypted, authentic, fully valid, or safe to retain permanently.
pub(crate) struct Fmp4Inspector {
    phase: Phase,
    offset: u64,
    approved: u64,
    init: Vec<u8>,
    fragments: usize,
    /// Generic audio mode: also accept a non-fragmented MP4/M4A whose `moov`
    /// precedes `mdat`. The strict provisional-fMP4 door keeps this off.
    allow_classic: bool,
    classic: bool,
    /// Stable token naming why bytes were refused; never contains data.
    reason: Option<&'static str>,
}

impl Default for Fmp4Inspector {
    fn default() -> Self { Self { phase: Phase::Ftyp, offset: 0, approved: 0, init: Vec::new(), fragments: 0, allow_classic: false, classic: false, reason: None } }
}

impl Fmp4Inspector {
    /// Inspector for the generic audio lease: fragmented MP4 as before plus
    /// progressive (moov-first) M4A. Moov-after-mdat files are rejected with a
    /// typed reason so the caller can fall back to a complete download.
    pub(crate) fn audio() -> Self { Self { allow_classic: true, ..Self::default() } }

    pub(crate) fn reason(&self) -> Option<&'static str> { self.reason }

    pub(crate) fn advance(&mut self, written: u64, mut read: impl FnMut(u64, usize) -> std::io::Result<Vec<u8>>) -> Result<u64, ()> {
        if written < self.offset || written < self.approved { return Err(()); }
        loop {
            if let Phase::Mdat { end } = self.phase {
                self.approved = written.min(end);
                if written < end { return Ok(self.approved); }
                self.offset = end;
                self.phase = Phase::MoofOrIndex;
                continue;
            }
            if written.saturating_sub(self.offset) < 8 { return Ok(self.approved); }
            let header = read(self.offset, 8).map_err(|_| ())?;
            if self.offset == 0 && std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() {
                let format = if header.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]) { "webm_ebml" } else if header.starts_with(b"OggS") { "ogg" } else if &header[4..8] == b"ftyp" { "mp4" } else if header.starts_with(b"ID3") { "mp3_id3" } else { "other" };
                eprintln!("inspection_initial_format={format}");
            }
            let short = be32(&header).map_err(|_| ())?;
            let mut header_len = 8u64;
            let size = if short == 1 {
                if written.saturating_sub(self.offset) < 16 { return Ok(self.approved); }
                let extra = read(self.offset + 8, 8).map_err(|_| ())?;
                header_len = 16;
                u64::from_be_bytes(extra.try_into().map_err(|_| ())?)
            } else if short == 0 { return Err(()); } else { u64::from(short) };
            if size < header_len { return Err(()); }
            let end = self.offset.checked_add(size).ok_or(())?;
            let kind = &header[4..8];
            if matches!(self.phase, Phase::MdatHeader) {
                if kind != b"mdat" { return Err(()); }
                self.offset += header_len;
                self.approved = self.offset;
                self.phase = Phase::Mdat { end };
                continue;
            }
            if self.allow_classic && kind == b"mdat" {
                match self.phase {
                    Phase::Moov => { self.reason = Some("metadata_after_media"); return Err(()); }
                    Phase::MoofOrIndex if self.fragments == 0 && !self.init.windows(4).any(|w| w == b"mvex") => {
                        // The moov was inspected and declares no fragments, so
                        // the payload is the single media box and can stream.
                        self.classic = true;
                        self.offset += header_len;
                        self.approved = self.offset;
                        self.phase = Phase::Mdat { end };
                        continue;
                    }
                    _ => {}
                }
            }
            if size > MAX_METADATA as u64 { self.reason = Some("metadata_too_large"); return Err(()); }
            if written < end { return Ok(self.approved); }
            let atom = read(self.offset, size as usize).map_err(|_| ())?;
            match self.phase {
                Phase::Ftyp if kind == b"ftyp" => {
                    self.init.extend_from_slice(&atom); self.phase = Phase::Moov;
                }
                Phase::Moov if kind == b"moov" => {
                    if self.init.len().checked_add(atom.len()).ok_or(())? > MAX_METADATA { return Err(()); }
                    self.init.extend_from_slice(&atom);
                    let init_result = inspect_init(&self.init);
                    if let Err(reason) = &init_result { self.reason = Some(if *reason == Reject::Protected { "protected_media" } else { "unsupported_mp4_structure" }); }
                    init_result.map_err(|reason| { if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("inspection_init={}", match reason { Reject::Protected => "protected", Reject::Truncated => "truncated", Reject::Invalid => "invalid", Reject::Unsupported => "unsupported", Reject::Limit => "limit" }); } })?;
                    self.approved = end; self.phase = Phase::MoofOrIndex;
                }
                Phase::MoofOrIndex if matches!(kind, b"sidx" | b"free" | b"skip") => { self.approved = end; }
                Phase::MoofOrIndex if kind == b"moof" => {
                    let fragment_result = inspect_fragment(&atom);
                    if let Err(reason) = &fragment_result { self.reason = Some(if *reason == Reject::Protected { "protected_media" } else { "unsupported_mp4_structure" }); }
                    fragment_result.map_err(|reason| { if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("inspection_fragment={}", match reason { Reject::Protected => "protected", Reject::Truncated => "truncated", Reject::Invalid => "invalid", Reject::Unsupported => "unsupported", Reject::Limit => "limit" }); } })?;
                    self.fragments += 1; self.approved = end; self.phase = Phase::MdatHeader;
                }
                Phase::MoofOrIndex if kind == b"mfra" && self.fragments > 0 => {
                    inspect_mfra(&atom).map_err(|_| ())?;
                    self.approved = end; self.phase = Phase::Done;
                }
                _ => { self.reason = Some("unsupported_mp4_structure"); if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("inspection_structure=unexpected_box"); } return Err(()); },
            }
            self.offset = end;
        }
    }

    pub(crate) fn complete(&self, total: u64) -> bool {
        matches!(self.phase, Phase::MoofOrIndex | Phase::Done) && (self.fragments > 0 || self.classic) && self.offset == total && self.approved == total
    }
}

#[derive(Default)]
struct Seen { boxes: usize, ftyp: usize, moov: usize, moof: usize, mp4a: usize, esds: usize, tfhd: usize, trun: usize }

fn be32(bytes: &[u8]) -> Result<u32, Reject> {
    Ok(u32::from_be_bytes(bytes.get(..4).ok_or(Reject::Truncated)?.try_into().unwrap()))
}

fn inspect_init(bytes: &[u8]) -> Result<Inspection, Reject> {
    if bytes.len() > MAX_METADATA { return Err(Reject::Limit); }
    if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { diagnostic_tracks(bytes, 0); }
    let mut seen = Seen::default();
    boxes(bytes, b"root", 0, &mut seen)?;
    if seen.ftyp != 1 || seen.moov != 1 || seen.moof != 0 || seen.mp4a != 1 || seen.esds != 1 {
        if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("inspection_counts ftyp={} moov={} moof={} mp4a={} esds={}", seen.ftyp, seen.moov, seen.moof, seen.mp4a, seen.esds); }
        return Err(Reject::Unsupported);
    }
    Ok(Inspection::NoExplicitProtectionSeen)
}

fn diagnostic_tracks(bytes: &[u8], depth: usize) {
    if depth > MAX_DEPTH || std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_none() { return; }
    let mut position = 0usize;
    while position.saturating_add(8) <= bytes.len() {
        let size = u32::from_be_bytes(bytes[position..position + 4].try_into().unwrap()) as usize;
        if size < 8 || size > bytes.len() - position { return; }
        let name = &bytes[position + 4..position + 8]; let payload = &bytes[position + 8..position + size];
        if name == b"hdlr" && payload.len() >= 12 {
            let handler = match &payload[8..12] { b"soun" => "audio", b"vide" => "video", _ => "other" };
            eprintln!("inspection_handler={handler}");
        }
        if name == b"stsd" && payload.len() >= 16 {
            let sample = match &payload[12..16] { b"mp4a" => "mp4a", b"avc1" => "avc1", b"enca" => "enca", b"encv" => "encv", _ => "other" };
            eprintln!("inspection_sample={sample}");
        }
        if matches!(name, b"moov" | b"trak" | b"mdia" | b"minf" | b"stbl") { diagnostic_tracks(payload, depth + 1); }
        position += size;
    }
}

fn inspect_fragment(bytes: &[u8]) -> Result<Inspection, Reject> {
    if bytes.len() > MAX_METADATA { return Err(Reject::Limit); }
    let mut seen = Seen::default();
    boxes(bytes, b"root", 0, &mut seen)?;
    if seen.moof != 1 || seen.tfhd != 1 || seen.trun != 1 || seen.moov != 0 {
        return Err(Reject::Unsupported);
    }
    Ok(Inspection::NoExplicitProtectionSeen)
}

fn inspect_mfra(bytes: &[u8]) -> Result<(), Reject> {
    if bytes.len() < 8 || &bytes[4..8] != b"mfra" { return Err(Reject::Invalid); }
    let header_len = if be32(bytes)? == 1 { if bytes.len() < 16 { return Err(Reject::Truncated); } 16 } else { 8 };
    let mut body = &bytes[header_len..]; let mut saw_mfro = false; let mut count = 0;
    while !body.is_empty() {
        if body.len() < 8 { return Err(Reject::Truncated); }
        count += 1; if count > MAX_BOXES { return Err(Reject::Limit); }
        let size = be32(body)? as usize;
        if size < 8 || size > body.len() { return Err(Reject::Invalid); }
        let payload = &body[8..size];
        match &body[4..8] {
            b"tfra" if !saw_mfro => {
                if payload.len() < 16 { return Err(Reject::Truncated); }
                let version = payload[0];
                if version > 1 || payload[1..4] != [0, 0, 0] { return Err(Reject::Unsupported); }
                let sizes = be32(&payload[8..])?;
                if sizes & !0x3f != 0 { return Err(Reject::Invalid); }
                let entries = be32(&payload[12..])? as usize;
                let entry_size = (if version == 0 { 8usize } else { 16usize }) + ((sizes >> 4 & 3) + (sizes >> 2 & 3) + (sizes & 3) + 3) as usize;
                let expected = entries.checked_mul(entry_size).and_then(|n| n.checked_add(16)).ok_or(Reject::Limit)?;
                if expected != payload.len() { return Err(Reject::Invalid); }
            }
            b"mfro" if !saw_mfro => {
                if payload.len() != 8 || payload[..4] != [0, 0, 0, 0] || be32(&payload[4..])? as usize != bytes.len() { return Err(Reject::Invalid); }
                saw_mfro = true;
            }
            b"pssh" | b"sinf" | b"schi" | b"schm" | b"tenc" | b"enca" | b"encv" | b"senc" | b"saiz" | b"saio" | b"sgpd" | b"sbgp" | b"uuid" => return Err(Reject::Protected),
            _ => return Err(Reject::Unsupported),
        }
        body = &body[size..];
    }
    if !saw_mfro { return Err(Reject::Invalid); }
    Ok(())
}

fn boxes(mut bytes: &[u8], parent: &[u8; 4], depth: usize, seen: &mut Seen) -> Result<(), Reject> {
    if depth > MAX_DEPTH { return Err(Reject::Limit); }
    while !bytes.is_empty() {
        if bytes.len() < 8 { return Err(Reject::Truncated); }
        seen.boxes += 1;
        if seen.boxes > MAX_BOXES { return Err(Reject::Limit); }
        let mut header = 8usize;
        let short = be32(bytes)?;
        let size = if short == 1 {
            header = 16;
            let encoded: [u8; 8] = bytes.get(8..16).ok_or(Reject::Truncated)?.try_into().unwrap();
            usize::try_from(u64::from_be_bytes(encoded)).map_err(|_| Reject::Limit)?
        } else if short == 0 { return Err(Reject::Unsupported); } else { short as usize };
        if size < header { return Err(Reject::Invalid); }
        if size > bytes.len() { return Err(Reject::Truncated); }
        let name = &bytes[4..8];
        let payload = &bytes[header..size];
        if matches!(name, b"pssh" | b"sinf" | b"schi" | b"schm" | b"tenc" | b"enca" | b"encv" | b"senc" | b"saiz" | b"saio" | b"uuid") {
            return Err(Reject::Protected);
        }
        match name {
            // Sample groups are benign only in `stbl` and only for pre-roll / random
            // access grouping (normal AAC carries `roll`). `seig` is CENC; anything
            // else is not understood; outside `stbl` they stay refused.
            b"sgpd" | b"sbgp" if parent == b"stbl" => {
                if payload.len() < 8 { return Err(Reject::Truncated); }
                match &payload[4..8] {
                    b"roll" | b"prol" | b"rap " => {}
                    b"seig" => return Err(Reject::Protected),
                    _ => return Err(Reject::Unsupported),
                }
            }
            b"sgpd" | b"sbgp" => return Err(Reject::Protected),
            b"ftyp" if parent == b"root" => { if payload.len() < 8 { return Err(Reject::Truncated); } seen.ftyp += 1; }
            b"moov" if parent == b"root" => { seen.moov += 1; boxes(payload, b"moov", depth + 1, seen)?; }
            b"moof" if parent == b"root" => { seen.moof += 1; boxes(payload, b"moof", depth + 1, seen)?; }
            b"trak" if parent == b"moov" => boxes(payload, b"trak", depth + 1, seen)?,
            b"mdia" if parent == b"trak" => boxes(payload, b"mdia", depth + 1, seen)?,
            b"minf" if parent == b"mdia" => boxes(payload, b"minf", depth + 1, seen)?,
            b"stbl" if parent == b"minf" => boxes(payload, b"stbl", depth + 1, seen)?,
            b"mvex" if parent == b"moov" => boxes(payload, b"mvex", depth + 1, seen)?,
            b"traf" if parent == b"moof" => boxes(payload, b"traf", depth + 1, seen)?,
            b"stsd" if parent == b"stbl" => {
                if payload.len() < 8 { return Err(Reject::Truncated); }
                if be32(&payload[4..])? != 1 { if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("inspection_reason=sample_entry_count"); } return Err(Reject::Unsupported); }
                boxes(&payload[8..], b"stsd", depth + 1, seen)?;
            }
            b"mp4a" if parent == b"stsd" => {
                if payload.len() < 28 { return Err(Reject::Truncated); }
                if payload[8..10] != [0, 0] { if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { eprintln!("inspection_reason=sample_entry_version"); } return Err(Reject::Unsupported); }
                seen.mp4a += 1;
                boxes(&payload[28..], b"mp4a", depth + 1, seen)?;
            }
            b"esds" if parent == b"mp4a" => { if payload.len() < 4 { return Err(Reject::Truncated); } seen.esds += 1; }
            b"btrt" if parent == b"mp4a" => { if payload.len() < 12 { return Err(Reject::Truncated); } if payload.len() != 12 { return Err(Reject::Invalid); } }
            b"tfhd" if parent == b"traf" => { if payload.len() < 8 { return Err(Reject::Truncated); } seen.tfhd += 1; }
            b"trun" if parent == b"traf" => {
                if payload.len() < 8 { return Err(Reject::Truncated); }
                let flags = be32(payload)? & 0x00ff_ffff;
                if flags & !0x000f05 != 0 { return Err(Reject::Unsupported); }
                let count = be32(&payload[4..])? as usize;
                if count == 0 || count > 1_000_000 { return Err(Reject::Unsupported); }
                let fixed = 8usize + if flags & 1 != 0 { 4 } else { 0 } + if flags & 4 != 0 { 4 } else { 0 };
                let per = [0x100, 0x200, 0x400, 0x800].iter().filter(|flag| flags & **flag != 0).count() * 4;
                let required = count.checked_mul(per).and_then(|n| n.checked_add(fixed)).ok_or(Reject::Limit)?;
                if payload.len() < required { return Err(Reject::Truncated); }
                seen.trun += 1;
            }
            // These are not interpreted as evidence of clear content.
            b"mdat" => return Err(Reject::Unsupported),
            b"mvhd" | b"tkhd" | b"edts" | b"mdhd" | b"hdlr" | b"dinf" | b"stts" | b"stsc" | b"stco" | b"stsz" | b"smhd" | b"trex" | b"mfhd" | b"tfdt" | b"udta" | b"sidx" | b"free" | b"skip" => {}
            _ => { if std::env::var_os("MORNYE_LOCAL_NETWORK_DIAGNOSTIC").is_some() { let safe = if name.iter().all(|b| b.is_ascii_alphanumeric() || *b == b' ') { std::str::from_utf8(name).unwrap_or("other") } else { "other" }; eprintln!("inspection_unknown_box={safe}"); } return Err(Reject::Unsupported); },
        }
        bytes = &bytes[size..];
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn atom(name: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut result = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        result.extend_from_slice(name); result.extend_from_slice(payload); result
    }
    fn init(sample: &[u8; 4], child: &[u8]) -> Vec<u8> {
        let mut entry = vec![0; 28]; entry.extend_from_slice(child);
        let mut stsd = vec![0; 4]; stsd.extend_from_slice(&1u32.to_be_bytes()); stsd.extend(atom(sample, &entry));
        let stbl = atom(b"stbl", &atom(b"stsd", &stsd));
        let moov = atom(b"moov", &atom(b"trak", &atom(b"mdia", &atom(b"minf", &stbl))));
        let mut result = atom(b"ftyp", b"isom\0\0\0\0"); result.extend(moov); result
    }
    fn fragment(extra: &[u8]) -> Vec<u8> {
        let mut traf = atom(b"tfhd", &[0; 8]);
        traf.extend(atom(b"trun", &[0, 0, 0, 0, 0, 0, 0, 1])); traf.extend_from_slice(extra);
        atom(b"moof", &atom(b"traf", &traf))
    }
    /// Classic AAC `moov` as muxed by real encoders: sample tables plus sample groups.
    fn stbl_with(extra: &[u8]) -> Vec<u8> {
        let mut entry = vec![0; 28]; entry.extend(atom(b"esds", &[0; 4]));
        let mut stsd = vec![0; 4]; stsd.extend_from_slice(&1u32.to_be_bytes()); stsd.extend(atom(b"mp4a", &entry));
        let mut stbl = atom(b"stsd", &stsd);
        for name in [b"stts", b"stsc", b"stsz", b"stco"] { stbl.extend(atom(name, &[0; 8])); }
        stbl.extend_from_slice(extra);
        let moov = atom(b"moov", &atom(b"trak", &atom(b"mdia", &atom(b"minf", &atom(b"stbl", &stbl)))));
        let mut result = atom(b"ftyp", b"isom    "); result.extend(moov); result
    }
    fn group(name: &[u8; 4], kind: &[u8; 4]) -> Vec<u8> {
        let mut payload = vec![0, 0, 0, 0]; payload.extend_from_slice(kind); payload.extend_from_slice(&[0; 8]); atom(name, &payload)
    }
    #[test]
    fn roll_sample_groups_in_stbl_are_benign_but_seig_and_unknown_groups_are_not() {
        for name in [b"sgpd", b"sbgp"] {
            for kind in [b"roll", b"prol", b"rap "] {
                assert_eq!(inspect_init(&stbl_with(&group(name, kind))), Ok(Inspection::NoExplicitProtectionSeen), "{name:?} {kind:?}");
            }
            assert_eq!(inspect_init(&stbl_with(&group(name, b"seig"))), Err(Reject::Protected));
            assert_eq!(inspect_init(&stbl_with(&group(name, b"tele"))), Err(Reject::Unsupported));
            assert_eq!(inspect_init(&stbl_with(&atom(name, &[0; 6]))), Err(Reject::Truncated));
        }
        let mut both = group(b"sgpd", b"roll"); both.extend(group(b"sbgp", b"roll"));
        assert_eq!(inspect_init(&stbl_with(&both)), Ok(Inspection::NoExplicitProtectionSeen));
    }
    #[test]
    fn sample_groups_outside_stbl_are_still_refused() {
        let mut traf = atom(b"tfhd", &[0; 8]); traf.extend(atom(b"trun", &[0, 0, 0, 0, 0, 0, 0, 1])); traf.extend(group(b"sbgp", b"roll"));
        assert_eq!(inspect_fragment(&atom(b"moof", &atom(b"traf", &traf))), Err(Reject::Protected));
    }
    #[test]
    fn aac_and_fragment_are_only_provisionally_inspected() {
        assert_eq!(inspect_init(&init(b"mp4a", &atom(b"esds", &[0; 4]))), Ok(Inspection::NoExplicitProtectionSeen));
        assert_eq!(inspect_fragment(&fragment(&[])), Ok(Inspection::NoExplicitProtectionSeen));
    }
    #[test]
    fn bitrate_box_and_terminal_mfra_are_checked_incrementally() {
        let mut children = atom(b"esds", &[0; 4]); children.extend(atom(b"btrt", &[0; 12]));
        let mut stream = init(b"mp4a", &children); stream.extend(fragment(&[])); stream.extend(atom(b"mdat", &[1,2,3]));
        let before_index = stream.len();
        let mut index = atom(b"tfra", &[0; 16]); index.extend(atom(b"mfro", &[0, 0, 0, 0, 0, 0, 0, 48]));
        stream.extend(atom(b"mfra", &index));
        let mut parser = Fmp4Inspector::default();
        let mut read = |offset: u64, len: usize| Ok(stream[offset as usize..offset as usize + len].to_vec());
        assert_eq!(parser.advance(before_index as u64, &mut read), Ok(before_index as u64));
        assert_eq!(parser.advance((stream.len() - 1) as u64, &mut read), Ok(before_index as u64));
        assert!(!parser.complete((stream.len() - 1) as u64));
        assert_eq!(parser.advance(stream.len() as u64, &mut read), Ok(stream.len() as u64));
        assert!(parser.complete(stream.len() as u64));
        let mut bad = atom(b"esds", &[0; 4]); bad.extend(atom(b"btrt", &[0; 11]));
        assert_eq!(inspect_init(&init(b"mp4a", &bad)), Err(Reject::Truncated));
        let mut protected = atom(b"esds", &[0; 4]); protected.extend(atom(b"btrt", &[0; 12])); protected.extend(atom(b"sinf", &[]));
        assert_eq!(inspect_init(&init(b"mp4a", &protected)), Err(Reject::Protected));
        assert_eq!(inspect_mfra(&atom(b"mfra", &atom(b"senc", &[]))), Err(Reject::Protected));
        assert_eq!(inspect_mfra(&atom(b"mfra", &atom(b"tfra", &[0; 15]))), Err(Reject::Truncated));
    }
    #[test]
    fn protected_entries_and_fragment_signals_are_rejected() {
        assert_eq!(inspect_init(&init(b"enca", &[])), Err(Reject::Protected));
        assert_eq!(inspect_init(&init(b"mp4a", &atom(b"sinf", &[]))), Err(Reject::Protected));
        for name in [b"senc", b"saiz", b"saio", b"sgpd", b"sbgp", b"uuid"] {
            assert_eq!(inspect_fragment(&fragment(&atom(name, &[]))), Err(Reject::Protected));
        }
    }
    #[test]
    fn truncation_missing_required_atoms_and_oversize_fail_closed() {
        let mut data = init(b"mp4a", &atom(b"esds", &[0; 4])); data.pop();
        assert_eq!(inspect_init(&data), Err(Reject::Truncated));
        assert_eq!(inspect_fragment(&atom(b"moof", &[])), Err(Reject::Unsupported));
        assert_eq!(inspect_init(&vec![0; MAX_METADATA + 1]), Err(Reject::Limit));
        let mut fragment = fragment(&[]); fragment.pop();
        assert_eq!(inspect_fragment(&fragment), Err(Reject::Truncated));
    }

    #[test]
    fn late_protection_revokes_previously_available_provisional_bytes() {
        use super::super::progressive::{PrefixEvent, PrefixObserver};
        use super::super::progressive_candidate::CandidateGate;
        use super::super::progressive_reader::{ReadAtError, ReadAtResult};
        use std::io::Write;
        use std::time::Duration;
        let root = tempfile::tempdir().unwrap(); let path = root.path().join("source");
        let mut writer = std::fs::File::create(&path).unwrap();
        let gate = CandidateGate::new_inspected(super::super::progressive_container::InspectionKind::Fmp4);
        gate.attach(std::fs::File::open(&path).unwrap()).unwrap();
        let (lease, _) = gate.stream().lease();
        let mut bytes = init(b"mp4a", &atom(b"esds", &[0; 4]));
        bytes.extend(fragment(&[])); bytes.extend(atom(b"mdat", &[1, 2, 3, 4]));
        writer.write_all(&bytes).unwrap(); writer.flush().unwrap();
        gate.notify(PrefixEvent::Available { generation: 0, bytes: bytes.len() as u64 });
        assert!(matches!(lease.read_at(0, 65536, Duration::ZERO).unwrap(), ReadAtResult::Bytes(data) if data == bytes));
        let protected = fragment(&atom(b"senc", &[]));
        writer.write_all(&protected).unwrap(); writer.flush().unwrap();
        gate.notify(PrefixEvent::Available { generation: 0, bytes: (bytes.len() + protected.len()) as u64 });
        assert!(matches!(lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Aborted)));
    }

    #[test]
    fn incomplete_fragment_never_becomes_committed_eof() {
        use super::super::progressive::{PrefixEvent, PrefixObserver};
        use super::super::progressive_candidate::CandidateGate;
        use super::super::progressive_reader::ReadAtError;
        use std::io::Write;
        use std::time::Duration;
        let root = tempfile::tempdir().unwrap(); let path = root.path().join("source");
        let mut writer = std::fs::File::create(&path).unwrap();
        let gate = CandidateGate::new_inspected(super::super::progressive_container::InspectionKind::Fmp4); gate.attach(std::fs::File::open(&path).unwrap()).unwrap();
        let (lease, _) = gate.stream().lease();
        let mut bytes = init(b"mp4a", &atom(b"esds", &[0; 4]));
        let mut partial = fragment(&[]); partial.pop(); bytes.extend(partial);
        writer.write_all(&bytes).unwrap(); writer.flush().unwrap();
        gate.notify(PrefixEvent::Available { generation: 0, bytes: bytes.len() as u64 });
        gate.notify(PrefixEvent::Committed { generation: 0, bytes: bytes.len() as u64 });
        assert!(matches!(lease.read_at(0, 1, Duration::ZERO), Err(ReadAtError::Aborted)));
    }

    #[test]
    #[ignore = "requires explicitly supplied local fMP4 fixture"]
    fn external_ffmpeg_fragmented_fixture_accepts_terminal_index() {
        let path = std::env::var_os("MORNYE_FFMPEG_FMP4_FIXTURE").expect("set local synthetic fixture explicitly");
        let bytes = std::fs::read(path).unwrap();
        assert!(bytes.windows(4).any(|v| v == b"btrt"));
        assert!(bytes.windows(4).any(|v| v == b"mfra"));
        let mut parser = Fmp4Inspector::default();
        let mut available = 0usize;
        while available < bytes.len() {
            available = (available + 97).min(bytes.len());
            let approved = parser.advance(available as u64, |offset, len| Ok(bytes[offset as usize..offset as usize + len].to_vec())).unwrap();
            assert!(approved <= available as u64);
        }
        assert!(parser.complete(bytes.len() as u64));
    }

    #[test]
    #[ignore = "requires explicitly supplied local fMP4 fixture"]
    fn external_fragmented_aac_fixture_checks_only_bounded_metadata_boxes() {
        use std::io::{Read, Seek, SeekFrom};
        let path = std::env::var_os("MORNYE_PROGRESSIVE_FIXTURE").expect("set local fixture explicitly");
        let mut file = std::fs::File::open(path).expect("local fixture unavailable");
        let size = file.metadata().unwrap().len();
        let mut offset = 0u64; let mut init = Vec::new(); let mut fragments = 0;
        while offset < size {
            file.seek(SeekFrom::Start(offset)).unwrap();
            let mut header = [0; 8]; file.read_exact(&mut header).unwrap();
            let short = u32::from_be_bytes(header[..4].try_into().unwrap());
            let len = if short == 1 { let mut extended = [0; 8]; file.read_exact(&mut extended).unwrap(); u64::from_be_bytes(extended) } else { u64::from(short) };
            assert!(len >= 8 && len <= size - offset);
            let kind = &header[4..];
            if kind == b"ftyp" || kind == b"moov" || kind == b"moof" {
                assert!(len <= MAX_METADATA as u64);
                file.seek(SeekFrom::Start(offset)).unwrap();
                let mut atom = vec![0; len as usize]; file.read_exact(&mut atom).unwrap();
                if kind == b"moof" { assert_eq!(inspect_fragment(&atom), Ok(Inspection::NoExplicitProtectionSeen)); fragments += 1; }
                else { init.extend(atom); }
            }
            offset += len;
        }
        assert_eq!(inspect_init(&init), Ok(Inspection::NoExplicitProtectionSeen));
        assert!(fragments > 0);
        eprintln!("bounded_init_bytes={} inspected_fragments={fragments}; mdat skipped", init.len());
    }
}
