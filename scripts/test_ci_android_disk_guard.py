"""Tests for the ephemeral GitHub runner's Android disk guard."""

import os
import signal
import subprocess
import sys
import unittest
from unittest.mock import MagicMock, patch

import ci_android_disk_guard as guard


class GuardTests(unittest.TestCase):
    def setUp(self):
        patches = [
            patch.dict(os.environ, {"GITHUB_WORKSPACE": "workspace", "RUNNER_TEMP": "temp"}),
            patch.object(signal, "SIGHUP", 1, create=True),
            patch.object(signal, "SIGKILL", 9, create=True),
            patch.object(signal, "signal"),
            patch.object(guard.tempfile, "mkstemp", return_value=(99, "reserve")),
            patch.object(os, "posix_fallocate", create=True),
            patch.object(os, "close"),
            patch.object(os, "unlink"),
            patch.object(os, "killpg", create=True),
            patch.object(guard.shutil, "disk_usage", return_value=MagicMock(free=9 * 1024**3)),
        ]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)
        self.process = MagicMock(pid=123)
        self.process.wait.return_value = 0
        process_patch = patch.object(subprocess, "Popen", return_value=self.process)
        self.popen = process_patch.start()
        self.addCleanup(process_patch.stop)

    def test_preserves_build_failure(self):
        self.process.wait.return_value = 7
        self.assertEqual(guard.main(), 7)
        self.assertEqual(os.killpg.call_count, 2)

    def test_monitor_failure_escalates_when_term_is_ignored(self):
        guard.shutil.disk_usage.side_effect = OSError("measurement failed")
        self.process.wait.side_effect = [subprocess.TimeoutExpired("build", 10), 0]
        self.assertEqual(guard.main(), 1)
        self.assertEqual([call.args[1] for call in os.killpg.call_args_list],
                         [signal.SIGTERM, signal.SIGKILL])

    def test_reserve_failure_does_not_start_build(self):
        os.posix_fallocate.side_effect = OSError("reserve failed")
        self.assertEqual(guard.main(), 1)
        self.popen.assert_not_called()
        os.unlink.assert_called_once_with("reserve")

    def test_low_space_stops_build(self):
        guard.shutil.disk_usage.return_value = MagicMock(free=1)
        self.assertEqual(guard.main(), 1)
        self.assertEqual(os.killpg.call_count, 2)

    def test_logging_failure_does_not_skip_cleanup(self):
        guard.shutil.disk_usage.side_effect = OSError("measurement failed")
        with patch("builtins.print", side_effect=BrokenPipeError("log unavailable")):
            self.assertEqual(guard.main(), 1)
        self.assertEqual([call.args[1] for call in os.killpg.call_args_list],
                         [signal.SIGTERM, signal.SIGKILL])

    def test_signal_during_launch_still_cleans_child(self):
        handlers = {}
        signal.signal.side_effect = lambda sig, handler: handlers.update({sig: handler})

        def launch(*args, **kwargs):
            handlers[signal.SIGTERM](signal.SIGTERM, None)
            return self.process

        self.popen.side_effect = launch
        self.assertEqual(guard.main(), 128 + signal.SIGTERM)
        self.assertEqual(os.killpg.call_count, 2)


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux process groups required")
class LinuxProcessTests(unittest.TestCase):
    def test_real_process_ignoring_term_is_killed(self):
        child = subprocess.Popen(
            [sys.executable, "-u", "-c",
             "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
             "print('ready', flush=True); time.sleep(60)"],
            stdout=subprocess.PIPE, text=True, start_new_session=True,
        )
        try:
            self.assertEqual(child.stdout.readline().strip(), "ready")
            with patch.object(guard, "TERM_GRACE_SECONDS", 0.2):
                guard.stop_group(child)
            self.assertEqual(child.returncode, -signal.SIGKILL)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
            child.stdout.close()


if __name__ == "__main__":
    unittest.main()
