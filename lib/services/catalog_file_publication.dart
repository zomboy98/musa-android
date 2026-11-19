import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _testAndroidLegacy = bool.fromEnvironment('CATALOG_TEST_ANDROID_LEGACY');

int _androidRenameSyscallNumber() {
  final abi = Abi.current();
  if (abi == Abi.androidArm) return 382;
  if (abi == Abi.androidArm64) return 276;
  if (abi == Abi.androidIA32) return 353;
  if (abi == Abi.androidX64) return 316;
  throw UnsupportedError('Unsupported Android ABI for atomic publication');
}

/// Publishes a completed staging file without replacing any existing entry,
/// including a dangling symbolic link. Staging must be on the same filesystem
/// and in an app-owned directory. This does not sandbox hostile parent-directory
/// replacement; callers must keep the store roots under their control.
///
/// Never fall back to Dart File.rename/copy: both can overwrite an existing file.
/// Native contracts:
/// https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexw
/// https://man7.org/linux/man-pages/man2/link.2.html
/// https://man7.org/linux/man-pages/man2/rename.2.html
void publishCatalogFileNew(String source, String destination) {
  if (Platform.isAndroid) {
    final library = DynamicLibrary.open('libc.so');
    int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)? rename;
    if (!_testAndroidLegacy) {
      try {
        rename = library
            .lookupFunction<
              Int32 Function(
                Int32,
                Pointer<Utf8>,
                Int32,
                Pointer<Utf8>,
                Uint32,
              ),
              int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
            >('renameat2');
      } on ArgumentError {
        // The libc wrapper was introduced in Android API 30.
      }
    }
    final from = source.toNativeUtf8();
    final to = destination.toNativeUtf8();
    try {
      // AT_FDCWD and RENAME_NOREPLACE; never replace even a dangling link.
      final int result;
      if (rename != null) {
        result = rename(-100, from, -100, to, 1);
      } else {
        // Android 8's AOSP seccomp allowlist includes renameat2; OEM policy
        // can differ. The kernel/filesystem may still reject this operation.
        final syscall = library
            .lookupFunction<
              IntPtr Function(
                IntPtr,
                IntPtr,
                Pointer<Utf8>,
                IntPtr,
                Pointer<Utf8>,
                IntPtr,
              ),
              int Function(int, int, Pointer<Utf8>, int, Pointer<Utf8>, int)
            >('syscall');
        result = syscall(
          _androidRenameSyscallNumber(),
          -100,
          from,
          -100,
          to,
          1,
        );
      }
      if (result != 0) {
        throw FileSystemException(
          'Cannot publish catalog file without replacement',
          destination,
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
    return;
  }
  if (Platform.isWindows) {
    final library = DynamicLibrary.open('kernel32.dll');
    final move = library
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final error = library.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    final from = source.toNativeUtf16();
    final to = destination.toNativeUtf16();
    try {
      // No REPLACE_EXISTING and no COPY_ALLOWED: a same-volume rename only.
      if (move(from, to, 0) == 0) {
        final code = error();
        throw FileSystemException(
          'Cannot publish catalog file without replacement',
          destination,
          OSError('MoveFileExW failed', code),
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
    return;
  }
  if (Platform.isLinux ||
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isIOS) {
    final library = Platform.isAndroid
        ? DynamicLibrary.open('libc.so')
        : DynamicLibrary.process();
    final link = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('link');
    final from = source.toNativeUtf8();
    final to = destination.toNativeUtf8();
    try {
      // link(2) creates the new directory entry atomically and fails with
      // EEXIST for every existing destination, including dangling symlinks.
      // The caller removes the staging name after commit. No copy fallback on
      // filesystems without hard links: leave source and destination intact.
      if (link(from, to) != 0) {
        throw FileSystemException(
          'Cannot publish catalog file without replacement',
          destination,
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
    return;
  }
  throw UnsupportedError('Atomic catalog publication is unsupported');
}

/// Pins an Android file's identity until the current transaction finishes.
/// This descriptor cannot survive a process crash; recovery must preserve
/// entries whose ownership can no longer be established.
class AndroidCatalogFileIdentity {
  AndroidCatalogFileIdentity._(this._fd, this._close);
  final int _fd;
  final int Function(int) _close;

  /// Compare stat64 identities while the descriptor pins the inode. Offsets
  /// are from Android NDK sys/stat.h, checked for the four supported ABIs.
  bool matches(String path) {
    final library = DynamicLibrary.open('libc.so');
    final fstat = library
        .lookupFunction<
          Int32 Function(Int32, Pointer<Void>),
          int Function(int, Pointer<Void>)
        >('fstat64');
    final lstat = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Void>),
          int Function(Pointer<Utf8>, Pointer<Void>)
        >('lstat64');
    final name = path.toNativeUtf8();
    final held = calloc<Uint8>(256);
    final current = calloc<Uint8>(256);
    try {
      final abi = Abi.current();
      final int inoOffset;
      if (abi == Abi.androidArm64 || abi == Abi.androidX64) {
        inoOffset = 8;
      } else if (abi == Abi.androidArm) {
        inoOffset = 96;
      } else if (abi == Abi.androidIA32) {
        inoOffset = 88;
      } else {
        throw UnsupportedError('Unsupported Android ABI for identity');
      }
      if (fstat(_fd, held.cast()) != 0 || lstat(name, current.cast()) != 0) {
        return false;
      }
      return held.cast<Uint64>().value == current.cast<Uint64>().value &&
          (held + inoOffset).cast<Uint64>().value ==
              (current + inoOffset).cast<Uint64>().value;
    } finally {
      calloc.free(name);
      calloc.free(held);
      calloc.free(current);
    }
  }

  static AndroidCatalogFileIdentity open(String path) {
    final library = DynamicLibrary.open('libc.so');
    final open = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, int)
        >('open');
    final close = library
        .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
    final name = path.toNativeUtf8();
    try {
      // O_CLOEXEC | O_NOFOLLOW | O_RDONLY.
      final fd = open(name, 0x80000 | 0x20000);
      if (fd < 0) {
        throw FileSystemException(
          'Cannot anchor catalog staging identity',
          path,
        );
      }
      return AndroidCatalogFileIdentity._(fd, close);
    } finally {
      calloc.free(name);
    }
  }

  void close() => _close(_fd);
}

/// An identity anchor for private staging. Both entries refer to the same file;
/// recovery can distinguish its own partially written file from a replacement.
void linkCatalogFileNew(String source, String destination) {
  if (!Platform.isWindows) {
    publishCatalogFileNew(source, destination);
    return;
  }
  final library = DynamicLibrary.open('kernel32.dll');
  final link = library
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
        int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
      >('CreateHardLinkW');
  final from = source.toNativeUtf16();
  final to = destination.toNativeUtf16();
  try {
    if (link(to, from, nullptr) == 0) {
      throw FileSystemException(
        'Cannot anchor catalog staging identity',
        destination,
      );
    }
  } finally {
    calloc.free(from);
    calloc.free(to);
  }
}
