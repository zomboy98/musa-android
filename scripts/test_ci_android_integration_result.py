import subprocess
import unittest
from unittest.mock import call, patch

from ci_android_integration_result import run_gate


class AndroidIntegrationResultTests(unittest.TestCase):
    adb = ['adb', '-s', 'emulator-5554']
    drive = ['timeout', '8m', 'flutter', 'drive', '--keep-app-running']

    def run_with_logs(self, *logs, host_code=0, pids=(), cross_deadline=False):
        logs = iter(logs)
        pids = iter(pids)
        last_log = ''
        clock = iter(range(30))
        now = 0

        def run(command, **kwargs):
            nonlocal last_log, now
            if command == self.drive:
                return subprocess.CompletedProcess(command, host_code)
            if command[3:5] == ['shell', 'pidof']:
                pid = next(pids, '2942')
                if cross_deadline and last_log:
                    now = 4.1
                return subprocess.CompletedProcess(command, 0 if pid else 1, stdout=pid)
            if '-d' in command:
                last_log = next(logs, last_log)
                return subprocess.CompletedProcess(command, 0, stdout=last_log)
            return subprocess.CompletedProcess(command, 0)

        with patch('ci_android_integration_result.subprocess.run', side_effect=run) as mock:
            with patch('ci_android_integration_result.time.sleep'):
                with patch('ci_android_integration_result.time.monotonic', side_effect=lambda: now if cross_deadline else next(clock)):
                    code = run_gate('adb', 'emulator-5554', self.drive, wait_seconds=4)
        self.assertEqual(
            mock.call_args_list[0],
            call([*self.adb, 'logcat', '-b', 'main', '-c'], check=True, timeout=5),
        )
        for invocation in mock.call_args_list[2:]:
            command = invocation.args[0]
            self.assertEqual(command[:3], self.adb)
            if '-d' in command:
                self.assertIn('--pid=2942', command)
        return code, mock.call_count

    def test_late_failure_in_a_later_dump_overrides_success(self):
        success = 'I/flutter ( 2942): 00:22 +1: All tests passed!\n'
        failure = 'I/flutter ( 2942): 00:23 +1 -1: Some tests failed.\n'
        self.assertEqual(self.run_with_logs(success, failure)[0], 1)

    def test_dump_after_deadline_catches_failure_when_pid_lookup_crossed_deadline(self):
        success = 'I/flutter ( 2942): 00:22 +1: All tests passed!\n'
        failure = 'I/flutter ( 2942): 00:23 +1 -1: Some tests failed.\n'
        self.assertEqual(self.run_with_logs(success, failure, cross_deadline=True)[0], 1)

    def test_pid_disappearance_after_success_fails(self):
        success = 'I/flutter ( 2942): 00:22 +1: All tests passed!\n'
        self.assertEqual(self.run_with_logs(success, pids=('2942', '2942', ''))[0], 1)

    def test_false_green_from_real_run(self):
        log = ('I/flutter ( 2942): 00:21 +0: Android native worker saves permanent flac audio [E]\n'
               'I/flutter ( 2942): 00:22 +0 -1: (tearDownAll)\n'
               'All tests passed.\n'
               'I/flutter ( 2942): 00:22 +1 -1: Some tests failed.\n')
        self.assertEqual(self.run_with_logs(log)[0], 1)

    def test_host_only_and_other_pid_cannot_pass(self):
        log = 'All tests passed.\nI/flutter ( 2939): 00:22 +1: All tests passed!\n'
        self.assertEqual(self.run_with_logs(log, log, log)[0], 1)

    def test_current_pid_success_after_delay(self):
        stale = 'I/flutter ( 2939): 00:22 +1 -1: Some tests failed.\n'
        success = 'I/flutter ( 2942): 00:22 +1: All tests passed!\n'
        self.assertEqual(self.run_with_logs(stale, stale + success)[0], 0)

    def test_repeated_run_does_not_inherit_a_success_for_the_same_pid(self):
        success = 'I/flutter ( 2942): 00:22 +1: All tests passed!\n'
        self.assertEqual(self.run_with_logs(success)[0], 0)
        self.assertEqual(self.run_with_logs('', '', '')[0], 1)

    def test_zero_passes_and_skipped_only_do_not_pass(self):
        for summary in ('+0: All tests passed!', '+0 ~1: All tests skipped.', '+1 ~1: All tests passed!'):
            with self.subTest(summary=summary):
                log = f'I/flutter ( 2942): 00:22 {summary}\n'
                self.assertEqual(self.run_with_logs(log)[0], 1)

    def test_host_nonzero_exits_without_polling(self):
        self.assertEqual(self.run_with_logs(host_code=124), (124, 2))

    def test_rejects_physical_device_serial_before_adb(self):
        with patch('ci_android_integration_result.subprocess.run') as run:
            with self.assertRaises(ValueError):
                run_gate('adb', 'physical-device', self.drive)
        run.assert_not_called()

