//! Experimental host-only reader. No production path constructs this type.
//! The producer must provide an already-open staged-file capability; callers
//! cannot obtain paths, URLs, tokens, or the uncommitted file from this API.

#![allow(dead_code)]

use super::progressive::{PrefixEvent, PrefixObserver};
use std::fs::File;
use std::io;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub enum ReadAtResult { Bytes(Vec<u8>), Pending, End }
#[derive(Debug)]
pub enum ReadAtError { Cancelled, Invalidated, Aborted, InvalidInput, NotAttached, Io(io::Error) }
#[derive(Debug, PartialEq, Eq)]
pub enum LeaseState { Pending, Invalidated, Committed, Aborted }
const MAX_READ: usize = 64 * 1024;
const MAX_WAIT: Duration = Duration::from_millis(1000);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Terminal { Open, Committed, Aborted }

/// Medios en claro producidos por el descifrado al vuelo. Solo en memoria (sin
/// archivo en claro en disco) y con tope; el lector lee de aqui y nunca del
/// archivo cifrado cuando existe.
pub(crate) struct ClearSpool {
    blocks: Vec<Vec<u8>>,
    len: u64,
}

const SPOOL_BLOCK: usize = 1 << 20;
const SPOOL_LIMIT: u64 = 320 * 1024 * 1024;

impl ClearSpool {
    fn new() -> Self { Self { blocks: Vec::new(), len: 0 } }
    fn len(&self) -> u64 { self.len }
    fn append(&mut self, mut data: &[u8]) -> Result<(), ()> {
        if self.len.checked_add(data.len() as u64).ok_or(())? > SPOOL_LIMIT { return Err(()); }
        while !data.is_empty() {
            if self.blocks.last().is_none_or(|block| block.len() == SPOOL_BLOCK) {
                self.blocks.push(Vec::with_capacity(SPOOL_BLOCK.min(data.len().next_power_of_two().max(4096))));
            }
            let block = self.blocks.last_mut().expect("spool block");
            let room = SPOOL_BLOCK - block.len();
            let take = room.min(data.len());
            block.extend_from_slice(&data[..take]);
            self.len += take as u64;
            data = &data[take..];
        }
        Ok(())
    }
    fn read(&self, offset: u64, count: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(count);
        let mut at = offset;
        while out.len() < count && at < self.len {
            let block = &self.blocks[(at / SPOOL_BLOCK as u64) as usize];
            let start = (at % SPOOL_BLOCK as u64) as usize;
            let take = (block.len() - start).min(count - out.len());
            out.extend_from_slice(&block[start..start + take]);
            at += take as u64;
        }
        out
    }
}

struct State {
    file: Option<File>,
    /// Si existe, es la unica fuente de bytes que ve un lease.
    spool: Option<ClearSpool>,
    generation: u64,
    available: u64,
    /// Server-announced total for the current generation, if any.
    expected: Option<u64>,
    terminal: Terminal,
}

pub(crate) struct PrefixStream {
    state: Mutex<State>,
    changed: Condvar,
}

pub struct PrefixLease {
    source: Arc<PrefixStream>,
    generation: u64,
    offset: u64,
    cancelled: Arc<std::sync::atomic::AtomicBool>,
}

pub struct LeaseCancellation {
    source: Arc<PrefixStream>,
    cancelled: Arc<std::sync::atomic::AtomicBool>,
}

impl PrefixStream {
    pub(super) fn new() -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State { file: None, spool: None, generation: 0, available: 0, expected: None, terminal: Terminal::Open }),
            changed: Condvar::new(),
        })
    }

    pub(crate) fn lease(self: &Arc<Self>) -> (PrefixLease, LeaseCancellation) {
        let generation = self.state.lock().unwrap().generation;
        let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
        (PrefixLease { source: self.clone(), generation, offset: 0, cancelled: cancelled.clone() },
         LeaseCancellation { source: self.clone(), cancelled })
    }

    pub(crate) fn close(&self) {
        let mut state = self.state.lock().unwrap();
        state.terminal = Terminal::Aborted;
        state.spool = None;
        self.changed.notify_all();
    }

    /// Publica bytes en claro contiguos (descifrado al vuelo). Debe llamarse
    /// antes de anunciar `Available` por ese tramo. Err = tope de memoria.
    pub(crate) fn append_clear(&self, data: &[u8]) -> Result<(), ()> {
        let mut state = self.state.lock().unwrap();
        if state.terminal != Terminal::Open { return Err(()); }
        state.spool.get_or_insert_with(ClearSpool::new).append(data)
    }

    /// Host-only bounded metadata read before exposing a prefix to a lease.
    pub(crate) fn inspect_staged(&self, offset: u64, len: usize) -> io::Result<Vec<u8>> {
        if len > 256 * 1024 { return Err(io::Error::new(io::ErrorKind::InvalidInput, "metadata bound exceeded")); }
        let state = self.state.lock().unwrap();
        let file = state.file.as_ref().ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "reader not attached"))?;
        let mut data = vec![0; len];
        let mut consumed = 0usize;
        while consumed < len {
            #[cfg(unix)]
            let n = { use std::os::unix::fs::FileExt; file.read_at(&mut data[consumed..], offset + consumed as u64)? };
            #[cfg(windows)]
            let n = { use std::os::windows::fs::FileExt; file.seek_read(&mut data[consumed..], offset + consumed as u64)? };
            if n == 0 { return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "metadata not yet written")); }
            consumed += n;
        }
        Ok(data)
    }
}

impl LeaseCancellation {
    pub fn cancel(&self) {
        // Hold the same lock used for the wait predicate to avoid lost wakeups.
        let _guard = self.source.state.lock().unwrap();
        self.cancelled.store(true, std::sync::atomic::Ordering::Release);
        self.source.changed.notify_all();
    }
}

impl PrefixObserver for PrefixStream {
    fn attach(&self, file: File) -> io::Result<()> {
        let mut state = self.state.lock().unwrap();
        if state.file.is_some() {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists, "reader already attached"));
        }
        state.file = Some(file);
        Ok(())
    }
    fn notify(&self, event: PrefixEvent) {
        let mut state = self.state.lock().unwrap();
        match event {
            // Con spool, nunca se anuncia mas de lo ya descifrado.
            PrefixEvent::Available { generation, bytes }
                if generation == state.generation && state.terminal == Terminal::Open && bytes >= state.available
                    && state.spool.as_ref().is_none_or(|spool| bytes <= spool.len()) => state.available = bytes,
            PrefixEvent::ExpectedLength { generation, bytes }
                if generation == state.generation && state.terminal == Terminal::Open => state.expected = Some(bytes),
            // A stale length hint is only a hint: it must never abort a lease.
            PrefixEvent::ExpectedLength { .. } => {}
            PrefixEvent::Invalidate { generation }
                if generation == state.generation && state.terminal == Terminal::Open => {
                    state.generation += 1;
                    state.available = 0;
                    state.expected = None;
                    state.spool = None;
                }
            PrefixEvent::Committed { generation, bytes }
                if generation == state.generation && state.terminal == Terminal::Open && bytes == state.available => state.terminal = Terminal::Committed,
            PrefixEvent::Aborted { generation }
                if generation == state.generation && state.terminal == Terminal::Open => state.terminal = Terminal::Aborted,
            _ => state.terminal = Terminal::Aborted,
        }
        if state.terminal == Terminal::Aborted { state.spool = None; }
        self.changed.notify_all();
    }
}

impl PrefixLease {
    /// Allows the owner to revoke a deck even when it is not currently reading.
    pub fn wait_terminal(&self, timeout: Duration) -> io::Result<LeaseState> {
        if timeout > MAX_WAIT { return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid wait bound")); }
        let deadline = Instant::now() + timeout;
        let mut state = self.source.state.lock().unwrap();
        loop {
            if self.cancelled.load(std::sync::atomic::Ordering::Acquire) {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "lease cancelled"));
            }
            if state.generation != self.generation { return Ok(LeaseState::Invalidated); }
            match state.terminal {
                Terminal::Committed => return Ok(LeaseState::Committed),
                Terminal::Aborted => return Ok(LeaseState::Aborted),
                Terminal::Open => {}
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() { return Ok(LeaseState::Pending); }
            state = self.source.changed.wait_timeout(state, remaining).unwrap().0;
        }
    }

    pub fn size(&self) -> Result<Option<u64>, ReadAtError> {
        let state = self.source.state.lock().unwrap();
        if self.cancelled.load(std::sync::atomic::Ordering::Acquire) { return Err(ReadAtError::Cancelled); }
        if state.generation != self.generation { return Err(ReadAtError::Invalidated); }
        match state.terminal {
            Terminal::Open => Ok(state.expected),
            Terminal::Committed => Ok(Some(state.available)),
            Terminal::Aborted => Err(ReadAtError::Aborted),
        }
    }

    /// Positional read; Pending is never EOF. The owner must restart the deck
    /// when a generation is invalidated, including bytes already returned.
    pub fn read_at(&self, offset: u64, max_bytes: usize, timeout: Duration) -> Result<ReadAtResult, ReadAtError> {
        if max_bytes == 0 || max_bytes > MAX_READ || timeout > MAX_WAIT {
            return Err(ReadAtError::InvalidInput);
        }
        let deadline = Instant::now() + timeout;
        let mut state = self.source.state.lock().unwrap();
        loop {
            if self.cancelled.load(std::sync::atomic::Ordering::Acquire) {
                return Err(ReadAtError::Cancelled);
            }
            if state.generation != self.generation {
                return Err(ReadAtError::Invalidated);
            }
            if state.terminal == Terminal::Aborted {
                return Err(ReadAtError::Aborted);
            }
            if offset < state.available {
                let count = (state.available - offset).min(max_bytes as u64) as usize;
                if let Some(spool) = state.spool.as_ref() {
                    let output = spool.read(offset, count);
                    if output.is_empty() { return Err(ReadAtError::Io(io::Error::new(io::ErrorKind::UnexpectedEof, "published prefix missing"))); }
                    return Ok(ReadAtResult::Bytes(output));
                }
                let file = state.file.as_ref().ok_or(ReadAtError::NotAttached)?;
                let mut output = vec![0; count];
                #[cfg(unix)]
                let n = { use std::os::unix::fs::FileExt; file.read_at(&mut output, offset).map_err(ReadAtError::Io)? };
                #[cfg(windows)]
                let n = { use std::os::windows::fs::FileExt; file.seek_read(&mut output, offset).map_err(ReadAtError::Io)? };
                if n == 0 { return Err(ReadAtError::Io(io::Error::new(io::ErrorKind::UnexpectedEof, "published prefix missing"))); }
                output.truncate(n);
                return Ok(ReadAtResult::Bytes(output));
            }
            if state.terminal == Terminal::Committed { return Ok(ReadAtResult::End); }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() { return Ok(ReadAtResult::Pending); }
            state = self.source.changed.wait_timeout(state, remaining).unwrap().0;
        }
    }

    /// Wait for bytes, final commit, invalidation, abort, or this lease's cancel.
    /// EOF is returned only after commit and after consuming the whole prefix.
    pub(super) fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if output.is_empty() { return Ok(0); }
        let mut state = self.source.state.lock().unwrap();
        loop {
            if self.cancelled.load(std::sync::atomic::Ordering::Acquire) {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "lease cancelled"));
            }
            if state.generation != self.generation {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "prefix invalidated"));
            }
            if state.terminal == Terminal::Aborted {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "transfer aborted"));
            }
            if self.offset < state.available {
                let count = (state.available - self.offset).min(output.len() as u64) as usize;
                let file = state.file.as_ref().ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "reader not attached"))?;
                #[cfg(unix)]
                let n = { use std::os::unix::fs::FileExt; file.read_at(&mut output[..count], self.offset)? };
                #[cfg(windows)]
                let n = { use std::os::windows::fs::FileExt; file.seek_read(&mut output[..count], self.offset)? };
                if n == 0 { return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "published prefix missing")); }
                self.offset += n as u64;
                return Ok(n);
            }
            if state.terminal == Terminal::Committed { return Ok(0); }
            state = self.source.changed.wait(state).unwrap();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Seek, SeekFrom, Write};
    use std::sync::mpsc;
    use std::time::{Duration, SystemTime};
    use std::io::Read;

    fn fixture() -> (std::path::PathBuf, File, Arc<PrefixStream>) {
        let stamp = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir().join(format!("progressive-{}-{stamp}", std::process::id()));
        let writer = File::create(&path).unwrap();
        let stream = PrefixStream::new();
        stream.attach(File::open(&path).unwrap()).unwrap();
        (path, writer, stream)
    }

    #[test]
    fn announced_length_is_reported_before_commit_and_reset_by_invalidation() {
        let (path, writer, stream) = fixture();
        let (lease, _) = stream.lease();
        assert_eq!(lease.size().unwrap(), None);
        stream.notify(PrefixEvent::ExpectedLength { generation: 0, bytes: 100 });
        assert_eq!(lease.size().unwrap(), Some(100));
        stream.notify(PrefixEvent::ExpectedLength { generation: 3, bytes: 7 });
        assert_eq!(lease.size().unwrap(), Some(100));
        stream.notify(PrefixEvent::Invalidate { generation: 0 });
        assert!(matches!(lease.size(), Err(ReadAtError::Invalidated)));
        let (fresh, _) = stream.lease();
        assert_eq!(fresh.size().unwrap(), None);
        stream.notify(PrefixEvent::Aborted { generation: 1 });
        assert!(matches!(fresh.size(), Err(ReadAtError::Aborted)));
        drop(lease); drop(fresh); drop(writer); drop(stream); std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn positional_reads_support_seek_pending_and_committed_size() {
        let (path, mut writer, stream) = fixture();
        writer.write_all(b"abcdef").unwrap(); writer.flush().unwrap();
        stream.notify(PrefixEvent::Available { generation: 0, bytes: 6 });
        let (lease, _) = stream.lease();
        assert_eq!(lease.size().unwrap(), None);
        assert!(matches!(lease.read_at(3, 2, Duration::ZERO).unwrap(), ReadAtResult::Bytes(b) if b == b"de"));
        assert!(matches!(lease.read_at(0, 3, Duration::ZERO).unwrap(), ReadAtResult::Bytes(b) if b == b"abc"));
        assert!(matches!(lease.read_at(6, 1, Duration::ZERO).unwrap(), ReadAtResult::Pending));
        assert!(lease.read_at(0, MAX_READ + 1, Duration::ZERO).is_err());
        assert!(lease.read_at(0, 1, MAX_WAIT + Duration::from_millis(1)).is_err());
        stream.notify(PrefixEvent::Committed { generation: 0, bytes: 6 });
        assert_eq!(lease.size().unwrap(), Some(6));
        assert!(matches!(lease.read_at(u64::MAX, 1, Duration::ZERO).unwrap(), ReadAtResult::End));
        drop(lease); drop(writer); drop(stream); std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn positional_waiters_wake_for_data_and_concurrent_cancel() {
        let (path, mut writer, stream) = fixture();
        let (lease, cancel) = stream.lease();
        let lease = Arc::new(lease);
        let waiting = lease.clone();
        let thread = std::thread::spawn(move || waiting.read_at(3, 2, MAX_WAIT));
        writer.write_all(b"abcde").unwrap(); writer.flush().unwrap();
        stream.notify(PrefixEvent::Available { generation: 0, bytes: 5 });
        assert!(matches!(thread.join().unwrap().unwrap(), ReadAtResult::Bytes(b) if b == b"de"));
        let waiting = lease.clone();
        let thread = std::thread::spawn(move || waiting.read_at(6, 1, MAX_WAIT));
        cancel.cancel();
        assert!(matches!(thread.join().unwrap(), Err(ReadAtError::Cancelled)));
        drop(cancel); drop(lease); drop(writer); drop(stream); std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn idle_deck_watcher_is_notified_on_invalidation_without_reading() {
        let (path, writer, stream) = fixture();
        let (lease, _) = stream.lease();
        let lease = Arc::new(lease);
        let waiting = lease.clone();
        let thread = std::thread::spawn(move || waiting.wait_terminal(MAX_WAIT).unwrap());
        stream.notify(PrefixEvent::Invalidate { generation: 0 });
        assert_eq!(thread.join().unwrap(), LeaseState::Invalidated);
        drop(lease); drop(writer); drop(stream); std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn waits_for_bytes_and_only_committed_end_is_eof() {
        let (path, mut writer, stream) = fixture();
        let (mut lease, _) = stream.lease();
        let (tx, rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut buf = [0; 4];
            let first = lease.read(&mut buf).unwrap();
            tx.send((first, buf)).unwrap();
            let end = lease.read(&mut buf).unwrap();
            tx.send((end, buf)).unwrap();
        });
        assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
        writer.write_all(b"abcd").unwrap(); writer.flush().unwrap();
        stream.notify(PrefixEvent::Available { generation: 0, bytes: 4 });
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap().0, 4);
        assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
        stream.notify(PrefixEvent::Committed { generation: 0, bytes: 4 });
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap().0, 0);
        worker.join().unwrap(); drop(writer); drop(stream); std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn invalidation_wakes_old_lease_and_new_lease_reads_new_generation() {
        let (path, mut writer, stream) = fixture();
        writer.write_all(b"old").unwrap(); writer.flush().unwrap();
        stream.notify(PrefixEvent::Available { generation: 0, bytes: 3 });
        let (mut old, _) = stream.lease();
        stream.notify(PrefixEvent::Invalidate { generation: 0 });
        let mut buf = [0; 3];
        assert_eq!(old.read(&mut buf).unwrap_err().kind(), io::ErrorKind::Interrupted);
        writer.set_len(0).unwrap(); writer.seek(SeekFrom::Start(0)).unwrap();
        writer.write_all(b"new").unwrap(); writer.flush().unwrap();
        stream.notify(PrefixEvent::Available { generation: 1, bytes: 3 });
        let (mut fresh, _) = stream.lease();
        assert_eq!(fresh.read(&mut buf).unwrap(), 3); assert_eq!(&buf, b"new");
        drop(fresh); drop(old); drop(writer); drop(stream); std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn real_observer_retry_invalidates_lease_and_abort_is_not_eof() {
        let (path, mut writer, stream) = fixture();
        let mut observer = super::super::progressive::Observation::new(Some(stream.clone()));
        writer.write_all(b"abc").unwrap(); writer.flush().unwrap();
        observer.available(3);
        let (mut old, _) = stream.lease();
        let mut buf = [0; 3];
        assert_eq!(old.read(&mut buf).unwrap(), 3);
        observer.invalidate();
        assert_eq!(old.read(&mut buf).unwrap_err().kind(), io::ErrorKind::Interrupted);
        writer.set_len(0).unwrap(); writer.seek(SeekFrom::Start(0)).unwrap();
        writer.write_all(b"xyz").unwrap(); writer.flush().unwrap();
        observer.available(3);
        let (mut fresh, _) = stream.lease();
        assert_eq!(fresh.read(&mut buf).unwrap(), 3); assert_eq!(&buf, b"xyz");
        drop(observer);
        assert_eq!(fresh.read(&mut buf).unwrap_err().kind(), io::ErrorKind::UnexpectedEof);
        drop(fresh); drop(old); drop(writer); drop(stream); std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn cancellation_wakes_waiter_without_marking_transfer_complete() {
        let (path, writer, stream) = fixture();
        let (mut lease, cancel) = stream.lease();
        let (tx, rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut buf = [0; 1]; tx.send(lease.read(&mut buf).unwrap_err().kind()).unwrap();
        });
        assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
        cancel.cancel();
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), io::ErrorKind::Interrupted);
        worker.join().unwrap(); drop(cancel); drop(writer); drop(stream); std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn host_download_delivers_prefix_then_handles_retry_or_cancellation() {
        use crate::download::{download, DownloadOptions};
        use crate::download::progress::ItemProgressTarget;
        use crate::files::FileRegistry;
        use crate::transfer_policy::DownloadTransferPolicy;
        use mornye_core::app_version::AppVersion;
        use mornye_core::progress::ProgressRegistry;
        use mornye_network::NetworkService;
        use std::net::TcpListener;
        use std::sync::atomic::{AtomicBool, Ordering};

        for mode in 0..3 {
            let cancel = mode == 1;
            let unknown_length = mode == 2;
            let dir = tempfile::tempdir().unwrap();
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let url = format!("http://{}/audio", listener.local_addr().unwrap());
            let (pause_tx, pause_rx) = mpsc::channel();
            let server = std::thread::spawn(move || {
                for attempt in 0..if cancel || unknown_length { 1 } else { 2 } {
                    let (mut client, _) = listener.accept().unwrap();
                    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                    let mut request = [0; 4096];
                    let _ = client.read(&mut request).unwrap();
                    if unknown_length {
                        write!(client, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n").unwrap();
                    } else {
                        write!(client, "HTTP/1.1 200 OK\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n").unwrap();
                    }
                    if attempt == 0 {
                        client.write_all(&[0x11; 4096]).unwrap();
                        client.flush().unwrap();
                        pause_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                        if unknown_length { client.write_all(&[0x22; 4096]).unwrap(); }
                    } else {
                        client.write_all(&[0x22; 8192]).unwrap();
                    }
                }
            });
            let files = Arc::new(FileRegistry::default()).extension(dir.path()).unwrap();
            let path = files.resolve("audio.bin").unwrap();
            let service = NetworkService::new().unwrap();
            service.set_allow_private_network(true);
            let network = service.native_media_session(Duration::from_secs(5));
            let stream = PrefixStream::new();
            let flag = Arc::new(AtomicBool::new(false));
            let observer = stream.clone();
            let worker_flag = flag.clone();
            let worker = std::thread::spawn(move || {
                download(&files, &path, &network, &url, DownloadOptions {
                    item: ItemProgressTarget::new(Arc::new(ProgressRegistry::new()), String::new(), false),
                    headers: Default::default(), app_version: AppVersion::default(), resume: false,
                    persistent: false, policy: DownloadTransferPolicy { max_attempts: if cancel { 1 } else { 2 }, ..Default::default() },
                    budget: None, chunk_size: None, prefix_observer: Some(observer),
                }, &|| if worker_flag.load(Ordering::Acquire) { Err("cancelled".into()) } else { Ok(()) },
                &|_| Ok(()), &mut |_, _| {})
            });
            let (mut old, _) = stream.lease();
            let mut buf = [0; 4096];
            let n = old.read(&mut buf).unwrap();
            assert!(n > 0 && buf[..n].iter().all(|byte| *byte == 0x11));
            assert!(!dir.path().join("audio.bin").exists());
            if cancel { flag.store(true, Ordering::Release); }
            pause_tx.send(()).unwrap();
            let result = worker.join().unwrap();
            server.join().unwrap();
            if cancel {
                assert!(result.is_err());
                assert_eq!(old.read(&mut buf).unwrap_err().kind(), io::ErrorKind::UnexpectedEof);
                assert!(!dir.path().join("audio.bin").exists());
            } else if unknown_length {
                assert!(result.is_ok());
                let mut received = buf[..n].to_vec();
                loop { let n = old.read(&mut buf).unwrap(); if n == 0 { break; } received.extend_from_slice(&buf[..n]); }
                let mut expected = vec![0x11; 4096]; expected.extend_from_slice(&[0x22; 4096]);
                assert_eq!(received, expected);
                assert_eq!(std::fs::read(dir.path().join("audio.bin")).unwrap(), expected);
            } else {
                assert!(result.is_ok());
                assert_eq!(old.read(&mut buf).unwrap_err().kind(), io::ErrorKind::Interrupted);
                let (mut fresh, _) = stream.lease();
                let mut received = Vec::new();
                loop { let n = fresh.read(&mut buf).unwrap(); if n == 0 { break; } received.extend_from_slice(&buf[..n]); }
                assert_eq!(received, vec![0x22; 8192]);
                assert_eq!(std::fs::read(dir.path().join("audio.bin")).unwrap(), received);
            }
        }
    }
}

