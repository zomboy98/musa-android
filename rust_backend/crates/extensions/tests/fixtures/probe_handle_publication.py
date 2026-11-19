"""Manual probe on a trusted parent: python probe_handle_publication.py DIR.

An unsupported system call is a probe failure. This fixture is independent of MUSA.
Windows uses an absolute destination path without anchoring the parent by handle.
Linux pins the destination directory and requires a linkable anonymous inode and procfs.
Cancellation is simulated before publication. Android app policy, crash durability,
and resistance to a hostile process with the same UID are outside this probe.
"""

import ctypes
import os
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, closing
from pathlib import Path


def check(condition, message):
    if not condition:
        raise AssertionError(message)


if sys.platform == "win32":
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    create = kernel.CreateFileW
    create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                       ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    create.restype = wintypes.HANDLE
    set_info = kernel.SetFileInformationByHandle
    set_info.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    set_info.restype = wintypes.BOOL
    get_info = kernel.GetFileInformationByHandleEx
    get_info.argtypes = set_info.argtypes
    get_info.restype = wintypes.BOOL
    close_handle = kernel.CloseHandle
    close_handle.argtypes = [wintypes.HANDLE]
    close_handle.restype = wintypes.BOOL

    class FileIdInfo(ctypes.Structure):
        _fields_ = [("volume", ctypes.c_ulonglong), ("id", ctypes.c_ubyte * 16)]

    def identity(fd):
        import msvcrt

        info = FileIdInfo()
        if not get_info(msvcrt.get_osfhandle(fd), 18, ctypes.byref(info), ctypes.sizeof(info)):
            raise ctypes.WinError(ctypes.get_last_error())
        return info.volume, bytes(info.id)

    class RenameInfo(ctypes.Structure):
        _fields_ = [("flags", wintypes.DWORD), ("parent", wintypes.HANDLE),
                    ("length", wintypes.DWORD), ("name", wintypes.WCHAR * 1)]

    class DispositionInfo(ctypes.Structure):
        _fields_ = [("delete", wintypes.BOOL)]

    def update(handle, kind, data):
        if not set_info(handle, kind, ctypes.byref(data), ctypes.sizeof(data)):
            raise ctypes.WinError(ctypes.get_last_error())

    class Stage:
        def __init__(self, root, name, payload):
            import msvcrt

            self.path = root / name
            handle = create(str(self.path), 0xC0010000, 0, None, 1, 0x80, None)
            if handle == ctypes.c_void_p(-1).value:
                raise ctypes.WinError(ctypes.get_last_error())
            self.handle = handle
            try:
                self.fd = msvcrt.open_osfhandle(handle, os.O_RDWR | os.O_BINARY)
            except BaseException:
                try:
                    update(handle, 4, DispositionInfo(True))
                finally:
                    close_handle(handle)
                raise
            self.published = False
            try:
                self.fill(payload)
            except BaseException:
                self.close()
                raise

        def fill(self, payload):
            check(os.write(self.fd, payload) == len(payload), "short stage write")
            os.fsync(self.fd)
            os.lseek(self.fd, 0, os.SEEK_SET)
            check(os.read(self.fd, len(payload) + 1) == payload, "stage bytes differ")

        def publish(self, target):
            encoded = str(self.path.with_name(target)).encode("utf-16-le")
            data = ctypes.create_string_buffer(ctypes.sizeof(RenameInfo) + len(encoded))
            info = RenameInfo.from_buffer(data)
            info.length = len(encoded)
            ctypes.memmove(ctypes.addressof(data) + RenameInfo.name.offset, encoded, len(encoded))
            update(self.handle, 3, data)
            self.published = True

        def close(self):
            try:
                if not self.published:
                    update(self.handle, 4, DispositionInfo(True))
            finally:
                os.close(self.fd)

elif sys.platform.startswith("linux"):
    def identity(fd):
        info = os.fstat(fd)
        return info.st_dev, info.st_ino

    class Stage:
        def __init__(self, root, name, payload):
            self.path = root / name
            self.parent = os.open(root, os.O_DIRECTORY)
            try:
                self.fd = os.open(".", os.O_TMPFILE | os.O_RDWR, 0o600, dir_fd=self.parent)
            except BaseException:
                os.close(self.parent)
                raise
            try:
                check(os.fstat(self.fd).st_nlink == 0, "temporary inode already has a name")
                check(os.write(self.fd, payload) == len(payload), "short stage write")
                os.fsync(self.fd)
                check(os.pread(self.fd, len(payload) + 1, 0) == payload, "stage bytes differ")
            except BaseException:
                self.close()
                raise

        def publish(self, target):
            # Supplying dir_fd selects linkat in CPython.
            os.link(f"/proc/self/fd/{self.fd}", target, dst_dir_fd=self.parent,
                    follow_symlinks=True)

        def close(self):
            os.close(self.fd)
            os.close(self.parent)

else:
    raise SystemExit("No probe backend on this OS")


def run(root):
    ready = threading.Barrier(2, timeout=5)
    attacked = threading.Barrier(2, timeout=5)
    def substitute(stage):
        ready.wait()
        try:
            if sys.platform == "win32":
                try:
                    stage.path.rename(root / "stolen")
                except OSError as error:
                    check(error.winerror in (5, 32), error)
                else:
                    raise AssertionError("Windows stage could be renamed through its name")
            else:
                stage.path.write_bytes(b"replacement")
        finally:
            attacked.wait()

    with closing(Stage(root, "source", b"validated")) as stage:
        original = identity(stage.fd)
        with ThreadPoolExecutor(1) as pool:
            attack = pool.submit(substitute, stage)
            ready.wait()
            attacked.wait()
            attack.result(timeout=5)
            stage.publish("final")
    final = root / "final"
    check(final.read_bytes() == b"validated", "published bytes differ")
    with final.open("rb") as published:
        check(identity(published.fileno()) == original, "published identity differs")
    if sys.platform != "win32":
        check(stage.path.read_bytes() == b"replacement", "replacement was modified")
        stage.path.unlink()

    stage = Stage(root, "abort", b"discard")
    stage.close()
    check(not stage.path.exists(), "abort left a stage")

    staged = threading.Barrier(2, timeout=5)
    cancelled = threading.Event()

    def cancel():
        staged.wait()
        cancelled.set()

    with closing(Stage(root, "cancel", b"discard")) as stage:
        with ThreadPoolExecutor(1) as pool:
            cancel_task = pool.submit(cancel)
            staged.wait()
            check(cancelled.wait(timeout=5), "cancellation worker timed out")
            # Models cancellation before a commit lease, not cancellation after commit.
            if not cancelled.is_set():
                stage.publish("cancelled-final")
            cancel_task.result(timeout=5)
    check(not stage.path.exists(), "cancellation left a stage")
    check(not (root / "cancelled-final").exists(), "cancelled output appeared")

    stage = Stage(root, "collision", b"discard")
    try:
        try:
            stage.publish("final")
        except FileExistsError:
            pass
        else:
            raise AssertionError("Publication replaced an existing file")
    finally:
        stage.close()
    check(final.read_bytes() == b"validated", "collision modified existing output")
    check(not stage.path.exists(), "collision left a stage")

    gate = threading.Barrier(2, timeout=5)

    def race(stage, payload):
        try:
            gate.wait()
            stage.publish("winner")
            return payload
        except FileExistsError:
            return None
    with ExitStack() as stages:
        contenders = []
        for value in ("one", "two"):
            payload = value.encode()
            stage = stages.enter_context(closing(Stage(root, value, payload)))
            contenders.append((stage, payload))
        with ThreadPoolExecutor(2) as pool:
            results = [pool.submit(race, *contender) for contender in contenders]
            winners = [value for result in results
                       if (value := result.result(timeout=5)) is not None]
    check(len(winners) == 1, "expected exactly one winner")
    check((root / "winner").read_bytes() == winners[0], "winner bytes differ")
    check({entry.name for entry in root.iterdir()} == {"final", "winner"}, "unexpected artifacts remain")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(dir=sys.argv[1]) as directory:
        run(Path(directory).resolve())
    print("PASS: source substitution, content, abort, cancel, collision, two publishers, cleanup")
