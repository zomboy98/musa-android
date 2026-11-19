use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
use mornye_extensions::{environment::ExtensionEnvironment, RuntimeLimits};
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::Path;
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

// Test-only model: a reader must never treat temporary EOF as completion, and
// must reject a rewritten or truncated prefix. Completion comes from the owner,
// not from observing file length. This intentionally copies small test data.
#[derive(Default)]
struct ProgressiveReader { observed: Vec<u8> }

impl ProgressiveReader {
    fn observe(&mut self, path: &Path) -> Result<&[u8], &'static str> {
        let bytes = fs::read(path).map_err(|_| "not available")?;
        if !bytes.starts_with(&self.observed) { return Err("prefix changed"); }
        self.observed = bytes;
        Ok(&self.observed)
    }
}

#[test]
fn progressive_reader_rejects_rewritten_or_truncated_prefix() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("partial");
    let mut reader = ProgressiveReader::default();
    fs::write(&path, b"abcdef").unwrap();
    assert_eq!(reader.observe(&path).unwrap(), b"abcdef");
    fs::write(&path, b"abc").unwrap();
    assert_eq!(reader.observe(&path), Err("prefix changed"));
    fs::write(&path, b"abcXefg").unwrap();
    assert_eq!(reader.observe(&path), Err("prefix changed"));
    fs::write(&path, b"abcdefgh").unwrap();
    assert_eq!(reader.observe(&path).unwrap(), b"abcdefgh");
}

// Exercises the existing host transfer; no production progressive API is added.
#[test]
fn local_partial_has_contiguous_prefix_before_commit_and_cancel_prevents_commit() {
    for cancel in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_path_buf();
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36_u32 + 262_144).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&8000_u32.to_le_bytes());
        bytes.extend_from_slice(&8000_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&8_u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&262_144_u32.to_le_bytes());
        bytes.extend((0..262_144).map(|i| (i % 251) as u8));
        let body = bytes.clone();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/audio", listener.local_addr().unwrap());
        let (first_tx, first_rx) = mpsc::channel();
        let (resume_tx, resume_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut request = [0; 4096];
            let _ = stream.read(&mut request).unwrap();
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
            stream.write_all(&body[..131_072]).unwrap();
            stream.flush().unwrap();
            first_tx.send(()).unwrap();
            resume_rx.recv_timeout(Duration::from_secs(10)).unwrap();
            let _ = stream.write_all(&body[131_072..]);
        });
        let registry = Arc::new(CancellationRegistry::new(CancellationDomain::Download));
        let worker_registry = Arc::clone(&registry);
        let worker_root = root.clone();
        let worker = thread::spawn(move || {
            let env = ExtensionEnvironment::new(&worker_root, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1").unwrap();
            env.set_allow_private_network(true).unwrap();
            let manifest = json!({"name":"progressive.fixture","version":"1","description":"local fixture",
                "type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true}}).to_string();
            let runtime = env.load(&manifest, r#"registerExtension({run(url){return file.download(url,'audio.bin',{maxAttempts:1,resume:false});}});"#, RuntimeLimits::default()).unwrap();
            let lease = Arc::new(worker_registry.acquire("fixture").unwrap());
            let result = runtime.call_download("run", &json!([url]).to_string(), Some(lease), 10_000);
            env.shutdown();
            result
        });
        first_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let partial = root.join("progressive.fixture/audio.bin.partial");
        let target = root.join("progressive.fixture/audio.bin");
        let deadline = Instant::now() + Duration::from_secs(5);
        let prefix = loop {
            if let Ok(data) = fs::read(&partial) {
                if !data.is_empty() { break data; }
            }
            assert!(Instant::now() < deadline, "partial bytes not visible");
            thread::sleep(Duration::from_millis(5));
        };
        assert_eq!(prefix, bytes[..prefix.len()]);
        assert!(prefix.len() <= 131_072);
        let mut reader = ProgressiveReader::default();
        let visible = reader.observe(&partial).unwrap();
        assert!(!visible.is_empty() && visible.len() < bytes.len());
        assert_eq!(visible, &bytes[..visible.len()]);
        assert!(!target.exists(), "target must not be committed early");
        if cancel { registry.cancel("fixture").unwrap(); }
        resume_tx.send(()).unwrap();
        let result = worker.join().unwrap();
        server.join().unwrap();
        if cancel {
            assert!(!target.exists(), "cancelled transfer must not commit");
            if let Ok(response) = result {
                let response: Value = serde_json::from_str(&response).unwrap();
                assert_ne!(response["success"], true, "cancel must not report success");
            }
        } else {
            let result: Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_eq!(result["success"], true);
            assert_eq!(reader.observe(&target).unwrap(), bytes);
        }
    }
}
