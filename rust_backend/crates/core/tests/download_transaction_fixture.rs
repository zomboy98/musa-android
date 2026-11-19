//! Contract fixture only: this does not connect the coordinator to downloads.
use mornye_core::download_transaction::{Cancellation, DownloadTransaction, OperationError};
use mornye_core::tags::read_file_metadata;
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::sync::{Arc, mpsc};
use std::thread;

// A short valid mono 16-bit PCM WAV; no external tools or provider credentials.
fn wav_fixture(sample_rate: u32) -> Vec<u8> {
    let samples = vec![0_u8; 200];
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36_u32 + samples.len() as u32).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16_u32.to_le_bytes());
    bytes.extend_from_slice(&1_u16.to_le_bytes());
    bytes.extend_from_slice(&1_u16.to_le_bytes());
    bytes.extend_from_slice(&sample_rate.to_le_bytes());
    bytes.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    bytes.extend_from_slice(&2_u16.to_le_bytes());
    bytes.extend_from_slice(&16_u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(samples.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&samples);
    bytes
}

fn validate_pcm(path: &Path, expected_rate: u64) -> Result<(), String> {
    let mut file = File::open(path).map_err(|error| error.to_string())?;
    let metadata = read_file_metadata(&mut file, "fixture.wav", "", &|| Ok(()))?;
    if metadata["audio_codec"] != "pcm"
        || metadata["bit_depth"] != 16
        || metadata["sample_rate"] != expected_rate
    {
        return Err("unexpected audio quality".into());
    }
    Ok(())
}

#[test]
fn valid_audio_is_probed_before_local_no_replace_publish() {
    let dir = tempfile::tempdir().unwrap();
    let staging = dir.path().join("private.wav");
    let destination = dir.path().join("published.wav");
    let bytes = wav_fixture(44_100);
    let tx = DownloadTransaction::default();
    tx.start_producer().unwrap();
    fs::write(&staging, &bytes).unwrap();
    tx.producer_stopped(true).unwrap();
    assert!(!destination.exists());
    tx.validate(|| validate_pcm(&staging, 44_100)).unwrap();
    // Hard-link is used only as a same-filesystem no-replace fixture; the
    // production destination adapters still need their own commit guarantees.
    tx.commit(|| fs::hard_link(&staging, &destination)).unwrap();
    assert_eq!(fs::read(&destination).unwrap(), bytes);
    assert_eq!(tx.cancel().unwrap(), Cancellation::AlreadyCommitted);
}

#[test]
fn mismatched_audio_never_reaches_destination() {
    let dir = tempfile::tempdir().unwrap();
    let staging = dir.path().join("private.wav");
    let destination = dir.path().join("published.wav");
    let tx = DownloadTransaction::default();
    tx.start_producer().unwrap();
    fs::write(&staging, wav_fixture(48_000)).unwrap();
    tx.producer_stopped(true).unwrap();
    assert!(matches!(tx.validate(|| validate_pcm(&staging, 44_100)), Err(OperationError::Operation(_))));
    assert!(tx.commit(|| fs::hard_link(&staging, &destination)).is_err());
    assert!(!destination.exists());
    assert!(tx.cleanup_allowed().unwrap());
}

#[test]
fn collision_preserves_existing_file() {
    let dir = tempfile::tempdir().unwrap();
    let staging = dir.path().join("private.wav");
    let destination = dir.path().join("published.wav");
    fs::write(&destination, b"existing audio").unwrap();
    let tx = DownloadTransaction::default();
    tx.start_producer().unwrap();
    fs::write(&staging, wav_fixture(44_100)).unwrap();
    tx.producer_stopped(true).unwrap();
    tx.validate(|| validate_pcm(&staging, 44_100)).unwrap();
    assert!(matches!(tx.commit(|| fs::hard_link(&staging, &destination)), Err(OperationError::Operation(_))));
    assert_eq!(fs::read(&destination).unwrap(), b"existing audio");
    assert_eq!(tx.cancel().unwrap(), Cancellation::Accepted);
    assert!(tx.cleanup_allowed().unwrap());
}

#[test]
fn cancelled_live_writer_must_stop_before_staging_cleanup() {
    let dir = tempfile::tempdir().unwrap();
    let staging = dir.path().join("private.wav");
    let destination = dir.path().join("published.wav");
    let tx = Arc::new(DownloadTransaction::default());
    tx.start_producer().unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    let writer_path = staging.clone();
    let writer = thread::spawn(move || {
        let mut file = File::create(writer_path).unwrap();
        file.write_all(&wav_fixture(44_100)[..20]).unwrap();
        file.flush().unwrap();
        started_tx.send(()).unwrap();
        stop_rx.recv().unwrap();
        // Return closes the file; the owner joins before acknowledging it.
    });
    started_rx.recv().unwrap();
    assert_eq!(tx.cancel().unwrap(), Cancellation::Accepted);
    assert!(!tx.cleanup_allowed().unwrap());
    assert!(staging.exists());
    stop_tx.send(()).unwrap();
    writer.join().unwrap();
    tx.producer_stopped(false).unwrap();
    assert!(tx.cleanup_allowed().unwrap());
    fs::remove_file(&staging).unwrap();
    assert!(!destination.exists());
    assert!(tx.commit(|| fs::hard_link(&staging, &destination)).is_err());
}
