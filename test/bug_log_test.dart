import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _BlockingStore extends SharedPreferencesStorePlatform {
  final started = Completer<void>();
  final release = Completer<void>();
  final values = <String, Object>{};
  bool failFirst = false;
  bool throwFirst = false;
  bool failRemove = false;
  bool failWrite = false;
  bool failReload = false;
  Completer<void>? removeStarted;
  Completer<void>? releaseRemove;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
      if (throwFirst) throw StateError('write failed');
      if (failFirst) return false;
    }
    if (failWrite) return false;
    values[key] = value;
    return true;
  }
  @override
  Future<Map<String, Object>> getAll() async {
    if (failReload) throw StateError('reload failed');
    return Map.of(values);
  }
  @override
  Future<bool> remove(String key) async {
    removeStarted?.complete();
    await releaseRemove?.future;
    if (failRemove) return false;
    values.remove(key);
    return true;
  }
  @override
  Future<bool> clear() async { values.clear(); return true; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('temporary preparation reasons persist only allowlisted values', () async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    await log.recordPreparationFailure(reason: 'AAC conversion failed');
    await log.recordPreparationFailure(reason: 'https://private.invalid/?token=secret');
    final entries = await BugLog().entries();
    expect(entries[0]['frames'], 'stage_preparation, reason_aac_conversion_failed');
    expect(entries[1]['frames'], 'stage_preparation, reason_unknown');
    expect(entries.toString(), isNot(contains('secret')));
    expect(entries.toString(), isNot(contains('private.invalid')));
  });
  test('permanent diagnostics reject arbitrary fields and control flow', () async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    await log.recordTerminalDownloadFailure(
      stage: 'https://diagnostic-canary.invalid/song',
      errorType: 'diagnostic_canary',
      cause: {'decryption_key': 'diagnostic-canary'},
    );
    for (final type in ['cancelled', 'verification_required']) {
      await log.recordTerminalDownloadFailure(
        stage: 'downloading',
        errorType: type,
        cause: 'encrypted_validation_guard',
      );
    }
    final entries = await log.entries();
    expect(entries, hasLength(1));
    expect(
      entries.single['frames'],
      'stage_unknown, error_type_unknown, cause_unknown',
    );
    expect(
      (await SharedPreferences.getInstance()).getString(BugLog.key),
      isNot(contains('diagnostic-canary')),
    );
  });

  test('terminal diagnostics record only allowlisted reported provider', () async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    const inputs = <Object?>[
      ' Tidal-Web ',
      'deezer',
      'https://diagnostic-canary.invalid/?token=secret',
      'Bearer secret-token',
      {'session': 'secret'},
      '',
    ];
    for (final provider in inputs) {
      await log.recordTerminalDownloadFailure(
        stage: 'backend_download',
        errorType: 'network',
        provider: provider,
      );
    }
    await log.recordTerminalDownloadFailure(
      stage: 'backend_download',
      errorType: 'network',
    );
    final entries = await log.entries();
    const base = 'stage_backend_download, error_type_network, cause_unknown';
    expect(entries.map((entry) => entry['frames']), [
      '$base, provider_tidal',
      '$base, provider_deezer',
      '$base, provider_unknown',
      '$base, provider_unknown',
      '$base, provider_unknown',
      '$base, provider_unknown',
      base,
    ]);
    final raw = (await SharedPreferences.getInstance()).getString(BugLog.key)!;
    expect(raw, isNot(contains('secret')));
    expect(raw, isNot(contains('diagnostic-canary')));
  });

  test('stored terminal provider is re-sanitized when entries are read', () async {
    SharedPreferences.setMockInitialValues({
      BugLog.key: jsonEncode([
        {
          'time': '2026-01-01T00:00:00Z',
          'category': 'download',
          'type': 'TerminalDownloadFailure',
          'frames': 'stage_backend_download, error_type_network, '
              'cause_unknown, provider_evil-host',
        },
        {
          'time': '2026-01-01T00:00:00Z',
          'category': 'download',
          'type': 'TerminalDownloadFailure',
          'frames': 'stage_backend_download, error_type_network, '
              'cause_unknown, provider_qobuz-web',
        },
      ]),
    });
    final entries = await BugLog().entries();
    expect(entries.map((entry) => entry['frames']), [
      'stage_backend_download, error_type_network, cause_unknown, provider_unknown',
      'stage_backend_download, error_type_network, cause_unknown, provider_qobuz',
    ]);
  });

  group('provider_attempts', () {
    const base = 'stage_backend_download, error_type_network, cause_unknown';

    Future<String> frames(Object? attempts) async {
      SharedPreferences.setMockInitialValues({});
      final log = BugLog();
      await log.recordTerminalDownloadFailure(
        stage: 'backend_download',
        errorType: 'network',
        provider: 'tidal',
        providerAttempts: attempts,
      );
      return (await log.entries()).single['frames']!;
    }

    test('keeps order and maps aliases, empty error type to none', () async {
      expect(
        await frames([
          {'provider': 'qobuz-web', 'stage': 'availability', 'error_type': ''},
          {'provider': 'tidal', 'stage': 'preflight_error', 'error_type': 'timeout'},
          {'provider': 'deezer', 'stage': 'download', 'error_type': 'rate_limited'},
          {'provider': 'qobuz-web', 'stage': 'download', 'error_type': null},
        ]),
        '$base, provider_tidal, attempts_'
        'qobuz:availability:none;tidal:preflight_error:timeout;'
        'deezer:download:rate_limit;qobuz:download:none',
      );
    });

    test('malicious fields become unknown and never persist', () async {
      final result = await frames([
        {
          'provider': 'https://diagnostic-canary.invalid/?token=secret',
          'stage': 'Bearer secret-stage',
          'error_type': 'title: Secret Song',
        },
        {'provider': {'id': 'secret'}, 'stage': 7, 'error_type': 42},
        'secret-string-entry',
        null,
        {'provider': 'spotify:download:network;tidal', 'stage': 'download;x'},
      ]);
      expect(
        result,
        '$base, provider_tidal, attempts_'
        'unknown:unknown:unknown;unknown:unknown:unknown;'
        'unknown:unknown:none',
      );
      final raw = (await SharedPreferences.getInstance()).getString(BugLog.key)!;
      for (final leak in ['secret', 'diagnostic-canary', 'Song', 'http']) {
        expect(raw, isNot(contains(leak)));
      }
    });

    test('details keep only closed-list tokens', () {
      final result = BugLog.sanitizeProviderAttemptDetails([
        {
          'provider': 'tidal',
          'stage': 'availability_response_unavailable',
          'error_type': '',
          'reason_class': 'no_match',
        },
        {
          'provider': 'amazon',
          'stage': 'download',
          'error_type': 'rate_limit',
          'id_source': 'availability',
          'id_len': 10,
          'retry_after_s': 30,
        },
        {
          'provider': 'qobuz',
          'stage': 'download',
          'error_type': 'network',
          'reason_class': 'https://evil.example/secret',
          'id_source': 'Song Title',
          'id_len': 99999,
          'retry_after_s': '30',
        },
        'not-a-map',
      ]);
      expect(result, [
        'tidal:availability_response_unavailable:none/reason_class=no_match',
        'amazon:download:rate_limit/id_source=availability/id_len=10/retry_after_s=30',
        'qobuz:download:network',
      ]);
      expect(BugLog.sanitizeProviderAttemptDetails(null), isEmpty);
      expect(BugLog.sanitizeProviderAttemptDetails('x'), isEmpty);
    });

    test('reads at most 64 entries', () async {
      final many = List.generate(
        200,
        (i) => {'provider': i < 64 ? 'amazon' : 'tidal', 'stage': 'download', 'error_type': 'network'},
      );
      final result = await frames(many);
      final payload = result.split('attempts_').last.split(';');
      expect(payload, hasLength(64));
      expect(payload.toSet(), {'amazon:download:network'});
      expect(BugLog.sanitizeProviderAttempts(many), hasLength(64));
    });

    test('absent, empty or non-list value keeps legacy format', () async {
      for (final value in <Object?>[null, <Object?>[], 'secret', {'provider': 'tidal'}, 5]) {
        expect(await frames(value), '$base, provider_tidal');
      }
    });

    test('stored attempts are re-sanitized and legacy rows still load', () async {
      SharedPreferences.setMockInitialValues({
        BugLog.key: jsonEncode([
          {
            'time': '2026-01-01T00:00:00Z',
            'category': 'download',
            'type': 'TerminalDownloadFailure',
            'frames': '$base, provider_qobuz, attempts_evil-host:download:none;'
                'tidal-web:bogus:secret_type;deezer:download:network',
          },
          {
            'time': '2026-01-01T00:00:00Z',
            'category': 'download',
            'type': 'TerminalDownloadFailure',
            'frames': '$base, provider_qobuz',
          },
          {
            'time': '2026-01-01T00:00:00Z',
            'category': 'download',
            'type': 'TerminalDownloadFailure',
            'frames': '$base, provider_qobuz, attempts_https://x/?token=s',
          },
        ]),
      });
      final entries = await BugLog().entries();
      expect(entries[0]['frames'],
          '$base, provider_qobuz, attempts_unknown:download:none;'
          'tidal:unknown:unknown;deezer:download:network');
      expect(entries[1]['frames'], '$base, provider_qobuz');
      expect(entries[2]['frames'],
          'stage_unknown, error_type_unknown, cause_unknown');
    });
  });

  test('terminal diagnostics preserve closed provider failure codes', () async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    const types = [
      'subscription_required',
      'expired_stream',
      'http_error',
      'integrity_failed',
      'transient_network',
      'timeout',
      'auth',
      'authentication_error',
      'provider_auth_failed',
      'request_auth_invalid',
      'provider_reauth_required',
      'provider_unavailable',
      'storage_error',
      'file_error',
      'isp_blocked',
      'not_implemented',
      'invalid_url',
      'provider_error',
      'extension_error',
      'runtime_error',
      'script_error',
      'download_error',
      'init_error',
      'api_error',
    ];
    for (final type in types) {
      await log.recordTerminalDownloadFailure(
        stage: 'downloading',
        errorType: ' ${type.toUpperCase()} ',
        cause: 'https://diagnostic-canary.invalid/?token=secret',
      );
    }
    final entries = await log.entries();
    expect(entries.map((entry) => entry['frames']), [
      for (final type in types)
        'stage_backend_download, error_type_$type, cause_unknown',
    ]);
    expect(jsonEncode(entries), isNot(contains('secret')));
  });

  test('corrupt history remains intact when recording', () async {
    SharedPreferences.setMockInitialValues({BugLog.key: '{invalid secret'});
    final log = BugLog();
    await log.record('player');
    expect(log.persistenceFailed, isTrue);
    await expectLater(log.entries(), throwsFormatException);
    expect((await SharedPreferences.getInstance()).getString(BugLog.key), '{invalid secret');
  });
  test('write failure is visible and tags are allowlisted', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _BlockingStore()..release.complete()..failFirst = true;
    SharedPreferencesStorePlatform.instance = platform;
    final log = BugLog();
    await log.record('player', tag: 'token=secret https://song');
    expect(log.persistenceFailed, isTrue);
    await log.record('download', tag: 'DownloadQueue');
    expect(log.persistenceFailed, isFalse);
    final entries = await log.entries();
    expect(entries.first['tag'], 'other');
    expect(entries.last['tag'], 'download_queue');
    expect(jsonEncode(entries), isNot(contains('secret')));
  });
  test('failed write and reload block reads and writes until reload succeeds', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _BlockingStore()..release.complete();
    SharedPreferencesStorePlatform.instance = platform;
    final log = BugLog();
    await log.record('search');
    final original = Map<String, Object>.of(platform.values);
    expect(original['flutter.${BugLog.key}'], isNotNull);
    platform.failReload = true;
    platform.failRemove = true;
    await expectLater(log.clear(), throwsStateError);
    await expectLater(log.entries(), throwsStateError);
    await log.record('player');
    expect(platform.values, original);
    platform.failReload = false;
    await log.record('download');
    expect((await log.entries()).map((e) => e['category']), ['search', 'player', 'download']);
  });
  test('failed event write and reload do not duplicate or overwrite history', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _BlockingStore()..release.complete();
    SharedPreferencesStorePlatform.instance = platform;
    final log = BugLog();
    await log.record('search');
    final original = Map<String, Object>.of(platform.values);
    expect(original['flutter.${BugLog.key}'], isNotNull);
    platform.failWrite = true;
    platform.failReload = true;
    await log.record('player');
    await log.record('download');
    expect(platform.values, original);
    await expectLater(log.entries(), throwsStateError);
    platform.failWrite = false;
    platform.failReload = false;
    await log.record('async');
    expect((await log.entries()).map((e) => e['category']), ['search', 'player', 'download', 'async']);
  });
  test('failed note and reload never revive the note on retry', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _BlockingStore()..release.complete();
    SharedPreferencesStorePlatform.instance = platform;
    final log = BugLog();
    await log.record('search');
    final original = Map<String, Object>.of(platform.values);
    expect(original['flutter.${BugLog.key}'], isNotNull);
    platform.failWrite = true;
    platform.failReload = true;
    await expectLater(log.addNote('failed note'), throwsStateError);
    await log.record('player');
    expect(platform.values, original);
    platform.failWrite = false;
    platform.failReload = false;
    await log.record('download');
    final entries = await log.entries();
    expect(entries.map((e) => e['category']), ['search', 'player', 'download']);
    expect(jsonEncode(entries), isNot(contains('failed note')));
  });
  test('legacy entries without tags remain readable', () async {
    SharedPreferences.setMockInitialValues({BugLog.key: '[{"time":"2026-01-01T00:00:00Z","category":"player","type":"Error","frames":""}]'});
    expect((await BugLog().entries()).single['category'], 'player');
  });
  for (final throws in [false, true]) {
    test('failed note write (${throws ? 'throws' : 'false'}) is not revived', () async {
      SharedPreferences.setMockInitialValues({});
      final platform = _BlockingStore()
        ..release.complete()
        ..failFirst = !throws
        ..throwFirst = throws;
      SharedPreferencesStorePlatform.instance = platform;
      final log = BugLog();
      await expectLater(log.addNote('failed note'), throwsStateError);
      await log.record('player');
      final entries = await log.entries();
      expect(entries, hasLength(1));
      expect(entries.single['category'], 'player');
      expect(jsonEncode(entries), isNot(contains('failed note')));
    });
  }
  test('failed removal reloads cache before a later record', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _BlockingStore()..release.complete();
    SharedPreferencesStorePlatform.instance = platform;
    final log = BugLog();
    await log.record('search');
    platform.failRemove = true;
    platform.removeStarted = Completer<void>();
    platform.releaseRemove = Completer<void>();
    final clear = log.clear();
    final failure = expectLater(clear, throwsStateError);
    await platform.removeStarted!.future;
    final next = log.record('player');
    platform.releaseRemove!.complete();
    await failure;
    await next;
    expect((await log.entries()).map((e) => e['category']), ['search', 'player']);
  });
  test('retains drop increments while a flush is writing', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _BlockingStore();
    SharedPreferencesStorePlatform.instance = platform;
    final log = BugLog();
    final initial = [for (var i = 0; i < 150; i++) log.record('search')];
    await platform.started.future;
    final additional = [for (var i = 0; i < 150; i++) log.record('player')];
    platform.release.complete();
    await Future.wait([...initial, ...additional]);
    final entries = await log.entries();
    expect(entries.where((e) => e['type'] == 'DroppedEvents').last['count'], '51');
  });
  test('does not count in-flight events as dropped during a burst', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _BlockingStore();
    SharedPreferencesStorePlatform.instance = platform;
    final log = BugLog();
    final initial = [for (var i = 0; i < 100; i++) log.record('search')];
    await platform.started.future;
    final additional = [for (var i = 0; i < 200; i++) log.record('player')];
    platform.release.complete();
    await Future.wait([...initial, ...additional]);
    final entries = await log.entries();
    expect(entries.where((e) => e['type'] == 'DroppedEvents').single['count'], '101');
    expect(entries.where((e) => e['category'] == 'player'), hasLength(99));
  });
  test('failed in-flight write restores bounded queue and retries', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = _BlockingStore()..failFirst = true;
    SharedPreferencesStorePlatform.instance = platform;
    final log = BugLog();
    final initial = [for (var i = 0; i < 100; i++) log.record('search')];
    await platform.started.future;
    final additional = [for (var i = 0; i < 200; i++) log.record('player')];
    platform.release.complete();
    await Future.wait([...initial, ...additional]);
    await log.record('download');
    final entries = await log.entries();
    expect(entries.where((e) => e['type'] == 'DroppedEvents').single['count'], '202');
    expect(entries.where((e) => e['category'] == 'download'), hasLength(1));
  });
  test('clear is a barrier between concurrent records', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<void>();
    var first = true;
    final log = BugLog(preferences: () async {
      if (first) { first = false; await gate.future; }
      return prefs;
    });
    final before = log.record('search');
    final clear = log.clear();
    final after = log.record('player');
    gate.complete();
    await Future.wait([before, clear, after]);
    final entries = await log.entries();
    expect(entries, hasLength(1));
    expect(entries.single['category'], 'player');
  });

  test('failed clear preserves queued events across generations', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    final log = BugLog(preferences: () async {
      calls++;
      if (calls <= 2) throw StateError('unavailable');
      return prefs;
    });
    final before = log.record('search');
    final clear = log.clear();
    final clearFailure = expectLater(clear, throwsStateError);
    final after = log.record('player');
    await Future.wait([before, clearFailure, after]);
    expect((await log.entries()).map((e) => e['category']), ['search', 'player']);
  });
  test('clear discards failed queued events before subsequent records', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var failing = true;
    final log = BugLog(preferences: () async {
      if (failing) throw StateError('unavailable');
      return prefs;
    });
    await Future.wait([for (var i = 0; i < 150; i++) log.record('search')]);
    failing = false;
    await log.clear();
    await log.record('player');
    final entries = await log.entries();
    expect(entries, hasLength(1));
    expect(entries.single['category'], 'player');
    expect(entries.single['type'], 'Error');
  });
  test('manual notes persist with bounded best-effort redaction and clear', () async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    await log.addNote('Playback failed https://example.com/?token=abc password=secret Bearer xyz');
    final recreated = BugLog();
    final note = (await recreated.entries()).single['note']!;
    expect(note, contains('Playback failed'));
    expect(note, isNot(contains('example.com')));
    expect(note, isNot(contains('secret')));
    expect(note, isNot(contains('xyz')));
    await log.addNote('x' * 600);
    expect((await log.entries()).last['note']!.length, BugLog.maxNoteLength);
    await log.addNote('${'x' * 499}😀z');
    expect((await log.entries()).last['note'], '${'x' * 499}😀');
    await log.clear();
    expect(await recreated.entries(), isEmpty);
  });
  test(
    'persists bounded records without exception contents and clears',
    () async {
      SharedPreferences.setMockInitialValues({});
      final log = BugLog();
      for (var i = 0; i < 105; i++) {
        await log.record(
          'download',
          error: Exception(
            'password=secret https://host/?token=abc C:\\Users\\name song',
          ),
        );
      }
      final recreated = BugLog();
      final entries = await recreated.entries();
      expect(entries, hasLength(100));
      final persisted = (await SharedPreferences.getInstance()).getString(
        BugLog.key,
      )!;
      expect(persisted, isNot(contains('secret')));
      expect(persisted, isNot(contains('song')));
      expect(persisted, isNot(contains('https')));
      expect(
        (jsonDecode(persisted) as List<Object?>).last,
        containsPair('category', 'download'),
      );
      await recreated.clear();
      expect(await log.entries(), isEmpty);
    },
  );
  test('categorizes errors without storing arbitrary tags', () {
    expect(BugLog.categoryForTag('DownloadQueue'), 'download');
    expect(BugLog.categoryForTag('SearchProvider'), 'search');
    expect(BugLog.categoryForTag('MusicPlayer'), 'player');
    expect(BugLog.categoryForTag('secret'), 'application');
  });
  test('extracts only application function names without locations', () {
    final stack = StackTrace.fromString(
      '#0      Player.play (package:mornye/player.dart:10:2)\n#1      secret (file:///C:/Users/name/file.dart:1:1)',
    );
    expect(BugLog.safeFrames(stack), 'Player.play');
  });
  test('listener errors do not recursively generate log entries', () async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    final previous = FlutterError.onError;
    var notifications = 0;
    FlutterError.onError = (details) {
      log.record('flutter', error: details.exception);
    };
    log.addListener(() {
      notifications++;
      throw StateError('listener');
    });
    try {
      await log.record('player');
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      expect(await log.entries(), hasLength(1));
    } finally {
      FlutterError.onError = previous;
    }
  });
  test('bounds burst and reports omitted events', () async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    await Future.wait([for (var i = 0; i < 150; i++) log.record('search')]);
    final entries = await log.entries();
    expect(entries, hasLength(100));
    expect(entries.last['type'], 'DroppedEvents');
    expect(entries.last['count'], '51');
  });
  test(
    'native errors and Main errors retain only safe structured data',
    () async {
      SharedPreferences.setMockInitialValues({});
      await BugLog.instance.clear();
      LogBuffer().add(
        LogEntry(
          timestamp: DateTime.now(),
          level: 'ERROR',
          tag: 'NativeDownload',
          message: 'token=secret',
          isFromNative: true,
        ),
      );
      AppLogger('Main').e(
        'secret message',
        StateError('password=secret'),
        StackTrace.fromString(
          '#0      Startup.run (package:mornye/main.dart:1:1)',
        ),
      );
      final entries = await BugLog.instance.entries();
      expect(entries, hasLength(2));
      expect(entries.first['category'], 'download');
      expect(entries.last['type'], 'StateError');
      expect(entries.last['frames'], 'Startup.run');
      expect(jsonEncode(entries), isNot(contains('secret')));
    },
  );
  test('clear reports storage failures', () async {
    final log = BugLog(
      preferences: () async => throw StateError('unavailable'),
    );
    await expectLater(log.clear(), throwsStateError);
  });
}
