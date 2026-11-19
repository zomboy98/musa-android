import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/background_favorites.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_remote_playback.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/media_library_browser.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/quality_switch_result.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/network_playback_cache.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/exclusive_output_deck.dart';
import 'package:mornye/services/playback_notification.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

import 'support/link_fakes.dart';
import 'support/virtual_time.dart';

class _HandoffQueueSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(allowQualityVariants: true);
}

class _HandoffQueueExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(extensions: []);
}

class _HandoffQueue extends DownloadQueueNotifier {
  _HandoffQueue() : super(queuePersistenceForTesting: _handoffPersistence);
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      isPaused: true,
      isProcessing: true,
    );
  }
}

DownloadQueuePersistence _handoffPersistence(
  List<DownloadItem> Function() currentItems,
  void Function(Object) onError,
) {
  final events = <Map<String, dynamic>>[];
  return DownloadQueuePersistence(
    currentItems: currentItems,
    onError: onError,
    loadRows: () async => [],
    loadSelectionEvents: () async =>
        events.map(Map<String, dynamic>.of).toList(),
    applyChanges: ({required upserts, required deletedIds}) async {},
    applySelectionChanges:
        ({
          required upserts,
          required deletedIds,
          required selectionEvents,
        }) async {
          events.addAll(selectionEvents.map(Map<String, dynamic>.of));
        },
  );
}

/// A NAS download of a three-byte song, held until [release] completes.
class _NasTransfer implements NetworkPlaybackTransfer {
  _NasTransfer(this.release);

  final Future<void>? release;

  @override
  Future<String?> identity(String source) async => 'v1';

  @override
  Future<void> download(
    String source,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    await release;
    await output.writeAsBytes([1, 2, 3]);
    progress(3, 3);
  }

  @override
  void close() {}
}

class _SeekLogDeck extends _Deck {
  final events = <String>[];
  @override
  Future<Duration?> getCurrentPosition() async =>
      position + const Duration(milliseconds: 200);

  @override
  Future<void> setVolume(double volume) async {
    events.add('volume');
    await super.setVolume(volume);
  }

  @override
  Future<void> seek(Duration value) async {
    events.add('seek');
    await super.seek(value);
  }
}

class _Deck implements PlaybackDeck {
  @override
  PlaybackDeckState state = PlaybackDeckState.stopped;
  final volumes = <double>[];
  Map<String, bool>? outputOptions;
  final sources = <String>[];
  Duration position = Duration.zero;
  int disposals = 0;
  bool failStop = false;
  Future<void> Function()? beforeDispose;

  @override
  bool get isDirect => false;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => const Stream.empty();
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<void> get onPlayerComplete => const Stream.empty();
  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {}
  @override
  Future<void> configureOutput() async {}
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setPlaybackRate(double rate) async {}
  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> stop() async {
    if (failStop) throw StateError('Transport failed');
    state = PlaybackDeckState.stopped;
  }

  @override
  Future<void> pause() async => state = PlaybackDeckState.paused;
  @override
  Future<void> resume() async => state = PlaybackDeckState.playing;
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 60);
  @override
  Future<Duration?> getCurrentPosition() async => position;
  @override
  Future<void> dispose() async {
    await beforeDispose?.call();
    disposals++;
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
    sources.add(path);
    outputOptions = {
      'bitPerfect': preferBitPerfect,
      'direct': directUsb,
      'dop': allowDop,
      'fixedVolume': allowFixedVolume,
      'exclusive': dapExclusive,
    };
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async =>
      sources.add('${arriving ? 'arriving' : 'stream'} $url');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DroppingDeck extends _Deck {
  _DroppingDeck(this.outgoing);

  final _Deck outgoing;

  @override
  Future<Duration?> getCurrentPosition() async {
    if (outgoing.state == PlaybackDeckState.paused) {
      state = PlaybackDeckState.stopped;
    }
    return position;
  }
}

class _PausingDeck extends _Deck {
  int setVolumeCalls = 0;
  int pauseAfterVolumeCalls = 3;

  @override
  Future<void> setVolume(double volume) async {
    await super.setVolume(volume);
    if (++setVolumeCalls == pauseAfterVolumeCalls &&
        state == PlaybackDeckState.playing) {
      state = PlaybackDeckState.paused;
    }
  }
}

class _CastDeck extends _Deck {
  final states = StreamController<PlaybackDeckState>.broadcast(sync: true);
  final completions = StreamController<void>.broadcast(sync: true);

  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => states.stream;
  @override
  Stream<void> get onPlayerComplete => completions.stream;

  void remotePlay() {
    state = PlaybackDeckState.playing;
    states.add(state);
  }

  void complete() {
    state = PlaybackDeckState.completed;
    states.add(state);
    completions.add(null);
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await completions.close();
    await super.dispose();
  }
}

class _QueuedDeck extends _TickingDeck implements QueuedPlaybackDeck {
  final completions = StreamController<void>.broadcast();
  void Function()? onStart;
  String? nextSource;
  double? nextVolume;
  bool failQueue = false;
  int queued = 0;

  @override
  bool get canQueueNextSource => true;
  @override
  Stream<void> get onPlayerComplete => completions.stream;
  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    queued++;
    if (failQueue) throw StateError('Native playlist unavailable');
    nextSource = source;
    nextVolume = volume;
    onStart = onStarted;
    return true;
  }

  @override
  Future<void> clearNextSource() async {
    nextSource = null;
    nextVolume = null;
    onStart = null;
  }

  void advance() {
    nextSource = null;
    volumes.add(nextVolume!);
    position = Duration.zero;
    onStart?.call();
  }

  @override
  Future<void> dispose() async {
    await completions.close();
    await super.dispose();
  }
}

class _OutputChangeDeck extends _CastDeck {
  final stopStarted = Completer<void>();
  final stopBarrier = Completer<void>();
  bool blockStop = false;
  int resumes = 0;
  Future<void>? cancellation;
  Future<void>? resuming;
  final resumeStarted = Completer<void>();
  CastOutput? castOutput;

  @override
  bool get needsSourceReload => castOutput?.connected == false;

  @override
  Future<void> cancelPreparation() async => await cancellation;

  @override
  Future<void> stop() async {
    if (blockStop && !stopStarted.isCompleted) {
      stopStarted.complete();
      await stopBarrier.future;
    }
    await super.stop();
  }

  @override
  Future<void> resume() async {
    if (resuming != null && !resumeStarted.isCompleted) {
      resumeStarted.complete();
      await resuming;
    }
    resumes++;
    await super.resume();
  }
}

class _ResumeGateDeck extends _Deck {
  _ResumeGateDeck(this.gate);

  final Future<void> gate;

  @override
  Future<void> resume() async {
    await gate;
    await super.resume();
  }
}

class _DelayedSeekDeck extends _Deck {
  final seekStarted = Completer<void>();
  final seekBarrier = Completer<void>();
  final seekSources = <String>[];
  bool failSeek = false;

  @override
  Future<void> seek(Duration value) async {
    seekStarted.complete();
    await seekBarrier.future;
    seekSources.add(sources.last);
    if (failSeek) throw StateError('Seek failed');
    await super.seek(value);
  }
}

/// Delivers positions only when a test sends them, and keeps the tick filter
/// the handler passes.
class _TickingDeck extends _Deck {
  final positionEvents = StreamController<Duration>.broadcast();
  Duration? interval;
  bool Function()? wanted;

  @override
  Stream<Duration> get onPositionChanged => positionEvents.stream;

  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {
    this.interval = interval;
    this.wanted = wanted;
  }

  @override
  Future<void> dispose() async {
    await positionEvents.close();
    await super.dispose();
  }
}

class _ReloadDeck extends _TickingDeck {
  bool reload = false;
  @override
  bool get needsSourceReload => reload;
}

class _SlowStartDeck extends _Deck {
  _SlowStartDeck({this.startDelay = Duration.zero});

  final Duration startDelay;
  final seeks = <Duration>[];

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    await super.seek(value);
  }

  @override
  Future<void> resume() async {
    await Future<void>.delayed(startDelay);
    await super.resume();
  }
}

class _ClockDeck extends _Deck {
  _ClockDeck({
    this.name = 'deck',
    this.startDelay = Duration.zero,
    this.seekDelay = Duration.zero,
    this.landing,
    List<(String, double)>? log,
  }) : log = log ?? [];

  final String name;
  final Duration startDelay;
  final Duration seekDelay;
  final Duration Function(Duration target)? landing;
  final List<(String, double)> log;
  final Stopwatch clock = Stopwatch()..start();
  final seeks = <Duration>[];
  final timedVolumes = <(Duration, double)>[];
  Duration? runsFrom;

  bool get _running =>
      state == PlaybackDeckState.playing &&
      runsFrom != null &&
      clock.elapsed >= runsFrom!;

  @override
  Future<Duration?> getCurrentPosition() async =>
      _running ? position + (clock.elapsed - runsFrom!) : position;

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    position = landing?.call(value) ?? value;
    if (state == PlaybackDeckState.playing) {
      runsFrom = clock.elapsed + seekDelay;
    }
  }

  @override
  Future<void> resume() async {
    final wasPlaying = state == PlaybackDeckState.playing;
    state = PlaybackDeckState.playing;
    if (!wasPlaying) runsFrom = clock.elapsed + startDelay;
  }

  @override
  Future<void> pause() async {
    position = await getCurrentPosition() ?? position;
    runsFrom = null;
    state = PlaybackDeckState.paused;
  }

  @override
  Future<void> setVolume(double volume) async {
    timedVolumes.add((clock.elapsed, volume));
    log.add((name, volume));
    await super.setVolume(volume);
  }
}

class _StaleClockDeck extends _ClockDeck {
  _StaleClockDeck({super.startDelay, this.freezeAtSeek});

  final int? freezeAtSeek;
  Duration? frozen;

  @override
  Future<Duration?> getCurrentPosition() async {
    if (frozen != null) return frozen;
    final value = await super.getCurrentPosition();
    if (freezeAtSeek != null && seeks.length >= freezeAtSeek!) frozen = value;
    return value;
  }
}

class _StubbornDeck extends _ClockDeck {
  _StubbornDeck({
    super.name,
    super.log,
    super.startDelay,
    this.honored = 2,
    this.offset = Duration.zero,
  });

  final int honored;
  final Duration offset;

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    if (seeks.length > honored) return;
    position = seeks.length == honored ? value + offset : value;
    if (state == PlaybackDeckState.playing) runsFrom = clock.elapsed;
  }
}

class _HandoffDeck extends _TickingDeck {
  final preparing = Completer<void>();
  final prepared = Completer<void>();
  final disposed = Completer<void>();
  final resumedPositions = <Duration>[];
  Future<void>? cancellationGate;
  bool stopAfterCancellation = false;
  int cancellations = 0;

  @override
  Future<void> cancelPreparation() async {
    cancellations++;
    final gate = cancellationGate;
    cancellationGate = null;
    await gate;
    if (gate != null && stopAfterCancellation) await stop();
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
    await super.setFileSource(path);
    if (!preparing.isCompleted) {
      preparing.complete();
      await prepared.future;
    }
  }

  @override
  Future<void> resume() async {
    resumedPositions.add(position);
    await super.resume();
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    disposed.complete();
  }
}

class _PermanentFailureDeck extends _Deck {
  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) async => throw StateError('Cannot open permanent file');
}

class _BlockingDisposeDeck extends _Deck {
  final disposing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> dispose() async {
    disposing.complete();
    await release.future;
    await super.dispose();
  }
}

class _CompletesOnResumeDeck extends _CastDeck {
  @override
  Future<void> resume() async {
    await super.resume();
    complete();
  }
}

class _CompletesOnSeekDeck extends _CastDeck {
  @override
  Future<void> seek(Duration value) async {
    await super.seek(value);
    complete();
  }
}

class _AbortOnResumeDeck extends _Deck {
  _AbortOnResumeDeck(this.events);
  final List<String> events;
  final resumeStarted = Completer<void>();
  final resumeReleased = Completer<void>();
  @override
  Future<void> resume() async {
    await super.resume();
    events.add('incoming resume');
    resumeStarted.complete();
    await resumeReleased.future;
  }

  @override
  Future<void> stop() async {
    events.add('incoming stop');
    await super.stop();
  }
}

class _ResumeLogDeck extends _Deck {
  _ResumeLogDeck(this.events);
  final List<String> events;
  @override
  Future<void> resume() async {
    events.add('outgoing resume');
    await super.resume();
  }
}

class _DisposeFailureDeck extends _Deck {
  @override
  Future<void> dispose() async => throw StateError('dispose failed');
}

class _DurationHandoffDeck extends _Deck {
  final durations = StreamController<Duration>.broadcast(sync: true);

  @override
  Stream<Duration> get onDurationChanged => durations.stream;

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
    await super.setFileSource(path);
    durations.add(const Duration(seconds: 60));
  }

  @override
  Future<void> dispose() async {
    await durations.close();
    await super.dispose();
  }
}

class _PermanentSeekFailureDeck extends _Deck {
  @override
  Future<void> seek(Duration position) async => throw StateError('Seek failed');
}

class _Session implements AudioSession {
  int configurations = 0;
  final activations = <bool>[];
  bool focusGranted = true;
  Object? activationError;
  Completer<void>? configureBarrier;
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();

  Future<void> dispose() => interruptions.close();

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations++;
    await configureBarrier?.future;
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    if (activationError case final error?) throw error;
    return !active || focusGranted;
  }

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SessionStore implements AppStateDatabase {
  int clears = 0;
  int? persistedPositionMs;

  @override
  Future<Map<String, dynamic>?> getPlaybackSession() async => null;
  @override
  Future<void> savePlaybackSession({
    required Uint8List mediaJson,
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    persistedPositionMs = positionMs;
  }

  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    persistedPositionMs = positionMs;
    return true;
  }

  @override
  Future<void> clearPlaybackSession() async => clears++;

  @override
  Future<void> archivePlaybackSession(Map<String, dynamic> media) async =>
      clears++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PositionLog extends _SessionStore {
  final positions = <int>[];

  @override
  Future<void> savePlaybackSession({
    required Uint8List mediaJson,
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    positions.add(positionMs);
    await super.savePlaybackSession(
      mediaJson: mediaJson,
      index: index,
      positionMs: positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );
  }

  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) {
    positions.add(positionMs);
    return super.updatePlaybackSessionState(
      index: index,
      positionMs: positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );
  }
}

class _ResumeSessionStore extends _SessionStore {
  Map<String, dynamic>? active;
  Map<String, dynamic>? archived;
  Map<String, dynamic>? preview;
  Future<void> Function()? beforeResumeLoad;
  int resumeReads = 0;

  @override
  Future<Map<String, dynamic>?> getPlaybackSession() async => active;

  @override
  Future<void> savePlaybackSession({
    required Uint8List mediaJson,
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    await super.savePlaybackSession(
      mediaJson: mediaJson,
      index: index,
      positionMs: positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );
    active = {
      'version': 2,
      'media': jsonDecode(utf8.decode(mediaJson)),
      'index': index,
      'positionMs': positionMs,
      'shuffle': shuffle,
      'repeat': repeatMode,
    };
  }

  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    if (active == null) return false;
    active = {
      ...active!,
      'index': index,
      'positionMs': positionMs,
      'shuffle': shuffle,
      'repeat': repeatMode,
    };
    return super.updatePlaybackSessionState(
      index: index,
      positionMs: positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );
  }

  @override
  Future<void> archivePlaybackSession(Map<String, dynamic> media) async {
    archived = active;
    preview = {'media': media, 'positionMs': active?['positionMs']};
    active = null;
    clears++;
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackResumePreview() async => preview;

  @override
  Future<Map<String, dynamic>?> getPlaybackResumeSession() async {
    resumeReads++;
    await beforeResumeLoad?.call();
    return archived;
  }

  @override
  Future<void> clearPlaybackResume() async {
    archived = preview = null;
  }
}

class _DeletionHandler extends MusicPlayerHandler {
  _DeletionHandler(MusicPlayerRuntime runtime) : super(runtime: runtime);

  final deletedSources = <String>[];

  @override
  Future<void> onSourceDeleted(String source) async =>
      deletedSources.add(source);
}

class _Recorder extends ListeningRecorder {
  _Recorder({required super.write, required super.elapsed, required super.now});

  int updates = 0;
  int flushes = 0;
  ListeningTrack? latestTrack;

  @override
  Future<void> flush() {
    flushes++;
    return super.flush();
  }

  @override
  void update(
    ListeningTrack? track, {
    required bool playing,
    bool ended = false,
    Object? playbackInstance,
  }) {
    updates++;
    latestTrack = track;
    super.update(
      track,
      playing: playing,
      ended: ended,
      playbackInstance: playbackInstance,
    );
  }
}

/// Serves Library songs by offset, as the queue query does for rows that
/// have no seek cursor.
class _QueueLibrary implements LibraryDatabase {
  _QueueLibrary(this.rows);

  final List<Map<String, dynamic>> rows;
  final requests = <QueueLibraryDbQuery>[];

  @override
  Future<QueueLibraryDbPage> getQueueTrackPageResult(
    QueueLibraryDbQuery request,
  ) async {
    requests.add(request);
    return QueueLibraryDbPage(
      rows: rows.skip(request.offset).take(request.limit).toList(),
      nextCursor: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One scanned album and the songs a search finds, as a media browser such
/// as Android Auto reads them.
class _BrowsedLibrary implements LibraryDatabase {
  static Map<String, dynamic> song(String id, int number) => {
    'id': id,
    'trackName': 'Song $id',
    'artistName': 'Artist',
    'albumName': 'Album',
    'filePath': '/album/$id.flac',
    'scannedAt': '2026-01-01T00:00:00.000Z',
    'trackNumber': number,
  };

  final album = [song('c', 3), song('a', 1), song('b', 2)];

  @override
  Future<QueueLibraryDbPage> getQueueAlbumPageResult(
    QueueLibraryDbQuery request,
  ) async => const QueueLibraryDbPage(
    rows: [
      {
        'queue_source': 'local',
        'album_key': 'album',
        'album_name': 'Album',
        'artist_name': 'Artist',
      },
    ],
    nextCursor: null,
  );

  @override
  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracksByKey(
    String albumKey,
  ) async => albumKey == 'album' ? album : const [];

  @override
  Future<List<LibrarySearchHit>> searchLibrary({
    required String query,
    required LibrarySearchKind kind,
    required bool includeLocal,
    int limit = 40,
    int offset = 0,
  }) async => kind == LibrarySearchKind.songs && query == 'song b'
      ? const [
          LibrarySearchHit(
            kind: LibrarySearchKind.songs,
            id: 'b',
            title: 'Song b',
            source: 'local',
          ),
        ]
      : const [];

  @override
  Future<Map<String, dynamic>?> getById(String id) async {
    for (final row in album) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoHistory implements HistoryDatabase {
  @override
  Future<Map<String, dynamic>?> findByFilePath(String filePath) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Loved collection by track key.
class _Loved implements LibraryCollectionsDatabase {
  final keys = <String>{};

  @override
  Future<bool> containsLovedTrack(String trackKey) async =>
      keys.contains(trackKey);

  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async => keys.add(trackKey);

  @override
  Future<void> deleteLovedEntry(String trackKey) async => keys.remove(trackKey);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MusicPlayerRuntime _runtime({
  AppSettings settings = const AppSettings(),
  Future<MusicPlayerHandler> Function(MusicPlayerHandler Function())?
  initialize,
  List<_Deck>? decks,
  PlaybackDeck Function(String)? createDeck,
  PlaybackDeck Function(CastOutput, MediaItem? Function())? createCastDeck,
  Stream<double> volumeChanges = const Stream.empty(),
  SourceDeletionEvents? sourceDeletionEvents,
  SourceMetadataEvents? sourceMetadataEvents,
  Future<Map<String, dynamic>> Function(String, {String? displayName})?
  readMetadata,
  ListeningRecorder? recorder,
  AutoplayPersonalization Function()? createPersonalization,
  AutoplayTaste Function()? createTaste,
  AutoplayRanker Function()? createRanker,
  bool isIOS = false,
  bool isAndroid = false,
  Future<void> Function()? synchronizePlaybackState,
  _Session? session,
  AppStateDatabase? sessionDatabase,
  LibraryDatabase? libraryDatabase,
  HistoryDatabase? historyDatabase,
  LibraryCollectionsDatabase? collectionsDatabase,
  Future<String?> Function(String)? recoverMissingFile,
  Future<String?> Function(String, String, AppSettings)? recoverMovedDownload,
  Future<String> Function(String)? resolveNetworkSource,
  Future<String?> Function(String)? offlineCopy,
  NetworkPlaybackCache? networkCache,
  Future<Map<String, dynamic>> Function(String)? readNetworkMetadata,
  CoverStore? coverStore,
}) {
  if (isAndroid) {
    const channel = MethodChannel(
      'com.ryanheise.audio_service.handler.methods',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }
  final audioSession = session ?? _Session();
  addTearDown(audioSession.dispose);
  final runtime = MusicPlayerRuntime(
    settings: settings,
    dependencies: PlaybackDependencies(
      createPersonalization:
          createPersonalization ?? AutoplayPersonalization.new,
      createTaste: createTaste ?? AutoplayTaste.new,
      createRanker: createRanker ?? AutoplayRanker.new,
      createDeck:
          createDeck ??
          (_) {
            final deck = _Deck();
            decks?.add(deck);
            return deck;
          },
      createCastDeck: createCastDeck ?? (_, _) => _Deck(),
      audioSession: () async => audioSession,
      initializeHandler: initialize ?? (builder) async => builder(),
      synchronizePlaybackState: synchronizePlaybackState ?? () async {},
      readMetadata:
          readMetadata ??
          (_, {displayName}) async => {'replaygain_track_gain': '-6 dB'},
      recoverMissingFile: recoverMissingFile ?? (_) async => null,
      recoverMovedDownload: recoverMovedDownload ?? (_, _, _) async => null,
      resolveNetworkSource:
          resolveNetworkSource ?? NetworkStorageService.instance.resolve,
      offlineCopy: offlineCopy ?? (_) async => null,
      networkCache: () => networkCache,
      readNetworkMetadata:
          readNetworkMetadata ?? NetworkMetadataService.instance.read,
      coverStore: coverStore,
      sessionDatabase: sessionDatabase ?? _SessionStore(),
      libraryDatabase: libraryDatabase,
      historyDatabase: historyDatabase,
      collectionsDatabase: collectionsDatabase,
      recorder:
          recorder ??
          ListeningRecorder(
            write: (_) async {},
            elapsed: () => Duration.zero,
            now: () => DateTime(2026),
          ),
      volumeChanges: volumeChanges,
      sourceDeletionEvents: sourceDeletionEvents ?? SourceDeletionEvents(),
      sourceMetadataEvents: sourceMetadataEvents ?? SourceMetadataEvents(),
      isAndroid: isAndroid,
      isIOS: isIOS,
    ),
  );
  addTearDown(runtime.dispose);
  return runtime;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _item = MediaItem(id: 'one', title: 'One');
const _track = PlayableMedia(
  id: 'one',
  source: '/one.flac',
  title: 'One',
  artist: 'Artist',
  duration: Duration(seconds: 60),
);

class _QualityTestPaths extends PathProviderPlatform {
  _QualityTestPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('permanent download handoff', () {
    const catalogTrack = Track(
      id: 'handoff-track',
      name: 'Handoff',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 120,
      source: 'spotify',
    );

    String temporaryKey(Track track) => jsonEncode([
      'catalog-audio-v5',
      catalogPlayback.key(track),
      128,
      'auto_light',
      'spotify',
      true,
    ]);

    Future<MusicPlayerHandler> playerWithTemporary(
      PlaybackDeck outgoing,
      _Deck incoming, {
      bool includeNext = true,
      Track initialTrack = catalogTrack,
      _SessionStore? sessionStore,
      PlaybackDeck Function()? permanentFactory,
      Future<PrimaryAudioProperties> Function(String)? probe,
      Future<void> Function(MusicPlayerHandler, Future<void>)? whileLoading,
      CastOutput? castOutput,
      PlaybackDeck Function(CastOutput, MediaItem? Function())? createCastDeck,
      PlaybackDeck Function()? createLocalDeck,
    }) async {
      final root = await Directory.systemTemp.createTemp('handoff-test-');
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _QualityTestPaths(root.path);
      SharedPreferences.setMockInitialValues({});
      addTearDown(() async {
        PathProviderPlatform.instance = oldPaths;
        await root.delete(recursive: true);
      });
      final previousResolver = catalogPlayback.resolveDownloadService;
      catalogPlayback.resolveDownloadService = (_, _) async => 'spotify';
      addTearDown(
        () => catalogPlayback.resolveDownloadService = previousResolver,
      );
      final store = await catalogPlayback.store;
      await store.initialize();
      final file = File('${root.path}/source.m4a');
      await file.writeAsBytes([1, 2, 3]);
      await store.putTemporary(
        temporaryKey(initialTrack),
        file,
        extension: '.m4a',
        qualityMetadata: const {'provider': 'spotify'},
      );
      var initialDeck = true;
      final runtime = _runtime(
        sessionDatabase: sessionStore,
        createDeck: (id) {
          if (id.startsWith('music-permanent-')) {
            return permanentFactory?.call() ?? incoming;
          }
          if (!initialDeck && createLocalDeck != null) return createLocalDeck();
          initialDeck = false;
          return outgoing;
        },
        createCastDeck: createCastDeck,
      );
      final player = probe == null && castOutput == null
          ? await runtime.initialize()
          : MusicPlayerHandler(
              runtime: runtime,
              probeCatalogAudio: probe,
              castOutput: castOutput,
            );
      await castOutput?.initialize();
      final loading = player.setQueueAndPlay(
        [playableFromCatalogTrack(initialTrack), if (includeNext) _track],
        initialPosition: whileLoading == null
            ? Duration.zero
            : const Duration(seconds: 37),
      );
      if (whileLoading != null) {
        await whileLoading(player, loading);
      }
      await loading;
      if (whileLoading != null) return player;
      expect(outgoing.state, PlaybackDeckState.playing);
      await outgoing.seek(const Duration(seconds: 37));
      return player;
    }

    for (final sameCatalogIdentity in [false, true]) {
      test(
        'keeps distinct invalid ISRCs separate (same catalog identity: $sameCatalogIdentity)',
        () async {
          final outgoing = _Deck();
          final incoming = _Deck();
          final track = catalogTrack.copyWith(
            isrc: sameCatalogIdentity ? '---' : 'AA-A',
          );
          final player = await playerWithTemporary(
            outgoing,
            incoming,
            initialTrack: track,
          );
          final download = sameCatalogIdentity
              ? track.copyWith(isrc: 'AA9BQ2200061')
              : track.copyWith(id: 'other-id', source: 'tidal', isrc: 'AAA');
          await player.onPermanentDownloadReady(download, '/other.flac');

          expect(incoming.sources, isEmpty);
          expect(outgoing.position, const Duration(seconds: 37));
          expect(player.playbackState.value.playing, isTrue);
        },
      );
    }

    for (final paused in [false, true]) {
      test(
        'matches formatted ISRCs during handoff (paused: $paused)',
        () async {
          final outgoing = _Deck();
          final incoming = _Deck();
          final track = catalogTrack.copyWith(isrc: ' aa-9bq-22-00061 ');
          final player = await playerWithTemporary(
            outgoing,
            incoming,
            initialTrack: track,
          );
          if (paused) await player.pause();

          await player.onPermanentDownloadReady(
            track.copyWith(isrc: 'AA9BQ2200062'),
            '/other-recording.flac',
          );
          expect(incoming.sources, isEmpty);
          expect(outgoing.position, const Duration(seconds: 37));

          await player.onPermanentDownloadReady(
            track.copyWith(id: 'download-id', isrc: 'AA9BQ2200061'),
            '/permanent.flac',
          );
          expect(incoming.sources, ['/permanent.flac']);
          expect(incoming.position, const Duration(seconds: 37));
          expect(player.playbackState.value.playing, !paused);
        },
      );
    }

    for (final beforeInstance in [false, true]) {
      test(
        'hands off a download offered during load (early: $beforeInstance)',
        () async {
          final gate = Completer<void>();
          final outgoing = _HandoffDeck();
          if (beforeInstance) outgoing.cancellationGate = gate.future;
          final incoming = _TickingDeck();
          final player = await playerWithTemporary(
            outgoing,
            incoming,
            whileLoading: (player, loading) async {
              if (!beforeInstance) {
                await Future.any([outgoing.preparing.future, loading]);
                expect(outgoing.preparing.isCompleted, isTrue);
              }
              await player.onPermanentDownloadReady(catalogTrack, '/old.flac');
              await player.onPermanentDownloadReady(
                catalogTrack,
                '/permanent.flac',
              );
              await player.onPermanentDownloadReady(
                const Track(
                  id: 'other',
                  name: 'Other',
                  artistName: 'Artist',
                  albumName: 'Album',
                  duration: 120,
                  source: 'spotify',
                ),
                '/other.flac',
              );
              if (beforeInstance) gate.complete();
              outgoing.prepared.complete();
            },
          );
          expect(incoming.sources, ['/permanent.flac']);
          expect(incoming.state, PlaybackDeckState.playing);
          await player.pause();
          expect(incoming.state, PlaybackDeckState.paused);
          await player.play();
          expect(incoming.state, PlaybackDeckState.playing);
          expect(incoming.position, const Duration(seconds: 37));
          expect(player.mediaItem.value?.extras?['source'], '/permanent.flac');
        },
      );
    }

    test(
      'pauses a deferred handoff once the temporary source is ready',
      () async {
        final outgoing = _HandoffDeck();
        final incoming = _Deck();
        late MusicPlayerHandler handler;
        late Future<void> pausing;
        final player = await playerWithTemporary(
          outgoing,
          incoming,
          probe: (_) async {
            pausing = handler.pause();
            return const PrimaryAudioProperties();
          },
          whileLoading: (player, loading) async {
            handler = player;
            await Future.any([outgoing.preparing.future, loading]);
            expect(outgoing.preparing.isCompleted, isTrue);
            await player.onPermanentDownloadReady(
              catalogTrack,
              '/permanent.flac',
            );
            outgoing.prepared.complete();
            await loading;
            await pausing;
          },
        );
        expect(incoming.sources, ['/permanent.flac']);
        expect(player.playbackState.value.playing, isFalse);
        expect(incoming.position, const Duration(seconds: 37));
        await player.play();
        expect(incoming.state, PlaybackDeckState.playing);
        expect(incoming.position, const Duration(seconds: 37));
      },
    );

    for (final beforeInstance in [false, true]) {
      test(
        'retains the offer and position when paused before ready (early: $beforeInstance)',
        () async {
          final gate = Completer<void>();
          final outgoing = _HandoffDeck();
          if (beforeInstance) outgoing.cancellationGate = gate.future;
          final incoming = _Deck();
          final player = await playerWithTemporary(
            outgoing,
            incoming,
            whileLoading: (player, loading) async {
              if (!beforeInstance) {
                await Future.any([outgoing.preparing.future, loading]);
                expect(outgoing.preparing.isCompleted, isTrue);
              }
              await player.onPermanentDownloadReady(
                catalogTrack,
                '/permanent.flac',
              );
              final pausing = player.pause();
              if (beforeInstance) gate.complete();
              outgoing.prepared.complete();
              await pausing;
            },
          );
          expect(player.playbackState.value.playing, isFalse);
          expect(
            player.playbackState.value.position,
            const Duration(seconds: 37),
          );
          expect(incoming.sources, isEmpty);
          await player.play();
          expect(incoming.sources, ['/permanent.flac']);
          expect(incoming.position, const Duration(seconds: 37));
          expect(incoming.state, PlaybackDeckState.playing);
        },
      );
    }

    for (final hadOffer in [false, true]) {
      test(
        'accepts the latest offer after Pause cancels loading (had offer: $hadOffer)',
        () async {
          final outgoing = _HandoffDeck();
          final incoming = _Deck();
          final player = await playerWithTemporary(
            outgoing,
            incoming,
            whileLoading: (player, loading) async {
              await Future.any([outgoing.preparing.future, loading]);
              expect(outgoing.preparing.isCompleted, isTrue);
              if (hadOffer) {
                await player.onPermanentDownloadReady(
                  catalogTrack,
                  '/old.flac',
                );
              }
              final pausing = player.pause();
              await player.onPermanentDownloadReady(catalogTrack, '/new.flac');
              outgoing.prepared.complete();
              await pausing;
            },
          );
          expect(incoming.sources, isEmpty);
          expect(player.playbackState.value.playing, isFalse);
          await player.play();
          expect(incoming.sources, ['/new.flac']);
          expect(incoming.position, const Duration(seconds: 37));
        },
      );
    }

    test(
      'drops the pending offer if the temporary source fails to load',
      () async {
        final outgoing = _HandoffDeck();
        final incoming = _Deck();
        final player = await playerWithTemporary(
          outgoing,
          incoming,
          includeNext: false,
          whileLoading: (player, loading) async {
            await Future.any([outgoing.preparing.future, loading]);
            expect(outgoing.preparing.isCompleted, isTrue);
            await player.onPermanentDownloadReady(catalogTrack, '/stale.flac');
            outgoing.prepared.completeError(
              StateError('Temporary decoder failed'),
            );
          },
        );
        expect(incoming.sources, isEmpty);
        await player.play();
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(incoming.sources, isEmpty);
      },
    );

    test(
      'ignores a download after Stop while cancellation is blocked',
      () async {
        final outgoing = _HandoffDeck()..prepared.complete();
        final incoming = _Deck();
        final sessionStore = _SessionStore();
        final player = await playerWithTemporary(
          outgoing,
          incoming,
          sessionStore: sessionStore,
        );
        final gate = Completer<void>();
        outgoing.cancellationGate = gate.future;
        final stopping = player.stop(keepResume: true);
        try {
          await player.onPermanentDownloadReady(catalogTrack, '/late.flac');
          expect(incoming.sources, isEmpty);
        } finally {
          gate.complete();
          await stopping;
        }
        expect(sessionStore.persistedPositionMs, 37000);
      },
    );

    test('Play supersedes an earlier Stop waiting for cancellation', () async {
      final outgoing = _HandoffDeck()..prepared.complete();
      final incoming = _Deck();
      final player = await playerWithTemporary(outgoing, incoming);
      await player.seek(const Duration(seconds: 37));
      final gate = Completer<void>();
      outgoing.cancellationGate = gate.future;
      outgoing.stopAfterCancellation = true;
      final stopping = player.stop(keepResume: true);
      final cancellations = outgoing.cancellations;
      final playing = player.play();
      try {
        expect(outgoing.cancellations, cancellations);
        await _settle();
        expect(outgoing.sources, hasLength(1));
      } finally {
        gate.complete();
        await Future.wait([playing, stopping]);
      }
      expect(player.playbackState.value.playing, isTrue);
      expect(outgoing.position.inSeconds, 37);
      await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
      expect(incoming.sources, ['/permanent.flac']);
      expect(incoming.position.inSeconds, 37);
      await player.pause();
      expect(incoming.state, PlaybackDeckState.paused);
      expect(incoming.position.inSeconds, 37);
    });

    test('a Cast output change does not supersede a blocked Stop', () async {
      const channel = MethodChannel('stopping-cast-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'connected': false},
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>.broadcast(sync: true);
      final output = CastOutput(channel: channel, events: events.stream);
      addTearDown(events.close);
      addTearDown(output.dispose);
      final outgoing = _HandoffDeck()..prepared.complete();
      final tv = _CastDeck();
      final player = await playerWithTemporary(
        outgoing,
        _Deck(),
        castOutput: output,
        createCastDeck: (_, _) => tv,
      );
      final gate = Completer<void>();
      outgoing.cancellationGate = gate.future;
      outgoing.stopAfterCancellation = true;
      final stopping = player.stop(keepResume: true);
      final cancellations = outgoing.cancellations;
      try {
        events.add({'connected': true, 'deviceId': 'tv', 'host': '192.0.2.10'});
        expect(outgoing.cancellations, cancellations);
        expect(tv.sources, isEmpty);
      } finally {
        gate.complete();
        await stopping;
      }
      expect(player.mediaItem.value, isNull);
      expect(player.playbackState.value.playing, isFalse);
      expect(tv.sources, isEmpty);
      await player.setQueueAndPlay([playableFromCatalogTrack(catalogTrack)]);
      expect(tv.sources, hasLength(1));
      expect(tv.state, PlaybackDeckState.playing);
    });

    test(
      'hands off while returning from Cast with a paused local source',
      () async {
        const channel = MethodChannel('permanent-handoff-cast-test');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'connected': false},
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final events = StreamController<Object?>.broadcast(sync: true);
        final output = CastOutput(channel: channel, events: events.stream);
        addTearDown(events.close);
        addTearDown(output.dispose);
        final tv = _CastDeck();
        final returning = _HandoffDeck();
        final incoming = _Deck();
        final player = await playerWithTemporary(
          _Deck(),
          incoming,
          castOutput: output,
          createCastDeck: (_, _) => tv,
          createLocalDeck: () => returning,
          whileLoading: (player, loading) async {
            await loading;
            events.add({
              'connected': true,
              'deviceId': 'tv',
              'host': '192.0.2.10',
            });
            await player.playbackState.stream.firstWhere(
              (state) =>
                  tv.state == PlaybackDeckState.playing &&
                  state.processingState == AudioProcessingState.ready,
            );
            await player.pause();
            await player.seek(const Duration(seconds: 37));
            events.add({'connected': false});
            await returning.preparing.future;
            await player.onPermanentDownloadReady(
              catalogTrack,
              '/permanent.flac',
            );
            final committed = player.mediaItem.stream.firstWhere(
              (item) => item?.extras?['source'] == '/permanent.flac',
            );
            returning.prepared.complete();
            await committed.timeout(const Duration(seconds: 3));
          },
        );
        expect(player.playbackState.value.playing, isFalse);
        expect(incoming.position, const Duration(seconds: 37));
        await player.play();
        expect(incoming.sources, ['/permanent.flac']);
        expect(incoming.state, PlaybackDeckState.playing);
      },
    );

    for (final action in ['replace', 'stop', 'next', 'select']) {
      test('invalidates a download offered during load on $action', () async {
        final outgoing = _HandoffDeck();
        final incoming = _Deck();
        final player = await playerWithTemporary(
          outgoing,
          incoming,
          whileLoading: (player, loading) async {
            await Future.any([outgoing.preparing.future, loading]);
            expect(outgoing.preparing.isCompleted, isTrue);
            await player.onPermanentDownloadReady(catalogTrack, '/stale.flac');
            final pausing = player.pause();
            outgoing.prepared.complete();
            await pausing;
            final Future<void>? change;
            switch (action) {
              case 'replace':
                change = player.setQueueAndPlay([
                  playableFromCatalogTrack(catalogTrack),
                ]);
              case 'stop':
                change = player.stop();
              case 'next':
                change = player.skipToNext();
              default:
                player.onPermanentDownloadSelected(catalogTrack);
                change = null;
            }
            await change;
          },
        );
        expect(incoming.sources, isEmpty);
        if (action == 'select') {
          await player.play();
          expect(incoming.sources, isEmpty);
        }
        await player.setQueueAndPlay([playableFromCatalogTrack(catalogTrack)]);
        expect(incoming.sources, isEmpty);
        expect(outgoing.state, PlaybackDeckState.playing);
      });
    }

    test('verified temporary facts belong only to the audible lease', () async {
      final result = Completer<PrimaryAudioProperties>();
      final player = await playerWithTemporary(
        _Deck(),
        _Deck(),
        probe: (_) => result.future,
      );
      expect(player.mediaItem.value?.extras?['verifiedAudioCodec'], isNull);
      result.complete(
        const PrimaryAudioProperties(codec: 'aac', sampleRate: 44100),
      );
      await _settle();
      final extras = player.mediaItem.value!.extras!;
      expect(extras['verifiedAudioCodec'], 'aac');
      expect(extras['verifiedAudioSampleRate'], 44100);
      expect(extras['resolvedSource'], isNull);
      expect(extras['verifiedAudioBitrate'], isNull);
      await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
      expect(player.mediaItem.value?.extras?['verifiedAudioCodec'], isNull);
      expect(
        player.mediaItem.value?.extras?['verifiedAudioSampleRate'],
        isNull,
      );
    });

    test(
      'probe survives pause and its verified facts remain after resume',
      () async {
        final result = Completer<PrimaryAudioProperties>();
        var probes = 0;
        final player = await playerWithTemporary(
          _Deck(),
          _Deck(),
          probe: (_) {
            probes++;
            return result.future;
          },
        );
        await player.pause();
        result.complete(
          const PrimaryAudioProperties(codec: 'aac', sampleRate: 44100),
        );
        await _settle();
        expect(player.mediaItem.value?.extras?['verifiedAudioCodec'], 'aac');
        expect(
          player.mediaItem.value?.extras?['verifiedAudioSampleRate'],
          44100,
        );
        await player.play();
        expect(player.mediaItem.value?.extras?['verifiedAudioCodec'], 'aac');
        expect(probes, 1);
      },
    );

    test('late probe cannot overwrite the permanent handoff', () async {
      final result = Completer<PrimaryAudioProperties>();
      final player = await playerWithTemporary(
        _Deck(),
        _Deck(),
        probe: (_) => result.future,
      );
      await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
      result.complete(
        const PrimaryAudioProperties(codec: 'aac', sampleRate: 44100),
      );
      await _settle();
      expect(player.mediaItem.value?.extras?['source'], '/permanent.flac');
      expect(player.mediaItem.value?.extras?['verifiedAudioCodec'], isNull);
    });

    test('late probe cannot overwrite the next track', () async {
      final result = Completer<PrimaryAudioProperties>();
      final player = await playerWithTemporary(
        _Deck(),
        _Deck(),
        probe: (_) => result.future,
      );
      await player.skipToNext();
      result.complete(
        const PrimaryAudioProperties(codec: 'aac', sampleRate: 44100),
      );
      await _settle();
      expect(player.mediaItem.value?.extras?['verifiedAudioCodec'], isNull);
      expect(
        player.mediaItem.value?.extras?['verifiedAudioSampleRate'],
        isNull,
      );
    });

    ProviderContainer queueFor(MusicPlayerHandler player) {
      musicPlayerRuntime.attach(player);
      addTearDown(() => musicPlayerRuntime.detach(player));
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_HandoffQueueSettings.new),
          extensionProvider.overrideWith(_HandoffQueueExtensions.new),
          downloadQueueProvider.overrideWith(_HandoffQueue.new),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'queue completion keeps the latest choice when older download finishes last',
      () async {
        final outgoing = _Deck();
        final incoming = _Deck();
        final player = await playerWithTemporary(outgoing, incoming);
        final container = queueFor(player);
        final queue = container.read(downloadQueueProvider.notifier);
        await queue.flushQueuePersistence();
        final a = queue.addToQueue(
          catalogTrack,
          'spotify',
          qualityOverride: 'HIGH',
        );
        final b = queue.addToQueue(
          catalogTrack,
          'spotify',
          qualityOverride: 'LOSSLESS',
        );
        await player.pause();
        await player.seek(const Duration(seconds: 45));
        final committed = player.mediaItem.stream.firstWhere(
          (item) => item?.extras?['source'] == '/b.flac',
        );
        queue.updateItemStatus(
          b,
          DownloadStatus.completed,
          filePath: '/b.flac',
        );
        await committed;
        queue.updateItemStatus(
          a,
          DownloadStatus.completed,
          filePath: '/a.flac',
        );
        await _settle();
        expect(player.mediaItem.value?.extras?['source'], '/b.flac');
        expect(incoming.sources, ['/b.flac']);
        expect(incoming.position, const Duration(seconds: 45));
        expect(player.playbackState.value.playing, isFalse);
      },
    );

    test(
      'queue choice invalidates preparation before the new download completes',
      () async {
        final outgoing = _Deck();
        final first = _HandoffDeck();
        final second = _Deck();
        var created = 0;
        final player = await playerWithTemporary(
          outgoing,
          first,
          permanentFactory: () => created++ == 0 ? first : second,
        );
        final container = queueFor(player);
        final queue = container.read(downloadQueueProvider.notifier);
        await queue.flushQueuePersistence();
        final a = queue.addToQueue(
          catalogTrack,
          'spotify',
          qualityOverride: 'HIGH',
        );
        queue.updateItemStatus(
          a,
          DownloadStatus.completed,
          filePath: '/a.flac',
        );
        await first.preparing.future;
        final b = queue.addToQueue(
          catalogTrack,
          'spotify',
          qualityOverride: 'LOSSLESS',
        );
        first.prepared.complete();
        await first.disposed.future;
        expect(first.resumedPositions, isEmpty);
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(
          player.mediaItem.value?.extras?['source'],
          startsWith('catalog:'),
        );
        // The next offer waits on the same serialized source-change queue.
        final committed = player.mediaItem.stream.firstWhere(
          (item) => item?.extras?['source'] == '/b.flac',
        );
        queue.updateItemStatus(
          b,
          DownloadStatus.completed,
          filePath: '/b.flac',
        );
        await committed;
        expect(first.disposals, 1);
        expect(first.resumedPositions, isEmpty);
        expect(second.position, const Duration(seconds: 37));
        expect(second.state, PlaybackDeckState.playing);
        expect(player.mediaItem.value?.extras?['source'], '/b.flac');
      },
    );

    for (final paused in [false, true]) {
      test(
        'preserves position and ${paused ? 'pause' : 'play'} state',
        () async {
          final outgoing = _Deck();
          final incoming = _Deck();
          final player = await playerWithTemporary(outgoing, incoming);
          if (paused) await player.pause();
          await player.onPermanentDownloadReady(
            catalogTrack,
            '/permanent.flac',
          );
          expect(incoming.sources, ['/permanent.flac']);
          expect(incoming.position, const Duration(seconds: 37));
          expect(
            incoming.state,
            paused ? PlaybackDeckState.stopped : PlaybackDeckState.playing,
          );
          expect(player.playbackState.value.playing, !paused);
          expect(player.mediaItem.value?.extras?['source'], '/permanent.flac');
          expect(outgoing.disposals, 1);
          if (paused) {
            await player.play();
            expect(incoming.state, PlaybackDeckState.playing);
            expect(incoming.position, const Duration(seconds: 37));
            expect(incoming.sources, ['/permanent.flac']);
          }
        },
      );
    }

    test(
      'prepared paused handoff marker does not survive a new track',
      () async {
        final outgoing = _Deck();
        final incoming = _Deck();
        final player = await playerWithTemporary(outgoing, incoming);
        await player.pause();
        await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
        await player.skipToQueueItem(1);
        expect(incoming.sources.last, _track.source);
        incoming.state = PlaybackDeckState.stopped;
        final count = incoming.sources.length;
        await player.play();
        expect(incoming.sources.length, count + 1);
        expect(incoming.sources.last, _track.source);
        expect(incoming.state, PlaybackDeckState.playing);
      },
    );

    test('stop during permanent preparation discards the offer', () async {
      final outgoing = _Deck();
      final incoming = _HandoffDeck();
      final player = await playerWithTemporary(outgoing, incoming);
      final handoff = player.onPermanentDownloadReady(
        catalogTrack,
        '/permanent.flac',
      );
      await incoming.preparing.future;
      final stopping = player.stop();
      incoming.prepared.complete();
      await Future.wait([handoff, stopping]);
      expect(incoming.disposals, 1);
      expect(outgoing.state, PlaybackDeckState.stopped);
      expect(
        player.mediaItem.value?.extras?['source'],
        isNot('/permanent.flac'),
      );
      expect(incoming.resumedPositions, isEmpty);
    });

    test(
      'failed handoff after the fade restores the outgoing volume',
      () async {
        final outgoing = _Deck();
        final incoming = _DroppingDeck(outgoing);
        final player = await playerWithTemporary(outgoing, incoming);
        await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
        expect(outgoing.volumes, isNotEmpty);
        expect(outgoing.volumes.contains(0.0), isTrue);
        expect(outgoing.volumes.last, greaterThan(0.5));
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(incoming.disposals, 1);
        expect(
          player.mediaItem.value?.extras?['source'],
          startsWith('catalog:'),
        );
      },
    );

    test('the incoming deck is not seeked once the fade has ended', () async {
      final outgoing = _Deck();
      final incoming = _SeekLogDeck();
      final player = await playerWithTemporary(outgoing, incoming);
      outgoing.position = const Duration(seconds: 10);
      await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
      final lastVolume = incoming.events.lastIndexOf('volume');
      expect(lastVolume, isNonNegative);
      expect(incoming.events.sublist(lastVolume + 1), isNot(contains('seek')));
    });

    test('a source switch reports only a handoff that committed', () async {
      final committedOutgoing = _Deck();
      final committedIncoming = _Deck();
      final committed = await playerWithTemporary(
        committedOutgoing,
        committedIncoming,
      );
      expect(
        await committed.switchPlaybackSource(catalogTrack, '/permanent.flac'),
        isTrue,
      );
      final failedOutgoing = _Deck();
      final failed = await playerWithTemporary(
        failedOutgoing,
        _DroppingDeck(failedOutgoing),
      );
      expect(
        await failed.switchPlaybackSource(catalogTrack, '/permanent.flac'),
        isFalse,
      );
    });

    test('pausing during the fade ends it without an audible tail', () async {
      final outgoing = _PausingDeck();
      final incoming = _Deck();
      final player = await playerWithTemporary(outgoing, incoming);
      outgoing.setVolumeCalls = 0;
      outgoing.pauseAfterVolumeCalls = 3;
      await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
      expect(outgoing.volumes.length, lessThan(8));
      expect(incoming.volumes.last, greaterThan(0.5));
      expect(incoming.state, PlaybackDeckState.paused);
    });

    test('same-track fade is linear and unrelated fade is equal power', () {
      for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final linear = MusicPlayerHandler.handoffFadeGains(t, correlated: true);
        expect(linear.incoming + linear.outgoing, closeTo(1, 1e-9));
        final power = MusicPlayerHandler.handoffFadeGains(t, correlated: false);
        expect(
          power.incoming * power.incoming + power.outgoing * power.outgoing,
          closeTo(1, 1e-9),
        );
      }
    });

    test('new offer supersedes an offer still preparing', () async {
      final outgoing = _Deck();
      final first = _HandoffDeck();
      final second = _Deck();
      var created = 0;
      final player = await playerWithTemporary(
        outgoing,
        second,
        permanentFactory: () => created++ == 0 ? first : second,
      );
      final firstHandoff = player.onPermanentDownloadReady(
        catalogTrack,
        '/first.flac',
      );
      await first.preparing.future;
      final secondHandoff = player.onPermanentDownloadReady(
        catalogTrack,
        '/second.flac',
      );
      first.prepared.complete();
      await Future.wait([firstHandoff, secondHandoff]);
      expect(first.disposals, 1);
      expect(first.resumedPositions, isEmpty);
      expect(second.sources, ['/second.flac']);
      expect(second.position, const Duration(seconds: 37));
      expect(second.state, PlaybackDeckState.playing);
      expect(player.mediaItem.value?.extras?['source'], '/second.flac');
    });

    test(
      'selecting another download cancels a preparing offer immediately',
      () async {
        final outgoing = _Deck();
        final first = _HandoffDeck();
        final player = await playerWithTemporary(outgoing, first);
        final handoff = player.onPermanentDownloadReady(
          catalogTrack,
          '/old.flac',
        );
        await first.preparing.future;
        player.onPermanentDownloadSelected(catalogTrack);
        first.prepared.complete();
        await handoff;
        expect(first.disposals, 1);
        expect(first.resumedPositions, isEmpty);
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(
          player.mediaItem.value?.extras?['source'],
          startsWith('catalog:'),
        );
      },
    );

    test(
      'same provider id with conflicting ISRC cannot replace playback',
      () async {
        final outgoing = _Deck();
        final incoming = _Deck();
        final encodedCurrent = catalogTrack.copyWith(isrc: 'AAA');
        final player = await playerWithTemporary(
          outgoing,
          incoming,
          initialTrack: encodedCurrent,
        );
        await player.onPermanentDownloadReady(
          catalogTrack.copyWith(isrc: 'BBB'),
          '/wrong.flac',
        );
        expect(incoming.sources, isEmpty);
        expect(
          player.mediaItem.value?.extras?['source'],
          startsWith('catalog:'),
        );
      },
    );

    test(
      'a later permanent offer replaces the committed local source',
      () async {
        final outgoing = _Deck();
        final first = _Deck();
        final second = _Deck();
        var created = 0;
        final player = await playerWithTemporary(
          outgoing,
          first,
          permanentFactory: () => created++ == 0 ? first : second,
        );
        await player.onPermanentDownloadReady(catalogTrack, '/first.flac');
        await player.pause();
        await player.seek(const Duration(seconds: 45));
        await player.onPermanentDownloadReady(catalogTrack, '/second.flac');
        expect(second.sources, ['/second.flac']);
        expect(second.position, const Duration(seconds: 45));
        expect(player.playbackState.value.playing, isFalse);
        expect(player.mediaItem.value?.extras?['source'], '/second.flac');
      },
    );

    test(
      'offer arriving during post-commit cleanup uses the committed deck',
      () async {
        final outgoing = _BlockingDisposeDeck();
        final first = _Deck();
        final second = _Deck();
        var created = 0;
        final player = await playerWithTemporary(
          outgoing,
          first,
          permanentFactory: () => created++ == 0 ? first : second,
        );
        final a = player.onPermanentDownloadReady(catalogTrack, '/first.flac');
        await outgoing.disposing.future;
        final b = player.onPermanentDownloadReady(catalogTrack, '/second.flac');
        outgoing.release.complete();
        await Future.wait([a, b]);
        expect(first.disposals, 1);
        expect(second.sources, ['/second.flac']);
        expect(second.position, const Duration(seconds: 37));
        expect(second.state, PlaybackDeckState.playing);
        expect(player.mediaItem.value?.extras?['source'], '/second.flac');
      },
    );

    test(
      'failed opening keeps temporary playback and releases incoming deck',
      () async {
        final outgoing = _Deck();
        final incoming = _PermanentFailureDeck();
        final player = await playerWithTemporary(outgoing, incoming);
        final source = player.mediaItem.value?.extras?['source'];
        await player.onPermanentDownloadReady(catalogTrack, '/broken.flac');
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(outgoing.position, const Duration(seconds: 37));
        expect(outgoing.disposals, 0);
        expect(incoming.disposals, 1);
        expect(player.mediaItem.value?.extras?['source'], source);
      },
    );

    test(
      'seek failure resumes temporary playback after it was paused',
      () async {
        final outgoing = _Deck();
        final incoming = _PermanentSeekFailureDeck();
        final player = await playerWithTemporary(outgoing, incoming);
        await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(outgoing.position, const Duration(seconds: 37));
        expect(outgoing.disposals, 0);
        expect(incoming.disposals, 1);
        expect(
          player.mediaItem.value?.extras?['source'],
          startsWith('catalog:'),
        );
      },
    );

    test('incoming decoder duration replaces stale catalog duration', () async {
      final outgoing = _Deck();
      final incoming = _DurationHandoffDeck();
      final player = await playerWithTemporary(outgoing, incoming);
      expect(player.mediaItem.value?.duration, const Duration(seconds: 120));
      await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
      expect(player.mediaItem.value?.duration, const Duration(seconds: 60));
    });

    test(
      'recording playback after replacement touches the sounding lease',
      () async {
        final outgoing = _Deck();
        final player = await playerWithTemporary(outgoing, _Deck());
        final store = await catalogPlayback.store;
        final oldFile = File(outgoing.sources.last);
        final replacement = File(
          '${oldFile.parent.path}/replacement-source.m4a',
        );
        await replacement.writeAsBytes([4, 5, 6]);
        final entry = await store.putTemporary(
          temporaryKey(catalogTrack),
          replacement,
          extension: '.m4a',
          qualityMetadata: const {'provider': 'spotify'},
        );
        final newFile = File(entry.path);
        expect(newFile.path, isNot(oldFile.path));
        final earlier = DateTime.utc(2020);
        await oldFile.setLastModified(earlier);
        await newFile.setLastModified(earlier);
        await player.pause();
        await player.play();
        expect((await oldFile.lastModified()).isAfter(earlier), isTrue);
        expect(
          (await newFile.lastModified()).isAtSameMomentAs(earlier),
          isTrue,
        );
      },
    );

    test('incoming completion during resume advances the queue', () async {
      final outgoing = _Deck();
      final incoming = _CompletesOnResumeDeck();
      final player = await playerWithTemporary(outgoing, incoming);
      await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
      for (var i = 0; i < 50 && player.mediaItem.value?.id != _track.id; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(player.mediaItem.value?.id, _track.id);
      expect(outgoing.disposals, 1);
    });

    for (final paused in [false, true]) {
      test(
        'completion during seek respects final state: paused=$paused',
        () async {
          final outgoing = _Deck();
          final incoming = _CompletesOnSeekDeck();
          final player = await playerWithTemporary(outgoing, incoming);
          if (paused) await player.pause();
          await player.onPermanentDownloadReady(
            catalogTrack,
            '/permanent.flac',
          );
          expect(player.mediaItem.value?.extras?['source'], '/permanent.flac');
          expect(player.playbackState.value.playing, !paused);
          expect(
            player.playbackState.value.processingState,
            isNot(AudioProcessingState.completed),
          );
        },
      );
    }

    test(
      'the swap starts muted and crossfades without pausing first',
      () async {
        final events = <String>[];
        final outgoing = _ResumeLogDeck(events);
        final incoming = _Deck();
        final player = await playerWithTemporary(outgoing, incoming);
        outgoing.volumes.clear();
        await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
        expect(incoming.volumes.first, 0);
        expect(incoming.volumes.last, closeTo(1, 0.0001));
        expect(
          incoming.volumes.skip(1),
          orderedEquals(incoming.volumes.skip(1).toList()..sort()),
        );
        expect(outgoing.volumes.first, lessThan(1));
        expect(outgoing.volumes.last, closeTo(0, 0.0001));
        expect(incoming.state, PlaybackDeckState.playing);
        expect(incoming.position, const Duration(seconds: 37));
        expect(outgoing.state, PlaybackDeckState.paused);
        expect(player.mediaItem.value?.extras?['source'], '/permanent.flac');
      },
    );

    test(
      'the incoming deck starts ahead by the measured start latency',
      () async {
        final outgoing = _Deck();
        final slow = _SlowStartDeck(
          startDelay: const Duration(milliseconds: 80),
        );
        final fast = _SlowStartDeck();
        final decks = [slow, fast];
        final player = await playerWithTemporary(
          outgoing,
          slow,
          permanentFactory: () => decks.removeAt(0),
        );
        await player.onPermanentDownloadReady(catalogTrack, '/first.flac');
        expect(slow.state, PlaybackDeckState.playing);
        slow.position = const Duration(seconds: 50);
        await player.onPermanentDownloadReady(catalogTrack, '/second.flac');
        expect(fast.seeks.length, greaterThanOrEqualTo(2));
        expect(fast.seeks.first, const Duration(seconds: 50));
        expect(
          fast.seeks[1] - const Duration(seconds: 50),
          greaterThanOrEqualTo(const Duration(milliseconds: 70)),
        );
      },
    );

    Future<MusicPlayerHandler> clockPlayer(
      _ClockDeck outgoing,
      List<_ClockDeck> incoming,
    ) => playerWithTemporary(
      outgoing,
      incoming.first,
      permanentFactory: () => incoming.removeAt(0),
    );

    Future<Duration> gap(_ClockDeck a, _ClockDeck b) async =>
        (await a.getCurrentPosition())! - (await b.getCurrentPosition())!;

    test('handoff waits for the incoming clock before fading', () async {
      final outgoing = _ClockDeck();
      final incoming = _ClockDeck(
        startDelay: const Duration(milliseconds: 150),
      );
      final player = await clockPlayer(outgoing, [incoming]);
      expect(await player.switchPlaybackSource(catalogTrack, '/a.flac'), isTrue);
      final audible = incoming.timedVolumes.firstWhere((v) => v.$2 > 0).$1;
      expect(audible, greaterThanOrEqualTo(incoming.runsFrom!));
    });

    test('handoff corrects a late incoming deck with few seeks', () async {
      final outgoing = _ClockDeck();
      final incoming = _ClockDeck(
        startDelay: const Duration(milliseconds: 200),
        seekDelay: const Duration(milliseconds: 100),
      );
      final player = await clockPlayer(outgoing, [incoming]);
      expect(await player.switchPlaybackSource(catalogTrack, '/a.flac'), isTrue);
      expect(incoming.seeks.length - 2, lessThanOrEqualTo(3));
      expect(
        (await gap(incoming, outgoing)).abs(),
        lessThanOrEqualTo(const Duration(milliseconds: 30)),
      );
    });

    test('handoff learns the start latency for the next switch', () async {
      final outgoing = _ClockDeck();
      final first = _ClockDeck(
        startDelay: const Duration(milliseconds: 200),
        seekDelay: const Duration(milliseconds: 100),
      );
      final second = _ClockDeck(
        startDelay: const Duration(milliseconds: 200),
        seekDelay: const Duration(milliseconds: 100),
      );
      final player = await clockPlayer(outgoing, [first, second]);
      expect(await player.switchPlaybackSource(catalogTrack, '/a.flac'), isTrue);
      expect(await player.switchPlaybackSource(catalogTrack, '/b.flac'), isTrue);
      expect(second.seeks.length - 2, lessThanOrEqualTo(1));
    });

    test(
      'handoff leaves the outgoing deck when the incoming one cannot be aligned',
      () async {
        final outgoing = _ClockDeck();
        final incoming = _ClockDeck(
          landing: (target) => target + const Duration(milliseconds: 900),
        );
        final player = await clockPlayer(outgoing, [incoming]);
        final volume = outgoing.volumes.last;
        expect(
          await player.switchPlaybackSource(catalogTrack, '/a.flac'),
          isFalse,
        );
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(outgoing.volumes.last, volume);
        expect(incoming.state, isNot(PlaybackDeckState.playing));
      },
    );

    test('handoff with a static reference keeps the legacy fade', () async {
      final outgoing = _Deck();
      final incoming = _Deck();
      final player = await playerWithTemporary(outgoing, incoming);
      expect(await player.switchPlaybackSource(catalogTrack, '/a.flac'), isTrue);
      expect(incoming.state, PlaybackDeckState.playing);
      expect(outgoing.state, PlaybackDeckState.paused);
    });

    test('unaligned handoff dips instead of overlapping', () async {
      final log = <(String, double)>[];
      final outgoing = _ClockDeck(name: 'out', log: log);
      final incoming = _StubbornDeck(
        name: 'in',
        log: log,
        startDelay: const Duration(milliseconds: 450),
        offset: const Duration(milliseconds: 120),
      );
      final player = await clockPlayer(outgoing, [incoming]);
      log.clear();
      final volume = outgoing.volumes.first;
      expect(await player.switchPlaybackSource(catalogTrack, '/a.flac'), isTrue);
      var out = volume;
      var inc = 0.0;
      for (final (deck, level) in log) {
        if (deck == 'out') {
          out = level;
        } else {
          inc = level;
        }
        expect(out > 0 && inc > 0, isFalse);
      }
      expect(inc, volume);
      expect(outgoing.state, PlaybackDeckState.paused);
    });

    group('handoff with invalid or drifting incoming clocks', () {
      late List<String> trace;
      late DebugPrintCallback previousPrint;

      setUp(() {
        trace = [];
        previousPrint = debugPrint;
        debugPrint = (message, {wrapWidth}) {
          if (message != null) trace.add(message);
        };
      });

      tearDown(() => debugPrint = previousPrint);

      bool traced(String text) => trace.any((line) => line.contains(text));

      test('a stale position after a seek does not abort', () async {
        final outgoing = _ClockDeck();
        final incoming = _StaleClockDeck(
          startDelay: const Duration(milliseconds: 150),
          freezeAtSeek: 3,
        );
        final player = await clockPlayer(outgoing, [incoming]);
        expect(
          await player.switchPlaybackSource(catalogTrack, '/a.flac'),
          isTrue,
        );
        expect(traced('stale'), isTrue);
        expect(traced('mode=dip reason=stale_after_correction'), isTrue);
        expect(traced('mode=abort'), isFalse);
        expect(incoming.state, PlaybackDeckState.playing);
        expect(outgoing.state, PlaybackDeckState.paused);
      });

      test('a small initial drift is not corrected with a seek', () async {
        final outgoing = _ClockDeck();
        final incoming = _ClockDeck(
          startDelay: const Duration(milliseconds: 390),
        );
        final player = await clockPlayer(outgoing, [incoming]);
        expect(
          await player.switchPlaybackSource(catalogTrack, '/a.flac'),
          isTrue,
        );
        expect(incoming.seeks.length, 2);
        expect(traced('correct#'), isFalse);
        expect(traced('mode=dip reason=aligned'), isTrue);
      });

      test('a moderate drift gets one correction and then aligns', () async {
        final outgoing = _ClockDeck();
        final incoming = _ClockDeck(
          startDelay: const Duration(milliseconds: 150),
          seekDelay: const Duration(milliseconds: 200),
        );
        final player = await clockPlayer(outgoing, [incoming]);
        expect(
          await player.switchPlaybackSource(catalogTrack, '/a.flac'),
          isTrue,
        );
        expect(incoming.seeks.length, 3);
        expect(traced('correct#1'), isTrue);
        expect(traced('correct#2'), isFalse);
        expect(traced('reason=aligned'), isTrue);
        expect(traced('mode=abort'), isFalse);
      });

      test('a valid drift above the limit twice aborts', () async {
        final outgoing = _ClockDeck();
        final incoming = _ClockDeck(
          landing: (target) => target + const Duration(milliseconds: 500),
        );
        final player = await clockPlayer(outgoing, [incoming]);
        final volume = outgoing.volumes.last;
        expect(
          await player.switchPlaybackSource(catalogTrack, '/a.flac'),
          isFalse,
        );
        expect(traced('mode=abort reason=drift_over_limit'), isTrue);
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(outgoing.volumes.last, volume);
      });

      test('a valid drift above 150 ms after corrections does not switch', () async {
        final outgoing = _ClockDeck();
        final incoming = _StubbornDeck(
          startDelay: const Duration(milliseconds: 450),
          offset: const Duration(milliseconds: 300),
        );
        final player = await clockPlayer(outgoing, [incoming]);
        final volume = outgoing.volumes.last;
        expect(
          await player.switchPlaybackSource(catalogTrack, '/a.flac'),
          isFalse,
        );
        expect(traced('mode=abort'), isTrue);
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(outgoing.volumes.last, volume);
        expect(incoming.state, isNot(PlaybackDeckState.playing));
      });

      test('a deck ahead by 692 ms is corrected by subtracting the drift', () async {
        final outgoing = _ClockDeck();
        var calls = 0;
        final incoming = _ClockDeck(
          landing: (target) =>
              ++calls == 2 ? target + const Duration(milliseconds: 242) : target,
        );
        final player = await clockPlayer(outgoing, [incoming]);
        expect(
          await player.switchPlaybackSource(catalogTrack, '/a.flac'),
          isTrue,
        );
        final correction = trace.firstWhere((l) => l.contains('correct#1'));
        expect(RegExp(r'drift=69\d').hasMatch(correction), isTrue);
        final aimed = RegExp(r'seek=(\d+) in=(\d+) drift=(\d+)')
            .firstMatch(correction)!;
        final seek = int.parse(aimed.group(1)!);
        final heard = int.parse(aimed.group(2)!);
        final drift = int.parse(aimed.group(3)!);
        expect(seek, lessThan(heard - drift + 300));
        expect(seek, greaterThan(heard - drift));
        expect(
          (await gap(incoming, outgoing)).abs(),
          lessThanOrEqualTo(const Duration(milliseconds: 100)),
        );
      });

      test('latencies are learned per source kind', () async {
        final outgoing = _ClockDeck();
        final video = _ClockDeck(startDelay: const Duration(milliseconds: 1200));
        final audio = _ClockDeck(startDelay: const Duration(milliseconds: 400));
        final player = await clockPlayer(outgoing, [video, audio]);
        final videoKind = player.handoffKindFor(
          video,
          '/clip.m4a',
          sourceKind: 'video',
        );
        final audioKind = player.handoffKindFor(audio, '/song.flac');
        expect(videoKind, isNot(audioKind));
        expect(player.handoffLatencyFor(videoKind, cold: true).inMilliseconds, 450);
        expect(
          await player.switchPlaybackSource(
            catalogTrack,
            '/clip.m4a',
            sourceKind: 'video',
          ),
          isTrue,
        );
        expect(
          player.handoffLatencyFor(videoKind, cold: true),
          greaterThan(const Duration(milliseconds: 700)),
        );
        expect(player.handoffLatencyFor(audioKind, cold: true).inMilliseconds, 450);
        trace.clear();
        expect(
          await player.switchPlaybackSource(catalogTrack, '/song.flac'),
          isTrue,
        );
        expect(traced('start '), isTrue);
        expect(traced('kind=$audioKind cold=450'), isTrue);
      });

      test('latency learning has the right sign and range', () {
        const base = Duration(milliseconds: 1200);
        expect(
          MusicPlayerHandler.learnHandoffLatency(
            base,
            const Duration(milliseconds: 692),
          ),
          const Duration(milliseconds: 854),
        );
        expect(
          MusicPlayerHandler.learnHandoffLatency(
            base,
            const Duration(milliseconds: -300),
          ),
          const Duration(milliseconds: 1350),
        );
        expect(
          MusicPlayerHandler.learnHandoffLatency(
            const Duration(milliseconds: 1500),
            const Duration(milliseconds: -2000),
          ),
          const Duration(milliseconds: 1500),
        );
        expect(
          MusicPlayerHandler.learnHandoffLatency(
            const Duration(milliseconds: 150),
            const Duration(milliseconds: 2000),
          ),
          const Duration(milliseconds: 150),
        );
      });

      test('an incoming deck that never starts aborts', () async {
        final outgoing = _ClockDeck();
        final incoming = _ClockDeck(startDelay: const Duration(seconds: 5));
        final player = await clockPlayer(outgoing, [incoming]);
        expect(
          await player.switchPlaybackSource(catalogTrack, '/a.flac'),
          isFalse,
        );
        expect(traced('mode=abort reason=incoming_not_running'), isTrue);
        expect(outgoing.state, PlaybackDeckState.playing);
      });
    });

    test('handoff publishes the incoming position once', () async {
      final outgoing = _ClockDeck();
      final incoming = _ClockDeck(
        startDelay: const Duration(milliseconds: 150),
        seekDelay: const Duration(milliseconds: 50),
      );
      final player = await clockPlayer(outgoing, [incoming]);
      expect(await player.switchPlaybackSource(catalogTrack, '/a.flac'), isTrue);
      final published = player.playbackState.value.position;
      final actual = await incoming.getCurrentPosition();
      expect(
        (actual! - published).abs(),
        lessThanOrEqualTo(const Duration(milliseconds: 50)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.playbackState.value.position, greaterThanOrEqualTo(published));
    });

    test(
      'an incoming deck that never starts leaves the outgoing one',
      () async {
        final outgoing = _Deck();
        final stuck = _Deck();
        final never = Completer<void>();
        final incoming = _ResumeGateDeck(never.future);
        final player = await playerWithTemporary(
          outgoing,
          stuck,
          permanentFactory: () => incoming,
        );
        await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(incoming.state, PlaybackDeckState.stopped);
        expect(
          player.mediaItem.value?.extras?['source'],
          startsWith('catalog:'),
        );
        never.complete();
      },
    );

    test(
      'abort silences incoming before resuming after output changes',
      () async {
        final events = <String>[];
        final outgoing = _ResumeLogDeck(events);
        final incoming = _AbortOnResumeDeck(events);
        final player = await playerWithTemporary(outgoing, incoming);
        addTearDown(() => playbackExclusiveOutput.value = false);
        events.clear();
        final handoff = player.onPermanentDownloadReady(
          catalogTrack,
          '/permanent.flac',
        );
        await incoming.resumeStarted.future;
        playbackExclusiveOutput.value = true;
        incoming.resumeReleased.complete();
        await handoff;
        expect(events, ['incoming resume', 'incoming stop', 'outgoing resume']);
        expect(incoming.disposals, 1);
        expect(outgoing.state, PlaybackDeckState.playing);
      },
    );

    test(
      'exclusive output switch resumes the active deck after handoff abort',
      () async {
        final shared = _Deck();
        final exclusive = _Deck();
        final outgoing = ExclusiveOutputDeck(
          shared: shared,
          createExclusive: () => exclusive,
          exclusiveAvailable: () => true,
        );
        final incoming = _AbortOnResumeDeck(<String>[]);
        final player = await playerWithTemporary(outgoing, incoming);
        addTearDown(() => playbackExclusiveOutput.value = false);
        final handoff = player.onPermanentDownloadReady(
          catalogTrack,
          '/permanent.flac',
        );
        await incoming.resumeStarted.future;
        playbackExclusiveOutput.value = true;
        incoming.resumeReleased.complete();
        await handoff;
        expect(incoming.disposals, 1);
        expect(exclusive.sources, isNotEmpty);
        expect(exclusive.state, PlaybackDeckState.playing);
        expect(shared.state, isNot(PlaybackDeckState.playing));
      },
    );

    test(
      'outgoing runtime error during preparation prevents handoff',
      () async {
        final outgoing = _CastDeck();
        final incoming = _HandoffDeck();
        final player = await playerWithTemporary(outgoing, incoming);
        final handoff = player.onPermanentDownloadReady(
          catalogTrack,
          '/permanent.flac',
        );
        await incoming.preparing.future;
        outgoing.states.addError(StateError('decoder failed'));
        await _settle();
        incoming.prepared.complete();
        await handoff;
        expect(incoming.disposals, 1);
        expect(incoming.resumedPositions, isEmpty);
        expect(
          player.mediaItem.value?.extras?['source'],
          startsWith('catalog:'),
        );
      },
    );

    test(
      'outgoing disposal failure still persists committed handoff',
      () async {
        final outgoing = _DisposeFailureDeck();
        final incoming = _Deck();
        final store = _SessionStore();
        final player = await playerWithTemporary(
          outgoing,
          incoming,
          sessionStore: store,
        );
        await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
        expect(player.mediaItem.value?.extras?['source'], '/permanent.flac');
        expect(player.playbackState.value.playing, isTrue);
        expect(store.persistedPositionMs, 37000);
      },
    );

    for (final includeNext in [false, true]) {
      test(
        'completion during preparation preserves completion or advance: next=$includeNext',
        () async {
          final outgoing = _CastDeck();
          final incoming = _HandoffDeck();
          final player = await playerWithTemporary(
            outgoing,
            incoming,
            includeNext: includeNext,
          );
          final handoff = player.onPermanentDownloadReady(
            catalogTrack,
            '/permanent.flac',
          );
          await incoming.preparing.future;
          outgoing.complete();
          await _settle();
          incoming.prepared.complete();
          await handoff;
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            if (includeNext && player.mediaItem.value?.id == _track.id) break;
          }
          expect(incoming.disposals, 1);
          expect(incoming.resumedPositions, isEmpty);
          if (includeNext) {
            expect(player.mediaItem.value?.id, _track.id);
            expect(player.playbackState.value.playing, isTrue);
          } else {
            expect(
              player.playbackState.value.processingState,
              AudioProcessingState.completed,
            );
            expect(player.playbackState.value.playing, isFalse);
          }
        },
      );
    }

    test('another catalog identity cannot replace the current song', () async {
      final outgoing = _Deck();
      final incoming = _Deck();
      final player = await playerWithTemporary(outgoing, incoming);
      await player.onPermanentDownloadReady(
        catalogTrack.copyWith(id: 'different-track'),
        '/other.flac',
      );
      expect(outgoing.state, PlaybackDeckState.playing);
      expect(incoming.sources, isEmpty);
      expect(player.mediaItem.value?.extras?['source'], startsWith('catalog:'));
    });

    test(
      'track change during preparation discards the incoming deck',
      () async {
        final outgoing = _Deck();
        final incoming = _HandoffDeck();
        final player = await playerWithTemporary(outgoing, incoming);
        final handoff = player.onPermanentDownloadReady(
          catalogTrack,
          '/permanent.flac',
        );
        await incoming.preparing.future;
        final next = player.skipToQueueItem(1);
        incoming.prepared.complete();
        await Future.wait([handoff, next]);
        expect(player.mediaItem.value?.id, _track.id);
        expect(outgoing.sources.last, _track.source);
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(incoming.disposals, 1);
        expect(incoming.resumedPositions, isEmpty);
      },
    );
    test(
      'pause during preparation retries permanent source at position',
      () async {
        final outgoing = _Deck();
        final incoming = _HandoffDeck();
        final replacement = _Deck();
        var created = 0;
        final player = await playerWithTemporary(
          outgoing,
          incoming,
          permanentFactory: () => created++ == 0 ? incoming : replacement,
        );
        final handoff = player.onPermanentDownloadReady(
          catalogTrack,
          '/permanent.flac',
        );
        await incoming.preparing.future;
        await player.onPermanentDownloadReady(catalogTrack, '/permanent.flac');
        final pause = player.pause();
        incoming.prepared.complete();
        await Future.wait([handoff, pause]);
        expect(outgoing.state, PlaybackDeckState.paused);
        expect(outgoing.disposals, 1);
        expect(incoming.disposals, 1);
        expect(incoming.resumedPositions, isEmpty);
        expect(created, 2);
        expect(replacement.position, const Duration(seconds: 37));
        expect(player.mediaItem.value?.extras?['source'], '/permanent.flac');
        await player.play();
        expect(replacement.state, PlaybackDeckState.playing);
        expect(replacement.position, const Duration(seconds: 37));
      },
    );

    test(
      'exclusive output enabled during preparation cancels handoff',
      () async {
        final outgoing = _Deck();
        final incoming = _HandoffDeck();
        final player = await playerWithTemporary(outgoing, incoming);
        addTearDown(() => playbackExclusiveOutput.value = false);
        final handoff = player.onPermanentDownloadReady(
          catalogTrack,
          '/permanent.flac',
        );
        await incoming.preparing.future;
        playbackExclusiveOutput.value = true;
        incoming.prepared.complete();
        await handoff;
        expect(outgoing.state, PlaybackDeckState.playing);
        expect(outgoing.disposals, 0);
        expect(incoming.disposals, 1);
      },
    );
  });
  test(
    'restored catalog playback sends playback quality to provider',
    () async {
      final root = await Directory.systemTemp.createTemp('playback-quality-');
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _QualityTestPaths(root.path);
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final captured = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'downloadByStrategy') {
          captured.complete(
            Map<String, dynamic>.from(
              jsonDecode(call.arguments as String) as Map,
            ),
          );
          return {'success': false};
        }
        return null;
      });
      final oldResolver = catalogPlayback.resolveDownloadService;
      catalogPlayback.resolveDownloadService = (_, _) async => 'example';
      addTearDown(() async {
        catalogPlayback.resolveDownloadService = oldResolver;
        messenger.setMockMethodCallHandler(channel, null);
        PathProviderPlatform.instance = oldPaths;
        await root.delete(recursive: true);
      });
      const track = Track(
        id: 'quality-test',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 120,
        source: 'spotify',
      );
      final handler = await _runtime(
        settings: const AppSettings(
          playbackQuality: 'HIGH',
          audioQuality: 'LOW',
        ),
      ).initialize();
      await handler.restoreSession(
        items: [playableFromCatalogTrack(track)],
        index: 0,
        position: const Duration(seconds: 12),
        shuffle: false,
      );
      await handler.play();
      final payload = await captured.future.timeout(const Duration(seconds: 5));
      expect(payload['quality'], 'HIGH');
      expect(payload['quality'], isNot('LOW'));
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();

  test('source deletion preserves the shared Jam queue', () async {
    final player = await _runtime(settings: const AppSettings()).initialize();
    const next = PlayableMedia(
      id: 'two',
      source: '/two.flac',
      title: 'Two',
      artist: 'Artist',
    );
    await player.setQueueAndPlay([_track, next, _track]);
    await player.reconcileJamQueue([
      (occurrenceId: 'one', media: _track),
      (occurrenceId: 'two', media: next),
      (occurrenceId: 'three', media: _track),
    ], initialCurrentOccurrenceId: 'one');
    final before = player.queue.value;
    await player.onSourceDeleted('/one.flac');
    await player.onSourceDeleted('/two.flac');
    expect(player.queue.value, same(before));
    expect(player.queue.value.map((item) => item.extras?['jamOccurrenceId']), [
      'one',
      'two',
      'three',
    ]);
    expect(player.mediaItem.value?.id, 'one');

    player.endJamQueue();
    await player.onSourceDeleted('/two.flac');
    expect(player.queue.value.map((item) => item.id), ['one', 'one']);
  });

  test('shuffle begun before Jam cannot reorder its queue', () async {
    final player = await _runtime(settings: const AppSettings()).initialize();
    const next = PlayableMedia(
      id: 'two',
      source: '/two.flac',
      title: 'Two',
      artist: 'Artist',
    );
    await player.setQueueAndPlay([_track, next, _track]);
    final shuffle = player.setShuffleMode(AudioServiceShuffleMode.all);
    final jam = player.reconcileJamQueue([
      (occurrenceId: 'one', media: _track),
      (occurrenceId: 'two', media: next),
      (occurrenceId: 'three', media: _track),
    ], initialCurrentOccurrenceId: 'one');
    await expectLater(shuffle, throwsStateError);
    await jam;
    expect(player.queue.value.map((item) => item.extras?['jamOccurrenceId']), [
      'one',
      'two',
      'three',
    ]);
    player.endJamQueue();
  });

  test(
    'Jam rejects a native queue whose next source may already have started',
    () async {
      final deck = _QueuedDeck();
      final runtime = _runtime(
        settings: const AppSettings(gaplessPlayback: true),
        createDeck: (_) => deck,
      );
      final player = await runtime.initialize();
      const next = PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Artist',
        duration: Duration(seconds: 60),
      );
      await player.setQueueAndPlay([_track, next]);
      deck.positionEvents.add(const Duration(seconds: 45));
      for (var i = 0; i < 30 && deck.nextSource == null; i++) {
        await _settle();
      }
      expect(deck.nextSource, '/two.flac');
      // Native output advances while its callback is delayed.
      deck.nextSource = null;
      deck.position = Duration.zero;
      final before = player.queue.value;
      await expectLater(
        player.reconcileJamQueue([
          (occurrenceId: 'one', media: _track),
          (occurrenceId: 'two', media: next),
        ]),
        throwsStateError,
      );
      expect(player.queue.value, same(before));
      expect(player.mediaItem.value?.id, 'one');
    },
  );

  test(
    'pause persists the last listening delta without waiting for the timer',
    () async {
      final deck = _ReloadDeck();
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026),
      );
      final runtime = _runtime(createDeck: (_) => deck, recorder: recorder);
      final player = await runtime.initialize();
      await player.setQueueAndPlay([_track]);
      await _settle();
      elapsed = const Duration(seconds: 25);
      await recorder.flush();
      elapsed = const Duration(seconds: 31);
      await player.pause();
      await _settle();
      expect(writes.fold<int>(0, (sum, d) => sum + d.milliseconds), 31000);
      expect(writes.fold<int>(0, (sum, d) => sum + d.plays), 1);
    },
  );

  test(
    'Android lifecycle checkpoints without pausing background audio',
    () async {
      final deck = _ReloadDeck();
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026),
      );
      final runtime = _runtime(
        createDeck: (_) => deck,
        recorder: recorder,
        isAndroid: true,
      );
      final player = await runtime.initialize();
      await player.setQueueAndPlay([_track]);
      await _settle();
      elapsed = const Duration(seconds: 31);
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _settle();
      expect(deck.state, PlaybackDeckState.playing);
      expect(writes.fold<int>(0, (sum, d) => sum + d.milliseconds), 31000);
      expect(writes.fold<int>(0, (sum, d) => sum + d.plays), 1);
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  test('pause does not wait for listening storage', () async {
    final gate = Completer<void>();
    var elapsed = Duration.zero;
    final recorder = ListeningRecorder(
      write: (_) => gate.future,
      elapsed: () => elapsed,
      now: () => DateTime(2026),
    );
    final runtime = _runtime(
      createDeck: (_) => _ReloadDeck(),
      recorder: recorder,
    );
    final player = await runtime.initialize();
    await player.setQueueAndPlay([_track]);
    await _settle();
    elapsed = const Duration(seconds: 31);
    try {
      await player.pause().timeout(const Duration(seconds: 2));
    } finally {
      gate.complete();
    }
  });

  for (final seconds in [20, 30]) {
    test(
      'source reload preserves listening session after $seconds seconds',
      () async {
        final deck = _ReloadDeck();
        var elapsed = Duration.zero;
        final writes = <ListeningDelta>[];
        final recorder = ListeningRecorder(
          write: (batch) async => writes.addAll(batch),
          elapsed: () => elapsed,
          now: () => DateTime(2026),
        );
        final runtime = _runtime(createDeck: (_) => deck, recorder: recorder);
        final player = await runtime.initialize();
        await player.setQueueAndPlay([_track]);
        await _settle();
        elapsed += Duration(seconds: seconds);
        await player.pause();
        await _settle();
        deck.reload = true;
        await player.play();
        deck.reload = false;
        await _settle();
        elapsed += Duration(seconds: seconds);
        await recorder.flush();
        expect(deck.sources.length, 2);
        expect(writes.fold<int>(0, (sum, delta) => sum + delta.plays), 1);
        expect(
          writes.fold<int>(0, (sum, delta) => sum + delta.milliseconds),
          seconds * 2000,
        );
      },
    );
  }

  test('gapless duplicate source counts each playback once', () async {
    final deck = _QueuedDeck();
    var elapsed = Duration.zero;
    final writes = <ListeningDelta>[];
    final recorder = ListeningRecorder(
      write: (deltas) async => writes.addAll(deltas),
      elapsed: () => elapsed,
      now: () => DateTime(2026),
    );
    final runtime = _runtime(
      settings: const AppSettings(exclusiveOutput: true, gaplessPlayback: true),
      createDeck: (_) => deck,
      recorder: recorder,
    );
    playbackExclusiveOutput.value = true;
    addTearDown(() => playbackExclusiveOutput.value = false);
    final player = await runtime.initialize();
    await player.setQueueAndPlay([_track, _track]);
    await _settle();
    elapsed = const Duration(seconds: 35);
    deck.positionEvents.add(const Duration(seconds: 45));
    for (var i = 0; i < 30 && deck.nextSource == null; i++) {
      await _settle();
    }
    expect(deck.nextSource, '/one.flac');
    deck.advance();
    await _settle();
    elapsed = const Duration(seconds: 70);
    await recorder.flush();
    expect(writes.fold<int>(0, (sum, delta) => sum + delta.plays), 2);
    expect(
      writes.fold<int>(0, (sum, delta) => sum + delta.milliseconds),
      70000,
    );
  });

  test('exclusive gapless advances metadata on one continuous deck', () async {
    final deck = _QueuedDeck();
    var created = 0;
    final runtime = _runtime(
      settings: const AppSettings(
        exclusiveOutput: true,
        gaplessPlayback: true,
        autoMix: true,
        playbackNormalization: true,
      ),
      createDeck: (_) {
        created++;
        return deck;
      },
      readMetadata: (path, {displayName}) async => {
        'replaygain_track_gain': path == '/two.flac' ? '-12 dB' : '-6 dB',
      },
    );
    playbackExclusiveOutput.value = true;
    addTearDown(() => playbackExclusiveOutput.value = false);
    final player = await runtime.initialize();
    await player.setQueueAndPlay([
      _track,
      const PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Artist',
        duration: Duration(seconds: 60),
      ),
      const PlayableMedia(
        id: 'three',
        source: '/three.flac',
        title: 'Three',
        artist: 'Artist',
        duration: Duration(seconds: 60),
      ),
    ]);
    deck.positionEvents.add(const Duration(seconds: 45));
    for (var i = 0; i < 30 && deck.nextSource == null; i++) {
      await _settle();
    }
    expect(deck.nextSource, '/two.flac');
    deck.advance();
    await _settle();
    expect(player.mediaItem.value!.id, 'two');
    expect(player.playbackState.value.queueIndex, 1);
    expect(player.processing.normalizationGain, closeTo(0.251189, 0.000001));
    expect(deck.sources, ['/one.flac']);
    expect(deck.disposals, 0);
    expect(created, 1);
    deck.positionEvents.add(const Duration(seconds: 45));
    for (var i = 0; i < 30 && deck.nextSource == null; i++) {
      await _settle();
    }
    expect(deck.nextSource, '/three.flac');
    await player.setRepeatMode(AudioServiceRepeatMode.one);
    await _settle();
    expect(deck.nextSource, isNull);
    expect(created, 1);
  });

  for (final failure in [false, true]) {
    test(
      'exclusive gapless handles cancellation and queue failure ($failure)',
      () async {
        final deck = _QueuedDeck()..failQueue = failure;
        final runtime = _runtime(
          settings: const AppSettings(exclusiveOutput: true),
          createDeck: (_) => deck,
        );
        playbackExclusiveOutput.value = true;
        addTearDown(() => playbackExclusiveOutput.value = false);
        final player = await runtime.initialize();
        await player.setQueueAndPlay([
          _track,
          const PlayableMedia(
            id: 'two',
            source: '/two.flac',
            title: 'Two',
            artist: 'Artist',
            duration: Duration(seconds: 60),
          ),
        ]);
        deck.positionEvents.add(const Duration(seconds: 45));
        for (var i = 0; i < 30 && deck.queued == 0; i++) {
          await _settle();
        }
        expect(deck.queued, 1);
        if (failure) {
          await _settle();
          deck.state = PlaybackDeckState.completed;
          deck.completions.add(null);
          for (var i = 0; i < 30 && player.mediaItem.value!.id != 'two'; i++) {
            await _settle();
          }
          expect(player.mediaItem.value!.id, 'two');
          expect(deck.sources, ['/one.flac', '/two.flac']);
        } else {
          final stale = deck.onStart!;
          await player.stop();
          stale();
          await _settle();
          expect(player.mediaItem.value, isNull);
          expect(deck.nextSource, isNull);
          expect(deck.state, PlaybackDeckState.stopped);
        }
      },
    );
  }

  test(
    'Cast handoff keeps position, controls and queue, and disconnect returns paused',
    () async {
      const channel = MethodChannel('runtime-cast-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'state' ? {'connected': false} : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>.broadcast(sync: true);
      final output = CastOutput(channel: channel, events: events.stream);
      final local = <_Deck>[];
      final tv = <_CastDeck>[];
      final runtime = _runtime(
        decks: local,
        createCastDeck: (_, _) {
          final deck = _CastDeck();
          tv.add(deck);
          return deck;
        },
      );
      final handler = MusicPlayerHandler(runtime: runtime, castOutput: output);
      await output.initialize();
      await handler.setQueueAndPlay([
        _track,
        const PlayableMedia(
          id: 'two',
          source: '/two.flac',
          title: 'Two',
          artist: 'Artist',
        ),
      ]);
      await handler.seek(const Duration(seconds: 12));
      events.add({
        'connected': true,
        'deviceId': 'tv',
        'host': '192.0.2.10',
        'volume': 0.4,
      });
      await handler.play();
      expect(local.single.disposals, 1);
      expect(tv.single.sources, [_track.source]);
      expect(tv.single.position.inSeconds, 12);
      expect(handler.playbackState.value.playing, isTrue);
      await handler.pause();
      expect(tv.single.state, PlaybackDeckState.paused);
      tv.single.remotePlay();
      expect(handler.playbackState.value.playing, isTrue);
      tv.single.complete();
      for (var i = 0; i < 20; i++) {
        await _settle();
      }
      expect(tv.single.sources.last, '/two.flac');
      expect(handler.queue.value, hasLength(2));
      events.add({'connected': false});
      for (var i = 0; i < 20; i++) {
        await _settle();
      }
      expect(local, hasLength(2));
      expect(local.last.sources.last, '/two.flac');
      expect(local.last.state, isNot(PlaybackDeckState.playing));
      expect(handler.playbackState.value.playing, isFalse);
      await runtime.dispose();
      output.dispose();
      await events.close();
    },
  );

  for (final scenario in ['next', 'pause while loading', 'next while paused']) {
    test('Cast uses the requested occurrence for $scenario', () async {
      const channel = MethodChannel('pending-cast-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'connected': false},
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>.broadcast(sync: true);
      final output = CastOutput(channel: channel, events: events.stream);
      addTearDown(events.close);
      addTearDown(output.dispose);
      final outgoing = _HandoffDeck()..prepared.complete();
      final tv = _CastDeck();
      final runtime = _runtime(
        createDeck: (_) => outgoing,
        createCastDeck: (_, _) => tv,
      );
      final handler = MusicPlayerHandler(runtime: runtime, castOutput: output);
      addTearDown(runtime.dispose);
      await output.initialize();
      const next = PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Artist',
      );
      await handler.setQueueAndPlay([_track, next]);
      await handler.seek(const Duration(seconds: 12));
      if (scenario == 'next while paused') await handler.pause();

      final nextGate = Completer<void>();
      final pauseGate = Completer<void>();
      final shouldPause = scenario == 'pause while loading';
      outgoing.cancellationGate = nextGate.future;
      final skipping = handler.skipToNext();
      Future<void>? pausing;
      try {
        expect(handler.mediaItem.value?.id, _track.id);
        if (shouldPause) {
          outgoing.cancellationGate = pauseGate.future;
          pausing = handler.pause();
          expect(handler.playbackState.value.playing, isTrue);
        }
        events.add({'connected': true, 'deviceId': 'tv', 'host': '192.0.2.10'});
      } finally {
        nextGate.complete();
        pauseGate.complete();
        await skipping;
        await pausing;
      }
      for (var i = 0; i < 20; i++) {
        await _settle();
      }
      expect(tv.sources, [next.source]);
      expect(tv.state == PlaybackDeckState.playing, !shouldPause);
      expect(tv.position, Duration.zero);
      expect(handler.playbackState.value.playing, !shouldPause);
      if (shouldPause) {
        await handler.play();
        expect(tv.sources, [next.source]);
        expect(tv.position, Duration.zero);
        expect(tv.state, PlaybackDeckState.playing);
      }
    });
  }

  for (final disconnect in [false, true]) {
    final direction = disconnect ? 'disconnect' : 'connect';
    test(
      'Cast $direction finishes paused when Pause arrives during stop',
      () async {
        const channel = MethodChannel('cast-then-pause-test');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'connected': false},
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final events = StreamController<Object?>.broadcast(sync: true);
        final output = CastOutput(channel: channel, events: events.stream);
        addTearDown(events.close);
        addTearDown(output.dispose);
        final outgoing = _OutputChangeDeck();
        final incoming = _OutputChangeDeck();
        var createdLocal = false;
        final runtime = _runtime(
          createDeck: (_) {
            if (!disconnect) return outgoing;
            if (createdLocal) return incoming;
            createdLocal = true;
            return _Deck();
          },
          createCastDeck: (_, _) => disconnect ? outgoing : incoming,
        );
        final handler = MusicPlayerHandler(
          runtime: runtime,
          castOutput: output,
        );
        addTearDown(runtime.dispose);
        await output.initialize();
        const connected = {
          'connected': true,
          'deviceId': 'tv',
          'host': '192.0.2.10',
        };
        if (disconnect) events.add(connected);
        await handler.setQueueAndPlay([_track]);
        const position = Duration(seconds: 19);
        await handler.seek(position);
        outgoing.blockStop = true;
        events.add(disconnect ? {'connected': false} : connected);
        await outgoing.stopStarted.future.timeout(const Duration(seconds: 2));
        final pausing = handler.pause();
        outgoing.stopBarrier.complete();
        await pausing;
        expect(outgoing.disposals, 1);
        expect(incoming.sources, [_track.source]);
        expect(incoming.position, greaterThanOrEqualTo(position));
        expect(
          incoming.position,
          lessThan(position + const Duration(milliseconds: 250)),
        );
        expect(incoming.resumes, 0);
        expect(handler.playbackState.value.playing, isFalse);
      },
    );
  }

  for (final scenario in ['connect', 'disconnect', 'Next', 'failed seek']) {
    test('Cast uses the current seek intent during $scenario', () async {
      const channel = MethodChannel('seek-then-cast-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'connected': false},
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>.broadcast(sync: true);
      final output = CastOutput(channel: channel, events: events.stream);
      addTearDown(events.close);
      addTearDown(output.dispose);
      final next = scenario == 'Next';
      final disconnect = scenario == 'disconnect';
      final fails = scenario == 'failed seek';
      final outgoing = _DelayedSeekDeck()..failSeek = fails;
      final incoming = _CastDeck();
      var createdLocal = false;
      final runtime = _runtime(
        createDeck: (_) {
          if (!disconnect) return outgoing;
          if (createdLocal) return incoming;
          createdLocal = true;
          return _Deck();
        },
        createCastDeck: (_, _) => disconnect ? outgoing : incoming,
      );
      final handler = MusicPlayerHandler(runtime: runtime, castOutput: output);
      addTearDown(runtime.dispose);
      await output.initialize();
      const second = PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Artist',
      );
      const connected = {
        'connected': true,
        'deviceId': 'tv',
        'host': '192.0.2.10',
      };
      if (disconnect) events.add(connected);
      await handler.setQueueAndPlay([_track, second]);
      if (fails) await handler.pause();
      final firstSeek = handler.seek(const Duration(seconds: 12));
      await outgoing.seekStarted.future.timeout(const Duration(seconds: 2));
      const target = Duration(seconds: 31);
      if (fails) {
        final failed = expectLater(firstSeek, throwsStateError);
        outgoing.seekBarrier.complete();
        await failed;
        events.add(connected);
      } else {
        final lastSeek = handler.seek(target);
        final skipping = next ? handler.skipToNext() : null;
        events.add(disconnect ? {'connected': false} : connected);
        outgoing.seekBarrier.complete();
        await firstSeek;
        await lastSeek;
        await skipping;
      }
      for (var i = 0; i < 20; i++) {
        await _settle();
      }
      expect(incoming.sources, [next ? second.source : _track.source]);
      expect(incoming.position, next || fails ? Duration.zero : target);
      expect(handler.playbackState.value.playing, !disconnect && !fails);
    });
  }

  for (final scenario in [
    'seek',
    'seek after disconnect',
    'pending seek then Play',
    'new seek after Play',
    'completed seek then Play after disconnect',
    'Next then Pause',
    'replacement then Pause',
    'Play then Pause then Play',
  ]) {
    test('Cast preserves the current intent for $scenario', () async {
      const channel = MethodChannel('cast-current-intent-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'connected': false},
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>.broadcast(sync: true);
      final output = CastOutput(channel: channel, events: events.stream);
      addTearDown(events.close);
      addTearDown(output.dispose);
      final outgoing = _OutputChangeDeck();
      final incoming = _OutputChangeDeck();
      final playAfterDisconnect =
          scenario == 'completed seek then Play after disconnect';
      final disconnect =
          scenario == 'seek after disconnect' || playAfterDisconnect;
      if (disconnect) outgoing.castOutput = output;
      final replacement = scenario == 'replacement then Pause';
      final changingTrack = replacement || scenario == 'Next then Pause';
      var createdLocal = false;
      final runtime = _runtime(
        createDeck: (_) {
          if (!disconnect) return outgoing;
          if (createdLocal) return incoming;
          createdLocal = true;
          return _Deck();
        },
        createCastDeck: (_, _) => disconnect ? outgoing : incoming,
      );
      final handler = MusicPlayerHandler(runtime: runtime, castOutput: output);
      addTearDown(runtime.dispose);
      await output.initialize();
      const second = PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Artist',
      );
      const connected = {
        'connected': true,
        'deviceId': 'tv',
        'host': '192.0.2.10',
      };
      if (disconnect) events.add(connected);
      await handler.setQueueAndPlay([_track, second]);
      void switchOutput() =>
          events.add(disconnect ? {'connected': false} : connected);
      const target = Duration(seconds: 32);
      const timeout = Duration(seconds: 2);
      switch (scenario) {
        case 'seek':
        case 'seek after disconnect':
          final barrier = Completer<void>();
          outgoing.cancellation = barrier.future;
          switchOutput();
          try {
            await handler.seek(const Duration(seconds: 12)).timeout(timeout);
            await handler.seek(target).timeout(timeout);
          } finally {
            barrier.complete();
          }
        case 'pending seek then Play':
        case 'new seek after Play':
          outgoing.blockStop = true;
          switchOutput();
          await outgoing.stopStarted.future.timeout(timeout);
          final newSeek = scenario == 'new seek after Play';
          final seek = handler.seek(
            newSeek ? const Duration(seconds: 12) : target,
          );
          final play = handler.play();
          final latest = newSeek ? handler.seek(target) : null;
          outgoing.stopBarrier.complete();
          await Future.wait([seek, play, ?latest]).timeout(timeout);
        case 'completed seek then Play after disconnect':
          await handler.seek(const Duration(seconds: 8));
          final barrier = Completer<void>();
          outgoing.cancellation = barrier.future;
          switchOutput();
          final Future<void> play;
          try {
            await handler.seek(target).timeout(timeout);
            expect(outgoing.position, const Duration(seconds: 8));
            play = handler.play();
          } finally {
            barrier.complete();
          }
          await play.timeout(timeout);
        case 'Next then Pause':
        case 'replacement then Pause':
          outgoing.blockStop = true;
          switchOutput();
          await outgoing.stopStarted.future.timeout(timeout);
          final next = replacement
              ? handler.setQueueAndPlay([second], initialPosition: target)
              : handler.skipToNext();
          final pause = handler.pause();
          outgoing.stopBarrier.complete();
          await Future.wait([next, pause]).timeout(timeout);
        case 'Play then Pause then Play':
          await handler.pause();
          final barrier = Completer<void>();
          outgoing.resuming = barrier.future;
          final first = handler.play();
          await outgoing.resumeStarted.future.timeout(timeout);
          switchOutput();
          final pause = handler.pause();
          final last = handler.play();
          barrier.complete();
          await Future.wait([first, pause, last]).timeout(timeout);
      }
      for (var i = 0; i < 20; i++) {
        await _settle();
      }
      expect(incoming.sources, [changingTrack ? second.source : _track.source]);
      final shouldPlay = !changingTrack && (!disconnect || playAfterDisconnect);
      expect(handler.playbackState.value.playing, shouldPlay);
      if (!shouldPlay) expect(incoming.resumes, 0);
      if (scenario != 'Play then Pause then Play') {
        expect(
          incoming.position,
          changingTrack && !replacement ? Duration.zero : target,
        );
      }
    });
  }

  test(
    'Cast disconnect retains seek through Pause during local preparation',
    () async {
      const channel = MethodChannel('cast-seek-pause-during-preparation');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'connected': false},
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>.broadcast(sync: true);
      final output = CastOutput(channel: channel, events: events.stream);
      addTearDown(events.close);
      addTearDown(output.dispose);
      final outgoing = _CastDeck();
      final incoming = _HandoffDeck();
      var createdLocal = false;
      final runtime = _runtime(
        createDeck: (_) {
          if (createdLocal) return incoming;
          createdLocal = true;
          return _Deck();
        },
        createCastDeck: (_, _) => outgoing,
      );
      final handler = MusicPlayerHandler(runtime: runtime, castOutput: output);
      addTearDown(runtime.dispose);
      await output.initialize();
      events.add({'connected': true, 'deviceId': 'tv', 'host': '192.0.2.10'});
      await handler.setQueueAndPlay([_track]);
      await handler.seek(const Duration(seconds: 8));

      const timeout = Duration(seconds: 2);
      const target = Duration(seconds: 31);
      events.add({'connected': false});
      await incoming.preparing.future.timeout(timeout);
      final seek = handler.seek(target);
      final pause = handler.pause();
      incoming.prepared.complete();
      await Future.wait([seek, pause]).timeout(timeout);

      expect(incoming.resumedPositions, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
      await handler.play().timeout(timeout);
      expect(incoming.resumedPositions, [target]);
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test('a paused song stays paused when moved to the TV', () async {
    const channel = MethodChannel('paused-cast-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'state' ? {'connected': false} : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final events = StreamController<Object?>.broadcast(sync: true);
    final output = CastOutput(channel: channel, events: events.stream);
    final tv = _Deck();
    final runtime = _runtime(createCastDeck: (_, _) => tv);
    final handler = MusicPlayerHandler(runtime: runtime, castOutput: output);
    await output.initialize();
    await handler.setQueueAndPlay([_track]);
    await handler.pause();
    events.add({'connected': true, 'deviceId': 'tv', 'host': '192.0.2.10'});
    for (var i = 0; i < 20; i++) {
      await _settle();
    }
    expect(tv.sources, [_track.source]);
    expect(tv.state, isNot(PlaybackDeckState.playing));
    expect(handler.playbackState.value.playing, isFalse);
    await runtime.dispose();
    output.dispose();
    await events.close();
  });

  test(
    'playback instances survive pause and seek but change for repeated songs',
    () async {
      final handler = await _runtime().initialize();
      await handler.setQueueAndPlay([_track, _track]);
      final first = handler.mediaItem.value!.extras!['playbackInstance'];
      await handler.pause();
      await handler.play();
      await handler.seek(Duration.zero);
      expect(handler.mediaItem.value!.extras!['playbackInstance'], first);
      await handler.skipToQueueItem(1);
      expect(handler.mediaItem.value!.id, _track.id);
      expect(
        handler.mediaItem.value!.extras!['playbackInstance'],
        isNot(first),
      );
    },
  );

  test(
    'Android updates every queued copy before playing a moved download',
    () async {
      final decks = <_Deck>[];
      final store = _ResumeSessionStore();
      final runtime = _runtime(
        isAndroid: true,
        decks: decks,
        sessionDatabase: store,
        recoverMovedDownload: (source, id, settings) async =>
            source == _track.source ? '/new-folder/song.flac' : null,
      );
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track, _track]);
      expect(decks.single.sources, ['/new-folder/song.flac']);
      expect(
        handler.mediaItem.value?.extras?['source'],
        '/new-folder/song.flac',
      );
      expect(handler.queue.value.map((item) => item.extras?['source']), [
        '/new-folder/song.flac',
        '/new-folder/song.flac',
      ]);
      await handler.skipToQueueItem(1);
      expect(decks.single.sources.last, '/new-folder/song.flac');
      expect(handler.playbackState.value.errorMessage, isNull);
      await handler.pause();
      await _settle();
      expect(
        (store.active!['media'] as List).map((item) => (item as Map)['source']),
        ['/new-folder/song.flac', '/new-folder/song.flac'],
      );
    },
  );

  test(
    'a late moved-file lookup cannot replace the newly selected song',
    () async {
      final pending = Completer<String?>();
      final decks = <_Deck>[];
      final handler = await _runtime(
        isAndroid: true,
        decks: decks,
        recoverMovedDownload: (source, id, settings) async =>
            source == _track.source ? pending.future : null,
      ).initialize();
      final first = handler.setQueueAndPlay([_track]);
      await _settle();
      final second = handler.setQueueAndPlay([
        PlayableMedia.fromJson({
          ..._track.toJson(),
          'id': 'next',
          'source': '/next.flac',
        })!,
      ]);
      pending.complete('/new-folder/song.flac');
      await Future.wait([first, second]);
      expect(handler.mediaItem.value?.id, 'next');
      expect(decks.single.sources, ['/next.flac']);
    },
  );

  test(
    'changed tags update queued copies without restarting playback',
    () async {
      final events = SourceMetadataEvents();
      final decks = <_Deck>[];
      var title = 'Old title';
      final runtime = _runtime(
        decks: decks,
        sourceMetadataEvents: events,
        readMetadata: (_, {displayName}) async => {
          'title': title,
          'artist': 'Edited artist',
          'album': 'Edited album',
        },
      );
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track, _track]);
      await handler.seek(const Duration(seconds: 34));
      await handler.pause();
      final sources = List.of(decks.first.sources);
      final position = decks.first.position;
      title = 'Edited title';
      await events.publish(_track.source);
      expect(handler.mediaItem.value!.title, title);
      expect(handler.queue.value.map((item) => item.title), [title, title]);
      expect(handler.mediaItem.value!.artist, 'Edited artist');
      expect(decks.first.sources, sources);
      expect(decks.first.position, position);
      expect(handler.playbackState.value.playing, isFalse);
      expect(RuntimeLinkPlayerPort(runtime).snapshot().current!.title, title);
      await runtime.dispose();
      await events.publish(_track.source);
    },
  );

  test(
    'relocated sources update every queue occurrence without restarting',
    () async {
      final decks = <_Deck>[];
      final store = _ResumeSessionStore();
      final handler = await _runtime(
        decks: decks,
        sessionDatabase: store,
      ).initialize();
      await handler.setQueueAndPlay([_track, _track]);
      await handler.seek(const Duration(seconds: 34));
      final sources = List.of(decks.first.sources);
      await handler.onSourceRelocated(_track.source, '/organized/song.flac');
      expect(handler.queue.value.map((item) => item.extras?['source']), [
        '/organized/song.flac',
        '/organized/song.flac',
      ]);
      expect(
        handler.mediaItem.value?.extras?['source'],
        '/organized/song.flac',
      );
      expect(decks.first.sources, sources);
      expect(decks.first.position, const Duration(seconds: 34));
      expect(jsonEncode(store.active), contains('/organized/song.flac'));
      expect(jsonEncode(store.active), isNot(contains(_track.source)));
    },
  );

  test(
    'an older metadata read cannot overwrite a newer successful edit',
    () async {
      final old = Completer<Map<String, dynamic>>();
      var reads = 0;
      final handler = await _runtime(
        settings: const AppSettings(playbackNormalization: false),
        readMetadata: (_, {displayName}) {
          reads++;
          return reads == 1
              ? old.future
              : Future.value({'title': 'Newest title'});
        },
      ).initialize();
      await handler.setQueueAndPlay([_track]);
      await handler.onSourceMetadataChanged('/unrelated.flac');
      expect(reads, 0);
      final pending = handler.onSourceMetadataChanged(_track.source);
      await handler.onSourceMetadataChanged(_track.source);
      expect(handler.mediaItem.value!.title, 'Newest title');
      old.complete({'title': 'Stale title'});
      await pending;
      expect(handler.mediaItem.value!.title, 'Newest title');
      expect(handler.queue.value.single.title, 'Newest title');
    },
  );

  test('the local player publishes Android stream volume handling', () async {
    final handler = await _runtime().initialize();
    expect(handler.androidPlaybackInfo.value, isA<LocalAndroidPlaybackInfo>());
  });

  test(
    'Link adopts repeat before either player has been initialized',
    () async {
      final desktop = _runtime();
      await RuntimeLinkPlayerPort(desktop).setRepeat(LinkRepeatMode.one);
      expect(
        desktop.handler!.playbackState.value.repeatMode,
        AudioServiceRepeatMode.one,
      );
      final phone = _runtime();
      await LinkMusicPhonePlayer(
        runtime: phone,
        controller: MusicPlayerController(runtime: phone),
        writeVolume: (_) async {},
      ).setRepeat(LinkRepeatMode.all);
      expect(
        phone.handler!.playbackState.value.repeatMode,
        AudioServiceRepeatMode.all,
      );
    },
  );

  for (final desktop in [false, true]) {
    test('Link handoff starts at its position on desktop=$desktop', () async {
      final deck = _HandoffDeck();
      final runtime = _runtime(createDeck: (_) => deck);
      final handler = await runtime.initialize();
      const target = Duration(seconds: 42);
      final positions = <Duration>[];
      final subscription = handler.playbackState.listen((state) {
        if (handler.mediaItem.value?.id == _track.id) {
          positions.add(state.updatePosition);
        }
      });
      addTearDown(subscription.cancel);
      final playing = desktop
          ? RuntimeLinkPlayerPort(
              runtime,
            ).playQueue([_track], index: 0, position: target, playing: true)
          : LinkMusicPhonePlayer(
              runtime: runtime,
              controller: MusicPlayerController(runtime: runtime),
              writeVolume: (_) async {},
            ).playQueue([_track], index: 0, position: target, playing: true);
      try {
        await deck.preparing.future;
        deck.positionEvents.add(Duration.zero);
        await _settle();
        expect(handler.playbackState.value.updatePosition, target);
        expect(positions, isNotEmpty);
        expect(positions, everyElement(target));
      } finally {
        deck.prepared.complete();
        await playing;
      }
      expect(deck.resumedPositions, [target]);
      expect(positions, everyElement(target));
    });
  }

  test(
    'a handed-off shuffled queue keeps its order and current song',
    () async {
      final handler = await _runtime().initialize();
      final media = [
        for (var i = 0; i < 12; i++)
          PlayableMedia(
            id: '$i',
            source: '/$i.flac',
            title: 'Song $i',
            artist: 'Artist',
          ),
      ];
      await handler.setQueueAndPlay(media, initialIndex: 4, shuffle: true);
      expect(
        handler.queue.value.map((item) => item.id),
        media.map((item) => item.id),
      );
      expect(handler.mediaItem.value?.id, '4');
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      await handler.setQueueAndPlay(media, initialIndex: 2, shuffle: false);
      expect(
        handler.queue.value.map((item) => item.id),
        media.map((item) => item.id),
      );
      expect(handler.mediaItem.value?.id, '2');
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.none,
      );
    },
  );

  test('dismissing a paused player ends the saved session and permits new '
      'playback', () async {
    final store = _SessionStore();
    final decks = <_Deck>[];
    final runtime = _runtime(sessionDatabase: store, decks: decks);
    final controller = MusicPlayerController(runtime: runtime);
    final handler = await runtime.initialize();
    await controller.playSingle(_track);
    await handler.pause();

    await controller.dismiss();

    expect(decks.single.state, PlaybackDeckState.stopped);
    expect(handler.mediaItem.value, isNull);
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    expect(store.clears, 1);
    expect(handler.queue.value.map((item) => item.id), ['one']);

    await controller.playSingle(_track);
    expect(handler.mediaItem.value?.id, 'one');
    expect(handler.playbackState.value.playing, isTrue);
  });

  test(
    'Home resumes a dismissed queue at its position after a fresh runtime',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'resume-runtime-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final tracks = [
        for (var i = 0; i < 3; i++)
          PlayableMedia(
            id: '$i',
            source: (await File(
              '${directory.path}/$i.flac',
            ).writeAsString('audio')).path,
            title: 'Track $i',
            artist: 'Artist',
            artUri: 'https://example.com/cover.jpg',
            duration: const Duration(minutes: 3),
          ),
      ];
      final store = _ResumeSessionStore();
      final decks = <_Deck>[];
      final runtime = _runtime(sessionDatabase: store, decks: decks);
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay(tracks, initialIndex: 1, shuffle: true);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      decks.single.position = const Duration(seconds: 23);
      await handler.pause();
      final order = handler.queue.value.map((item) => item.id).toList();
      await MusicPlayerController(runtime: runtime).dismiss();
      expect(handler.mediaItem.value, isNull);
      expect(store.active, isNull);
      expect(store.archived?['positionMs'], 23000);

      final resumedDecks = <_Deck>[];
      final fresh = _runtime(sessionDatabase: store, decks: resumedDecks);
      await fresh.restoreSession();
      expect(fresh.handler, isNull);
      final container = ProviderContainer(
        overrides: [musicPlayerRuntimeProvider.overrideWithValue(fresh)],
      );
      addTearDown(container.dispose);
      final preview = await container.read(playbackResumeProvider.future);
      expect(preview?.media.id, '1');
      expect(preview?.position, const Duration(seconds: 23));
      expect(fresh.handler, isNull);

      expect(
        await MusicPlayerController(runtime: fresh).resumeSavedSession(),
        isTrue,
      );
      expect(fresh.handler!.queue.value.map((item) => item.id), order);
      expect(fresh.handler!.mediaItem.value?.id, '1');
      expect(resumedDecks.single.position, const Duration(seconds: 23));
      expect(fresh.handler!.playbackState.value.playing, isTrue);
      expect(
        fresh.handler!.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      expect(
        fresh.handler!.playbackState.value.repeatMode,
        AudioServiceRepeatMode.all,
      );
    },
  );

  test(
    'switching to external stops playback and keeps the saved session',
    () async {
      final store = _ResumeSessionStore();
      final decks = <_Deck>[];
      final runtime = _runtime(sessionDatabase: store, decks: decks);
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track]);
      decks.single.position = const Duration(seconds: 23);
      final stopped = handler.mediaItem.firstWhere((item) => item == null);
      runtime.configure(runtime.settings.copyWith(playerMode: 'external'));
      await stopped;
      expect(decks.single.state, PlaybackDeckState.stopped);
      expect(store.archived?['positionMs'], 23000);
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        await MusicPlayerController(runtime: runtime).resumeSavedSession(),
        isFalse,
      );
      expect(store.resumeReads, 0);
    },
  );

  test(
    'external startup does not initialize the internal player or restore a session',
    () async {
      final store = _ResumeSessionStore();
      final runtime = _runtime(
        settings: const AppSettings(playerMode: 'external'),
        sessionDatabase: store,
      );
      await runtime.restoreSession();
      await runtime.recoverRestoredArtwork();
      expect(runtime.handler, isNull);
      expect(store.clears, 0);
      expect(store.resumeReads, 0);
    },
  );

  test('a repeated Resume request cannot replace newer playback', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final store = _ResumeSessionStore()
      ..archived = {
        'media': [
          const PlayableMedia(
            id: 'saved',
            source: 'network://fixture/saved.flac',
            title: 'Saved',
            artist: 'Artist',
            artUri: 'https://example.com/cover.jpg',
          ).toJson(),
        ],
        'index': 0,
        'positionMs': 23000,
      }
      ..beforeResumeLoad = () {
        entered.complete();
        return release.future;
      };
    final runtime = _runtime(sessionDatabase: store);
    final controller = MusicPlayerController(runtime: runtime);
    final pending = controller.resumeSavedSession();
    expect(identical(pending, controller.resumeSavedSession()), isTrue);
    await entered.future;
    await controller.playSingle(_track);
    release.complete();
    expect(await pending, isFalse);
    expect(store.resumeReads, 1);
    expect(runtime.handler!.mediaItem.value?.id, _track.id);
    expect(runtime.handler!.playbackState.value.playing, isTrue);
  });

  test(
    'a removed saved file leaves Home without a stale Resume card',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'resume-missing-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = _ResumeSessionStore()
        ..preview = {
          'media': PlayableMedia(
            id: 'missing',
            source: '${directory.path}/missing.flac',
            title: 'Missing',
            artist: 'Artist',
          ).toJson(),
          'positionMs': 23000,
        };
      final runtime = _runtime(sessionDatabase: store);
      expect(await loadPlaybackResumePreview(runtime), isNull);
      expect(runtime.handler, isNull);
    },
  );

  test(
    'deleting a saved source refreshes an already loaded Resume card',
    () async {
      final directory = await Directory.systemTemp.createTemp('resume-delete-');
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/saved.flac',
      ).writeAsString('audio');
      final events = SourceDeletionEvents();
      final store = _ResumeSessionStore()
        ..preview = {
          'media': PlayableMedia(
            id: 'saved',
            source: file.path,
            title: 'Saved',
            artist: 'Artist',
          ).toJson(),
          'positionMs': 23000,
        };
      final runtime = _runtime(
        sessionDatabase: store,
        sourceDeletionEvents: events,
      );
      final container = ProviderContainer(
        overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);
      expect(await container.read(playbackResumeProvider.future), isNotNull);
      expect(await deleteFile(file.path, deletionEvents: events), isTrue);
      expect(await container.read(playbackResumeProvider.future), isNull);
      expect(runtime.handler, isNull);
    },
  );

  for (final state in [
    PlaybackState(playing: true, processingState: AudioProcessingState.ready),
    PlaybackState(processingState: AudioProcessingState.loading),
    PlaybackState(processingState: AudioProcessingState.buffering),
  ]) {
    test('dismiss ignores playing=${state.playing}, '
        'processing=${state.processingState.name}', () async {
      final store = _SessionStore();
      final runtime = _runtime(sessionDatabase: store);
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track]);
      handler.playbackState.add(state);

      await MusicPlayerController(runtime: runtime).dismiss();

      expect(handler.mediaItem.value?.id, 'one');
      expect(handler.playbackState.value, state);
      expect(store.clears, 0);
    });
  }

  test('a pending seek cannot move the next song', () async {
    final deck = _DelayedSeekDeck();
    final runtime = _runtime(createDeck: (_) => deck);
    final handler = await runtime.initialize();
    const nextTrack = PlayableMedia(
      id: 'two',
      source: '/two.flac',
      title: 'Two',
      artist: 'Artist',
    );
    await handler.setQueueAndPlay([_track, nextTrack]);
    final seek = handler.seek(const Duration(seconds: 12));
    await deck.seekStarted.future;
    final next = handler.skipToNext();
    try {
      await _settle();
      expect(deck.sources, ['/one.flac']);
    } finally {
      deck.seekBarrier.complete();
      await Future.wait([seek, next]);
    }
    expect(deck.seekSources, ['/one.flac']);
    expect(handler.mediaItem.value?.id, 'two');
    expect(handler.playbackState.value.updatePosition, Duration.zero);
  });

  test(
    'trained personalized ranking runs through the real autoplay worker',
    () async {
      final model = AutoplayPreferenceModel();
      const preferred = AutoplayLearningTrack(
        source: '/jazz.flac',
        title: 'Jazz',
        artist: 'Jazz Artist',
        genre: 'Jazz',
        duration: Duration(seconds: 60),
      );
      const avoided = AutoplayLearningTrack(
        source: '/rock.flac',
        title: 'Rock',
        artist: 'Rock Artist',
        genre: 'Rock',
        duration: Duration(seconds: 60),
      );
      const seed = AutoplayLearningTrack(
        source: '/one.flac',
        title: 'One',
        artist: 'Artist',
      );
      for (var i = 0; i < 80; i++) {
        model.learn(preferred, previous: seed, at: DateTime.now(), reward: 1);
        model.learn(avoided, previous: seed, at: DateTime.now(), reward: 0);
      }
      final learning = AutoplayPersonalization(
        load: () async => model.encode(),
        save: (_) async {},
      );
      final runtime = _runtime(
        settings: const AppSettings(
          autoplay: true,
          autoplayPersonalization: true,
        ),
        createPersonalization: () => learning,
      );
      final handler = MusicPlayerHandler(
        runtime: runtime,
        autoplayLibraryLoader: (_) async => [
          const PlayableMedia(
            id: 'rock',
            source: '/rock.flac',
            title: 'Rock',
            artist: 'Rock Artist',
            genre: 'Rock',
            duration: Duration(seconds: 60),
          ),
          const PlayableMedia(
            id: 'jazz',
            source: '/jazz.flac',
            title: 'Jazz',
            artist: 'Jazz Artist',
            genre: 'Jazz',
            duration: Duration(seconds: 60),
          ),
        ],
      );
      await learning.ensureLoaded();
      await handler.setQueueAndPlay([_track]);
      await handler.queue
          .firstWhere((queue) => queue.length == 3)
          .timeout(const Duration(seconds: 5));
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        'jazz',
        'rock',
      ]);
      expect(handler.playbackState.value.playing, isTrue);
      await resetAutoplayLearning(runtime: runtime);
      expect(learning.observations, 0);
      await handler.queue
          .firstWhere((queue) => queue.length == 3)
          .timeout(const Duration(seconds: 5));
      expect(handler.queue.value.first.id, 'one');
      runtime.configure(
        runtime.settings.copyWith(autoplayPersonalization: false),
      );
      await handler.queue
          .firstWhere((queue) => queue.length == 3)
          .timeout(const Duration(seconds: 5));
      expect(handler.queue.value.first.id, 'one');
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test('songs played together rank through the real autoplay worker', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('autoplay-taste-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await AutoplayTaste.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/taste.db',
    );
    addTearDown(db.close);
    final taste = AutoplayTaste(
      open: () async => db,
      train: (plays) async => trainAutoplayTaste(plays),
    );
    // Night artists play together, and Day artists, never with each other.
    for (var session = 0; session < 16; session++) {
      final group = session.isEven ? 'Night' : 'Day';
      for (var i = 0; i < 8; i++) {
        taste.record(
          AutoplayFeedback(
            kind: AutoplayFeedbackKind.listened,
            track: AutoplayLearningTrack(
              source: '/$group/$i.flac',
              title: 'Song ${i % 4}',
              artist: '$group ${1 + i % 3}',
            ),
            previous: null,
            at: DateTime(
              2026,
            ).add(Duration(hours: 3 * session, minutes: 4 * i)),
            reward: 1,
          ),
        );
      }
    }
    await taste.train();
    expect(taste.model?.positives, 128);
    final runtime = _runtime(
      settings: const AppSettings(
        autoplay: true,
        autoplayPersonalization: true,
      ),
      createPersonalization: () =>
          AutoplayPersonalization(load: () async => null, save: (_) async {}),
      createTaste: () => taste,
    );
    final handler = MusicPlayerHandler(
      runtime: runtime,
      autoplayLibraryLoader: (_) async => [
        const PlayableMedia(
          id: 'day',
          source: '/day.flac',
          title: 'Song 2',
          artist: 'Day 2',
        ),
        const PlayableMedia(
          id: 'night',
          source: '/night.flac',
          title: 'Song 2',
          artist: 'Night 3',
        ),
      ],
    );
    await handler.setQueueAndPlay([
      const PlayableMedia(
        id: 'one',
        source: '/one.flac',
        title: 'Song 0',
        artist: 'Night 1',
      ),
    ]);
    await handler.queue
        .firstWhere((queue) => queue.length == 3)
        .timeout(const Duration(seconds: 5));
    expect(handler.queue.value.map((item) => item.id), ['one', 'night', 'day']);
    await resetAutoplayLearning(runtime: runtime);
    expect(await taste.readLog(), isEmpty);
    expect(taste.model, isNull);
  });

  test('how the listener takes autoplay picks teaches the ranker', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('autoplay-rank-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await AutoplayRanker.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/ranker.db',
    );
    addTearDown(db.close);
    final ranker = AutoplayRanker(
      open: () async => db,
      train: (outcomes) async => trainAutoplayRanker(outcomes),
    );
    var elapsed = Duration.zero;
    final learning = AutoplayPersonalization(
      load: () async => null,
      save: (_) async {},
      elapsed: () => elapsed,
      now: () => DateTime(2026),
    );
    final runtime = _runtime(
      settings: const AppSettings(
        autoplay: true,
        autoplayPersonalization: true,
      ),
      createPersonalization: () => learning,
      createRanker: () => ranker,
    );
    final handler = MusicPlayerHandler(
      runtime: runtime,
      autoplayLibraryLoader: (_) async => [
        for (final id in ['two', 'three'])
          PlayableMedia(
            id: id,
            source: '/$id.flac',
            title: id,
            artist: 'Artist $id',
            duration: const Duration(seconds: 60),
          ),
      ],
    );
    await learning.ensureLoaded();
    await handler.setQueueAndPlay([_track]);
    await handler.queue
        .firstWhere((queue) => queue.length == 3)
        .timeout(const Duration(seconds: 5));
    await _settle();
    // The song the listener chose says nothing about autoplay's ranking.
    elapsed += const Duration(seconds: 40);
    await handler.skipToNext();
    await _settle();
    expect(await ranker.readOutcomes(), isEmpty);
    // Skipping the first pick within seconds.
    elapsed += const Duration(seconds: 5);
    await handler.skipToNext();
    await _settle();
    final outcomes = await ranker.readOutcomes();
    expect(outcomes, hasLength(1));
    expect(outcomes.single.reward, 0);
    // A new artist, before learning has a preference model.
    expect(outcomes.single.parts, {'novelty': 1});

    await resetAutoplayLearning(runtime: runtime);
    expect(await ranker.readOutcomes(), isEmpty);
  });

  test(
    'player learns explicit skips, excludes pauses and obeys live opt-out',
    () async {
      var elapsed = Duration.zero;
      final learning = AutoplayPersonalization(
        load: () async => null,
        save: (_) async {},
        elapsed: () => elapsed,
        now: () => DateTime(2026),
      );
      final runtime = _runtime(
        settings: const AppSettings(autoplayPersonalization: true),
        createPersonalization: () => learning,
      );
      final handler = await runtime.initialize();
      await learning.ensureLoaded();
      const second = PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Other',
        duration: Duration(seconds: 60),
      );
      await handler.setQueueAndPlay([_track, second]);
      await _settle();
      elapsed += const Duration(seconds: 10);
      await handler.pause();
      elapsed += const Duration(hours: 1);
      await handler.play();
      await _settle();
      await handler.skipToNext();
      await _settle();
      expect(learning.observations, 1);
      expect(
        learning.adjustment(
          const AutoplayLearningTrack(
            source: '/one.flac',
            title: 'One',
            artist: 'Artist',
            duration: Duration(seconds: 60),
          ),
          const AutoplayLearningTrack(
            source: '/two.flac',
            title: 'Two',
            artist: 'Other',
          ),
          DateTime(2026),
        ),
        lessThan(0),
      );
      elapsed += const Duration(seconds: 10);
      await handler.skipToQueueItem(
        1,
      ); // Restarting is not rejecting this song.
      await _settle();
      expect(learning.observations, 1);
      runtime.configure(
        runtime.settings.copyWith(autoplayPersonalization: false),
      );
      elapsed += const Duration(seconds: 50);
      await handler.skipToQueueItem(0);
      expect(learning.observations, 1);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.mediaItem.value?.id, 'one');
    },
  );

  test(
    'initializing and restoring a paused session does not request audio focus',
    () async {
      final session = _Session();
      final decks = <_Deck>[];
      final handler = await _runtime(
        session: session,
        decks: decks,
        isAndroid: true,
      ).initialize();
      await handler.restoreSession(
        items: [_track],
        index: 0,
        position: const Duration(seconds: 12),
        shuffle: false,
      );
      await _settle();
      expect(session.activations, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
      expect(decks.single.state, PlaybackDeckState.stopped);
    },
  );

  for (final target in [Duration.zero, const Duration(seconds: 7)]) {
    test('seek after restore replaces the saved start with $target', () async {
      final decks = <_Deck>[];
      final store = _SessionStore();
      final handler = await _runtime(
        decks: decks,
        sessionDatabase: store,
      ).initialize();
      await handler.restoreSession(
        items: [_track],
        index: 0,
        position: const Duration(seconds: 30),
        shuffle: false,
      );

      await handler.seek(target);
      expect(handler.playbackState.value.updatePosition, target);
      expect(decks.single.sources, isEmpty);
      expect(decks.single.position, Duration.zero);
      expect(handler.playbackState.value.playing, isFalse);
      expect(store.persistedPositionMs, target.inMilliseconds);

      await handler.play();
      expect(decks.single.position, target);
      expect(handler.playbackState.value.playing, isTrue);
    });
  }

  test(
    'queue update during remote resolution preserves foreground playback',
    () async {
      final session = _Session();
      final decks = <_Deck>[];
      final resolving = Completer<void>();
      final release = Completer<String>();
      late MusicPlayerHandler handler;
      handler = await _runtime(
        session: session,
        decks: decks,
        isAndroid: true,
        resolveNetworkSource: (_) {
          resolving.complete();
          return release.future;
        },
        synchronizePlaybackState: () async {
          session.focusGranted = handler.playbackState.value.playing;
        },
      ).initialize();
      const remote = PlayableMedia(
        id: 'remote',
        source: 'network://fixture/song.flac',
        title: 'Remote',
        artist: 'Artist',
      );
      final start = handler.setQueueAndPlay([remote]);
      await resolving.future;
      await handler.enqueue(_track);
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      release.complete('http://127.0.0.1/song.flac');
      await start;
      expect(decks.single.state, PlaybackDeckState.playing);
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
    },
  );

  test(
    'denied audio focus leaves a new source paused and allows retry',
    () async {
      final session = _Session()..focusGranted = false;
      final decks = <_Deck>[];
      final handler = await _runtime(
        session: session,
        decks: decks,
      ).initialize();
      await handler.setQueueAndPlay([_track]);
      expect(decks.single.state, isNot(PlaybackDeckState.playing));
      expect(handler.playbackState.value.playing, isFalse);

      session.focusGranted = true;
      await handler.play();
      expect(decks.single.state, PlaybackDeckState.playing);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.mediaItem.value?.id, _track.id);
    },
  );

  test(
    'queued network song prefers its offline original and retains its origin',
    () async {
      final temp = await Directory.systemTemp.createTemp('player-offline-');
      addTearDown(() => temp.delete(recursive: true));
      final local = await File(
        '${temp.path}/song.flac',
      ).writeAsBytes([1, 2, 3]);
      final decks = <_Deck>[];
      var remoteRequests = 0;
      final handler = await _runtime(
        decks: decks,
        offlineCopy: (_) async => local.path,
        resolveNetworkSource: (_) async {
          remoteRequests++;
          throw const SocketException('Offline');
        },
      ).initialize();
      await handler.setQueueAndPlay([
        const PlayableMedia(
          id: 'nas-song',
          source: 'network://nas/a.flac',
          title: 'NAS song',
          artist: 'Artist',
        ),
      ]);
      expect(decks.single.sources, [local.path]);
      expect(remoteRequests, 0);
      expect(handler.mediaItem.value!.extras!['source'], local.path);
      expect(
        handler.mediaItem.value!.extras!['originSource'],
        'network://nas/a.flac',
      );
      await handler.onSourceDeleted('network://nas/a.flac');
      expect(handler.queue.value, hasLength(1));
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test(
    'missing offline file falls back to its server without requiring a rescan',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'player-offline-missing-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final decks = <_Deck>[];
      final requests = <String>[];
      final handler = await _runtime(
        decks: decks,
        resolveNetworkSource: (source) async {
          requests.add(source);
          return 'http://127.0.0.1:1/original';
        },
      ).initialize();
      await handler.setQueueAndPlay([
        PlayableMedia(
          id: 'saved-song',
          source: '${temp.path}/gone.flac',
          originSource: 'network://nas/a.flac',
          title: 'NAS song',
          artist: 'Artist',
        ),
      ]);
      expect(requests, ['network://nas/a.flac']);
      expect(decks.single.sources, ['stream http://127.0.0.1:1/original']);
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  group('prefetched network copies', () {
    const source = 'network://nas/Album/song.flac';
    const song = PlayableMedia(
      id: 'nas-song',
      source: source,
      title: 'NAS song',
      artist: 'Artist',
    );

    Future<NetworkPlaybackCache> networkCache({Future<void>? release}) async {
      final root = await Directory.systemTemp.createTemp('player-prefetch-');
      addTearDown(() async {
        // Let a background index write finish first.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          // Removed with the system temporary folder later.
        }
      });
      return NetworkPlaybackCache(
        directory: () async => root,
        transfer: () => _NasTransfer(release),
        connectionRemovals: SourceDeletionEvents(),
      );
    }

    test('a whole copy plays as a local file', () async {
      final cache = await networkCache();
      cache.want([source]);
      expect(await cache.ready(source, const Duration(seconds: 5)), isTrue);
      final decks = <_Deck>[];
      var remoteRequests = 0;
      final handler = await _runtime(
        decks: decks,
        networkCache: cache,
        resolveNetworkSource: (_) async {
          remoteRequests++;
          return 'http://127.0.0.1:1/song.flac';
        },
      ).initialize();

      await handler.setQueueAndPlay([song]);

      final path = decks.single.sources.single;
      expect(cache.owns(path), isTrue);
      expect(await File(path).readAsBytes(), [1, 2, 3]);
      expect(remoteRequests, 0);
      // The queue keeps the server song; only this playback opens the copy.
      expect(handler.mediaItem.value!.extras!['source'], source);
    });

    test('a song still downloading streams from its server', () async {
      final cache = await networkCache(release: Completer<void>().future);
      cache.want([source]);
      final decks = <_Deck>[];
      final handler = await _runtime(
        decks: decks,
        networkCache: cache,
        resolveNetworkSource: (_) async => 'http://127.0.0.1:1/song.flac',
      ).initialize();

      await handler.setQueueAndPlay([song]);

      expect(decks.single.sources, ['stream http://127.0.0.1:1/song.flac']);
      cache.want([]);
    });

    test('a saved offline copy plays before a prefetched one', () async {
      final cache = await networkCache();
      cache.want([source]);
      expect(await cache.ready(source, const Duration(seconds: 5)), isTrue);
      final temp = await Directory.systemTemp.createTemp('player-offline-');
      addTearDown(() => temp.delete(recursive: true));
      final local = await File('${temp.path}/song.flac').writeAsBytes([4]);
      final decks = <_Deck>[];
      final handler = await _runtime(
        decks: decks,
        networkCache: cache,
        offlineCopy: (_) async => local.path,
      ).initialize();

      await handler.setQueueAndPlay([song]);

      expect(decks.single.sources, [local.path]);
    });

    test('an edited song no longer plays from its old copy', () async {
      final cache = await networkCache();
      cache.want([source]);
      expect(await cache.ready(source, const Duration(seconds: 5)), isTrue);
      cache.want([]);
      final events = SourceMetadataEvents();
      final handler = await _runtime(
        networkCache: cache,
        sourceMetadataEvents: events,
        readNetworkMetadata: (_) async => {'error': 'unavailable'},
      ).initialize();
      await handler.setQueueAndPlay([song]);

      await events.publish(source);

      expect(await cache.lookup(source), isNull);
    });
  });

  for (final resolved in [
    '/received/Phone song.flac',
    'http://127.0.0.1:1/song.flac',
    'https://example.invalid/song.flac',
  ]) {
    test('a phone song opens its resolved source: $resolved', () async {
      final decks = <_Deck>[];
      final handler = await _runtime(
        decks: decks,
        resolveNetworkSource: (_) async => resolved,
      ).initialize();
      await handler.setQueueAndPlay([
        const PlayableMedia(
          id: 'phone-song',
          source: 'network://example-phone/song.flac',
          title: 'Phone song',
          artist: 'Artist',
        ),
      ]);
      final isStream = resolved.startsWith('http');
      expect(decks.single.sources, [isStream ? 'stream $resolved' : resolved]);
      expect(handler.playbackState.value.playing, isTrue);
    });
  }

  test('a file still arriving plays from its stream until whole', () async {
    final decks = <_Deck>[];
    final runtime = _runtime(decks: decks);
    final handler = await runtime.initialize();
    final arrived = Completer<void>();
    runtime.streamWhileArriving(
      '/one.flac',
      url: 'http://127.0.0.1:1/one.flac',
      done: arrived.future,
    );
    await handler.setQueueAndPlay([_track]);
    // Marked, so AVPlayer starts it without reading to its unwritten end.
    expect(decks.single.sources, ['arriving http://127.0.0.1:1/one.flac']);

    arrived.complete();
    await _settle();
    expect(runtime.arrivingFile('/one.flac'), isNull);
    await handler.skipToQueueItem(0);
    expect(decks.single.sources.last, '/one.flac');
  });

  test(
    'a received file that is gone plays as the phone sends it again',
    () async {
      final decks = <_Deck>[];
      final arrived = Completer<void>();
      late final MusicPlayerRuntime runtime;
      runtime = _runtime(
        decks: decks,
        recoverMissingFile: (path) async {
          // Fetching it again streams it as a phone song arriving does.
          runtime.streamWhileArriving(
            path,
            url: 'http://127.0.0.1:1/one.flac',
            done: arrived.future,
          );
          return 'http://127.0.0.1:1/one.flac';
        },
      );
      final handler = await runtime.initialize();
      await handler.setQueueAndPlay([_track]);
      expect(decks.single.sources, ['arriving http://127.0.0.1:1/one.flac']);
      expect(handler.playbackState.value.playing, isTrue);
      arrived.complete();
    },
  );

  test('a gone file no phone can send fails as unavailable', () async {
    final decks = <_Deck>[];
    final runtime = _runtime(
      decks: decks,
      recoverMissingFile: (_) async =>
          throw const LinkException('unavailable', 'No phone is connected'),
    );
    final handler = await runtime.initialize();
    await handler.setQueueAndPlay([_track]);
    expect(decks.single.sources, isEmpty);
    expect(
      handler.playbackState.value.errorMessage,
      contains('Audio file is unavailable'),
    );
  });

  test('denied or failed audio focus cannot resume a paused source', () async {
    final session = _Session();
    final decks = <_Deck>[];
    final handler = await _runtime(session: session, decks: decks).initialize();
    await handler.setQueueAndPlay([_track]);
    await handler.pause();
    session.focusGranted = false;
    await handler.play();
    expect(decks.single.state, PlaybackDeckState.paused);
    expect(handler.playbackState.value.playing, isFalse);

    session.activationError = PlatformException(code: 'focus-unavailable');
    await handler.play();
    expect(decks.single.state, PlaybackDeckState.paused);
    expect(handler.playbackState.value.playing, isFalse);

    session.activationError = null;
    session.focusGranted = true;
    await handler.play();
    expect(decks.single.state, PlaybackDeckState.playing);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test(
    'Android awaits foreground service acknowledgement before resuming',
    () async {
      final session = _Session();
      final decks = <_Deck>[];
      Completer<void>? promotion;
      final handler = await _runtime(
        session: session,
        decks: decks,
        isAndroid: true,
        synchronizePlaybackState: () async => promotion?.future,
      ).initialize();
      await handler.setQueueAndPlay([_track]);
      await handler.pause();
      session.activations.clear();
      promotion = Completer<void>();
      final resume = handler.play();
      await _settle();
      expect(session.activations, isEmpty);
      expect(decks.single.state, PlaybackDeckState.paused);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      promotion.complete();
      await resume;
      expect(session.activations, [true]);
      expect(decks.single.state, PlaybackDeckState.playing);

      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _settle();
      expect(decks.single.state, PlaybackDeckState.paused);
      session.activations.clear();
      promotion = Completer<void>();
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await _settle();
      expect(session.activations, isEmpty);
      expect(decks.single.state, PlaybackDeckState.paused);
      promotion.complete();
      await _settle();
      expect(session.activations, [true]);
      expect(decks.single.state, PlaybackDeckState.playing);
    },
  );

  test('pause cancels a resume awaiting foreground promotion', () async {
    final session = _Session();
    final decks = <_Deck>[];
    Completer<void>? promotion;
    final handler = await _runtime(
      session: session,
      decks: decks,
      isAndroid: true,
      synchronizePlaybackState: () async => promotion?.future,
    ).initialize();
    await handler.setQueueAndPlay([_track]);
    await handler.pause();
    session.activations.clear();
    promotion = Completer<void>();
    final resume = handler.play();
    await _settle();
    final pause = handler.pause();
    promotion.complete();
    await Future.wait([resume, pause]);
    expect(session.activations, isEmpty);
    expect(decks.single.state, PlaybackDeckState.paused);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test(
    'foreground promotion failure prevents audio focus and playback',
    () async {
      final session = _Session();
      final decks = <_Deck>[];
      final handler = await _runtime(
        session: session,
        decks: decks,
        isAndroid: true,
        synchronizePlaybackState: () async =>
            throw PlatformException(code: 'foreground-denied'),
      ).initialize();
      await handler.setQueueAndPlay([_track]);
      expect(session.activations, isEmpty);
      expect(decks.single.state, isNot(PlaybackDeckState.playing));
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test(
    'iOS restores controls across unlock/background without changing track',
    () async {
      const channel = MethodChannel(
        'com.ryanheise.audio_service.client.methods',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => calls.add(call));
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final session = _Session();
      final runtime = _runtime(isIOS: true, session: session);
      final handler = await runtime.initialize();
      await _settle();
      handler.mediaItem.add(_item);
      final state = PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 17),
      );
      handler.playbackState.add(state);
      final configurations = session.configurations;
      for (final lifecycle in [
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
      ]) {
        handler.didChangeAppLifecycleState(lifecycle);
        await _settle();
      }
      expect(session.configurations, configurations + 5);
      expect(session.activations, List.filled(5, true));
      expect(
        calls.map((call) => call.method),
        List.filled(5, 'refreshNowPlayingInfo'),
      );
      expect(handler.mediaItem.value, same(_item));
      expect(handler.playbackState.value, same(state));
    },
  );

  test(
    'iOS does not reclaim controls when paused, stopped or interrupted',
    () async {
      final session = _Session();
      final runtime = _runtime(isIOS: true, session: session);
      final handler = await runtime.initialize();
      await _settle();
      final configurations = session.configurations;
      await handler.restoreIosNowPlaying();
      handler.mediaItem.add(_item);
      handler.playbackState.add(
        PlaybackState(processingState: AudioProcessingState.ready),
      );
      await handler.restoreIosNowPlaying();
      handler.playbackState.add(PlaybackState(playing: true));
      await handler.restoreIosNowPlaying();
      expect(session.configurations, configurations);
      expect(session.activations, isEmpty);

      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _settle();
      await handler.restoreIosNowPlaying();
      expect(session.activations, isEmpty);
      await handler.dispose();
      await handler.restoreIosNowPlaying();
      expect(session.activations, isEmpty);
    },
  );

  test(
    'iOS recovery cannot activate audio after a pause during configuration',
    () async {
      final session = _Session();
      final handler = await _runtime(
        isIOS: true,
        session: session,
      ).initialize();
      await _settle();
      handler.mediaItem.add(_item);
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      session.configureBarrier = Completer<void>();
      final restore = handler.restoreIosNowPlaying();
      await _settle();
      await handler.pause();
      session.configureBarrier!.complete();
      await restore;
      expect(session.activations, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test('muted playback stays playing even with legacy pause setting', () async {
    final directory = await Directory.systemTemp.createTemp('muted-playback-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/song.flac',
    ).writeAsString('audio');
    final volume = StreamController<double>.broadcast();
    addTearDown(volume.close);
    final runtime = _runtime(
      settings: const AppSettings(playerMode: 'internal'),
      volumeChanges: volume.stream,
    );
    var warnings = 0;
    final notices = runtime.mutedPlaybackEvents.listen((_) => warnings++);
    addTearDown(notices.cancel);
    final handler = await runtime.initialize();
    volume.add(0);
    await _settle();
    await handler.setQueueAndPlay([
      PlayableMedia(id: 'muted', source: file.path, title: 'Muted', artist: ''),
    ]);
    await _settle();
    await _settle();
    expect(handler.mediaItem.value?.id, 'muted');
    expect(handler.playbackState.value.playing, isTrue);
    expect(warnings, 0);

    await handler.play();
    await _settle();
    expect(handler.playbackState.value.playing, isTrue);
    volume.add(0);
    await _settle();
    expect(handler.playbackState.value.playing, isTrue);
    expect(warnings, 0);

    volume.add(0.5);
    await _settle();
    volume.add(0);
    await _settle();
    await _settle();
    expect(handler.playbackState.value.playing, isTrue);
    expect(warnings, 0);
    await handler.pause();
    volume.add(0.5);
    await _settle();
    expect(handler.playbackState.value.playing, isFalse);
  });

  test(
    'position ticks skip listening updates while flushes retain time',
    () async {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = _Recorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 1, 23, 59, 50).add(elapsed),
      );
      final handler = await _runtime(recorder: recorder).initialize();
      handler.mediaItem.add(_item);
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      await _settle();
      final updates = recorder.updates;
      for (var tick = 1; tick <= 1200; tick++) {
        elapsed = Duration(milliseconds: tick * 500);
        handler.playbackState.add(
          handler.playbackState.value.copyWith(updatePosition: elapsed),
        );
        if (tick % 20 == 0) await recorder.flush();
      }
      await _settle();
      expect(recorder.updates, updates);
      expect(
        writes.fold<int>(0, (sum, delta) => sum + delta.milliseconds),
        600000,
      );
      expect(writes.fold<int>(0, (sum, delta) => sum + delta.plays), 1);
      expect(writes.first.day, '2026-10-01');
      expect(writes.first.milliseconds, 10000);
      expect(
        writes.skip(1).every((delta) => delta.day == '2026-10-02'),
        isTrue,
      );
    },
  );

  test(
    'listening transitions retain buffering, repeat and metadata semantics',
    () async {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = _Recorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 1, 23, 59, 50).add(elapsed),
      );
      final handler = await _runtime(recorder: recorder).initialize();
      Future<void> state(bool playing, AudioProcessingState processing) async {
        handler.playbackState.add(
          handler.playbackState.value.copyWith(
            playing: playing,
            processingState: processing,
          ),
        );
        await _settle();
      }

      handler.mediaItem.add(_item);
      await state(true, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 5);
      final beforeSeek = recorder.updates;
      handler.playbackState.add(
        handler.playbackState.value.copyWith(
          updatePosition: const Duration(minutes: 10),
        ),
      );
      await _settle();
      expect(recorder.updates, beforeSeek);
      await recorder.flush();
      await state(true, AudioProcessingState.buffering);
      elapsed += const Duration(seconds: 20);
      await state(false, AudioProcessingState.ready);
      await state(true, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 25);
      await state(false, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 10);
      await state(true, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 10);
      await state(false, AudioProcessingState.ready);
      await state(false, AudioProcessingState.completed);
      await state(true, AudioProcessingState.ready);
      elapsed += const Duration(seconds: 35);
      await recorder.flush();
      final beforeMetadata = recorder.updates;
      handler.mediaItem.add(_item.copyWith(title: 'Revised', artist: 'Guest'));
      await _settle();
      expect(recorder.updates, beforeMetadata + 1);
      expect(recorder.latestTrack?.title, 'Revised');
      expect(recorder.latestTrack?.artist, 'Guest');
      recorder.setEnabled(false);
      elapsed += const Duration(seconds: 25);
      await recorder.flush();
      recorder.setEnabled(true);
      elapsed += const Duration(seconds: 5);
      await recorder.flush();
      handler.mediaItem.add(const MediaItem(id: 'two', title: 'Two'));
      await _settle();
      elapsed += const Duration(seconds: 10);
      await recorder.flush();
      final one = writes.where((delta) => delta.track.key == 'one').toList();
      expect(one.fold<int>(0, (sum, delta) => sum + delta.milliseconds), 80000);
      expect(one.fold<int>(0, (sum, delta) => sum + delta.plays), 2);
      expect(one.first.day, '2026-10-01');
      expect(one.first.milliseconds, 5000);
      expect(one.skip(1).every((delta) => delta.day == '2026-10-02'), isTrue);
      expect(writes.last.track.key, 'two');
      expect(writes.last.milliseconds, 10000);
      expect(writes.last.plays, 0);
    },
  );

  test('listening flushes run only while there is time to write', () async {
    final time = VirtualTime();
    final writes = <int>[];
    var failNext = false;
    final recorder = _Recorder(
      write: (batch) async {
        if (failNext) {
          failNext = false;
          throw StateError('database is locked');
        }
        writes.add(batch.fold(0, (sum, delta) => sum + delta.milliseconds));
      },
      elapsed: () => time.now,
      now: () => DateTime(2026, 10, 1, 12).add(time.now),
    );
    await time.run(() async {
      final handler = await _runtime(recorder: recorder).initialize();
      Future<void> wait(int seconds) =>
          Future<void>.delayed(Duration(seconds: seconds));
      Future<void> playing(bool value) async {
        handler.playbackState.add(
          handler.playbackState.value.copyWith(
            playing: value,
            processingState: AudioProcessingState.ready,
          ),
        );
        await _settle();
      }

      int written() => writes.fold(0, (sum, value) => sum + value);
      // The real time the test itself takes is played time as well.
      Matcher about(int seconds) => closeTo(seconds * 1000, 2000);

      handler.mediaItem.add(_item);
      await _settle();
      await wait(60);
      expect(recorder.flushes, 0);

      await playing(true);
      await wait(35);
      expect(writes, hasLength(3));
      await playing(false);
      // Pausing writes the last five seconds and stops the timer.
      await wait(30);
      expect(written(), about(35));
      expect(writes, hasLength(4));
      final flushes = recorder.flushes;
      await wait(60);
      expect(recorder.flushes, flushes);

      // A failed write keeps the timer until a retry lands.
      await playing(true);
      await wait(5);
      failNext = true;
      await playing(false);
      expect(writes, hasLength(4));
      await wait(10);
      expect(writes, hasLength(5));
      expect(written(), about(40));
      final retried = recorder.flushes;
      await wait(60);
      expect(recorder.flushes, retried);
      await handler.dispose();
      expect(written(), about(40));
    });
  });

  test('a failed write by another caller is retried within 10 s', () async {
    final time = VirtualTime();
    final writes = <int>[];
    Completer<void>? hold;
    var calls = 0;
    final recorder = _Recorder(
      write: (batch) async {
        final call = ++calls;
        await hold?.future;
        if (call == 2) throw StateError('database is locked');
        writes.add(batch.fold(0, (sum, delta) => sum + delta.milliseconds));
      },
      elapsed: () => time.now,
      now: () => DateTime(2026, 10, 1, 12).add(time.now),
    );
    await time.run(() async {
      final handler = await _runtime(recorder: recorder).initialize();
      Future<void> wait(int seconds) =>
          Future<void>.delayed(Duration(seconds: seconds));
      Future<void> playing(bool value) async {
        handler.playbackState.add(
          handler.playbackState.value.copyWith(
            playing: value,
            processingState: AudioProcessingState.ready,
          ),
        );
        await _settle();
      }

      handler.mediaItem.add(_item);
      await playing(true);
      // The timer's write is still in flight when playback pauses and
      // another caller takes the last seconds; then that write fails.
      hold = Completer<void>();
      await wait(13);
      expect(calls, 1);
      await playing(false);
      unawaited(recorder.flush());
      final pending = hold!;
      hold = null;
      pending.complete();
      await wait(1);
      expect(writes, hasLength(1));
      expect(calls, 2);
      await wait(10);
      expect(writes, hasLength(2));
      expect(writes.last, closeTo(3000, 2000));
      await handler.dispose();
      expect(writes, hasLength(2));
    });
  });

  /// Plays [_track] on a [_TickingDeck] and sends [ticks] engine ticks on
  /// its interval, each reading the time played. [deliver] decides whether
  /// a tick reaches the handler. Returns the ticks the handler asked for,
  /// those it took longer than a quick platform reply to handle, those
  /// whose position it published or saved, and the time the ticks took.
  Future<
    ({
      Set<int> asked,
      Set<int> slow,
      List<int> published,
      Set<int> saved,
      Duration elapsed,
    })
  >
  tickPlayback(int ticks, {required bool Function(bool wanted) deliver}) async {
    final deck = _TickingDeck();
    final store = _PositionLog();
    var created = 0;
    final handler = await _runtime(
      createDeck: (_) => created++ == 0 ? deck : _Deck(),
      sessionDatabase: store,
    ).initialize();
    await handler.setQueueAndPlay([_track]);
    await _settle();
    final interval = deck.interval!;
    expect(interval, const Duration(milliseconds: 200));
    var tick = 0;
    final published = <int>[];
    var last = handler.playbackState.value.updatePosition;
    final subscription = handler.playbackState.listen((state) {
      if (state.updatePosition == last) return;
      last = state.updatePosition;
      published.add(tick);
    });
    final asked = <int>{};
    final slow = <int>{};
    final readAt = <int, int>{};
    final clock = Stopwatch()..start();
    for (tick = 1; tick <= ticks; tick++) {
      await Future<void>.delayed(interval);
      final askedAt = clock.elapsed;
      final wanted = deck.wanted?.call() ?? true;
      if (wanted) asked.add(tick);
      if (!deliver(wanted)) continue;
      deck.position = askedAt;
      readAt[deck.position.inMilliseconds] = tick;
      deck.positionEvents.add(deck.position);
      await _settle();
      if (clock.elapsed - askedAt > const Duration(milliseconds: 40)) {
        slow.add(tick);
      }
    }
    final elapsed = clock.elapsed;
    await subscription.cancel();
    return (
      asked: asked,
      slow: slow,
      published: published,
      saved: {for (final ms in store.positions) ?readAt[ms]},
      elapsed: elapsed,
    );
  }

  /// The most queries [elapsed] of ticks may make: the first tick, one per
  /// save, and per publish (at least 450 ms apart) one more when a late
  /// tick left the first ask just short of the gate, so at most one per
  /// 300 ms. Querying every 200 ms tick exceeds it; a loaded machine that
  /// spaces ticks further apart raises it.
  int queryBudget(Duration elapsed) =>
      elapsed.inMilliseconds ~/ 300 + elapsed.inSeconds ~/ 10 + 2;

  test(
    'position ticks ask the engine only for positions the player uses',
    () async {
      // Every tick reaches the handler, as it did when each one read the
      // engine; none of those the handler declines may be published or
      // saved. A reply slower than the query allowance is the one case
      // where a declined tick could have passed the gate.
      const ticks = 55;
      final run = await tickPlayback(ticks, deliver: (_) => true);
      expect(run.published.length, greaterThanOrEqualTo(ticks ~/ 3 - 1));
      expect(run.saved, isNotEmpty);
      final missed = {
        ...run.published,
        ...run.saved,
      }.difference(run.asked).difference(run.slow);
      expect(missed, isEmpty);
      expect(run.asked.length, lessThanOrEqualTo(queryBudget(run.elapsed)));
    },
  );

  test('a deck that skips declined ticks queries once per position', () async {
    final run = await tickPlayback(30, deliver: (wanted) => wanted);
    expect(run.published.length, greaterThanOrEqualTo(8));
    expect(run.asked.length, lessThanOrEqualTo(queryBudget(run.elapsed)));
  });

  test(
    'deletion subscriptions follow handler ownership and scoped overrides',
    () async {
      final events = SourceDeletionEvents();
      late MusicPlayerRuntime first;
      late MusicPlayerRuntime second;
      first = _runtime(
        sourceDeletionEvents: events,
        initialize: (_) async => _DeletionHandler(first),
      );
      second = _runtime(
        sourceDeletionEvents: events,
        initialize: (_) async => _DeletionHandler(second),
      );
      late MusicPlayerRuntime isolated;
      isolated = _runtime(initialize: (_) async => _DeletionHandler(isolated));
      final firstHandler = await first.initialize() as _DeletionHandler;
      final secondHandler = await second.initialize() as _DeletionHandler;
      final isolatedHandler = await isolated.initialize() as _DeletionHandler;
      first.attach(firstHandler); // Reattaching must not subscribe twice.
      await events.publish('/one.flac');
      expect(firstHandler.deletedSources, ['/one.flac']);
      expect(secondHandler.deletedSources, ['/one.flac']);
      expect(isolatedHandler.deletedSources, isEmpty);
      await firstHandler.dispose();
      final replacement = await first.initialize() as _DeletionHandler;
      await events.publish('/two.flac');
      expect(firstHandler.deletedSources, ['/one.flac']);
      expect(replacement.deletedSources, ['/two.flac']);
      expect(secondHandler.deletedSources, ['/one.flac', '/two.flac']);
      await first.dispose();
      await second.dispose();
      await events.publish('/three.flac');
      expect(replacement.deletedSources, ['/two.flac']);
      expect(secondHandler.deletedSources, ['/one.flac', '/two.flac']);
    },
  );

  test(
    'storage deletion removes duplicates and advances every attached player',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'queued-deletion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/one.flac',
      ).writeAsString('audio');
      final events = SourceDeletionEvents();
      final runtimes = [
        _runtime(sourceDeletionEvents: events),
        _runtime(sourceDeletionEvents: events),
      ];
      final removed = PlayableMedia(
        id: 'removed',
        source: file.path,
        title: 'Removed',
        artist: '',
      );
      for (final runtime in runtimes) {
        await (await runtime.initialize()).setQueueAndPlay([
          removed,
          removed,
          _track,
        ]);
      }
      expect(await deleteFile(file.path, deletionEvents: events), isTrue);
      for (final runtime in runtimes) {
        expect(runtime.handler!.queue.value.map((item) => item.id), ['one']);
        expect(runtime.handler!.mediaItem.value?.id, 'one');
        expect(runtime.handler!.playbackState.value.queueIndex, 0);
      }
    },
  );

  for (final hasSuccessor in [false, true]) {
    test('local deletion releases the decoder first ($hasSuccessor)', () async {
      final directory = await Directory.systemTemp.createTemp('open-deletion-');
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/song.flac',
      ).writeAsString('audio');
      final events = SourceDeletionEvents();
      final decks = <_Deck>[];
      final handler = await _runtime(
        decks: decks,
        sourceDeletionEvents: events,
      ).initialize();
      await handler.setQueueAndPlay([
        PlayableMedia(
          id: 'removed',
          source: file.path,
          title: 'Removed',
          artist: '',
        ),
        if (hasSuccessor) _track,
      ]);
      final playing = decks.single;
      var releasedBeforeDelete = false;
      playing.beforeDispose = () async {
        releasedBeforeDelete = await file.exists();
      };

      expect(await deleteFile(file.path, deletionEvents: events), isTrue);
      expect(releasedBeforeDelete, isTrue);
      expect(playing.disposals, 1);
      expect(handler.mediaItem.value?.id, hasSuccessor ? 'one' : null);
      expect(
        handler.queue.value.map((item) => item.id),
        hasSuccessor ? ['one'] : isEmpty,
      );
    });
  }

  test('failed decoder release keeps the current song resumable', () async {
    final directory = await Directory.systemTemp.createTemp('held-deletion-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/song.flac',
    ).writeAsString('audio');
    final events = SourceDeletionEvents();
    final decks = <_Deck>[];
    final handler = await _runtime(
      decks: decks,
      sourceDeletionEvents: events,
    ).initialize();
    await handler.setQueueAndPlay([
      PlayableMedia(id: 'held', source: file.path, title: 'Held', artist: ''),
    ]);
    decks.single.beforeDispose = () async => throw StateError('Release failed');
    expect(await deleteFile(file.path, deletionEvents: events), isFalse);
    expect(await file.exists(), isTrue);
    expect(handler.queue.value.single.id, 'held');
    expect(handler.mediaItem.value?.id, 'held');
    expect(handler.playbackState.value.playing, isFalse);
    await handler.play();
    expect(decks.last.sources, [file.path]);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test(
    'a rejected storage deletion retains the queue and resume position',
    () async {
      final events = SourceDeletionEvents();
      final handler = await _runtime(sourceDeletionEvents: events).initialize();
      await handler.setQueueAndPlay([_track]);
      await handler.seek(const Duration(seconds: 12));
      expect(await events.delete(_track.source, () async => false), isFalse);
      expect(handler.queue.value.single.id, 'one');
      expect(handler.playbackState.value.playing, isFalse);
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.position.inSeconds, 12);
    },
  );

  test(
    'Play cannot reopen the current file while deletion releases it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pending-release-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/song.flac',
      ).writeAsString('audio');
      final events = SourceDeletionEvents();
      final decks = <_Deck>[];
      final handler = await _runtime(
        decks: decks,
        sourceDeletionEvents: events,
      ).initialize();
      await handler.setQueueAndPlay([
        PlayableMedia(id: 'held', source: file.path, title: 'Held', artist: ''),
      ]);
      final entered = Completer<void>();
      final release = Completer<void>();
      decks.single.beforeDispose = () async {
        entered.complete();
        await release.future;
      };
      final deletion = deleteFile(file.path, deletionEvents: events);
      await entered.future;
      try {
        await handler.play();
        expect(await file.exists(), isTrue);
        expect(decks.single.sources, [file.path]);
      } finally {
        release.complete();
      }
      expect(await deletion, isTrue);
      expect(handler.mediaItem.value, isNull);
      expect(decks.last.sources, isEmpty);
    },
  );

  test(
    'deleting a duplicate current source selects its immediate successor',
    () async {
      final events = SourceDeletionEvents();
      final handler = await _runtime(sourceDeletionEvents: events).initialize();
      const next = PlayableMedia(
        id: 'next',
        source: '/next.flac',
        title: 'Next',
        artist: '',
      );
      const last = PlayableMedia(
        id: 'last',
        source: '/last.flac',
        title: 'Last',
        artist: '',
      );
      await handler.setQueueAndPlay([
        _track,
        _track,
        next,
        last,
      ], initialIndex: 1);
      await events.publish(_track.source);
      expect(handler.mediaItem.value?.id, 'next');
      expect(handler.playbackState.value.queueIndex, 0);
    },
  );

  test(
    'SAF deletion releases cached playback copies before returning',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cached-deletion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cached = await File(
        '${directory.path}/copy.flac',
      ).writeAsString('audio');
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'safCopyToTemp' => cached.path,
          'safDelete' => true,
          _ => null,
        },
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = SourceDeletionEvents();
      final runtime = _runtime(sourceDeletionEvents: events);
      final handler = await runtime.initialize();
      const source = 'content://test.provider/document/song.flac';
      const removed = PlayableMedia(
        id: 'removed',
        source: source,
        title: 'Removed',
        artist: '',
        artUri: 'https://example.com/cover.jpg',
      );
      await handler.setQueueAndPlay([removed, _track]);
      expect(await cached.exists(), isTrue);
      expect(await deleteFile(source, deletionEvents: events), isTrue);
      expect(await cached.exists(), isFalse);
      expect(handler.queue.value.map((item) => item.id), ['one']);
      expect(handler.mediaItem.value?.id, 'one');
    },
  );

  test('failed player stop cannot undo a confirmed storage deletion', () async {
    final directory = await Directory.systemTemp.createTemp('failed-reaction-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/song.flac',
    ).writeAsString('audio');
    final events = SourceDeletionEvents();
    final decks = <_Deck>[];
    final runtime = _runtime(decks: decks, sourceDeletionEvents: events);
    final handler = await runtime.initialize();
    await handler.setQueueAndPlay([
      PlayableMedia(
        id: 'removed',
        source: file.path,
        title: 'Removed',
        artist: '',
      ),
    ]);
    decks.single.failStop = true;
    expect(await deleteFile(file.path, deletionEvents: events), isTrue);
    expect(await file.exists(), isFalse);
    expect(handler.queue.value, isEmpty);
  });

  test(
    'deletion retires a pending SAF copy without blocking a later copy',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pending-deletion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final stale = await File(
        '${directory.path}/stale.flac',
      ).writeAsString('old');
      final replacement = await File(
        '${directory.path}/new.flac',
      ).writeAsString('new');
      final copying = Completer<void>();
      final release = Completer<String>();
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var copies = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'safDelete') return true;
        if (call.method != 'safCopyToTemp') return null;
        if (++copies > 1) return replacement.path;
        copying.complete();
        return release.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = SourceDeletionEvents();
      final handler = await _runtime(sourceDeletionEvents: events).initialize();
      const source = 'content://test.provider/document/pending.flac';
      const removed = PlayableMedia(
        id: 'removed',
        source: source,
        title: 'Removed',
        artist: '',
        artUri: 'https://example.com/cover.jpg',
      );
      final playing = handler.setQueueAndPlay([removed]);
      await copying.future;
      try {
        expect(
          await deleteFile(
            source,
            deletionEvents: events,
          ).timeout(const Duration(seconds: 1)),
          isTrue,
        );
        expect(handler.queue.value, isEmpty);
      } finally {
        release.complete(stale.path);
      }
      final restarted = handler.setQueueAndPlay([removed]);
      await playing;
      await restarted;
      expect(copies, 2);
      expect(await stale.exists(), isFalse);
      expect(await replacement.exists(), isTrue);
      expect(handler.mediaItem.value?.id, 'removed');
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test(
    'player metadata follows playback after restoring the last session',
    () async {
      final runtime = _runtime();
      final container = ProviderContainer(
        overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);
      final titles = <String?>[];
      final subscription = container.listen(currentMediaItemProvider, (
        _,
        next,
      ) {
        if (next.hasValue) titles.add(next.value?.title);
      });
      addTearDown(subscription.close);
      await container.read(currentMediaItemProvider.future);
      final handler = await runtime.initialize();
      const second = PlayableMedia(
        id: 'two',
        source: '/two.flac',
        title: 'Two',
        artist: 'Other',
        duration: Duration(seconds: 60),
      );
      await handler.restoreSession(
        items: [_track, second],
        index: 0,
        position: const Duration(seconds: 15),
        shuffle: false,
      );
      await container.pump();
      expect(titles.last, 'One');
      final controller = container.read(musicPlayerControllerProvider);
      await controller.next();
      await container.pump();
      expect(handler.playbackState.value.playing, isTrue);
      expect(titles.last, 'Two');

      await controller.playSingle(_track);
      await container.pump();
      expect(handler.playbackState.value.playing, isTrue);
      expect(titles.last, 'One');
      expect(
        container.read(currentMediaItemProvider).value?.extras?['source'],
        _track.source,
      );
    },
  );

  test(
    'Library shuffle queues downloads and scanned songs in Library order',
    () async {
      const added = '2026-01-01T00:00:00.000Z';
      Map<String, dynamic> row(int i) => {
        'source': i.isEven ? 'downloaded' : 'local',
        'item': {
          'id': 'song-$i',
          'trackName': 'Song $i',
          'artistName': 'Artist',
          'albumName': 'Album',
          // One scanned row has no file to play.
          'filePath': i == 1 ? '' : '/song-$i.flac',
          if (i.isEven) ...{'service': 'extension', 'downloadedAt': added},
          if (i.isOdd) 'scannedAt': added,
        },
      };
      // More than one page of 1,000 songs.
      final library = _QueueLibrary([for (var i = 0; i < 1001; i++) row(i)]);
      final runtime = _runtime(
        settings: const AppSettings(localLibraryEnabled: true),
        libraryDatabase: library,
      );
      final container = ProviderContainer(
        overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
      );
      addTearDown(container.dispose);
      final controller = container.read(musicPlayerControllerProvider);

      expect(await controller.shuffleLibrary(), isTrue);
      expect(library.requests.map((request) => request.offset), [0, 1000]);
      expect(library.requests.every((request) => request.includeLocal), true);
      final handler = runtime.handler!;
      final libraryOrder = [
        for (var i = 0; i < 1001; i++)
          if (i != 1) 'song-$i',
      ];
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      expect(handler.queue.value.first.id, handler.mediaItem.value?.id);
      expect(
        handler.queue.value.map((item) => item.id).toSet(),
        libraryOrder.toSet(),
      );

      await controller.setShuffle(false);
      expect(handler.queue.value.map((item) => item.id), libraryOrder);
    },
  );

  test('shuffling an artist plays only the songs that credit them', () async {
    final added = DateTime(2026).toIso8601String();
    Map<String, Object?> row(String id, String artist) => {
      'source': 'downloaded',
      'item': {
        'id': id,
        'trackName': id,
        'artistName': artist,
        'albumName': 'Album',
        'filePath': '/$id.flac',
        'service': 'extension',
        'downloadedAt': added,
      },
    };
    final runtime = _runtime(
      settings: const AppSettings(),
      libraryDatabase: _QueueLibrary([
        row('solo', 'First Artist'),
        row('duet', 'Second Artist, first artist'),
        row('other', 'Second Artist'),
      ]),
    );
    final container = ProviderContainer(
      overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
    );
    addTearDown(container.dispose);
    final controller = container.read(musicPlayerControllerProvider);

    expect(await controller.shuffleLibrary(artist: 'Missing Artist'), isFalse);
    expect(await controller.shuffleLibrary(artist: 'First Artist'), isTrue);
    expect(runtime.handler!.queue.value.map((item) => item.id).toSet(), {
      'solo',
      'duet',
    });
  });

  test('a media browser plays the album a song was chosen from', () async {
    final runtime = _runtime(
      libraryDatabase: _BrowsedLibrary(),
      historyDatabase: _NoHistory(),
    );
    final handler = await runtime.initialize();

    final album = (await handler.getChildren(
      MediaLibraryBrowser.albumsId,
    )).single;
    final songs = await handler.getChildren(album.id);
    expect(
      [for (final song in songs) song.title],
      ['Song a', 'Song b', 'Song c'],
    );
    await handler.playFromMediaId(songs[1].id);

    expect(handler.queue.value.map((item) => item.id), ['a', 'b', 'c']);
    expect(handler.mediaItem.value?.id, 'b');
    expect(
      handler.playbackState.value.shuffleMode,
      AudioServiceShuffleMode.none,
    );
    // Media resumption offers the song that plays.
    expect(
      (await handler.getChildren(
        AudioService.recentRootId,
      )).map((item) => item.id),
      ['b'],
    );
    // Queue items still play by their own ids.
    await handler.playFromMediaId('c');
    expect(handler.mediaItem.value?.id, 'c');
  });

  test(
    'a spoken request plays what it names and resumes without words',
    () async {
      final runtime = _runtime(
        libraryDatabase: _BrowsedLibrary(),
        historyDatabase: _NoHistory(),
      );
      final handler = await runtime.initialize();

      await handler.playFromSearch('song b');
      expect(handler.queue.value.map((item) => item.id), ['b']);
      expect(handler.playbackState.value.playing, isTrue);

      await handler.pause();
      await handler.playFromSearch('');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.queue.value.map((item) => item.id), ['b']);
    },
  );

  test('the star loves songs until the app shell takes it over', () async {
    final loved = _Loved();
    final runtime = _runtime(
      libraryDatabase: _BrowsedLibrary(),
      historyDatabase: _NoHistory(),
      collectionsDatabase: loved,
    );
    String keyFor(String id) => trackCollectionKey(
      UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem.fromJson(_BrowsedLibrary.song(id, 1)),
      ).toTrack(),
    );
    final dependencies = runtime.dependencies;
    runtime.configureBackgroundNotification(
      presentation: const PlaybackNotification(),
      favorites: BackgroundFavorites(
        library: dependencies.libraryDatabase,
        history: dependencies.historyDatabase,
        collections: loved,
      ),
    );
    final handler = await runtime.initialize();
    final album = (await handler.getChildren(
      MediaLibraryBrowser.albumsId,
    )).single;
    await handler.playFromMediaId(
      (await handler.getChildren(album.id)).first.id,
    );

    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(loved.keys, {keyFor('a')});
    expect(runtime.notification.mediaId, 'a');
    expect(runtime.notification.loved, isTrue);

    // A song loved earlier shows a filled star when it starts.
    loved.keys.add(keyFor('b'));
    await handler.skipToNext();
    await pumpEventQueue();
    expect(runtime.notification.mediaId, 'b');
    expect(runtime.notification.loved, isTrue);

    final shellToggles = <String>[];
    runtime.configureNotification(
      presentation: const PlaybackNotification(),
      toggleFavorite: (item) async {
        shellToggles.add(item.id);
        return false;
      },
    );
    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(shellToggles, ['b']);
    expect(loved.keys, contains(keyFor('b')));
    await handler.skipToNext();
    await pumpEventQueue();
    // The background binding no longer follows the playing song.
    expect(runtime.notification.mediaId, 'b');
    expect(runtime.notification.loved, isFalse);
  });

  test(
    'pre-init events have empty values and cancellation never waits for init',
    () async {
      var calls = 0;
      final runtime = _runtime(
        initialize: (builder) async {
          calls++;
          return builder();
        },
      );
      final items = <MediaItem?>[];
      final queues = <List<MediaItem>>[];
      final states = <PlaybackState>[];
      final itemEvents = runtime.mediaItemEvents().listen(items.add);
      final queueEvents = runtime.queueEvents().listen(queues.add);
      final stateEvents = runtime.playbackStateEvents().listen(states.add);
      await _settle();

      expect(items, [null]);
      expect(queues, [isEmpty]);
      expect(states, isEmpty);
      await Future.wait([
        itemEvents.cancel(),
        queueEvents.cancel(),
        stateEvents.cancel(),
      ]).timeout(const Duration(seconds: 1));
      expect(calls, 0);
      await runtime.initialize();
      await _settle();
      expect(items, [null]);
      expect(queues, [isEmpty]);
      expect(states, isEmpty);
    },
  );

  test(
    'pending init is deduplicated and uses the latest live configuration',
    () async {
      final ready = Completer<MusicPlayerHandler>();
      final volume = StreamController<double>.broadcast();
      addTearDown(volume.close);
      var calls = 0;
      late MusicPlayerHandler created;
      final runtime = _runtime(
        volumeChanges: volume.stream,
        initialize: (builder) {
          calls++;
          created = builder();
          return ready.future;
        },
      );
      final items = <MediaItem?>[];
      final events = runtime.mediaItemEvents().listen(items.add);
      addTearDown(events.cancel);
      runtime.configure(runtime.settings.copyWith(autoMix: true));
      final first = runtime.initialize();
      expect(runtime.initialize(), same(first));
      await _settle();
      expect(calls, 1);
      expect(runtime.handler, isNull);
      expect(volume.hasListener, isFalse);
      runtime.configure(runtime.settings.copyWith());
      created.mediaItem.add(_item);
      await _settle();
      expect(volume.hasListener, isFalse);
      expect(items, [null]);
      ready.complete(created);
      expect(await first, same(created));
      expect(await runtime.initialize(), same(created));
      await _settle();
      expect(items, [null, _item]);
      expect(calls, 1);
      expect(runtime.settings.autoMix, isTrue);
      await runtime.dispose();
      expect(volume.hasListener, isFalse);
    },
  );

  test('failed initialization releases its handler and can retry', () async {
    var calls = 0;
    final decks = <_Deck>[];
    final runtime = _runtime(
      decks: decks,
      initialize: (builder) async {
        final handler = builder();
        if (++calls == 1) throw StateError('Initialization failed');
        return handler;
      },
    );
    await expectLater(runtime.initialize(), throwsStateError);
    expect(
      LogBuffer().entries.any(
        (entry) =>
            entry.tag == 'MusicPlayerRuntime' &&
            entry.level == 'ERROR' &&
            entry.message == 'Failed to initialize playback' &&
            entry.error?.contains('Initialization failed') == true,
      ),
      isTrue,
    );
    expect(runtime.handler, isNull);
    expect(decks.single.disposals, 1);
    final retried = await runtime.initialize();
    expect(runtime.handler, same(retried));
    expect(calls, 2);
    await runtime.dispose();
    expect(decks.map((deck) => deck.disposals), [1, 1]);
  });

  test(
    'deck construction failure leaves no partial handler and can retry',
    () async {
      var calls = 0;
      final deck = _Deck();
      final runtime = _runtime(
        createDeck: (_) {
          if (++calls == 1) throw StateError('Deck creation failed');
          return deck;
        },
      );
      await expectLater(runtime.initialize(), throwsStateError);
      expect(runtime.handler, isNull);
      final handler = await runtime.initialize();
      expect(runtime.handler, same(handler));
      expect(calls, 2);
      await runtime.dispose();
      expect(deck.disposals, 1);
    },
  );

  test('an initializer returning a disposed handler can retry', () async {
    var calls = 0;
    final runtime = _runtime(
      initialize: (builder) async {
        final handler = builder();
        if (++calls == 1) await handler.dispose();
        return handler;
      },
    );
    await expectLater(runtime.initialize(), throwsStateError);
    final handler = await runtime.initialize();
    expect(runtime.handler, same(handler));
    expect(handler.isDisposed, isFalse);
    expect(calls, 2);
  });

  test(
    'runtime disposal retires a pending handler and closes its events',
    () async {
      final ready = Completer<MusicPlayerHandler>();
      final decks = <_Deck>[];
      late MusicPlayerHandler created;
      final runtime = _runtime(
        decks: decks,
        initialize: (builder) {
          created = builder();
          return ready.future;
        },
      );
      final closed = Completer<void>();
      final events = runtime.mediaItemEvents().listen(
        (_) {},
        onDone: closed.complete,
      );
      addTearDown(events.cancel);
      final pending = runtime.initialize();
      final failed = expectLater(pending, throwsStateError);
      await _settle();
      final disposed = runtime.dispose();
      expect(runtime.dispose(), same(disposed));
      expect(created.isDisposed, isTrue);
      expect(runtime.handler, isNull);
      ready.complete(created);
      await failed;
      await disposed;
      await closed.future.timeout(const Duration(seconds: 1));
      expect(decks.single.disposals, 1);
      await expectLater(runtime.initialize(), throwsStateError);
    },
  );

  test(
    'a delayed builder cannot create playback resources after disposal',
    () async {
      final build = Completer<void>();
      final decks = <_Deck>[];
      final runtime = _runtime(
        decks: decks,
        initialize: (builder) async {
          await build.future;
          return builder();
        },
      );
      final failed = expectLater(runtime.initialize(), throwsStateError);
      await _settle();
      final disposed = runtime.dispose();
      build.complete();
      await failed;
      await disposed;
      expect(runtime.handler, isNull);
      expect(decks, isEmpty);
    },
  );

  test(
    'event subscribers follow a replacement and ignore the retired handler',
    () async {
      final runtime = _runtime();
      final items = <MediaItem?>[];
      final queues = <List<MediaItem>>[];
      final itemEvents = runtime.mediaItemEvents().listen(items.add);
      final queueEvents = runtime.queueEvents().listen(queues.add);
      addTearDown(itemEvents.cancel);
      addTearDown(queueEvents.cancel);
      final first = await runtime.initialize();
      first.mediaItem.add(_item);
      first.queue.add([_item]);
      await _settle();
      expect(items.last, _item);
      expect(queues.last, [_item]);
      await first.dispose();
      await _settle();
      expect(items.last, isNull);
      expect(queues.last, isEmpty);
      first.mediaItem.add(const MediaItem(id: 'stale', title: 'Stale'));
      first.queue.add([_item]);
      final second = await runtime.initialize();
      const replacement = MediaItem(id: 'two', title: 'Two');
      second.mediaItem.add(replacement);
      second.queue.add([replacement]);
      await _settle();
      expect(items.last, replacement);
      expect(queues.last, [replacement]);
      expect(items.whereType<MediaItem>().map((item) => item.id), [
        'one',
        'two',
      ]);
    },
  );

  test(
    'provider scopes isolate transport settings and notification favorites',
    () async {
      final firstDecks = <_Deck>[];
      final secondDecks = <_Deck>[];
      final first = _runtime(
        decks: firstDecks,
        settings: const AppSettings(playbackNormalization: true),
      );
      final second = _runtime(
        decks: secondDecks,
        settings: const AppSettings(
          usbBitPerfect: true,
          usbDirect: true,
          usbDsdOverPcm: true,
          usbAllowFixedVolume: true,
          dapExclusive: true,
        ),
      );
      final containers = [
        for (final runtime in [first, second])
          ProviderContainer(
            overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
          ),
      ];
      for (final container in containers) {
        addTearDown(container.dispose);
        await container.read(musicPlayerControllerProvider).playSingle(_track);
      }
      expect(firstDecks.single.state, PlaybackDeckState.playing);
      expect(secondDecks.single.state, PlaybackDeckState.playing);
      expect(firstDecks.single.volumes.last, closeTo(0.501, 0.001));
      expect(secondDecks.single.volumes.last, 1);
      expect(firstDecks.single.outputOptions!.values, everyElement(isFalse));
      expect(secondDecks.single.outputOptions!.values, everyElement(isTrue));
      final toggled = <String>[];
      first.configureNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          toggled.add('first:${item.id}');
          return true;
        },
      );
      second.configureNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          toggled.add('second:${item.id}');
          return false;
        },
      );
      await first.handler!.customAction(PlaybackNotification.favoriteAction);
      expect(first.notification.loved, isTrue);
      expect(second.notification.loved, isFalse);
      await second.handler!.customAction(PlaybackNotification.favoriteAction);
      expect(toggled, ['first:one', 'second:one']);
      expect(
        first.handler!.playbackState.value.controls.first.label,
        'Remove from favorites',
      );
      expect(
        second.handler!.playbackState.value.controls.first.label,
        'Favorite',
      );
      // A pre-amp change reaches the playing track without a restart.
      first.configure(first.settings.copyWith(playbackNormalizationPreamp: -6));
      await _settle();
      expect(firstDecks.single.volumes.last, closeTo(0.251, 0.001));
      first.configure(first.settings.copyWith(playbackNormalization: false));
      await _settle();
      expect(firstDecks.single.volumes.last, 1);
      expect(second.settings.usbBitPerfect, isTrue);
      expect(secondDecks.single.volumes, [1]);
    },
  );

  group('network covers', () {
    const cover = 'network://nas/Album/cover.jpg';
    const song = PlayableMedia(
      id: 'nas-song',
      source: 'network://nas/Album/01.flac',
      title: 'Song',
      artist: 'Artist',
      networkArtworkSource: cover,
    );
    late Directory directory;
    late List<String> fetched;
    late CoverStore covers;
    var version = 0;
    var tokens = 0;

    CoverStore store() => CoverStore(
      directory: () async => directory,
      fetch: (ref, output) async {
        fetched.add(ref);
        await output.writeAsBytes([
          0xFF,
          0xD8,
          0xFF,
          version,
          ...ref.codeUnits,
        ]);
      },
    );

    // Each audio resolve hands out a new loopback URL, as the proxy does.
    Future<String> resolve(String _) async => 'http://127.0.0.1:1/${++tokens}';

    Future<MediaItem> shown(
      MusicPlayerHandler handler,
      bool Function(MediaItem item) test,
    ) => handler.mediaItem
        .firstWhere((item) => item != null && test(item))
        .timeout(const Duration(seconds: 5))
        .then((item) => item!);

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 500 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('player-covers-');
      fetched = [];
      version = 0;
      tokens = 0;
      covers = store();
      addTearDown(() async {
        await covers.dispose();
        await directory.delete(recursive: true);
      });
    });

    test(
      'a stored cover shows from the first item, the same every play',
      () async {
        final stored = Uri.file((await covers.file(cover))!);
        fetched.clear();
        final handler = await _runtime(
          coverStore: covers,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {},
        ).initialize();
        final covered = <Uri?>[];
        final subscription = handler.mediaItem.listen((item) {
          if (item != null) covered.add(item.artUri);
        });
        addTearDown(subscription.cancel);

        await handler.setQueueAndPlay([song]);
        await _settle();
        await handler.setQueueAndPlay([song]);
        await _settle();
        expect(covered, isNotEmpty);
        expect(covered, everyElement(stored));
        expect(handler.queue.value.single.artUri, stored);
        expect(handler.mediaItem.value!.extras!['artworkRef'], cover);
        // Only the audio is resolved; the stored cover is not fetched again.
        expect(tokens, 2);
        expect(fetched, isEmpty);
      },
    );

    test(
      'scanned Library covers survive shuffled skips and restored order',
      () async {
        final songs = [
          for (var i = 0; i < 4; i++)
            playableFromLocal(
              LocalLibraryItem(
                id: 'scanned-$i',
                trackName: 'Song $i',
                artistName: 'Artist',
                albumName: 'Album',
                filePath: 'network://nas/Album/$i.flac',
                coverPath: 'network://nas/Album/$i.jpg',
                scannedAt: DateTime(2026),
              ),
            ),
        ];
        for (final media in songs) {
          await covers.file(media.coverReference!);
        }
        final handler = await _runtime(
          coverStore: covers,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {},
        ).initialize();
        await handler.setQueueAndPlay(songs, shuffle: true);
        for (var i = 0; i < songs.length; i++) {
          await handler.skipToQueueItem(i);
          final item = handler.mediaItem.value!;
          final reference = item.extras!['artworkRef'] as String;
          expect(item.artUri!.toFilePath(), covers.indexedFile(reference));
          expect(handler.queue.value[i].artUri, item.artUri);
        }
        await handler.setShuffleMode(AudioServiceShuffleMode.none);
        expect(
          handler.queue.value.map((item) => item.id),
          songs.map((s) => s.id),
        );
        for (final item in handler.queue.value) {
          expect(
            item.artUri!.toFilePath(),
            covers.indexedFile(item.extras!['artworkRef'] as String),
          );
        }
      },
    );

    test(
      'a cover not stored yet shows once fetched, with the next three ahead',
      () async {
        final songs = [
          for (var i = 0; i < 6; i++)
            PlayableMedia(
              id: 'nas-$i',
              source: 'network://nas/Album/0$i.flac',
              title: 'Song $i',
              artist: 'Artist',
              networkArtworkSource: 'network://nas/Album/$i.jpg',
            ),
        ];
        final handler = await _runtime(
          coverStore: covers,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {},
        ).initialize();
        await handler.setQueueAndPlay(songs);
        final item = await shown(handler, (item) => item.artUri != null);
        expect(
          item.artUri!.toFilePath(),
          covers.indexedFile(songs.first.networkArtworkSource),
        );
        await until(
          () =>
              handler.queue.value.where((row) => row.artUri != null).length ==
              4,
        );
        expect(
          fetched,
          unorderedEquals([
            for (final song in songs.take(4)) song.networkArtworkSource,
          ]),
        );
        final queue = handler.queue.value;
        for (final (i, row) in queue.indexed) {
          expect(row.extras!['artworkRef'], songs[i].networkArtworkSource);
          expect(
            row.artUri?.toFilePath(),
            i < 4 ? covers.indexedFile(songs[i].networkArtworkSource) : isNull,
          );
        }

        // A skip shows the cover fetched ahead at once.
        await handler.skipToNext();
        expect(handler.mediaItem.value!.artUri, queue[1].artUri);
        await until(() => fetched.length == 5);
        expect(fetched.last, songs[4].networkArtworkSource);
      },
    );

    test(
      'a changed cover of the playing song replaces it, others wait',
      () async {
        final events = SourceMetadataEvents();
        final songs = [
          for (var i = 0; i < 6; i++)
            PlayableMedia(
              id: 'nas-$i',
              source: 'network://nas/Album/0$i.flac',
              title: 'Song $i',
              artist: 'Artist',
              networkArtworkSource: 'network://nas/Album/$i.jpg',
            ),
        ];
        final handler = await _runtime(
          coverStore: covers,
          sourceMetadataEvents: events,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {},
        ).initialize();
        await handler.setQueueAndPlay(songs);
        final before = await shown(handler, (item) => item.artUri != null);
        await until(() => fetched.length == 4);

        // As a library job reports every song it changed: queued songs past
        // the fetched ones, and songs not queued, fetch nothing.
        version = 1;
        for (final song in songs.skip(4)) {
          await events.publish(song.source);
        }
        await events.publish('network://nas/Album/elsewhere.flac');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(fetched, hasLength(4));

        await events.publish(songs.first.source);
        final after = await shown(
          handler,
          (item) => item.artUri != before.artUri,
        );
        expect(
          after.artUri!.toFilePath(),
          covers.indexedFile(songs.first.networkArtworkSource),
        );
        expect(handler.queue.value.first.artUri, after.artUri);
        expect(fetched, hasLength(5));
      },
    );

    test(
      'a network:// artwork shows as its stored file, never as itself',
      () async {
        // As Home plays a song listening statistics kept.
        const recorded = PlayableMedia(
          id: 'nas-recorded',
          source: 'network://nas/Album/03.flac',
          title: 'Three',
          artist: 'Artist',
          artUri: cover,
        );
        expect(recorded.coverReference, cover);
        final handler = await _runtime(
          coverStore: covers,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {},
        ).initialize();
        final covered = <Uri?>[];
        final subscription = handler.mediaItem.listen((item) {
          if (item != null) covered.add(item.artUri);
        });
        addTearDown(subscription.cancel);
        await handler.setQueueAndPlay([recorded]);
        final item = await shown(handler, (item) => item.artUri != null);
        expect(item.artUri!.toFilePath(), covers.indexedFile(cover));
        expect(item.extras!['artworkRef'], cover);
        expect(fetched, [cover]);
        expect(covered.whereType<Uri>(), everyElement(item.artUri));
        expect(handler.queue.value.single.artUri, item.artUri);
      },
    );

    test(
      'listening keeps the cover reference, never a loopback or temporary file',
      () async {
        final recorder = _Recorder(
          write: (_) async {},
          elapsed: () => Duration.zero,
          now: () => DateTime(2026),
        );
        final handler = await _runtime(
          coverStore: covers,
          recorder: recorder,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {},
        ).initialize();
        await handler.setQueueAndPlay([song]);
        await shown(handler, (item) => item.artUri != null);
        await _settle();
        expect(recorder.latestTrack?.artwork, cover);

        for (final artwork in [
          Uri.parse('http://127.0.0.1:41234/2f6d1c'),
          Uri.file(p.join(directory.path, 'network_metadata', 'a.image')),
          Uri.file(p.join(Directory.systemTemp.path, 'a.jpg')),
        ]) {
          handler.mediaItem.add(
            MediaItem(id: 'other', title: 'Other', artUri: artwork),
          );
          await _settle();
          expect(recorder.latestTrack?.artwork, isNull, reason: '$artwork');
        }
        handler.mediaItem.add(
          MediaItem(
            id: 'web',
            title: 'Web',
            artUri: Uri.parse('https://example.test/cover.jpg'),
          ),
        );
        await _settle();
        expect(recorder.latestTrack?.artwork, 'https://example.test/cover.jpg');
      },
    );

    test(
      'a tag cover read to a temporary file is stored before the session keeps it',
      () async {
        final temporary = await Directory.systemTemp.createTemp('nas-tags-');
        addTearDown(() => temporary.delete(recursive: true));
        final tagCover =
            File(p.join(temporary.path, 'network_metadata', 'tags.image'))
              ..createSync(recursive: true)
              ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 1]);
        var title = 'Tagged';
        final events = SourceMetadataEvents();
        final session = _ResumeSessionStore();
        final recorder = _Recorder(
          write: (_) async {},
          elapsed: () => Duration.zero,
          now: () => DateTime(2026),
        );
        final handler = await _runtime(
          coverStore: covers,
          recorder: recorder,
          sessionDatabase: session,
          sourceMetadataEvents: events,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {
            'title': title,
            'cover_path': tagCover.path,
          },
        ).initialize();
        const tagged = PlayableMedia(
          id: 'nas-tagged',
          source: 'network://nas/Album/02.flac',
          title: 'Two',
          artist: 'Artist',
        );
        final reference = CoverStore.songCoverReference(tagged.source);
        await handler.setQueueAndPlay([tagged]);
        final first = await shown(handler, (item) => item.title == 'Tagged');
        expect(first.artUri!.toFilePath(), covers.indexedFile(reference));
        await _settle();
        // Statistics keep the tag cover's reference, not a store file.
        expect(recorder.latestTrack?.artwork, reference);

        // A tag edit stores the new cover. The session keeps neither file:
        // the store finds the song's tag cover by its source.
        tagCover.writeAsBytesSync([0xFF, 0xD8, 0xFF, 2]);
        title = 'Retagged';
        await events.publish(tagged.source);
        final edited = await shown(handler, (item) => item.title == title);
        final path = edited.artUri!.toFilePath();
        expect(path, isNot(first.artUri!.toFilePath()));
        expect(path, covers.indexedFile(reference));
        expect(p.isWithin(directory.path, path), isTrue);
        expect(handler.queue.value.single.artUri, edited.artUri);
        await until(
          () =>
              ((session.active?['media'] as List?)?.single as Map?)?['title'] ==
              title,
        );
        final saved = (session.active!['media'] as List).single as Map;
        expect(saved.containsKey('artUri'), isFalse);
        expect('${session.active}', isNot(contains(temporary.path)));
        await tagCover.delete();
        expect(File(path).readAsBytesSync(), [0xFF, 0xD8, 0xFF, 2]);

        final restarted = store();
        addTearDown(restarted.dispose);
        final restored = await _runtime(
          coverStore: restarted,
          resolveNetworkSource: resolve,
        ).initialize();
        await restored.restoreSession(
          items: [PlayableMedia.fromJson(Map<String, dynamic>.from(saved))!],
          index: 0,
          position: Duration.zero,
          shuffle: false,
        );
        expect(restored.mediaItem.value!.artUri, edited.artUri);
      },
    );

    test(
      'a known tag cover wins over the folder cover on every later play',
      () async {
        final stored = Uri.file((await covers.file(cover))!);
        fetched.clear();
        final temporary = await Directory.systemTemp.createTemp('nas-tags-');
        addTearDown(() => temporary.delete(recursive: true));
        final tagCover =
            File(p.join(temporary.path, 'network_metadata', 'tags.image'))
              ..createSync(recursive: true)
              ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 7]);
        final recorder = _Recorder(
          write: (_) async {},
          elapsed: () => Duration.zero,
          now: () => DateTime(2026),
        );
        final handler = await _runtime(
          coverStore: covers,
          recorder: recorder,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {'cover_path': tagCover.path},
        ).initialize();
        final tags = CoverStore.songCoverReference(song.source);
        final first = <Uri?>[];
        final firstPlay = handler.mediaItem.listen((item) {
          if (item != null) first.add(item.artUri);
        });

        // The folder cover shows only until the tags are read.
        await handler.setQueueAndPlay([song]);
        final tagged = await shown(
          handler,
          (item) => item.artUri != null && item.artUri != stored,
        );
        await firstPlay.cancel();
        expect(first.first, stored);
        expect(
          first.skipWhile((uri) => uri == stored),
          everyElement(tagged.artUri),
        );
        expect(tagged.artUri!.toFilePath(), covers.indexedFile(tags));
        expect(tagged.extras!['artworkRef'], cover);
        expect(handler.queue.value.single.artUri, tagged.artUri);
        await _settle();
        expect(recorder.latestTrack?.artwork, tags);

        // A changed folder cover does not replace it.
        version = 1;
        covers.invalidate(cover);
        await covers.file(cover);
        await until(() => covers.indexedFile(cover) != stored.toFilePath());
        await _settle();
        expect(handler.mediaItem.value!.artUri, tagged.artUri);
        expect(handler.queue.value.single.artUri, tagged.artUri);

        // A later play shows it from its first item, and fetches no folder.
        final covered = <Uri?>[];
        final subscription = handler.mediaItem.listen((item) {
          if (item != null) covered.add(item.artUri);
        });
        addTearDown(subscription.cancel);
        final fetches = fetched.length;
        await handler.setQueueAndPlay([song]);
        await _settle();
        expect(covered, everyElement(tagged.artUri));
        expect(fetched, hasLength(fetches));
      },
    );

    test('a tag read without a cover keeps the stored one', () async {
      // A Subsonic song played from the Library: its cover comes with its
      // tags, and a failed cover request leaves it out of them.
      final temporary = await Directory.systemTemp.createTemp('nas-tags-');
      addTearDown(() => temporary.delete(recursive: true));
      final thumbnail = File(p.join(temporary.path, 'thumbnail.jpg'))
        ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 3]);
      final served =
          File(p.join(temporary.path, 'network_metadata', 'subsonic.image'))
            ..createSync(recursive: true)
            ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 4]);
      final library = PlayableMedia(
        id: 'library-s1',
        source: NetworkStorageService.source(
          'nas',
          subsonicSongPath('s1', 'flac'),
        ),
        title: 'One',
        artist: 'Artist',
        artUri: thumbnail.path,
      );
      var tags = <String, dynamic>{'cover_path': served.path};
      final events = SourceMetadataEvents();
      final handler = await _runtime(
        coverStore: covers,
        sourceMetadataEvents: events,
        resolveNetworkSource: resolve,
        readNetworkMetadata: (_) async => tags,
      ).initialize();
      final reference = CoverStore.songCoverReference(library.source);
      await handler.setQueueAndPlay([library]);
      final adopted = await shown(
        handler,
        (item) => item.artUri?.toFilePath() == covers.indexedFile(reference),
      );

      tags = {};
      await events.publish(library.source);
      await handler.setQueueAndPlay([library]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(covers.indexedFile(reference), adopted.artUri!.toFilePath());
      expect(File(adopted.artUri!.toFilePath()).existsSync(), isTrue);
      expect(handler.mediaItem.value!.artUri, adopted.artUri);
      expect(handler.queue.value.single.artUri, adopted.artUri);
    });

    test('an older or orphaned tag read changes nothing', () async {
      final temporary = await Directory.systemTemp.createTemp('nas-tags-');
      addTearDown(() => temporary.delete(recursive: true));
      File tagCover(int version) =>
          File(p.join(temporary.path, 'network_metadata', '$version.image'))
            ..createSync(recursive: true)
            ..writeAsBytesSync([0xFF, 0xD8, 0xFF, version]);
      final first = tagCover(1);
      final second = tagCover(2);
      final reads = <Completer<Map<String, dynamic>>>[];
      var held = false;
      final handler = await _runtime(
        coverStore: covers,
        resolveNetworkSource: resolve,
        readNetworkMetadata: (_) {
          if (!held) return Future.value({});
          final read = Completer<Map<String, dynamic>>();
          reads.add(read);
          return read.future;
        },
      ).initialize();
      await handler.setQueueAndPlay([song]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      held = true;
      final reference = CoverStore.songCoverReference(song.source);

      // The newer change's read answers first.
      final older = handler.onSourceMetadataChanged(song.source);
      final newer = handler.onSourceMetadataChanged(song.source);
      await until(() => reads.length == 2);
      reads[1].complete({'cover_path': second.path});
      await newer;
      final kept = covers.indexedFile(reference);
      expect(File(kept!).readAsBytesSync(), [0xFF, 0xD8, 0xFF, 2]);
      reads[0].complete({'cover_path': first.path});
      await older;
      expect(covers.indexedFile(reference), kept);

      // The song leaves the queue during the read.
      final orphaned = handler.onSourceMetadataChanged(song.source);
      await until(() => reads.length == 3);
      held = false;
      await handler.setQueueAndPlay([
        const PlayableMedia(
          id: 'nas-next',
          source: 'network://nas/Album/05.flac',
          title: 'Five',
          artist: 'Artist',
        ),
      ]);
      reads[2].complete({'cover_path': first.path});
      await expectLater(orphaned, completes);
      expect(covers.indexedFile(reference), kept);
    });

    test('a tag read for a queued song updates the queue once', () async {
      const other = PlayableMedia(
        id: 'nas-other',
        source: 'network://nas/Album/02.flac',
        title: 'Two',
        artist: 'Artist',
        networkArtworkSource: 'network://nas/Album/02.jpg',
      );
      final temporary = await Directory.systemTemp.createTemp('nas-tags-');
      addTearDown(() => temporary.delete(recursive: true));
      final tagCover =
          File(p.join(temporary.path, 'network_metadata', 'tags.image'))
            ..createSync(recursive: true)
            ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 7]);
      final events = SourceMetadataEvents();
      final handler = await _runtime(
        coverStore: covers,
        sourceMetadataEvents: events,
        resolveNetworkSource: resolve,
        readNetworkMetadata: (source) async =>
            source == other.source ? {'cover_path': tagCover.path} : {},
      ).initialize();
      await handler.setQueueAndPlay([song, other]);
      await until(
        () => handler.queue.value.every((item) => item.artUri != null),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final queues = <List<MediaItem>>[];
      final subscription = handler.queue.skip(1).listen(queues.add);
      addTearDown(subscription.cancel);

      // As a library job reports a song whose tags it read.
      await events.publish(other.source);
      await until(() => queues.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(queues, hasLength(1));
      expect(
        queues.single.last.artUri!.toFilePath(),
        covers.indexedFile(CoverStore.songCoverReference(other.source)),
      );
    });

    test(
      "a desktop song played on the phone shows the desktop's new cover",
      () async {
        // A desktop song as Link resolves it, with the server's cover.
        final source = linkDesktopSongSource(linkTestServer, 's0');
        final reference = linkDesktopCoverSource(linkTestServer, 's0');
        final desktopSong = PlayableMedia(
          id: 'desktop-s0',
          source: source,
          title: 'Song s0',
          artist: 'Artist',
          networkArtworkSource: reference,
        );
        // Its tags come with that same cover, read to a temporary file.
        final temporary = await Directory.systemTemp.createTemp('link-tags-');
        addTearDown(() => temporary.delete(recursive: true));
        final served =
            File(p.join(temporary.path, 'network_metadata', 'subsonic.image'))
              ..createSync(recursive: true)
              ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0]);
        final recorder = _Recorder(
          write: (_) async {},
          elapsed: () => Duration.zero,
          now: () => DateTime(2026),
        );
        final handler = await _runtime(
          coverStore: covers,
          recorder: recorder,
          resolveNetworkSource: resolve,
          readNetworkMetadata: (_) async => {
            'title': 'Played',
            'cover_path': served.path,
          },
        ).initialize();
        await handler.setQueueAndPlay([desktopSong]);
        await until(
          () =>
              handler.mediaItem.value?.title == 'Played' &&
              handler.mediaItem.value?.artUri ==
                  Uri.file(covers.indexedFile(reference) ?? ''),
        );
        // Stored once, under the reference the desktop keeps fresh.
        expect(covers.songCover(source), isNull);
        await _settle();
        expect(recorder.latestTrack?.artwork, reference);

        // The phone's remote view of the desktop playing it.
        final client = FakeLinkClient(
          onGet: (_, _) => null,
          onPost: (_, _) => {'resolved': 1, 'missing': <int>[]},
        );
        final container = ProviderContainer(
          overrides: [linkPhoneClientProvider.overrideWithValue(client)],
        );
        addTearDown(container.dispose);
        final lookup = FakeLibraryLookup();
        final playback = LinkRemotePlayback(
          name: 'Studio PC',
          remote: container.read(linkDesktopRemoteProvider.notifier),
          handoff: LinkHandoff(
            client: client,
            player: FakePhonePlayer(),
            refs: LinkTrackRefCache(lookup: lookup, server: client.server),
            resolver: LinkTrackResolver(lookup: lookup, server: client.server),
          ),
          covers: covers,
          extractArtwork: (_) async => null,
          tick: const Duration(milliseconds: 10),
        );
        addTearDown(playback.dispose);
        container.listen(linkDesktopRemoteProvider, (_, next) {
          playback.update(next);
        });
        // The remote's first state request answers before the push.
        await Future<void>.delayed(Duration.zero);
        final track = TrackRef(
          title: 'Song s0',
          artist: 'Artist',
          durationMs: 200000,
          songId: 's0',
          serverId: linkTestServer.serverId,
        );
        client.push({
          'type': LinkMessageTypes.playerState,
          'state': LinkPlayerState(
            track: track,
            playing: true,
            durationMs: 200000,
            updatedMs: 1,
            queue: [track],
            index: 0,
          ).toJson(),
        });
        final before = await playback.mediaItems
            .firstWhere((item) => item?.artUri != null)
            .timeout(const Duration(seconds: 5));
        expect(before!.artUri, handler.mediaItem.value!.artUri);

        // The desktop changes the cover.
        version = 1;
        playback.refreshCover(reference);
        final after = await playback.mediaItems
            .firstWhere((item) => item?.artUri != before.artUri)
            .timeout(const Duration(seconds: 5));
        expect(after!.artUri!.toFilePath(), covers.indexedFile(reference));
        expect(File(after.artUri!.toFilePath()).readAsBytesSync()[3], 1);
        await until(() => handler.mediaItem.value!.artUri == after.artUri);
      },
    );

    test(
      'a restored session shows its stored cover from the first item',
      () async {
        final stored = Uri.file((await covers.file(cover))!);
        final restarted = store();
        addTearDown(restarted.dispose);
        final handler = await _runtime(
          coverStore: restarted,
          resolveNetworkSource: resolve,
        ).initialize();
        final covered = <Uri?>[];
        final subscription = handler.mediaItem.listen((item) {
          if (item != null) covered.add(item.artUri);
        });
        addTearDown(subscription.cancel);
        await handler.restoreSession(
          items: [song],
          index: 0,
          position: Duration.zero,
          shuffle: false,
        );
        await _settle();
        expect(covered, isNotEmpty);
        expect(covered, everyElement(stored));
        expect(handler.queue.value.single.artUri, stored);
      },
    );

    test('the Home resume item shows the stored cover', () async {
      final stored = Uri.file((await covers.file(cover))!);
      final restarted = store();
      addTearDown(restarted.dispose);
      final runtime = _runtime(
        coverStore: restarted,
        sessionDatabase: _ResumeSessionStore()
          ..preview = {'media': song.toJson(), 'positionMs': 23000},
      );
      final preview = (await loadPlaybackResumePreview(runtime))!;
      final item = preview.media.toMediaItem(covers: restarted);
      expect(item.artUri, stored);
      expect(item.extras!['artworkRef'], cover);
      expect(runtime.handler, isNull);
    });

    test(
      'the Home resume item drops a loopback cover of earlier versions',
      () async {
        final runtime = _runtime(
          coverStore: covers,
          sessionDatabase: _ResumeSessionStore()
            ..preview = {
              'media': {
                ...const PlayableMedia(
                  id: 'nas-old',
                  source: 'network://nas/Album/04.flac',
                  title: 'Four',
                  artist: 'Artist',
                ).toJson(),
                'artUri': 'http://127.0.0.1:41234/2f6d1c',
              },
              'positionMs': 23000,
            },
        );
        final preview = (await loadPlaybackResumePreview(runtime))!;
        expect(preview.media.artUri, isNull);
        expect(preview.media.toMediaItem(covers: covers).artUri, isNull);
      },
    );
  });

  group('source switch of a local downloaded file', () {
    const fromHistory = Track(
      id: 'row-song',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 60,
      isrc: 'USAAA0000001',
    );
    const local = PlayableMedia(
      id: '/music/Artist/Album/01 - Song.m4a',
      source: '/music/Artist/Album/01 - Song.m4a',
      title: 'Song',
      artist: 'Artist',
      duration: Duration(seconds: 60),
    );

    for (final playing in [true, false]) {
      test('moves ${playing ? 'playing' : 'paused'} playback onto the new '
          'file at the same position', () async {
        final decks = <_Deck>[];
        final player = await _runtime(decks: decks).initialize();
        await player.setQueueAndPlay([local]);
        if (!playing) await player.pause();
        decks.first.position = const Duration(seconds: 21);
        final switched = await player.switchPlaybackSource(
          fromHistory,
          '/music/Artist/Album/01 - Song.flac',
          replacing: local.source,
        );
        expect(switched, isTrue);
        expect(decks.last.sources, ['/music/Artist/Album/01 - Song.flac']);
        expect(decks.last.position, const Duration(seconds: 21));
        expect(
          player.mediaItem.value?.extras?['source'],
          '/music/Artist/Album/01 - Song.flac',
        );
      });
    }

    test('a local file with no catalog identity says why it cannot switch '
        'live', () async {
      final player = await _runtime().initialize();
      await player.setQueueAndPlay([local]);
      final result = await player.switchCatalogQualityResult(
        fromHistory,
        'LOSSLESS',
      );
      expect(result.failure, QualitySwitchFailure.notCatalogTrack);
    });

    test('a catalog song other than the playing one is an identity '
        'mismatch, not an unknown failure', () async {
      const playing = Track(
        id: 'playing',
        name: 'Playing',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 60,
        source: 'tidal',
      );
      final player = await _runtime().initialize();
      await player.setQueueAndPlay([playableFromCatalogTrack(playing)]);
      final result = await player.switchCatalogQualityResult(
        playing.copyWith(id: 'other'),
        'LOSSLESS',
      );
      expect(result.failure, QualitySwitchFailure.identityMismatch);
    });

    test('a song without source or ISRC still matches itself', () async {
      const playing = Track(
        id: 'bare',
        name: 'Bare',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 60,
      );
      final player = await _runtime().initialize();
      await player.setQueueAndPlay([playableFromCatalogTrack(playing)]);
      final result = await player.switchCatalogQualityResult(
        playing,
        'LOSSLESS',
      );
      expect(result.failure, isNot(QualitySwitchFailure.identityMismatch));
      expect(result.failure, isNot(QualitySwitchFailure.notCatalogTrack));
    });
  });
}
