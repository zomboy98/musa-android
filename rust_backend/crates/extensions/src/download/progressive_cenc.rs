//! Descifrado al vuelo de MP4 fragmentado con cifrado comun `cenc` (AES-128-CTR).
//!
//! Es el equivalente en streaming del descifrado final con `-decryption_key`:
//! a medida que llegan bytes se parsean las cajas ISO-BMFF y solo se produce el
//! prefijo contiguo YA descifrado. La salida tiene exactamente la misma longitud
//! que la entrada (se neutralizan cajas cambiando su tipo en el sitio), de modo
//! que tamanos y desplazamientos (`sidx`, `trun`, `Content-Length`) siguen siendo
//! validos:
//!
//! * `moov`: la entrada de muestras `enca` recupera su formato original (`frma`),
//!   `sinf` y `pssh` pasan a `free`.
//! * `moof`: `senc`, `saiz`, `saio` y `pssh` pasan a `free`.
//! * `mdat`: cada muestra protegida se descifra con AES-CTR (IV por muestra o
//!   constante, con o sin subsamples); el resto pasa sin cambios.
//!
//! Todo lo que no se pueda descifrar con certeza aborta con un motivo estable
//! (nunca se entrega texto cifrado ni bytes dudosos): esquemas distintos de
//! `cenc` (`cens`, `cbc1`, `cbcs`), `moov` despues de los medios, MP4 clasico no
//! fragmentado, varios `traf`, grupos de muestras `seig`, `uuid` en fragmentos,
//! pistas no de audio, clave rechazada por la comprobacion de cabecera FLAC o
//! cajas mal formadas. La clave solo vive en el cifrador (`aes` con `zeroize`);
//! este modulo no registra ni expone claves, rutas ni medios.

#![allow(dead_code)]

use aes::cipher::{Block, BlockCipherEncrypt, KeyInit};
use std::collections::VecDeque;
use std::io;

type Reason = &'static str;

const MAX_META: u64 = 1024 * 1024;
const MAX_SAMPLE: u64 = 8 * 1024 * 1024;
const MAX_SAMPLES: u64 = 200_000;
const MAX_BOXES: usize = 8192;
const COPY_CHUNK: u64 = 64 * 1024;
const READ_CHUNK: u64 = 128 * 1024;
const FREE: [u8; 4] = *b"free";

const R_MALFORMED: Reason = "cenc_malformed";
const R_LAYOUT: Reason = "cenc_unsupported_layout";
const R_SCHEME: Reason = "cenc_unsupported_scheme";
const R_IO: Reason = "cenc_io";

#[derive(Clone, Copy)]
struct BoxRef {
    kind: [u8; 4],
    start: usize,
    header: usize,
    end: usize,
}

impl BoxRef {
    fn payload(&self) -> usize { self.start + self.header }
}

fn be16(data: &[u8], at: usize) -> Result<u16, Reason> {
    Ok(u16::from_be_bytes(data.get(at..at + 2).ok_or(R_MALFORMED)?.try_into().unwrap()))
}
fn be32(data: &[u8], at: usize) -> Result<u32, Reason> {
    Ok(u32::from_be_bytes(data.get(at..at + 4).ok_or(R_MALFORMED)?.try_into().unwrap()))
}
fn be64(data: &[u8], at: usize) -> Result<u64, Reason> {
    Ok(u64::from_be_bytes(data.get(at..at + 8).ok_or(R_MALFORMED)?.try_into().unwrap()))
}
fn quad(data: &[u8], at: usize) -> Result<[u8; 4], Reason> {
    Ok(data.get(at..at + 4).ok_or(R_MALFORMED)?.try_into().unwrap())
}

/// Hijos directos de `[from, to)`; valida que cada caja quepa en su padre.
fn children(data: &[u8], from: usize, to: usize, budget: &mut usize) -> Result<Vec<BoxRef>, Reason> {
    let mut out = Vec::new();
    let mut at = from;
    while at < to {
        if to - at < 8 { return Err(R_MALFORMED); }
        if *budget == 0 { return Err(R_LAYOUT); }
        *budget -= 1;
        let short = u64::from(be32(data, at)?);
        let kind = quad(data, at + 4)?;
        let (header, size) = match short {
            0 => (8usize, (to - at) as u64),
            1 => { if to - at < 16 { return Err(R_MALFORMED); } (16usize, be64(data, at + 8)?) }
            n => (8usize, n),
        };
        if size < header as u64 || size > (to - at) as u64 { return Err(R_MALFORMED); }
        out.push(BoxRef { kind, start: at, header, end: at + size as usize });
        at += size as usize;
    }
    Ok(out)
}

fn child(data: &[u8], parent: &BoxRef, kind: &[u8; 4], budget: &mut usize) -> Result<Option<BoxRef>, Reason> {
    Ok(children(data, parent.payload(), parent.end, budget)?.into_iter().find(|b| &b.kind == kind))
}

#[derive(Clone)]
struct Track {
    id: u32,
    protected: bool,
    iv_size: u8,
    constant_iv: Option<[u8; 16]>,
    flac: bool,
    default_size: u32,
}

struct Sample {
    offset: u64,
    size: u32,
    iv: [u8; 16],
    subsamples: Vec<(u16, u32)>,
    flac: bool,
}

#[derive(Clone, Copy)]
enum Phase { Header, Passthrough { end: u64 }, Payload { end: u64 } }

pub(crate) struct CencStream {
    cipher: aes::Aes128,
    pos: u64,
    phase: Phase,
    tracks: Vec<Track>,
    moov_seen: bool,
    pending_moof: bool,
    /// MP4 no fragmentado: el plan de muestras sale del moov.
    classic: bool,
    fragments: u32,
    samples: VecDeque<Sample>,
    out: Vec<u8>,
    reason: Option<Reason>,
}

impl CencStream {
    /// Solo claves AES-128 (16 bytes), como el descriptor `ffmpeg.mov_key`.
    pub(crate) fn new(key: &[u8]) -> Result<Self, ()> {
        if key.len() != 16 { return Err(()); }
        let cipher = aes::Aes128::new_from_slice(key).map_err(|_| ())?;
        Ok(Self {
            cipher, pos: 0, phase: Phase::Header, tracks: Vec::new(), moov_seen: false, pending_moof: false, classic: false,
            fragments: 0, samples: VecDeque::new(), out: Vec::new(), reason: None,
        })
    }

    pub(crate) fn reason(&self) -> Option<&'static str> { self.reason }

    /// Bytes en claro producidos desde la ultima llamada; siempre empiezan donde
    /// termino la salida anterior (la salida es contigua desde el byte 0).
    pub(crate) fn take_output(&mut self) -> Vec<u8> { std::mem::take(&mut self.out) }

    pub(crate) fn complete(&self, total: u64) -> bool {
        matches!(self.phase, Phase::Header) && !self.pending_moof && self.fragments > 0 && self.samples.is_empty() && self.pos == total
    }

    /// `written` es el prefijo contiguo ya escrito del archivo cifrado. Devuelve
    /// el prefijo en claro disponible (siempre == bytes consumidos). Ante cualquier
    /// duda aborta y descarta la salida pendiente.
    pub(crate) fn advance(&mut self, written: u64, mut read: impl FnMut(u64, usize) -> io::Result<Vec<u8>>) -> Result<u64, ()> {
        if written < self.pos { self.reason = Some(R_MALFORMED); self.out.clear(); return Err(()); }
        match self.step(written, &mut read) {
            Ok(()) => Ok(self.pos),
            Err(reason) => { self.reason = Some(reason); self.out.clear(); Err(()) }
        }
    }

    fn step(&mut self, written: u64, read: &mut impl FnMut(u64, usize) -> io::Result<Vec<u8>>) -> Result<(), Reason> {
        loop {
            match self.phase {
                Phase::Passthrough { end } => {
                    let limit = written.min(end);
                    self.copy(limit, read)?;
                    if self.pos == end { self.phase = Phase::Header; continue; }
                    return Ok(());
                }
                Phase::Payload { end } => {
                    if self.payload(written, end, read)? { self.phase = Phase::Header; continue; }
                    return Ok(());
                }
                Phase::Header => {
                    if !self.header(written, read)? { return Ok(()); }
                }
            }
        }
    }

    /// Copia `[pos, limit)` sin cambios, en trozos acotados.
    fn copy(&mut self, limit: u64, read: &mut impl FnMut(u64, usize) -> io::Result<Vec<u8>>) -> Result<(), Reason> {
        while self.pos < limit {
            let count = (limit - self.pos).min(COPY_CHUNK) as usize;
            let chunk = read(self.pos, count).map_err(|_| R_IO)?;
            if chunk.len() != count { return Err(R_IO); }
            self.out.extend_from_slice(&chunk);
            self.pos += count as u64;
        }
        Ok(())
    }

    fn read_box(&self, size: u64, read: &mut impl FnMut(u64, usize) -> io::Result<Vec<u8>>) -> Result<Vec<u8>, Reason> {
        let mut data = Vec::with_capacity(size as usize);
        let mut done = 0u64;
        while done < size {
            let count = (size - done).min(READ_CHUNK) as usize;
            let chunk = read(self.pos + done, count).map_err(|_| R_IO)?;
            if chunk.len() != count { return Err(R_IO); }
            data.extend_from_slice(&chunk);
            done += count as u64;
        }
        Ok(data)
    }

    /// Devuelve `false` si faltan bytes para decidir.
    fn header(&mut self, written: u64, read: &mut impl FnMut(u64, usize) -> io::Result<Vec<u8>>) -> Result<bool, Reason> {
        let available = written - self.pos;
        if available < 8 { return Ok(false); }
        let head = read(self.pos, 8).map_err(|_| R_IO)?;
        if head.len() != 8 { return Err(R_IO); }
        let short = u64::from(be32(&head, 0)?);
        let kind: [u8; 4] = head[4..8].try_into().unwrap();
        let (header_len, size) = match short {
            0 => return Err(R_LAYOUT),
            1 => {
                if available < 16 { return Ok(false); }
                let extra = read(self.pos + 8, 8).map_err(|_| R_IO)?;
                if extra.len() != 8 { return Err(R_IO); }
                (16u64, u64::from_be_bytes(extra.try_into().unwrap()))
            }
            n => (8u64, n),
        };
        if size < header_len { return Err(R_MALFORMED); }
        let end = self.pos.checked_add(size).ok_or(R_MALFORMED)?;
        match &kind {
            b"moov" => {
                if self.moov_seen || self.fragments > 0 { return Err(R_LAYOUT); }
                if size > MAX_META { return Err("metadata_too_large"); }
                if written < end { return Ok(false); }
                let mut data = self.read_box(size, read)?;
                let (tracks, classic) = scan_moov(&mut data, self.pos)?;
                self.tracks = tracks;
                if let Some(plan) = classic { self.samples = plan; self.classic = true; }
                self.out.extend_from_slice(&data);
                self.pos = end;
                self.moov_seen = true;
            }
            b"moof" => {
                if !self.moov_seen || self.pending_moof || self.classic { return Err(R_LAYOUT); }
                if size > MAX_META { return Err("metadata_too_large"); }
                if written < end { return Ok(false); }
                let mut data = self.read_box(size, read)?;
                self.samples = scan_moof(&mut data, self.pos, &self.tracks)?;
                self.out.extend_from_slice(&data);
                self.pos = end;
                self.pending_moof = true;
            }
            b"mdat" => {
                // Datos antes que su metadato: moov al final, MP4 clasico o mdat suelto.
                if !self.moov_seen { return Err("metadata_after_media"); }
                if !self.pending_moof && !self.classic { return Err(R_LAYOUT); }
                let payload_start = self.pos + header_len;
                let mut cursor = payload_start;
                for sample in &self.samples {
                    // Clasico: las muestras de un mdat posterior se validan al llegar a el.
                    if self.classic && sample.offset >= end { break; }
                    if sample.offset < cursor || sample.offset + u64::from(sample.size) > end { return Err(R_MALFORMED); }
                    cursor = sample.offset + u64::from(sample.size);
                }
                let header = read(self.pos, header_len as usize).map_err(|_| R_IO)?;
                if header.len() != header_len as usize { return Err(R_IO); }
                self.out.extend_from_slice(&header);
                self.pos = payload_start;
                self.pending_moof = false;
                self.fragments += 1;
                self.phase = Phase::Payload { end };
            }
            _ => {
                if !self.moov_seen && !matches!(&kind, b"ftyp" | b"styp" | b"free" | b"skip") { return Err(R_LAYOUT); }
                if self.pending_moof { return Err(R_LAYOUT); }
                self.phase = Phase::Passthrough { end };
            }
        }
        Ok(true)
    }

    /// Devuelve `true` cuando el `mdat` termino.
    fn payload(&mut self, written: u64, end: u64, read: &mut impl FnMut(u64, usize) -> io::Result<Vec<u8>>) -> Result<bool, Reason> {
        let limit = written.min(end);
        loop {
            if self.pos == end { return Ok(true); }
            match self.samples.front() {
                Some(sample) => {
                    let (offset, size) = (sample.offset, u64::from(sample.size));
                    if self.pos < offset {
                        let upto = limit.min(offset);
                        if upto == self.pos { return Ok(false); }
                        self.copy(upto, read)?;
                        continue;
                    }
                    // pos == offset (validado al abrir el mdat)
                    if limit < offset + size { return Ok(false); }
                    if size > MAX_SAMPLE { return Err(R_LAYOUT); }
                    let mut data = Vec::with_capacity(size as usize);
                    let mut done = 0u64;
                    while done < size {
                        let count = (size - done).min(READ_CHUNK) as usize;
                        let chunk = read(offset + done, count).map_err(|_| R_IO)?;
                        if chunk.len() != count { return Err(R_IO); }
                        data.extend_from_slice(&chunk);
                        done += count as u64;
                    }
                    let sample = self.samples.pop_front().expect("front sample");
                    self.decrypt(&sample, &mut data)?;
                    self.out.extend_from_slice(&data);
                    self.pos = offset + size;
                }
                None => {
                    self.copy(limit, read)?;
                    return Ok(self.pos == end);
                }
            }
        }
    }

    fn decrypt(&self, sample: &Sample, data: &mut [u8]) -> Result<(), Reason> {
        let mut counter = sample.iv;
        let mut keystream = [0u8; 16];
        let mut used = 16usize;
        let mut apply = |bytes: &mut [u8]| {
            for byte in bytes {
                if used == 16 {
                    let mut block = Block::<aes::Aes128>::try_from(&counter[..]).expect("16-byte block");
                    self.cipher.encrypt_block(&mut block);
                    for (slot, value) in keystream.iter_mut().zip(block.iter()) { *slot = *value; }
                    // Mismo contador que ffmpeg: 64 bits bajos, big-endian, sin acarreo al IV.
                    for index in (8..16).rev() {
                        counter[index] = counter[index].wrapping_add(1);
                        if counter[index] != 0 { break; }
                    }
                    used = 0;
                }
                *byte ^= keystream[used];
                used += 1;
            }
        };
        if sample.subsamples.is_empty() {
            apply(data);
        } else {
            let mut at = 0usize;
            for (clear, protected) in &sample.subsamples {
                at = at.checked_add(usize::from(*clear)).ok_or(R_MALFORMED)?;
                let stop = at.checked_add(*protected as usize).ok_or(R_MALFORMED)?;
                apply(data.get_mut(at..stop).ok_or(R_MALFORMED)?);
                at = stop;
            }
        }
        // Un fotograma FLAC empieza siempre por el sincronismo 0xFFF8/0xFFF9; una
        // clave equivocada produce ruido y no debe llegar al reproductor.
        if sample.flac && !data.is_empty() && !(data.len() >= 2 && data[0] == 0xff && data[1] & 0xfe == 0xf8) {
            return Err("cenc_key_rejected");
        }
        Ok(())
    }
}

/// Analiza el `moov`, lo neutraliza en el sitio y devuelve las pistas.
fn scan_moov(data: &mut Vec<u8>, moov_start: u64) -> Result<(Vec<Track>, Option<VecDeque<Sample>>), Reason> {
    let mut budget = MAX_BOXES;
    let top = children(data, 0, data.len(), &mut budget)?;
    let moov = *top.iter().find(|b| &b.kind == b"moov").ok_or(R_MALFORMED)?;
    let mut patches: Vec<(usize, [u8; 4])> = Vec::new();
    let mut tracks = Vec::new();
    let mut stbls = Vec::new();
    let mut trex: Vec<(u32, u32)> = Vec::new();
    let mut fragmented = false;
    for item in children(data, moov.payload(), moov.end, &mut budget)? {
        match &item.kind {
            b"trak" => {
                let (track, stbl) = scan_trak(data, &item, &mut budget, &mut patches)?;
                tracks.push(track);
                stbls.push(stbl);
            }
            b"mvex" => {
                fragmented = true;
                for entry in children(data, item.payload(), item.end, &mut budget)? {
                    if &entry.kind == b"trex" {
                        let p = entry.payload();
                        trex.push((be32(data, p + 4)?, be32(data, p + 16)?));
                    }
                }
            }
            b"pssh" => patches.push((item.start + 4, FREE)),
            _ => {}
        }
    }
    if tracks.is_empty() { return Err(R_LAYOUT); }
    for track in &mut tracks {
        if let Some((_, size)) = trex.iter().find(|(id, _)| *id == track.id) { track.default_size = *size; }
    }
    if !tracks.iter().any(|t| t.protected) { return Err("cenc_not_protected"); }
    // MP4 clasico (sin mvex): el moov ya trae las tablas de muestras y la
    // informacion de IV, asi que el plan completo se calcula aqui. Solo una pista.
    let mut classic = None;
    if !fragmented {
        if tracks.len() != 1 { return Err(R_LAYOUT); }
        classic = Some(classic_samples(data, &stbls[0], &tracks[0], moov_start, &mut budget, &mut patches)?);
    }
    for (offset, kind) in patches { data[offset..offset + 4].copy_from_slice(&kind); }
    Ok((tracks, classic))
}

fn scan_trak(data: &[u8], trak: &BoxRef, budget: &mut usize, patches: &mut Vec<(usize, [u8; 4])>) -> Result<(Track, BoxRef), Reason> {
    let tkhd = child(data, trak, b"tkhd", budget)?.ok_or(R_MALFORMED)?;
    let version = *data.get(tkhd.payload()).ok_or(R_MALFORMED)?;
    let id = be32(data, tkhd.payload() + if version == 1 { 20 } else { 12 })?;
    let mdia = child(data, trak, b"mdia", budget)?.ok_or(R_MALFORMED)?;
    let hdlr = child(data, &mdia, b"hdlr", budget)?.ok_or(R_MALFORMED)?;
    if &quad(data, hdlr.payload() + 8)? != b"soun" { return Err(R_LAYOUT); }
    let minf = child(data, &mdia, b"minf", budget)?.ok_or(R_MALFORMED)?;
    let stbl = child(data, &minf, b"stbl", budget)?.ok_or(R_MALFORMED)?;
    let stsd = child(data, &stbl, b"stsd", budget)?.ok_or(R_MALFORMED)?;
    let p = stsd.payload();
    if be32(data, p + 4)? != 1 { return Err(R_LAYOUT); }
    let entries = children(data, p + 8, stsd.end, budget)?;
    let entry = *entries.first().ok_or(R_MALFORMED)?;
    let mut track = Track { id, protected: false, iv_size: 0, constant_iv: None, flac: &entry.kind == b"fLaC", default_size: 0 };
    match &entry.kind {
        b"encv" => return Err(R_LAYOUT),
        b"enca" => {}
        _ => return Ok((track, stbl)),
    }
    let ep = entry.payload();
    let ext = match be16(data, ep + 8)? { 0 => 0usize, 1 => 16, 2 => 36, _ => return Err(R_LAYOUT) };
    let inner = children(data, ep + 28 + ext, entry.end, budget)?;
    let sinf = *inner.iter().find(|b| &b.kind == b"sinf").ok_or(R_LAYOUT)?;
    let parts = children(data, sinf.payload(), sinf.end, budget)?;
    let frma = parts.iter().find(|b| &b.kind == b"frma").ok_or(R_LAYOUT)?;
    let original = quad(data, frma.payload())?;
    let schm = parts.iter().find(|b| &b.kind == b"schm").ok_or(R_LAYOUT)?;
    if &quad(data, schm.payload() + 4)? != b"cenc" { return Err(R_SCHEME); }
    let schi = parts.iter().find(|b| &b.kind == b"schi").ok_or(R_LAYOUT)?;
    let tenc = children(data, schi.payload(), schi.end, budget)?.into_iter().find(|b| &b.kind == b"tenc").ok_or(R_LAYOUT)?;
    let t = tenc.payload();
    if tenc.end < t + 24 { return Err(R_MALFORMED); }
    // Con version >= 1 el byte siguiente es el patron crypt/skip: `cenc` no lo usa.
    if data[t] >= 1 && data[t + 5] != 0 { return Err(R_SCHEME); }
    let is_protected = data[t + 6];
    let iv_size = data[t + 7];
    match is_protected {
        0 => track.protected = false,
        1 => {
            track.protected = true;
            match iv_size {
                8 | 16 => track.iv_size = iv_size,
                0 => {
                    let constant = usize::from(*data.get(t + 24).ok_or(R_MALFORMED)?);
                    if !matches!(constant, 8 | 16) || tenc.end < t + 25 + constant { return Err(R_MALFORMED); }
                    let mut iv = [0u8; 16];
                    iv[..constant].copy_from_slice(&data[t + 25..t + 25 + constant]);
                    track.constant_iv = Some(iv);
                }
                _ => return Err(R_LAYOUT),
            }
        }
        _ => return Err(R_MALFORMED),
    }
    track.flac = original == *b"fLaC";
    patches.push((entry.start + 4, original));
    patches.push((sinf.start + 4, FREE));
    Ok((track, stbl))
}

fn scan_moof(data: &mut Vec<u8>, moof_start: u64, tracks: &[Track]) -> Result<VecDeque<Sample>, Reason> {
    let mut budget = MAX_BOXES;
    let top = children(data, 0, data.len(), &mut budget)?;
    let moof = *top.iter().find(|b| &b.kind == b"moof").ok_or(R_MALFORMED)?;
    let mut patches: Vec<(usize, [u8; 4])> = Vec::new();
    let mut samples = None;
    for item in children(data, moof.payload(), moof.end, &mut budget)? {
        match &item.kind {
            b"traf" => {
                if samples.is_some() { return Err(R_LAYOUT); }
                samples = Some(scan_traf(data, &item, moof_start, tracks, &mut budget, &mut patches)?);
            }
            b"pssh" => patches.push((item.start + 4, FREE)),
            _ => {}
        }
    }
    let samples = samples.ok_or(R_LAYOUT)?;
    for (offset, kind) in patches { data[offset..offset + 4].copy_from_slice(&kind); }
    Ok(samples)
}

fn scan_traf(
    data: &[u8], traf: &BoxRef, moof_start: u64, tracks: &[Track], budget: &mut usize,
    patches: &mut Vec<(usize, [u8; 4])>,
) -> Result<VecDeque<Sample>, Reason> {
    let mut tfhd = None;
    let mut truns = Vec::new();
    let mut senc = None;
    for item in children(data, traf.payload(), traf.end, budget)? {
        match &item.kind {
            b"tfhd" => { if tfhd.is_some() { return Err(R_LAYOUT); } tfhd = Some(item); }
            b"trun" => truns.push(item),
            b"senc" => {
                if senc.is_some() { return Err(R_LAYOUT); }
                senc = Some(item);
                patches.push((item.start + 4, FREE));
            }
            b"saiz" | b"saio" => patches.push((item.start + 4, FREE)),
            b"sbgp" | b"sgpd" => { if &quad(data, item.payload() + 4)? == b"seig" { return Err(R_LAYOUT); } }
            b"uuid" => return Err(R_LAYOUT),
            _ => {}
        }
    }
    let tfhd = tfhd.ok_or(R_MALFORMED)?;
    let p = tfhd.payload();
    let flags = be32(data, p)? & 0x00ff_ffff;
    let id = be32(data, p + 4)?;
    let mut cursor = p + 8;
    let mut base = moof_start;
    if flags & 0x1 != 0 { base = be64(data, cursor)?; cursor += 8; }
    if flags & 0x2 != 0 { cursor += 4; }
    if flags & 0x8 != 0 { cursor += 4; }
    let tfhd_size = if flags & 0x10 != 0 { Some(be32(data, cursor)?) } else { None };
    let track = tracks.iter().find(|t| t.id == id).ok_or(R_LAYOUT)?;
    if !track.protected { return Ok(VecDeque::new()); }
    let default_size = tfhd_size.or((track.default_size != 0).then_some(track.default_size));

    let mut layout: Vec<(u64, u32)> = Vec::new();
    let mut next = base;
    for (index, trun) in truns.iter().enumerate() {
        let q = trun.payload();
        let flags = be32(data, q)? & 0x00ff_ffff;
        let count = u64::from(be32(data, q + 4)?);
        if layout.len() as u64 + count > MAX_SAMPLES { return Err(R_LAYOUT); }
        let mut at = q + 8;
        if flags & 0x1 != 0 {
            let offset = i64::from(be32(data, at)? as i32);
            at += 4;
            next = u64::try_from(base as i64 + offset).map_err(|_| R_MALFORMED)?;
        } else if index == 0 {
            next = base;
        }
        if flags & 0x4 != 0 { at += 4; }
        for _ in 0..count {
            if flags & 0x100 != 0 { at += 4; }
            let size = if flags & 0x200 != 0 { let v = be32(data, at)?; at += 4; v } else { default_size.ok_or(R_LAYOUT)? };
            if flags & 0x400 != 0 { at += 4; }
            if flags & 0x800 != 0 { at += 4; }
            layout.push((next, size));
            next = next.checked_add(u64::from(size)).ok_or(R_MALFORMED)?;
        }
        if at > trun.end { return Err(R_MALFORMED); }
    }

    let constant = |track: &Track| -> Result<[u8; 16], Reason> { track.constant_iv.ok_or(R_LAYOUT) };
    let mut samples = VecDeque::with_capacity(layout.len());
    match senc {
        None => {
            // Sin `senc` solo es valido con IV constante y toda la muestra cifrada.
            let iv = constant(track)?;
            for (offset, size) in layout { samples.push_back(Sample { offset, size, iv, subsamples: Vec::new(), flac: track.flac }); }
        }
        Some(senc) => {
            let q = senc.payload();
            let flags = be32(data, q)? & 0x00ff_ffff;
            // El bit 0 (override de parametros de pista) no es `cenc` estandar.
            if flags & 0x1 != 0 { return Err(R_LAYOUT); }
            let count = u64::from(be32(data, q + 4)?);
            if count != layout.len() as u64 { return Err(R_MALFORMED); }
            let mut at = q + 8;
            for (offset, size) in layout {
                let iv = if track.iv_size > 0 {
                    let size = usize::from(track.iv_size);
                    let mut iv = [0u8; 16];
                    iv[..size].copy_from_slice(data.get(at..at + size).ok_or(R_MALFORMED)?);
                    at += size;
                    iv
                } else { constant(track)? };
                let mut subsamples = Vec::new();
                if flags & 0x2 != 0 {
                    let n = usize::from(be16(data, at)?);
                    at += 2;
                    let mut sum = 0u64;
                    for _ in 0..n {
                        let clear = be16(data, at)?;
                        let protected = be32(data, at + 2)?;
                        at += 6;
                        sum += u64::from(clear) + u64::from(protected);
                        subsamples.push((clear, protected));
                    }
                    if sum != u64::from(size) { return Err(R_MALFORMED); }
                }
                samples.push_back(Sample { offset, size, iv, subsamples, flac: track.flac });
            }
            if at != senc.end { return Err(R_MALFORMED); }
        }
    }
    Ok(samples)
}

struct Entry {
    iv: [u8; 16],
    subs: Vec<(u16, u32)>,
}

/// Tablas de muestras de un MP4 clasico: `(offset absoluto, tamano)` en orden de archivo.
fn classic_samples(
    data: &[u8], stbl: &BoxRef, track: &Track, moov_start: u64, budget: &mut usize,
    patches: &mut Vec<(usize, [u8; 4])>,
) -> Result<VecDeque<Sample>, Reason> {
    let (mut stsz, mut stsc, mut chunks, mut senc, mut saiz, mut saio) = (None, None, None, None, None, None);
    for item in children(data, stbl.payload(), stbl.end, budget)? {
        match &item.kind {
            b"stsz" => stsz = Some(item),
            b"stsc" => stsc = Some(item),
            b"stco" | b"co64" => chunks = Some(item),
            b"senc" => { senc = Some(item); patches.push((item.start + 4, FREE)); }
            b"saiz" => { saiz = Some(item); patches.push((item.start + 4, FREE)); }
            b"saio" => { saio = Some(item); patches.push((item.start + 4, FREE)); }
            b"sbgp" | b"sgpd" => { if &quad(data, item.payload() + 4)? == b"seig" { return Err(R_LAYOUT); } }
            b"uuid" => return Err(R_LAYOUT),
            _ => {}
        }
    }
    let (stsz, stsc, chunks) = (stsz.ok_or(R_LAYOUT)?, stsc.ok_or(R_LAYOUT)?, chunks.ok_or(R_LAYOUT)?);
    // Tamanos
    let p = stsz.payload();
    let fixed = be32(data, p + 4)?;
    let count = u64::from(be32(data, p + 8)?);
    if count > MAX_SAMPLES { return Err(R_LAYOUT); }
    let mut sizes = Vec::with_capacity(count as usize);
    for i in 0..count as usize {
        sizes.push(if fixed != 0 { fixed } else { be32(data, p + 12 + 4 * i)? });
    }
    // Muestras por trozo
    let q = stsc.payload();
    let runs = be32(data, q + 4)? as usize;
    if runs == 0 || runs > 100_000 { return Err(R_LAYOUT); }
    let mut table = Vec::with_capacity(runs);
    for i in 0..runs {
        let at = q + 8 + 12 * i;
        table.push((be32(data, at)?, be32(data, at + 4)?));
    }
    // Desplazamientos de trozo
    let wide = &chunks.kind == b"co64";
    let r = chunks.payload();
    let chunk_count = be32(data, r + 4)? as usize;
    if chunk_count == 0 || chunk_count > 1_000_000 { return Err(R_LAYOUT); }
    let mut layout: Vec<(u64, u32)> = Vec::with_capacity(sizes.len());
    let mut next_size = 0usize;
    let mut run = 0usize;
    for chunk in 0..chunk_count {
        let offset = if wide { be64(data, r + 8 + 8 * chunk)? } else { u64::from(be32(data, r + 8 + 4 * chunk)?) };
        while run + 1 < table.len() && table[run + 1].0 as usize <= chunk + 1 { run += 1; }
        if (table[run].0 as usize) > chunk + 1 { return Err(R_MALFORMED); }
        let mut cursor = offset;
        for _ in 0..table[run].1 {
            let size = *sizes.get(next_size).ok_or(R_MALFORMED)?;
            next_size += 1;
            layout.push((cursor, size));
            cursor = cursor.checked_add(u64::from(size)).ok_or(R_MALFORMED)?;
        }
    }
    if next_size != sizes.len() { return Err(R_MALFORMED); }
    // Para descifrar en orden de llegada las muestras no pueden solaparse ni retroceder.
    for pair in layout.windows(2) {
        if pair[1].0 < pair[0].0 + u64::from(pair[0].1) { return Err(R_LAYOUT); }
    }
    let entries = match (senc, saiz, saio) {
        (Some(senc), _, _) => Some(senc_entries(data, &senc, track, layout.len() as u64)?),
        (None, Some(saiz), Some(saio)) => Some(aux_entries(data, &saiz, &saio, track, moov_start, layout.len())?),
        (None, None, None) => None,
        _ => return Err(R_LAYOUT),
    };
    let mut samples = VecDeque::with_capacity(layout.len());
    match entries {
        None => {
            let iv = track.constant_iv.ok_or(R_LAYOUT)?;
            for (offset, size) in layout { samples.push_back(Sample { offset, size, iv, subsamples: Vec::new(), flac: track.flac }); }
        }
        Some(entries) => {
            if entries.len() != layout.len() { return Err(R_MALFORMED); }
            for ((offset, size), entry) in layout.into_iter().zip(entries) {
                if !entry.subs.is_empty() {
                    let sum: u64 = entry.subs.iter().map(|(c, e)| u64::from(*c) + u64::from(*e)).sum();
                    if sum != u64::from(size) { return Err(R_MALFORMED); }
                }
                samples.push_back(Sample { offset, size, iv: entry.iv, subsamples: entry.subs, flac: track.flac });
            }
        }
    }
    Ok(samples)
}

fn iv_for(data: &[u8], at: usize, track: &Track) -> Result<[u8; 16], Reason> {
    if track.iv_size == 0 { return track.constant_iv.ok_or(R_LAYOUT); }
    let size = usize::from(track.iv_size);
    let mut iv = [0u8; 16];
    iv[..size].copy_from_slice(data.get(at..at + size).ok_or(R_MALFORMED)?);
    Ok(iv)
}

fn senc_entries(data: &[u8], senc: &BoxRef, track: &Track, expected: u64) -> Result<Vec<Entry>, Reason> {
    let q = senc.payload();
    let flags = be32(data, q)? & 0x00ff_ffff;
    if flags & 0x1 != 0 { return Err(R_LAYOUT); }
    if u64::from(be32(data, q + 4)?) != expected { return Err(R_MALFORMED); }
    let mut at = q + 8;
    let mut out = Vec::with_capacity(expected as usize);
    for _ in 0..expected {
        let iv = iv_for(data, at, track)?;
        at += usize::from(track.iv_size);
        let mut subs = Vec::new();
        if flags & 0x2 != 0 {
            let n = usize::from(be16(data, at)?);
            at += 2;
            for _ in 0..n { subs.push((be16(data, at)?, be32(data, at + 2)?)); at += 6; }
        }
        out.push(Entry { iv, subs });
    }
    if at != senc.end { return Err(R_MALFORMED); }
    Ok(out)
}

/// Informacion auxiliar localizada con `saiz`/`saio`; solo si cae dentro del moov
/// (ya recibido). Si estuviera en el mdat no se puede conocer antes de las muestras.
fn aux_entries(data: &[u8], saiz: &BoxRef, saio: &BoxRef, track: &Track, moov_start: u64, expected: usize) -> Result<Vec<Entry>, Reason> {
    let p = saiz.payload();
    let mut at = p + 4;
    if be32(data, p)? & 1 != 0 { at += 8; }
    let default = *data.get(at).ok_or(R_MALFORMED)?;
    let count = be32(data, at + 1)? as usize;
    at += 5;
    if count != expected { return Err(R_MALFORMED); }
    let mut sizes = Vec::with_capacity(count);
    for i in 0..count { sizes.push(if default != 0 { default } else { *data.get(at + i).ok_or(R_MALFORMED)? }); }
    let q = saio.payload();
    let version = *data.get(q).ok_or(R_MALFORMED)?;
    let mut at = q + 4;
    if be32(data, q)? & 1 != 0 { at += 8; }
    if be32(data, at)? != 1 { return Err(R_LAYOUT); }
    let offset = if version == 0 { u64::from(be32(data, at + 4)?) } else { be64(data, at + 4)? };
    let total: u64 = sizes.iter().map(|s| u64::from(*s)).sum();
    if offset < moov_start || offset + total > moov_start + data.len() as u64 { return Err(R_LAYOUT); }
    let mut cursor = (offset - moov_start) as usize;
    let mut out = Vec::with_capacity(count);
    for size in sizes {
        let size = usize::from(size);
        let end = cursor + size;
        let iv_size = usize::from(track.iv_size);
        if size < iv_size { return Err(R_MALFORMED); }
        let iv = iv_for(data, cursor, track)?;
        let mut subs = Vec::new();
        let mut at = cursor + iv_size;
        if at < end {
            let n = usize::from(be16(data, at)?);
            at += 2;
            if end - at != n * 6 { return Err(R_MALFORMED); }
            for _ in 0..n { subs.push((be16(data, at)?, be32(data, at + 2)?)); at += 6; }
        }
        out.push(Entry { iv, subs });
        cursor = end;
    }
    Ok(out)
}

#[cfg(test)]
pub(crate) mod tests;
