//! Internal opt-in notifications for sequential downloads; no app consumer yet.
//!
//! Available counts a contiguous prefix already written to the owned staged
//! file. Observers do not receive URLs, paths, bytes, or ownership of that file.
//! Invalidate is synchronous and precedes truncation/restart. A future reader
//! must stop using the old generation before this callback returns. Commit is
//! emitted only after publication; dropping any other attempt emits Aborted.
//! Counts do not establish audio decodability or integrity of the whole file.

use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PrefixEvent {
    Available { generation: u64, bytes: u64 },
    /// Total size announced by the server for this generation (Content-Length).
    /// A hint for readers; it is never proof that the bytes are complete.
    ExpectedLength { generation: u64, bytes: u64 },
    Invalidate { generation: u64 },
    Committed { generation: u64, bytes: u64 },
    Aborted { generation: u64 },
}

pub(crate) trait PrefixObserver: Send + Sync {
    fn notify(&self, event: PrefixEvent);
    #[cfg(feature = "experimental-progressive-reader")]
    fn attach(&self, _file: std::fs::File) -> std::io::Result<()> { Ok(()) }
}

pub(super) struct Observation {
    observer: Option<Arc<dyn PrefixObserver>>,
    generation: u64,
    committed: bool,
}

impl Observation {
    pub(super) fn new(observer: Option<Arc<dyn PrefixObserver>>) -> Self {
        Self { observer, generation: 0, committed: false }
    }
    pub(super) fn enabled(&self) -> bool { self.observer.is_some() }
    #[cfg(feature = "experimental-progressive-reader")]
    pub(super) fn attach(&self, file: std::fs::File) -> std::io::Result<()> {
        if let Some(observer) = &self.observer {
            observer.attach(file)?;
        }
        Ok(())
    }
    pub(super) fn available(&self, bytes: u64) {
        if let Some(observer) = &self.observer {
            observer.notify(PrefixEvent::Available { generation: self.generation, bytes });
        }
    }
    pub(super) fn expected_length(&self, bytes: u64) {
        if let Some(observer) = &self.observer {
            observer.notify(PrefixEvent::ExpectedLength { generation: self.generation, bytes });
        }
    }
    pub(super) fn invalidate(&mut self) {
        if let Some(observer) = &self.observer {
            observer.notify(PrefixEvent::Invalidate { generation: self.generation });
        }
        self.generation = self.generation.saturating_add(1);
    }
    pub(super) fn committed(&mut self, bytes: u64) {
        if let Some(observer) = &self.observer {
            observer.notify(PrefixEvent::Committed { generation: self.generation, bytes });
        }
        self.committed = true;
    }
}

impl Drop for Observation {
    fn drop(&mut self) {
        if !self.committed {
            if let Some(observer) = &self.observer {
                observer.notify(PrefixEvent::Aborted { generation: self.generation });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::time::Duration;
    use crate::download::{download, DownloadOptions};
    use crate::download::progress::ItemProgressTarget;
    use crate::files::FileRegistry;
    use crate::transfer_policy::DownloadTransferPolicy;
    use mornye_core::app_version::AppVersion;
    use mornye_core::progress::ProgressRegistry;
    use mornye_network::NetworkService;

    #[derive(Default)]
    struct Recorder(Mutex<Vec<PrefixEvent>>);
    impl PrefixObserver for Recorder {
        fn notify(&self, event: PrefixEvent) { self.0.lock().unwrap().push(event); }
    }

    #[test]
    fn retry_revokes_old_prefix_before_new_generation_and_commit() {
        let recorder = Arc::new(Recorder::default());
        let mut stream = Observation::new(Some(recorder.clone()));
        stream.available(4);
        stream.invalidate();
        stream.available(2);
        stream.available(8);
        stream.committed(8);
        drop(stream);
        assert_eq!(*recorder.0.lock().unwrap(), vec![
            PrefixEvent::Available { generation: 0, bytes: 4 },
            PrefixEvent::Invalidate { generation: 0 },
            PrefixEvent::Available { generation: 1, bytes: 2 },
            PrefixEvent::Available { generation: 1, bytes: 8 },
            PrefixEvent::Committed { generation: 1, bytes: 8 },
        ]);
    }

    #[test]
    fn cancelled_or_failed_attempt_notifies_abort_without_commit() {
        let recorder = Arc::new(Recorder::default());
        { let stream = Observation::new(Some(recorder.clone())); stream.available(12); }
        assert_eq!(*recorder.0.lock().unwrap(), vec![
            PrefixEvent::Available { generation: 0, bytes: 12 },
            PrefixEvent::Aborted { generation: 0 },
        ]);
    }

    struct Capture {
        events: Mutex<Vec<PrefixEvent>>,
        partial: std::path::PathBuf,
        expected: Vec<u8>,
        cancel: AtomicBool,
        cancel_on_data: bool,
    }
    impl PrefixObserver for Capture {
        fn notify(&self, event: PrefixEvent) {
            if let PrefixEvent::Available { bytes, .. } = event {
                if bytes > 0 {
                    let data = std::fs::read(&self.partial).unwrap();
                    assert_eq!(&data[..bytes as usize], &self.expected[..bytes as usize]);
                    if self.cancel_on_data { self.cancel.store(true, Ordering::Release); }
                }
            }
            self.events.lock().unwrap().push(event);
        }
    }

    fn transfer_fixture(cancel: bool) -> Vec<PrefixEvent> {
        let temp = tempfile::tempdir().unwrap();
        let body: Vec<u8> = (0..32_768).map(|i| (i % 251) as u8).collect();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/audio", listener.local_addr().unwrap());
        let outgoing = body.clone();
        let server = std::thread::spawn(move || {
            for attempt in 0..if cancel { 1 } else { 2 } {
                let (mut connection, _) = listener.accept().unwrap();
                connection.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut request = [0; 4096];
                let _ = connection.read(&mut request).unwrap();
                write!(connection, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", outgoing.len()).unwrap();
                let amount = if attempt == 0 { 4096 } else { outgoing.len() };
                let _ = connection.write_all(&outgoing[..amount]);
                if cancel { std::thread::sleep(Duration::from_millis(100)); }
            }
        });
        let registry = Arc::new(FileRegistry::default());
        let files = registry.extension(temp.path()).unwrap();
        let path = files.resolve("audio.bin").unwrap();
        let service = NetworkService::new().unwrap();
        service.set_allow_private_network(true);
        let network = service.native_media_session(Duration::from_secs(5));
        let observer = Arc::new(Capture {
            events: Mutex::new(Vec::new()), partial: temp.path().join("audio.bin.partial"),
            expected: body.clone(), cancel: AtomicBool::new(false), cancel_on_data: cancel,
        });
        let policy = DownloadTransferPolicy { max_attempts: if cancel { 1 } else { 2 }, ..Default::default() };
        let result = download(&files, &path, &network, &url, DownloadOptions {
            item: ItemProgressTarget::new(Arc::new(ProgressRegistry::new()), String::new(), false),
            headers: Default::default(), app_version: AppVersion::default(), resume: false,
            persistent: false, policy, budget: None, chunk_size: None,
            prefix_observer: Some(observer.clone()),
        }, &|| if observer.cancel.load(Ordering::Acquire) { Err("cancelled".into()) } else { Ok(()) },
        &|_| Ok(()), &mut |_, _| {});
        server.join().unwrap();
        if cancel {
            assert!(result.is_err());
            assert!(!temp.path().join("audio.bin").exists());
        } else {
            assert!(result.is_ok());
            assert_eq!(std::fs::read(temp.path().join("audio.bin")).unwrap(), body);
        }
        let events = observer.events.lock().unwrap().clone();
        events
    }

    #[test]
    fn real_retry_revokes_prefix_and_commits_contiguous_bytes() {
        let events = transfer_fixture(false);
        let invalidated = events.iter().position(|event| *event == PrefixEvent::Invalidate { generation: 0 }).unwrap();
        assert!(events[..invalidated].iter().any(|event| matches!(event, PrefixEvent::Available { generation: 0, bytes } if *bytes > 0)));
        assert!(events[invalidated + 1..].iter().any(|event| matches!(event, PrefixEvent::Available { generation: 1, bytes } if *bytes > 0)));
        assert!(matches!(events.last(), Some(PrefixEvent::Committed { generation: 1, bytes: 32768 })));
    }

    #[test]
    fn real_cancellation_aborts_without_publishing() {
        let events = transfer_fixture(true);
        assert!(matches!(events.last(), Some(PrefixEvent::Aborted { .. })));
        assert!(!events.iter().any(|event| matches!(event, PrefixEvent::Committed { .. })));
    }
}
