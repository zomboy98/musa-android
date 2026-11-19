import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/download_queue_codec.dart';
import 'support/fixed_settings.dart';
import 'support/native_discard_memory.dart';

class _Extensions extends ExtensionNotifier {
  @override
  Future<void> ensureInitialized() async {}
  @override
  ExtensionState build() => const ExtensionState(extensions: [Extension(id: 'fixture', name: 'fixture', displayName: 'Fixture', version: '1', description: '', enabled: true, status: 'loaded', hasDownloadProvider: true)]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeDiscardMemory discards;
  setUp(() { discards = NativeDiscardMemory(); });
  final sharedCases = <String, ({String type, String message, String expected})>{};
  for (final line in File(
    'android/app/src/test/resources/download_rate_limit_cases.tsv',
  ).readAsLinesSync()) {
    final [name, type, message, expected] = line.split('\t');
    sharedCases['shared_$name'] = (type: type, message: message, expected: expected);
  }
  const typedFailures = {
    'subscription_required': (type: 'subscriptionRequired', message: 'Provider subscription required'),
    'expired_stream': (type: 'expiredStream', message: 'Provider stream request failed; a refreshed stream may be available'),
    'http_error': (type: 'httpError', message: 'Provider HTTP request failed'),
    'integrity_failed': (type: 'integrityFailed', message: 'Provider download failed integrity validation'),
    'transient_network': (type: 'transientNetwork', message: 'Provider network request failed'),
    'timeout': (type: 'timeout', message: 'The provider request timed out. Try again later.'),
    'auth': (type: 'authenticationError', message: 'Provider authentication failed'),
    'authentication_error': (type: 'authenticationError', message: 'Provider authentication failed'),
    'provider_auth_failed': (type: 'authenticationError', message: 'Provider authentication failed'),
    'request_auth_invalid': (type: 'authenticationError', message: 'Provider authentication failed'),
    'provider_reauth_required': (type: 'providerReauthRequired', message: 'Reconnect the provider account'),
    'provider_unavailable': (type: 'providerUnavailable', message: 'Provider is unavailable'),
    'storage_error': (type: 'fileError', message: 'Provider could not write the download'),
    'file_error': (type: 'fileError', message: 'Provider could not write the download'),
    'isp_blocked': (type: 'ispBlocked', message: 'Provider access may be blocked by the network'),
    'not_implemented': (type: 'notImplemented', message: 'Provider does not implement this download operation'),
    'invalid_url': (type: 'invalidUrl', message: 'Provider download URL is invalid'),
    'provider_error': (type: 'providerError', message: 'Provider request failed'),
    'extension_error': (type: 'providerError', message: 'Provider request failed'),
    'runtime_error': (type: 'providerError', message: 'Provider request failed'),
    'script_error': (type: 'providerError', message: 'Provider request failed'),
    'download_error': (type: 'providerError', message: 'Provider request failed'),
    'init_error': (type: 'providerError', message: 'Provider request failed'),
  };
  for (final failureType in [
    ...typedFailures.keys,
    'unknown_type',
    'legacy_generic_network',
    null,
    'quality_unavailable',
    'http_429',
    'legacy_rate_limit',
    'soundcloud_rate_limit',
    'soundcloud_not_rate_limit',
    'deezer_rate_limit',
    'network_path',
    'network_url_parameter',
    'provider_attempts',
    ...sharedCases.keys,
  ]) {
  final terminalFailure = failureType != null;
  final shared = sharedCases[failureType];
  final typed = typedFailures[failureType];
  test('start error reconciles stopped result before ownership release (failure=$failureType)', () async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    var runId = '';
    var itemId = '';
    var startCalls = 0;
    var blockWrite = false;
    final savedRows = <Map<String, dynamic>>[];
    final deletedIdsFromStorage = <String>{};
    final writeEntered = Completer<void>();
    final release = Completer<void>();
    const channel = MethodChannel('com.zarz.mornye/backend');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => Directory.systemTemp.path);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startNativeDownloadWorker') {
        startCalls++;
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final settingsFile = File(args['settings_path'] as String);
        final requestsFile = File(args['requests_path'] as String);
        final settings = jsonDecode(await settingsFile.readAsString()) as Map;
        final requests = jsonDecode(await requestsFile.readAsString()) as List;
        runId = settings['run_id'] as String;
        itemId = (requests.single as Map)['item_id'] as String;
        await settingsFile.delete();
        await requestsFile.delete();
        blockWrite = true;
        throw PlatformException(code: 'channel_failure');
      }
      if (call.method == 'getNativeDownloadWorkerSnapshot') {
        final item = {
          'item_id': itemId,
          'status': terminalFailure ? 'failed' : 'skipped',
          if (terminalFailure)
            'result': {
              'success': false,
              'error': shared?.message ?? switch (failureType) {
                'http_429' => 'HTTP error: 429 https://diagnostic-canary.invalid',
                'legacy_rate_limit' => 'Provider throttled',
                'soundcloud_rate_limit' =>
                  'Could not fetch track data: SoundCloud API returned HTTP 429',
                'soundcloud_not_rate_limit' =>
                  'Could not fetch track data: SoundCloud API returned HTTP 4290',
                'deezer_rate_limit' =>
                  'Failed to resolve Deezer download: HTTP 429 for https://diagnostic-canary.invalid/track',
                'network_path' || 'legacy_generic_network' =>
                  'Connection reset https://diagnostic-canary.invalid/track/1429',
                'network_url_parameter' =>
                  'Connection reset https://diagnostic-canary.invalid/track;status=429',
                _ => 'Native error https://diagnostic-canary.invalid',
              },
              'error_type': shared?.type ?? switch (failureType) {
                'quality_unavailable' => 'quality_unavailable',
                'legacy_rate_limit' => 'rate_limited',
                'soundcloud_rate_limit' ||
                'soundcloud_not_rate_limit' ||
                'deezer_rate_limit' => 'api_error',
                'unknown_type' => 'diagnostic-canary-type',
                'legacy_generic_network' => 'api_error',
                _ => typed == null ? 'network' : failureType,
              },
              'failure_stage': 'downloading',
              if (failureType == 'quality_unavailable')
                'diagnostic_cause': 'encrypted_validation_guard',
              if (failureType == 'provider_attempts')
                'provider_attempts': [
                  {'provider': 'tidal-web', 'stage': 'availability', 'error_type': ''},
                  {'provider': 'https://diagnostic-canary.invalid/?token=secret', 'stage': 'download', 'error_type': 'timeout'},
                  {'provider': 'qobuz', 'stage': 'secret-stage', 'error_type': 'secret-type'},
                ],
            },
        };
        return {
          'run_id': runId,
          'contract_version': 1,
          'is_running': false,
          'items': [item],
          'item_delta': item,
        };
      }
      return null;
    });
    addTearDown(() { messenger.setMockMethodCallHandler(channel, null); messenger.setMockMethodCallHandler(paths, null); });
    final container = ProviderContainer(overrides: [
      settingsProvider.overrideWith(() => FixedSettingsNotifier(const AppSettings(downloadDirectory: '/fixture', nativeDownloadWorkerEnabled: true, useExtensionProviders: true))),
      extensionProvider.overrideWith(_Extensions.new),
      downloadQueueProvider.overrideWith(() => DownloadQueueNotifier(isAndroidForTesting: true, nativeRequestJsonForTesting: (_) async => '{}', queuePersistenceForTesting: (items, onError) => DownloadQueuePersistence(
        currentItems: items, onError: onError, loadRows: () async => [], loadSelectionEvents: () async => [],
        applyNativeDiscardChanges: discards.apply, loadNativeDiscardsFromStorage: discards.load, ackNativeDiscardsInStorage: discards.ack,
        applyChanges: ({required upserts, required deletedIds}) async {
          savedRows.removeWhere((row) => deletedIds.contains(row['id']));
          deletedIdsFromStorage.addAll(deletedIds);
          for (final row in upserts) {
            savedRows.removeWhere((saved) => saved['id'] == row['id']);
            savedRows.add(row);
          }
          if (blockWrite) {
            if (!writeEntered.isCompleted) writeEntered.complete();
            await release.future;
          }
        },
        applySelectionChanges: ({required upserts, required deletedIds, required selectionEvents}) async {},
      ))),
    ]);
    final notifier = container.read(downloadQueueProvider.notifier);
    await notifier.flushQueuePersistence();
    notifier.addToQueue(const Track(id: 'error', name: 'Error', artistName: 'Artist', albumName: 'Album', duration: 1), 'fixture');
    await writeEntered.future.timeout(const Duration(seconds: 8));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('download_queue_native_worker_run_id'), runId);
    expect(startCalls, 1);
    release.complete();
    for (var i = 0; i < 300 && prefs.getString('download_queue_native_worker_run_id') != null; i++) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    expect(prefs.getString('download_queue_native_worker_run_id'), isNull);
    expect(
      container.read(downloadQueueProvider).items.single.status.name,
      terminalFailure ? 'failed' : 'skipped',
    );
    if (failureType == 'legacy_generic_network') {
      final item = container.read(downloadQueueProvider).items.single;
      expect(item.errorType?.name, 'network');
      expect(item.error, 'Connection failed, check your internet');
    }
    if (failureType == 'unknown_type') {
      final item = container.read(downloadQueueProvider).items.single;
      expect(item.errorType?.name, 'unknown');
      expect(item.errorMessage, 'Download failed');
      expect(savedRows.toString(), isNot(contains('diagnostic-canary')));
    }
    if (typed != null) {
      final item = container.read(downloadQueueProvider).items.single;
      expect(item.errorType?.name, typed.type);
      expect(item.error, typed.message);
      expect(item.errorMessage, typed.message);
      final restored = (await decodeDownloadQueueRows(savedRows)).items.single;
      expect(restored.id, itemId);
      expect(restored.status.name, 'failed');
      expect(restored.errorType, item.errorType);
      expect(restored.error, typed.message);
      expect(restored.errorMessage, item.errorMessage);
      expect(savedRows.toString(), isNot(contains('diagnostic-canary')));
    }
    final entries = (await BugLog.instance.entries())
        .where((entry) => entry['type'] == 'TerminalDownloadFailure');
    expect(entries, hasLength(terminalFailure ? 1 : 0));
    if (terminalFailure) {
      expect(
        entries.single['frames'],
        shared != null
            ? 'stage_backend_download, error_type_${shared.expected == 'unknown' ? shared.type : shared.expected}, cause_unknown'
            : switch (failureType) {
          'http_429' ||
          'legacy_rate_limit' ||
          'soundcloud_rate_limit' ||
          'deezer_rate_limit' =>
            'stage_backend_download, error_type_rate_limit, cause_unknown',
          'soundcloud_not_rate_limit' || 'legacy_generic_network' =>
            'stage_backend_download, error_type_api_error, cause_unknown',
          'network_path' || 'network_url_parameter' =>
            'stage_backend_download, error_type_network, cause_unknown',
          'unknown_type' =>
            'stage_backend_download, error_type_unknown, cause_unknown',
          'provider_attempts' =>
            'stage_backend_download, error_type_network, cause_unknown, '
            'attempts_tidal:availability:none;unknown:download:timeout;'
            'qobuz:unknown:unknown',
          _ when typed != null =>
            'stage_backend_download, error_type_$failureType, cause_unknown',
          _ => 'stage_backend_download, error_type_quality_unavailable, cause_encrypted_validation_guard',
        },
      );
    }
    expect(startCalls, 1);
    if (typed != null) {
      notifier.removeItem(itemId);
      await notifier.flushQueuePersistence();
      expect(deletedIdsFromStorage, contains(itemId));
      expect((await decodeDownloadQueueRows(savedRows)).items, isEmpty);
    }
    container.dispose();
  });
  }
}
