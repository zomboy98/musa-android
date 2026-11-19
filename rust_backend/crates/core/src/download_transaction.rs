//! Unwired coordination primitive for a single private download attempt.
//!
//! The owner must stop and join every producer before calling `producer_stopped`,
//! keep the validated artifact immutable, and implement rollback and crash
//! recovery. This primitive neither owns files nor proves those obligations.

use std::sync::Mutex;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum State {
    Created,
    Producing,
    Ready,
    Validated,
    Cancelling,
    Cancelled,
    Failed,
    Committed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransactionError {
    InvalidState,
    Poisoned,
}

#[derive(Debug, Eq, PartialEq)]
pub enum OperationError<E> {
    State(TransactionError),
    Operation(E),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Cancellation {
    /// No new commit can begin. Cleanup still requires `cleanup_allowed`.
    Accepted,
    /// Publication already completed; the output must be preserved.
    AlreadyCommitted,
}

/// Serializes cancellation with validation and the actual publication operation.
/// Callbacks must not re-enter this coordinator. The commit callback must itself
/// provide the destination's atomic no-replace and rollback guarantees.
pub struct DownloadTransaction {
    state: Mutex<State>,
}

impl Default for DownloadTransaction {
    fn default() -> Self {
        Self { state: Mutex::new(State::Created) }
    }
}

impl DownloadTransaction {
    pub fn start_producer(&self) -> Result<(), TransactionError> {
        let mut state = self.state.lock().map_err(|_| TransactionError::Poisoned)?;
        if *state != State::Created { return Err(TransactionError::InvalidState); }
        *state = State::Producing;
        Ok(())
    }

    /// Call only after the producer's completion has been acknowledged and joined.
    pub fn producer_stopped(&self, success: bool) -> Result<(), TransactionError> {
        let mut state = self.state.lock().map_err(|_| TransactionError::Poisoned)?;
        *state = match *state {
            State::Producing if success => State::Ready,
            State::Producing => State::Failed,
            State::Cancelling => State::Cancelled,
            _ => return Err(TransactionError::InvalidState),
        };
        Ok(())
    }

    /// The callback must probe and enforce the requested quality on the actual
    /// final bytes. A failed probe permanently rejects this attempt.
    pub fn validate<E>(&self, probe: impl FnOnce() -> Result<(), E>) -> Result<(), OperationError<E>> {
        let mut state = self.state.lock().map_err(|_| OperationError::State(TransactionError::Poisoned))?;
        if *state != State::Ready { return Err(OperationError::State(TransactionError::InvalidState)); }
        match probe() {
            Ok(()) => { *state = State::Validated; Ok(()) }
            Err(error) => { *state = State::Failed; Err(OperationError::Operation(error)) }
        }
    }

    /// The callback is the publication linearization operation, not a scheduling
    /// request. It must return success only after the destination is committed.
    /// On failure it must leave any existing destination intact.
    pub fn commit<E>(&self, publish: impl FnOnce() -> Result<(), E>) -> Result<(), OperationError<E>> {
        let mut state = self.state.lock().map_err(|_| OperationError::State(TransactionError::Poisoned))?;
        if *state != State::Validated { return Err(OperationError::State(TransactionError::InvalidState)); }
        publish().map_err(OperationError::Operation)?;
        *state = State::Committed;
        Ok(())
    }

    /// The caller must separately signal the live producer to stop.
    pub fn cancel(&self) -> Result<Cancellation, TransactionError> {
        let mut state = self.state.lock().map_err(|_| TransactionError::Poisoned)?;
        match *state {
            State::Committed => Ok(Cancellation::AlreadyCommitted),
            State::Producing => { *state = State::Cancelling; Ok(Cancellation::Accepted) }
            State::Cancelling | State::Cancelled => Ok(Cancellation::Accepted),
            State::Created | State::Ready | State::Validated | State::Failed => {
                *state = State::Cancelled;
                Ok(Cancellation::Accepted)
            }
        }
    }

    /// True only after every registered producer has acknowledged termination,
    /// or after successful commit. This does not perform or acknowledge cleanup.
    pub fn cleanup_allowed(&self) -> Result<bool, TransactionError> {
        let state = self.state.lock().map_err(|_| TransactionError::Poisoned)?;
        Ok(matches!(*state, State::Cancelled | State::Failed | State::Committed))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, mpsc};
    use std::thread;

    #[test]
    fn cannot_publish_before_successful_probe_or_after_failed_probe() {
        let tx = DownloadTransaction::default();
        assert_eq!(tx.commit(|| Ok::<_, ()>(())), Err(OperationError::State(TransactionError::InvalidState)));
        tx.start_producer().unwrap();
        tx.producer_stopped(true).unwrap();
        assert_eq!(tx.validate(|| Err("wrong codec")), Err(OperationError::Operation("wrong codec")));
        assert_eq!(tx.commit(|| panic!("must not publish")), Err(OperationError::<()>::State(TransactionError::InvalidState)));
        assert!(tx.cleanup_allowed().unwrap());
    }

    #[test]
    fn cancellation_requires_producer_ack_before_cleanup() {
        let tx = DownloadTransaction::default();
        tx.start_producer().unwrap();
        assert_eq!(tx.cancel().unwrap(), Cancellation::Accepted);
        assert!(!tx.cleanup_allowed().unwrap());
        assert_eq!(tx.validate(|| Ok::<_, ()>(())), Err(OperationError::State(TransactionError::InvalidState)));
        tx.producer_stopped(true).unwrap();
        assert!(tx.cleanup_allowed().unwrap());
        assert_eq!(tx.commit(|| Ok::<_, ()>(())), Err(OperationError::State(TransactionError::InvalidState)));
    }

    #[test]
    fn failed_commit_can_be_cancelled_without_claiming_publication() {
        let tx = DownloadTransaction::default();
        tx.start_producer().unwrap();
        tx.producer_stopped(true).unwrap();
        tx.validate(|| Ok::<_, ()>(())).unwrap();
        assert_eq!(tx.commit(|| Err("collision")), Err(OperationError::Operation("collision")));
        assert_eq!(tx.cancel().unwrap(), Cancellation::Accepted);
        assert!(tx.cleanup_allowed().unwrap());
    }

    #[test]
    fn cancellation_after_validation_prevents_commit() {
        let tx = DownloadTransaction::default();
        tx.start_producer().unwrap();
        tx.producer_stopped(true).unwrap();
        tx.validate(|| Ok::<_, ()>(())).unwrap();
        assert_eq!(tx.cancel().unwrap(), Cancellation::Accepted);
        assert_eq!(tx.commit(|| panic!("must not publish")), Err(OperationError::<()>::State(TransactionError::InvalidState)));
        assert!(tx.cleanup_allowed().unwrap());
    }

    #[test]
    fn commit_and_cancellation_have_one_order() {
        let tx = Arc::new(DownloadTransaction::default());
        tx.start_producer().unwrap();
        tx.producer_stopped(true).unwrap();
        tx.validate(|| Ok::<_, ()>(())).unwrap();
        let (entered, wait) = mpsc::channel();
        let (release, resume) = mpsc::channel();
        let publisher = Arc::clone(&tx);
        let worker = thread::spawn(move || publisher.commit(|| {
            entered.send(()).unwrap();
            resume.recv().unwrap();
            Ok::<_, ()>(())
        }));
        wait.recv().unwrap();
        let canceller = Arc::clone(&tx);
        let cancel = thread::spawn(move || canceller.cancel().unwrap());
        release.send(()).unwrap();
        worker.join().unwrap().unwrap();
        assert_eq!(cancel.join().unwrap(), Cancellation::AlreadyCommitted);
        assert!(tx.cleanup_allowed().unwrap());
    }
}
