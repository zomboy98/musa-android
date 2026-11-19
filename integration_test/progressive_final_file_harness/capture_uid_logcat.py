"""Host-only, sanitized UID capture. Does not install, instrument or uninstall.
Start after UID/permission gates, before instrumentation; stop and persist before
uninstall. All adb invocations are scoped to the explicit serial. No buffer clears.
"""
import argparse
import hashlib
import json
import re
import subprocess
import threading
import time
from pathlib import Path
from instrument_once import bounded_lines, valid_epoch, classify_stderr, REAL_SONG_STAGES, NATIVE_TRANSITION_STAGES


# Fixed library basenames only. No symbol/function/path text is retained.
FRAME_MODULES = frozenset(('libflutter.so', 'libc.so', 'libart.so',
    'libmedia_jni.so', 'libaudioclient.so', 'libaudioprocessing.so',
    'libaaudio.so', 'libstagefright.so', 'libffmpegkit.so'))


def own_relative_frame(raw, own_pids):
    """Only standard threadtime backtrace frames emitted by a caller-allowlisted PID.

    #NN pc identifies module-relative PC, not register/absolute memory addresses.
    The reader does NOT verify UID/PID ownership, process start time, reuse or
    association with a crash. External gates must establish those independently;
    default empty set drops all.
    """
    if len(raw) > 4096 or not own_pids:
        return None
    match = re.fullmatch(
        r'\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3,6}\s+'
        r'([1-9][0-9]{0,8})\s+[1-9][0-9]{0,8}\s+[FE]\s+DEBUG\s*:\s*'
        r'#[0-9]{2}\s+pc\s+([0-9a-fA-F]{1,16})\s+'
        r'(?:/[A-Za-z0-9_.+@=!-]+)+/([A-Za-z0-9_.+-]+\.so)'
        r'(?: \([^\r\n]*\))?\s*', raw.rstrip())
    if not match or int(match.group(1)) not in own_pids:
        return None
    module = match.group(3)
    relative_pc = int(match.group(2), 16)
    if module not in FRAME_MODULES or relative_pc > 0xffffffff:
        return None
    return 'CRASH_FRAME MODULE ' + module + ' RELATIVE_PC ' + format(relative_pc, 'x')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--own-pid', action='append', type=int, default=[], help='Optional caller-supplied PID; reader does not verify ownership/start time/reuse')
    parser.add_argument('--uid', required=True, type=int)
    parser.add_argument('--device-time', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--stop-file', required=True, type=Path)
    parser.add_argument('--seconds', type=int, default=155)
    args = parser.parse_args()
    if len(args.own_pid) > 8 or any(x < 1 or x > 999999999 for x in args.own_pid):
        parser.error('Own PID allowlist invalid')
    own_pids = frozenset(args.own_pid)
    if not valid_epoch(args.device_time):
        parser.error('Require device-time epoch.mmm')
    if args.uid < 10000 or not 1 <= args.seconds <= 180:
        parser.error('Require app UID and bounded duration')
    # Fresh directory prevents accidental replacement of prior evidence.
    if args.stop_file.exists():
        parser.error('Stop file must initially be absent')
    args.output.mkdir(parents=True, exist_ok=False)
    allowed = {'MusaHarnessStage', 'MusaRealSongStage', 'MusaNativeTransition', 'flutter'}
    constants = set(re.findall(r'^    ([A-Z][A-Z0-9_]+)[,\n]',
        (Path(__file__).parents[2] / 'android/app/src/androidTest/kotlin/com/zarz/mornye/ProgressiveFlutterFinalFileInstrumentedTest.kt').read_text(), re.M))
    dart_constants = set(re.findall(r'^  ([a-z][A-Za-z0-9]+),?$',
        (Path(__file__).parents[1] / 'android_progressive_final_file_test.dart').read_text(), re.M))
    proc = subprocess.Popen([args.adb, '-s', args.serial, 'logcat',
        '--uid=' + str(args.uid), '-T', args.device_time, '-v', 'threadtime'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        encoding='utf-8', errors='replace', bufsize=1)
    state = {'kept': 0, 'dropped': 0, 'bytes': 0, 'loss': False, 'line_truncated': False, 'reader_error': False, 'stderr_reader_error': False}
    lines = []
    lock = threading.Lock()

    def truncated():
        with lock:
            state['loss'] = True
            state['line_truncated'] = True

    def consume():
        try:
            for raw in bounded_lines(proc.stdout, truncated):
                retained = own_relative_frame(raw, own_pids)
                match = re.search(r'\b([A-Za-z][A-Za-z0-9]*)\s*: (.*)$', raw.rstrip())
                if match:
                    tag, message = match.groups()
                    if tag in allowed:
                        if tag == 'MusaHarnessStage' and message in constants:
                            retained = 'NATIVE ' + message
                        elif tag == 'MusaRealSongStage' and message in REAL_SONG_STAGES:
                            retained = 'REAL_SONG ' + message
                        elif tag == 'MusaNativeTransition' and message in NATIVE_TRANSITION_STAGES:
                            retained = 'NATIVE_TRANSITION ' + message
                        elif tag == 'flutter' and message.startswith('MUSA_HARNESS_STAGE '):
                            name = message.removeprefix('MUSA_HARNESS_STAGE ')
                            if name in dart_constants:
                                retained = 'DART ' + name
                    if tag == 'AndroidRuntime':
                        if message.startswith('FATAL EXCEPTION:'):
                            retained = 'CRASH FATAL_EXCEPTION'
                        else:
                            error = re.match(r'(?:Caused by: )?([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+(?:Exception|Error))(?::|$)', message)
                            if error:
                                retained = 'CRASH JAVA_EXCEPTION'
                    elif tag == 'libc':
                        signal = re.match(r'Fatal signal (\d+)\b', message)
                        if signal:
                            retained = 'CRASH FATAL_SIGNAL ' + signal.group(1)
                with lock:
                    if retained and state['bytes'] + len(retained) + 1 <= 262144:
                        lines.append(retained)
                        state['bytes'] += len(retained) + 1
                        state['kept'] += 1
                    else:
                        if retained:
                            state['loss'] = True
                        state['dropped'] += 1
        except Exception:
            with lock:
                state['reader_error'] = True
                state['loss'] = True

    stderr_categories = set()
    stderr_truncated = threading.Event()
    def consume_stderr():
        try:
            for line in bounded_lines(proc.stderr, stderr_truncated.set):
                category = classify_stderr(line)
                if category != 'NONE':
                    stderr_categories.add(category)
        except Exception:
            with lock:
                state['stderr_reader_error'] = True
                state['loss'] = True

    error_reader = threading.Thread(target=consume_stderr, daemon=True)
    error_reader.start()
    reader = threading.Thread(target=consume, daemon=True)
    reader.start()
    started = time.monotonic()
    reason = 'deadline'
    try:
        time.sleep(0.25)
        if proc.poll() is not None:
            reason = 'reader_failed_before_ready'
        else:
            (args.output / 'ready').write_text('UID_READER_STARTED\n')
            while time.monotonic() - started < args.seconds:
                if proc.poll() is not None:
                    reason = 'reader_exited'
                    break
                if args.stop_file.exists():
                    reason = 'stop_requested'
                    time.sleep(2)  # Bounded drain, packages must remain installed.
                    break
                time.sleep(0.1)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
        reader.join(timeout=3)
        error_reader.join(timeout=3)
        if not error_reader.is_alive():
            proc.stderr.close()
        if not reader.is_alive():
            proc.stdout.close()
        with lock:
            data = ('\n'.join(lines) + ('\n' if lines else '')).encode()
            summary = dict(state)
        (args.output / 'sanitized.txt').write_bytes(data)
        summary.update(reason=reason, reader_exit=proc.returncode,
            stderr_categories=sorted(stderr_categories), stderr_truncated=stderr_truncated.is_set(),
            stderr_reader_joined=not error_reader.is_alive(),
            reader_joined=not reader.is_alive(), sha256=hashlib.sha256(data).hexdigest())
        (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    return 0 if reason == 'stop_requested' and not reader.is_alive() and not error_reader.is_alive() and not summary['loss'] and not stderr_categories and not stderr_truncated.is_set() else 1


if __name__ == '__main__':
    raise SystemExit(main())
