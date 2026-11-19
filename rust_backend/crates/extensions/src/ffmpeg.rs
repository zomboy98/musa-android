//! Commands executed by the native FFmpeg pump, scoped to one environment.

use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

static NEXT_COMMAND: AtomicU64 = AtomicU64::new(0);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(300);

pub(crate) const UNCONFIRMED_PRODUCER_MARKER: &str = ".mornye-external-producer-unconfirmed";

/// Attempt owner retained by each dispatched producer until its typed ack.
pub(crate) struct DownloadStaging {
    path: PathBuf,
    owner: Arc<AttemptOwner>,
    registry: Arc<CommandRegistry>,
}

struct AttemptLifetime {
    directory: Option<tempfile::TempDir>,
    pending: usize,
    finished: bool,
}

struct AttemptOwner {
    lifetime: Mutex<AttemptLifetime>,
}

impl AttemptOwner {
    fn producer_started(&self) -> std::io::Result<()> {
        let mut life = self.lifetime.lock().expect("attempt lifetime lock");
        if life.pending == 0 {
            let directory = life.directory.as_ref().expect("live attempt");
            // Never truncate/follow a provider-created marker or symlink.
            let marker = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(directory.path().join(UNCONFIRMED_PRODUCER_MARKER))?;
            marker.sync_all()?;
        }
        life.pending += 1;
        Ok(())
    }

    fn producer_stopped(&self) {
        let mut life = self.lifetime.lock().expect("attempt lifetime lock");
        assert!(life.pending > 0, "producer ack without registration");
        life.pending -= 1;
        if life.pending == 0 {
            if let Some(directory) = &life.directory {
                let _ = std::fs::remove_file(directory.path().join(UNCONFIRMED_PRODUCER_MARKER));
            }
            if life.finished {
                life.directory.take();
            }
        }
    }

    fn finish(&self) {
        let mut life = self.lifetime.lock().expect("attempt lifetime lock");
        life.finished = true;
        if life.pending == 0 {
            life.directory.take();
        }
    }
}

impl Drop for AttemptOwner {
    fn drop(&mut self) {
        let life = self.lifetime.get_mut().expect("attempt lifetime lock");
        if life.pending != 0 {
            if let Some(directory) = life.directory.take() {
                let _ = directory.keep();
            }
        }
    }
}

/// Only the native producer owner may issue these terminal events. Generic
/// command success/failure, cancellation or timeout is never an acknowledgement.
#[derive(Clone, Copy, Debug)]
pub enum ProducerTerminal {
    NotStarted,
    Stopped,
}

impl DownloadStaging {
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    #[cfg(feature = "experimental-private-mov")]
    pub(crate) fn begin_private_producer(&self) -> std::io::Result<PrivateProducer> {
        self.owner.producer_started()?;
        Ok(PrivateProducer {
            owner: Arc::clone(&self.owner),
            acknowledged: std::sync::atomic::AtomicBool::new(false),
        })
    }
}

#[cfg(feature = "experimental-private-mov")]
pub(crate) struct PrivateProducer {
    owner: Arc<AttemptOwner>,
    acknowledged: std::sync::atomic::AtomicBool,
}

#[cfg(feature = "experimental-private-mov")]
impl PrivateProducer {
    pub(crate) fn acknowledge(&self) {
        if !self.acknowledged.swap(true, Ordering::AcqRel) {
            self.owner.producer_stopped();
        }
    }
}

impl Drop for DownloadStaging {
    fn drop(&mut self) {
        // Claiming a producer and retiring its attempt use one lock. Otherwise
        // a claim could race between our flag check and TempDir's deletion.
        let mut state = self.registry.state.lock().expect("FFmpeg state lock");
        state.attempts.remove(self.path());
        drop(state);
        self.owner.finish();
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Command {
    pub command_id: String,
    pub extension_id: String,
    pub arguments: Vec<String>,
    pub input_path: String,
    pub output_path: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct CommandResult {
    pub success: bool,
    pub output: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
}

struct Entry {
    command: Command,
    claimed: bool,
    result: Option<CommandResult>,
    waiter: std::thread::Thread,
}

#[derive(Default)]
struct State {
    commands: BTreeMap<String, Entry>,
    attempts: BTreeMap<PathBuf, (String, Weak<AttemptOwner>)>,
    producers: BTreeMap<String, Vec<Arc<AttemptOwner>>>,
    typed_producer_lifetime: bool,
    closed: bool,
}

#[derive(Default)]
pub struct CommandRegistry {
    state: Mutex<State>,
    changed: Condvar,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
#[error("FFmpeg command registry closed")]
pub struct RegistryClosed;

impl CommandRegistry {
    /// Host capability negotiation: legacy pumps remain on their original path
    /// rather than silently accumulating every successful download forever.
    pub fn enable_typed_producer_lifetime(&self) -> Result<(), RegistryClosed> {
        let mut state = self.state.lock().expect("FFmpeg state lock");
        state.check()?;
        state.typed_producer_lifetime = true;
        Ok(())
    }

    /// Late acknowledgements remain valid after caller cancellation/shutdown.
    pub fn acknowledge_producer_termination(&self, id: &str, _terminal: ProducerTerminal) -> bool {
        let producers = self
            .state
            .lock()
            .expect("FFmpeg state lock")
            .producers
            .remove(id);
        let Some(producers) = producers else {
            return false;
        };
        for owner in producers {
            owner.producer_stopped();
        }
        true
    }

    pub(crate) fn protect_download_staging(
        self: &Arc<Self>,
        extension_id: &str,
        directory: tempfile::TempDir,
    ) -> Result<DownloadStaging, RegistryClosed> {
        let mut state = self.state.lock().expect("FFmpeg state lock");
        state.check()?;
        state
            .attempts
            .retain(|_, (_, owner)| owner.strong_count() > 0);
        let path = directory.path().to_owned();
        let owner = Arc::new(AttemptOwner {
            lifetime: Mutex::new(AttemptLifetime {
                directory: Some(directory),
                pending: 0,
                finished: false,
            }),
        });
        if state.typed_producer_lifetime {
            state
                .attempts
                .insert(path.clone(), (extension_id.into(), Arc::downgrade(&owner)));
        }
        Ok(DownloadStaging {
            path,
            owner,
            registry: Arc::clone(self),
        })
    }
    pub fn get(&self, id: &str) -> Result<Option<Command>, RegistryClosed> {
        let state = self.state.lock().expect("FFmpeg state lock");
        state.check()?;
        Ok(state.commands.get(id).map(|entry| entry.command.clone()))
    }

    /// Claims each command at most once, even with multiple native pumps.
    /// A zero/negative timeout performs a nonblocking claim. Shutdown wakes waits.
    pub fn wait_pending_json(&self, timeout_ms: i64) -> Result<String, RegistryClosed> {
        let started = Instant::now();
        let timeout = Duration::from_millis(timeout_ms.clamp(0, 60_000) as u64);
        let mut state = self.state.lock().expect("FFmpeg state lock");
        loop {
            state.check()?;
            let commands = state.claim_pending();
            let remaining = timeout.saturating_sub(started.elapsed());
            if commands != "[]" || remaining.is_zero() {
                return Ok(commands);
            }
            state = self
                .changed
                .wait_timeout(state, remaining)
                .expect("FFmpeg pending wait")
                .0;
        }
    }

    /// Late or duplicate results cannot complete another command or revive one
    /// removed by cancellation. The native pump can use get() to stop such work.
    pub fn complete(&self, id: &str, result: CommandResult) -> Result<bool, RegistryClosed> {
        let mut state = self.state.lock().expect("FFmpeg state lock");
        state.check()?;
        let Some(entry) = state.commands.get_mut(id) else {
            return Ok(false);
        };
        if entry.result.is_some() {
            return Ok(false);
        }
        entry.result = Some(result);
        entry.waiter.unpark();
        self.changed.notify_all();
        Ok(true)
    }

    pub fn shutdown(&self) {
        let mut state = self.state.lock().expect("FFmpeg state lock");
        state.closed = true;
        for entry in state.commands.values() {
            entry.waiter.unpark();
        }
        state.commands.clear();
        self.changed.notify_all();
    }

    pub(crate) fn execute(
        &self,
        extension_id: &str,
        arguments: Vec<String>,
        input_path: String,
        output_path: String,
        control: &crate::runtime::Control,
    ) -> Result<CommandResult, String> {
        let _wait = control.watch_thread();
        let check = || control.check().map_err(|error| error.to_string());
        check()?;
        let sequence = NEXT_COMMAND.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        let id = format!("{extension_id}_{sequence}");
        let command = Command {
            command_id: id.clone(),
            extension_id: extension_id.into(),
            arguments,
            input_path,
            output_path,
        };
        {
            let mut state = self.state.lock().expect("FFmpeg state lock");
            state.check().map_err(|e| e.to_string())?;
            state.commands.insert(
                id.clone(),
                Entry {
                    command,
                    claimed: false,
                    result: None,
                    waiter: std::thread::current(),
                },
            );
            self.changed.notify_all();
        }
        let _pending = Pending {
            registry: self,
            id: &id,
        };
        let started = Instant::now();
        let mut state = self.state.lock().expect("FFmpeg state lock");
        loop {
            check().map_err(|e| format!("FFmpeg command cancelled: {e}"))?;
            state.check().map_err(|e| e.to_string())?;
            if state
                .commands
                .get(&id)
                .is_some_and(|entry| entry.result.is_some())
            {
                return Ok(state
                    .commands
                    .remove(&id)
                    .expect("completed FFmpeg command")
                    .result
                    .expect("FFmpeg result"));
            }
            let remaining = COMMAND_TIMEOUT.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return Err("FFmpeg command timed out".into());
            }
            drop(state);
            std::thread::park_timeout(remaining.min(control.deadline_remaining()));
            state = self.state.lock().expect("FFmpeg state lock");
        }
    }
}

impl State {
    fn check(&self) -> Result<(), RegistryClosed> {
        if self.closed {
            Err(RegistryClosed)
        } else {
            Ok(())
        }
    }

    fn claim_pending(&mut self) -> String {
        #[derive(Serialize)]
        struct PendingCommand<'a> {
            command_id: &'a str,
            extension_id: &'a str,
            arguments: &'a [String],
            output_path: &'a str,
        }
        self.attempts
            .retain(|_, (_, owner)| owner.strong_count() > 0);
        let attempts = &self.attempts;
        let producers = &mut self.producers;
        let typed_producer_lifetime = self.typed_producer_lifetime;
        let pending: Vec<_> = self
            .commands
            .values_mut()
            .filter(|entry| !entry.claimed && entry.result.is_none())
            .filter_map(|entry| {
                let mut owners: Vec<Arc<AttemptOwner>> = Vec::new();
                for (_, (extension_id, owner)) in attempts {
                    if extension_id != &entry.command.extension_id {
                        continue;
                    }
                    let Some(owner) = owner.upgrade() else {
                        continue;
                    };
                    // Persist before allowing the pump to start. Marker failure
                    // rejects dispatch, so no untracked producer can be launched.
                    if owner.producer_started().is_err() {
                        for owner in owners {
                            AttemptOwner::producer_stopped(&owner);
                        }
                        entry.result = Some(CommandResult {
                            success: false,
                            output: String::new(),
                            error: "could not retain native producer staging".into(),
                        });
                        entry.waiter.unpark();
                        return None;
                    }
                    owners.push(owner);
                }
                if typed_producer_lifetime {
                    producers.insert(entry.command.command_id.clone(), owners);
                }
                entry.claimed = true;
                Some(PendingCommand {
                    command_id: &entry.command.command_id,
                    extension_id: &entry.command.extension_id,
                    arguments: &entry.command.arguments,
                    output_path: &entry.command.output_path,
                })
            })
            .collect();
        serde_json::to_string(&pending).expect("FFmpeg pending JSON")
    }
}

struct Pending<'a> {
    registry: &'a CommandRegistry,
    id: &'a str,
}

impl Drop for Pending<'_> {
    fn drop(&mut self) {
        self.registry
            .state
            .lock()
            .expect("FFmpeg state lock")
            .commands
            .remove(self.id);
        self.registry.changed.notify_all();
    }
}

impl Drop for CommandRegistry {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod lifetime_tests {
    use super::*;

    fn queue(registry: &CommandRegistry, id: &str) {
        registry.state.lock().unwrap().commands.insert(
            id.into(),
            Entry {
                command: Command {
                    command_id: id.into(),
                    extension_id: "fixture".into(),
                    arguments: vec!["fixture".into()],
                    input_path: String::new(),
                    output_path: String::new(),
                },
                claimed: false,
                result: None,
                waiter: std::thread::current(),
            },
        );
    }

    fn setup() -> (Arc<CommandRegistry>, DownloadStaging, PathBuf) {
        let registry = Arc::new(CommandRegistry::default());
        registry.enable_typed_producer_lifetime().unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_owned();
        std::fs::write(path.join("input.flac"), b"private source").unwrap();
        let owner = registry
            .protect_download_staging("fixture", directory)
            .unwrap();
        (registry, owner, path)
    }

    #[test]
    fn cancellation_and_generic_result_do_not_release_missing_callback() {
        let (registry, owner, path) = setup();
        queue(&registry, "one");
        assert!(registry.wait_pending_json(0).unwrap().contains("one"));
        assert!(path.join(UNCONFIRMED_PRODUCER_MARKER).exists());
        assert!(
            registry
                .complete(
                    "one",
                    CommandResult {
                        success: false,
                        output: String::new(),
                        error: "timeout".into()
                    }
                )
                .unwrap()
        );
        registry.state.lock().unwrap().commands.remove("one");
        drop(owner);
        assert_eq!(
            std::fs::read(path.join("input.flac")).unwrap(),
            b"private source"
        );
        assert!(registry.acknowledge_producer_termination("one", ProducerTerminal::Stopped));
        assert!(!path.exists());
        assert!(!registry.acknowledge_producer_termination("one", ProducerTerminal::Stopped));
    }

    #[test]
    fn all_claimed_producers_must_ack_before_cleanup() {
        let (registry, owner, path) = setup();
        queue(&registry, "one");
        queue(&registry, "two");
        let claimed: Vec<serde_json::Value> =
            serde_json::from_str(&registry.wait_pending_json(0).unwrap()).unwrap();
        assert_eq!(claimed.len(), 2);
        drop(owner);
        assert!(registry.acknowledge_producer_termination("two", ProducerTerminal::NotStarted));
        assert!(path.exists());
        assert!(path.join(UNCONFIRMED_PRODUCER_MARKER).exists());
        assert!(registry.acknowledge_producer_termination("one", ProducerTerminal::Stopped));
        assert!(!path.exists());
    }

    #[test]
    fn successful_ack_retains_live_attempt_then_cleans_normally() {
        let (registry, owner, path) = setup();
        queue(&registry, "success");
        registry.wait_pending_json(0).unwrap();
        registry.acknowledge_producer_termination("success", ProducerTerminal::Stopped);
        assert!(path.exists());
        assert!(!path.join(UNCONFIRMED_PRODUCER_MARKER).exists());
        drop(owner);
        assert!(!path.exists());
        assert!(registry.state.lock().unwrap().producers.is_empty());
    }

    #[test]
    fn late_ack_after_shutdown_still_releases_attempt() {
        let (registry, owner, path) = setup();
        queue(&registry, "late");
        registry.wait_pending_json(0).unwrap();
        registry.shutdown();
        drop(owner);
        assert!(path.exists());
        assert!(registry.acknowledge_producer_termination("late", ProducerTerminal::Stopped));
        assert!(!path.exists());
    }

    #[test]
    fn lost_registry_preserves_unknown_producer_and_excludes_retry_sweep() {
        let (registry, owner, path) = setup();
        queue(&registry, "lost");
        registry.wait_pending_json(0).unwrap();
        drop(owner);
        drop(registry);
        assert!(path.exists());
        assert!(path.join(UNCONFIRMED_PRODUCER_MARKER).exists());
        // Fixture has no native producer; reclaim only after that fact is known.
        std::fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn removing_marker_cannot_make_live_producer_reclaimable() {
        let (registry, owner, path) = setup();
        queue(&registry, "live");
        registry.wait_pending_json(0).unwrap();
        drop(owner);
        std::fs::remove_file(path.join(UNCONFIRMED_PRODUCER_MARKER)).unwrap();
        assert!(path.join("input.flac").exists());
        registry.acknowledge_producer_termination("live", ProducerTerminal::Stopped);
        assert!(!path.exists());
    }

    #[test]
    fn provider_marker_collision_rejects_dispatch_without_truncating_it() {
        let (registry, owner, path) = setup();
        let marker = path.join(UNCONFIRMED_PRODUCER_MARKER);
        std::fs::write(&marker, b"provider file").unwrap();
        queue(&registry, "collision");
        assert_eq!(registry.wait_pending_json(0).unwrap(), "[]");
        assert_eq!(std::fs::read(&marker).unwrap(), b"provider file");
        let state = registry.state.lock().unwrap();
        assert!(!state.commands["collision"].claimed);
        assert!(!state.commands["collision"].result.as_ref().unwrap().success);
        assert!(state.producers.is_empty());
        drop(state);
        drop(owner);
        assert!(!path.exists());
    }

    #[test]
    fn legacy_pump_does_not_accumulate_successful_attempts() {
        let registry = Arc::new(CommandRegistry::default());
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_owned();
        let owner = registry
            .protect_download_staging("fixture", directory)
            .unwrap();
        queue(&registry, "legacy");
        registry.wait_pending_json(0).unwrap();
        assert!(registry.state.lock().unwrap().producers.is_empty());
        drop(owner);
        assert!(!path.exists());
    }
}
