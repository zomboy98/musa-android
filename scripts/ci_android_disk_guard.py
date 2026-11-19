#!/usr/bin/env python3
"""Run the Android build with a log reserve and a bounded disk watchdog."""

import os
import shutil
import signal
import subprocess
import sys
import tempfile

RESERVE_BYTES = 2 * 1024**3
MIN_FREE_BYTES = 2 * 1024**3
POLL_SECONDS = 10
TERM_GRACE_SECONDS = 10


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def stop_group(process):
    """Signal only the session and process group created for this child."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=TERM_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    # The leader may have exited while descendants ignored SIGTERM.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=TERM_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            print("Android build did not exit after SIGKILL", file=sys.stderr, flush=True)
        except OSError:
            pass


def main():
    process = None
    reserve_path = None
    error = None
    result = 1
    interrupted = None

    def interrupt(signum, _frame):
        nonlocal interrupted
        interrupted = signum

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupt)

    try:
        workspace = os.environ["GITHUB_WORKSPACE"]
        runner_temp = os.environ["RUNNER_TEMP"]
        fd, reserve_path = tempfile.mkstemp(prefix="android-disk-reserve-", dir=runner_temp)
        try:
            os.posix_fallocate(fd, 0, RESERVE_BYTES)
        finally:
            os.close(fd)

        # A new session makes the child's PID its private process-group ID.
        if interrupted is not None:
            raise Interrupted(interrupted)
        process = subprocess.Popen(
            ["bash", "scripts/build_android.sh", "--lite", "--target", "lib/main.dart"],
            cwd=workspace,
            start_new_session=True,
        )
        while True:
            if interrupted is not None:
                raise Interrupted(interrupted)
            free = min(shutil.disk_usage(workspace).free, shutil.disk_usage(runner_temp).free)
            print(f"Android build minimum free space: {free // 1024} KiB", flush=True)
            if free < MIN_FREE_BYTES:
                raise RuntimeError("less than 2 GiB free; stopping Android build")
            try:
                result = process.wait(timeout=POLL_SECONDS)
                if interrupted is not None:
                    raise Interrupted(interrupted)
                if result != 0:
                    error = f"Android build exited with status {result}"
                break
            except subprocess.TimeoutExpired:
                pass
    except Interrupted as exc:
        error = f"Android disk guard interrupted by signal {exc.signum}"
        result = 128 + exc.signum
    except Exception as exc:
        error = f"Android disk guard failed: {exc}"
        result = 1
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        # Release the reserve before logging or stopping a full-disk build.
        if reserve_path is not None:
            try:
                os.unlink(reserve_path)
            except FileNotFoundError:
                pass
            except OSError as exc:
                error = f"Could not release Android disk reserve: {exc}"
                result = 1
        if error is not None:
            if process is not None:
                stop_group(process)
            try:
                print(error, file=sys.stderr, flush=True)
            except OSError:
                pass
    return result


if __name__ == "__main__":
    sys.exit(main())
