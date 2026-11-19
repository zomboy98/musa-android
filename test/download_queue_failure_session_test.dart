import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/utils/logger.dart';

class _Settings extends SettingsNotifier {
  _Settings(this._directory);
  final String _directory;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: _directory,
    embedMetadata: false,
    saveDownloadHistory: false,
    autoExportFailedDownloads: true,
    autoFallback: false,
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

DownloadItem _item(
  String id, {
  String service = 'example-provider',
  String networkDownloadFolder = '',
}) => DownloadItem(
  id: id,
  track: Track(
    id: 'extension:example:$id',
    name: id == 'backend-failure' ? 'diagnostic-canary title' : id,
    artistName: 'diagnostic-canary artist',
    albumName: 'Album',
    duration: 180,
  ),
  service: service,
  networkDownloadFolder: networkDownloadFolder,
  createdAt: DateTime.utc(2026),
);

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      items: [
        _item('backend-failure'),
        _item('exception'),
        _item(
          'network-failure',
          service: 'unavailable-provider',
          networkDownloadFolder: 'smb://example.test/music',
        ),
        _item('unavailable', service: 'unavailable-provider'),
        _item('cancelled'),
        _item('rate-limited'),
      ],
    );
  }
}

void _registerQueueTest(
  TestDefaultBinaryMessenger messenger, {
  required bool typedFailure,
}) {
  test(
    'queue retains failures and retries without summary notifications (typed=$typedFailure)',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'queue-failures-',
      );
      final outputDirectory = await Directory(
        '${directory.path}/diagnostic-canary-output',
      ).create();
      addTearDown(() => directory.delete(recursive: true));
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactorySqflitePlugin;
      addTearDown(() => databaseFactory = previousFactory);
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      SharedPreferences.setMockInitialValues({
        'app_state_migrated_queue_to_sqlite_v1': true,
      });
      final wasLoggingEnabled = LogBuffer.loggingEnabled;
      LogBuffer.loggingEnabled = true;
      addTearDown(() => LogBuffer.loggingEnabled = wasLoggingEnabled);
      const backend = MethodChannel('com.zarz.mornye/backend');
      const sqlite = MethodChannel('com.tekartik.sqflite');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const notifications = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      const permissions = MethodChannel(
        'flutter.baseflow.com/permissions/methods',
      );
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      const progress = MethodChannel(
        'com.zarz.mornye/download_progress_stream',
      );
      final summaries = <String>[];
      final attempts = <String>[];
      final resetIds = <String>[];
      var failedQueueWrites = 0;
      final durableBatches = <String>[];
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      messenger.setMockMethodCallHandler(connectivity, (_) async => null);
      messenger.setMockMethodCallHandler(progress, (_) async => null);
      messenger.setMockMethodCallHandler(permissions, (call) async {
        if (call.method == 'checkPermissionStatus') {
          return PermissionStatus.granted.index;
        }
        return <int, int>{};
      });
      messenger.setMockMethodCallHandler(sqlite, (call) async {
        if (call.method == 'openDatabase') return {'id': 1};
        if (call.method == 'batch' &&
            call.arguments.toString().contains('download_queue_items') &&
            failedQueueWrites == 0) {
          failedQueueWrites++;
          throw PlatformException(
            code: 'sqlite_error',
            message: 'Failed queue SQL with diagnostic-canary sqlite JSON',
            details: {'row': '{"password":"diagnostic-canary fixture"}'},
          );
        }
        if (call.method == 'batch') {
          durableBatches.add(call.arguments.toString());
        }
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
      messenger.setMockMethodCallHandler(notifications, (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'show') {
          final body = (call.arguments as Map)['body'] as String?;
          if (body != null && body.contains('downloaded,')) {
            summaries.add(body);
            if (summaries.length == 1) {
              throw PlatformException(
                code: 'notification_unavailable',
                message: 'Notification server unavailable',
              );
            }
          }
        }
        return null;
      });
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'resetDownloadCancel') {
          resetIds.add((call.arguments as Map)['item_id'] as String);
        }
        if (call.method != 'downloadByStrategy') return null;
        final request = jsonDecode(call.arguments as String) as Map;
        final id = request['item_id'] as String;
        attempts.add(id);
        if (id == 'exception') {
          throw PlatformException(
            code: 'fixture',
            message: 'Fixture processing error',
          );
        }
        if (id == 'rate-limited') {
          return {
            'success': false,
            'error':
                'Could not fetch track data: SoundCloud API returned HTTP 429',
            'error_type': 'api_error',
            'retry_after_seconds': 5,
          };
        }
        if (id == 'backend-failure' && typedFailure) {
          return {
            'success': false,
            'error':
                'Provider verification required? https://diagnostic-canary.invalid/?token=secret',
            'error_type': 'subscription_required',
          };
        }
        return {
          'success': false,
          'error': id == 'cancelled'
              ? 'Cancelled'
              : 'Fixture track unavailable https://diagnostic-canary.invalid/song',
          'error_type': id == 'cancelled' ? 'cancelled' : 'not_found',
          'diagnostic_cause': id == 'cancelled'
              ? 'strict_quality_mismatch'
              : 'encrypted_validation_guard',
          if (id == 'backend-failure')
            'provider_attempts': [
              {'provider': 'tidal-web', 'stage': 'availability', 'error_type': ''},
              'hostile-non-map-item',
              {
                'provider': 'https://diagnostic-canary.invalid/?token=secret',
                'stage': 'download',
                'error_type': 'timeout',
              },
              {'provider': 'qobuz', 'stage': 'secret-stage', 'error_type': 'secret-type'},
            ],
        };
      });
      addTearDown(() {
        for (final channel in [
          backend,
          sqlite,
          paths,
          notifications,
          permissions,
          connectivity,
          progress,
        ]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(outputDirectory.path)),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(_Queue.new),
        ],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier);
      queue.pauseQueue(persistAcrossRestarts: false);
      await queue.flushQueuePersistence();
      var finished = Completer<void>();
      container.listen(downloadQueueProvider, (previous, next) {
        if (previous?.isProcessing == true &&
            !next.isProcessing &&
            !finished.isCompleted) {
          finished.complete();
        }
      });

      queue.resumeQueue();
      await finished.future.timeout(const Duration(seconds: 10));
      final first = container.read(downloadQueueProvider);
      expect(failedQueueWrites, 1);
      final persistenceLogs = LogBuffer().entries.where(
        (entry) => entry.message.contains('Failed to persist queue'),
      );
      expect(persistenceLogs, isNotEmpty);
      expect(persistenceLogs.every((entry) => entry.error == null), isTrue);
      expect(persistenceLogs.toString(), isNot(contains('diagnostic-canary')));

      expect(attempts, [
        'backend-failure',
        'exception',
        'cancelled',
        'rate-limited',
        'rate-limited',
      ]);
      expect(first.lookup.failedCount, 5);
      expect(
        first.lookup.byItemId['rate-limited']!.errorType,
        DownloadErrorType.rateLimit,
      );
      expect(
        first.lookup.byItemId['cancelled']!.status,
        DownloadStatus.skipped,
      );
      expect(
        first.lookup.byItemId['backend-failure']!.errorType,
        typedFailure
            ? DownloadErrorType.subscriptionRequired
            : DownloadErrorType.notFound,
      );
      expect(
        first.lookup.byItemId['exception']!.error,
        contains('Fixture processing error'),
      );
      expect(
        first.lookup.byItemId['network-failure']!.error,
        'Provider is unavailable',
      );
      expect(
        first.lookup.byItemId['unavailable']!.error,
        'Provider is unavailable',
      );
      if (typedFailure) {
        final item = first.lookup.byItemId['backend-failure']!;
        expect(item.error, 'Provider subscription required');
        expect(item.errorMessage, 'Provider subscription required');
      }
      expect(summaries, isEmpty);
      final diagnostics = (await BugLog.instance.entries())
          .where((row) => row['type'] == 'TerminalDownloadFailure')
          .toList();
      expect(diagnostics, hasLength(5));
      expect(
        diagnostics.where(
          (row) =>
              row['frames'] ==
              'stage_backend_download, error_type_rate_limit, cause_unknown',
        ),
        hasLength(1),
      );
      expect(
        diagnostics.where(
          (row) =>
              row['frames'] ==
              (typedFailure
                  ? 'stage_backend_download, error_type_subscription_required, cause_unknown'
                  : 'stage_backend_download, error_type_not_found, cause_encrypted_validation_guard, '
                        'attempts_tidal:availability:none;unknown:download:timeout;'
                        'qobuz:unknown:unknown'),
        ),
        hasLength(1),
      );
      expect(diagnostics.toString(), isNot(contains('diagnostic-canary')));
      expect(diagnostics.toString(), isNot(contains('token=secret')));
      expect(diagnostics.toString(), isNot(contains('secret-stage')));
      expect(diagnostics.toString(), isNot(contains('secret-type')));
      expect(diagnostics.toString(), isNot(contains('hostile-non-map-item')));
      expect(
        diagnostics.toString(),
        isNot(contains('Fixture processing error')),
      );
      expect(
        diagnostics.toString(),
        isNot(contains('cause_strict_quality_mismatch')),
      );
      expect(
        LogBuffer().entries.where(
          (entry) => entry.message.contains('diagnostic-canary'),
        ),
        isEmpty,
      );
      final exports = await Directory(
        '${outputDirectory.path}/failed_downloads',
      ).list().where((entry) => entry is File).cast<File>().toList();
      expect(exports, hasLength(1));
      expect(
        await exports.single.readAsString(),
        typedFailure
            ? allOf(
                contains('Provider subscription required'),
                isNot(contains('token=secret')),
              )
            : allOf(
                contains('No matching track found for this download'),
                isNot(contains('Fixture track unavailable')),
                isNot(contains('diagnostic-canary.invalid')),
              ),
      );
      expect(
        LogBuffer().entries.where(
          (entry) => entry.message.contains('Download queue processing failed'),
        ),
        isEmpty,
      );

      finished = Completer<void>();
      await queue.retryItem('backend-failure');
      await finished.future.timeout(const Duration(seconds: 10));
      expect(resetIds, ['backend-failure']);
      expect(attempts, [
        'backend-failure',
        'exception',
        'cancelled',
        'rate-limited',
        'rate-limited',
        'backend-failure',
      ]);
      expect(container.read(downloadQueueProvider).lookup.failedCount, 5);
      final afterRetry = await BugLog.instance.entries();
      expect(
        afterRetry.where((row) => row['type'] == 'TerminalDownloadFailure'),
        hasLength(6),
      );
      expect(summaries, isEmpty);
      await queue.flushQueuePersistence();
      if (typedFailure) {
        expect(
          durableBatches.where(
            (batch) => batch.contains('subscriptionRequired'),
          ),
          isNotEmpty,
        );
        expect(durableBatches.toString(), isNot(contains('token=secret')));
        await (await AppStateDatabase.instance.database).close();
      }
    },
  );
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  _registerQueueTest(messenger, typedFailure: false);
  _registerQueueTest(messenger, typedFailure: true);
}
