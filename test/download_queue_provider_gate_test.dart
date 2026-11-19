import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.directory);
  final String directory;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: directory,
    saveDownloadHistory: false,
    autoFallback: false,
    concurrentDownloads: 3,
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      Extension.fromJson({
        'id': 'example-provider',
        'name': 'Example Provider',
        'enabled': true,
        'has_download_provider': true,
        'skip_metadata_enrichment': true,
      }),
    ],
  );

  @override
  Future<void> ensureInitialized() async {}
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this.ids);
  final List<String> ids;

  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      isPaused: true,
      items: [
        for (final id in ids)
          DownloadItem(
            id: id,
            track: Track(
              id: 'example:$id',
              name: id,
              artistName: 'Artist',
              albumName: 'Album',
              source: 'example-provider',
              duration: 1,
            ),
            service: 'example-provider',
            createdAt: DateTime.utc(2026),
          ),
      ],
    );
  }
}

class _MemoryStore implements ProviderCooldownStore {
  final Map<String, int> values = {};

  @override
  Future<Map<String, int>> readAll() async => Map.of(values);

  @override
  void write(String key, int value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

Map<String, dynamic> _failure() => {
  'success': false,
  'error_type': 'not_found',
  'error': 'x',
};

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const backend = MethodChannel('com.zarz.mornye/backend');
  const sqlite = MethodChannel('com.tekartik.sqflite');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  const connectivity = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  const progress = MethodChannel('com.zarz.mornye/download_progress_stream');
  final previousFactory = databaseFactoryOrNull;
  setUpAll(() {
    databaseFactory = databaseFactorySqflitePlugin;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });
  tearDownAll(() => databaseFactory = previousFactory);
  setUp(() {
    ProviderRequestGate.instance = ProviderRequestGate();
    ProviderCooldown.instance = ProviderCooldown(
      clock: DateTime.now,
      store: _MemoryStore(),
    );
  });
  tearDown(() {
    for (final channel in [
      backend,
      sqlite,
      paths,
      notifications,
      connectivity,
      progress,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    ProviderRequestGate.instance = ProviderRequestGate();
  });

  Future<
    ({
      ProviderContainer container,
      DownloadQueueNotifier queue,
      List<int> calls,
    })
  >
  start(
    Directory directory,
    List<String> ids,
    Future<Map<String, dynamic>> Function(int call) respond,
  ) async {
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(connectivity, (_) async => null);
    messenger.setMockMethodCallHandler(progress, (_) async => null);
    messenger.setMockMethodCallHandler(
      notifications,
      (call) async => call.method == 'initialize' ? true : null,
    );
    messenger.setMockMethodCallHandler(sqlite, (call) async {
      if (call.method == 'openDatabase') return {'id': 1};
      if (call.method != 'query') return null;
      final sql = (call.arguments as Map)['sql'] as String;
      return sql.toLowerCase().contains('pragma user_version')
          ? {
              'columns': ['user_version'],
              'rows': [
                [4],
              ],
            }
          : {'columns': <String>[], 'rows': <List<Object?>>[]};
    });
    final calls = <int>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'getProviderMetadata') {
        return {'album_artist': 'Artist'};
      }
      if (call.method != 'downloadByStrategy') return null;
      calls.add(calls.length + 1);
      return respond(calls.length);
    });
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(directory.path)),
        extensionProvider.overrideWith(_Extensions.new),
        downloadQueueProvider.overrideWith(() => _Queue(ids)),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.flushQueuePersistence();
    return (container: container, queue: queue, calls: calls);
  }

  Future<Directory> tempDirectory() async {
    final directory = await Directory.systemTemp.createTemp('gate-');
    addTearDown(() => directory.delete(recursive: true));
    return directory;
  }

  test('la cola espera el turno de la compuerta antes de llamar', () async {
    final gate = ProviderRequestGate.instance;
    final held = gate.request(ProviderRequestPriority.foreground);
    await held.granted;
    final run = await start(await tempDirectory(), [
      'song',
    ], (_) async => _failure());
    run.queue.resumeQueue();
    await _until(() => gate.waiting == 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(run.calls, isEmpty);
    held.release();
    await _until(() => run.calls.length == 1);
    await run.queue.flushQueuePersistence();
  });

  test('la cola pide turno con prioridad queue y gana a la precarga', () async {
    final gate = ProviderRequestGate.instance;
    final held = gate.request(ProviderRequestPriority.foreground);
    await held.granted;
    final prefetch = gate.request(ProviderRequestPriority.prefetch);
    bool? prefetchHoldingDuringCall;
    final run = await start(await tempDirectory(), ['song'], (_) async {
      prefetchHoldingDuringCall = prefetch.isHolding;
      return _failure();
    });
    run.queue.resumeQueue();
    await _until(() => gate.waiting == 2);
    held.release();
    await _until(() => run.calls.length == 1);
    expect(prefetchHoldingDuringCall, isFalse);
    await _until(() => prefetch.isHolding);
    await run.queue.flushQueuePersistence();
    prefetch.release();
  });

  test('no lanza dos descargas a la vez', () async {
    final gate = ProviderRequestGate.instance;
    final first = Completer<Map<String, dynamic>>();
    final run = await start(await tempDirectory(), ['one', 'two'], (call) {
      if (call == 1) return first.future;
      return Future.value({'success': true});
    });
    run.queue.resumeQueue();
    await _until(() => run.calls.length == 1);
    expect(gate.busy, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(run.calls, hasLength(1));
    first.complete(_failure());
    await run.queue.flushQueuePersistence();
    run.queue.pauseQueue();
  });

  test('libera el turno al fallar la descarga', () async {
    final gate = ProviderRequestGate.instance;
    final run = await start(await tempDirectory(), [
      'song',
    ], (_) async => _failure());
    run.queue.resumeQueue();
    await _until(() => run.calls.length == 1);
    await _until(() => !gate.busy);
    expect(gate.waiting, 0);
    await run.queue.flushQueuePersistence();
  });

  test('libera el turno al terminar la descarga', () async {
    final gate = ProviderRequestGate.instance;
    final run = await start(await tempDirectory(), [
      'song',
    ], (_) async => {'success': true});
    run.queue.resumeQueue();
    await _until(() => run.calls.length == 1);
    await _until(() => !gate.busy);
    expect(gate.waiting, 0);
    await run.queue.flushQueuePersistence();
  });
}
