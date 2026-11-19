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

bool _autoFallback = false;
bool _fromBatch = false;
bool _android = false;
final methods = <String>[];
int _itemCount = 1;
List<DownloadStatus>? _statuses;
final requests = <String>[];

class _Settings extends SettingsNotifier {
  _Settings(this.directory);
  final String directory;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: directory,
    saveDownloadHistory: false,
    autoFallback: _autoFallback,
    concurrentDownloads: 1,
    nativeDownloadWorkerEnabled: _android,
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
  _Queue() : super(isAndroidForTesting: _android);

  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      isPaused: true,
      items: [
        for (var i = 0; i < _itemCount; i++)
          DownloadItem(
            id: 'song$i',
            track: const Track(
              id: 'example:track',
              name: 'Song',
              artistName: 'Artist',
              albumName: 'Album',
              source: 'example-provider',
              duration: 1,
            ),
            service: 'example-provider',
            createdAt: DateTime.utc(2026, 1, 1, 0, 0, i),
            fromBatch: _fromBatch,
            status: _statuses?[i] ?? DownloadStatus.queued,
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
  });

  Future<
    ({
      ProviderContainer container,
      DownloadQueueNotifier queue,
      List<int> calls,
      List<String> requests,
    })
  >
  start(
    Directory directory,
    Map<String, dynamic> Function(int call) respond,
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
    requests.clear();
    methods.clear();
    messenger.setMockMethodCallHandler(backend, (call) async {
      methods.add(call.method);
      if (call.method == 'getProviderMetadata') {
        return {'album_artist': 'Artist'};
      }
      if (call.method != 'downloadByStrategy') return null;
      calls.add(calls.length + 1);
      requests.add(call.arguments.toString());
      return respond(calls.length);
    });
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(directory.path)),
        extensionProvider.overrideWith(_Extensions.new),
        downloadQueueProvider.overrideWith(_Queue.new),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.flushQueuePersistence();
    return (
      container: container,
      queue: queue,
      calls: calls,
      requests: requests,
    );
  }

  Future<DownloadItem> failedItem(ProviderContainer container) async {
    final done = Completer<DownloadItem>();
    container.listen(downloadQueueProvider, (previous, next) {
      final item = next.items.firstOrNull;
      if (item != null &&
          item.status == DownloadStatus.failed &&
          !done.isCompleted) {
        done.complete(item);
      }
    });
    return done.future.timeout(const Duration(seconds: 5));
  }

  late ProviderCooldown cooldown;
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 11, 16, 12);
    cooldown = ProviderCooldown(clock: () => now, store: _MemoryStore());
    ProviderCooldown.instance = cooldown;
    _autoFallback = false;
    _fromBatch = false;
    _android = false;
    _itemCount = 1;
    _statuses = null;
  });

  Future<void> until(bool Function() condition) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  DownloadItem item(ProviderContainer c, String id) =>
      c.read(downloadQueueProvider).items.firstWhere((i) => i.id == id);
  bool paused(ProviderContainer c) => c.read(downloadQueueProvider).isPaused;

  test(
    'limite de peticiones pausa la cola sin fallar los pendientes',
    () async {
      _itemCount = 3;
      final directory = await Directory.systemTemp.createTemp('pacing-');
      addTearDown(() => directory.delete(recursive: true));
      final run = await start(
        directory,
        (call) => {
          'success': false,
          'error_type': 'rate_limit',
          'error': 'Busy',
          'retry_after_seconds': 40947,
        },
      );
      run.queue.resumeQueue();
      await until(() => paused(run.container));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(run.calls, hasLength(1));
      expect(item(run.container, 'song0').status, DownloadStatus.failed);
      expect(item(run.container, 'song1').status, DownloadStatus.queued);
      expect(item(run.container, 'song2').status, DownloadStatus.queued);
    },
  );

  test('un proveedor en enfriamiento pausa la cola y no se llama', () async {
    _itemCount = 2;
    final directory = await Directory.systemTemp.createTemp('pacing-');
    addTearDown(() => directory.delete(recursive: true));
    cooldown.note('example-provider', 900);
    final run = await start(directory, (_) => {'success': true});
    run.queue.resumeQueue();
    await until(() => paused(run.container));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(run.calls, isEmpty);
    expect(item(run.container, 'song0').status, DownloadStatus.queued);
    expect(item(run.container, 'song1').status, DownloadStatus.queued);
    expect(
      item(run.container, 'song0').preparationStage,
      DownloadQueueNotifier.cooldownWaitText,
    );
  });

  test('reanudar a mano tras vencer el enfriamiento sigue la cola', () async {
    _itemCount = 2;
    final directory = await Directory.systemTemp.createTemp('pacing-');
    addTearDown(() => directory.delete(recursive: true));
    cooldown.note('example-provider', 900);
    final run = await start(directory, (_) => {'success': true});
    run.queue.resumeQueue();
    await until(() => paused(run.container));
    now = now.add(const Duration(seconds: 901));
    run.queue.resumeQueue();
    await until(() => run.calls.isNotEmpty);
    expect(paused(run.container), isFalse);
  });

  test('tres fallos seguidos pausan la cola', () async {
    _itemCount = 5;
    final directory = await Directory.systemTemp.createTemp('pacing-');
    addTearDown(() => directory.delete(recursive: true));
    final run = await start(
      directory,
      (_) => {'success': false, 'error_type': 'timeout', 'error': 'late'},
    );
    run.queue.resumeQueue();
    await until(() => paused(run.container));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(run.calls, hasLength(3));
    expect(item(run.container, 'song3').status, DownloadStatus.queued);
    expect(item(run.container, 'song4').status, DownloadStatus.queued);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('un item de lote no abre relevo entre proveedores', () async {
    _autoFallback = true;
    _fromBatch = true;
    final directory = await Directory.systemTemp.createTemp('pacing-');
    addTearDown(() => directory.delete(recursive: true));
    final run = await start(directory, (_) => {'success': true});
    run.queue.resumeQueue();
    await until(() => run.calls.isNotEmpty);
    expect(run.requests.first, contains('"use_fallback":false'));
  });

  test('un item suelto conserva el relevo con autoFallback', () async {
    _autoFallback = true;
    final directory = await Directory.systemTemp.createTemp('pacing-');
    addTearDown(() => directory.delete(recursive: true));
    final run = await start(directory, (_) => {'success': true});
    run.queue.resumeQueue();
    await until(() => run.calls.isNotEmpty);
    expect(run.requests.first, contains('"use_fallback":true'));
  });

  test(
    'un item de lote en enfriamiento pausa aunque haya autoFallback',
    () async {
      _autoFallback = true;
      _fromBatch = true;
      final directory = await Directory.systemTemp.createTemp('pacing-');
      addTearDown(() => directory.delete(recursive: true));
      cooldown.note('example-provider', 900);
      final run = await start(directory, (_) => {'success': true});
      run.queue.resumeQueue();
      await until(() => paused(run.container));
      expect(run.calls, isEmpty);
      expect(item(run.container, 'song0').status, DownloadStatus.queued);
    },
  );

  test('removeFailedItems quita solo las fallidas', () async {
    _statuses = [
      DownloadStatus.failed,
      DownloadStatus.queued,
      DownloadStatus.completed,
      DownloadStatus.failed,
      DownloadStatus.skipped,
    ];
    _itemCount = _statuses!.length;
    final directory = await Directory.systemTemp.createTemp('pacing-');
    addTearDown(() => directory.delete(recursive: true));
    final run = await start(directory, (_) => {'success': true});
    expect(run.queue.removeFailedItems(), 2);
    final ids = run.container
        .read(downloadQueueProvider)
        .items
        .map((i) => i.id)
        .toList();
    expect(ids, ['song1', 'song2', 'song4']);
    expect(run.queue.removeFailedItems(), 0);
  });
}
