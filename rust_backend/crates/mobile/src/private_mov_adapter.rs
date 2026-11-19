//! Opt-in adapter for the synchronous private MOV primitive. Nothing is
//! registered automatically. The optional Android loader is test-only and
//! requires a trusted host to attest the library's origin and isolation.
#![allow(unsafe_code)]

use mornye_extensions::backend::{PrivateFinalizationError, PrivateMovFinalizer, PrivateMovJob};
use mornye_extensions::ffmpeg::ProducerTerminal;
use std::ffi::{CString, c_char, c_int, c_void};
use std::os::unix::ffi::OsStrExt;
use std::sync::Arc;

type Cancel = unsafe extern "C" fn(*mut c_void) -> c_int;
type Terminal = unsafe extern "C" fn(*mut c_void, c_int);
pub type PrivateMovEntry = unsafe extern "C" fn(
    *const c_char,
    *const c_char,
    *const u8,
    usize,
    Option<Cancel>,
    Option<Terminal>,
    *mut c_void,
) -> c_int;

/// An explicitly supplied native entry point. This does not load FFmpegKit.
pub struct NativePrivateMovFinalizer {
    entry: PrivateMovEntry,
    #[cfg(all(
        target_os = "android",
        feature = "experimental-private-mov-loader-test"
    ))]
    _library: Option<PrivateLibrary>,
}

impl NativePrivateMovFinalizer {
    /// # Safety
    /// `entry` must obey private_mov.h, run synchronously, close all resources
    /// before its terminal callback, invoke callbacks serially only during the call,
    /// and use isolated libav symbols from matching private headers and archives.
    /// Its library must remain loaded for the adapter's entire lifetime. The
    /// entry point must support concurrent calls from different threads.
    pub unsafe fn new(entry: PrivateMovEntry) -> Self {
        Self {
            entry,
            #[cfg(all(
                target_os = "android",
                feature = "experimental-private-mov-loader-test"
            ))]
            _library: None,
        }
    }
}

/// Test-only loader. The caller must supply a trusted, isolated library built
/// from this directory for the device ABI. This never registers a capability.
#[cfg(all(
    target_os = "android",
    feature = "experimental-private-mov-loader-test"
))]
impl NativePrivateMovFinalizer {
    /// # Safety
    /// The library must satisfy the same ABI and isolation contract as `new`.
    /// Its path and all parent directories must be controlled by the test host.
    pub unsafe fn load_test_library_unchecked(
        path: &std::path::Path,
    ) -> Result<Self, &'static str> {
        if !path.is_absolute()
            || path
                .file_name()
                .is_none_or(|n| n != "libmornye_private_mov.so")
        {
            return Err("invalid private library path");
        }
        let path = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| "invalid private library path")?;
        let handle = unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL) };
        let handle = std::ptr::NonNull::new(handle).ok_or("private library load failed")?;
        let library = PrivateLibrary(handle);
        let symbol = unsafe { libc::dlsym(handle.as_ptr(), c"mornye_private_mov".as_ptr()) };
        if symbol.is_null() {
            return Err("private library symbol unavailable");
        }
        let entry: PrivateMovEntry = unsafe { std::mem::transmute(symbol) };
        Ok(Self {
            entry,
            _library: Some(library),
        })
    }
}

#[cfg(all(
    target_os = "android",
    feature = "experimental-private-mov-loader-test"
))]
struct PrivateLibrary(std::ptr::NonNull<c_void>);

// dlopen handles may be used and closed from different threads. Ownership is
// held by the finalizer, and Rust borrows self throughout each synchronous call.
#[cfg(all(
    target_os = "android",
    feature = "experimental-private-mov-loader-test"
))]
unsafe impl Send for PrivateLibrary {}
#[cfg(all(
    target_os = "android",
    feature = "experimental-private-mov-loader-test"
))]
unsafe impl Sync for PrivateLibrary {}
#[cfg(all(
    target_os = "android",
    feature = "experimental-private-mov-loader-test"
))]
impl Drop for PrivateLibrary {
    fn drop(&mut self) {
        unsafe {
            libc::dlclose(self.0.as_ptr());
        }
    }
}

struct Context<'a> {
    job: &'a PrivateMovJob,
    terminal_state: TerminalState,
}

#[derive(Default)]
struct TerminalState {
    terminal: Option<c_int>,
    duplicate: bool,
}

impl TerminalState {
    fn record(&mut self, result: c_int) {
        if self.terminal.replace(result).is_some() {
            self.duplicate = true;
        }
    }

    fn outcome(&self, result: c_int) -> Result<(), PrivateFinalizationError> {
        let Some(terminal_result) = self.terminal else {
            return Err(PrivateFinalizationError::ProducerUnconfirmed);
        };
        if self.duplicate || terminal_result != result {
            return Err(PrivateFinalizationError::Failed);
        }
        match result {
            0 => Ok(()),
            2 => Err(PrivateFinalizationError::Cancelled),
            _ => Err(PrivateFinalizationError::Failed),
        }
    }
}

unsafe extern "C" fn cancel(context: *mut c_void) -> c_int {
    let context = unsafe { &*(context.cast::<Context<'_>>()) };
    i32::from(context.job.is_cancelled())
}

unsafe extern "C" fn terminal(context: *mut c_void, result: c_int) {
    let context = unsafe { &mut *(context.cast::<Context<'_>>()) };
    context.terminal_state.record(result);
}

impl PrivateMovFinalizer for NativePrivateMovFinalizer {
    fn finalize(&self, job: Arc<PrivateMovJob>) -> Result<(), PrivateFinalizationError> {
        // These fixed host-owned filenames share the private attempt directory.
        let paths = || {
            let input = job.input_path();
            let output = job.output_path();
            if !input.is_absolute()
                || input.parent() != output.parent()
                || input.file_name()?.as_bytes() != b"input.mp4"
                || output.file_name()?.as_bytes() != b"output.flac"
            {
                return None;
            }
            Some((
                CString::new(input.as_os_str().as_bytes()).ok()?,
                CString::new(output.as_os_str().as_bytes()).ok()?,
            ))
        };
        let Some((input, output)) = paths() else {
            job.acknowledge_terminal(ProducerTerminal::NotStarted);
            return Err(PrivateFinalizationError::Failed);
        };
        if job.key_bytes().len() != 16 {
            job.acknowledge_terminal(ProducerTerminal::NotStarted);
            return Err(PrivateFinalizationError::Failed);
        }
        let mut context = Context {
            job: &job,
            terminal_state: TerminalState::default(),
        };
        // The synchronous contract keeps paths, key and callback context alive.
        let result = unsafe {
            (self.entry)(
                input.as_ptr(),
                output.as_ptr(),
                job.key_bytes().as_ptr(),
                job.key_bytes().len(),
                Some(cancel),
                Some(terminal),
                (&mut context as *mut Context<'_>).cast(),
            )
        };
        if context.terminal_state.terminal.is_none() {
            return Err(PrivateFinalizationError::ProducerUnconfirmed);
        }
        job.acknowledge_terminal(ProducerTerminal::Stopped);
        context.terminal_state.outcome(result)
    }
}

#[cfg(all(
    test,
    target_os = "android",
    feature = "experimental-private-mov-loader-test"
))]
#[path = "private_mov/android_e2e.rs"]
mod android_e2e;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_outcomes_fail_closed() {
        let missing = TerminalState::default();
        assert_eq!(
            missing.outcome(0),
            Err(PrivateFinalizationError::ProducerUnconfirmed)
        );
        for (status, expected) in [
            (0, Ok(())),
            (1, Err(PrivateFinalizationError::Failed)),
            (2, Err(PrivateFinalizationError::Cancelled)),
            (99, Err(PrivateFinalizationError::Failed)),
        ] {
            let mut state = TerminalState::default();
            state.record(status);
            assert_eq!(state.outcome(status), expected);
            assert_eq!(
                state.outcome(status + 1),
                Err(PrivateFinalizationError::Failed)
            );
            state.record(status);
            assert_eq!(state.outcome(status), Err(PrivateFinalizationError::Failed));
        }
    }

    #[cfg(all(
        target_os = "android",
        feature = "experimental-private-mov-loader-test"
    ))]
    #[test]
    fn loader_rejects_invalid_paths_and_missing_library() {
        for path in ["libmornye_private_mov.so", "/tmp/not-private.so"] {
            assert!(
                unsafe { NativePrivateMovFinalizer::load_test_library_unchecked(path.as_ref()) }
                    .is_err()
            );
        }
        assert!(
            unsafe {
                NativePrivateMovFinalizer::load_test_library_unchecked(
                    "/does-not-exist/libmornye_private_mov.so".as_ref(),
                )
            }
            .is_err()
        );
    }
}
