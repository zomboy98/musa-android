import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart' hide expect;
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/experimental_progressive_transfer.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/playback_equalizer.dart';

// Diagnostic revision after SIG11; new markers not compiled or executed.
// Pair with ProgressiveFlutterFinalFileInstrumentedTest (AndroidJUnit4).
// Build this Dart target in org.musa.music.catalogintegration with:
// MORNYE_EXPERIMENTAL_PROGRESSIVE=true and MORNYE_EXPERIMENTAL_MEDIA3=true.
// This is a headless Dart entrypoint, driven by paired native JUnit, not a
// stand-alone flutter test suite. It never starts the application UI/main.
// No mock handlers for experimental_progressive or audioplayers are permitted.
enum _HarnessStage {
  dartEntered,
  bindingReady,
  fixtureReceived,
  handlerConstructBegin,
  handlerReady,
  loadRequested,
  media3EarlyVerified,
  pauseVerified,
  retireRequested,
  retireVerified,
  balanceTriggerBegin,
  balanceTriggerAcknowledged,
  postRetirementEqBegin,
  postRetirementEqAcknowledged,
  producerReleaseSent,
  resultEventReceived,
  hashBegin,
  hashEnd,
  storePutBegin,
  storePutEnd,
  storeAcquireBegin,
  storeAcquireEnd,
  setFileSourceBegin,
  setFileSourceEnd,
  finalFileVerified,
  resumeVerified,
  scenarioFailed,
  cleanupBegin,
  cleanupEnd,
  verdictReplyReceived,
  exitAckQueued,
}

// Every payload comes from this closed enum, never request/error/path data.
void _markStage(_HarnessStage value) {
  debugPrint('MUSA_HARNESS_STAGE ${value.name}');
}

const _control = MethodChannel('musa.test/progressive_final_file');

// Matchers without a widget-test binding or a rendering surface.
void expect(Object? actual, Object? expected, {String? reason}) {
  final matcher = wrapMatcher(expected);
  if (!matcher.matches(actual, <Object?, Object?>{})) {
    throw StateError('$reason actual=$actual expected=$matcher');
  }
}

class _SessionStore implements AppStateDatabase {
  @override
  Future<void> savePlaybackSession({
    required Uint8List mediaJson,
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {}
  @override
  Future<void> clearPlaybackSession() async {}
  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OfflineCast implements CastTransport {
  @override
  Stream<Object?> events() => const Stream.empty();
  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (method != 'state') {
      throw StateError('Unexpected Cast operation: $method');
    }
    return <Object?, Object?>{'connected': false};
  }
}

// A spy over the REAL deck. Every source/transport method delegates to super.
class _ObservedDeck extends AudioplayersPlaybackDeck {
  _ObservedDeck(String id) : super(playerId: id, nativeAvailable: false);
  final filePaths = <String>[];
  int resumes = 0;
  @override
  Future<void> resume() async {
    await super.resume();
    resumes++;
  }

  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) async {
    _markStage(_HarnessStage.setFileSourceBegin);
    await super.setFileSource(
      path,
      preferBitPerfect: preferBitPerfect,
      directUsb: directUsb,
      allowDop: allowDop,
      requiresDsd: requiresDsd,
      allowFixedVolume: allowFixedVolume,
      dapExclusive: dapExclusive,
    );
    _markStage(_HarnessStage.setFileSourceEnd);
    filePaths.add(path);
  }
}

// Only the provider/catalog boundary is synthetic. MusicPlayerHandler supplies
// the callback that calls the real native channel and returns its real result.
class _FixtureCatalog extends CatalogPlayback {
  _FixtureCatalog(this.catalogStore, this.root, this.expectedHash)
    : super(storage: catalogStore);
  final CatalogAudioStore catalogStore;
  final Directory root;
  final String expectedHash;
  int transfers = 0, cancellations = 0;
  @override
  Future<void> cancel(Track track) async {
    cancellations++;
  }

  @override
  Future<CatalogAudioLease> acquire(
    Track track, {
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)?
    experimentalTransfer,
    Future<void> Function(String)? cancelExperimentalTransfer,
  }) async {
    if (experimentalTransfer == null) {
      throw StateError('Experimental route was not selected');
    }
    transfers++;
    final result = await experimentalTransfer(
      DownloadRequestPayload(
        trackName: 'Synthetic progressive fixture',
        artistName: 'Fixture',
        albumName: 'Fixture',
        service: 'example.progressive.fixture',
        source: 'example.progressive.fixture',
        providerTrackId: 'fixture',
        outputDir: root.path,
        filenameFormat: 'fixture',
        itemId: 'fixture',
        storageMode: 'app',
        outputExt: '.m4a',
        useFallback: false,
        embedMetadata: false,
        embedLyrics: false,
      ),
    );
    _markStage(_HarnessStage.resultEventReceived);
    if (result['success'] != true) {
      throw StateError('Native fixture did not commit');
    }
    final file = File(result['file_path'] as String);
    expect(file.parent.absolute.path, root.absolute.path);
    _markStage(_HarnessStage.hashBegin);
    expect(sha256.convert(await file.readAsBytes()).toString(), expectedHash);
    _markStage(_HarnessStage.hashEnd);
    final id = key(track);
    _markStage(_HarnessStage.storePutBegin);
    await catalogStore.putTemporary(id, file, extension: '.m4a');
    _markStage(_HarnessStage.storePutEnd);
    _markStage(_HarnessStage.storeAcquireBegin);
    final lease = (await catalogStore.acquire(id))!;
    _markStage(_HarnessStage.storeAcquireEnd);
    return lease;
  }
}

// Attach an error observer immediately. Polling native readiness must not leave
// an early load error unhandled, and timeout() alone cannot cancel the load.
class _ObservedLoad {
  _ObservedLoad(Future<void> future) {
    settled = future.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _failure = error;
        _stack = stack;
      },
    );
  }
  late final Future<void> settled;
  Object? _failure;
  StackTrace? _stack;
  void throwIfFailed() {
    final error = _failure;
    if (error != null) Error.throwWithStackTrace(error, _stack!);
  }

  Future<void> wait(Duration timeout) async {
    await settled.timeout(timeout);
    throwIfFailed();
  }
}

Future<Map<String, dynamic>> _snapshot() async => Map<String, dynamic>.from(
  (await _control.invokeMapMethod<String, Object?>('snapshot'))!,
);

Future<Map<String, dynamic>> _waitNative(
  bool Function(Map<String, dynamic>) ready,
  String description, {
  Duration timeout = const Duration(seconds: 15),
  void Function()? checkFailure,
}) async {
  final end = DateTime.now().add(timeout);
  Map<String, dynamic>? last;
  while (DateTime.now().isBefore(end)) {
    checkFailure?.call();
    last = await _snapshot().timeout(const Duration(seconds: 3));
    checkFailure?.call();
    if (ready(last)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('$description; last native state: $last');
}

Future<void> main() => HttpOverrides.runZoned(
  _runScenario,
  createHttpClient: (_) =>
      throw StateError('HTTP is forbidden by the offline fixture'),
);

Future<void> _runScenario() async {
  _markStage(_HarnessStage.dartEntered);
  WidgetsFlutterBinding.ensureInitialized();
  _markStage(_HarnessStage.bindingReady);
  MusicPlayerHandler? handler;
  MusicPlayerRuntime? runtime;
  CastOutput? cast;
  final oldEqualizer = playbackEqualizer.value;
  Object? failure;
  StackTrace? failureStack;
  Map<String, dynamic>? report;
  _ObservedLoad? pendingLoad;
  final cleanupErrors = <String>[];
  void recordFailure(String stage, Object error, StackTrace stack) {
    if (failure == null) {
      failure = error;
      failureStack = stack;
    } else {
      cleanupErrors.add('$stage: $error');
    }
  }

  Future<void> clean(String stage, Future<void> Function() action) async {
    try {
      await action().timeout(const Duration(seconds: 5));
    } catch (error, stack) {
      recordFailure(stage, error, stack);
    }
  }

  try {
    expect(Platform.isAndroid, isTrue);
    expect(ExperimentalProgressiveTransfer.enabled, isTrue);
    expect(ExperimentalProgressiveTransfer.media3Enabled, isTrue);
    Map<String, dynamic>? fixture;
    final setupDeadline = DateTime.now().add(const Duration(seconds: 15));
    while (fixture == null && DateTime.now().isBefore(setupDeadline)) {
      try {
        fixture = Map<String, dynamic>.from(
          (await _control
              .invokeMapMethod<String, Object?>('fixture')
              .timeout(const Duration(seconds: 3)))!,
        );
      } on MissingPluginException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (fixture == null) {
      throw StateError('Native paired instrumentation harness is absent');
    }
    _markStage(_HarnessStage.fixtureReceived);
    final balanceRetirementEqEnabled =
        fixture['balanceRetirementEqEnabled'] as bool?;
    expect(fixture['package'], 'org.musa.music.catalogintegration');
    final root = Directory(fixture['root'] as String);
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/catalog-cache'),
      libraryDirectory: Directory('${root.path}/catalog-library'),
    );
    await store.initialize();
    final catalog = _FixtureCatalog(store, root, fixture['sha256'] as String);
    _ObservedDeck? primaryDeck;
    playbackEqualizer.value = const EqualizerSettings();
    cast = CastOutput(transport: _OfflineCast());
    runtime = MusicPlayerRuntime(
      settings: const AppSettings(
        autoplayPersonalization: false,
        autoplay: false,
        autoMix: false,
        gaplessPlayback: false,
        musicHaptics: false,
        playbackNormalization: false,
        usbBitPerfect: false,
        usbDirect: false,
      ),
      dependencies: PlaybackDependencies(
        createDeck: (id) {
          final created = _ObservedDeck(id);
          if (id == 'music-player') {
            if (primaryDeck != null) {
              throw StateError('Primary deck created twice');
            }
            primaryDeck = created;
          }
          return created;
        },
        sessionDatabase: _SessionStore(),
        recorder: ListeningRecorder(
          write: (_) async {},
          elapsed: () => Duration.zero,
          now: DateTime.now,
        ),
        volumeChanges: const Stream.empty(),
        synchronizePlaybackState: () async {},
        readMetadata: (path, {displayName}) async => <String, dynamic>{},
      ),
    );
    _markStage(_HarnessStage.handlerConstructBegin);
    handler = MusicPlayerHandler(
      runtime: runtime,
      catalogPlaybackOverride: catalog,
      castOutput: cast,
    );
    _markStage(_HarnessStage.handlerReady);
    const track = Track(
      id: 'fixture',
      source: 'example.progressive.fixture',
      name: 'Synthetic progressive fixture',
      artistName: 'Fixture',
      albumName: 'Fixture',
      duration: 8,
    );
    final deck =
        primaryDeck ?? (throw StateError('Primary deck was not created'));
    final loading = _ObservedLoad(
      handler.setQueueAndPlay([playableFromCatalogTrack(track)]),
    );
    pendingLoad = loading;
    _markStage(_HarnessStage.loadRequested);
    Future<Map<String, dynamic>> waitNative(
      bool Function(Map<String, dynamic>) ready,
      String description,
    ) => _waitNative(ready, description, checkFailure: loading.throwIfFailed);
    final early = await waitNative(
      (s) =>
          s['engine'] == 'Media3ProgressivePlayer' &&
          s['prepared'] == true &&
          s['playing'] == true &&
          (s['positionMs'] as num? ?? 0) >= 600,
      'Media3 never advanced before transfer completion',
    );
    _markStage(_HarnessStage.media3EarlyVerified);
    expect(early['released'], isFalse);
    expect(early['committed'], isFalse);
    expect(early['highWater'] as num, lessThanOrEqualTo(early['split'] as num));
    expect(deck.filePaths, isEmpty);
    await handler.pause();
    final paused = await waitNative(
      (s) => s['playing'] == false,
      'Pause did not reach native player',
    );
    final position = (paused['positionMs'] as num).toInt();
    expect(position, greaterThanOrEqualTo(500));
    final resumes = deck.resumes;
    _markStage(_HarnessStage.pauseVerified);

    // Actual EQ listener -> native retire callback -> real progressive events.
    _markStage(_HarnessStage.retireRequested);
    if (balanceRetirementEqEnabled == null) {
      playbackEqualizer.value = const EqualizerSettings(
        enabled: true,
        balance: 0.25,
      );
    } else {
      expect(paused['equalizerEnabled'], isFalse);
      _markStage(_HarnessStage.balanceTriggerBegin);
      await const MethodChannel('xyz.luan/audioplayers')
          .invokeMethod<void>('setBalance', {
            'playerId': 'music-player',
            'balance': 0.25,
          })
          .timeout(const Duration(seconds: 3));
      _markStage(_HarnessStage.balanceTriggerAcknowledged);
    }
    final retired = await waitNative(
      (s) =>
          s['leaseClosed'] == true &&
          s.containsKey('engine') &&
          s['engine'] == null,
      'EQ did not retire the real Media3 source',
    );
    _markStage(_HarnessStage.retireVerified);
    if (balanceRetirementEqEnabled != null) {
      expect(retired['equalizerEnabled'], isFalse);
      expect((retired['balance'] as num).toDouble(), closeTo(0.25, 0.001));
      final settings = EqualizerSettings(
        enabled: balanceRetirementEqEnabled,
        balance: 0.25,
      );
      _markStage(_HarnessStage.postRetirementEqBegin);
      playbackEqualizer.value = settings;
      // Real channel acknowledgement, after retirement barrier and before releasing
      // producer. Same command/configuration except enabled in both variants.
      await const MethodChannel('xyz.luan/audioplayers')
          .invokeMethod<void>('setEqualizer', {
            'playerId': 'music-player',
            'configuration': settings.toNative(),
          })
          .timeout(const Duration(seconds: 3));
      await waitNative(
        (s) =>
            s['engine'] == null &&
            s['equalizerEnabled'] == balanceRetirementEqEnabled,
        'Post-retirement EQ setting was not acknowledged',
      );
      _markStage(_HarnessStage.postRetirementEqAcknowledged);
    }
    expect(retired['released'], isFalse);
    expect(
      retired['sessionClosed'],
      isFalse,
      reason: 'Retirement must preserve useful producer',
    );
    expect(catalog.cancellations, 0);
    expect(deck.filePaths, isEmpty);
    expect(deck.resumes, resumes);

    expect(
      await _control
          .invokeMethod<bool>('release')
          .timeout(const Duration(seconds: 3)),
      isTrue,
    );
    _markStage(_HarnessStage.producerReleaseSent);
    await loading.wait(const Duration(seconds: 20));
    final finalState = await waitNative(
      (s) =>
          s['engine'] == 'MediaPlayerWrapper' &&
          s['prepared'] == true &&
          s['playing'] == false,
      'Dart did not load final file while preserving pause',
    );
    expect(deck.filePaths, hasLength(1));
    expect(finalState['sourceKind'], 'UrlSource');
    expect(finalState['sourcePath'], deck.filePaths.single);
    expect(finalState['equalizerEnabled'], balanceRetirementEqEnabled ?? true);
    expect(playbackEqualizerError.value, isNull);
    _markStage(_HarnessStage.finalFileVerified);
    final restored = (finalState['positionMs'] as num).toInt();
    expect((restored - position).abs(), lessThanOrEqualTo(250));
    expect(
      deck.resumes,
      resumes,
      reason: 'Final file must not briefly resume a paused request',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final stillPaused = await _snapshot().timeout(const Duration(seconds: 3));
    expect(stillPaused['playing'], isFalse);
    expect(
      ((stillPaused['positionMs'] as num).toInt() - restored).abs(),
      lessThanOrEqualTo(100),
    );
    await handler.play();
    await waitNative(
      (s) =>
          s['engine'] == 'MediaPlayerWrapper' &&
          s['playing'] == true &&
          (s['positionMs'] as num? ?? 0) >= restored + 300,
      'Final file did not resume explicitly',
    );
    await handler.pause();
    _markStage(_HarnessStage.resumeVerified);
    expect(catalog.transfers, 1);
    expect(
      (await _snapshot().timeout(const Duration(seconds: 3)))['starts'],
      1,
    );
    report = <String, dynamic>{
      'early_position_ms': early['positionMs'],
      'paused_ms': position,
      'restored_ms': restored,
      'final_file_loads': deck.filePaths.length,
      'native_transfers': catalog.transfers,
      'provider': 'synthetic_in_memory',
    };
  } catch (error, stack) {
    _markStage(_HarnessStage.scenarioFailed);
    recordFailure('scenario', error, stack);
  } finally {
    _markStage(_HarnessStage.cleanupBegin);
    // Each step is independent. Timeouts record uncertainty, never cancellation.
    await clean('handler.dispose', () async {
      await handler?.dispose();
    });
    await clean('runtime.dispose', () async {
      await runtime?.dispose();
    });
    await clean('cast.dispose', () async {
      cast?.dispose();
    });
    await clean('loading.settle', () async {
      await pendingLoad?.settled;
      pendingLoad?.throwIfFailed();
    });
    try {
      playbackEqualizer.value = oldEqualizer;
    } catch (error, stack) {
      recordFailure('restore.equalizer', error, stack);
    }
    _markStage(_HarnessStage.cleanupEnd);
    // Report only after every cleanup was attempted, keeping the original error.
    var verdictDelivered = false;
    try {
      await _control
          .invokeMethod<void>('finish', <String, dynamic>{
            'success': failure == null,
            'report': ?report,
            if (cleanupErrors.isNotEmpty) 'cleanupErrors': cleanupErrors,
            if (failure != null)
              'error': '$failure $failureStack cleanup=$cleanupErrors',
          })
          .timeout(const Duration(seconds: 3));
      verdictDelivered = true;
      _markStage(_HarnessStage.verdictReplyReceived);
    } catch (error, stack) {
      recordFailure('finish', error, stack);
    }
    if (verdictDelivered) {
      _markStage(_HarnessStage.exitAckQueued);
      // The final message proves finish's reply reached Dart. No resource work
      // remains. Its transport Future is observed without another required reply.
      unawaited(
        _control
            .invokeMethod<void>('acknowledgeFinish')
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}
