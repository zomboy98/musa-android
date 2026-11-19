import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:path/path.dart' as p;

import 'support/music_player_automix_harness.dart';

class ProgressiveTestSession implements AudioSession {
  int activations = 0;
  @override Future<bool> setActive(bool active, {AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions, AndroidAudioFocusGainType? androidAudioFocusGainType, AndroidAudioAttributes? androidAudioAttributes, bool? androidWillPauseWhenDucked, AudioSessionConfiguration fallbackConfiguration = const AudioSessionConfiguration.music()}) async { if (active) activations++; return true; }
  @override Future<void> configure(AudioSessionConfiguration configuration) async {}
  @override Stream<AudioInterruptionEvent> get interruptionEventStream => const Stream.empty();
  @override Stream<void> get becomingNoisyEventStream => const Stream.empty();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ProgressiveTestDeck extends AudioplayersPlaybackDeck {
  ProgressiveTestDeck(String id) : super(playerId: id, nativeAvailable: false, equalizerAvailable: false);
  Completer<bool> prepared = Completer<bool>();
  final started = Completer<void>();
  int resumes = 0, pauses = 0, fileLoads = 0, stops = 0, preparations = 0, cancelPreparations = 0;
  bool failStop = false;
  final seeks = <Duration>[];
  Completer<void>? fileGate;
  Completer<void>? seekGate;
  final seekStarted = Completer<void>();
  final events = <String>[];
  @override Future<void> configureOutput() async {}
  @override Future<void> cancelPreparation() async { cancelPreparations++; await super.cancelPreparation(); }
  @override Future<void> setVolume(double volume) async {}
  @override Future<void> stop() async { stops++; if (failStop) throw StateError('synthetic stop failure'); }
  @override Future<void> resume() async { events.add('resume'); resumes++; if (!started.isCompleted) started.complete(); }
  @override Future<void> pause() async { pauses++; }
  @override Future<void> seek(Duration position) async { seeks.add(position); events.add('seek:${position.inMilliseconds}'); if (seekGate != null) { if (!seekStarted.isCompleted) seekStarted.complete(); await seekGate!.future; } }
  @override Future<ExperimentalDeckPreparation> beginExperimentalPreparation() async {
    preparations++;
    if (prepared.isCompleted) prepared = Completer<bool>();
    final current = prepared;
    return ExperimentalDeckPreparation('progressive-deck', current.future, () async { if (!current.isCompleted) current.complete(false); });
  }
  @override Future<void> setFileSource(String path, {bool preferBitPerfect = false, bool directUsb = false, bool allowDop = false, bool requiresDsd = false, bool allowFixedVolume = false, bool dapExclusive = false}) async { fileLoads++; await fileGate?.future; }
}

class ProgressiveTestCatalog extends CatalogPlayback {
  ProgressiveTestCatalog(this.storage, this.file) : super(storage: storage);
  final CatalogAudioStore storage;
  final File file;
  int transfers = 0;
  int normalTransfers = 0;
  int cancellations = 0;
  @override Future<void> cancel(Track track) async { cancellations++; }
  bool allowNormal = false;
  @override Future<CatalogAudioLease> acquire(Track track, {
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)? experimentalTransfer,
    Future<void> Function(String)? cancelExperimentalTransfer,
    bool initial = false,
  }) async {
    if (experimentalTransfer == null) {
      if (!allowNormal) throw StateError('missing experimental transfer');
      normalTransfers++;
    } else {
      transfers++;
      await experimentalTransfer(DownloadRequestPayload(trackName: 'fixture', artistName: 'artist', albumName: 'album', outputDir: file.parent.path, filenameFormat: 'fixture', itemId: 'fixture'));
    }
    await storage.putTemporary('fixture', file, extension: '.m4a');
    return (await storage.acquire('fixture'))!;
  }
}

void main() {
  setUpMusicPlayerHarness();
  for (final outcome in ['success', 'failure', 'timeout', 'stop', 'stop_false', 'stop_late', 'stop_late_new', 'stop_late_error']) {
  test('next track waits for active progressive close acknowledgement: $outcome', () async {
    const a = Track(id: 'a', source: 'spotify', name: 'A', artistName: 'Artist', albumName: 'Album', duration: 2);
    const b = Track(id: 'b', source: 'spotify', name: 'B', artistName: 'Artist', albumName: 'Album', duration: 2);
    const c = Track(id: 'c', source: 'spotify', name: 'C', artistName: 'Artist', albumName: 'Album', duration: 2);
    final root = await Directory.systemTemp.createTemp('musa-progressive-close-barrier-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library'))); await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file); final deck = ProgressiveTestDeck('music-player');
    final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger; const channel = MethodChannel('com.zarz.mornye/experimental_progressive');
    final started = <String>[]; final cancelEntered = Completer<void>(); final ack = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') { started.add((call.arguments as Map)['attemptId'] as String); return true; }
      if (call.method == 'cancel') { if (!cancelEntered.isCompleted) cancelEntered.complete(); return ack.future; }
      return null;
    });
    addTearDown(() { if (!ack.isCompleted) ack.complete(false); messenger.setMockMethodCallHandler(channel, null); });
    await handler.dispose(); handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    final loadingA = handler.setQueueAndPlay([playableFromCatalogTrack(a)]);
    while (started.isEmpty) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    Future<void> emit(String kind, [String? result]) => messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': started.first, 'kind': kind, if (result != null) 'resultJson': result})), (_) {});
    await emit('attached'); deck.prepared.complete(true); await deck.started.future.timeout(const Duration(seconds: 5));
    await emit('result', jsonEncode({'success': true, 'file_path': file.path})); await loadingA.timeout(const Duration(seconds: 5));
    final stopsBefore = deck.stops, preparationsBefore = deck.preparations;
    final loadingB = handler.setQueueAndPlay([playableFromCatalogTrack(b)]);
    await cancelEntered.future.timeout(const Duration(seconds: 5)); await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(deck.stops, stopsBefore); expect(deck.preparations, preparationsBefore); expect(started.length, 1);
    Future<void>? loadingC;
    Future<void>? stopping;
    if (outcome == 'success') {
      loadingC = handler.setQueueAndPlay([playableFromCatalogTrack(c)]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(deck.stops, stopsBefore); expect(started.length, 1);
    } else if (outcome.startsWith('stop')) {
      if (outcome.startsWith('stop_late')) {
        handler.playbackState.add(handler.playbackState.value.copyWith(playing: true));
      }
      stopping = handler.stop();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(deck.stops, stopsBefore); expect(started.length, 1);
    }
    if (outcome.startsWith('stop_late')) {
      final playingBeforeTimeout = handler.playbackState.value.playing;
      await stopping!.timeout(const Duration(seconds: 5));
      expect(deck.stops, stopsBefore);
      expect(handler.playbackState.value.errorMessage, contains('audio may still be playing'));
      expect(handler.playbackState.value.playing, playingBeforeTimeout);
      if (outcome == 'stop_late_new') {
        loadingC = handler.setQueueAndPlay([playableFromCatalogTrack(c)]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(deck.stops, stopsBefore);
      }
      if (outcome == 'stop_late_error') deck.failStop = true;
      ack.complete(true);
      if (outcome == 'stop_late_error') {
        final limit = DateTime.now().add(const Duration(seconds: 2));
        while (deck.stops == stopsBefore && DateTime.now().isBefore(limit)) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(handler.playbackState.value.errorMessage, contains('synthetic stop failure'));
        deck.failStop = false; await loadingB.timeout(const Duration(seconds: 5)); await handler.dispose(); return;
      }
      if (outcome == 'stop_late') {
        final limit = DateTime.now().add(const Duration(seconds: 2));
        while (deck.stops == stopsBefore && DateTime.now().isBefore(limit)) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
        expect(deck.stops, greaterThan(stopsBefore)); expect(started.length, 1);
        await loadingB.timeout(const Duration(seconds: 5)); await handler.dispose(); return;
      }
      stopping = null;
    }
    if (outcome != 'timeout' && !ack.isCompleted) ack.complete(outcome == 'success' || outcome == 'stop');
    if (stopping != null) {
      await stopping.timeout(const Duration(seconds: 5)); await loadingB.timeout(const Duration(seconds: 5));
      if (outcome == 'stop_false') {
        expect(deck.stops, stopsBefore); expect(started.length, 1);
        expect(handler.playbackState.value.errorMessage, contains('audio may still be playing'));
        await handler.dispose(); return;
      }
      expect(deck.stops, greaterThan(stopsBefore)); expect(started.length, 1);
      await handler.dispose(); return;
    }
    Future<void>? retry;
    if (outcome != 'success' && outcome != 'stop_late_new') {
      await loadingB.timeout(const Duration(seconds: 5));
      expect(deck.stops, stopsBefore); expect(deck.preparations, preparationsBefore); expect(started.length, 1);
      expect(handler.playbackState.value.playing, isFalse);
      if (!ack.isCompleted) ack.complete(true);
      retry = handler.setQueueAndPlay([playableFromCatalogTrack(b)]);
      if (outcome == 'failure') {
        await retry.timeout(const Duration(seconds: 5));
        expect(deck.stops, stopsBefore); expect(deck.preparations, preparationsBefore); expect(started.length, 1);
        await handler.dispose();
        return;
      }
    }
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (started.length < 2 && DateTime.now().isBefore(deadline)) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    expect(deck.stops, greaterThan(stopsBefore));
    expect(started.length, 2);
    await messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': started.last, 'kind': 'attached'})), (_) {});
    deck.prepared.complete(true);
    await messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': started.last, 'kind': 'result', 'resultJson': jsonEncode({'success': true, 'file_path': file.path})})), (_) {});
    await (retry ?? loadingC ?? loadingB).timeout(const Duration(seconds: 5));
    await loadingB.timeout(const Duration(seconds: 5)); await handler.dispose();
  });
  }
  test('experimental source pauses and resumes without restarting on final result', () async {
    const track = Track(id: 'fixture', source: 'spotify', name: 'Fixture', artistName: 'Artist', albumName: 'Album', duration: 2);
    final root = await Directory.systemTemp.createTemp('musa-progressive-service-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library')));
    await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file);
    final deck = ProgressiveTestDeck('music-player');
    final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
    var hookCalls = 0;
    runtime.exclusiveAudioHook = () async { hookCalls++; };
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.zarz.mornye/experimental_progressive');
    final nativeStarted = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') { nativeStarted.complete((call.arguments as Map)['attemptId'] as String); return true; }
      if (call.method == 'cancel') return true;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await handler.dispose();
    handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    final loading = handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    final id = await nativeStarted.future.timeout(const Duration(seconds: 5));
    Future<void> emit(String kind, [String? result]) => messenger.handlePlatformMessage(channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': id, 'kind': kind, if (result != null) 'resultJson': result})), (_) {});
    await emit('attached');
    deck.prepared.complete(true);
    await deck.started.future.timeout(const Duration(seconds: 5));
    expect(hookCalls, 1);
    await handler.pause();
    await handler.play();
    await emit('result', jsonEncode({'success': true, 'file_path': file.path}));
    await loading.timeout(const Duration(seconds: 5));
    expect(catalog.transfers, 1);
    expect(deck.pauses, greaterThanOrEqualTo(1));
    expect(deck.resumes, 2);
    expect(deck.fileLoads, 0);
    await handler.dispose();
  });

  test('late start A is cancelled and cannot replace the active B attempt', () async {
    const a = Track(id: 'a', source: 'spotify', name: 'A', artistName: 'Artist', albumName: 'Album', duration: 2);
    const b = Track(id: 'b', source: 'spotify', name: 'B', artistName: 'Artist', albumName: 'Album', duration: 2);
    final root = await Directory.systemTemp.createTemp('musa-progressive-ab-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library')));
    await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file); final deck = ProgressiveTestDeck('music-player');
    final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.zarz.mornye/experimental_progressive');
    final firstStarted = Completer<void>(); final secondStarted = Completer<void>(); final firstReply = Completer<bool>();
    final ids = <String>[]; final cancelled = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        ids.add((call.arguments as Map)['attemptId'] as String);
        if (ids.length == 1) { firstStarted.complete(); return firstReply.future; }
        secondStarted.complete(); return true;
      }
      if (call.method == 'cancel') { cancelled.add((call.arguments as Map)['attemptId'] as String); return true; }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await handler.dispose();
    handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    final loadingA = handler.setQueueAndPlay([playableFromCatalogTrack(a)]);
    await firstStarted.future.timeout(const Duration(seconds: 5));
    final cancelsBefore = deck.cancelPreparations;
    final loadingB = handler.setQueueAndPlay([playableFromCatalogTrack(b)]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(secondStarted.isCompleted, isFalse, reason: 'B must wait for A pending start and close');
    expect(deck.cancelPreparations, cancelsBefore, reason: 'B must not mutate the deck while A start is unresolved');
    firstReply.complete(true);
    await secondStarted.future.timeout(const Duration(seconds: 5));
    expect(cancelled, contains(ids.first));
    expect(cancelled, isNot(contains(ids.last)));
    Future<void> emit(String kind, [String? result]) => messenger.handlePlatformMessage(channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': ids.last, 'kind': kind, if (result != null) 'resultJson': result})), (_) {});
    await emit('attached'); deck.prepared.complete(true);
    await deck.started.future.timeout(const Duration(seconds: 5));
    await emit('result', jsonEncode({'success': true, 'file_path': file.path}));
    await Future.wait([loadingA, loadingB]).timeout(const Duration(seconds: 5));
    expect(cancelled, isNot(contains(ids.last)));
    await handler.dispose();
  });

  test('invalidated source restores captured position and stays paused', () async {
    const track = Track(id: 'fixture', source: 'spotify', name: 'Fixture', artistName: 'Artist', albumName: 'Album', duration: 20);
    final root = await Directory.systemTemp.createTemp('musa-progressive-invalidate-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library')));
    await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file); final deck = ProgressiveTestDeck('music-player');
    final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.zarz.mornye/experimental_progressive');
    final nativeStarted = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') { nativeStarted.complete((call.arguments as Map)['attemptId'] as String); return true; }
      if (call.method == 'cancel') return true;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await handler.dispose();
    handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    final loading = handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    final id = await nativeStarted.future.timeout(const Duration(seconds: 5));
    Future<void> emit(Map<String, Object> args) => messenger.handlePlatformMessage(channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': id, ...args})), (_) {});
    await emit({'kind': 'attached'}); deck.prepared.complete(true);
    await deck.started.future.timeout(const Duration(seconds: 5));
    await handler.pause();
    await emit({'kind': 'invalidated', 'positionMs': 1234});
    await emit({'kind': 'result', 'resultJson': jsonEncode({'success': true, 'file_path': file.path})});
    await loading.timeout(const Duration(seconds: 5));
    expect(deck.fileLoads, 1);
    expect(deck.seeks, contains(const Duration(milliseconds: 1234)));
    expect(deck.resumes, 1);
    await handler.dispose();
  });

  test('prepared arriving after retiring never starts the retired deck', () async {
    const track = Track(id: 'fixture', source: 'spotify', name: 'Fixture', artistName: 'Artist', albumName: 'Album', duration: 2);
    final root = await Directory.systemTemp.createTemp('musa-progressive-early-retire-'); addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library'))); await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file); final deck = ProgressiveTestDeck('music-player');
    final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger; const channel = MethodChannel('com.zarz.mornye/experimental_progressive'); final nativeStarted = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async { if (call.method == 'start') { nativeStarted.complete((call.arguments as Map)['attemptId'] as String); return true; } if (call.method == 'cancel') return true; return null; });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null)); await handler.dispose();
    handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    final loading = handler.setQueueAndPlay([playableFromCatalogTrack(track)]); final id = await nativeStarted.future.timeout(const Duration(seconds: 5));
    Future<void> emit(Map<String, Object> args) => messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': id, ...args})), (_) {});
    await emit({'kind': 'attached'}); await emit({'kind': 'retiring'}); deck.prepared.complete(true); await Future<void>.delayed(Duration.zero);
    expect(deck.resumes, 0); await emit({'kind': 'retired', 'positionMs': 0});
    await emit({'kind': 'result', 'resultJson': jsonEncode({'success': true, 'file_path': file.path})}); await loading.timeout(const Duration(seconds: 5));
    expect(deck.fileLoads, 1); expect(deck.resumes, 1); expect(catalog.transfers, 1); await handler.dispose();
  });

  for (final (retireBeforeCommit, resumeBeforeCommit, seekDuringRetirement) in [(true, false, false), (true, true, false), (false, false, false), (true, false, true), (false, false, true)]) {
    test('retirement intent before commit: $retireBeforeCommit resume: $resumeBeforeCommit seek: $seekDuringRetirement', () async {
      const track = Track(id: 'fixture', source: 'spotify', name: 'Fixture', artistName: 'Artist', albumName: 'Album', duration: 2);
      final root = await Directory.systemTemp.createTemp('musa-progressive-retire-');
      addTearDown(() => root.delete(recursive: true));
      final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
      final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library')));
      await store.initialize();
      final catalog = ProgressiveTestCatalog(store, file); final deck = ProgressiveTestDeck('music-player');
      final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.zarz.mornye/experimental_progressive');
      final nativeStarted = Completer<String>(); var cancels = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') { nativeStarted.complete((call.arguments as Map)['attemptId'] as String); return true; }
        if (call.method == 'cancel') { cancels++; return true; }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await handler.dispose();
      handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
      final loading = handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
      final id = await nativeStarted.future.timeout(const Duration(seconds: 5));
      Future<void> emit(Map<String, Object> args) => messenger.handlePlatformMessage(channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': id, ...args})), (_) {});
      await emit({'kind': 'attached'}); deck.prepared.complete(true);
      await deck.started.future.timeout(const Duration(seconds: 5));
      Future<void>? pendingSeek;
      if (retireBeforeCommit) await emit({'kind': 'retiring'});
      if (retireBeforeCommit && seekDuringRetirement) pendingSeek = handler.seek(const Duration(milliseconds: 1800));
      await handler.pause();
      if (retireBeforeCommit) expect(catalog.cancellations, 0);
      if (resumeBeforeCommit) { await handler.play(); expect(catalog.cancellations, 0); }
      if (retireBeforeCommit) await emit({'kind': 'retired', 'positionMs': 1234});
      await emit({'kind': 'result', 'resultJson': jsonEncode({'success': true, 'file_path': file.path})});
      await loading.timeout(const Duration(seconds: 5));
      if (!retireBeforeCommit) await emit({'kind': 'retired', 'positionMs': 1234});
      if (!retireBeforeCommit && seekDuringRetirement) pendingSeek = handler.seek(const Duration(milliseconds: 1800));
      if (pendingSeek != null) await pendingSeek.timeout(const Duration(seconds: 5));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (deck.fileLoads == 0 && DateTime.now().isBefore(deadline)) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
      expect(deck.fileLoads, 1); expect(deck.seeks, contains(Duration(milliseconds: seekDuringRetirement ? 1800 : 1234)));
      expect(deck.resumes, resumeBeforeCommit ? 2 : 1); expect(catalog.transfers, 1); expect(cancels, 1);
      await handler.dispose();
    });
  }

  for (final resumeDuringLoad in [false, true]) {
  test('latest pause intent during retired source load: $resumeDuringLoad', () async {
    const track = Track(id: 'fixture', source: 'spotify', name: 'Fixture', artistName: 'Artist', albumName: 'Album', duration: 2);
    final root = await Directory.systemTemp.createTemp('musa-progressive-retire-pause-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library'))); await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file); final deck = ProgressiveTestDeck('music-player')..fileGate = Completer<void>();
    final session = ProgressiveTestSession();
    final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => session, synchronizePlaybackState: () async {}));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger; const channel = MethodChannel('com.zarz.mornye/experimental_progressive'); final nativeStarted = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async { if (call.method == 'start') { nativeStarted.complete((call.arguments as Map)['attemptId'] as String); return true; } if (call.method == 'cancel') return true; return null; });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null)); await handler.dispose();
    handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    final loading = handler.setQueueAndPlay([playableFromCatalogTrack(track)]); final id = await nativeStarted.future.timeout(const Duration(seconds: 5));
    Future<void> emit(Map<String, Object> args) => messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': id, ...args})), (_) {});
    await emit({'kind': 'attached'}); deck.prepared.complete(true); await deck.started.future.timeout(const Duration(seconds: 5));
    await emit({'kind': 'result', 'resultJson': jsonEncode({'success': true, 'file_path': file.path})}); await loading.timeout(const Duration(seconds: 5));
    if (resumeDuringLoad) await handler.pause();
    await emit({'kind': 'retired', 'positionMs': 1234}); final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (deck.fileLoads == 0 && DateTime.now().isBefore(deadline)) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    expect(deck.fileLoads, 1);
    if (resumeDuringLoad) { await handler.play(); } else { await handler.pause(); }
    deck.fileGate!.complete(); await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(deck.resumes, resumeDuringLoad ? 2 : 1); if (resumeDuringLoad) expect(session.activations, greaterThanOrEqualTo(2));
    expect(deck.seeks, contains(const Duration(milliseconds: 1234))); await handler.dispose();
  });
  }

  test('new seek while retirement seek is blocked wins before resume', () async {
    const track = Track(id: 'fixture', source: 'spotify', name: 'Fixture', artistName: 'Artist', albumName: 'Album', duration: 2);
    final root = await Directory.systemTemp.createTemp('musa-progressive-retire-seek-'); addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library'))); await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file); final deck = ProgressiveTestDeck('music-player')..seekGate = Completer<void>();
    final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger; const channel = MethodChannel('com.zarz.mornye/experimental_progressive'); final nativeStarted = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async { if (call.method == 'start') { nativeStarted.complete((call.arguments as Map)['attemptId'] as String); return true; } if (call.method == 'cancel') return true; return null; });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null)); await handler.dispose();
    handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    final loading = handler.setQueueAndPlay([playableFromCatalogTrack(track)]); final id = await nativeStarted.future.timeout(const Duration(seconds: 5));
    Future<void> emit(Map<String, Object> args) => messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': id, ...args})), (_) {});
    await emit({'kind': 'attached'}); deck.prepared.complete(true); await deck.started.future.timeout(const Duration(seconds: 5));
    await emit({'kind': 'result', 'resultJson': jsonEncode({'success': true, 'file_path': file.path})}); await loading.timeout(const Duration(seconds: 5));
    await emit({'kind': 'retiring'}); await emit({'kind': 'retired', 'positionMs': 700}); await deck.seekStarted.future.timeout(const Duration(seconds: 3));
    final newerSeek = handler.seek(const Duration(milliseconds: 1800)); await Future<void>.delayed(Duration.zero); deck.seekGate!.complete(); await newerSeek.timeout(const Duration(seconds: 5));
    final deadline = DateTime.now().add(const Duration(seconds: 3)); while (deck.resumes < 2 && DateTime.now().isBefore(deadline)) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    final secondResume = deck.events.lastIndexOf('resume'); expect(secondResume, greaterThan(0)); expect(deck.events.sublist(0, secondResume).last, 'seek:1800'); expect(catalog.transfers, 1); await handler.dispose();
  });

  test('normalization uses complete download and preserves exclusive hook', () async {
    const track = Track(id: 'fixture', source: 'spotify', name: 'Fixture', artistName: 'Artist', albumName: 'Album', duration: 2);
    final root = await Directory.systemTemp.createTemp('musa-progressive-normalization-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library')));
    await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file)..allowNormal = true;
    final deck = ProgressiveTestDeck('music-player');
    final runtime = MusicPlayerRuntime(settings: const AppSettings(playbackNormalization: true), dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
    var hooks = 0;
    runtime.exclusiveAudioHook = () async { hooks++; };
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.zarz.mornye/experimental_progressive');
    var starts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async { if (call.method == 'start') starts++; return null; });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await handler.dispose();
    handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    await handler.setQueueAndPlay([playableFromCatalogTrack(track)]).timeout(const Duration(seconds: 5));
    expect(starts, 0); expect(catalog.normalTransfers, 1); expect(deck.fileLoads, 1); expect(hooks, 1);
    await handler.dispose();
  });

  for (final positionAvailable in [true, false]) {
  test('paused fallback waits for cancellation; position available: $positionAvailable', () async {
    const track = Track(id: 'fixture', source: 'spotify', name: 'Fixture', artistName: 'Artist', albumName: 'Album', duration: 20);
    final root = await Directory.systemTemp.createTemp('musa-progressive-fallback-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'fixture.m4a')).writeAsString('fixture');
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: Directory(p.join(root.path, 'library')));
    await store.initialize();
    final catalog = ProgressiveTestCatalog(store, file); final deck = ProgressiveTestDeck('music-player');
    final runtime = MusicPlayerRuntime(dependencies: PlaybackDependencies(isAndroid: true, createDeck: (_) => deck, audioSession: () async => ProgressiveTestSession(), synchronizePlaybackState: () async {}));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.zarz.mornye/experimental_progressive');
    const backend = MethodChannel('com.zarz.mornye/backend');
    final nativeStarted = Completer<String>(); final cancelled = Completer<bool>(); final cancelCalled = Completer<void>();
    var fullDownloads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') { nativeStarted.complete((call.arguments as Map)['attemptId'] as String); return true; }
      if (call.method == 'cancel') { if (!cancelCalled.isCompleted) cancelCalled.complete(); return cancelled.future; }
      return null;
    });
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'downloadByStrategy') { fullDownloads++; return {'success': true, 'file_path': file.path}; }
      return null;
    });
    addTearDown(() { messenger.setMockMethodCallHandler(channel, null); messenger.setMockMethodCallHandler(backend, null); });
    await handler.dispose();
    handler = MusicPlayerHandler(runtime: runtime, catalogPlaybackOverride: catalog, probeCatalogAudio: (_) async => const PrimaryAudioProperties(codec: 'aac'));
    final loading = handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    final id = await nativeStarted.future.timeout(const Duration(seconds: 5));
    Future<void> emit(Map<String, Object> args) => messenger.handlePlatformMessage(channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'attemptId': id, ...args})), (_) {});
    await emit({'kind': 'attached'}); deck.prepared.complete(true);
    await deck.started.future.timeout(const Duration(seconds: 5));
    await handler.pause();
    await emit({'kind': 'fallback', if (positionAvailable) 'positionMs': 1234});
    await cancelCalled.future.timeout(const Duration(seconds: 5));
    expect(fullDownloads, 0);
    cancelled.complete(true);
    await loading.timeout(const Duration(seconds: 5));
    expect(fullDownloads, positionAvailable ? 1 : 0); expect(deck.fileLoads, positionAvailable ? 1 : 0);
    if (positionAvailable) expect(deck.seeks, contains(const Duration(milliseconds: 1234)));
    expect(deck.resumes, 1);
    await handler.dispose();
  });
  }
}
