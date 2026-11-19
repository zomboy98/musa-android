import importlib.util
import tempfile
import unittest
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('subject', Path(__file__).with_name('instrument_once.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class SupervisorTest(unittest.TestCase):
    def test_helper_simulated_stderr_is_classified_before_persistence(self):
        from unittest.mock import patch
        import subprocess
        import json
        import capture_uid_logcat as capture
        real_popen = subprocess.Popen
        def fake_adb(*args, **kwargs):
            return real_popen([sys.executable, '-c', 'import sys; print("invalid time SECRET_TOKEN", file=sys.stderr); raise SystemExit(1)'], **kwargs)
        with tempfile.TemporaryDirectory() as d:
            output = Path(d) / 'capture'
            argv = ['capture', '--adb', 'NOT_EXECUTED', '--serial', 'SIMULATED', '--uid', '12345', '--device-time', '1794492223.000', '--output', str(output), '--stop-file', str(Path(d) / 'stop')]
            with patch.object(sys, 'argv', argv), patch.object(capture.subprocess, 'Popen', fake_adb):
                self.assertEqual(1, capture.main())
            summary = json.loads((output / 'summary.json').read_text())
            self.assertEqual(['TIME_ARGUMENT'], summary['stderr_categories'])
            self.assertTrue(summary['stderr_reader_joined'])
            self.assertNotIn('SECRET', ''.join(p.read_text() for p in output.iterdir() if p.is_file()))
    def test_collect_stream_exception_fails_closed_without_text(self):
        from unittest.mock import patch
        def broken(stream, callback):
            yield 'INSTRUMENTATION_STATUS_CODE: 0'
            yield 'INSTRUMENTATION_CODE: -1'
            raise OSError('SECRET_TOKEN')
        with tempfile.TemporaryDirectory() as d, patch.object(m, 'bounded_lines', broken):
            result = m.collect([sys.executable, '-c', 'pass'], 3, Path(d) / 'result.txt')
            self.assertTrue(result['reader_error'])
            self.assertTrue(result['loss'])
            self.assertFalse(result['passed'])
            self.assertNotIn('SECRET', str(result))
    def test_helper_stream_exceptions_fail_closed(self):
        from unittest.mock import patch
        import subprocess
        import json
        import capture_uid_logcat as capture
        real_popen = subprocess.Popen
        def fake_adb(*args, **kwargs):
            return real_popen([sys.executable, '-c', 'pass'], **kwargs)
        def broken(*args):
            raise OSError('SECRET_TOKEN')
            yield
        with tempfile.TemporaryDirectory() as d:
            output = Path(d) / 'capture'
            argv = ['capture', '--adb', 'NOT_EXECUTED', '--serial', 'SIMULATED', '--uid', '12345', '--device-time', '1794492223.000', '--output', str(output), '--stop-file', str(Path(d) / 'stop')]
            with patch.object(sys, 'argv', argv), patch.object(capture.subprocess, 'Popen', fake_adb), patch.object(capture, 'bounded_lines', broken):
                self.assertEqual(1, capture.main())
            summary = json.loads((output / 'summary.json').read_text())
            self.assertTrue(summary['reader_error'])
            self.assertTrue(summary['stderr_reader_error'])
            self.assertTrue(summary['loss'])
            self.assertNotIn('SECRET', str(summary))
    def test_real_song_methods_are_fixed_and_individually_require_one_case(self):
        self.assertNotIn('real-song', m.SCENARIOS)
        self.assertEqual(('com.zarz.mornye.RealSongMediaPlayerEqInstrumentedTest#originalMp3MediaPlayerWithoutEq', 1), m.SCENARIOS['real-song-off'])
        self.assertEqual(('com.zarz.mornye.RealSongMediaPlayerEqInstrumentedTest#originalMp3MediaPlayerWithProductiveEq', 1), m.SCENARIOS['real-song-on'])
        for scenario in ('real-song-off', 'real-song-on'):
            expected = m.SCENARIOS[scenario][1]
            self.assertTrue(m.verdict(['STATUS_CODE 1', 'STATUS_CODE 0', 'CODE -1'], 0, False, True, expected))
            for values in ([], ['STATUS_CODE 0', 'STATUS_CODE 0', 'CODE -1'], ['STATUS_CODE -2', 'CODE -1'], ['PROCESS_CRASHED', 'CODE 0']):
                self.assertFalse(m.verdict(values, 0, False, True, expected))
        self.assertEqual('STAGE EQ_BEGIN', m.sanitize('INSTRUMENTATION_STATUS: musa_real_song_stage=EQ_BEGIN'))
    def test_aac_methods_are_fixed_and_individually_require_one_case(self):
        self.assertEqual(('com.zarz.mornye.RealSongMediaPlayerEqInstrumentedTest#syntheticAacMediaPlayerWithoutEq', 1), m.SCENARIOS['synthetic-aac-off'])
        self.assertEqual(('com.zarz.mornye.RealSongMediaPlayerEqInstrumentedTest#syntheticAacMediaPlayerWithProductiveEq', 1), m.SCENARIOS['synthetic-aac-on'])
        for scenario in ('synthetic-aac-off', 'synthetic-aac-on'):
            expected = m.SCENARIOS[scenario][1]
            self.assertTrue(m.verdict(['STATUS_CODE 0', 'CODE -1'], 0, False, True, expected))
            for values in ([], ['STATUS_CODE 0', 'STATUS_CODE 0', 'CODE -1'], ['STATUS_CODE -2', 'CODE -1'], ['PROCESS_CRASHED', 'CODE 0']):
                self.assertFalse(m.verdict(values, 0, False, True, expected))
        self.assertEqual('STAGE AAC_ON_BEGIN', m.sanitize('INSTRUMENTATION_STATUS: musa_real_song_stage=AAC_ON_BEGIN'))
    def test_transition_scenarios_select_one_fixed_method(self):
        for scenario, method in [('transition-eq-off', 'balanceRetirementThenFinalFileWithoutEq'), ('transition-eq-on', 'balanceRetirementThenFinalFileWithEq')]:
            self.assertEqual(('com.zarz.mornye.ProgressiveFlutterFinalFileInstrumentedTest#' + method, 1), m.SCENARIOS[scenario])
            self.assertTrue(m.verdict(['STATUS_CODE 0', 'CODE -1'], 0, False, True, 1))
            self.assertFalse(m.verdict(['STATUS_CODE -2', 'CODE -1'], 0, False, True, 1))
        self.assertIn('#', m.SCENARIOS['progressive'][0])
    def test_media3_eq_scenarios_are_fixed_and_exactly_one_case(self):
        expected = {
            'media3-eq-default': 'defaultRouteStillRetiresOnEqualizerEnable',
            'media3-eq-enabled': 'optedInRouteKeepsSameEngineAcrossOffOnAndReleases',
            'media3-eq-failure': 'optedInConfigurationFailureRetiresInsteadOfClaimingApplied',
            'media3-eq-no-session': 'optedInMissingSessionRetiresInsteadOfClaimingApplied',
            'media3-eq-owner-default': 'removedOptInDoesNotCarryToReplacementDeck',
            'media3-eq-owner-replaced': 'oldDeckLateCloseDoesNotRevokeReplacementOptIn',
        }
        for scenario, method in expected.items():
            self.assertEqual(('com.zarz.mornye.Media3SessionEqRouteInstrumentedTest#' + method, 1), m.SCENARIOS[scenario])
            self.assertFalse(m.verdict(['STATUS_CODE 1','STATUS_CODE -2','CODE -1'],0,False,True,1))
            self.assertFalse(m.verdict(['STATUS_CODE 1','PROCESS_CRASHED','CODE 0'],0,False,True,1))
        self.assertNotIn('com.attacker.ArbitraryTest', m.SCENARIOS)

    def test_single_engine_commit_is_fixed_and_rejects_incomplete_results(self):
        self.assertEqual(('com.zarz.mornye.Media3SingleEngineCommitInstrumentedTest#partialCommitSeekAndEofKeepTheSameMedia3EngineAndEffect', 1), m.SCENARIOS['single-engine-commit'])
        self.assertTrue(m.verdict(['STATUS_CODE 1', 'STATUS_CODE 0', 'CODE -1'], 0, False, True, 1))
        for bad in ([], ['STATUS_CODE -2','CODE -1'], ['STATUS_CODE 0'], ['STATUS_CODE 0','STATUS_CODE 0','CODE -1'], ['PROCESS_CRASHED','CODE 0']):
            self.assertFalse(m.verdict(bad, 0, False, True, 1))
        self.assertFalse(m.verdict(['STATUS_CODE 0','CODE -1'], 0, True, True, 1))

    def test_single_engine_markers_are_closed_and_never_retain_payload(self):
        for stage in m.SINGLE_ENGINE_STAGES:
            self.assertEqual('SINGLE_STAGE '+stage,m.sanitize('INSTRUMENTATION_STATUS: musa_single_engine_stage='+stage))
        for kind in m.SINGLE_ENGINE_FAILURES:
            self.assertEqual('SINGLE_FAILURE '+kind,m.sanitize('INSTRUMENTATION_STATUS: musa_single_engine_failure='+kind))
        for payload in ('musa_single_engine_stage=SECRET','musa_single_engine_stage=COMMIT_SET SECRET',
                        'musa_single_engine_failure=java.lang.Exception','musa_single_engine_failure=IO SECRET',
                        'musa_single_engine_stage=/private/path'):
            self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: '+payload))
        base = ['SINGLE_STAGE '+x for x in sorted(m.SINGLE_ENGINE_STAGES - m.SINGLE_ENGINE_SEEK_DIAGNOSTICS - {'CASE_SUCCESS'})]
        def with_seek(mark):
            at = base.index('SINGLE_STAGE SEEK_BEGIN') + 1
            return base[:at] + ([mark] if mark else []) + base[at:] + ['SINGLE_STAGE CASE_SUCCESS']
        for mark in ('SEEK_DEFERRED', 'SEEK_DISPATCHED'):
            self.assertEqual('SINGLE_STAGE '+mark, m.sanitize('INSTRUMENTATION_STATUS: musa_single_engine_stage='+mark))
            self.assertTrue(m.single_engine_complete(with_seek('SINGLE_STAGE '+mark)))
        self.assertEqual(frozenset(('SEEK_DEFERRED','SEEK_DISPATCHED')), m.SINGLE_ENGINE_SEEK_DIAGNOSTICS)
        self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: musa_single_engine_stage=SEEK_UNKNOWN'))
        self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: musa_single_engine_stage=SEEK_DEFERRED SECRET'))
        self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: musa_single_engine_failure=SEEK_DEFERRED'))
        stages = with_seek('SINGLE_STAGE SEEK_DEFERRED')
        late = with_seek(None)[:-1] + ['SINGLE_STAGE SEEK_DISPATCHED', 'SINGLE_STAGE CASE_SUCCESS']
        for bad in (with_seek(None), stages[:-1], stages+['SINGLE_STAGE START'], stages+['SINGLE_FAILURE CLEANUP'], ['SINGLE_STAGE CASE_SUCCESS']+stages[:-1],
                    with_seek('SINGLE_STAGE SEEK_DEFERRED')[:-1] + ['SINGLE_STAGE SEEK_DISPATCHED', 'SINGLE_STAGE CASE_SUCCESS'], late):
            self.assertFalse(m.single_engine_complete(bad))

    def test_real_lease_markers_are_closed_and_sequences_exact(self):
        for stage in m.REAL_LEASE_STAGES:
            self.assertEqual('REAL_LEASE_STAGE '+stage,m.sanitize('INSTRUMENTATION_STATUS: musa_real_lease_stage='+stage))
        for kind in m.REAL_LEASE_FAILURES:
            self.assertEqual('REAL_LEASE_FAILURE '+kind,m.sanitize('INSTRUMENTATION_STATUS: musa_real_lease_failure='+kind))
        for payload in ('musa_real_lease_stage=SECRET','musa_real_lease_stage=PREPARED SECRET','musa_real_lease_failure=java.lang.Exception',
                        'musa_real_lease_failure=PREPARED','musa_real_lease_stage=/private/path'):
            self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: '+payload))
        for name, expects in (('real-lease-aac',True),('real-lease-sidx',True),('real-lease-mp3',False)):
            self.assertEqual(1, m.SCENARIOS[name][1]); self.assertEqual(expects, m.REAL_LEASE_SCENARIOS[name])
        def seq(expect, range_mark='RANGE_HEADER_ABSENT', seek='SEEK_DISPATCHED'):
            body = list(m.REAL_LEASE_PLAY) if expect else ['REJECTION_OBSERVED']
            if expect:
                at = body.index('SEEK_BEGIN'); body.insert(at + 1, seek)
            return ['REAL_LEASE_STAGE '+x for x in list(m.REAL_LEASE_COMMON)+[range_mark]+body+list(m.REAL_LEASE_TAIL)]
        for expect in (True, False):
            self.assertTrue(m.real_lease_complete(seq(expect), expect))
        self.assertTrue(m.real_lease_complete(seq(True,'RANGE_HEADER_PRESENT','SEEK_DEFERRED'), True))
        good = seq(True)
        for bad in (good[:-1], good+['REAL_LEASE_FAILURE CLEANUP'], good[:8]+good[9:], [x for x in good if x != 'REAL_LEASE_STAGE SEEK_DISPATCHED'],
                    good[:1]+good, seq(False)):
            self.assertFalse(m.real_lease_complete(bad, True))
        self.assertFalse(m.real_lease_complete(seq(True), False))
        obs = m.real_lease_observations(good)
        self.assertTrue(obs['seek_confirmed'] and obs['committed'] and not obs['rejected_by_gate'] and not obs['range_header_present'])

    def test_expected_eq_red_is_exact_and_fail_closed(self):
        exact = 'INSTRUMENTATION_STATUS: stack=java.lang.NoSuchMethodException: xyz.luan.audioplayers.AudioplayersPlugin$ExperimentalProgressiveDeck.enableSessionEqForInstrumentation []'
        marker = m.sanitize(exact)
        self.assertEqual('EQ_EXPECTED_MISSING_OPT_IN', marker)
        values = ['STATUS_CODE 1', marker, 'STATUS_CODE -2', 'CODE -1']
        result = dict(exit_code=0,timed_out=False,reader_joined=True,reader_error=False,loss=False,line_truncated=False,process_crashed=False,passed=False)
        self.assertTrue(m.expected_eq_red('media3-eq-enabled',values,result))
        for scenario in ('media3-eq-default','progressive','arbitrary'):
            self.assertFalse(m.expected_eq_red(scenario,values,result))
        for bad in (exact+' SECRET',exact.replace('enableSessionEqForInstrumentation','otherMethod'),exact.replace('NoSuchMethodException','IllegalStateException'),exact.replace('xyz.luan.audioplayers','private.path')):
            self.assertIsNone(m.sanitize(bad))
        for other in (values+['EQ_ADDITIONAL_EXCEPTION'],values+['PROCESS_CRASHED'],['STATUS_CODE 1','STATUS_CODE -2','CODE -1'],['STATUS_CODE 1',marker,'STATUS_CODE 0','CODE -1'],values+['STATUS_CODE -2']):
            self.assertFalse(m.expected_eq_red('media3-eq-enabled',other,result))
        for key in ('timed_out','reader_error','loss','line_truncated','process_crashed','passed'):
            self.assertFalse(m.expected_eq_red('media3-eq-enabled',values,dict(result,**{key:True})))
        self.assertFalse(m.expected_eq_red('media3-eq-enabled',values,dict(result,reader_joined=False)))
        self.assertFalse(m.expected_eq_red('media3-eq-enabled',values,dict(result,exit_code=1)))
        self.assertFalse(m.verdict(values,0,False,True,1))

    def test_eq_red_collection_drops_private_stack_and_rejects_crash(self):
        exact = 'INSTRUMENTATION_STATUS: stack=java.lang.NoSuchMethodException: xyz.luan.audioplayers.AudioplayersPlugin$ExperimentalProgressiveDeck.enableSessionEqForInstrumentation []'
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'case.txt'
            script = 'print("INSTRUMENTATION_STATUS_CODE: 1");print(' + repr(exact) + ');print("secret path /PRIVATE/SENTINEL");print("INSTRUMENTATION_STATUS_CODE: -2");print("INSTRUMENTATION_CODE: -1")'
            result = m.collect([sys.executable,'-c',script],3,out)
            self.assertFalse(result['passed'])
            self.assertTrue(m.expected_eq_red('media3-eq-enabled',out.read_text().splitlines(),result))
            self.assertNotIn('SENTINEL',out.read_text()+out.with_suffix('.json').read_text())
            crash = Path(d) / 'crash.txt'
            script = 'print("INSTRUMENTATION_STATUS_CODE: 1");print(' + repr(exact) + ');print("INSTRUMENTATION_RESULT: shortMsg=Process crashed.");print("INSTRUMENTATION_STATUS_CODE: -2");print("INSTRUMENTATION_CODE: -1")'
            result = m.collect([sys.executable,'-c',script],3,crash)
            self.assertFalse(m.expected_eq_red('media3-eq-enabled',crash.read_text().splitlines(),result))
    def test_relative_frames_require_verified_own_pid_and_library(self):
        import capture_uid_logcat as capture
        line = '11-12 12:00:00.123 12345 12346 F DEBUG : #00 pc 000000000001abcd /apex/SECRET_PATH/lib64/libflutter.so (SECRET_SYMBOL+42)'
        expected = 'CRASH_FRAME MODULE libflutter.so RELATIVE_PC 1abcd'
        self.assertEqual(expected, capture.own_relative_frame(line, {12345}))
        self.assertNotIn('SECRET', capture.own_relative_frame(line, {12345}))
        self.assertIsNone(capture.own_relative_frame(line, set()))
        self.assertIsNone(capture.own_relative_frame(line, {99999}))
        for bad in (line.replace('libflutter.so', 'SECRET.so'), line.replace('000000000001abcd', 'ffffffffffffffff'), line.replace('#00 pc', 'pc'), line.replace('F DEBUG', 'F libc'), line + ' SECRET', line + 'X'*5000):
            self.assertIsNone(capture.own_relative_frame(bad, {12345}))
    def test_native_transition_methods_are_fixed_one_case(self):
        for scenario, method in [('native-transition-off', 'balanceRetirementToFinalWrapperWithoutEq'), ('native-transition-on', 'balanceRetirementToFinalWrapperWithEq')]:
            self.assertEqual(('com.zarz.mornye.NativeMedia3FinalWrapperInstrumentedTest#' + method, 1), m.SCENARIOS[scenario])
            self.assertTrue(m.verdict(['STATUS_CODE 0', 'CODE -1'], 0, False, True, 1))
            for values in ([], ['STATUS_CODE -2', 'CODE -1'], ['STATUS_CODE 0','STATUS_CODE 0','CODE -1'], ['PROCESS_CRASHED','CODE 0']):
                self.assertFalse(m.verdict(values, 0, False, True, 1))
        self.assertEqual('STAGE FINAL_SEEK_COMPLETE', m.sanitize('INSTRUMENTATION_STATUS: musa_native_transition_stage=FINAL_SEEK_COMPLETE'))
    def test_private_context_and_nonce_are_not_persisted(self):
        import json
        context = {}
        nonce = 'a'*32
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)/'result.txt'
            script = 'print("INSTRUMENTATION_STATUS: musa_diag_uid=12345"); print("INSTRUMENTATION_STATUS: musa_diag_pid=456"); print("INSTRUMENTATION_STATUS: musa_diag_start_ms=1794492223000"); print("INSTRUMENTATION_STATUS: diagNonce=' + nonce + '"); print("INSTRUMENTATION_STATUS_CODE: 0"); print("INSTRUMENTATION_CODE: -1")'
            result = m.collect([sys.executable,'-c',script],3,out,owner_context=context)
            self.assertTrue(result['passed'])
            self.assertEqual({'uid':12345,'pid':456,'start_ms':1794492223000},context)
            saved = out.read_text()+out.with_suffix('.json').read_text()
            for secret in (nonce,'12345','1794492223000','musa_diag'):
                self.assertNotIn(secret,saved)
    def test_trace_command_requires_nonce_exact_context_and_window(self):
        context = dict(uid=12345,pid=456,start_ms=1794492223000)
        command = m.trace_command('ADB_NOT_RUN','SERIAL_NOT_RUN',context,'a'*32,1794492225000)
        self.assertIn('com.zarz.mornye.OwnNativeExitTraceInstrumentedTest#collectOnlyExactOwnNativeCrashProjection',command)
        for changed,nonce,ended in ((dict(context,invalid=True),'a'*32,1794492225000),(context,'SECRET',1794492225000),(context,'a'*32,1794492222000),(context,'a'*32,1794492423000)):
            with self.assertRaises(ValueError):m.trace_command('NO_ADB','NO_SERIAL',changed,nonce,ended)
    def test_trace_projection_filter_rejects_arbitrary_payload(self):
        self.assertEqual('TRACE_SIGNAL 11',m.sanitize('INSTRUMENTATION_STATUS: musa_own_trace_signal=11'))
        self.assertEqual('TRACE_FRAME libflutter.so@abcd',m.sanitize('INSTRUMENTATION_STATUS: musa_own_trace_frame=libflutter.so@abcd'))
        for bad in ('SECRET.so@abcd','/SECRET/libflutter.so@abcd','libflutter.so@fffffffff','libflutter.so@abcd SECRET'):
            self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: musa_own_trace_frame='+bad))
        self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: musa_own_trace_signal=99'))
    def test_trace_fixed_apk_ids_round_trip_and_reject_collisions(self):
        for n in range(1, 20):
            module = f"APK_MODULE_{n:02d}"
            self.assertEqual(f"TRACE_FRAME {module}@abcd", m.sanitize(f"INSTRUMENTATION_STATUS: musa_own_trace_frame={module}@abcd"))
        for bad in ("APK_MODULE_00", "APK_MODULE_20", "APK_MODULE_1", "APK_MODULE_019", "APK_MODULE_01SECRET", "SECRET"):
            self.assertIsNone(m.sanitize(f"INSTRUMENTATION_STATUS: musa_own_trace_frame={bad}@abcd"))
        self.assertIsNone(m.sanitize("INSTRUMENTATION_STATUS: musa_own_trace_frame=APK_MODULE_01@abcd SECRET"))
    def test_trace_counter_filter_accepts_only_bounded_fixed_numeric_fields(self):
        self.assertEqual('TRACE_COUNT total 256',m.sanitize('INSTRUMENTATION_STATUS: musa_own_trace_count_total=256'))
        self.assertEqual('TRACE_COUNT unknown_fields 1024',m.sanitize('INSTRUMENTATION_STATUS: musa_own_trace_count_unknown_fields=1024'))
        for payload in ('total=257','unknown_fields=1025','SECRET=1','total=-1','total=2 SECRET'):
            self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: musa_own_trace_count_'+payload))
    def test_trace_completeness_requires_unique_consistent_counts(self):
        counts = dict(total=2,named=1,missing_name=1,allowed=1,unallowed=0,pc_present=1,pc_missing=1,emitted=1,unknown_fields=0)
        def lines(values):return ['TRACE_SIGNAL 11','TRACE_FRAME libflutter.so@1234'] + ['TRACE_COUNT '+k+' '+str(v) for k,v in values.items()]
        valid = lines(counts)
        self.assertEqual({'signal_present':True,'counters_complete':True},m.trace_completeness(valid))
        for bad in (valid[:-1],valid+['TRACE_COUNT total 2'],valid+['TRACE_COUNT SECRET 1'],valid+['TRACE_FRAME libc.so@12'],lines(dict(counts,total=3)),lines(dict(counts,named=2)),lines(dict(counts,pc_present=2)),lines(dict(counts,allowed=0,unallowed=1)),lines(dict(counts,emitted=0)),lines(dict(counts,unknown_fields=1025))):
            self.assertFalse(m.trace_completeness(bad)['counters_complete'])
        self.assertEqual({'signal_present':True,'counters_complete':False},m.trace_completeness(['TRACE_SIGNAL 11']))
        self.assertFalse(m.trace_completeness(valid+['TRACE_SIGNAL 11'])['signal_present'])
        zero = dict(total=0,named=0,missing_name=0,allowed=0,unallowed=0,pc_present=0,pc_missing=0,emitted=0,unknown_fields=0)
        self.assertTrue(m.trace_completeness(['TRACE_SIGNAL 11']+['TRACE_COUNT '+k+' '+str(v) for k,v in zero.items()])['counters_complete'])
    def test_trace_category_and_fault_lines_use_closed_vocabulary(self):
        pre = 'INSTRUMENTATION_STATUS: musa_own_trace_'
        for cat in ('ANON_OR_JIT', 'APK_CONTAINER', 'UNKNOWN_MAP'):
            self.assertEqual('TRACE_OTHER_FRAME ' + cat + '@1abcd', m.sanitize(pre + 'other_frame=' + cat + '@1abcd'))
            self.assertEqual('TRACE_OTHER_FRAME ' + cat + '@0', m.sanitize(pre + 'other_frame=' + cat + '@0'))
        self.assertEqual('TRACE_OTHER_FRAME UNKNOWN_MAP@ffffffff', m.sanitize(pre + 'other_frame=UNKNOWN_MAP@ffffffff'))
        for bad in ('SECRET@abcd', 'libflutter.so@abcd', 'APK_MODULE_01@abcd', 'anon_or_jit@abcd', 'ANON_OR_JIT@', 'ANON_OR_JIT',
                    'ANON_OR_JIT@fffffffff', 'ANON_OR_JIT@xyz', 'ANON_OR_JIT@ABCD', 'ANON_OR_JIT@-1', 'ANON_OR_JIT@abcd SECRET',
                    'ANON_OR_JIT@abcd@ef', '/SECRET/ANON_OR_JIT@abcd', 'ANON_OR_JIT@0x1abc'):
            self.assertIsNone(m.sanitize(pre + 'other_frame=' + bad), bad)
        for fault in ('FAULT_NONE', 'FAULT_NULL_PAGE', 'FAULT_OTHER'):
            self.assertEqual('TRACE_FAULT ' + fault, m.sanitize(pre + 'fault=' + fault))
        for bad in ('FAULT_UNKNOWN', 'fault_none', 'FAULT_OTHER SECRET', '0xdeadbeef', 'FAULT_NULL_PAGE@10', '', 'SECRET'):
            self.assertIsNone(m.sanitize(pre + 'fault=' + bad), bad)
        for key, value in (('anon_or_jit', 256), ('apk_container', 0), ('unknown_map', 12)):
            self.assertEqual('TRACE_COUNT %s %d' % (key, value), m.sanitize(pre + 'count_%s=%d' % (key, value)))
        for key in ('anon_or_jit', 'apk_container', 'unknown_map'):
            for bad in ('257', '-1', '1 SECRET', 'x'):
                self.assertIsNone(m.sanitize(pre + 'count_%s=%s' % (key, bad)))
    def test_trace_completeness_with_category_fields_and_old_traces(self):
        old = dict(total=2,named=1,missing_name=1,allowed=1,unallowed=0,pc_present=1,pc_missing=1,emitted=1,unknown_fields=0)
        def tc(values, other=(), fault=None):
            return (['TRACE_SIGNAL 11', 'TRACE_FRAME libflutter.so@1234'] + ['TRACE_COUNT ' + k + ' ' + str(v) for k, v in values.items()]
                + list(other) + (['TRACE_FAULT ' + fault] if fault else []))
        # Old trace without any new field is still complete.
        self.assertTrue(m.trace_completeness(tc(old))['counters_complete'])
        # New trace: total-allowed = 1 = anon+apk+unknown; pc_present(1) - emitted(1) = 0 other frames.
        new = dict(old, anon_or_jit=1, apk_container=0, unknown_map=0)
        self.assertEqual({'signal_present': True, 'counters_complete': True}, m.trace_completeness(tc(new, fault='FAULT_NULL_PAGE')))
        # With a categorised frame that carried a pc: pc_present 2, emitted 1 -> exactly one other frame.
        withpc = dict(new, pc_present=2, pc_missing=0)
        self.assertTrue(m.trace_completeness(tc(withpc, other=['TRACE_OTHER_FRAME ANON_OR_JIT@2a'], fault='FAULT_OTHER'))['counters_complete'])
        self.assertTrue(m.trace_completeness(tc(withpc, other=['TRACE_OTHER_FRAME UNKNOWN_MAP@2a']))['counters_complete'])
        # Broken invariant: categories do not add up to total-allowed.
        for broken in (dict(new, anon_or_jit=0), dict(new, anon_or_jit=2), dict(new, anon_or_jit=0, apk_container=1, unknown_map=1)):
            self.assertFalse(m.trace_completeness(tc(broken))['counters_complete'])
        # Any new field without all three new counters is incomplete.
        for partial in (dict(old, anon_or_jit=1), dict(old, anon_or_jit=1, apk_container=0)):
            self.assertFalse(m.trace_completeness(tc(partial))['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(old, fault='FAULT_NONE'))['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(old, other=['TRACE_OTHER_FRAME ANON_OR_JIT@1']))['counters_complete'])
        # Other-frame count must match pc_present - emitted (missing or extra frame is incomplete).
        self.assertFalse(m.trace_completeness(tc(withpc))['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(withpc, other=['TRACE_OTHER_FRAME ANON_OR_JIT@2a'] * 2))['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(new, other=['TRACE_OTHER_FRAME ANON_OR_JIT@2a']))['counters_complete'])
        # Duplicate fault, duplicate new counter, malformed new lines are incomplete.
        self.assertFalse(m.trace_completeness(tc(new, fault='FAULT_NONE') + ['TRACE_FAULT FAULT_OTHER'])['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(new) + ['TRACE_COUNT anon_or_jit 1'])['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(new, other=['TRACE_OTHER_FRAME SECRET@1']))['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(new, other=['TRACE_OTHER_FRAME ANON_OR_JIT@1 SECRET']))['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(new) + ['TRACE_FAULT SECRET'])['counters_complete'])
        self.assertFalse(m.trace_completeness(tc(dict(new, anon_or_jit=257)))['counters_complete'])
    def test_ffprobe_stage_vocabulary_and_scenario_are_closed(self):
        self.assertEqual(('com.zarz.mornye.FfprobeFixtureInstrumentedTest#ffprobeMediaInformationOnSyntheticFinalFileSurvivesRepeatedAndOffMainThreadCalls', 1), m.SCENARIOS['ffprobe-fixture'])
        for stage in ('FFPROBE_FIXTURE_READY', 'FFPROBE_BEGIN', 'FFPROBE_END_OK', 'FFPROBE_END_ERROR', 'CASE_SUCCESS'):
            self.assertEqual('FFPROBE_STAGE ' + stage, m.sanitize('INSTRUMENTATION_STATUS: musa_ffprobe_stage=' + stage))
        self.assertEqual(frozenset(('FFPROBE_FIXTURE_READY', 'FFPROBE_BEGIN', 'FFPROBE_END_OK', 'FFPROBE_END_ERROR', 'CASE_SUCCESS')), m.FFPROBE_STAGES)
        for bad in ('FFPROBE_END', 'ffprobe_begin', 'FFPROBE_BEGIN SECRET', '/private/path', 'FFPROBE_END_OK SECRET', 'SECRET', ''):
            self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: musa_ffprobe_stage=' + bad), bad)
    def test_ffprobe_sequence_must_be_complete_and_open_begin_is_incomplete(self):
        def stage(x): return 'FFPROBE_STAGE ' + x
        pair = [stage('FFPROBE_BEGIN'), stage('FFPROBE_END_OK')]
        ready, ok = stage('FFPROBE_FIXTURE_READY'), stage('CASE_SUCCESS')
        full = [ready] + pair * 4 + [ok]
        self.assertTrue(m.ffprobe_complete(full))
        self.assertFalse(m.ffprobe_open_begin(full))
        # Death inside ffprobe: BEGIN without END -> incomplete and reported open, never success.
        died = [ready] + pair * 2 + [stage('FFPROBE_BEGIN')]
        self.assertFalse(m.ffprobe_complete(died))
        self.assertTrue(m.ffprobe_open_begin(died))
        # Death inside the 4th (worker-thread) call, CASE_SUCCESS missing.
        died_last = [ready] + pair * 3 + [stage('FFPROBE_BEGIN')]
        self.assertTrue(m.ffprobe_open_begin(died_last))
        self.assertFalse(m.ffprobe_complete(died_last))
        for bad in ([], [ready], [ready] + pair * 3 + [ok], [ready] + pair * 5 + [ok], full[:-1], full[1:], [ok] + full[:-1],
                    [ready] + pair * 3 + [stage('FFPROBE_BEGIN'), stage('FFPROBE_END_ERROR'), ok],
                    [ready] + pair * 4 + [ok, ok], full + [stage('FFPROBE_BEGIN')],
                    [ready, stage('FFPROBE_END_OK'), stage('FFPROBE_BEGIN')] + pair * 3 + [ok],
                    full + [stage('FFPROBE_END_ERROR')]):
            self.assertFalse(m.ffprobe_complete(bad), bad)
        self.assertFalse(m.ffprobe_open_begin([]))
        self.assertFalse(m.ffprobe_open_begin([ready]))
        self.assertFalse(m.ffprobe_open_begin([ready, stage('FFPROBE_BEGIN'), stage('FFPROBE_END_ERROR')]))
        # A crash keeps the adb verdict failing even if all earlier markers looked fine.
        self.assertFalse(m.verdict(['STATUS_CODE 1', 'PROCESS_CRASHED', 'CODE 0'], 0, False, True, 1))
    def test_epoch_requires_milliseconds(self):
        self.assertTrue(m.valid_epoch('1794492223.000'))
        for value in ('1794492223', '11-12 11:00:00', '11-12 11:00:00.000', '1794492223.0', '1794492223.000 SECRET'):
            self.assertFalse(m.valid_epoch(value))
    def test_stderr_classification_never_retains_payload(self):
        self.assertEqual('TIME_ARGUMENT', m.classify_stderr('invalid time SECRET_TOKEN'))
        self.assertEqual('UNCLASSIFIED', m.classify_stderr('SECRET_TOKEN'))
        self.assertEqual('NONE', m.classify_stderr(''))
        for secret in ('SECRET_TOKEN', 'invalid time SECRET_TOKEN', 'permission SECRET_TOKEN'):
            self.assertNotIn('SECRET', m.classify_stderr(secret))
    def test_secret_and_unknown_stage_are_discarded(self):
        self.assertIsNone(m.sanitize('INSTRUMENTATION_RESULT: stack=SECRET_TOKEN'))
        self.assertIsNone(m.sanitize('INSTRUMENTATION_STATUS: musa_harness_stage=SECRET_TOKEN'))
        self.assertEqual('STAGE TEST_ENTERED', m.sanitize('INSTRUMENTATION_STATUS: musa_harness_stage=TEST_ENTERED'))
    def test_failure_with_successful_adb_exit_is_not_pass(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'result.txt'
            result = m.collect([sys.executable, '-c', 'print("INSTRUMENTATION_STATUS_CODE: -2"); print("INSTRUMENTATION_CODE: -1")'], 3, out)
            self.assertEqual(0, result['exit_code'])
            self.assertFalse(result['passed'])
    def test_verdict_requires_exact_success_and_completion(self):
        self.assertTrue(m.verdict(['STATUS_CODE 1', 'STATUS_CODE 0', 'CODE -1'], 0, False, True))
        for values in ([], ['STATUS_CODE 0'], ['CODE -1'], ['STATUS_CODE -1', 'CODE -1'], ['STATUS_CODE 0', 'CODE 0']):
            self.assertFalse(m.verdict(values, 0, False, True))
    def test_oversized_line_is_dropped(self):
        import io
        self.assertEqual(['STATUS_CODE 0'], list(m.bounded_lines(io.StringIO('SECRET' * 100000 + '\nSTATUS_CODE 0\n'))))
    def test_queue_full_dropped_failure_cannot_pass(self):
        from unittest.mock import patch
        real_queue = m.queue.Queue
        class SaturatedQueue(real_queue):
            lost = False
            def put_nowait(self, value):
                if not self.lost:
                    self.lost = True
                    raise m.queue.Full
                return super().put_nowait(value)
        with tempfile.TemporaryDirectory() as d, patch.object(m.queue, 'Queue', SaturatedQueue):
            result = m.collect([sys.executable, '-c', 'print("INSTRUMENTATION_STATUS_CODE: -2"); print("INSTRUMENTATION_STATUS_CODE: 0"); print("INSTRUMENTATION_CODE: -1")'], 3, Path(d) / 'result.txt')
            self.assertTrue(result['loss'])
            self.assertFalse(result['passed'])
    def test_output_capacity_loss_cannot_pass(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'result.txt'
            command = [sys.executable, '-c', 'print("INSTRUMENTATION_STATUS_CODE: 0"); print("INSTRUMENTATION_CODE: -1")']
            result = m.collect(command, 3, out, byte_limit=1)
            self.assertTrue(result['loss'])
            self.assertFalse(result['passed'])
    def test_truncated_line_cannot_pass(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'result.txt'
            result = m.collect([sys.executable, '-c', 'print("X"*10000); print("INSTRUMENTATION_STATUS_CODE: 0"); print("INSTRUMENTATION_CODE: -1")'], 3, out)
            self.assertTrue(result['line_truncated'])
            self.assertTrue(result['loss'])
            self.assertFalse(result['passed'])
    def test_process_crash_is_sanitized_and_reader_joined(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'result.txt'
            result = m.collect([sys.executable, '-c', 'print("SECRET_TOKEN"); print("INSTRUMENTATION_RESULT: shortMsg=Process crashed."); raise SystemExit(7)'], 3, out)
            self.assertEqual(7, result['exit_code'])
            self.assertTrue(result['reader_joined'])
            self.assertFalse(result['timed_out'])
            self.assertEqual('PROCESS_CRASHED\n', out.read_text())
    def test_timeout_stops_own_child_and_reader(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'result.txt'
            result = m.collect([sys.executable, '-c', 'import time; print("SECRET_TOKEN", flush=True); time.sleep(30)'], .15, out)
            self.assertTrue(result['timed_out'])
            self.assertTrue(result['reader_joined'])
            self.assertIsNotNone(result['exit_code'])
            self.assertNotIn('SECRET', out.read_text())

if __name__ == '__main__':
    unittest.main()
