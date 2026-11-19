import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';

import 'support/native_discard_memory.dart';

class _Settings extends SettingsNotifier {
  _Settings(
    this._directory, {
    required this.native,
    this.defaultQuality,
    this.bundled,
    this.fallback = false,
    this.autoFallback = false,
    this.qualitySource,
  });
  final String _directory;
  final bool native;
  final bool fallback;
  final bool autoFallback;
  final String? defaultQuality;
  final Extension? bundled;
  final DownloadQualitySource? qualitySource;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: _directory,
    // This file is the contract of "only this quality". Since the provider
    // relay became the default, the pre-check and the absence of substitutes
    // asserted below hold only in strict mode; the relay default is covered
    // by download_queue_relay_dedupe_test.dart and the Rust relay tests.
    strictDownloadQuality: true,
    embedMetadata: false,
    saveDownloadHistory: false,
    autoFallback: fallback || autoFallback,
    nativeDownloadWorkerEnabled: native,
    defaultService: fallback
        ? 'unavailable'
        : bundled?.id ?? (defaultQuality == null ? '' : 'deezer-extension'),
    audioQuality: defaultQuality ?? (bundled == null ? 'LOSSLESS' : ''),
    downloadQualitySourceByProvider: {
      if (qualitySource != null) qualitySource!.provider: qualitySource!,
    },
    downloadQualityByProvider: {
      if (bundled != null && defaultQuality != null && !fallback)
        bundled!.id: defaultQuality!,
      if (bundled == null)
        'deezer-extension': defaultQuality == null ? '\u0085 FLAC ' : 'ÄAC',
    },
  );
}

class _Extensions extends ExtensionNotifier {
  _Extensions(this.bundled);
  final Extension? bundled;
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      if (bundled != null) bundled!,
      Extension.fromJson({
        'id': 'example-provider',
        'name': 'Example Provider',
        'enabled': true,
        'has_download_provider': true,
        'quality_options': [
          {'id': 'b1', 'label': 'B1'},
          {'id': 'b2', 'label': 'B2'},
        ],
        'skip_metadata_enrichment': true,
      }),
      Extension.fromJson({
        'id': 'legacy',
        'name': 'Legacy',
        'enabled': true,
        'has_download_provider': true,
        'skip_metadata_enrichment': true,
      }),
      Extension.fromJson({
        'id': 'common',
        'name': 'Common',
        'enabled': true,
        'has_download_provider': true,
        'skip_metadata_enrichment': true,
        'quality_options': [
          {'id': 'LOSSLESS', 'label': 'Different semantics'},
        ],
      }),
      Extension.fromJson({
        'id': 'deezer-extension',
        'name': 'Deezer fixture',
        'enabled': true,
        'has_download_provider': true,
        'skip_metadata_enrichment': true,
        'quality_options': [
          {'id': ' flac ', 'label': 'FLAC'},
          {'id': 'FLAC', 'label': 'Duplicate'},
          {'id': 'ÄAC', 'label': 'Unicode ID'},
        ],
      }),
    ],
  );

  @override
  Future<void> ensureInitialized() async {}
}

DownloadItem _item(
  String id, {
  String service = 'example-provider',
  String? qualityOverride,
}) => DownloadItem(
  id: id,
  track: Track(
    id: 'extension:example:$id',
    name: id,
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
  ),
  service: service,
  qualityOverride: qualityOverride,
  createdAt: DateTime.utc(2026),
);

class _Queue extends DownloadQueueNotifier {
  _Queue({
    required this.native,
    required NativeDiscardMemory discards,
    this.qualityOverride,
    this.bundled,
  }) : super(
         isAndroidForTesting: native,
         queuePersistenceForTesting: (items, onError) =>
             DownloadQueuePersistence(
               currentItems: items,
               onError: onError,
               loadRows: () async => [],
               loadSelectionEvents: () async => [],
               applyChanges: ({required upserts, required deletedIds}) async {},
               applySelectionChanges:
                   ({
                     required upserts,
                     required deletedIds,
                     required selectionEvents,
                   }) async {},
               applyNativeDiscardChanges: discards.apply,
               loadNativeDiscardsFromStorage: discards.load,
               ackNativeDiscardsInStorage: discards.ack,
             ),
       );

  final bool native;
  final String? qualityOverride;
  final Extension? bundled;

  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      items: [
        if (native || bundled != null)
          _item(
            'canonical',
            service: bundled?.id ?? 'deezer-extension',
            qualityOverride: qualityOverride,
          )
        else ...[
          _item('disjoint'),
          _item('coincidence', service: 'common'),
          _item('legacy', service: 'legacy'),
          _item('canonical', service: 'deezer-extension'),
          _item(
            'duplicate',
            service: 'deezer-extension',
            qualityOverride: 'FLAC',
          ),
          _item(
            'different',
            service: 'deezer-extension',
            qualityOverride: 'LOSSLESS',
          ),
          _item('empty', service: 'deezer-extension', qualityOverride: '  '),
          _item('foreign', service: 'common', qualityOverride: ' FLAC '),
          _item(
            'unicode-case',
            service: 'deezer-extension',
            qualityOverride: 'äac',
          ),
          _item(
            'unicode-exact',
            service: 'deezer-extension',
            qualityOverride: ' Äac ',
          ),
          _item(
            'bom',
            service: 'deezer-extension',
            qualityOverride: '\ufeffflac',
          ),
        ],
      ],
    );
  }
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  Future<void> verifyQueuePayload({
    required bool native,
    String? defaultQuality,
    String? qualityOverride,
    bool expectInvalidDefault = false,
    Extension? bundled,
    String? expectedBundledQuality,
    bool fallback = false,
    bool autoFallback = false,
    bool strictUnavailableFirst = false,
    bool forceDart = false,
    bool cancelOnFirst = false,
    String? firstErrorType,
    List<String>? expectedQualities,
    DownloadQualitySource? qualitySource,
    List<bool>? expectSources,
  }) async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    final directory = await Directory.systemTemp.createTemp('queue-failures-');
    addTearDown(() => directory.delete(recursive: true));
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({});
    const backend = MethodChannel('com.zarz.mornye/backend');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const notifications = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    const connectivity = MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const progress = MethodChannel('com.zarz.mornye/download_progress_stream');
    final attempts = <String>[];
    final qualities = <String>[];
    final capturedRequests = <Map<dynamic, dynamic>>[];
    late DownloadQueueNotifier queue;
    final requests = <String, Map<dynamic, dynamic>>{};
    String? nativeRunId;
    var nativeStarts = 0;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    messenger.setMockMethodCallHandler(progress, (_) async => null);
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'checkPermissionStatus') {
        return PermissionStatus.granted.index;
      }
      return <int, int>{};
    });
    messenger.setMockMethodCallHandler(notifications, (call) async {
      if (call.method == 'initialize') return true;
      return null;
    });
    void captureRequest(Map<dynamic, dynamic> request) {
      final id = request['item_id'] as String;
      requests[id] = request;
      capturedRequests.add(request);
      attempts.add(id);
      qualities.add(request['quality'] as String);
    }

    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'startNativeDownloadWorker') {
        nativeStarts++;
        final args = call.arguments as Map;
        final settingsFile = File(args['settings_path'] as String);
        final requestsFile = File(args['requests_path'] as String);
        final settings = jsonDecode(await settingsFile.readAsString()) as Map;
        final entries = jsonDecode(await requestsFile.readAsString()) as List;
        nativeRunId = settings['run_id'] as String;
        captureRequest(
          jsonDecode(entries.single['request_json'] as String) as Map,
        );
        await settingsFile.delete();
        await requestsFile.delete();
        return null;
      }
      if (call.method == 'getNativeDownloadWorkerSnapshot' &&
          nativeRunId != null) {
        return {
          'run_id': nativeRunId,
          'contract_version': 1,
          'is_running': false,
          'items': [
            {
              'item_id': 'canonical',
              'status': 'failed',
              'result': {'success': false, 'error_type': 'not_found'},
            },
          ],
        };
      }
      if (call.method != 'downloadByStrategy') return null;
      final request = jsonDecode(call.arguments as String) as Map;
      captureRequest(request);
      if (firstErrorType != null && qualities.length == 1) {
        return {'success': false, 'error': 'provider unavailable', 'error_type': firstErrorType};
      }
      if (strictUnavailableFirst && qualities.length == 1) {
        if (cancelOnFirst) queue.cancelItem(request['item_id'] as String);
        return const {'success': false, 'error': 'quality unavailable', 'error_type': 'quality_unavailable'};
      }
      return const {
        'success': false,
        'error': 'Fixture track unavailable',
        'error_type': 'not_found',
      };
    });
    addTearDown(() {
      for (final channel in [
        backend,
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
        settingsProvider.overrideWith(
          () => _Settings(
            directory.path,
            native: native,
            defaultQuality: defaultQuality,
            fallback: fallback,
            autoFallback: autoFallback,
            bundled: bundled,
            qualitySource: qualitySource,
          ),
        ),
        extensionProvider.overrideWith(() => _Extensions(bundled)),
        downloadQueueProvider.overrideWith(
          () => _Queue(
            native: native,
            discards: NativeDiscardMemory(),
            qualityOverride: qualityOverride,
            bundled: bundled,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    queue = container.read(downloadQueueProvider.notifier);
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
    if (expectInvalidDefault) {
      expect(nativeStarts, 0);
      expect(attempts, isEmpty);
      final failed = first.lookup.byItemId['canonical']!;
      expect(failed.status, DownloadStatus.failed);
      expect(failed.errorType, DownloadErrorType.qualityUnavailable);
      expect(failed.error, contains('Requested quality unavailable'));
      await queue.flushQueuePersistence();
      return;
    }
    expect(nativeStarts, native && !forceDart ? 1 : 0);
    if (expectSources != null) {
      expect(capturedRequests.length, expectSources.length);
      for (var i = 0; i < expectSources.length; i++) {
        final request = capturedRequests[i];
        if (expectSources[i]) {
          expect(request['quality_source_provider'], qualitySource!.provider);
          expect(request['quality_source_id'], qualitySource.id);
          expect(request['quality_source_kind'], qualitySource.kind);
          expect(request['quality_source_label'], qualitySource.label);
        } else {
          for (final key in ['quality_source_provider', 'quality_source_id', 'quality_source_kind', 'quality_source_label']) {
            expect(request, isNot(contains(key)));
          }
        }
      }
    }
    if (bundled != null) {
      expect(attempts, List.filled(expectedQualities?.length ?? 1, 'canonical'),
          reason: first.lookup.byItemId['canonical']?.error);
      expect(qualities, expectedQualities ?? [expectedBundledQuality!]);
      expect(
        requests['canonical'],
        containsPair('download_provider', bundled.id),
      );
      if (autoFallback && qualityOverride == null && qualities.last == defaultQuality && (defaultQuality?.isNotEmpty ?? false)) {
        expect(requests['canonical'], containsPair('allow_saved_quality_id_fallback', true));
      } else if (qualityOverride != null) {
        expect(requests['canonical'], isNot(contains('allow_saved_quality_id_fallback')));
      }
      await queue.flushQueuePersistence();
      return;
    }
    expect(
      attempts,
      native
          ? ['canonical']
          : ['legacy', 'canonical', 'duplicate', 'unicode-exact'],
    );
    expect(qualities, native ? ['flac'] : ['LOSSLESS', 'flac', 'flac', 'ÄAC']);
    expect(requests['canonical'], containsPair('service', 'deezer-extension'));
    expect(
      requests['canonical'],
      containsPair('download_provider', 'deezer-extension'),
    );
    expect(requests['canonical'], containsPair('use_extensions', true));
    expect(requests['canonical'], containsPair('use_fallback', false));
    expect(requests['canonical'], isNot(contains('allow_quality_fallback')));
    if (!native) {
      expect(first.lookup.byItemId['disjoint']!.status, DownloadStatus.failed);
      expect(
        first.lookup.byItemId['coincidence']!.status,
        DownloadStatus.failed,
      );
      expect(
        first.lookup.byItemId['disjoint']!.error,
        contains('Requested quality unavailable'),
      );
      for (final id in [
        'different',
        'empty',
        'foreign',
        'unicode-case',
        'bom',
      ]) {
        expect(
          first.lookup.byItemId[id]!.error,
          contains('Requested quality unavailable'),
        );
      }
      finished = Completer<void>();
      await queue.retryItemWithQuality('disjoint', ' B1 ');
      await finished.future.timeout(const Duration(seconds: 10));
      expect(attempts, [
        'legacy',
        'canonical',
        'duplicate',
        'unicode-exact',
        'disjoint',
      ]);
      expect(qualities, ['LOSSLESS', 'flac', 'flac', 'ÄAC', 'b1']);
    }
    await queue.flushQueuePersistence();
  }

  test(
    'queue sends the first matching manifest ID with strict provider policy',
    () => verifyQueuePayload(native: false),
  );
  test(
    'simulated Android worker channel receives the strict canonical quality',
    () => verifyQueuePayload(native: true),
  );
  test(
    'simulated Android worker channel prefers the canonical active default',
    () => verifyQueuePayload(native: true, defaultQuality: ' FLAC '),
  );
  test(
    'obsolete active default fails before simulated Android worker dispatch',
    () => verifyQueuePayload(
      native: true,
      defaultQuality: 'obsolete-quality',
      expectInvalidDefault: true,
    ),
  );
  test(
    'simulated Android worker channel receives the explicit quality override',
    () => verifyQueuePayload(
      native: true,
      defaultQuality: 'obsolete-quality',
      qualityOverride: 'flac',
    ),
  );

  Extension bundledExtension(String file, String id) {
    final zip = ZipDecoder().decodeBytes(
      File('assets/bundled_extensions/$file.sflx').readAsBytesSync(),
    );
    final manifest =
        jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content)) as Map;
    return Extension.fromJson({
      'id': id,
      'name': id,
      'enabled': true,
      'has_download_provider': true,
      'quality_options': manifest['qualityOptions'],
      'skip_metadata_enrichment': true,
    });
  }

  for (final native in [false, true]) {
    const source = DownloadQualitySource(provider: 'tidal-web', id: 'HIGH', kind: 'lossy', label: 'High quality');
    test('saved quality source travels through queue (native=$native)', () => verifyQueuePayload(
      native: native, bundled: bundledExtension('tidal-web', 'tidal-web'),
      defaultQuality: 'HIGH', expectedBundledQuality: 'HIGH', qualitySource: source, expectSources: [true],
    ));
    test('explicit override carries no saved source (native=$native)', () => verifyQueuePayload(
      native: native, bundled: bundledExtension('tidal-web', 'tidal-web'),
      defaultQuality: 'HIGH', qualityOverride: 'HIGH', expectedBundledQuality: 'HIGH', qualitySource: source, expectSources: [false],
    ));
    test('stale selected quality is unavailable (native=$native)', () => verifyQueuePayload(
      native: native, bundled: bundledExtension('tidal-web', 'tidal-web'),
      defaultQuality: 'obsolete', expectInvalidDefault: true,
      qualitySource: const DownloadQualitySource(provider: 'tidal-web', id: 'obsolete', kind: 'lossy', label: 'Old'),
    ));
  }
  test('unavailable selected quality does not retry a different default', () => verifyQueuePayload(
    native: false, bundled: bundledExtension('tidal-web', 'tidal-web'),
    defaultQuality: 'HIGH', autoFallback: true, strictUnavailableFirst: true,
    expectedQualities: ['HIGH'],
    qualitySource: const DownloadQualitySource(provider: 'tidal-web', id: 'HIGH', kind: 'lossy', label: 'High quality'),
    expectSources: [true],
  ));

  test(
    'fallback uses its own declared source default',
    () => verifyQueuePayload(
      native: false,
      bundled: bundledExtension('deezer', 'deezer'),
      fallback: true,
      defaultQuality: 'aac-from-unavailable-source',
      expectedBundledQuality: 'flac',
    ),
  );
  test(
    'an explicit source quality takes precedence',
    () => verifyQueuePayload(
      native: true,
      bundled: bundledExtension('tidal-web', 'tidal-web'),
      defaultQuality: 'HIGH',
      expectedBundledQuality: 'HIGH',
    ),
  );
  test(
    'an explicit empty item override is still rejected',
    () => verifyQueuePayload(
      native: true,
      bundled: bundledExtension('amzn', 'amazon'),
      qualityOverride: ' ',
      expectInvalidDefault: true,
    ),
  );

  for (final native in [false, true]) {
    test('network failure never triggers a lower-quality default (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('tidal-web', 'tidal-web'),
        defaultQuality: 'HIGH', expectedQualities: ['HIGH'],
        autoFallback: true, firstErrorType: 'network',
      );
    });
    test('equivalent live ID does not retry default (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon').copyWith(
          qualityOptions: const [
            QualityOption(id: 'flac-new', label: 'FLAC 24-bit 96kHz'),
            QualityOption(id: 'best', label: 'FLAC Best Available'),
          ],
        ),
        defaultQuality: 'flac_24bit_96khz',
        expectedQualities: ['flac-new'],
        autoFallback: true,
        strictUnavailableFirst: true,
      );
    });
    test('saved generic ID is attempted without retrying default (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon'),
        defaultQuality: 'LOSSLESS',
        expectedQualities: ['LOSSLESS'],
        autoFallback: true,
        strictUnavailableFirst: true,
      );
    });
    test('unavailable saved quality does not retry default (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('tidal-web', 'tidal-web'),
        defaultQuality: 'HIGH',
        expectedQualities: ['HIGH'],
        autoFallback: true,
        strictUnavailableFirst: true,
      );
    });
    test('proven stale request reaches provider strategy before local default (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon'),
        defaultQuality: 'flac_24bit_96khz',
        expectedBundledQuality: 'flac_24bit_96khz',
        autoFallback: true,
      );
    });
    test('provider exhaustion does not retry declared default (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon'),
        defaultQuality: 'flac_24bit_96khz',
        expectedQualities: ['flac_24bit_96khz'],
        autoFallback: true,
        strictUnavailableFirst: true,
      );
    });
    test('cancellation suppresses declared default retry (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon'),
        defaultQuality: 'flac_24bit_96khz',
        expectedQualities: ['flac_24bit_96khz'],
        autoFallback: true,
        strictUnavailableFirst: true,
        cancelOnFirst: true,
      );
    });
    test('saved quality maps to a proven equivalent in the live manifest (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon').copyWith(
          qualityOptions: const [QualityOption(id: 'flac-new', label: 'FLAC 24-bit 96kHz')],
        ),
        defaultQuality: 'flac_24bit_96khz',
        expectedBundledQuality: 'flac-new',
      );
    });
    test('explicit item quality does not use equivalence or default (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon').copyWith(
          qualityOptions: const [QualityOption(id: 'flac-new', label: 'FLAC 24-bit 96kHz')],
        ),
        qualityOverride: 'flac_24bit_96khz',
        expectInvalidDefault: true,
      );
    });
    test('stale saved quality without a live default reaches strict provider fallback (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon').copyWith(
          qualityOptions: const [QualityOption(id: 'opus', label: 'Opus')],
        ),
        defaultQuality: 'flac-24bit-96khz',
        expectedBundledQuality: 'flac-24bit-96khz',
        autoFallback: true,
      );
    });
    test('invalid explicit override remains strict with provider fallback enabled (native=$native)', () {
      return verifyQueuePayload(
        native: native,
        bundled: bundledExtension('amzn', 'amazon'),
        qualityOverride: 'not-declared',
        autoFallback: true,
        expectInvalidDefault: true,
      );
    });
  }

  for (final (file, id, quality) in [
    ('amzn', 'amazon', 'opus'),
    ('deezer', 'deezer', 'flac'),
    ('tidal-web', 'tidal-web', 'HIGH'),
    ('ytmusic-spotiflac', 'ytmusic-spotiflac', 'best'),
    ('soundcloud', 'soundcloud', 'aac_160'),
  ]) {
    for (final native in [false, true]) {
      test('$id rejects stale saved preference without equivalent (native=$native)', () {
        return verifyQueuePayload(
          native: native,
          bundled: bundledExtension(file, id),
          defaultQuality: 'obsolete-saved-quality',
          expectInvalidDefault: true,
        );
      });
      test('$id uses $quality from its bundled manifest (native=$native)', () {
        return verifyQueuePayload(
          native: native,
          bundled: bundledExtension(file, id),
          expectedBundledQuality: quality,
        );
      });
      test('$id rejects an invalid explicit override (native=$native)', () {
        return verifyQueuePayload(
          native: native,
          bundled: bundledExtension(file, id),
          qualityOverride: 'invalid-quality',
          expectInvalidDefault: true,
        );
      });
    }
  }
}
