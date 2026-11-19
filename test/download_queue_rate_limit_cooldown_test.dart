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

class _Settings extends SettingsNotifier {
  _Settings(this.directory);
  final String directory;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: directory,
    saveDownloadHistory: false,
    autoFallback: false,
    concurrentDownloads: 1,
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
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      isPaused: true,
      items: [
        DownloadItem(
          id: 'song',
          track: const Track(
            id: 'example:track',
            name: 'Song',
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
        downloadQueueProvider.overrideWith(_Queue.new),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.flushQueuePersistence();
    return (container: container, queue: queue, calls: calls);
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
  });

  test('retry-after largo registra enfriamiento y no espera', () async {
    final directory = await Directory.systemTemp.createTemp('cooldown-');
    addTearDown(() => directory.delete(recursive: true));
    final run = await start(
      directory,
      (_) => {
        'success': false,
        'error_type': 'rate_limit',
        'error': 'Busy',
        'retry_after_seconds': 40947,
      },
    );
    final failed = failedItem(run.container);
    run.queue.resumeQueue();
    final item = await failed;
    expect(item.errorType, DownloadErrorType.rateLimit);
    expect(run.calls, hasLength(1));
    expect(
      cooldown.remaining('example-provider'),
      const Duration(seconds: 40947),
    );
    await run.queue.flushQueuePersistence();
  });

  test('retry-after corto conserva el reintento unico', () async {
    final directory = await Directory.systemTemp.createTemp('cooldown-');
    addTearDown(() => directory.delete(recursive: true));
    final run = await start(
      directory,
      (_) => {
        'success': false,
        'error_type': 'rate_limit',
        'error': 'Busy',
        'retry_after_seconds': 20,
      },
    );
    final waiting = Completer<DownloadItem>();
    run.container.listen(downloadQueueProvider, (previous, next) {
      final item = next.items.firstOrNull;
      if (item?.error?.contains('retrying after 20s') == true &&
          !waiting.isCompleted) {
        waiting.complete(item);
      }
    });
    run.queue.resumeQueue();
    await waiting.future.timeout(const Duration(seconds: 5));
    expect(cooldown.remaining('example-provider'), Duration.zero);
    run.queue.dismissItem('song');
    await run.queue.flushQueuePersistence();
  });

  test('un proveedor en enfriamiento no se llama', () async {
    final directory = await Directory.systemTemp.createTemp('cooldown-');
    addTearDown(() => directory.delete(recursive: true));
    cooldown.note('example-provider', 900);
    final run = await start(directory, (_) => {'success': true});
    run.queue.resumeQueue();
    for (
      var i = 0;
      i < 50 && !run.container.read(downloadQueueProvider).isPaused;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final state = run.container.read(downloadQueueProvider);
    expect(state.isPaused, isTrue);
    expect(state.items.single.status, DownloadStatus.queued);
    expect(run.calls, isEmpty);
    await run.queue.flushQueuePersistence();
  });
}
