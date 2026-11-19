"""Require both the host driver and the on-device Flutter reporter to pass."""

import re
import subprocess
import sys
import time


PACKAGE = 'org.musa.music.catalogintegration'
ANSI_COLOR = re.compile(r'\x1b\[[0-9;]*m')
SUMMARY = re.compile(
    r'I/flutter\s*\(\s*(?P<pid>[1-9][0-9]*)\):\s+'
    r'[0-9:]+ \+(?P<passed>[0-9]+)(?: ~(?P<skipped>[0-9]+))?(?: -(?P<failed>[0-9]+))?: '
    r'(?P<result>All tests passed!|All tests skipped\.|Some tests failed\.)'
)


def package_pid(adb):
    result = subprocess.run(
        [*adb, 'shell', 'pidof', PACKAGE], timeout=5, capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ''


def run_gate(adb, serial, drive, *, wait_seconds=15):
    if not re.fullmatch(r'emulator-[0-9]+', serial):
        raise ValueError('The result gate requires a disposable Android emulator serial.')
    adb = [adb, '-s', serial]
    # The AVD is dedicated to this suite. Exclude logs from previous invocations,
    # even if Android happens to reuse a process ID.
    subprocess.run([*adb, 'logcat', '-b', 'main', '-c'], check=True, timeout=5)
    driver_result = subprocess.run(drive).returncode
    if driver_result:
        return driver_result if driver_result > 0 else 128 - driver_result

    pid = package_pid(adb)
    if not re.fullmatch(r'[1-9][0-9]*', pid):
        raise ValueError(f'Expected one PID for {PACKAGE}.')

    # A host success can precede an on-device failure. Observe the full
    # post-drive window, with a final sample at its end. Events after that
    # sample are outside this check. Each ADB command also has a timeout.
    deadline = time.monotonic() + wait_seconds
    passed_summary = None
    while True:
        final_sample = time.monotonic() >= deadline
        log = subprocess.run(
            [*adb, 'logcat', '-b', 'main', '-d', f'--pid={pid}', '-v', 'brief', '-s', 'flutter:I'],
            check=True, timeout=5, capture_output=True, text=True, errors='replace',
        ).stdout
        if package_pid(adb) != pid:
            print(f'{PACKAGE} exited or changed PID before result verification.', file=sys.stderr)
            return 1
        for line in log.splitlines():
            match = SUMMARY.fullmatch(ANSI_COLOR.sub('', line).rstrip())
            if match is None or match['pid'] != pid:
                continue
            if (
                match['result'] != 'All tests passed!'
                or not int(match['passed'])
                or int(match['failed'] or 0)
                or int(match['skipped'] or 0)
            ):
                print(line, flush=True)
                return 1
            passed_summary = line
        if final_sample:
            break
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(1, remaining))

    if passed_summary is not None:
        print(passed_summary, flush=True)
        return 0

    print(f'Missing final Flutter integration test result for {PACKAGE} (PID {pid}).', file=sys.stderr)
    return 1


if __name__ == '__main__':
    try:
        sys.exit(run_gate(sys.argv[1], sys.argv[2], sys.argv[3:]))
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        sys.exit(f'Could not verify Android integration test results: {error}')

