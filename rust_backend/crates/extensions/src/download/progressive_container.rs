//! Container-agnostic admission for the generic audio lease.
//!
//! The strict fMP4 door (`Fmp4Inspector`) only understands fragmented MP4. For
//! every other audio container the leading bytes already identify the format
//! and the payload can be served as it arrives, so this inspector sniffs a
//! signature once and then approves everything written. Formats that need
//! structure inspection (MP4/M4A) are delegated to the MP4 inspector, which
//! refuses `moov`-after-`mdat` files with a typed reason instead of stalling.
//! A signature is not proof of decodability: the player must still treat
//! decoder errors as a reason to fall back to a complete download.

#![allow(dead_code)]

use super::progressive_cenc::CencStream;
use super::progressive_fmp4_inspection::Fmp4Inspector;
use std::io;
use zeroize::Zeroizing;

/// Bytes needed to recognise every supported signature (RIFF....WAVE).
const SNIFF_LEN: u64 = 12;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Container { Mp3, Adts, Flac, Ogg, Wav, Mp4 }

/// Which inspection a progressive operation applies to staged bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InspectionKind { None, Fmp4, Audio }

pub(crate) enum Inspection { Fmp4(Fmp4Inspector), Audio(AudioInspector) }

pub(crate) struct AudioInspector {
    stage: Stage,
    reason: Option<&'static str>,
    /// Clave CENC aportada por el host para un MP4 protegido; se consume al
    /// reconocer el contenedor y solo vive despues en el cifrador.
    key: Option<Zeroizing<Vec<u8>>>,
}

enum Stage { Sniff, Direct(Container), Mp4(Fmp4Inspector), Cenc(Box<CencStream>) }

impl Inspection {
    pub(crate) fn new(kind: InspectionKind) -> Option<Self> {
        match kind {
            InspectionKind::None => None,
            InspectionKind::Fmp4 => Some(Self::Fmp4(Fmp4Inspector::default())),
            InspectionKind::Audio => Some(Self::Audio(AudioInspector::default())),
        }
    }

    pub(crate) fn advance(&mut self, written: u64, read: impl FnMut(u64, usize) -> io::Result<Vec<u8>>) -> Result<u64, ()> {
        match self {
            Self::Fmp4(inspector) => inspector.advance(written, read),
            Self::Audio(inspector) => inspector.advance(written, read),
        }
    }

    pub(crate) fn complete(&self, total: u64) -> bool {
        match self {
            Self::Fmp4(inspector) => inspector.complete(total),
            Self::Audio(inspector) => inspector.complete(total),
        }
    }

    /// Ofrece la clave CENC; solo la acepta la inspeccion de audio generico y
    /// antes de haber visto ningun byte.
    pub(crate) fn set_key(&mut self, key: Zeroizing<Vec<u8>>) -> bool {
        match self {
            Self::Audio(inspector) => inspector.set_key(key),
            Self::Fmp4(_) => false,
        }
    }

    /// Bytes en claro pendientes de publicar; `Some` solo si esta descifrando.
    pub(crate) fn take_clear(&mut self) -> Option<Vec<u8>> {
        match self {
            Self::Audio(inspector) => inspector.take_clear(),
            Self::Fmp4(_) => None,
        }
    }

    pub(crate) fn reason(&self) -> Option<&'static str> {
        match self {
            Self::Fmp4(inspector) => inspector.reason(),
            Self::Audio(inspector) => inspector.reason(),
        }
    }
}

impl Default for AudioInspector {
    fn default() -> Self { Self { stage: Stage::Sniff, reason: None, key: None } }
}

impl AudioInspector {
    pub(crate) fn container(&self) -> Option<Container> {
        match &self.stage { Stage::Sniff => None, Stage::Direct(kind) => Some(*kind), Stage::Mp4(_) | Stage::Cenc(_) => Some(Container::Mp4) }
    }

    pub(crate) fn reason(&self) -> Option<&'static str> {
        match &self.stage {
            Stage::Mp4(inspector) if self.reason.is_none() => inspector.reason(),
            Stage::Cenc(stream) if self.reason.is_none() => stream.reason(),
            _ => self.reason,
        }
    }

    pub(crate) fn set_key(&mut self, key: Zeroizing<Vec<u8>>) -> bool {
        if !matches!(self.stage, Stage::Sniff) { return false; }
        self.key = Some(key);
        true
    }

    pub(crate) fn take_clear(&mut self) -> Option<Vec<u8>> {
        match &mut self.stage { Stage::Cenc(stream) => Some(stream.take_output()), _ => None }
    }

    pub(crate) fn advance(&mut self, written: u64, mut read: impl FnMut(u64, usize) -> io::Result<Vec<u8>>) -> Result<u64, ()> {
        if matches!(self.stage, Stage::Sniff) {
            if written < SNIFF_LEN { return Ok(0); }
            let head = read(0, SNIFF_LEN as usize).map_err(|_| ())?;
            self.stage = match sniff(&head) {
                Some(Container::Mp4) => match self.key.take() {
                    Some(key) => match CencStream::new(&key) {
                        Ok(stream) => Stage::Cenc(Box::new(stream)),
                        Err(()) => { self.reason = Some("cenc_key_invalid"); return Err(()); }
                    },
                    None => Stage::Mp4(Fmp4Inspector::audio()),
                },
                Some(kind) => Stage::Direct(kind),
                None => { self.reason = Some("unrecognized_container"); return Err(()); }
            };
        }
        match &mut self.stage {
            Stage::Direct(_) => Ok(written),
            Stage::Mp4(inspector) => inspector.advance(written, &mut read),
            Stage::Cenc(stream) => stream.advance(written, &mut read),
            Stage::Sniff => Err(()),
        }
    }

    pub(crate) fn complete(&self, total: u64) -> bool {
        match &self.stage {
            Stage::Sniff => false,
            Stage::Direct(_) => total >= SNIFF_LEN,
            Stage::Mp4(inspector) => inspector.complete(total),
            Stage::Cenc(stream) => stream.complete(total),
        }
    }
}

/// Recognises a container from its first `SNIFF_LEN` bytes.
fn sniff(head: &[u8]) -> Option<Container> {
    if head.len() < SNIFF_LEN as usize { return None; }
    if head.starts_with(b"ID3") && (2..=4).contains(&head[3]) && head[6..10].iter().all(|b| b & 0x80 == 0) { return Some(Container::Mp3); }
    if head.starts_with(b"fLaC") { return Some(Container::Flac); }
    if head.starts_with(b"OggS") && head[4] == 0 { return Some(Container::Ogg); }
    if head.starts_with(b"RIFF") && &head[8..12] == b"WAVE" { return Some(Container::Wav); }
    if &head[4..8] == b"ftyp" { return Some(Container::Mp4); }
    if head[0] == 0xff && head[1] & 0xe0 == 0xe0 {
        let layer = head[1] >> 1 & 3;
        // ADTS: sync 0xFFF, layer 00. MPEG audio: layer 01..11, version != 01.
        if layer == 0 { return (head[1] & 0xf6 == 0xf0).then_some(Container::Adts); }
        let valid = head[1] >> 3 & 3 != 1 && head[2] >> 4 != 0xf && head[2] >> 2 & 3 != 3;
        return valid.then_some(Container::Mp3);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(data: &[u8], steps: &[u64]) -> (Vec<Result<u64, ()>>, AudioInspector) {
        let mut inspector = AudioInspector::default();
        let mut read = |offset: u64, len: usize| Ok(data[offset as usize..offset as usize + len].to_vec());
        let results = steps.iter().map(|written| inspector.advance(*written, &mut read)).collect();
        (results, inspector)
    }

    fn atom(name: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut result = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        result.extend_from_slice(name); result.extend_from_slice(payload); result
    }

    fn aac_moov() -> Vec<u8> {
        let mut entry = vec![0; 28]; entry.extend(atom(b"esds", &[0; 4]));
        let mut stsd = vec![0; 4]; stsd.extend_from_slice(&1u32.to_be_bytes()); stsd.extend(atom(b"mp4a", &entry));
        atom(b"moov", &atom(b"trak", &atom(b"mdia", &atom(b"minf", &atom(b"stbl", &atom(b"stsd", &stsd))))))
    }

    fn padded(head: &[u8]) -> Vec<u8> { let mut v = head.to_vec(); v.extend([0u8; 60]); v }

    #[test]
    fn direct_containers_stream_every_written_byte_after_the_signature() {
        let fixtures = [
            (padded(&[0xff, 0xfb, 0x90, 0x64]), Container::Mp3),
            (padded(b"ID3\x04\0\0\0\0\0\x10"), Container::Mp3),
            (padded(b"fLaC"), Container::Flac),
            (padded(b"OggS\0\x02"), Container::Ogg),
            (padded(b"RIFF\x24\0\0\0WAVEfmt "), Container::Wav),
            (padded(&[0xff, 0xf1, 0x50, 0x80]), Container::Adts),
        ];
        for (data, kind) in fixtures {
            let (results, inspector) = run(&data, &[5, 11, 12, 40, 64]);
            assert_eq!(results, vec![Ok(0), Ok(0), Ok(12), Ok(40), Ok(64)], "{kind:?}");
            assert_eq!(inspector.container(), Some(kind));
            assert!(inspector.complete(64));
            assert!(!AudioInspector::default().complete(64));
        }
    }

    #[test]
    fn unknown_or_malformed_signatures_are_rejected_with_a_reason() {
        let rejected = [
            padded(&[0x1a, 0x45, 0xdf, 0xa3]),
            vec![0; 64],
            b"hello world, not audio at all".to_vec(),
            padded(&[0xff, 0xeb, 0x90, 0x64]),
            padded(&[0xff, 0xfb, 0xf0, 0x64]),
        ];
        for data in rejected {
            let (results, inspector) = run(&data, &[data.len() as u64]);
            assert_eq!(results, vec![Err(())]);
            assert_eq!(inspector.reason(), Some("unrecognized_container"));
        }
    }

    #[test]
    fn short_files_never_complete_and_cannot_be_published_as_audio() {
        let (results, inspector) = run(b"fLaC\0\0", &[6]);
        assert_eq!(results, vec![Ok(0)]);
        assert!(!inspector.complete(6));
    }

    #[test]
    fn progressive_m4a_with_leading_moov_streams_the_media_payload() {
        let mut file = atom(b"ftyp", b"M4A \0\0\0\0M4A isom"); file.extend(aac_moov());
        let header_end = file.len() as u64;
        file.extend(atom(b"mdat", &vec![0x55; 4096]));
        let total = file.len() as u64;
        let (results, inspector) = run(&file, &[header_end, header_end + 8 + 100, total]);
        assert_eq!(results, vec![Ok(header_end), Ok(header_end + 8 + 100), Ok(total)]);
        assert_eq!(inspector.container(), Some(Container::Mp4));
        assert!(inspector.complete(total));
        assert!(!inspector.complete(total - 1));
    }

    #[test]
    fn m4a_with_moov_after_media_is_rejected_with_a_typed_reason() {
        let mut file = atom(b"ftyp", b"M4A \0\0\0\0M4A isom");
        file.extend(atom(b"mdat", &vec![0x55; 4096])); file.extend(aac_moov());
        let (results, inspector) = run(&file, &[file.len() as u64]);
        assert_eq!(results, vec![Err(())]);
        assert_eq!(inspector.reason(), Some("metadata_after_media"));
    }

    #[test]
    fn protected_m4a_is_rejected_even_when_moov_comes_first() {
        let mut entry = vec![0; 28]; entry.extend(atom(b"sinf", &[]));
        let mut stsd = vec![0; 4]; stsd.extend_from_slice(&1u32.to_be_bytes()); stsd.extend(atom(b"mp4a", &entry));
        let moov = atom(b"moov", &atom(b"trak", &atom(b"mdia", &atom(b"minf", &atom(b"stbl", &atom(b"stsd", &stsd))))));
        let mut file = atom(b"ftyp", b"M4A \0\0\0\0M4A isom"); file.extend(moov); file.extend(atom(b"mdat", &[1; 64]));
        let (results, inspector) = run(&file, &[file.len() as u64]);
        assert_eq!(results, vec![Err(())]);
        assert_eq!(inspector.reason(), Some("protected_media"));
    }

    #[test]
    fn strict_fmp4_inspector_still_rejects_classic_mp4() {
        let mut file = atom(b"ftyp", b"isom\0\0\0\0"); file.extend(aac_moov()); file.extend(atom(b"mdat", &vec![0; 4096]));
        let mut strict = Fmp4Inspector::default();
        let mut read = |offset: u64, len: usize| Ok(file[offset as usize..offset as usize + len].to_vec());
        assert_eq!(strict.advance(file.len() as u64, &mut read), Err(()));
    }
}
