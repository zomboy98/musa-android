import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/native_discard_memory.dart';

Track _track(String id) => Track(
  id: id,
  name: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  source: 'catalog',
);

DownloadItem _item(
  String id,
  String track, {
  DownloadStatus status = DownloadStatus.failed,
  String service = 'provider-a',
  String? qualityOverride,
  bool variant = false,
}) => DownloadItem(
  id: id,
  track: _track(track),
  service: service,
  status: status,
  qualityOverride: qualityOverride,
  preserveQualityVariant: variant,
  error: status == DownloadStatus.failed ? 'quality unavailable' : null,
  errorType: status == DownloadStatus.failed
      ? DownloadErrorType.qualityUnavailable
      : null,
  createdAt: DateTime.utc(2026),
);

class _Settings extends SettingsNotifier {
  _Settings(this.strict);
  final bool strict;
  @override
  AppSettings build() => AppSettings(
    defaultService: 'provider-a',
    strictDownloadQuality: strict,
    saveDownloadHistory: false,
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      Extension.fromJson({
        'id': 'provider-a',
        'name': 'Provider A',
        'enabled': true,
        'has_download_provider': true,
        'quality_options': [
          {'id': 'LOW', 'label': 'Low', 'kind': 'lossy'},
          {'id': 'HI', 'label': '24-Bit', 'kind': 'lossless'},
          {'id': 'CD', 'label': 'Lossless', 'kind': 'lossless'},
        ],
      }),
    ],
  );

  @override
  Future<void> ensureInitialized() async {}
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this.initial, NativeDiscardMemory discards)
    : super(
        isAndroidForTesting: false,
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

  final List<DownloadItem> initial;

  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(items: initial, isPaused: true);
  }
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  Future<_Queue> queueWith(
    List<DownloadItem> items, {
    bool strict = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    for (final name in [
      'com.zarz.mornye/backend',
      'plugins.flutter.io/path_provider',
      'dexterous.com/flutter/local_notifications',
      'dev.fluttercommunity.plus/connectivity',
    ]) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    final queue = _Queue(items, NativeDiscardMemory());
    final container = ProviderContainer(
      overrides: [
        downloadQueueProvider.overrideWith(() => queue),
        settingsProvider.overrideWith(() => _Settings(strict)),
        extensionProvider.overrideWith(_Extensions.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(downloadQueueProvider);
    // Nothing may start downloading: these tests only observe the queue rows.
    queue.pauseQueue(persistAcrossRestarts: false);
    await pumpEventQueue();
    return queue;
  }

  List<String> ids(_Queue queue) => [for (final i in queue.state.items) i.id];

  test('the same track queued twice keeps one entry and returns it', () async {
    final queue = await queueWith([]);
    final first = queue.addToQueue(_track('t1'), 'provider-a');
    final second = queue.addToQueue(_track('t1'), 'provider-a');
    final third = queue.addToQueue(_track('t1'), 'provider-a');
    expect(second, first);
    expect(third, first);
    expect(ids(queue), [first]);
    queue.addIndividualTracksToQueue([_track('t1'), _track('t2')], 'provider-a');
    expect(queue.state.items.length, 2);
    expect(queue.addMultipleToQueue([_track('t1'), _track('t2')], 'provider-a'), isEmpty);
    expect(queue.state.items.length, 2);
  });

  test(
    'a failed track is retried in place and its failed twins are merged',
    () async {
      final queue = await queueWith([
        _item('f1', 't1'),
        _item('f2', 't1'),
        _item('other', 't2'),
        _item('f3', 't1'),
        _item('f4', 't1'),
      ]);
      final id = queue.addToQueue(_track('t1'), 'provider-a');
      await pumpEventQueue();
      // The four identical failures of the report collapse into the newest.
      expect(id, 'f4');
      expect(ids(queue), ['other', 'f4']);
      final retried = queue.state.items.last;
      expect(retried.status, DownloadStatus.queued);
      expect(retried.error, isNull);
      // Tapping again while it is queued still adds nothing.
      expect(queue.addToQueue(_track('t1'), 'provider-a'), 'f4');
      expect(queue.addMultipleToQueue([_track('t1')], 'provider-a'), isEmpty);
      expect(ids(queue), ['other', 'f4']);
    },
  );

  test('batch enqueue retries a failed entry instead of adding a twin', () async {
    final queue = await queueWith([_item('f1', 't1'), _item('f2', 't2')]);
    final added = queue.addMultipleToQueue([
      _track('t1'),
      _track('t2'),
      _track('t3'),
    ], 'provider-a');
    await pumpEventQueue();
    expect(added.length, 1);
    expect(queue.state.items.length, 3);
    expect(ids(queue).take(2), ['f1', 'f2']);
    expect(
      queue.state.items.every((i) => i.status == DownloadStatus.queued),
      isTrue,
    );
  });

  test('a completed entry is returned and never queued again', () async {
    final queue = await queueWith([
      _item('done', 't1', status: DownloadStatus.completed),
    ]);
    expect(queue.addToQueue(_track('t1'), 'provider-a'), 'done');
    expect(queue.addMultipleToQueue([_track('t1')], 'provider-a'), isEmpty);
    await pumpEventQueue();
    expect(ids(queue), ['done']);
    expect(queue.state.items.single.status, DownloadStatus.completed);
  });

  test('restore merges repeated failures without touching live rows', () async {
    final queue = await queueWith([]);
    final merged = queue.withoutFailedDuplicatesForTesting([
      _item('f1', 't1'),
      _item('q', 't1', status: DownloadStatus.queued),
      _item('f2', 't1'),
      _item('g1', 't2'),
      _item('g2', 't2', status: DownloadStatus.skipped),
      _item('done', 't3', status: DownloadStatus.completed),
      _item('late', 't3'),
      _item('a', 't4', status: DownloadStatus.downloading),
      _item('b', 't4', status: DownloadStatus.queued),
      // Deliberate quality variants are different requests.
      _item('v1', 't5', qualityOverride: 'HI', variant: true),
      _item('v2', 't5', qualityOverride: 'CD', variant: true),
      _item('solo', 't6'),
    ]);
    expect(
      [for (final i in merged) i.id],
      // g2 was cancelled by the user: such rows stay and are never a twin.
      ['q', 'g1', 'g2', 'done', 'a', 'b', 'v1', 'v2', 'solo'],
    );
    final clean = [_item('x', 't1'), _item('y', 't2')];
    expect(queue.withoutFailedDuplicatesForTesting(clean), same(clean));
  });

  test('the quality pre-check only blocks in strict mode', () async {
    final queue = await queueWith([]);
    String? resolve(String quality, {required bool strict, bool def = false}) =>
        queue.resolveDeclaredDownloadQualityForTesting(
          'provider-a',
          quality,
          useSourceDefault: def,
          strict: strict,
        );
    // Declared tiers are honoured in both modes.
    expect(resolve('cd', strict: true), 'CD');
    expect(resolve('cd', strict: false), 'CD');
    // An undeclared tier stops only "only this quality".
    expect(resolve('LOSSLESS', strict: true), isNull);
    expect(resolve('LOSSLESS', strict: false), 'LOSSLESS');
    // No choice at all means the provider's best tier, not a failure.
    expect(resolve('', strict: true, def: true), isNull);
    expect(resolve('', strict: false, def: true), 'HI');
  });

  test('relay is requested unless strict mode is on', () {
    const settings = AppSettings();
    expect(settings.strictDownloadQuality, isFalse);
    expect(settings.audioQuality, '');
    final restored = AppSettings.fromJson(
      settings.copyWith(strictDownloadQuality: true).toJson(),
    );
    expect(restored.strictDownloadQuality, isFalse);
    expect(AppSettings.fromJson(const {}).strictDownloadQuality, isFalse);
    // A stored explicit choice of an existing installation is preserved.
    expect(
      AppSettings.fromJson(const {'audioQuality': 'LOSSLESS'}).audioQuality,
      'LOSSLESS',
    );

    const relay = DownloadRequestPayload(
      isrc: '',
      service: 'provider-a',
      downloadProvider: 'provider-a',
      spotifyId: '',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      albumArtist: '',
      coverUrl: '',
      outputDir: '/out',
      filenameFormat: '{title}',
      qualityRelay: true,
    );
    expect(relay.toJson()['quality_relay'], isTrue);
    expect(
      relay.withStrategy(useExtensions: true).toJson()['quality_relay'],
      isTrue,
    );
    const strict = DownloadRequestPayload(
      isrc: '',
      service: 'provider-a',
      downloadProvider: 'provider-a',
      spotifyId: '',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      albumArtist: '',
      coverUrl: '',
      outputDir: '/out',
      filenameFormat: '{title}',
    );
    expect(strict.toJson().containsKey('quality_relay'), isFalse);
    expect(strict.toJson().containsKey('allow_quality_fallback'), isFalse);
  });
}
