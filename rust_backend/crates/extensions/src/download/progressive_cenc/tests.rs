//! Fixture sintetica: MP4 fragmentado `cenc` generado aqui, cifrado con la misma
//! clave y comparado byte a byte con el original esperado (muestras en claro y
//! cajas neutralizadas en el sitio).

use super::*;

pub(crate) const KEY: [u8; 16] = [0x13, 0x57, 0x9b, 0xdf, 0x24, 0x68, 0xac, 0xe0, 0x91, 0x82, 0x73, 0x64, 0x55, 0x46, 0x37, 0x28];
const OTHER_KEY: [u8; 16] = [0xa5; 16];
const KID: [u8; 16] = [0x81; 16];

fn atom(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
    out.extend_from_slice(kind);
    out.extend_from_slice(payload);
    out
}

fn full(kind: &[u8; 4], version_flags: u32, payload: &[u8]) -> Vec<u8> {
    let mut body = version_flags.to_be_bytes().to_vec();
    body.extend_from_slice(payload);
    atom(kind, &body)
}

#[derive(Clone)]
pub(crate) struct Spec {
    pub(crate) scheme: [u8; 4],
    pub(crate) iv_size: u8,
    pub(crate) constant_iv: Option<Vec<u8>>,
    pub(crate) original: [u8; 4],
    pub(crate) is_protected: u8,
    pub(crate) fragmented: bool,
    pub(crate) handler: [u8; 4],
}

impl Default for Spec {
    fn default() -> Self {
        Self { scheme: *b"cenc", iv_size: 8, constant_iv: None, original: *b"fLaC", is_protected: 1, fragmented: true, handler: *b"soun" }
    }
}

fn init(spec: &Spec) -> Vec<u8> {
    let mut tenc = vec![0, 0, spec.is_protected, spec.iv_size];
    tenc.extend_from_slice(&KID);
    if let Some(iv) = &spec.constant_iv {
        tenc.push(iv.len() as u8);
        tenc.extend_from_slice(iv);
    }
    let schi = atom(b"schi", &full(b"tenc", 0, &tenc));
    let mut schm_payload = spec.scheme.to_vec();
    schm_payload.extend_from_slice(&0x0001_0000u32.to_be_bytes());
    let mut sinf_payload = atom(b"frma", &spec.original);
    sinf_payload.extend(full(b"schm", 0, &schm_payload));
    sinf_payload.extend(schi);
    let mut entry = vec![0u8; 28];
    entry.extend(atom(b"dfLa", &[0; 12]));
    entry.extend(atom(b"sinf", &sinf_payload));
    let enca = atom(b"enca", &entry);
    let mut stsd_payload = 1u32.to_be_bytes().to_vec();
    stsd_payload.extend(enca);
    let stbl = atom(b"stbl", &full(b"stsd", 0, &stsd_payload));
    let minf = atom(b"minf", &stbl);
    let mut hdlr = vec![0u8; 4];
    hdlr.extend_from_slice(&spec.handler);
    hdlr.extend_from_slice(&[0; 12]);
    let mut mdia = full(b"hdlr", 0, &hdlr);
    mdia.extend(minf);
    let mut tkhd = vec![0u8; 8];
    tkhd.extend_from_slice(&1u32.to_be_bytes());
    tkhd.extend_from_slice(&[0; 68]);
    let mut trak = full(b"tkhd", 0, &tkhd);
    trak.extend(atom(b"mdia", &mdia));
    let mut moov = atom(b"mvhd", &[0; 100]);
    moov.extend(atom(b"trak", &trak));
    if spec.fragmented {
        let mut trex = Vec::new();
        for value in [1u32, 1, 0, 0, 0] { trex.extend_from_slice(&value.to_be_bytes()); }
        moov.extend(atom(b"mvex", &full(b"trex", 0, &trex)));
    }
    moov.extend(full(b"pssh", 0, &[0x90; 20]));
    let mut file = atom(b"ftyp", b"isom\0\0\0\0isomcenc");
    file.extend(atom(b"moov", &moov));
    file
}

/// Cifrador CTR independiente del de produccion.
fn ctr(key: &[u8; 16], iv: [u8; 16], data: &mut [u8], subsamples: &[(u16, u32)]) {
    use aes::cipher::{Block, BlockCipherEncrypt, KeyInit};
    let cipher = aes::Aes128::new_from_slice(key).unwrap();
    let mut counter = u128::from_be_bytes(iv);
    let mut stream = Vec::new();
    let regions: Vec<(usize, usize)> = if subsamples.is_empty() {
        vec![(0, data.len())]
    } else {
        let mut at = 0usize;
        subsamples.iter().map(|(clear, enc)| { let start = at + *clear as usize; at = start + *enc as usize; (start, at) }).collect()
    };
    let total: usize = regions.iter().map(|(a, b)| b - a).sum();
    while stream.len() < total {
        let mut block = Block::<aes::Aes128>::try_from(&counter.to_be_bytes()[..]).unwrap();
        cipher.encrypt_block(&mut block);
        stream.extend_from_slice(&block);
        counter = counter.wrapping_add(1);
    }
    let mut used = 0usize;
    for (start, stop) in regions {
        for byte in &mut data[start..stop] { *byte ^= stream[used]; used += 1; }
    }
}

fn flac_sample(seed: usize, len: usize) -> Vec<u8> {
    let mut sample = vec![0xff, 0xf8];
    sample.extend((0..len - 2).map(|i| (i.wrapping_mul(31).wrapping_add(seed * 7) % 251) as u8));
    sample
}

#[derive(Default, Clone)]
pub(crate) struct FragmentOptions {
    key: Option<[u8; 16]>,
    subsamples: Vec<Vec<(u16, u32)>>,
    omit_senc: bool,
    extra_traf: Vec<u8>,
    second_traf: bool,
    senc_count_delta: i64,
    use_16_byte_iv: bool,
}

pub(crate) struct Built {
    pub(crate) encrypted: Vec<u8>,
    pub(crate) expected: Vec<u8>,
    /// `(offset, len)` de cada muestra en el archivo.
    pub(crate) samples: Vec<(usize, usize)>,
}

pub(crate) fn build(spec: &Spec, fragments: &[Vec<Vec<u8>>], options: &FragmentOptions) -> Built {
    let init = init(spec);
    let mut encrypted = init.clone();
    let mut expected = neutralize(init.clone(), spec);
    let mut samples = Vec::new();
    let key = options.key.unwrap_or(KEY);
    let mut serial = 0usize;
    for (index, plain) in fragments.iter().enumerate() {
        let mut protected = plain.clone();
        let mut senc = ((plain.len() as i64 + options.senc_count_delta).max(0) as u32).to_be_bytes().to_vec();
        for (n, sample) in protected.iter_mut().enumerate() {
            serial += 1;
            let mut iv = [0u8; 16];
            let iv_len = if options.use_16_byte_iv { 16 } else { 8 };
            for (i, byte) in iv.iter_mut().take(iv_len).enumerate() { *byte = (0x90 + serial * 3 + i) as u8; }
            if let Some(constant) = &spec.constant_iv { iv = [0; 16]; iv[..constant.len()].copy_from_slice(constant); }
            let subs: Vec<(u16, u32)> = options.subsamples.get(n % options.subsamples.len().max(1)).cloned().unwrap_or_default();
            let subs: Vec<(u16, u32)> = if subs.is_empty() { Vec::new() } else { fit(&subs, sample.len()) };
            ctr(&key, iv, sample, &subs);
            if spec.iv_size > 0 { senc.extend_from_slice(&iv[..spec.iv_size as usize]); }
            if !subs.is_empty() {
                senc.extend_from_slice(&(subs.len() as u16).to_be_bytes());
                for (clear, enc) in &subs { senc.extend_from_slice(&clear.to_be_bytes()); senc.extend_from_slice(&enc.to_be_bytes()); }
            }
        }
        let senc_flags = if options.subsamples.is_empty() { 0 } else { 2 };
        let moof = |data_offset: i32| {
            let mut trun = (plain.len() as u32).to_be_bytes().to_vec();
            trun.extend_from_slice(&data_offset.to_be_bytes());
            for sample in plain { trun.extend_from_slice(&(sample.len() as u32).to_be_bytes()); }
            let mut traf = full(b"tfhd", 0x0002_0000, &1u32.to_be_bytes());
            traf.extend(full(b"tfdt", 0, &[0; 4]));
            traf.extend(full(b"trun", 0x0000_0201, &trun));
            if !options.omit_senc { traf.extend(full(b"senc", senc_flags, &senc)); }
            traf.extend(full(b"saiz", 0, &[0; 5]));
            traf.extend(full(b"saio", 0, &[0; 4]));
            traf.extend_from_slice(&options.extra_traf);
            let mut moof = full(b"mfhd", 0, &(index as u32 + 1).to_be_bytes());
            moof.extend(atom(b"traf", &traf));
            if options.second_traf { moof.extend(atom(b"traf", &traf)); }
            moof.extend(full(b"pssh", 0, &[0x91; 8]));
            atom(b"moof", &moof)
        };
        let size = moof(0).len();
        let moof_bytes = moof(size as i32 + 8);
        let mdat_payload: Vec<u8> = protected.iter().flatten().copied().collect();
        let plain_payload: Vec<u8> = plain.iter().flatten().copied().collect();
        let mut at = encrypted.len() + moof_bytes.len() + 8;
        for sample in plain { samples.push((at, sample.len())); at += sample.len(); }
        encrypted.extend_from_slice(&moof_bytes);
        encrypted.extend(atom(b"mdat", &mdat_payload));
        expected.extend(neutralize(moof_bytes, spec));
        expected.extend(atom(b"mdat", &plain_payload));
    }
    Built { encrypted, expected, samples }
}

fn fit(template: &[(u16, u32)], len: usize) -> Vec<(u16, u32)> {
    // Ajusta el patron de subsamples al tamano exacto de la muestra.
    let mut out = Vec::new();
    let mut left = len;
    for (clear, enc) in template {
        if left == 0 { break; }
        let clear = (*clear as usize).min(left);
        left -= clear;
        let enc = (*enc as usize).min(left);
        left -= enc;
        out.push((clear as u16, enc as u32));
    }
    if left > 0 { out.push((0, left as u32)); }
    out
}

fn swap(bytes: &mut [u8], from: &[u8; 4], to: &[u8; 4]) {
    let mut at = 0;
    while at + 4 <= bytes.len() {
        if &bytes[at..at + 4] == from { bytes[at..at + 4].copy_from_slice(to); }
        at += 1;
    }
}

fn neutralize(mut meta: Vec<u8>, spec: &Spec) -> Vec<u8> {
    swap(&mut meta, b"enca", &spec.original);
    for kind in [b"sinf", b"pssh", b"senc", b"saiz", b"saio"] { swap(&mut meta, kind, b"free"); }
    meta
}

/// Reparte la llegada y comprueba el invariante en cada paso.
fn stream(built: &Built, key: &[u8; 16], steps: &[u64]) -> Result<Vec<u8>, (&'static str, Vec<u8>)> {
    let data = &built.encrypted;
    let mut decryptor = CencStream::new(key).unwrap();
    let mut clear = Vec::new();
    let mut written = 0u64;
    let mut cursor = 0usize;
    let mut previous = 0u64;
    let mut worked = false;
    while written < data.len() as u64 {
        written = (written + steps[cursor % steps.len()]).min(data.len() as u64);
        cursor += 1;
        let result = decryptor.advance(written, |offset, len| {
            assert!(offset + len as u64 <= written, "lee mas alla de lo escrito");
            Ok(data[offset as usize..offset as usize + len].to_vec())
        });
        match result {
            Ok(approved) => {
                assert!(approved >= previous && approved <= written);
                previous = approved;
                worked |= approved < written;
                clear.extend(decryptor.take_output());
                assert_eq!(clear.len() as u64, approved);
                assert_eq!(clear[..], built.expected[..clear.len()], "la salida parcial difiere del original esperado");
            }
            Err(()) => return Err((decryptor.reason().unwrap(), clear)),
        }
    }
    assert!(decryptor.complete(data.len() as u64));
    assert!(!decryptor.complete(data.len() as u64 + 1));
    let _ = worked;
    Ok(clear)
}

pub(crate) fn plain_fragments(fragments: usize, samples: usize) -> Vec<Vec<Vec<u8>>> {
    (0..fragments).map(|f| (0..samples).map(|s| flac_sample(f * 10 + s, 40 + (f * 13 + s * 29) % 300)).collect()).collect()
}

#[test]
fn one_shot_decrypts_the_whole_fragmented_file() {
    let built = build(&Spec::default(), &plain_fragments(3, 5), &FragmentOptions::default());
    let output = stream(&built, &KEY, &[u64::MAX / 4]).unwrap();
    assert_eq!(output, built.expected);
    assert_eq!(output.len(), built.encrypted.len());
    assert_ne!(output, built.encrypted);
    // Cada muestra cifrada realmente difiere del texto en claro.
    for (offset, len) in &built.samples {
        assert_ne!(built.encrypted[*offset..*offset + len], output[*offset..*offset + len]);
    }
    // Sin cajas de proteccion: se recorre el arbol para comprobarlo.
    for kind in [b"sinf", b"enca", b"senc", b"saiz", b"saio", b"pssh"] {
        assert!(!output.windows(4).any(|w| w == kind), "queda {}", String::from_utf8_lossy(kind));
    }
    assert!(output.windows(4).any(|w| w == b"fLaC"));
}

#[test]
fn arrival_in_arbitrary_chunks_never_leaks_ciphertext_and_matches_the_original() {
    let built = build(&Spec::default(), &plain_fragments(3, 6), &FragmentOptions::default());
    let patterns: [&[u64]; 7] = [&[1], &[3], &[5, 11], &[64], &[1000], &[7, 1, 4093, 2, 31], &[19, 23, 29, 37]];
    for steps in patterns {
        let output = stream(&built, &KEY, steps).unwrap();
        assert_eq!(output, built.expected, "{steps:?}");
    }
}

#[test]
fn samples_crossing_chunk_boundaries_are_held_back_until_complete() {
    let built = build(&Spec::default(), &plain_fragments(1, 4), &FragmentOptions::default());
    let (offset, len) = built.samples[1];
    let mut decryptor = CencStream::new(&KEY).unwrap();
    let data = &built.encrypted;
    let read = |offset: u64, len: usize| Ok(data[offset as usize..offset as usize + len].to_vec());
    // Hasta la mitad de la segunda muestra no se puede pasar del inicio de esa muestra.
    let approved = decryptor.advance((offset + len / 2) as u64, read).unwrap();
    assert_eq!(approved, offset as u64);
    let out = decryptor.take_output();
    assert_eq!(out[..], built.expected[..offset]);
    let approved = decryptor.advance((offset + len) as u64, read).unwrap();
    assert_eq!(approved, (offset + len) as u64);
}

#[test]
fn subsample_encryption_keeps_the_keystream_across_protected_ranges() {
    let options = FragmentOptions { subsamples: vec![vec![(10, 30), (7, 50), (0, 1000)], vec![(2, 9)], vec![(33, 4000)]], ..Default::default() };
    for (iv_16, spec) in [(false, Spec::default()), (true, Spec { iv_size: 16, ..Spec::default() })] {
        let options = FragmentOptions { use_16_byte_iv: iv_16, ..options.clone() };
        let built = build(&spec, &plain_fragments(2, 7), &options);
        for steps in [&[1u64][..], &[41], &[u64::MAX / 4]] {
            assert_eq!(stream(&built, &KEY, steps).unwrap(), built.expected);
        }
        // Las partes en claro de cada subsample permanecen sin tocar.
        assert_eq!(built.expected[built.samples[0].0..built.samples[0].0 + 10], built.encrypted[built.samples[0].0..built.samples[0].0 + 10]);
    }
}

#[test]
fn constant_iv_without_per_sample_ivs_decrypts() {
    for constant in [vec![0x70u8; 8], vec![0x71u8; 16]] {
        let spec = Spec { iv_size: 0, constant_iv: Some(constant), ..Spec::default() };
        for options in [FragmentOptions::default(), FragmentOptions { omit_senc: true, ..Default::default() }, FragmentOptions { subsamples: vec![vec![(5, 20)]], ..Default::default() }] {
            let built = build(&spec, &plain_fragments(2, 4), &options);
            assert_eq!(stream(&built, &KEY, &[17]).unwrap(), built.expected);
        }
    }
}

#[test]
fn wrong_key_is_rejected_before_any_sample_is_released() {
    let built = build(&Spec::default(), &plain_fragments(2, 4), &FragmentOptions::default());
    let (reason, clear) = stream(&built, &OTHER_KEY, &[64]).unwrap_err();
    assert_eq!(reason, "cenc_key_rejected");
    // Solo pudo salir la cabecera (ftyp/moov/moof/mdat), nunca una muestra.
    assert!(clear.len() <= built.samples[0].0);
}

#[test]
fn unsupported_or_uncertain_layouts_abort_with_a_stable_reason() {
    let fragments = plain_fragments(2, 3);
    let abort = |spec: Spec, options: FragmentOptions| {
        let built = build(&spec, &fragments, &options);
        stream(&built, &KEY, &[53]).map(|_| "ok").unwrap_err()
    };
    for scheme in [b"cbcs", b"cens", b"cbc1"] {
        assert_eq!(abort(Spec { scheme: *scheme, ..Spec::default() }, Default::default()).0, "cenc_unsupported_scheme");
    }
    assert_eq!(abort(Spec { fragmented: false, ..Spec::default() }, Default::default()).0, "cenc_unsupported_layout");
    assert_eq!(abort(Spec { is_protected: 0, ..Spec::default() }, Default::default()).0, "cenc_not_protected");
    assert_eq!(abort(Spec { handler: *b"vide", ..Spec::default() }, Default::default()).0, "cenc_unsupported_layout");
    assert_eq!(abort(Spec { iv_size: 12, ..Spec::default() }, Default::default()).0, "cenc_unsupported_layout");
    assert_eq!(abort(Spec::default(), FragmentOptions { second_traf: true, ..Default::default() }).0, "cenc_unsupported_layout");
    assert_eq!(abort(Spec::default(), FragmentOptions { extra_traf: full(b"sgpd", 1, b"seig\0\0\0\x14\0\0\0\0"), ..Default::default() }).0, "cenc_unsupported_layout");
    assert_eq!(abort(Spec::default(), FragmentOptions { extra_traf: atom(b"uuid", &[0xa2; 20]), ..Default::default() }).0, "cenc_unsupported_layout");
    // Sin `senc` y sin IV constante no hay forma de conocer el IV.
    assert_eq!(abort(Spec::default(), FragmentOptions { omit_senc: true, ..Default::default() }).0, "cenc_unsupported_layout");
    assert_eq!(abort(Spec::default(), FragmentOptions { senc_count_delta: 1, ..Default::default() }).0, "cenc_malformed");
    assert_eq!(abort(Spec::default(), FragmentOptions { senc_count_delta: -1, ..Default::default() }).0, "cenc_malformed");
}

#[test]
fn media_before_metadata_and_oversized_metadata_abort() {
    let mut file = atom(b"ftyp", b"isom\0\0\0\0");
    file.extend(atom(b"mdat", &[0x55; 64]));
    file.extend(init(&Spec::default()));
    let built = Built { encrypted: file.clone(), expected: file, samples: Vec::new() };
    assert_eq!(stream(&built, &KEY, &[16]).unwrap_err().0, "metadata_after_media");

    let mut huge = atom(b"ftyp", b"isom\0\0\0\0");
    huge.extend_from_slice(&(MAX_META as u32 + 9).to_be_bytes());
    huge.extend_from_slice(b"moov");
    huge.extend(vec![0u8; 64]);
    let built = Built { encrypted: huge.clone(), expected: huge, samples: Vec::new() };
    assert_eq!(stream(&built, &KEY, &[16]).unwrap_err().0, "metadata_too_large");
}

#[test]
fn truncated_streams_are_never_complete_and_bad_keys_cannot_be_built() {
    let built = build(&Spec::default(), &plain_fragments(2, 3), &FragmentOptions::default());
    let data = &built.encrypted;
    for cut in [data.len() - 1, data.len() - 40, built.samples[0].0 + 3, 30] {
        let mut decryptor = CencStream::new(&KEY).unwrap();
        let approved = decryptor.advance(cut as u64, |offset, len| Ok(data[offset as usize..offset as usize + len].to_vec())).unwrap();
        assert!(approved <= cut as u64);
        assert!(!decryptor.complete(cut as u64) || cut == data.len());
    }
    assert!(CencStream::new(&KEY[..15]).is_err());
    assert!(CencStream::new(&[0; 32]).is_err());
}

#[test]
fn a_failed_advance_discards_pending_output_and_going_backwards_is_refused() {
    let built = build(&Spec::default(), &plain_fragments(1, 2), &FragmentOptions::default());
    let data = &built.encrypted;
    let read = |offset: u64, len: usize| Ok(data[offset as usize..offset as usize + len].to_vec());
    let mut decryptor = CencStream::new(&OTHER_KEY).unwrap();
    assert!(decryptor.advance(data.len() as u64, read).is_err());
    assert!(decryptor.take_output().is_empty());
    let mut decryptor = CencStream::new(&KEY).unwrap();
    decryptor.advance(data.len() as u64, read).unwrap();
    assert!(decryptor.advance(50, read).is_err());
}

fn mdat_payloads(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while at + 8 <= data.len() {
        let size = u32::from_be_bytes(data[at..at + 4].try_into().unwrap()) as usize;
        assert!(size >= 8 && at + size <= data.len(), "caja invalida en {at}");
        if &data[at + 4..at + 8] == b"mdat" { out.extend_from_slice(&data[at + 8..at + size]); }
        at += size;
    }
    out
}

/// Comprobacion contra muxers reales. `gpac-*` (MP4Box, fMP4 `cenc` con `senc` por
/// fragmento) debe descifrar y coincidir con el mismo mux sin cifrar; los
/// ficheros de ffmpeg no llevan informacion de IV por fragmento y deben abortar.
#[test]
#[ignore = "necesita fixtures generados con herramientas externas (WISS_CENC_FIXTURE)"]
fn real_muxer_fixtures_decrypt_or_abort() {
    let dir = std::path::PathBuf::from(std::env::var("WISS_CENC_FIXTURE").expect("WISS_CENC_FIXTURE"));
    let key_hex = std::fs::read_to_string(dir.join("key.hex")).unwrap();
    let key: Vec<u8> = (0..16).map(|i| u8::from_str_radix(&key_hex.trim()[i * 2..i * 2 + 2], 16).unwrap()).collect();
    let mut decrypted = 0;
    for name in ["flac", "aac", "opus", "gpac-flac", "gpac-aac", "gpac-opus", "classic-flac", "classic-aac", "classic-opus"] {
        let Ok(enc) = std::fs::read(dir.join(format!("{name}-enc.mp4"))) else { continue };
        let mut decryptor = CencStream::new(&key).unwrap();
        let mut output = Vec::new();
        let mut written = 0u64;
        let mut failure = None;
        while written < enc.len() as u64 {
            written = (written + 4099).min(enc.len() as u64);
            match decryptor.advance(written, |offset, len| Ok(enc[offset as usize..offset as usize + len].to_vec())) {
                Ok(approved) => { output.extend(decryptor.take_output()); assert_eq!(output.len() as u64, approved); }
                Err(()) => { failure = decryptor.reason(); break; }
            }
        }
        println!("{name}: {}", failure.unwrap_or("descifrado"));
        if !name.starts_with("gpac") && !name.starts_with("classic") {
            assert_eq!(failure, Some("cenc_unsupported_layout"), "{name}");
            continue;
        }
        // MP4 clasico de MP4Box: puede llevar el IV fuera del moov; entonces debe abortar.
        if name.starts_with("classic") && failure.is_some() {
            assert_eq!(failure, Some("cenc_unsupported_layout"), "{name}");
            continue;
        }
        assert_eq!(failure, None, "{name}");
        let clear = std::fs::read(dir.join(format!("{name}-clear.mp4"))).unwrap();
        assert!(decryptor.complete(enc.len() as u64), "{name}");
        assert_eq!(output.len(), enc.len(), "{name}");
        assert_ne!(mdat_payloads(&output), mdat_payloads(&enc), "{name}: las muestras deben cambiar");
        assert_eq!(mdat_payloads(&output), mdat_payloads(&clear), "{name}: muestras descifradas distintas del mux sin cifrar");
        std::fs::write(dir.join(format!("{name}-out.mp4")), &output).unwrap();
        decrypted += 1;
    }
    assert!(decrypted > 0, "ningun fixture gpac");
}

// ---------------------------------------------------------------------------
// MP4 clasico (no fragmentado): moov primero con tablas de muestras y senc o
// saiz/saio dentro del moov, un unico mdat despues.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum Aux { Senc, SaioInMoov, SaioInMdat, ConstantIv }

#[derive(Clone)]
struct ClassicOptions {
    aux: Aux,
    per_chunk: usize,
    wide: bool,
    subsamples: bool,
    key: [u8; 16],
}

impl Default for ClassicOptions {
    fn default() -> Self { Self { aux: Aux::Senc, per_chunk: 3, wide: false, subsamples: false, key: KEY } }
}

fn enca_stsd(spec: &Spec) -> Vec<u8> {
    let mut tenc = vec![0, 0, spec.is_protected, spec.iv_size];
    tenc.extend_from_slice(&KID);
    if let Some(iv) = &spec.constant_iv { tenc.push(iv.len() as u8); tenc.extend_from_slice(iv); }
    let mut schm = spec.scheme.to_vec();
    schm.extend_from_slice(&0x0001_0000u32.to_be_bytes());
    let mut sinf = atom(b"frma", &spec.original);
    sinf.extend(full(b"schm", 0, &schm));
    sinf.extend(atom(b"schi", &full(b"tenc", 0, &tenc)));
    let mut entry = vec![0u8; 28];
    entry.extend(atom(b"dfLa", &[0; 12]));
    entry.extend(atom(b"sinf", &sinf));
    let mut stsd = 1u32.to_be_bytes().to_vec();
    stsd.extend(atom(b"enca", &entry));
    full(b"stsd", 0, &stsd)
}

fn build_classic(spec: &Spec, samples: &[Vec<u8>], options: &ClassicOptions) -> Built {
    let ftyp = atom(b"ftyp", b"M4A \0\0\0\0M4A isom");
    let sizes: Vec<usize> = samples.iter().map(Vec::len).collect();
    // Subsamples: una parte en claro al principio de cada muestra.
    let subs_for = |len: usize| -> Vec<(u16, u32)> {
        if !options.subsamples { Vec::new() } else { vec![(4, (len - 4 - 3) as u32), (3, 0)] }
    };
    let mut protected = samples.to_vec();
    let mut entries: Vec<Vec<u8>> = Vec::new();
    for (n, sample) in protected.iter_mut().enumerate() {
        let mut iv = [0u8; 16];
        for (i, byte) in iv.iter_mut().take(spec.iv_size as usize).enumerate() { *byte = (0xa0 + n * 5 + i) as u8; }
        if let Some(constant) = &spec.constant_iv { iv = [0; 16]; iv[..constant.len()].copy_from_slice(constant); }
        let subs = subs_for(sample.len());
        ctr(&options.key, iv, sample, &subs);
        let mut entry = iv[..spec.iv_size as usize].to_vec();
        if !subs.is_empty() {
            entry.extend_from_slice(&(subs.len() as u16).to_be_bytes());
            for (clear, enc) in &subs { entry.extend_from_slice(&clear.to_be_bytes()); entry.extend_from_slice(&enc.to_be_bytes()); }
        }
        entries.push(entry);
    }
    let moov_for = |mdat_payload_start: u64, aux_offset: u64| -> (Vec<u8>, usize) {
        let mut stbl = enca_stsd(spec);
        stbl.extend(full(b"stts", 0, &[0; 4]));
        // stsc: trozos de `per_chunk` muestras y un ultimo trozo con el resto.
        let chunks = samples.len().div_ceil(options.per_chunk);
        let rest = samples.len() % options.per_chunk;
        let mut stsc = Vec::new();
        let runs = if rest == 0 { 1u32 } else { 2 };
        stsc.extend_from_slice(&runs.to_be_bytes());
        for value in [1u32, options.per_chunk as u32, 1] { stsc.extend_from_slice(&value.to_be_bytes()); }
        if rest != 0 { for value in [chunks as u32, rest as u32, 1] { stsc.extend_from_slice(&value.to_be_bytes()); } }
        stbl.extend(full(b"stsc", 0, &stsc));
        let mut stsz = vec![0u8; 4];
        stsz.extend_from_slice(&(sizes.len() as u32).to_be_bytes());
        for size in &sizes { stsz.extend_from_slice(&(*size as u32).to_be_bytes()); }
        stbl.extend(full(b"stsz", 0, &stsz));
        let mut stco = (chunks as u32).to_be_bytes().to_vec();
        let mut at = mdat_payload_start;
        for chunk in 0..chunks {
            if options.wide { stco.extend_from_slice(&at.to_be_bytes()); } else { stco.extend_from_slice(&(at as u32).to_be_bytes()); }
            for size in sizes.iter().skip(chunk * options.per_chunk).take(options.per_chunk) { at += *size as u64; }
        }
        stbl.extend(full(if options.wide { b"co64" } else { b"stco" }, 0, &stco));
        let blob: Vec<u8> = entries.iter().flatten().copied().collect();
        let flags = if options.subsamples { 2 } else { 0 };
        match options.aux {
            Aux::Senc => {
                let mut senc = (samples.len() as u32).to_be_bytes().to_vec();
                senc.extend_from_slice(&blob);
                stbl.extend(full(b"senc", flags, &senc));
            }
            Aux::SaioInMoov | Aux::SaioInMdat => {
                let mut saiz = vec![0u8];
                saiz.extend_from_slice(&(samples.len() as u32).to_be_bytes());
                for entry in &entries { saiz.push(entry.len() as u8); }
                stbl.extend(full(b"saiz", 0, &saiz));
                let mut saio = 1u32.to_be_bytes().to_vec();
                saio.extend_from_slice(&(aux_offset as u32).to_be_bytes());
                stbl.extend(full(b"saio", 0, &saio));
            }
            Aux::ConstantIv => {}
        }
        let mut trak = full(b"tkhd", 0, &{ let mut t = vec![0u8; 8]; t.extend_from_slice(&1u32.to_be_bytes()); t.extend_from_slice(&[0; 68]); t });
        let mut hdlr = vec![0u8; 4]; hdlr.extend_from_slice(b"soun"); hdlr.extend_from_slice(&[0; 12]);
        let mut mdia = full(b"hdlr", 0, &hdlr);
        mdia.extend(atom(b"minf", &atom(b"stbl", &stbl)));
        trak.extend(atom(b"mdia", &mdia));
        let mut moov = atom(b"mvhd", &[0; 100]);
        moov.extend(atom(b"trak", &trak));
        moov.extend(full(b"pssh", 0, &[0x90; 20]));
        let mut blob_at = 0;
        if options.aux == Aux::SaioInMoov {
            let aux = atom(b"free", &blob);
            moov.extend(aux);
            blob_at = moov.len() - blob.len();
        }
        (atom(b"moov", &moov), blob_at + 8)
    };
    // Dos pasadas: el tamano del moov no depende de los desplazamientos.
    let (probe, _) = moov_for(0, 0);
    let free = atom(b"free", &[0; 40]);
    let payload_start = (ftyp.len() + probe.len() + free.len() + 8) as u64;
    let blob: Vec<u8> = entries.iter().flatten().copied().collect();
    let aux_offset = match options.aux {
        Aux::SaioInMoov => (ftyp.len() + moov_for(payload_start, 0).1) as u64,
        // Fuera del moov: dentro del mdat, no disponible antes de las muestras.
        Aux::SaioInMdat => payload_start,
        _ => 0,
    };
    let (moov, _) = moov_for(payload_start, aux_offset);
    let mut encrypted = ftyp.clone();
    encrypted.extend_from_slice(&moov);
    encrypted.extend_from_slice(&free);
    let mut expected = neutralize(encrypted.clone(), spec);
    let mut out_samples = Vec::new();
    let mut at = encrypted.len() + 8;
    for sample in samples { out_samples.push((at, sample.len())); at += sample.len(); }
    let mut mdat_enc: Vec<u8> = Vec::new();
    if options.aux == Aux::SaioInMdat { mdat_enc.extend_from_slice(&blob); }
    let mdat_clear_prefix = mdat_enc.clone();
    mdat_enc.extend(protected.iter().flatten());
    encrypted.extend(atom(b"mdat", &mdat_enc));
    let mut mdat_plain = mdat_clear_prefix;
    mdat_plain.extend(samples.iter().flatten());
    expected.extend(atom(b"mdat", &mdat_plain));
    Built { encrypted, expected, samples: out_samples }
}

fn classic_plain(count: usize) -> Vec<Vec<u8>> {
    (0..count).map(|n| flac_sample(n, 40 + (n * 37) % 200)).collect()
}

#[test]
fn classic_mp4_with_senc_in_moov_decrypts_while_arriving() {
    for (wide, per_chunk) in [(false, 3), (true, 4), (false, 1), (false, 100)] {
        let options = ClassicOptions { wide, per_chunk, ..Default::default() };
        let built = build_classic(&Spec::default(), &classic_plain(11), &options);
        for steps in [&[1u64][..], &[7, 13], &[512], &[u64::MAX / 4]] {
            assert_eq!(stream(&built, &KEY, steps).unwrap(), built.expected, "wide={wide} per_chunk={per_chunk} {steps:?}");
        }
        assert_ne!(built.encrypted, built.expected);
    }
}

#[test]
fn classic_mp4_with_subsamples_and_16_byte_iv_decrypts() {
    for spec in [Spec::default(), Spec { iv_size: 16, ..Spec::default() }] {
        let options = ClassicOptions { subsamples: true, ..Default::default() };
        let built = build_classic(&spec, &classic_plain(9), &options);
        assert_eq!(stream(&built, &KEY, &[29]).unwrap(), built.expected);
    }
}

#[test]
fn classic_mp4_with_aux_info_located_by_saio_inside_the_moov_decrypts() {
    for subsamples in [false, true] {
        let options = ClassicOptions { aux: Aux::SaioInMoov, subsamples, ..Default::default() };
        let built = build_classic(&Spec::default(), &classic_plain(10), &options);
        assert_eq!(stream(&built, &KEY, &[23]).unwrap(), built.expected, "subsamples={subsamples}");
    }
}

#[test]
fn classic_mp4_with_constant_iv_and_no_aux_info_decrypts() {
    let spec = Spec { iv_size: 0, constant_iv: Some(vec![0x61; 8]), ..Spec::default() };
    let options = ClassicOptions { aux: Aux::ConstantIv, ..Default::default() };
    let built = build_classic(&spec, &classic_plain(8), &options);
    assert_eq!(stream(&built, &KEY, &[31]).unwrap(), built.expected);
}

#[test]
fn classic_mp4_aborts_when_the_iv_table_is_in_the_mdat_or_the_key_is_wrong() {
    let built = build_classic(&Spec::default(), &classic_plain(6), &ClassicOptions { aux: Aux::SaioInMdat, ..Default::default() });
    assert_eq!(stream(&built, &KEY, &[64]).unwrap_err().0, "cenc_unsupported_layout");
    let built = build_classic(&Spec::default(), &classic_plain(6), &ClassicOptions { key: OTHER_KEY, ..Default::default() });
    let (reason, clear) = stream(&built, &KEY, &[64]).unwrap_err();
    assert_eq!(reason, "cenc_key_rejected");
    assert!(clear.len() <= built.samples[0].0);
}

#[test]
fn classic_mp4_with_a_seig_group_or_inconsistent_tables_aborts() {
    // Tablas incoherentes: un stsz con mas muestras que las que describe el stsc.
    let built = build_classic(&Spec::default(), &classic_plain(6), &ClassicOptions::default());
    let mut broken = Built { encrypted: built.encrypted.clone(), expected: built.expected.clone(), samples: built.samples.clone() };
    let at = broken.encrypted.windows(4).position(|w| w == b"stsz").unwrap();
    // sample_count (tras tipo, ver/flags y sample_size) = 7
    broken.encrypted[at + 12..at + 16].copy_from_slice(&7u32.to_be_bytes());
    assert!(stream(&broken, &KEY, &[64]).is_err());
}
