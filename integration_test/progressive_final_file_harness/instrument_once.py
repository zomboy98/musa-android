"""Run one already-approved instrumentation; no install/uninstall operations.
Caller retains responsibility for package gates and uninstall AFTER this exits.
Only sanitized constant categories/codes/stages reach disk.
"""
import argparse
import secrets
import codecs
import os
import hashlib
import json
import queue
import re
import subprocess
import sys
import threading
import time
from pathlib import Path


def valid_epoch(value):
    return re.fullmatch(r'[1-9][0-9]{9,12}\.[0-9]{3}', value) is not None


def classify_stderr(text):
    lowered = text.lower()
    if not lowered.strip():
        return 'NONE'
    for needle, category in [('time', 'TIME_ARGUMENT'), ('permission', 'PERMISSION'),
                             ('offline', 'DEVICE_OFFLINE'), ('not found', 'NOT_FOUND'),
                             ('invalid', 'INVALID_ARGUMENT')]:
        if needle in lowered:
            return category
    return 'UNCLASSIFIED'


TRACE_MODULES = frozenset(('libflutter.so','libc.so','libart.so','libmedia_jni.so',
    'libaudioclient.so','libaudioprocessing.so','libaaudio.so','libstagefright.so')) | frozenset(f'APK_MODULE_{n:02d}' for n in range(1, 20))

SINGLE_ENGINE_STAGES = frozenset(('START','GUARDS_PASSED','FIXTURE_VERIFIED','DECK_OPTED_IN','ATTACH_BEGIN','ATTACHED',
    'PREPARED','PLAY_BEGIN','PROGRESS_OBSERVED','PENDING_OBSERVED','SESSION_VALID','EQ_BEGIN','EQ_CONFIRMED',
    'PAUSE_BEGIN','PAUSED','SEEK_BEGIN','SEEK_DEFERRED','SEEK_DISPATCHED','SEEK_CONFIRMED','COMMIT_SET','RESUME_BEGIN','COMPLETE_OBSERVED',
    'ENDED_OBSERVED','COVERAGE_VERIFIED','IDENTITIES_VERIFIED','CLEANUP_BEGIN','CLOSE_CONFIRMED','CLEANUP_END','CASE_SUCCESS'))
SINGLE_ENGINE_SEEK_DIAGNOSTICS = frozenset(('SEEK_DEFERRED','SEEK_DISPATCHED'))  # exactly one, right after SEEK_BEGIN
SINGLE_ENGINE_FAILURES = frozenset(('ASSERTION','SECURITY','IO','ILLEGAL_STATE','OTHER','CLEANUP','GUARD','ATTACH_TIMEOUT','ATTACH_REJECTED',
    'PREPARE_TIMEOUT','PROGRESS_TIMEOUT','PENDING_TIMEOUT','SESSION_TIMEOUT','EQ_MISSING','PAUSE_DRIFT','SEEK_TIMEOUT',
    'COMPLETE_TIMEOUT','ENDED_TIMEOUT','COMMIT_MISSING','HIGH_WATER','TAIL_INCOMPLETE','IDENTITY_MISMATCH',
    'UNEXPECTED_RETIREMENT','EARLY_REVOCATION','PLAYER_ERROR'))


REAL_LEASE_STAGES = frozenset(('START','GUARDS_PASSED','FIXTURE_VERIFIED','SERVER_STARTED','DECK_OPTED_IN','BRIDGE_STARTED',
    'PREFIX_SENT','RANGE_HEADER_ABSENT','RANGE_HEADER_PRESENT','ATTACHED','PREPARED','PLAY_BEGIN','PROGRESS_OBSERVED',
    'SEEK_BEGIN','SEEK_DEFERRED','SEEK_DISPATCHED','SEEK_CONFIRMED','POST_SEEK_PROGRESS','TAIL_RELEASED','DOWNLOAD_RESULT',
    'COMMIT_OBSERVED','REJECTION_OBSERVED','CLEANUP_BEGIN','CLOSE_CONFIRMED','CLEANUP_END','CASE_SUCCESS',
    'DIAG_STATE_IDLE','DIAG_STATE_BUFFERING','DIAG_STATE_READY','DIAG_STATE_ENDED','DIAG_PLAY_WHEN_READY','DIAG_NOT_PLAY_WHEN_READY','DIAG_IS_PLAYING',
    'DIAG_NOT_PLAYING','DIAG_POS_ADVANCED_SOME','DIAG_POS_STUCK','DIAG_POS_REGRESSED','DIAG_WRAPPED_PLAYING','DIAG_WRAPPED_NOT_PLAYING'))
REAL_LEASE_FAILURES = frozenset(('ASSERTION','SECURITY','IO','ILLEGAL_STATE','OTHER','CLEANUP','GUARD','SERVER','ATTACH_TIMEOUT',
    'PREPARE_TIMEOUT','PROGRESS_TIMEOUT','SEEK_TIMEOUT','POST_SEEK_TIMEOUT','DOWNLOAD_TIMEOUT','COMMIT_TIMEOUT',
    'UNEXPECTED_ATTACH','REJECTION_MISSING','PLAYER_ERROR','CLOSE_FAILED'))
REAL_LEASE_RANGE = frozenset(('RANGE_HEADER_ABSENT','RANGE_HEADER_PRESENT'))  # exactly one, after PREFIX_SENT
REAL_LEASE_SEEK = frozenset(('SEEK_DEFERRED','SEEK_DISPATCHED'))  # exactly one, right after SEEK_BEGIN
REAL_LEASE_COMMON = ('START','GUARDS_PASSED','FIXTURE_VERIFIED','SERVER_STARTED','DECK_OPTED_IN','BRIDGE_STARTED','PREFIX_SENT')
REAL_LEASE_PLAY = ('ATTACHED','PREPARED','PLAY_BEGIN','PROGRESS_OBSERVED','SEEK_BEGIN','SEEK_CONFIRMED','POST_SEEK_PROGRESS',
    'TAIL_RELEASED','DOWNLOAD_RESULT','COMMIT_OBSERVED')
REAL_LEASE_TAIL = ('CLEANUP_BEGIN','CLOSE_CONFIRMED','CLEANUP_END','CASE_SUCCESS')


TRACE_MAP_CATEGORIES = frozenset(('ANON_OR_JIT', 'APK_CONTAINER', 'UNKNOWN_MAP'))
TRACE_FAULTS = frozenset(('FAULT_NONE', 'FAULT_NULL_PAGE', 'FAULT_OTHER'))
TRACE_MAP_COUNTERS = frozenset(('anon_or_jit', 'apk_container', 'unknown_map'))

FFPROBE_STAGES = frozenset(('FFPROBE_FIXTURE_READY', 'FFPROBE_BEGIN', 'FFPROBE_END_OK', 'FFPROBE_END_ERROR', 'CASE_SUCCESS'))
FFPROBE_CALLS = 4  # 3 sequential on the instrumentation thread + 1 on a plain worker thread


def own_metadata(line):
    match = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_diag_(uid|pid|start_ms)=([0-9]{1,16})', line.strip())
    return (match.group(1), int(match.group(2))) if match else None


def trace_completeness(lines):
    required = {'total','named','missing_name','allowed','unallowed','pc_present','pc_missing','emitted','unknown_fields'}
    counters = {}
    duplicates = False
    signals = []
    frame_count = 0
    other_count = 0
    faults = 0
    for line in lines:
        if re.fullmatch(r'TRACE_OTHER_FRAME (ANON_OR_JIT|APK_CONTAINER|UNKNOWN_MAP)@[0-9a-f]{1,8}', line): other_count += 1
        elif line.startswith('TRACE_OTHER_FRAME '): duplicates = True
        if re.fullmatch(r'TRACE_FAULT (FAULT_NONE|FAULT_NULL_PAGE|FAULT_OTHER)', line): faults += 1
        elif line.startswith('TRACE_FAULT '): duplicates = True
        count = re.fullmatch(r'TRACE_COUNT ([a-z_]+) ([0-9]{1,4})',line)
        if line.startswith('TRACE_COUNT ') and not count:
            duplicates = True
        if count:
            key, value = count.group(1), int(count.group(2))
            if key not in required | TRACE_MAP_COUNTERS or key in counters:
                duplicates = True
            counters[key] = value
        if line.startswith('TRACE_SIGNAL '): signals.append(line)
        if line.startswith('TRACE_FRAME '): frame_count += 1
    # Old traces (no category fields) stay readable. If any new field appears (map
    # counters, other frames, fault), all three map counters must appear and the
    # category invariant must hold; a partial/mixed set is incomplete.
    has_map = set(counters) & TRACE_MAP_COUNTERS
    uses_new = bool(has_map) or other_count > 0 or faults > 0
    complete = (not duplicates and faults <= 1 and set(counters) - TRACE_MAP_COUNTERS == required
        and (has_map == TRACE_MAP_COUNTERS or (not has_map and not uses_new)))
    if complete:
        c = counters
        complete = (all(0 <= v <= (1024 if k == 'unknown_fields' else 256) for k,v in c.items())
            and c['total'] == c['named'] + c['missing_name']
            and c['total'] == c['pc_present'] + c['pc_missing']
            and c['named'] == c['allowed'] + c['unallowed']
            and c['emitted'] <= c['allowed'] and c['emitted'] <= c['pc_present']
            and frame_count == c['emitted'])
        if complete and has_map:
            complete = (c['anon_or_jit'] + c['apk_container'] + c['unknown_map'] == c['total'] - c['allowed']
                and other_count == c['pc_present'] - c['emitted'])
    return {'signal_present':len(signals) == 1, 'counters_complete':bool(complete)}


def trace_command(adb, serial, context, nonce, ended):
    if not re.fullmatch('[a-f0-9]{32}', nonce) or context.get('invalid') or set(context) != {'uid','pid','start_ms'}:
        raise ValueError('OWN_CONTEXT_INVALID')
    if context['uid'] < 10000 or context['pid'] <= 0 or not 0 <= ended-context['start_ms'] <= 180000:
        raise ValueError('OWN_CONTEXT_INVALID')
    return [adb,'-s',serial,'shell','am','instrument','-w','-r','-e','class',
        'com.zarz.mornye.OwnNativeExitTraceInstrumentedTest#collectOnlyExactOwnNativeCrashProjection',
        '-e','diagNonce',nonce,'-e','diagUid',str(context['uid']),'-e','diagPid',str(context['pid']),
        '-e','diagStartEpochMs',str(context['start_ms']),'-e','diagEndEpochMs',str(ended),
        'org.musa.music.catalogintegration.test/androidx.test.runner.AndroidJUnitRunner']


def sanitize(line):
    line = line.strip()
    single = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_single_engine_(stage|failure)=([A-Z_]+)', line)
    if single:
        allowed = SINGLE_ENGINE_STAGES if single.group(1) == 'stage' else SINGLE_ENGINE_FAILURES
        if single.group(2) in allowed:
            return 'SINGLE_' + single.group(1).upper() + ' ' + single.group(2)
        return None
    real = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_real_lease_(stage|failure)=([A-Z_]+)', line)
    if real:
        allowed = REAL_LEASE_STAGES if real.group(1) == 'stage' else REAL_LEASE_FAILURES
        return ('REAL_LEASE_' + real.group(1).upper() + ' ' + real.group(2)) if real.group(2) in allowed else None
    if re.fullmatch(r'INSTRUMENTATION_STATUS: stack=java\.lang\.NoSuchMethodException: xyz\.luan\.audioplayers\.AudioplayersPlugin\$ExperimentalProgressiveDeck\.enableSessionEqForInstrumentation \[\]', line):
        return 'EQ_EXPECTED_MISSING_OPT_IN'
    if line.startswith('Suppressed:') or line.startswith('Caused by:'):
        return 'EQ_ADDITIONAL_EXCEPTION'
    count = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_own_trace_count_(total|named|missing_name|allowed|unallowed|pc_present|pc_missing|emitted|unknown_fields|anon_or_jit|apk_container|unknown_map)=([0-9]{1,4})',line)
    if count and int(count.group(2)) <= (1024 if count.group(1) == 'unknown_fields' else 256):
        return 'TRACE_COUNT ' + count.group(1) + ' ' + count.group(2)
    signal = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_own_trace_signal=([0-9]{1,2})', line)
    if signal and 1 <= int(signal.group(1)) <= 64:
        return 'TRACE_SIGNAL ' + signal.group(1)
    frame = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_own_trace_frame=([a-z0-9_]+\.so|APK_MODULE_[0-9]{2})@([0-9a-f]{1,8})', line)
    if frame and frame.group(1) in TRACE_MODULES:
        return 'TRACE_FRAME ' + frame.group(1) + '@' + frame.group(2)
    other = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_own_trace_other_frame=([A-Z_]+)@([0-9a-f]{1,8})', line)
    if other and other.group(1) in TRACE_MAP_CATEGORIES:
        return 'TRACE_OTHER_FRAME ' + other.group(1) + '@' + other.group(2)
    fault = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_own_trace_fault=([A-Z_]+)', line)
    if fault and fault.group(1) in TRACE_FAULTS:
        return 'TRACE_FAULT ' + fault.group(1)
    ffprobe = re.fullmatch(r'INSTRUMENTATION_STATUS: musa_ffprobe_stage=([A-Z_]+)', line)
    if ffprobe and ffprobe.group(1) in FFPROBE_STAGES:
        return 'FFPROBE_STAGE ' + ffprobe.group(1)
    code = re.fullmatch(r'INSTRUMENTATION_(STATUS_CODE|CODE): (-?\d+)', line)
    if code:
        return code.group(1) + ' ' + code.group(2)
    stage = re.fullmatch(r'INSTRUMENTATION_STATUS: (?:musa_harness_stage|musa_real_song_stage|musa_native_transition_stage)=([A-Z][A-Z0-9_]*)', line)
    if stage and stage.group(1) in STAGES:
        return 'STAGE ' + stage.group(1)
    if line == 'INSTRUMENTATION_RESULT: shortMsg=Process crashed.':
        return 'PROCESS_CRASHED'
    return None


STAGES = set(re.findall(r'^    ([A-Z][A-Z0-9_]+)[,\n]',
    (Path(__file__).parents[2] / 'android/app/src/androidTest/kotlin/com/zarz/mornye/ProgressiveFlutterFinalFileInstrumentedTest.kt').read_text(), re.M))


SCENARIOS = {
    'progressive': ('com.zarz.mornye.ProgressiveFlutterFinalFileInstrumentedTest#dartHandlerRetiresMedia3AndLoadsFinalFilePreservingPauseAndPosition', 1),
    'transition-eq-off': ('com.zarz.mornye.ProgressiveFlutterFinalFileInstrumentedTest#balanceRetirementThenFinalFileWithoutEq', 1),
    'transition-eq-on': ('com.zarz.mornye.ProgressiveFlutterFinalFileInstrumentedTest#balanceRetirementThenFinalFileWithEq', 1),
    'native-transition-off': ('com.zarz.mornye.NativeMedia3FinalWrapperInstrumentedTest#balanceRetirementToFinalWrapperWithoutEq', 1),
    'native-transition-on': ('com.zarz.mornye.NativeMedia3FinalWrapperInstrumentedTest#balanceRetirementToFinalWrapperWithEq', 1),
    'real-song-off': ('com.zarz.mornye.RealSongMediaPlayerEqInstrumentedTest#originalMp3MediaPlayerWithoutEq', 1),
    'real-song-on': ('com.zarz.mornye.RealSongMediaPlayerEqInstrumentedTest#originalMp3MediaPlayerWithProductiveEq', 1),
    'synthetic-aac-off': ('com.zarz.mornye.RealSongMediaPlayerEqInstrumentedTest#syntheticAacMediaPlayerWithoutEq', 1),
    'synthetic-aac-on': ('com.zarz.mornye.RealSongMediaPlayerEqInstrumentedTest#syntheticAacMediaPlayerWithProductiveEq', 1),
    'media3-eq-default': ('com.zarz.mornye.Media3SessionEqRouteInstrumentedTest#defaultRouteStillRetiresOnEqualizerEnable', 1),
    'media3-eq-enabled': ('com.zarz.mornye.Media3SessionEqRouteInstrumentedTest#optedInRouteKeepsSameEngineAcrossOffOnAndReleases', 1),
    'media3-eq-failure': ('com.zarz.mornye.Media3SessionEqRouteInstrumentedTest#optedInConfigurationFailureRetiresInsteadOfClaimingApplied', 1),
    'media3-eq-no-session': ('com.zarz.mornye.Media3SessionEqRouteInstrumentedTest#optedInMissingSessionRetiresInsteadOfClaimingApplied', 1),
    'media3-eq-owner-default': ('com.zarz.mornye.Media3SessionEqRouteInstrumentedTest#removedOptInDoesNotCarryToReplacementDeck', 1),
    'media3-eq-owner-replaced': ('com.zarz.mornye.Media3SessionEqRouteInstrumentedTest#oldDeckLateCloseDoesNotRevokeReplacementOptIn', 1),
    'ffprobe-fixture': ('com.zarz.mornye.FfprobeFixtureInstrumentedTest#ffprobeMediaInformationOnSyntheticFinalFileSurvivesRepeatedAndOffMainThreadCalls', 1),
    'single-engine-commit': ('com.zarz.mornye.Media3SingleEngineCommitInstrumentedTest#partialCommitSeekAndEofKeepTheSameMedia3EngineAndEffect', 1),
    'real-lease-aac': ('com.zarz.mornye.RealLeaseMedia3InstrumentedTest#fragmentedAacFixtureStreamsThroughRealLease', 1),
    'real-lease-sidx': ('com.zarz.mornye.RealLeaseMedia3InstrumentedTest#seekableSidxFixtureStreamsThroughRealLease', 1),
    'real-lease-mp3': ('com.zarz.mornye.RealLeaseMedia3InstrumentedTest#mp3FixtureIsRejectedByProvisionalFmp4Gate', 1),
}
REAL_LEASE_SCENARIOS = {'real-lease-aac': True, 'real-lease-sidx': True, 'real-lease-mp3': False}  # value: expects a lease to play
EQ_RED_SCENARIOS = frozenset(('media3-eq-enabled', 'media3-eq-failure', 'media3-eq-no-session'))
REAL_SONG_SOURCE = Path(__file__).parents[2] / 'android/app/src/androidTest/kotlin/com/zarz/mornye/RealSongMediaPlayerEqInstrumentedTest.kt'
REAL_SONG_STAGES = set(re.findall(r'\b[A-Z][A-Z0-9_]+\b', REAL_SONG_SOURCE.read_text().split('private enum class Stage {', 1)[1].split('}', 1)[0]))
STAGES.update(REAL_SONG_STAGES)
NATIVE_TRANSITION_SOURCE = Path(__file__).parents[2] / 'android/app/src/androidTest/kotlin/com/zarz/mornye/NativeMedia3FinalWrapperInstrumentedTest.kt'
NATIVE_TRANSITION_STAGES = set(re.findall(r'\b[A-Z][A-Z0-9_]+\b', NATIVE_TRANSITION_SOURCE.read_text().split('private enum class Stage {', 1)[1].split('}', 1)[0]))
STAGES.update(NATIVE_TRANSITION_STAGES)


def bounded_lines(stream, on_truncated=lambda: None):
    """Drop oversized lines without accumulating unbounded producer input."""
    pending = ''
    discard = False
    decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
    try:
        descriptor = stream.fileno()
    except (AttributeError, OSError):
        descriptor = None
    while True:
        raw = os.read(descriptor, 2048) if descriptor is not None else stream.read(2048)
        chunk = decoder.decode(raw, final=not raw) if isinstance(raw, bytes) else raw
        if not raw:
            if pending and not discard:
                yield pending
            return
        for character in chunk:
            if character == '\n':
                if not discard:
                    yield pending
                pending = ''
                discard = False
            elif not discard:
                if len(pending) >= 4096:
                    pending = ''
                    discard = True
                    on_truncated()
                else:
                    pending += character


def verdict(values, exit_code, timed_out, joined, expected_cases=1):
    case_codes = [x for x in values if x.startswith('STATUS_CODE ')]
    final_codes = [x for x in values if x.startswith('CODE ')]
    return (exit_code == 0 and not timed_out and joined
        and 'PROCESS_CRASHED' not in values
        and case_codes.count('STATUS_CODE 0') == expected_cases
        and all(x in ('STATUS_CODE 1', 'STATUS_CODE 2', 'STATUS_CODE 0') for x in case_codes)
        and final_codes == ['CODE -1'])


def expected_eq_red(scenario, values, result):
    """Only the exact missing opt-in and a complete single failed case qualify."""
    codes = [x for x in values if x.startswith('STATUS_CODE ')]
    finals = [x for x in values if x.startswith('CODE ')]
    return (scenario in EQ_RED_SCENARIOS and result['exit_code'] == 0
        and not result['timed_out'] and result['reader_joined']
        and not result['reader_error'] and not result['loss'] and not result['line_truncated']
        and not result['process_crashed'] and not result['passed']
        and 'PROCESS_CRASHED' not in values
        and values.count('EQ_EXPECTED_MISSING_OPT_IN') == 1
        and 'EQ_ADDITIONAL_EXCEPTION' not in values
        and codes.count('STATUS_CODE 1') == 1 and codes.count('STATUS_CODE -2') == 1
        and all(x in ('STATUS_CODE 1', 'STATUS_CODE 2', 'STATUS_CODE -2') for x in codes)
        and finals == ['CODE -1'])


def single_engine_complete(values):
    stages = [value.removeprefix('SINGLE_STAGE ') for value in values if value.startswith('SINGLE_STAGE ')]
    seek = [x for x in stages if x in SINGLE_ENGINE_SEEK_DIAGNOSTICS]
    required = SINGLE_ENGINE_STAGES - SINGLE_ENGINE_SEEK_DIAGNOSTICS
    rest = [x for x in stages if x not in SINGLE_ENGINE_SEEK_DIAGNOSTICS]
    return (len(seek) == 1 and 'SEEK_BEGIN' in stages and stages.index(seek[0]) == stages.index('SEEK_BEGIN') + 1
        and len(rest) == len(required) and set(rest) == required
        and stages[-1:] == ['CASE_SUCCESS'] and not any(x.startswith('SINGLE_FAILURE ') for x in values))


def real_lease_complete(values, expect_lease):
    """Exact ordered sequence; lease cases need the full play/seek/commit path, the MP3 case needs a clean gate rejection."""
    if any(x.startswith('REAL_LEASE_FAILURE ') for x in values):
        return False
    stages = [x.removeprefix('REAL_LEASE_STAGE ') for x in values if x.startswith('REAL_LEASE_STAGE ')]
    common = len(REAL_LEASE_COMMON)
    if stages[:common] != list(REAL_LEASE_COMMON) or len(stages) <= common or stages[common] not in REAL_LEASE_RANGE:
        return False
    rest = stages[common + 1:]
    if expect_lease:
        if 'SEEK_BEGIN' not in rest:
            return False
        at = rest.index('SEEK_BEGIN')
        if len(rest) <= at + 1 or rest[at + 1] not in REAL_LEASE_SEEK:
            return False
        rest = rest[:at + 1] + rest[at + 2:]
        return rest == list(REAL_LEASE_PLAY) + list(REAL_LEASE_TAIL)
    return rest == ['REJECTION_OBSERVED'] + list(REAL_LEASE_TAIL)


def real_lease_observations(values):
    """Closed facts for the report: Range header presence and whether the seek was deferred."""
    stages = {x.removeprefix('REAL_LEASE_STAGE ') for x in values if x.startswith('REAL_LEASE_STAGE ')}
    return {'range_header_present': 'RANGE_HEADER_PRESENT' in stages, 'seek_deferred': 'SEEK_DEFERRED' in stages,
            'seek_confirmed': 'SEEK_CONFIRMED' in stages,
            'played_with_partial_download': 'PROGRESS_OBSERVED' in stages and 'TAIL_RELEASED' in stages,
            'committed': 'COMMIT_OBSERVED' in stages, 'rejected_by_gate': 'REJECTION_OBSERVED' in stages}


def ffprobe_stages(values):
    return [value.removeprefix('FFPROBE_STAGE ') for value in values if value.startswith('FFPROBE_STAGE ')]


def ffprobe_complete(values):
    """Exactly FIXTURE_READY, FFPROBE_CALLS x (BEGIN -> END_OK), CASE_SUCCESS, in order, no failure marker."""
    expected = ['FFPROBE_FIXTURE_READY'] + ['FFPROBE_BEGIN', 'FFPROBE_END_OK'] * FFPROBE_CALLS + ['CASE_SUCCESS']
    return ffprobe_stages(values) == expected


def ffprobe_open_begin(values):
    """True when a BEGIN has no END_* after it: the process died (or hung) inside ffprobe. Never a success."""
    stages = ffprobe_stages(values)
    last_begin = max((i for i, x in enumerate(stages) if x == 'FFPROBE_BEGIN'), default=-1)
    return last_begin >= 0 and not any(x in ('FFPROBE_END_OK', 'FFPROBE_END_ERROR') for x in stages[last_begin + 1:])


def collect(command, deadline, destination, queue_limit=1024, byte_limit=262144, expected_cases=1, owner_context=None):
    """Bounded child and reader lifecycle; no raw child output is persisted."""
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding='utf-8', errors='replace')
    output = queue.Queue(maxsize=queue_limit)
    loss = threading.Event()
    truncation = threading.Event()
    reader_error = threading.Event()
    done = threading.Event()
    def read():
        try:
            for line in bounded_lines(proc.stdout, lambda: (truncation.set(), loss.set())):
                if owner_context is not None:
                    meta = own_metadata(line)
                    if meta:
                        key, number = meta
                        if key in owner_context: owner_context['invalid'] = True
                        else: owner_context[key] = number
                value = sanitize(line)
                if value:
                    try:
                        output.put_nowait(value)
                    except queue.Full:
                        loss.set()
        except Exception:
            reader_error.set()
            loss.set()
        finally:
            done.set()
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    stop = time.monotonic() + deadline
    kept = []
    size = 0
    timed_out = False
    try:
        while proc.poll() is None or not done.is_set():
            if time.monotonic() >= stop:
                timed_out = True
                break
            try:
                value = output.get(timeout=.05)
                if size + len(value) + 1 <= byte_limit:
                    kept.append(value)
                    size += len(value) + 1
                else:
                    loss.set()
            except queue.Empty:
                pass
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
        reader.join(timeout=2)
        if not reader.is_alive():
            proc.stdout.close()
        while not output.empty():
            value = output.get_nowait()
            if size + len(value) + 1 <= byte_limit:
                kept.append(value)
                size += len(value) + 1
            else:
                loss.set()
        data = ('\n'.join(kept) + ('\n' if kept else '')).encode()
        destination.write_bytes(data)
        result = dict(exit_code=proc.returncode, timed_out=timed_out,
            reader_joined=not reader.is_alive(), process_crashed='PROCESS_CRASHED' in kept,
            reader_error=reader_error.is_set(), loss=loss.is_set(), line_truncated=truncation.is_set(),
            passed=not loss.is_set() and verdict(kept, proc.returncode, timed_out, not reader.is_alive(), expected_cases), sha256=hashlib.sha256(data).hexdigest())
        destination.with_suffix('.json').write_text(json.dumps(result, indent=2))
    return result


def main():
    p = argparse.ArgumentParser()
    for name in ('adb', 'serial', 'device-time', 'output'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--correlate-own-crash', action='store_true')
    p.add_argument('--scenario', choices=tuple(SCENARIOS), default='progressive')
    p.add_argument('--uid', required=True, type=int)
    args = p.parse_args()
    if not valid_epoch(args.device_time):
        p.error('Require device-time epoch.mmm')
    if args.correlate_own_crash and args.scenario not in ('progressive','transition-eq-off','transition-eq-on'):
        p.error('Correlation only supports the fixed integrated harness')
    nonce = secrets.token_hex(16) if args.correlate_own_crash else None
    owner_context = {} if nonce is not None else None
    trace_result = None
    root = Path(args.output)
    root.mkdir(parents=True, exist_ok=False)
    stop = root / 'stop-reader'
    capture = root / 'uid'
    helper = subprocess.Popen([sys.executable, str(Path(__file__).with_name('capture_uid_logcat.py')),
        '--adb', args.adb, '--serial', args.serial, '--uid', str(args.uid),
        '--device-time', args.device_time, '--output', str(capture),
        '--stop-file', str(stop), '--seconds', '165'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ready_deadline = time.monotonic() + 8
        while not (capture / 'ready').exists():
            if helper.poll() is not None or time.monotonic() >= ready_deadline:
                raise RuntimeError('UID_READER_NOT_READY')
            time.sleep(.05)
        result = collect([args.adb, '-s', args.serial, 'shell', 'am', 'instrument', '-w', '-r',
            '-e', 'class', SCENARIOS[args.scenario][0],
            *(['-e','diagNonce',nonce] if nonce is not None else []),
            'org.musa.music.catalogintegration.test/androidx.test.runner.AndroidJUnitRunner'],
            150, root / 'instrumentation-sanitized.txt', expected_cases=SCENARIOS[args.scenario][1], owner_context=owner_context)
        if args.scenario in EQ_RED_SCENARIOS:
            values = (root / 'instrumentation-sanitized.txt').read_text().splitlines()
            result['expected_eq_red'] = expected_eq_red(args.scenario, values, result)
            (root / 'instrumentation-sanitized.json').write_text(json.dumps(result, indent=2))
        if args.scenario == 'single-engine-commit':
            values = (root / 'instrumentation-sanitized.txt').read_text().splitlines()
            result['markers_complete'] = single_engine_complete(values)
            result['passed'] = result['passed'] and result['markers_complete']
            (root / 'instrumentation-sanitized.json').write_text(json.dumps(result, indent=2))
        if args.scenario in REAL_LEASE_SCENARIOS:
            values = (root / 'instrumentation-sanitized.txt').read_text().splitlines()
            result['markers_complete'] = real_lease_complete(values, REAL_LEASE_SCENARIOS[args.scenario])
            result['observations'] = real_lease_observations(values)
            result['passed'] = result['passed'] and result['markers_complete']
            (root / 'instrumentation-sanitized.json').write_text(json.dumps(result, indent=2))
        if args.scenario == 'ffprobe-fixture':
            values = (root / 'instrumentation-sanitized.txt').read_text().splitlines()
            result['markers_complete'] = ffprobe_complete(values)
            result['ffprobe_open_begin'] = ffprobe_open_begin(values)
            result['passed'] = result['passed'] and result['markers_complete']
            (root / 'instrumentation-sanitized.json').write_text(json.dumps(result, indent=2))
        run_failed = not result['passed']
    finally:
        stop.touch()
        try:
            helper.wait(timeout=10)
        except subprocess.TimeoutExpired:
            helper.terminate()
            try:
                helper.wait(timeout=3)
            except subprocess.TimeoutExpired:
                helper.kill()
                helper.wait(timeout=3)
        # Parent must verify persisted UID summary before proceeding to uninstall.
        (root / 'supervisor.json').write_text(json.dumps(dict(
            uid_helper_exit=helper.returncode,
            uid_capture_persisted=(capture / 'summary.json').is_file(),
            cleanup_scope='own host children only; caller must uninstall approved packages'), indent=2))

    # This follow-up starts only after the original UID capture has been saved.
    if nonce is not None and result['process_crashed']:
        if (helper.returncode != 0 or result['loss'] or result['reader_error'] or not result['reader_joined'] or result['timed_out'] or
            owner_context.get('uid') != args.uid or owner_context.get('start_ms',0) < int(float(args.device_time)*1000)):
            raise RuntimeError('OWN_CONTEXT_UNCONFIRMED')
        first = subprocess.run([args.adb,'-s',args.serial,'shell','date','+%s'],
            stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=5)
        if first.returncode or not re.fullmatch(r'[1-9][0-9]{9,12}\s*',first.stdout):
            raise RuntimeError('DEVICE_CLOCK_UNCONFIRMED')
        time.sleep(1.1)
        last = subprocess.run([args.adb,'-s',args.serial,'shell','date','+%s'],
            stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=5)
        if last.returncode or not re.fullmatch(r'[1-9][0-9]{9,12}\s*',last.stdout) or int(last.stdout) <= int(first.stdout):
            raise RuntimeError('DEVICE_CLOCK_UNCONFIRMED')
        ended = int(last.stdout)*1000
        command = trace_command(args.adb,args.serial,owner_context,nonce,ended)
        trace_result = collect(command,15,root/'own-trace-sanitized.txt')
        coverage = trace_completeness((root/'own-trace-sanitized.txt').read_text().splitlines())
        (root/'own-trace-summary.json').write_text(json.dumps(dict(
            requested=True, passed=trace_result['passed'] and coverage['signal_present'] and coverage['counters_complete'],
            signal_valid=trace_result['passed'] and coverage['signal_present'],
            counters_complete=coverage['counters_complete'], raw_trace_persisted=False),indent=2))

    return 1 if run_failed or helper.returncode != 0 or not (capture / 'summary.json').is_file() else 0


if __name__ == '__main__':
    raise SystemExit(main())
