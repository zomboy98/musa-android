import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, compute, debugPrint, visibleForTesting;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:mornye/services/playback_notification.dart';
import 'package:mornye/services/playback_ramp.dart';
import 'package:audio_session/audio_session.dart'
    show
        AudioDevice,
        AudioSession,
        AudioSessionConfiguration,
        AudioInterruptionType;
import 'package:mornye/services/listening_statistics.dart' show ListeningTrack;
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/media_library_browser.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_normalization.dart';
import 'package:mornye/services/playback_automation.dart';
import 'package:mornye/services/playback_session_writer.dart';
import 'package:mornye/services/content_uri_playback_cache.dart';
import 'package:mornye/services/file_access_check.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/avplayer_formats.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/network_playback_cache.dart';
import 'package:mornye/services/network_storage_service.dart'
    show subsonicSongIdFromPath;
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/automix_analysis.dart';
import 'package:mornye/services/automix_phase_lock.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/automix_analyzer.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/automix_effect_renderer.dart';
import 'package:mornye/services/automix_status.dart';
import 'package:mornye/services/music_haptics.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/utils/context_cover_availability.dart';
import 'package:mornye/utils/playback_artwork.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/download_queue_pacing.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/quality_switch_result.dart';
import 'package:mornye/services/prefetch_planner.dart';
import 'package:mornye/services/upcoming_prefetcher.dart';
import 'package:mornye/services/experimental_progressive_transfer.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/utils/file_access.dart' show fileExists;
import 'package:mornye/services/listening_signals.dart';
import 'package:mornye/services/shuffle_strategy.dart';
import 'package:mornye/services/smart_shuffle.dart';
import 'package:mornye/services/analytics/anonymous_metrics.dart';
import 'package:mornye/services/streaming_quality_resolver.dart' show StreamingRequest;
import 'package:mornye/services/special_quality_availability.dart'
    show atmosCapableProviders, isSpatialQualityId, normalizeAvailabilityProvider;

export 'autoplay_signal.dart';
export 'music_player_runtime.dart';
export 'playable_media.dart';
export 'playback_metadata.dart';
export 'playback_session_restore.dart';
export 'shuffle_strategy.dart';

part 'music_player_automix.dart';
part 'music_player_autoplay.dart';
part 'music_player_covers.dart';
part 'music_player_cast.dart';
part 'music_player_formats.dart';
part 'music_player_failures.dart';
part 'music_player_gapless.dart';
part 'music_player_prefetch.dart';
part 'music_player_upcoming.dart';

final _log = AppLogger('MusicPlayer');

/// Muted artwork shares the music session. Recover its Now Playing ownership
/// after video initialization, including failed or abandoned initialization.
Future<void> restoreMusicAudioSessionAfterVideo() async =>
    musicPlayerRuntime.handler?.restoreIosNowPlaying();

/// Gain and rate the player applies to the current track.
class PlaybackProcessing {
  const PlaybackProcessing({
    required this.normalizationGain,
    required this.direct,
    required this.autoMixRate,
  });

  /// Linear volume from ReplayGain normalization; 1 when none applies.
  final double normalizationGain;

  /// A verified native direct path that bypasses the system mixer and DSP.
  /// Desktop exclusive output may still apply software processing.
  final bool direct;

  /// AutoMix tempo matching; 1 outside a transition.
  final double autoMixRate;
}

/// Refreshes gain tags after a successful file update, including SAF copies.
void refreshPlaybackNormalization(String source) {
  final handler = musicPlayerRuntime.handler;
  if (handler != null) unawaited(handler._refreshNormalizationSource(source));
}

Future<void> notifyPlaybackSourceRelocated(
  String previous,
  String replacement,
) async {
  await musicPlayerRuntime.handler?.onSourceRelocated(previous, replacement);
  await AppStateDatabase.instance.relocatePlaybackSource(previous, replacement);
}

/// Offers a completed permanent download to the currently playing catalog song.
Future<void> notifyPermanentDownloadReady(Track track, String path) async {
  try {
    await musicPlayerRuntime.handler?.onPermanentDownloadReady(track, path);
  } catch (error) {
    _log.w('Permanent playback handoff unavailable: $error');
  }
}

/// The catalog song the player is on, also after its source was swapped for
/// a prepared local file.
Track? playingCatalogTrack() => musicPlayerRuntime.handler?.currentCatalogTrack;

/// Provider and quality the playing catalog song was prepared with.
({String service, String quality})? playingCatalogRequest(Track track) =>
    musicPlayerRuntime.handler?.catalogPlayingRequest(track);

/// Prepares [qualityId] of the playing catalog [track] in the background and
/// swaps to it at the current position once ready. False when nothing changed.
Future<bool> requestCatalogQualitySwitch(
  Track track,
  String qualityId, {
  String? service,
}) async => (await requestCatalogQualitySwitchResult(
  track,
  qualityId,
  service: service,
)).ok;

/// Same as [requestCatalogQualitySwitch], saying why the switch failed.
Future<QualitySwitchResult> requestCatalogQualitySwitchResult(
  Track track,
  String qualityId, {
  String? service,
}) async {
  try {
    return await musicPlayerRuntime.handler?.switchCatalogQualityResult(
          track,
          qualityId,
          service: service,
        ) ??
        const QualitySwitchResult.failed(QualitySwitchFailure.other);
  } catch (error) {
    _log.w('Quality switch unavailable: $error');
    return const QualitySwitchResult.failed(QualitySwitchFailure.other);
  }
}

/// Switches to one format trying [candidates] in order; see
/// [MusicPlayerHandler.switchCatalogQualityAcrossProviders].
Future<QualitySwitchResult> requestCatalogQualitySwitchAcrossProviders(
  Track track,
  List<({String service, String id})> candidates,
) async {
  try {
    return await musicPlayerRuntime.handler
            ?.switchCatalogQualityAcrossProviders(track, candidates) ??
        const QualitySwitchResult.failed(QualitySwitchFailure.other);
  } catch (error) {
    _log.w('Quality switch unavailable: $error');
    return const QualitySwitchResult.failed(QualitySwitchFailure.other);
  }
}

Future<void> cancelCatalogQualitySwitch(Track track) async {
  try {
    await musicPlayerRuntime.handler?.cancelCatalogQualitySwitch(track);
  } catch (error) {
    _log.w('Quality switch cancellation unavailable: $error');
  }
}

/// Swaps the file playing as [replacing] for the finished file at [path] at
/// the current position. False when the player kept its source.
Future<bool> requestPlaybackSourceSwitch(
  Track track,
  String path, {
  required String replacing,
  String? sourceKind,
}) async {
  try {
    return await musicPlayerRuntime.handler?.switchPlaybackSource(
          track,
          path,
          replacing: replacing,
          sourceKind: sourceKind,
        ) ??
        false;
  } catch (error) {
    _log.w('Source switch unavailable: $error');
    return false;
  }
}

/// Invalidates a pending handoff as soon as a new download is selected.
void notifyPermanentDownloadSelected(Track track) {
  musicPlayerRuntime.handler?.onPermanentDownloadSelected(track);
}

bool _samePermanentTrack(Track a, Track b) {
  final left = canonicalIsrcForCopy(a.isrc).toUpperCase();
  final right = canonicalIsrcForCopy(b.isrc).toUpperCase();
  if (left.isNotEmpty && right.isNotEmpty) return left == right;
  final source = a.source?.trim().toLowerCase() ?? '';
  return a.id.trim().isNotEmpty &&
      a.id == b.id &&
      source == (b.source?.trim().toLowerCase() ?? '');
}

List<int> buildShuffledQueueOrder({
  required int mediaCount,
  required int currentIndex,
  required Random random,
}) {
  final rest = [
    for (var i = 0; i < mediaCount; i++)
      if (i != currentIndex) i,
  ]..shuffle(random);
  return [
    if (currentIndex >= 0 && currentIndex < mediaCount) currentIndex,
    ...rest,
  ];
}

/// Returns a safe source-start position for restored playback. A completed
/// snapshot starts over instead of immediately completing again on resume.
Duration normalizedPlaybackResumePosition(
  Duration position, {
  Duration? duration,
}) {
  if (position <= Duration.zero) return Duration.zero;
  if (duration != null && duration > Duration.zero && position >= duration) {
    return Duration.zero;
  }
  return position;
}

class MusicPlayerHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler, WidgetsBindingObserver {
  final MusicPlayerRuntime _runtime;
  PlaybackDependencies get _dependencies => _runtime.dependencies;
  AppSettings get _settings => _runtime.settings;
  late PlaybackDeck _player;
  late final _MusicCast _cast;
  late final _MusicAutoMix _autoMix;
  late final _MusicGapless _gapless = _MusicGapless(this);
  late final _MusicPrefetch _prefetch = _MusicPrefetch(this);
  late final _MusicUpcoming _upcoming = _MusicUpcoming(this);
  late final _MusicFormats _formats = _MusicFormats(this);
  late final _MusicFailures _failures = _MusicFailures(this);
  late final _MusicCovers _covers = _MusicCovers(this);
  late final _MusicAutoplay _autoplay;
  late final MusicHaptics _haptics;
  bool _completing = false;
  double _normalizationVolume = 1;
  final _playerSubscriptions =
      <PlaybackDeck, List<StreamSubscription<dynamic>>>{};
  AudioSession? _audioSession;
  late final PlaybackAutomation _playbackAutomation;
  StreamSubscription<Set<AudioDevice>>? _automationDevicesSubscription;
  bool _headphoneMonitoringRequested = false;
  int _headphoneMonitoringRevision = 0;
  final List<PlayableMedia> _media = [];
  final List<MediaItem> _queueItems = [];
  late final ContentUriPlaybackCache _sourceCache;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _index = -1;
  bool _jamQueueActive = false;
  bool Function(String?, String?)? _jamPlaybackOccurrencesChanged;
  String? _jamAudibleOccurrence;
  bool _jamTransitionPending = false;
  bool _jamTransitionInFlight = false;
  String? _jamPendingOccurrence;

  void configureJamPlaybackOccurrences(
    String? current,
    bool Function(String?, String?) update,
  ) {
    _jamAudibleOccurrence = current;
    _jamPlaybackOccurrencesChanged = update;
    _jamTransitionPending = false;
    _jamTransitionInFlight = false;
    _jamPendingOccurrence = null;
  }

  void _rejectLocalJamQueueEdit() {
    if (_jamQueueActive) {
      throw StateError('Edit the queue through Jam while a session is active');
    }
  }

  int _playRequestGeneration = 0;
  ({Track track, String path, int instance})? _pendingPermanentOffer;
  Object _playOccurrence = Object();
  int _pausedLoadGeneration = 0;
  bool _stopRequested = false;
  Future<void>? _stopPreparation;
  ({Track track, String path, Object occurrence, int generation})?
  _loadingPermanentOffer;
  Track? _permanentCatalogTrack;
  int? _permanentCatalogInstance;
  PlaybackDeck? _preparedPausedDeck;
  int _playbackInstance = 0;
  int _listeningInstance = 0;
  final _metadataChanges = <String, Object>{};
  String? _activeResolvedPath;
  CatalogAudioLease? _catalogLease;
  ExperimentalProgressiveTransfer? _experimentalTransfer;
  ExperimentalProgressiveAttempt? _experimentalAttempt;
  Future<ExperimentalProgressiveAttempt?>? _experimentalPendingStart;
  Future<bool>? _experimentalCloseBarrier;
  bool _progressiveCloseUnconfirmed = false;
  int _experimentalRetiringGeneration = 0;
  Duration? _experimentalRetirementSeek;
  final Future<PrimaryAudioProperties> Function(String) _probeCatalogAudio;
  Track? _preparingCatalogTrack;
  ({
    int generation,
    PlayableMedia media,
    Duration startPosition,
    bool startPaused,
    Future<void> done,
  })?
  _inFlightLoad;
  Track? _audibleCatalogTrack;
  Future<void> _finishCatalogListening() async {
    final track = _audibleCatalogTrack;
    _audibleCatalogTrack = null;
    if (track != null) {
      await _recordCatalogPlayback(track);
    }
  }

  // Timestamp persistence must not interrupt playback or expose paths.
  Future<void> _recordCatalogPlayback(Track track) async {
    final lease = _catalogLease;
    try {
      final store = await _catalogPlayback.store;
      if (lease != null) {
        await store.recordPlaybackLease(lease);
      } else {
        await store.recordPlayback(_catalogPlayback.key(track));
      }
    } catch (_) {
      _log.w('Could not update catalog playback timestamp');
    }
  }

  Future<void> _retireCatalogListening() async {
    try {
      await _finishCatalogListening();
    } finally {
      final lease = _catalogLease;
      _catalogLease = null;
      await lease?.release();
    }
  }

  bool _disposed = false;
  Future<void>? _disposeFuture;
  bool _initialized = false;
  bool _sourceReady = false;
  Object? _playbackError;

  /// Reloads of the current song after Android's media server died, and
  /// whether the next [_playIndex] is one of them.
  int _serverDiedReloads = 0;
  bool _reloadingAfterServerDied = false;
  ({Future<void> future, int generation})? _activePlayOperation;
  Future<void> _sourceChangeTail = Future<void>.value();
  Timer? _sleepTimer;
  Timer? _listeningTimer;
  DateTime? _sleepTimerEndsAt;

  bool _shuffle = false;
  ShuffleStrategy _shuffleStrategy = ShuffleStrategy.off;
  final StreamController<ShuffleStrategy> _shuffleStrategyEvents =
      StreamController<ShuffleStrategy>.broadcast(sync: true);
  ListeningSignals? _listeningSignals;
  DateTime? _listeningSignalsAt;
  final SmartShuffleSession _smartSession = SmartShuffleSession();
  final Set<MediaItem> _smartManaged = Set<MediaItem>.identity();
  List<MediaItem>? _originalQueueOrder;
  int _shuffleRequestGeneration = 0;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  final Random _random = Random();
  final List<int> _playHistory = [];

  bool _pausedByInterruption = false;
  bool _interruptionActive = false;
  bool _userPaused = false;
  // Position saved with the restored session; applied on the first play().
  Duration? _pendingRestorePosition;
  ({Duration position, Object token, int? playbackInstance})? _pendingSeek;
  bool _restoringSession = false;
  int _switchingGeneration = 0;
  Duration _lastBroadcastPosition = Duration.zero;
  DateTime? _lastPositionBroadcastAt;
  DateTime? _lastPeriodicPersistAt;

  /// When the engine read the last published position, and when the last
  /// tick asked it for one, on a clock that wall-clock changes cannot move.
  final Stopwatch _positionClock = autoMixStopwatch()..start();
  Duration? _lastPositionReadAt;
  Duration? _positionQueriedAt;

  /// No engine position has arrived since a forced broadcast.
  bool _positionCheckDue = false;
  late final PlaybackSessionWriter _sessionWriter;
  int get _sessionQueueRevision => _sessionWriter.queueRevision;
  static const Duration _positionBroadcastInterval = Duration(
    milliseconds: 500,
  );
  static const Duration _positionPersistInterval = Duration(seconds: 10);

  /// How early a tick may ask the engine: the answer arrives a platform
  /// round trip later, which can carry it past an interval.
  static const Duration _positionQueryAllowance = Duration(milliseconds: 50);

  DateTime? get sleepTimerEndsAt => _sleepTimerEndsAt;
  bool get isDisposed => _disposed;
  int get playbackRequestGeneration => _playRequestGeneration;
  int _queueRequestGeneration = 0;
  int get queueRequestGeneration => _queueRequestGeneration;

  /// Reconcile only the playback fields affected by the new settings snapshot.
  void applySettings(AppSettings previous) {
    final settings = _settings;
    if (previous.autoplayPersonalization != settings.autoplayPersonalization ||
        previous.playerMode != settings.playerMode) {
      _configurePersonalization();
    }
    if (previous.playbackNormalization != settings.playbackNormalization ||
        previous.playbackNormalizationPreamp !=
            settings.playbackNormalizationPreamp ||
        previous.playbackNormalizationMode !=
            settings.playbackNormalizationMode) {
      reapplyNormalization();
    }
    if (previous.autoMix != settings.autoMix ||
        previous.autoMixOptions != settings.autoMixOptions ||
        previous.usbBitPerfect != settings.usbBitPerfect ||
        previous.exclusiveOutput != settings.exclusiveOutput) {
      unawaited(_autoMix.cancel());
    }
    if (previous.gaplessPlayback != settings.gaplessPlayback ||
        previous.autoMix != settings.autoMix ||
        previous.usbBitPerfect != settings.usbBitPerfect ||
        previous.exclusiveOutput != settings.exclusiveOutput) {
      unawaited(_gapless.cancel());
    }
    // USB changes apply at the next source boundary, without raising volume.
    if ((previous.playerMode == 'internal') !=
            (settings.playerMode == 'internal') ||
        previous.playOnHeadphonesConnected !=
            settings.playOnHeadphonesConnected ||
        previous.usbBitPerfect != settings.usbBitPerfect) {
      _refreshPlaybackAutomation();
    }
    if (previous.musicHaptics != settings.musicHaptics ||
        previous.musicHapticsSensitivity != settings.musicHapticsSensitivity ||
        previous.musicHapticsStrength != settings.musicHapticsStrength ||
        previous.playerMode != settings.playerMode) {
      _updateHaptics();
    }
    if (previous.autoplay != settings.autoplay ||
        previous.autoplayPersonalization != settings.autoplayPersonalization ||
        previous.localLibraryEnabled != settings.localLibraryEnabled) {
      _autoplay.updateMode();
    }
  }

  final CatalogPlayback _catalogPlayback;

  MusicPlayerHandler({
    CatalogPlayback? catalogPlaybackOverride,
    MusicPlayerRuntime? runtime,
    AutoMixAnalyzer? autoMixAnalyzer,
    AutoMixEffectRenderer? autoMixEffectRenderer,
    AutoplayLibraryLoader? autoplayLibraryLoader,
    MusicHapticsAnalyzer? hapticsAnalyzer,
    HapticPulse? hapticPulse,
    CastOutput? castOutput,
    Future<PrimaryAudioProperties> Function(String)? probeCatalogAudio,
  }) : _catalogPlayback = catalogPlaybackOverride ?? catalogPlayback,
       _probeCatalogAudio =
           probeCatalogAudio ??
           ((path) => FFmpegProbe.audioProperties(path, redactPath: true)),
       _runtime = runtime ?? musicPlayerRuntime {
    // Switching back from a remote session restores phone volume handling.
    androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
    _haptics = MusicHaptics(
      state: () => playbackState.value,
      analyzer: hapticsAnalyzer,
      pulse: hapticPulse,
    );
    _sourceCache = ContentUriPlaybackCache(
      copy: PlatformBridge.copyContentUriToTemp,
      isDisposed: () => _disposed,
      isPinned: (path) =>
          path == _activeResolvedPath ||
          _autoMix.pinnedPaths.contains(path) ||
          _gapless.pinnedPaths.contains(path),
      onResolveError: (error) =>
          _log.e('Failed to resolve content URI for playback: $error'),
      onDeleteError: (error) =>
          _log.w('Failed to delete SAF playback temp file: $error'),
    );
    _sessionWriter = PlaybackSessionWriter(
      database: _dependencies.sessionDatabase,
      onError: (error) =>
          _log.w('Failed to update persisted playback session: $error'),
    );
    _player = _dependencies.createDeck('music-player');
    _cast = _MusicCast(
      this,
      castOutput ??
          (Platform.isAndroid || Platform.isIOS || isDesktopPlatform
              ? CastOutput.instance
              : null),
    );
    _normalizationCache = PlaybackNormalizationCache(
      readMetadata: _dependencies.readMetadata,
      onReadError: (error) =>
          _log.w('Failed to read gain tags for normalization: $error'),
    );
    _playbackAutomation = PlaybackAutomation(
      isPlaying: () =>
          _player.state == PlaybackDeckState.playing ||
          playbackState.value.playing,
      canResume: () =>
          !_disposed &&
          !_interruptionActive &&
          _index >= 0 &&
          _index < _media.length,
      pause: _pausePlayback,
      play: play,
      onError: (error) => _log.w('Automatic playback failed: $error'),
      onMutedPause: _runtime.notifyMutedPlayback,
    );
    _autoMix = _MusicAutoMix(
      this,
      autoMixAnalyzer ?? AutoMixAnalyzer(),
      autoMixEffectRenderer ?? AutoMixEffectRenderer(),
    );
    _autoplay = _MusicAutoplay(
      this,
      autoplayLibraryLoader ?? (seed) => loadAutoplayLibrary(seed, _runtime),
    );
    try {
      _init();
      _runtime.attach(this);
    } catch (_) {
      unawaited(dispose());
      rethrow;
    }
  }

  Future<void> _publishVerifiedCatalogAudio(
    PlayableMedia media,
    int instance,
    CatalogAudioLease lease,
  ) async {
    PrimaryAudioProperties properties;
    try {
      properties = await _probeCatalogAudio(lease.path);
    } catch (_) {
      return;
    }
    if (_disposed ||
        _dependencies.sourceDeletionEvents.isDeleting(media.source) ||
        _playbackInstance != instance ||
        _index < 0 ||
        _index >= _media.length ||
        _media[_index].id != media.id ||
        _media[_index].source != media.source ||
        !_sourceReady ||
        !identical(_catalogLease, lease) ||
        _permanentCatalogInstance == _playbackInstance)
      return;
    final codec = properties.codec?.trim().toLowerCase();
    const allowedCodecs = {
      'aac',
      'alac',
      'flac',
      'mp3',
      'opus',
      'vorbis',
      'pcm_s16le',
      'pcm_s24le',
      'pcm_s32le',
    };
    final rate = properties.sampleRate;
    final facts = <String, Object>{
      if (codec != null && allowedCodecs.contains(codec))
        'verifiedAudioCodec': codec,
      if (rate != null && rate > 0 && rate <= 768000)
        'verifiedAudioSampleRate': rate,
    };
    final current = mediaItem.value;
    if (current == null || facts.isEmpty) return;
    mediaItem.add(current.copyWith(extras: {...?current.extras, ...facts}));
  }

  MediaItem _toMediaItem(PlayableMedia media, {String? resolvedSource}) {
    final item = media.toMediaItem(
      resolvedSource: resolvedSource,
      unknownTitle: _runtime.unknownTitle,
      unknownArtist: _runtime.unknownArtist,
      covers: _dependencies.coverStore,
    );
    return item.copyWith(
      extras: {
        ...?item.extras,
        'playbackInstance': _playbackInstance,
        'listeningInstance': _listeningInstance,
      },
    );
  }

  void _init() {
    if (_initialized) return;
    _initialized = true;
    _configurePersonalization();
    void recordListening() {
      final item = mediaItem.value;
      final state = playbackState.value;
      _runtime.personalization.updatePlayback(
        source: item?.extras?['source'] as String?,
        duration: item?.duration,
        playing:
            state.playing &&
            state.processingState == AudioProcessingState.ready,
      );
      _dependencies.recorder.update(
        item == null
            ? null
            : ListeningTrack(
                key: item.extras?['source']?.toString() ?? item.id,
                title: item.title,
                artist: item.artist ?? '',
                album: item.album ?? '',
                // A reference that outlasts this run, never a loopback URL
                // or a temporary file.
                artwork: _covers.reference(item),
              ),
        playbackInstance: item?.extras?['listeningInstance'],
        playing:
            state.playing &&
            state.processingState == AudioProcessingState.ready,
        ended:
            state.processingState == AudioProcessingState.completed ||
            state.processingState == AudioProcessingState.idle,
      );
      _scheduleListeningFlushes();
    }

    _subscriptions.add(mediaItem.listen((_) => recordListening()));
    _subscriptions.add(
      playbackState
          .map(
            (state) => (
              state.playing &&
                  state.processingState == AudioProcessingState.ready,
              state.processingState == AudioProcessingState.completed ||
                  state.processingState == AudioProcessingState.idle,
            ),
          )
          .distinct()
          .listen((_) {
            recordListening();
            final state = playbackState.value;
            if ((!state.playing ||
                    state.processingState == AudioProcessingState.completed ||
                    state.processingState == AudioProcessingState.idle) &&
                !_dependencies.recorder.idle) {
              unawaited(_flushListening());
            }
          }),
    );
    _subscriptions.add(
      playbackState.map((state) => state.playing).distinct().listen((playing) {
        if (playing) unawaited(_playbackAutomation.playbackStarted());
      }),
    );
    _subscriptions.add(mediaItem.listen((_) => _updateHaptics()));
    _subscriptions.add(playbackState.listen((_) => _updateHaptics()));
    _subscriptions.add(
      _dependencies.coverStore.changes.listen(_covers.changed),
    );
    unawaited(_player.configureOutput());
    unawaited(_configureAudioSession());
    _refreshPlaybackAutomation();

    _listenToPlayer(_player);
    _cast.initialize();
    if (_dependencies.isIOS || _dependencies.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  /// Writes listening time every 10 s from the start of playback until a
  /// flush finds the recorder idle, so a failed write, this timer's or
  /// another caller's, is retried within 10 s.
  void _scheduleListeningFlushes() {
    if (_disposed || _dependencies.recorder.idle) return;
    _listeningTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_flushListening());
    });
  }

  Future<void> _flushListening() async {
    final recorder = _dependencies.recorder;
    await recorder.flush();
    if (_disposed || !recorder.idle) return;
    _listeningTimer?.cancel();
    _listeningTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_runtime.personalization.flush());
      unawaited(_runtime.taste.flush());
      unawaited(_runtime.ranker.flush());
      if (!_dependencies.recorder.idle) unawaited(_flushListening());
    }
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(restoreIosNowPlaying());
    }
  }

  /// Haptics follow only decodable local files; streams have no full copy.
  void _updateHaptics() {
    if (_disposed) return;
    final extras = mediaItem.value?.extras;
    final source = extras?['source']?.toString() ?? '';
    final resolved = extras?['resolvedSource']?.toString().trim() ?? '';
    final document = source.startsWith('content://');
    // Use a stable document identity for both direct playback and AutoMix.
    // Haptics opens its own SAF input; the player's descriptor is short-lived.
    final path = document ? source : (resolved.isNotEmpty ? resolved : source);
    // Desktop has no vibration motor.
    final local =
        !isDesktopPlatform &&
        path.isNotEmpty &&
        (document || !path.contains('://')) &&
        _settings.musicHaptics &&
        _settings.playerMode == 'internal';
    _haptics.configure(
      sensitivity: _settings.musicHapticsSensitivity,
      strength: _settings.musicHapticsStrength,
    );
    _haptics.update(local ? path : null);
  }

  void _configurePersonalization() {
    final enabled =
        _settings.autoplayPersonalization && _settings.playerMode == 'internal';
    _runtime.personalization.setEnabled(enabled);
    if (enabled && _index >= 0 && _index < _media.length) {
      _runtime.personalization.begin(_learningTrack(_media[_index]));
      final state = playbackState.value;
      _runtime.personalization.updatePlayback(
        source: mediaItem.value?.extras?['source'] as String?,
        duration: mediaItem.value?.duration,
        playing:
            state.playing &&
            state.processingState == AudioProcessingState.ready,
      );
    }
  }

  /// Recover system controls without reloading, seeking or restarting audio.
  /// Never reclaim audio focus for a paused/interrupted/stopped player.
  Future<void> restoreIosNowPlaying() async {
    final generation = _playRequestGeneration;
    bool canRestore() =>
        _dependencies.isIOS &&
        !_disposed &&
        generation == _playRequestGeneration &&
        !_interruptionActive &&
        !_userPaused &&
        playbackState.value.playing &&
        playbackState.value.processingState == AudioProcessingState.ready &&
        mediaItem.value != null;
    if (!canRestore()) return;
    try {
      final session = _audioSession ?? await _dependencies.audioSession();
      if (!canRestore()) return;
      await session.configure(const AudioSessionConfiguration.music());
      if (!canRestore()) return;
      if (!await session.setActive(true) || !canRestore()) return;
      await AudioService.refreshNowPlayingInfo();
    } catch (error) {
      _log.w('Could not restore iOS playback controls: $error');
    }
  }

  void _listenToPlayer(PlaybackDeck player) {
    // Position updates must continue with the display asleep. UI progress is
    // interpolated between updates; querying native playback every frame is
    // unnecessary and would stop preparing AutoMix when there are no frames.
    player.startPositionUpdates(
      const Duration(milliseconds: 200),
      wanted: () => _wantsPosition(player),
    );
    _playerSubscriptions[player] = [
      player.onPlayerStateChanged.listen(
        (state) {
          if (!identical(player, _player)) return;
          if (_cast.active &&
              state == PlaybackDeckState.playing &&
              _sourceReady &&
              _switchingGeneration == 0) {
            // Playing from the TV's controls also releases a prior app pause.
            _userPaused = false;
          }
          if (state == PlaybackDeckState.paused && player.needsSourceReload) {
            _userPaused = true;
            _pausedByInterruption = false;
            _playbackAutomation.cancelPendingActions();
          }
          if (_switchingGeneration != 0 &&
              (state == PlaybackDeckState.stopped ||
                  state == PlaybackDeckState.completed ||
                  state == PlaybackDeckState.disposed)) {
            return;
          }
          if (state == PlaybackDeckState.completed && _shouldIgnoreComplete) {
            if (_userPaused || _interruptionActive) {
              _broadcastState(playerState: PlaybackDeckState.paused);
            }
            return;
          }
          _broadcastState(playerState: state);
        },
        onError: (Object error, StackTrace stackTrace) {
          // Preparation errors are handled by _loadIndex, including the SAF
          // fallback. Runtime failures must not look like successful completion.
          if (_sourceReady || _switchingGeneration == 0) {
            unawaited(_failures.onRuntimeError(player, error, stackTrace));
          }
        },
      ),
      player.onPositionChanged.listen((position) {
        if (identical(player, _player)) _handlePositionChanged(position);
      }),
      player.onDurationChanged.listen((duration) {
        if (!identical(player, _player) || !_sourceReady) return;
        final current = mediaItem.value;
        if (current != null && duration > Duration.zero) {
          mediaItem.add(current.copyWith(duration: duration));
        }
      }),
      player.onPlayerComplete.listen((_) {
        if (identical(player, _player)) unawaited(_handlePlayerComplete());
      }),
    ];
  }

  void _reportPlaybackError(
    PlaybackDeck player,
    Object error,
    StackTrace stackTrace,
  ) {
    if (_disposed || !identical(player, _player) || _playbackError != null) {
      return;
    }
    if (_reloadAfterServerDied(error)) return;
    _sourceReady = false;
    _playbackError = error;
    _userPaused = true;
    _pausedByInterruption = false;
    _playbackAutomation.cancelPendingActions();
    _log.e('Playback failed for ${mediaItem.value?.title}', error, stackTrace);
    _broadcastState(playerState: PlaybackDeckState.stopped);
    final generation = _playRequestGeneration;
    unawaited(
      _serializeSourceChange(() async {
        if (_disposed || generation != _playRequestGeneration) return;
        await _cancelTransitions();
        if (_disposed || generation != _playRequestGeneration) return;
        await player.stop();
      }).catchError((Object error) {
        _log.w('Could not stop failed playback: $error');
      }),
    );
  }

  static const _serverDiedReloadLimit = 2;
  static const _serverDiedReloadDelay = Duration(milliseconds: 500);

  /// Android restarts its media server shortly after it dies, which fails
  /// the playing song on every MediaPlayer. Plays the song again from where
  /// it was, as pressing Play once or twice does, before reporting it.
  bool _reloadAfterServerDied(Object error) {
    if (!'$error'.contains('MEDIA_ERROR_SERVER_DIED') ||
        _serverDiedReloads >= _serverDiedReloadLimit ||
        _index < 0 ||
        _index >= _media.length) {
      return false;
    }
    _serverDiedReloads++;
    final generation = _playRequestGeneration;
    final index = _index;
    final position = playbackState.value.position;
    _log.w('The media server died; reloading ${mediaItem.value?.title}');
    unawaited(
      Future<void>.delayed(_serverDiedReloadDelay, () {
        if (_disposed || generation != _playRequestGeneration) return null;
        _reloadingAfterServerDied = true;
        return _playIndex(
          index,
          recordHistory: false,
          startPosition: position,
          preserveListeningSession: true,
        );
      }),
    );
    return true;
  }

  /// Drops a prepared AutoMix or gapless transition.
  Future<void> _cancelTransitions() async {
    await _autoMix.cancel();
    await _gapless.cancel();
  }

  Future<void> _disposeDeck(PlaybackDeck player) async {
    final subscriptions = _playerSubscriptions.remove(player);
    if (subscriptions == null) return;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }

  /// Configures the OS audio session and reacts to interruptions (e.g. another
  /// app like PowerAmp taking audio focus, or headphones unplugged) so playback
  /// pauses and the UI/notification reflect the real state instead of staying
  /// stuck on "playing".
  Future<void> _configureAudioSession() async {
    // audio_session models mobile audio focus; desktop has no equivalent.
    if (isDesktopPlatform) return;
    try {
      final session = await _dependencies.audioSession();
      _audioSession = session;
      await session.configure(const AudioSessionConfiguration.music());
      if (_disposed) return;
      _refreshPlaybackAutomation();

      _subscriptions.add(
        session.interruptionEventStream.listen((event) {
          if (_cast.active) return;
          _log.d(
            'Audio interruption ${event.begin ? 'began' : 'ended'} '
            'type=${event.type} player=${_player.state} '
            'playing=${playbackState.value.playing}',
          );
          if (event.begin) {
            if (event.type == AudioInterruptionType.duck) {
              return;
            }

            _interruptionActive = true;
            _pausedByInterruption =
                _player.state == PlaybackDeckState.playing ||
                playbackState.value.playing;
            unawaited(_pauseForFocusLoss(reason: 'audio interruption'));
          } else {
            if (event.type == AudioInterruptionType.duck) {
              return;
            }

            _interruptionActive = false;
            if (_pausedByInterruption &&
                event.type == AudioInterruptionType.pause &&
                !_playbackAutomation.blocksPlayback) {
              _pausedByInterruption = false;
              unawaited(play());
            } else {
              _pausedByInterruption = false;
            }
          }
        }),
      );

      _subscriptions.add(
        session.becomingNoisyEventStream.listen((_) {
          if (_cast.active) return;
          // Headphones unplugged / output route lost.
          _pausedByInterruption = false;
          unawaited(_pauseForFocusLoss(reason: 'becoming noisy'));
        }),
      );
    } catch (e) {
      _log.w('Failed to configure audio session: $e');
    }
  }

  void _refreshPlaybackAutomation() {
    if (_disposed) return;
    // A silent system output must not stop the transport, including for
    // existing installations that saved the old pause-on-mute preference.
    const pauseOnMute = false;
    final playOnHeadphonesConnected =
        !_cast.active &&
        !isDesktopPlatform &&
        _settings.playerMode == 'internal' &&
        _settings.playOnHeadphonesConnected;
    unawaited(
      _playbackAutomation.configure(
        pauseOnMute: pauseOnMute,
        playOnHeadphonesConnected: playOnHeadphonesConnected,
      ),
    );
    final session = _audioSession;
    if (playOnHeadphonesConnected &&
        session != null &&
        !_headphoneMonitoringRequested) {
      _headphoneMonitoringRequested = true;
      unawaited(
        _startHeadphoneMonitoring(session, ++_headphoneMonitoringRevision),
      );
    } else if (!playOnHeadphonesConnected) {
      _headphoneMonitoringRequested = false;
      _headphoneMonitoringRevision++;
      final subscription = _automationDevicesSubscription;
      _automationDevicesSubscription = null;
      if (subscription != null) unawaited(subscription.cancel());
    }
  }

  Future<void> _startHeadphoneMonitoring(
    AudioSession session,
    int revision,
  ) async {
    try {
      // Query a fresh baseline. devicesStream can replay an old inventory
      // after monitoring was disabled, which would look like a new connection.
      final devices = await session.getDevices();
      if (_disposed || revision != _headphoneMonitoringRevision) return;
      unawaited(_playbackAutomation.devicesChanged(devices));
      _automationDevicesSubscription = session.devicesChangedEventStream
          .asyncMap((_) => session.getDevices())
          .listen(
            (devices) => unawaited(_playbackAutomation.devicesChanged(devices)),
            onError: (Object error) =>
                _log.w('Could not monitor headphone connections: $error'),
          );
    } catch (error) {
      _log.w('Could not monitor headphone connections: $error');
    }
  }

  bool get _shouldIgnoreComplete =>
      _switchingGeneration != 0 ||
      _failures.checking ||
      _interruptionActive ||
      _userPaused ||
      _playbackError != null;

  Future<void> _pauseForFocusLoss({required String reason}) async {
    _log.i('Pausing internal player because of $reason');
    _playbackAutomation.cancelPendingActions();
    try {
      await _pausePlayback();
    } catch (e) {
      _log.w('Failed to pause after audio focus loss: $e');
      if (!_disposed) _broadcastState(playerState: PlaybackDeckState.paused);
    }
  }

  void setSleepTimer(Duration duration) {
    if (duration <= Duration.zero) return;
    _sleepTimer?.cancel();
    _sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      _sleepTimer = null;
      _sleepTimerEndsAt = null;
      if (_disposed) return;
      _log.i('Sleep timer elapsed; pausing playback');
      unawaited(pause());
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndsAt = null;
  }

  Future<bool> _activateAudioSession(int generation) async {
    if (_cast.active) return true;
    if (isDesktopPlatform) return true;
    try {
      // Android 15+ rejects background focus requests without an active
      // foreground service. Publishing Dart state alone does not await it.
      if (_dependencies.isAndroid) {
        await _dependencies.synchronizePlaybackState();
      }
      if (generation != _playRequestGeneration || _disposed) return false;
      final session = _audioSession ?? await _dependencies.audioSession();
      _audioSession = session;
      // Other media plugins can change the process-wide iOS category/options
      // after initialization. Mixing makes us ineligible for Now Playing.
      if (_dependencies.isIOS) {
        await session.configure(const AudioSessionConfiguration.music());
      }
      if (generation != _playRequestGeneration || _disposed) return false;
      final granted = await session.setActive(true);
      if (!granted) {
        _log.w('Audio focus request was not granted');
      }
      return granted;
    } catch (e) {
      _log.w('Failed to activate audio session: $e');
      return false;
    }
  }

  // Required on some Android builds because audio_session manages focus.
  Future<void> _claimHardwareMediaButtons() async {
    if (!_dependencies.isAndroid) return;
    try {
      await AudioService.androidForceEnableMediaButtons();
    } catch (e) {
      _log.w('Failed to claim Android media-button routing: $e');
    }
  }

  AudioProcessingState _mapProcessingState(PlaybackDeckState state) {
    switch (state) {
      case PlaybackDeckState.playing:
      case PlaybackDeckState.paused:
        return AudioProcessingState.ready;
      case PlaybackDeckState.completed:
        return AudioProcessingState.completed;
      case PlaybackDeckState.stopped:
      case PlaybackDeckState.disposed:
        return AudioProcessingState.idle;
    }
  }

  void _broadcastState({PlaybackDeckState? playerState, bool? loading}) {
    // Queue and mode changes can broadcast while a new source is resolving.
    // The deck is still stopped then; publishing that incidental state would
    // withdraw Android's foreground service before the audio focus request.
    final preparing =
        playerState == null &&
        loading == null &&
        !_sourceReady &&
        _switchingGeneration != 0 &&
        playbackState.value.processingState == AudioProcessingState.loading;
    final state = preparing
        ? (playbackState.value.playing
              ? PlaybackDeckState.playing
              : PlaybackDeckState.paused)
        : playerState ?? _player.state;
    if (preparing) loading = true;
    final failed = _playbackError != null;
    final playing = _progressiveCloseUnconfirmed
        ? playbackState.value.playing
        : !failed && state == PlaybackDeckState.playing;
    _upcoming.playingChanged(playing: playing, failed: failed);

    playbackState.add(
      playbackState.value.copyWith(
        controls: _runtime.notification.controls(
          playing: playing,
          item: mediaItem.value,
          shuffle: _shuffle,
        ),
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToPrevious,
          MediaAction.skipToNext,
        },
        androidCompactActionIndices: const [1, 2, 3],
        processingState: failed
            ? AudioProcessingState.error
            : (loading == true)
            ? AudioProcessingState.loading
            : _mapProcessingState(state),
        errorCode: failed ? 1 : null,
        errorMessage: _playbackError?.toString(),
        playing: playing,
        queueIndex: _index >= 0 ? _index : null,
        speed: _autoMix.rate,
        shuffleMode: _shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: _repeatMode,
      ),
    );
  }

  void refreshNotificationControls() {
    if (_disposed) return;
    final state = playbackState.value;
    playbackState.add(
      state.copyWith(
        // copyWith creates a fresh updateTime; keep the extrapolated position
        // so changing a star or theme cannot pull the scrubber backwards.
        updatePosition: state.position,
        controls: _runtime.notification.controls(
          playing: state.playing,
          item: mediaItem.value,
          shuffle: _shuffle,
        ),
        androidCompactActionIndices: const [1, 2, 3],
      ),
    );
  }

  bool _savingNotificationFavorite = false;
  bool _changingNotificationShuffle = false;

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == PlaybackNotification.favoriteAction) {
      final item = mediaItem.value;
      if (item == null || _savingNotificationFavorite) return;
      _savingNotificationFavorite = true;
      try {
        final loved = await _runtime.toggleFavorite(item);
        final current = mediaItem.value;
        if (!_disposed &&
            loved != null &&
            current?.id == item.id &&
            current?.extras?['source'] == item.extras?['source']) {
          // Widget/provider rebuilds may wait for a frame while the app is
          // backgrounded. Publish the persisted result directly to the OS.
          _runtime.updateFavorite(item, loved);
        }
      } catch (error) {
        _log.w('Notification favorite failed: $error');
      } finally {
        _savingNotificationFavorite = false;
      }
    } else if (name == PlaybackNotification.shuffleAction) {
      if (mediaItem.value == null || _changingNotificationShuffle) return;
      _changingNotificationShuffle = true;
      try {
        await setShuffleMode(
          _shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all,
        );
      } catch (error) {
        _log.w('Notification shuffle failed: $error');
      } finally {
        _changingNotificationShuffle = false;
      }
    } else {
      return super.customAction(name, extras);
    }
  }

  void _broadcastPosition(
    Duration position, {
    bool force = false,
    Duration? readAt,
  }) {
    final now = DateTime.now();
    final lastAt = _lastPositionBroadcastAt;
    final elapsed = lastAt == null ? null : now.difference(lastAt);
    final moved = (position - _lastBroadcastPosition).abs();
    if (!force &&
        elapsed != null &&
        elapsed < _positionBroadcastInterval &&
        moved < _positionBroadcastInterval) {
      return;
    }
    _lastPositionBroadcastAt = now;
    _lastPositionReadAt = readAt ?? _positionClock.elapsed;
    _lastBroadcastPosition = position;
    if (force) _positionCheckDue = true;
    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
        speed: _autoMix.rate,
      ),
    );
  }

  /// Whether a position tick of [player] can change anything. The handler
  /// ignores other decks and songs still switching. The gate above passes
  /// a position [_positionBroadcastInterval] after the engine read the last
  /// one (which arrived a round trip later), and the session is saved every
  /// [_positionPersistInterval]. After a forced broadcast the next tick
  /// still reads the engine, which may be far from the published position.
  /// AutoMix, gapless playback and Autoplay get every tick they act on.
  bool _wantsPosition(PlaybackDeck player) {
    if (!identical(player, _player) ||
        !_sourceReady ||
        _switchingGeneration != 0) {
      return false;
    }
    final now = _positionClock.elapsed;
    final readAt = _lastPositionReadAt;
    final persistedAt = _lastPeriodicPersistAt;
    if (!_positionCheckDue &&
        readAt != null &&
        now - readAt < _positionBroadcastInterval - _positionQueryAllowance &&
        persistedAt != null &&
        DateTime.now().difference(persistedAt) <
            _positionPersistInterval - _positionQueryAllowance) {
      final estimate = _lastBroadcastPosition + (now - readAt) * _autoMix.rate;
      if (!_autoMix.wantsPosition(estimate) &&
          !_gapless.wantsPosition(estimate) &&
          !_autoplay.wouldFill) {
        return false;
      }
    }
    _positionQueriedAt = now;
    return true;
  }

  void _handlePositionChanged(Duration position) {
    if (!_sourceReady || _switchingGeneration != 0) return;
    final readAt = _positionQueriedAt;
    _positionQueriedAt = null;
    _positionCheckDue = false;
    _broadcastPosition(position, readAt: readAt);
    _autoMix.onPosition(position);
    _prefetch.onPosition(position);
    _gapless.onPosition(position);
    unawaited(_autoplay.fill());
    if (_restoringSession ||
        _player.state != PlaybackDeckState.playing ||
        _media.isEmpty ||
        _index < 0 ||
        _index >= _media.length) {
      return;
    }

    final now = DateTime.now();
    final lastPersistAt = _lastPeriodicPersistAt;
    if (lastPersistAt != null &&
        now.difference(lastPersistAt) < _positionPersistInterval) {
      return;
    }
    _lastPeriodicPersistAt = now;
    unawaited(_persistSession(position: position));
  }

  late final PlaybackNormalizationCache _normalizationCache;
  int _normalizationGeneration = 0;

  Future<void> _refreshNormalizationSource(String source) async {
    _normalizationGeneration++;
    _normalizationCache.invalidate(source);
    await _sourceCache.invalidate(source, waitForPending: true);
    // A FLAC copy carries the tags it was made with.
    await _formats.invalidate(source);
    if (_disposed) return;
    if (_index >= 0 &&
        _index < _media.length &&
        _media[_index].source == source) {
      reapplyNormalization();
    }
  }

  Future<double> _normalizationVolumeFor(
    String path, {
    String? cacheKey,
    String? displayName,
  }) async {
    if (const {
          'network',
          'http',
          'https',
        }.contains(Uri.tryParse(path)?.scheme) ||
        // A network song keeps its loudness whether or not it is cached.
        _prefetch.owns(path) ||
        !_settings.playbackNormalization ||
        _settings.usbBitPerfect ||
        _player.isDirect) {
      return 1.0;
    }
    return _normalizationCache.volumeFor(
      path,
      cacheKey: cacheKey,
      displayName: displayName,
      preampDb: _settings.playbackNormalizationPreamp,
      preferAlbumGain: _settings.playbackNormalizationMode == 'album',
    );
  }

  /// What the active output path applies to the playing track, for the
  /// audio information sheet.
  PlaybackProcessing get processing => PlaybackProcessing(
    normalizationGain: _normalizationVolume,
    direct: _player.isDirect,
    autoMixRate: _autoMix.rate,
  );

  Future<void> refreshOutputStatus() async {
    final player = _player;
    if (player is AudioplayersPlaybackDeck) await player.refreshNativeStatus();
  }

  /// Re-applies normalization to the playing track when the setting flips.
  void reapplyNormalization() {
    final index = _index;
    final generation = _playRequestGeneration;
    final normalizationGeneration = ++_normalizationGeneration;
    if (index < 0 || index >= _media.length) return;
    unawaited(() async {
      await _cancelTransitions();
      if (generation != _playRequestGeneration ||
          index != _index ||
          index >= _media.length ||
          _disposed) {
        return;
      }
      final media = _media[index];
      var resolved = media.isContentUri
          ? _sourceCache.cachedPath(media.source)
          : media.source;
      ContentUriPlaybackLease? playbackLease;
      if (resolved == null && media.isContentUri) {
        try {
          playbackLease = await PlatformBridge.openContentUriPlaybackLease(
            media.source,
          );
          resolved = playbackLease?.path;
        } catch (_) {}
        resolved ??= await _resolveSource(media);
      }
      if (resolved == null) return;
      final volume = await _normalizationVolumeFor(
        resolved,
        cacheKey: media.isContentUri ? media.source : null,
        displayName: playbackLease?.displayName,
      );
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      if (_index != index ||
          generation != _playRequestGeneration ||
          normalizationGeneration != _normalizationGeneration) {
        return;
      }
      try {
        await _player.setVolume(volume);
        _normalizationVolume = volume;
      } catch (e) {
        _log.w('Failed to apply normalization volume: $e');
      }
    }());
  }

  Future<String?> _resolveSource(PlayableMedia media) async {
    if (_dependencies.sourceDeletionEvents.isDeleting(media.source)) {
      return null;
    }
    if (media.source.startsWith('network://')) {
      try {
        final copy = await _dependencies.offlineCopy(media.source);
        if (copy != null) {
          final resolved = copy.startsWith('content://')
              ? await _sourceCache.resolve(copy)
              : copy;
          if (resolved != null) return resolved;
        }
      } catch (_) {
        // An unavailable local copy leaves the server source usable.
      }
      // A whole prefetched copy opens as a local file on every engine; a
      // song still downloading streams from the server instead.
      if (await _prefetch.lookup(media) case final cached?) return cached;
      try {
        return await _dependencies.resolveNetworkSource(media.source);
      } catch (_) {
        _log.w('Network source is unavailable');
        return null;
      }
    }
    if (media.originSource case final origin?) {
      if (!await fileExists(media.source)) {
        try {
          return await _dependencies.resolveNetworkSource(origin);
        } catch (_) {
          return null;
        }
      }
    }
    if (!media.isContentUri) {
      if (_runtime.arrivingFile(media.source) case final arriving?) {
        return arriving.url;
      }
      // A song a paired phone sent whose received copy is gone: the phone
      // sends it again, else it is unavailable.
      try {
        return await _dependencies.recoverMissingFile(media.source) ??
            media.source;
      } catch (error) {
        _log.w('Song file is gone and could not be fetched again: $error');
        return null;
      }
    }
    final resolved = await _sourceCache.resolve(media.source);
    if (resolved == null && media.originSource != null) {
      try {
        return await _dependencies.resolveNetworkSource(media.originSource!);
      } catch (_) {}
    }
    return resolved;
  }

  Future<void> _cleanupPendingResolvedPaths() => _sourceCache.releaseUnpinned();

  void _markSessionQueueChanged() => _sessionWriter.queueChanged();

  PlaybackSessionQueue _sessionQueue() {
    final media = List.of(_media);
    final original = _originalQueueOrder;
    if (original == null) return (media: media, originalIndices: null);
    final ranks = Map<MediaItem, int>.identity();
    for (var i = 0; i < original.length; i++) {
      ranks[original[i]] = i;
    }
    return (
      media: media,
      originalIndices: [
        for (var i = 0; i < _media.length; i++) ranks[_queueItems[i]] ?? i,
      ],
    );
  }

  void _applyQueueOrder(List<MediaItem> order) {
    final current = _index >= 0 && _index < _queueItems.length
        ? _queueItems[_index]
        : null;
    final media = Map<MediaItem, PlayableMedia>.identity();
    for (var i = 0; i < _media.length; i++) {
      media[_queueItems[i]] = _media[i];
    }
    _queueItems
      ..clear()
      ..addAll(order);
    _media
      ..clear()
      ..addAll(order.map((item) => media[item]!));
    _index = current == null
        ? -1
        : order.indexWhere((item) => identical(item, current));
    _playHistory.clear();
    if (_index >= 0) _playHistory.add(_index);
  }

  /// Shuffles the queue so that [first] (the current song by default) opens
  /// it. Autoplay additions keep their order after the chosen songs.
  void _shuffleQueue([int? first]) {
    _originalQueueOrder ??= List.of(_queueItems);
    final start = first ?? _index;
    final manual = [
      for (var i = 0; i < _media.length; i++)
        if (i == start || !_media[i].autoplay) i,
    ];
    final startAt = manual.indexOf(start);
    final smart = _shuffleStrategy == ShuffleStrategy.smart;
    final order = smart
        ? smartShuffleOrder(
            [for (final i in manual) _media[i]],
            signals:
                _listeningSignals ?? SnapshotListeningSignals(now: DateTime.now()),
            random: _random,
            first: startAt < 0 ? null : startAt,
            session: _smartSession,
          )
        : buildShuffledQueueOrder(
            mediaCount: manual.length,
            currentIndex: startAt,
            random: _random,
          );
    _smartManaged
      ..clear()
      ..addAll(smart ? [for (final i in manual) _queueItems[i]] : const []);
    _applyQueueOrder([
      ...order.map((index) => _queueItems[manual[index]]),
      for (var i = 0; i < _media.length; i++)
        if (i != start && _media[i].autoplay) _queueItems[i],
    ]);
  }

  /// The queue index that opens the next repeat-all pass. In shuffle mode it
  /// is a random queued song, not an Autoplay addition, other than the one
  /// that just finished.
  int _repeatPassStart() {
    if (!_shuffle) return 0;
    final candidates = [
      for (var i = 0; i < _media.length; i++)
        if (i != _index && !_media[i].autoplay) i,
    ];
    if (candidates.isEmpty) return 0;
    if (_shuffleStrategy == ShuffleStrategy.smart) {
      final pick = smartShufflePick(
        [for (final i in candidates) _media[i]],
        signals:
            _listeningSignals ?? SnapshotListeningSignals(now: DateTime.now()),
        random: _random,
        session: _smartSession,
      );
      return candidates[max(0, pick)];
    }
    return candidates[_random.nextInt(candidates.length)];
  }

  ShuffleStrategy get shuffleStrategy => _shuffleStrategy;

  Stream<ShuffleStrategy> shuffleStrategyChanges() =>
      Stream<ShuffleStrategy>.multi((listener) {
        listener.addSync(_shuffleStrategy);
        final events = _shuffleStrategyEvents.stream.listen(listener.addSync);
        listener.onCancel = events.cancel;
      });

  void _setShuffleStrategy(ShuffleStrategy strategy) {
    final changed = strategy != _shuffleStrategy;
    _shuffleStrategy = strategy;
    _shuffle = strategy.enabled;
    if (changed) {
      _smartSession.clear();
      _smartManaged.clear();
      if (!_shuffleStrategyEvents.isClosed) {
        _shuffleStrategyEvents.add(strategy);
      }
    }
  }

  Future<void> _refreshListeningSignals() async {
    final at = _listeningSignalsAt;
    if (_listeningSignals != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 10)) {
      return;
    }
    try {
      _listeningSignals = await _dependencies.loadListeningSignals(
        _runtime.taste,
      );
    } catch (error) {
      _log.w('Listening signals unavailable for smart shuffle: $error');
      _listeningSignals ??= SnapshotListeningSignals(now: DateTime.now());
    }
    _listeningSignalsAt = DateTime.now();
  }

  void _adaptSmartShuffle({required bool userSkip}) {
    if (_shuffleStrategy != ShuffleStrategy.smart || _index < 0) return;
    final outgoing = mediaItem.value;
    final source = outgoing?.extras?['source']?.toString();
    if (outgoing == null || source == null) return;
    if (_index >= _media.length || _media[_index].source == source) return;
    final at = _media.indexWhere((media) => media.source == source);
    if (at < 0) return;
    final position = playbackState.value.position;
    final duration = outgoing.duration;
    final listenedThrough = duration != null && duration > Duration.zero
        ? position * 2 >= duration
        : position >= const Duration(seconds: 90);
    if (userSkip && position < const Duration(seconds: 15)) {
      _smartSession.skipped(_media[at]);
    } else if (listenedThrough) {
      _smartSession.completed(_media[at]);
    } else {
      return;
    }
    _reorderSmartFuture();
  }

  void _reorderSmartFuture() {
    final signals = _listeningSignals;
    if (signals == null || _index < 0 || _smartManaged.isEmpty) return;
    final order = smartShuffleReorderFuture(
      _media,
      currentIndex: _index,
      movable: {
        for (var i = 0; i < _queueItems.length; i++)
          if (_smartManaged.contains(_queueItems[i])) i,
      },
      signals: signals,
      random: _random,
      session: _smartSession,
    );
    var changed = false;
    for (var i = 0; i < order.length; i++) {
      if (order[i] != i) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    final items = [for (final i in order) _queueItems[i]];
    final media = [for (final i in order) _media[i]];
    _queueItems
      ..clear()
      ..addAll(items);
    _media
      ..clear()
      ..addAll(media);
    _upcoming.refresh();
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
  }

  /// Returns to the start for repeat all and gives the index to play. In
  /// shuffle mode each pass plays in a new order that opens with [start],
  /// so the queue does not loop through the same order again.
  int _beginRepeatPass(int start) {
    if (!_shuffle || start < 0 || start >= _media.length) return 0;
    _shuffleQueue(start);
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    return 0;
  }

  void _rememberEnqueued(List<MediaItem> items, {required bool playNext}) {
    final original = _originalQueueOrder;
    if (original == null) return;
    final current = _queueItems[_index];
    final at = original.indexWhere((item) => identical(item, current));
    final firstAutoplay = original.indexWhere(
      (item) => item.extras?['autoplay'] == true && !identical(item, current),
      max(0, at + 1),
    );
    original.insertAll(
      playNext && at >= 0
          ? at + 1
          : firstAutoplay >= 0
          ? firstAutoplay
          : original.length,
      items,
    );
  }

  /// Persists the queue only when it changed. Periodic position updates write
  /// fixed-size scalar columns, avoiding full queue JSON serialization every
  /// ten seconds for large playback sessions.
  Future<void> _persistSession({Duration? position}) {
    if (_restoringSession) return Future<void>.value();
    if (_media.isEmpty || _index < 0 || _index >= _media.length) {
      return _sessionWriter.clear();
    }
    return _sessionWriter.persist(
      queue: _sessionQueue,
      index: _index,
      position: position ?? Duration.zero,
      shuffle: _shuffle,
      repeatMode: _repeatMode.name,
    );
  }

  Future<Duration> _currentPositionForPersist() async {
    // During restore/source preparation the engine may report a stale zero (or
    // the previous source). The broadcast position already represents the
    // intended start point for the current queue item.
    if (!_sourceReady) return playbackState.value.position;
    try {
      final position = await _player.getCurrentPosition();
      if (position != null) return position;
    } catch (_) {}
    return playbackState.value.position;
  }

  /// Flushes the live engine position and every older queued session write.
  /// Called when the app leaves the foreground so a normal restart resumes at
  /// the latest audible point rather than the beginning of the track.
  Future<void> persistCurrentSession() async {
    if (_media.isEmpty || _index < 0 || _index >= _media.length) return;
    final position = await _currentPositionForPersist();
    _lastPeriodicPersistAt = DateTime.now();
    await _persistSession(position: position);
  }

  /// Restores a persisted session paused: queue and current track become
  /// visible (mini player included) without loading any source; the first
  /// play() prepares the source directly at the saved position.
  Future<void> restoreSession({
    required List<PlayableMedia> items,
    required int index,
    required Duration position,
    required bool shuffle,
    List<int>? originalOrder,
    bool queueNeedsRewrite = false,
    bool replaceStoppedQueue = false,
    AudioServiceRepeatMode repeatMode = AudioServiceRepeatMode.none,
  }) async {
    if (items.isEmpty) return;
    // Network songs show their stored covers from the first item.
    if (items.any(
      (item) => item.coverReference != null || CoverStore.fetches(item.source),
    )) {
      await _dependencies.coverStore.warmUp();
      if (_disposed) return;
    }
    // Never clobber a session the user already started this launch.
    if (_index >= 0 || (_media.isNotEmpty && !replaceStoppedQueue)) return;
    _restoringSession = true;
    try {
      _media
        ..clear()
        ..addAll(items);
      _queueItems
        ..clear()
        ..addAll(items.map(_toMediaItem));
      _index = index.clamp(0, items.length - 1);
      _setShuffleStrategy(
        shuffle
            ? (_shuffleStrategy.enabled
                  ? _shuffleStrategy
                  : ShuffleStrategy.random)
            : ShuffleStrategy.off,
      );
      _originalQueueOrder = null;
      if (shuffle) {
        final order = [for (var i = 0; i < items.length; i++) i];
        if (originalOrder?.length == items.length) {
          order.sort((a, b) => originalOrder![a].compareTo(originalOrder[b]));
        }
        _originalQueueOrder = order.map((i) => _queueItems[i]).toList();
      }
      _repeatMode = repeatMode;
      _pendingRestorePosition = position > Duration.zero ? position : null;
      _sourceReady = false;
      _lastPeriodicPersistAt = null;
      _sessionWriter.queueRestored(needsRewrite: queueNeedsRewrite);
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      mediaItem.add(_toMediaItem(_media[_index]));
      _covers.fetchFor(_media[_index]);
      if (position > Duration.zero) {
        playbackState.add(
          playbackState.value.copyWith(updatePosition: position),
        );
      }
      _broadcastState(playerState: PlaybackDeckState.paused);
    } finally {
      _restoringSession = false;
    }
    if (queueNeedsRewrite) {
      await _persistSession(position: position);
    }
    _autoplay.updateMode();
  }

  /// Shows the restored song's cover from its file when the saved session
  /// kept none, as playing it would. The desktop backend reads files only
  /// once extensions are ready, which may be after the restore.
  Future<void> recoverRestoredArtwork() async {
    if (_index < 0 || _index >= _media.length) return;
    final media = _media[_index];
    if (media.isNetwork) return;
    await _recoverEmbeddedArtwork(media, _playRequestGeneration);
  }

  bool _isCurrentPlayRequest(int generation, PlayableMedia media) {
    return !_disposed &&
        !_dependencies.sourceDeletionEvents.isDeleting(media.source) &&
        generation == _playRequestGeneration &&
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].id == media.id &&
        _media[_index].source == media.source;
  }

  /// Captures all local occurrences with a revision for transactional import.
  ({List<PlayableMedia> entries, int revision, int currentIndex})
  captureJamQueue() => (
    entries: List.unmodifiable(_media),
    revision: _sessionQueueRevision,
    currentIndex: _index,
  );

  /// Reads the latest local media for a session occurrence after a relink.
  PlayableMedia? jamMediaForOccurrence(String occurrenceId) {
    for (var i = 0; i < _queueItems.length; i++) {
      if (_queueItems[i].extras?['jamOccurrenceId'] == occurrenceId) {
        return _media[i];
      }
    }
    return null;
  }

  /// Replaces the queue without touching the deck, preserving occurrences.
  Future<void> reconcileJamQueue(
    List<({String occurrenceId, PlayableMedia media})> entries, {
    int? expectedQueueRevision,
    int? expectedCurrentIndex,
    String? initialCurrentOccurrenceId,
  }) async {
    if (_disposed) throw StateError('Player disposed');
    // A native queued output may already have advanced before its callback is
    // delivered. Its API cannot atomically prove which source is audible.
    if ((_index >= 0 || _sourceReady || _switchingGeneration != 0) &&
        _player is QueuedPlaybackDeck &&
        (_player as QueuedPlaybackDeck).canQueueNextSource) {
      throw StateError('Jam cannot verify the active native queued source');
    }
    if (_cast.active) throw StateError('Jam requires local playback');
    if (_gapless.jamSourceIsUncertain) {
      throw StateError('Jam cannot verify a native gapless transition');
    }
    void validateRevision() {
      if (expectedQueueRevision != null &&
          expectedQueueRevision != _sessionQueueRevision) {
        throw StateError('Local queue changed while starting Jam');
      }
      if (expectedCurrentIndex != null && expectedCurrentIndex != _index) {
        throw StateError('Current occurrence changed while starting Jam');
      }
    }

    validateRevision();
    _applyJamQueue(
      entries,
      validateOnly: true,
      initialCurrentOccurrenceId: initialCurrentOccurrenceId,
    );
    final wasActive = _jamQueueActive;
    try {
      _jamQueueActive = true;
      _autoplay.reset();
      await _autoMix.cancel();
      // Unlink any natively chained source before accepting a new queue.
      await _gapless.cancel(requireUnlink: true);
      validateRevision();
      _applyJamQueue(
        entries,
        initialCurrentOccurrenceId: initialCurrentOccurrenceId,
      );
    } catch (_) {
      _jamQueueActive = wasActive;
      rethrow;
    }
  }

  void endJamQueue() {
    _jamQueueActive = false;
    _jamPlaybackOccurrencesChanged = null;
    _jamAudibleOccurrence = null;
    _jamTransitionPending = false;
    _jamTransitionInFlight = false;
    _jamPendingOccurrence = null;
  }

  void _applyJamQueue(
    List<({String occurrenceId, PlayableMedia media})> entries, {
    bool validateOnly = false,
    String? initialCurrentOccurrenceId,
  }) {
    if (_disposed) throw StateError('Player disposed');
    // Resolution can await database work or automation cancellation. Retain
    // the newest host-local source/metadata for every surviving occurrence.
    entries = [
      for (final entry in entries)
        (
          occurrenceId: entry.occurrenceId,
          media: jamMediaForOccurrence(entry.occurrenceId) ?? entry.media,
        ),
    ];
    final ids = <String>{};
    for (final entry in entries) {
      final source = entry.media.source;
      final scheme = Uri.tryParse(source)?.scheme.toLowerCase() ?? '';
      if (entry.occurrenceId.isEmpty ||
          !ids.add(entry.occurrenceId) ||
          source.trim().isEmpty ||
          (scheme.isNotEmpty &&
              scheme != 'file' &&
              scheme != 'content' &&
              !(scheme.length == 1 &&
                  RegExp(r'^[A-Za-z]:[\\/]').hasMatch(source)))) {
        throw StateError('Invalid Jam queue entry');
      }
    }
    final current = _index >= 0 && _index < _media.length
        ? _media[_index]
        : null;
    final currentItem = current == null ? null : _queueItems[_index];
    final occurrence =
        initialCurrentOccurrenceId ?? currentItem?.extras?['jamOccurrenceId'];
    var newIndex = -1;
    if (current != null) {
      final matches = <int>[];
      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        if (entry.media.id == current.id &&
            entry.media.source == current.source &&
            (occurrence == null || occurrence == entry.occurrenceId)) {
          matches.add(i);
        }
      }
      if (matches.length != 1) {
        throw StateError('Jam queue cannot preserve the current occurrence');
      }
      newIndex = matches.single;
    }
    if (validateOnly) return;
    final items = <MediaItem>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final base = i == newIndex ? currentItem! : _toMediaItem(entry.media);
      items.add(
        base.copyWith(
          extras: {...?base.extras, 'jamOccurrenceId': entry.occurrenceId},
        ),
      );
    }
    // A recommendation batch started against the previous queue must not
    // append itself after this authoritative projection has been applied.
    _autoplay.reset();
    _media
      ..clear()
      ..addAll(entries.map((entry) => entry.media));
    _queueItems
      ..clear()
      ..addAll(items);
    _index = newIndex;
    _originalQueueOrder = _shuffle ? List.of(items) : null;
    _playHistory.clear();
    if (_index >= 0) _playHistory.add(_index);
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> setQueueAndPlay(
    List<PlayableMedia> items, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool? shuffle,
  }) async {
    _rejectLocalJamQueueEdit();
    if (items.isEmpty) return;
    if (_shuffleStrategy == ShuffleStrategy.smart) {
      await _refreshListeningSignals();
      _rejectLocalJamQueueEdit();
    }
    _queueRequestGeneration++;
    _autoplay.reset();
    _playRequestGeneration++;
    _media
      ..clear()
      ..addAll(items);
    _queueItems
      ..clear()
      ..addAll(items.map(_toMediaItem));
    _originalQueueOrder = null;
    _index = initialIndex.clamp(0, items.length - 1);
    // An explicit mode accompanies a queue already in play order, as when
    // playback moves between devices. Adopt it without shuffling a second time.
    if (shuffle != null) {
      _setShuffleStrategy(
        shuffle
            ? (_shuffleStrategy.enabled
                  ? _shuffleStrategy
                  : ShuffleStrategy.random)
            : ShuffleStrategy.off,
      );
    }
    if (_shuffleStrategy == ShuffleStrategy.smart &&
        !smartShuffleEligible(items)) {
      _setShuffleStrategy(ShuffleStrategy.random);
    }
    _smartSession.clear();
    if (_shuffle && shuffle == null) _shuffleQueue();
    _markSessionQueueChanged();
    _playHistory.clear();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    await _playIndex(_index, startPosition: initialPosition);
  }

  Future<void> enqueue(PlayableMedia item, {bool playNext = false}) async {
    _rejectLocalJamQueueEdit();
    if (_media.isEmpty || _index < 0) {
      await setQueueAndPlay([item]);
      return;
    }
    final insertAt = playNext
        ? (_index + 1).clamp(0, _media.length)
        : _autoplay.manualInsertIndex;
    _media.insert(insertAt, item);
    final queueItem = _toMediaItem(item);
    _queueItems.insert(insertAt, queueItem);
    _rememberEnqueued([queueItem], playNext: playNext);
    _upcoming.refresh();
    _markSessionQueueChanged();

    for (var i = 0; i < _playHistory.length; i++) {
      if (_playHistory[i] >= insertAt) _playHistory[i]++;
    }

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> enqueueAll(
    List<PlayableMedia> items, {
    bool playNext = false,
  }) async {
    _rejectLocalJamQueueEdit();
    if (items.isEmpty) return;
    if (_media.isEmpty || _index < 0) {
      await setQueueAndPlay(items);
      return;
    }
    var at = playNext
        ? (_index + 1).clamp(0, _media.length)
        : _autoplay.manualInsertIndex;
    final queued = <MediaItem>[];
    for (final item in items) {
      _media.insert(at, item);
      final queueItem = _toMediaItem(item);
      _queueItems.insert(at, queueItem);
      queued.add(queueItem);
      for (var i = 0; i < _playHistory.length; i++) {
        if (_playHistory[i] >= at) _playHistory[i]++;
      }
      at++;
    }
    _rememberEnqueued(queued, playNext: playNext);
    _upcoming.refresh();
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    _rejectLocalJamQueueEdit();
    if (oldIndex < 0 ||
        oldIndex >= _media.length ||
        newIndex < 0 ||
        newIndex >= _media.length ||
        oldIndex == newIndex) {
      return;
    }
    final media = _media.removeAt(oldIndex);
    final qi = _queueItems.removeAt(oldIndex);
    _media.insert(newIndex, media);
    _queueItems.insert(newIndex, qi);
    _markSessionQueueChanged();

    if (_index == oldIndex) {
      _index = newIndex;
    } else {
      if (oldIndex < _index && newIndex >= _index) {
        _index--;
      } else if (oldIndex > _index && newIndex <= _index) {
        _index++;
      }
    }

    _playHistory.clear();
    _upcoming.refresh();

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  /// Removes one queued occurrence, including when the same song is queued
  /// twice. The current source is protected if playback advances mid-gesture.
  void removeQueuedItem(MediaItem item) {
    _rejectLocalJamQueueEdit();
    final at = _queueItems.indexWhere((entry) => identical(entry, item));
    if (_disposed || at < 0 || at == _index) return;
    _autoplay.dismiss(_media[at]);
    _queueItems.removeAt(at);
    _media.removeAt(at);
    _originalQueueOrder?.removeWhere((entry) => identical(entry, item));
    if (at < _index) _index--;
    final history = [
      for (final index in _playHistory)
        if (index != at) index > at ? index - 1 : index,
    ];
    _playHistory
      ..clear()
      ..addAll(history);
    _markSessionQueueChanged();
    unawaited(_cancelTransitions());
    _upcoming.refresh();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> _playIndex(
    int index, {
    bool recordHistory = true,
    bool userSkip = false,
    bool startPaused = false,
    Duration startPosition = Duration.zero,
    bool preserveListeningSession = false,
    bool resumeOccurrence = false,
    bool forceReload = false,
  }) async {
    if (_disposed || index < 0 || index >= _media.length) return;
    final inFlight = _inFlightLoad;
    if (inFlight != null &&
        !forceReload &&
        !_jamQueueActive &&
        !startPaused &&
        !resumeOccurrence &&
        !_userPaused &&
        !_stopRequested &&
        !_sourceReady &&
        !_cast.changingOutput &&
        _preparingCatalogTrack != null &&
        inFlight.generation == _playRequestGeneration &&
        index == _index &&
        !inFlight.startPaused &&
        inFlight.startPosition == startPosition &&
        inFlight.media.id == _media[index].id &&
        inFlight.media.source == _media[index].source) {
      const reuse =
          'playback: play requested again while the same song is preparing; '
          'keeping the preparation';
      debugPrint(reuse);
      _log.i(reuse);
      _broadcastState(loading: true);
      await inFlight.done;
      return;
    }
    String? jamTarget;
    final wasJamPending = _jamTransitionPending;
    if (_jamQueueActive && _jamPlaybackOccurrencesChanged != null) {
      final occurrence = _queueItems[index].extras?['jamOccurrenceId'];
      if (_jamTransitionInFlight ||
          occurrence is! String ||
          (_jamTransitionPending && occurrence != _jamPendingOccurrence) ||
          !_jamPlaybackOccurrencesChanged!(_jamAudibleOccurrence, occurrence)) {
        return;
      }
      jamTarget = occurrence;
      _jamTransitionPending = true;
      _jamTransitionInFlight = true;
      _jamPendingOccurrence = occurrence;
    }
    if (_dependencies.sourceDeletionEvents.isDeleting(_media[index].source)) {
      if (jamTarget != null) {
        _jamTransitionInFlight = false;
        if (!wasJamPending) {
          _jamPlaybackOccurrencesChanged?.call(_jamAudibleOccurrence, null);
          _jamTransitionPending = false;
          _jamPendingOccurrence = null;
        }
      }
      return;
    }
    if (_reloadingAfterServerDied) {
      _reloadingAfterServerDied = false;
    } else {
      _serverDiedReloads = 0;
    }
    _runtime.personalization.finish(
      skipped:
          userSkip &&
          mediaItem.value?.extras?['source'] != _media[index].source,
    );
    _adaptSmartShuffle(userSkip: userSkip);
    _playbackAutomation.cancelPendingActions();
    // Keep the requested position until preparation succeeds, including
    // when Pause cancels preparation before the decoder is ready.
    _pendingRestorePosition = startPosition;
    _userPaused = startPaused;
    final previousPreparation = _preparingCatalogTrack;
    final previousExperimental = _experimentalAttempt;
    final previousPendingStart = _experimentalPendingStart;
    _experimentalAttempt = null;
    if (previousExperimental != null) {
      _beginExperimentalClose(previousExperimental);
    } else if (previousPendingStart != null) {
      _trackExperimentalClose(
        previousPendingStart
            .then((attempt) => attempt?.cancel() ?? Future.value(true))
            .catchError((Object _) => false),
      );
    }
    if (previousPreparation != null) {
      unawaited(
        _catalogPlayback.cancel(previousPreparation, retain: !forceReload),
      );
    }
    final generation = ++_playRequestGeneration;
    _stopRequested = false;
    _pausedLoadGeneration = 0;
    if (!resumeOccurrence) {
      _newPlaybackOccurrence();
    } else {
      _carryLoadingPermanentOffer(generation);
    }
    _preparedPausedDeck = null;
    _sourceReady = false;
    _playbackError = null;
    _progressiveCloseUnconfirmed = false;
    // Advance the requested index synchronously so consecutive Next taps do
    // not all target the same song while AutoMix/source preparation awaits.
    _index = index;
    unawaited(_autoplay.fill());
    final media = _media[index];
    _upcoming.requested(media);
    _switchingGeneration = generation;
    _cast.beginOutputChange(generation);
    final loadDone = Completer<void>();
    _inFlightLoad = (
      generation: generation,
      media: media,
      startPosition: startPosition,
      startPaused: startPaused,
      done: loadDone.future,
    );
    try {
      final closeBarrier = _experimentalCloseBarrier;
      if (closeBarrier != null) {
        final closed = await closeBarrier.timeout(
          const Duration(seconds: 3),
          onTimeout: () => false,
        );
        if (!_isCurrentPlayRequest(generation, media)) return;
        if (!closed) {
          _sourceReady = false;
          _userPaused = true;
          _progressiveCloseUnconfirmed = true;
          _playbackError = StateError(
            'Progressive source close was not confirmed; audio may still be playing',
          );
          _broadcastState(playerState: PlaybackDeckState.stopped);
          return;
        }
        if (identical(_experimentalCloseBarrier, closeBarrier))
          _experimentalCloseBarrier = null;
      }
      if (_stopPreparation != null) {
        await _waitForStopPreparation();
        if (!_isCurrentPlayRequest(generation, media)) return;
      }
      await _player.cancelPreparation();
      await _serializeSourceChange(() async {
        try {
          if (!_isCurrentPlayRequest(generation, media)) return;
          await _cancelTransitions();
          if (!_isCurrentPlayRequest(generation, media)) return;
          // Retire the audible source before publishing another song's title.
          await _player.stop();
          await _retireCatalogListening();
          if (!_isCurrentPlayRequest(generation, media)) return;
          await _loadIndex(
            generation,
            media,
            recordHistory: recordHistory,
            startPaused: startPaused,
            startPosition: startPosition,
            preserveListeningSession: preserveListeningSession,
          );
        } finally {
          if (_switchingGeneration == generation) _switchingGeneration = 0;
        }
      });
      await _drainLoadingPermanentOffer(generation);
    } finally {
      if (_inFlightLoad?.generation == generation) _inFlightLoad = null;
      if (!loadDone.isCompleted) loadDone.complete();
      _finishSourceLoad(generation);
      if (jamTarget != null && _jamPendingOccurrence == jamTarget) {
        _jamTransitionInFlight = false;
      }
    }
  }

  void _beginExperimentalClose(ExperimentalProgressiveAttempt attempt) {
    _trackExperimentalClose(attempt.cancel().catchError((Object _) => false));
  }

  void _trackExperimentalClose(Future<bool> barrier) {
    _experimentalCloseBarrier = barrier;
    unawaited(
      barrier.then((closed) {
        if (closed && identical(_experimentalCloseBarrier, barrier))
          _experimentalCloseBarrier = null;
      }),
    );
  }

  Future<void> _waitForStopPreparation() async {
    // An earlier Stop can still call the native deck's stop() when
    // cancellation completes. Let it finish before touching that deck.
    try {
      await _stopPreparation;
    } catch (_) {
      // The new request can retry cancellation after the earlier failure.
    }
  }

  void _newPlaybackOccurrence() {
    _playOccurrence = Object();
    _pendingSeek = null;
    _pausedLoadGeneration = 0;
    _loadingPermanentOffer = null;
    _pendingPermanentOffer = null;
  }

  void _carryLoadingPermanentOffer(int generation) {
    final offer = _loadingPermanentOffer;
    _loadingPermanentOffer =
        offer != null &&
            offer.generation == generation - 1 &&
            identical(offer.occurrence, _playOccurrence)
        ? (
            track: offer.track,
            path: offer.path,
            occurrence: offer.occurrence,
            generation: generation,
          )
        : null;
  }

  void _finishSourceLoad(int generation) {
    _cast.finishOutputChange(generation);
    if (generation != _playRequestGeneration) return;
    _loadingPermanentOffer = null;
    if (_switchingGeneration == generation) _switchingGeneration = 0;
  }

  Future<void> _drainLoadingPermanentOffer(int generation) async {
    if (_disposed || generation != _playRequestGeneration || !_sourceReady) {
      return;
    }
    final offer = _loadingPermanentOffer;
    if (offer == null ||
        offer.generation != generation ||
        !identical(offer.occurrence, _playOccurrence)) {
      return;
    }
    _loadingPermanentOffer = null;
    // onPermanentDownloadReady serializes its own deck change.
    await onPermanentDownloadReady(offer.track, offer.path);
  }

  Future<void> _serializeSourceChange(Future<void> Function() action) {
    final operation = _sourceChangeTail.then((_) => action());
    // A failed operation must not poison later transport requests.
    _sourceChangeTail = operation.catchError((Object _) {});
    return operation;
  }

  static bool _requiresDsd(PlayableMedia media) =>
      media.bitDepth == 1 ||
      const ['dsf', 'dff'].contains(media.format?.toLowerCase()) ||
      media.source.toLowerCase().endsWith('.dsf') ||
      media.source.toLowerCase().endsWith('.dff');

  /// Starts [path] and returns what plays: [path], or a FLAC copy when
  /// AVPlayer cannot open it.
  Future<String> _startResolvedSource(
    String path,
    int generation,
    PlayableMedia media,
    Duration? position, {
    bool startPaused = false,
    bool requireFocusOnResume = false,
  }) async {
    // AudioPlayer.play combines prepare/seek/resume without a cancellation
    // boundary. A late prepare from an old request could resume the wrong
    // source. Serialize preparation and recheck before making it audible.
    // Link may resolve a network song to its completed local copy.
    // A file still arriving resolves to its HTTP stream instead.
    try {
      if (const {'http', 'https'}.contains(Uri.tryParse(path)?.scheme)) {
        await _player.setNetworkSource(
          path,
          arriving: _runtime.streamsArrivingFile(path),
        );
      } else {
        await _player.setFileSource(
          path,
          preferBitPerfect: _settings.usbBitPerfect,
          directUsb: _settings.usbDirect,
          allowFixedVolume: _settings.usbAllowFixedVolume,
          dapExclusive: _settings.dapExclusive,
          allowDop: _settings.usbDsdOverPcm,
          requiresDsd: _requiresDsd(media),
        );
      }
    } catch (_) {
      if (!_isCurrentPlayRequest(generation, media)) rethrow;
      if (media.isCatalog) rethrow;
      final copy = await _formats.afterFailure(media, path);
      if (copy == null || !_isCurrentPlayRequest(generation, media)) rethrow;
      return _startResolvedSource(
        copy,
        generation,
        media,
        position,
        startPaused: startPaused,
        requireFocusOnResume: requireFocusOnResume,
      );
    }
    if (!_isCurrentPlayRequest(generation, media)) return path;
    Duration? desiredPosition() {
      var desired = requireFocusOnResume
          ? _experimentalRetirementSeek ?? position
          : position;
      if (desired == null) return null;
      if (desired < Duration.zero) desired = Duration.zero;
      final duration = media.duration;
      if (duration != null && duration > Duration.zero && desired > duration)
        desired = duration;
      return desired;
    }

    while (_isCurrentPlayRequest(generation, media)) {
      final desired = desiredPosition();
      if (desired != null) {
        await _player.seek(desired);
        if (!_isCurrentPlayRequest(generation, media)) return path;
      }
      if (requireFocusOnResume && desiredPosition() != desired) continue;
      if (!startPaused && !_userPaused) {
        if (requireFocusOnResume && !await _activateAudioSession(generation))
          throw StateError('Audio focus unavailable');
        if (!_isCurrentPlayRequest(generation, media)) return path;
        if (requireFocusOnResume && desiredPosition() != desired) continue;
        if (!_userPaused) await _player.resume();
      }
      if (requireFocusOnResume && desiredPosition() != desired) {
        await _player.pause();
        continue;
      }
      break;
    }
    if (!_isCurrentPlayRequest(generation, media) || _userPaused)
      await _player.pause();
    return path;
  }

  Future<void> _loadIndex(
    int generation,
    PlayableMedia media, {
    required bool recordHistory,
    required Duration startPosition,
    bool startPaused = false,
    required bool preserveListeningSession,
  }) async {
    await _cast.applyOutput(generation);
    if (!_isCurrentPlayRequest(generation, media)) return;
    if (_cast.changingOutput) {
      startPosition =
          _pendingSeekPosition ?? _pendingRestorePosition ?? startPosition;
      _pendingRestorePosition = startPosition;
      startPaused = startPaused || _userPaused;
      _cast.finishOutputChange(generation);
    }
    if (media.source.startsWith('network://')) {
      try {
        final copy = await _dependencies.offlineCopy(media.source);
        if (!_isCurrentPlayRequest(generation, media)) return;
        if (copy != null) {
          _relocateQueuedSource(media.source, copy, origin: media.source);
          media = _media[_index];
        }
      } catch (_) {
        // Keep the original source when a local lookup is unavailable.
      }
    }
    if (!_isCurrentPlayRequest(generation, media)) return;
    _pausedByInterruption = false;
    _interruptionActive = false;

    if (recordHistory) _recordPlayHistory(_index);

    var effectiveStartPosition = normalizedPlaybackResumePosition(
      startPosition,
      duration: media.duration,
    );
    _runtime.personalization.begin(_learningTrack(media));
    if (recordHistory && media.isCatalog) {
      AnonymousMetrics.recordStreamPlayed();
    }
    _playbackInstance++;
    if (!preserveListeningSession) _listeningInstance++;
    mediaItem.add(_toMediaItem(media));
    _lastBroadcastPosition = Duration.zero;
    _lastPositionBroadcastAt = null;
    _broadcastPosition(effectiveStartPosition, force: true);
    // Claim the playing state up front (while the app is still in the
    // foreground window) so audio_service can start its foreground service
    // before the async source resolve below.
    _broadcastState(
      playerState: startPaused
          ? PlaybackDeckState.paused
          : PlaybackDeckState.playing,
      loading: true,
    );
    await _claimHardwareMediaButtons();
    if (!_isCurrentPlayRequest(generation, media)) return;
    if (_dependencies.isAndroid && !media.isNetwork && !media.isCatalog) {
      try {
        final recovered = await _dependencies.recoverMovedDownload(
          media.source,
          media.id,
          _settings,
        );
        if (!_isCurrentPlayRequest(generation, media)) return;
        if (recovered != null && recovered != media.source) {
          _relocateQueuedSource(media.source, recovered);
          media = _media[_index];
          mediaItem.add(_toMediaItem(media));
        }
      } catch (error) {
        _log.w('Could not resolve a moved download: $error');
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
    }
    if (!media.isNetwork && !media.isCatalog) {
      unawaited(_recoverEmbeddedArtwork(media, generation));
    }
    _covers
      ..fetchFor(media)
      ..fetchAhead();

    // Android opens SAF files through a short-lived file-descriptor lease.
    // MediaPlayer duplicates that descriptor, so the original can be closed
    // immediately after play() without retaining a full-file cache copy.
    ContentUriPlaybackLease? playbackLease;
    if (_dependencies.isAndroid && media.isContentUri && !_cast.active) {
      try {
        playbackLease = await PlatformBridge.openContentUriPlaybackLease(
          media.source,
        );
      } catch (e) {
        _log.w('Failed to open direct SAF playback lease: $e');
      }
    }
    String? resolved;
    if (media.isCatalog) {
      final track = media.catalogTrack;
      if (track == null) throw StateError('Identidad de catálogo inválida');
      _catalogPlayback.defaultService = _settings.defaultService;
      _catalogPlayback.providerConfirmed = _settings.playbackProviderConfirmed;
      _catalogPlayback.quality = _settings.playbackQuality;
      _catalogPlayback.playbackBitrateKbps =
          int.tryParse(_settings.playbackCacheBitrate.replaceAll('k', '')) ??
          128;
      _catalogPlayback.useExtensions = _settings.useExtensionProviders;
      _catalogPlayback.useFallback = _settings.autoFallback;
      var experimentalStarted = false;
      var experimentalFinished = false;
      var experimentalCancelled = false;
      var retirementSeen = false;
      Duration? retirementPosition;
      var continuedWithProgressive = false;
      final catalogSettled = Completer<void>();
      ExperimentalDeckPreparation? experimentalDeck;
      ExperimentalProgressiveAttempt? attempt;
      Future<ExperimentalProgressiveAttempt?>? pendingStart;
      Future<void>? sourceReady;
      if (ExperimentalProgressiveTransfer.enabled &&
          _dependencies.isAndroid &&
          !_cast.active &&
          !_settings.usbBitPerfect &&
          !_settings.usbDirect &&
          !_settings.playbackNormalization &&
          _player is AudioplayersPlaybackDeck) {
        try {
          await _runtime.exclusiveAudioHook?.call();
          await _player.configureOutput();
          final focus = startPaused || await _activateAudioSession(generation);
          if (focus && _isCurrentPlayRequest(generation, media)) {
            await _player.setVolume(1);
            experimentalDeck = await (_player as AudioplayersPlaybackDeck)
                .beginExperimentalPreparation();
          }
        } catch (_) {
          experimentalDeck = null;
        }
      }
      _preparingCatalogTrack = track;
      try {
        final lease = await _catalogPlayback.acquire(
          track,
          initial: true,
          experimentalTransfer: experimentalDeck == null
              ? null
              : (payload) async {
                  if (experimentalCancelled)
                    throw const TemporaryTrackException('cancelled');
                  final transfer = _experimentalTransfer ??=
                      ExperimentalProgressiveTransfer();
                  pendingStart = transfer.start(
                    playerId: experimentalDeck!.playerId,
                    requestJson: jsonEncode({
                      ...payload.toJson(),
                      'temporary_playback': true,
                    }),
                  );
                  final currentStart = pendingStart!;
                  _experimentalPendingStart = currentStart;
                  try {
                    attempt = await currentStart;
                  } finally {
                    if (identical(_experimentalPendingStart, currentStart))
                      _experimentalPendingStart = null;
                  }
                  final current = attempt;
                  if (current == null) {
                    if (experimentalCancelled)
                      throw const TemporaryTrackException('cancelled');
                    return PlatformBridge.downloadTemporary(payload);
                  }
                  if (experimentalCancelled ||
                      !_isCurrentPlayRequest(generation, media)) {
                    await current.cancel();
                    throw const TemporaryTrackException('cancelled');
                  }
                  _experimentalAttempt = current;
                  unawaited(() async {
                    if (!await current.retiring ||
                        current.isCancelled ||
                        experimentalCancelled ||
                        !_isCurrentPlayRequest(generation, media))
                      return;
                    if (_experimentalRetiringGeneration != generation)
                      _experimentalRetirementSeek = null;
                    _experimentalRetiringGeneration = generation;
                    _sourceReady = false;
                  }());
                  unawaited(() async {
                    final position = await current.retired;
                    if (current.isCancelled ||
                        experimentalCancelled ||
                        !_isCurrentPlayRequest(generation, media))
                      return;
                    retirementSeen = true;
                    if (_experimentalRetiringGeneration != generation)
                      _experimentalRetirementSeek = null;
                    _experimentalRetiringGeneration = generation;
                    retirementPosition = position;
                    if (position != null) effectiveStartPosition = position;
                    experimentalStarted = false;
                    _sourceReady = false;
                    await catalogSettled.future;
                    if (!continuedWithProgressive ||
                        current.isCancelled ||
                        !_isCurrentPlayRequest(generation, media))
                      return;
                    if (position == null) {
                      if (_experimentalRetiringGeneration == generation)
                        _experimentalRetiringGeneration = 0;
                      _reportPlaybackError(
                        _player,
                        StateError('Progressive position unavailable'),
                        StackTrace.current,
                      );
                      return;
                    }
                    try {
                      if (!await current.cancel() ||
                          !_isCurrentPlayRequest(generation, media))
                        return;
                      if (identical(_experimentalAttempt, current))
                        _experimentalAttempt = null;
                      await _serializeSourceChange(() async {
                        if (!_isCurrentPlayRequest(generation, media)) return;
                        final validated = _catalogLease;
                        if (validated == null)
                          throw StateError(
                            'Validated catalog audio unavailable',
                          );
                        try {
                          await _runtime.exclusiveAudioHook?.call();
                        } catch (_) {}
                        if (!_isCurrentPlayRequest(generation, media)) return;
                        final volume = await _normalizationVolumeFor(
                          validated.path,
                        );
                        if (!_isCurrentPlayRequest(generation, media)) return;
                        await _player.configureOutput();
                        if (!_isCurrentPlayRequest(generation, media)) return;
                        if (!_isCurrentPlayRequest(generation, media)) return;
                        await _player.stop();
                        await _player.setVolume(volume);
                        _normalizationVolume = volume;
                        if (!_isCurrentPlayRequest(generation, media)) return;
                        await _startResolvedSource(
                          validated.path,
                          generation,
                          media,
                          position,
                          requireFocusOnResume: true,
                        );
                        if (!_isCurrentPlayRequest(generation, media)) return;
                        if (_userPaused) await _player.pause();
                        _sourceReady = true;
                        if (_experimentalRetiringGeneration == generation)
                          _experimentalRetiringGeneration = 0;
                        _preparedPausedDeck = _userPaused ? _player : null;
                        _broadcastState();
                      });
                    } catch (error, stackTrace) {
                      if (_experimentalRetiringGeneration == generation)
                        _experimentalRetiringGeneration = 0;
                      if (_isCurrentPlayRequest(generation, media))
                        _reportPlaybackError(_player, error, stackTrace);
                    }
                  }());
                  sourceReady = () async {
                    if (!await current.sourceAttached ||
                        !await experimentalDeck!.ready ||
                        experimentalFinished ||
                        retirementSeen ||
                        _experimentalRetiringGeneration == generation ||
                        !_isCurrentPlayRequest(generation, media))
                      return;
                    experimentalStarted = true;
                    if (effectiveStartPosition > Duration.zero)
                      await _player.seek(effectiveStartPosition);
                    if (!_isCurrentPlayRequest(generation, media) ||
                        _experimentalRetiringGeneration == generation)
                      return;
                    _sourceReady = true;
                    if (!_userPaused &&
                        !startPaused &&
                        _experimentalRetiringGeneration != generation)
                      await _player.resume();
                    if (!_isCurrentPlayRequest(generation, media) ||
                        _userPaused ||
                        _experimentalRetiringGeneration == generation) {
                      await _player.pause();
                      if (!_isCurrentPlayRequest(generation, media) ||
                          _experimentalRetiringGeneration == generation)
                        return;
                    }
                    _preparedPausedDeck = (_userPaused || startPaused)
                        ? _player
                        : null;
                    _broadcastState();
                  }();
                  String? raw;
                  try {
                    raw = await current.result;
                  } catch (_) {
                    experimentalFinished = true;
                    if (!experimentalStarted) await experimentalDeck!.cancel();
                    await sourceReady;
                    final stopped = await current.cancel();
                    if (identical(_experimentalAttempt, current))
                      _experimentalAttempt = null;
                    if (!experimentalStarted &&
                        !experimentalCancelled &&
                        stopped) {
                      return PlatformBridge.downloadTemporary(payload);
                    }
                    rethrow;
                  }
                  experimentalFinished = true;
                  if (!experimentalStarted) await experimentalDeck!.cancel();
                  await sourceReady;
                  if (retirementSeen && retirementPosition == null)
                    throw const TemporaryTrackException(
                      'progressive position unavailable',
                    );
                  if (current.wasInvalidated) {
                    final position = current.invalidatedPosition;
                    if (experimentalStarted && position == null)
                      throw const TemporaryTrackException(
                        'progressive position unavailable',
                      );
                    if (position != null) effectiveStartPosition = position;
                    experimentalStarted = false;
                    _sourceReady = false;
                  }
                  if (raw != null && !experimentalStarted) {
                    if (!await current.cancel())
                      throw const TemporaryTrackException('cancelled');
                    if (identical(_experimentalAttempt, current))
                      _experimentalAttempt = null;
                  }
                  if (raw == null) {
                    experimentalStarted = false;
                    _sourceReady = false;
                    final wasCancelled = current.isCancelled;
                    final stopped = await current.cancel();
                    if (identical(_experimentalAttempt, current))
                      _experimentalAttempt = null;
                    if (wasCancelled || !stopped || experimentalCancelled)
                      throw const TemporaryTrackException('cancelled');
                    return PlatformBridge.downloadTemporary(payload);
                  }
                  final decoded = jsonDecode(raw);
                  if (decoded is! Map)
                    throw const TemporaryTrackException(
                      'provider download failed',
                    );
                  return Map<String, dynamic>.from(decoded);
                },
          cancelExperimentalTransfer: experimentalDeck == null
              ? null
              : (id) async {
                  experimentalCancelled = true;
                  final current = attempt ?? await pendingStart;
                  if (current != null && !await current.cancel())
                    throw const TemporaryTrackException('cancelled');
                  await PlatformBridge.cancelDownload(id);
                },
        );
        if (!_isCurrentPlayRequest(generation, media)) {
          await lease.release();
          return;
        }
        _catalogLease = lease;
        _catalogPlayback.selectLease(track, lease);
        resolved = lease.path;
        if (experimentalStarted && _isCurrentPlayRequest(generation, media)) {
          continuedWithProgressive = true;
          _pendingRestorePosition = null;
          _activeResolvedPath = null;
          _failures.started(media, resolved);
          _broadcastState();
          unawaited(_persistSession(position: effectiveStartPosition));
          unawaited(_ensureDurationKnown(media, generation));
          return;
        }
      } catch (error, stackTrace) {
        if (_experimentalRetiringGeneration == generation)
          _experimentalRetiringGeneration = 0;
        if (attempt != null) {
          await attempt!.cancel();
          if (identical(_experimentalAttempt, attempt))
            _experimentalAttempt = null;
        }
        if (_isCurrentPlayRequest(generation, media)) {
          _reportPlaybackError(_player, error, stackTrace);
        }
        return;
      } finally {
        if (!catalogSettled.isCompleted) catalogSettled.complete();
        await experimentalDeck?.cancel();
        if (identical(_preparingCatalogTrack, track)) {
          _preparingCatalogTrack = null;
        }
      }
    } else {
      resolved = playbackLease?.path ?? await _formats.resolve(media);
    }
    var usingLocalSafCopy = media.isContentUri && playbackLease == null;
    if (!_isCurrentPlayRequest(generation, media)) {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      return;
    }
    if (resolved == null) {
      if (await _failures.skipMissing(
        media,
        resolved,
        generation,
        startPaused: startPaused,
      )) {
        return;
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
      _reportPlaybackError(
        _player,
        StateError('Audio file is unavailable'),
        StackTrace.current,
      );
      return;
    }

    try {
      await _runtime.exclusiveAudioHook?.call();
    } catch (_) {}
    if (!_isCurrentPlayRequest(generation, media)) {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      return;
    }

    _switchingGeneration = generation;
    try {
      // Set before play() so the track never starts at the wrong loudness;
      // always set (1.0 when disabled/untagged) so a previous track's
      // attenuation can't leak into the next one.
      var normalizationVolume = await _normalizationVolumeFor(
        resolved,
        cacheKey: media.isContentUri ? media.source : null,
        displayName: playbackLease?.displayName,
      );
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _player.configureOutput();
      if (!_isCurrentPlayRequest(generation, media)) return;
      var focusGranted =
          startPaused || _userPaused || await _activateAudioSession(generation);
      if (!_isCurrentPlayRequest(generation, media)) return;
      final relayedTrack = media.isCatalog &&
              media.catalogTrack != null &&
              _catalogPlayback.wasRelayed(media.catalogTrack!)
          ? media.catalogTrack
          : null;
      if (!focusGranted && relayedTrack != null && !_userPaused) {
        var retries = 0;
        for (final wait in _relayFocusRetryDelays) {
          retries++;
          await Future<void>.delayed(wait);
          if (!_isCurrentPlayRequest(generation, media) || _userPaused) {
            return;
          }
          focusGranted = await _activateAudioSession(generation);
          if (!_isCurrentPlayRequest(generation, media)) return;
          if (focusGranted) break;
        }
        _catalogPlayback.diagnostic(
          'relay playback focus ${focusGranted ? 'granted' : 'denied'} '
          'after retries=$retries',
        );
      }
      if (!focusGranted) {
        _sourceReady = false;
        _pendingRestorePosition = effectiveStartPosition;
        await _player.pause();
        if (_isCurrentPlayRequest(generation, media)) {
          _broadcastState(playerState: PlaybackDeckState.paused);
        }
        return;
      }
      await _player.stop();
      _sourceReady = false;
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _player.setVolume(normalizationVolume);
      _normalizationVolume = normalizationVolume;
      if (!_isCurrentPlayRequest(generation, media)) return;
      final startAt = effectiveStartPosition > Duration.zero
          ? effectiveStartPosition
          : null;
      try {
        resolved = await _startResolvedSource(
          resolved,
          generation,
          media,
          startAt,
          startPaused: _experimentalRetiringGeneration == generation
              ? false
              : startPaused || _userPaused,
          requireFocusOnResume: _experimentalRetiringGeneration == generation,
        );
        if (playbackLease != null) {
          await PlatformBridge.closeContentUriPlaybackLease(
            playbackLease.token,
          );
          playbackLease = null;
        }
      } catch (directError) {
        final activeLease = _catalogLease;
        if (_isCurrentPlayRequest(generation, media) &&
            media.isCatalog &&
            activeLease != null &&
            activeLease.isTemporary &&
            playbackLease == null &&
            resolved == activeLease.path) {
          BugLog.instance.recordTemporaryPipelineOutcome(
            TemporaryPipelineStage.playback,
            TemporaryPipelineOutcome.failed,
            provider: activeLease.provider,
          );
        }
        if (directError is UsbOutputUnavailable ||
            playbackLease == null ||
            !_isCurrentPlayRequest(generation, media)) {
          rethrow;
        }
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
        playbackLease = null;
        _log.w(
          'Direct SAF playback unavailable; using bounded local fallback: '
          '$directError',
        );
        final fallback = await _resolveSource(media);
        if (fallback == null || !_isCurrentPlayRequest(generation, media)) {
          rethrow;
        }
        resolved = fallback;
        usingLocalSafCopy = true;
        normalizationVolume = await _normalizationVolumeFor(
          fallback,
          cacheKey: media.source,
        );
        if (!_isCurrentPlayRequest(generation, media)) return;
        await _player.setVolume(normalizationVolume);
        if (!_isCurrentPlayRequest(generation, media)) return;
        _normalizationVolume = normalizationVolume;
        await _startResolvedSource(
          fallback,
          generation,
          media,
          startAt,
          startPaused: startPaused,
        );
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
      _sourceReady = true;
      if (_experimentalRetiringGeneration == generation)
        _experimentalRetiringGeneration = 0;
      _preparedPausedDeck = (startPaused || _userPaused) ? _player : null;
      if (relayedTrack != null) {
        _catalogPlayback.diagnostic(
          'relay playback started paused=${startPaused || _userPaused}',
        );
      }
      final activeLease = _catalogLease;
      if (media.isCatalog &&
          activeLease != null &&
          resolved == activeLease.path) {
        if (activeLease.isTemporary) {
          BugLog.instance.recordTemporaryPipelineOutcome(
            TemporaryPipelineStage.playback,
            TemporaryPipelineOutcome.ready,
            provider: activeLease.provider,
          );
        }
        unawaited(
          _publishVerifiedCatalogAudio(media, _playbackInstance, activeLease),
        );
      }
      if (media.isCatalog && !startPaused) {
        final track = media.catalogTrack;
        if (track != null) {
          if (_catalogLease case final lease?) {
            _catalogPlayback.selectLease(track, lease);
          }
          _audibleCatalogTrack = track;
          await _recordCatalogPlayback(track);
          if (!_isCurrentPlayRequest(generation, media)) return;
        }
      }
      if (_jamQueueActive && _jamTransitionPending) {
        final occurrence = _queueItems[_index].extras?['jamOccurrenceId'];
        if (occurrence is String &&
            (_jamPlaybackOccurrencesChanged?.call(occurrence, null) ?? false)) {
          _jamAudibleOccurrence = occurrence;
          _jamTransitionPending = false;
          _jamTransitionInFlight = false;
          _jamPendingOccurrence = null;
        }
      }
      if (media.source.startsWith('network://')) {
        unawaited(_loadNetworkMetadata(media, generation));
      }
      _pendingRestorePosition = null;
      _activeResolvedPath = usingLocalSafCopy || _formats.owns(resolved)
          ? resolved
          : null;
      _failures.started(media, resolved);
      await _cleanupPendingResolvedPaths();
      if (!_isCurrentPlayRequest(generation, media)) return;
      _upcoming.refresh();
      // Plain file paths were already published before loading. Re-publishing
      // them with an identical resolved path made Now Playing clear and probe
      // the same metadata twice on every Next. SAF needs this second event so
      // the UI can inspect its temporary local copy.
      if (usingLocalSafCopy) {
        mediaItem.add(_toMediaItem(_media[_index], resolvedSource: resolved));
      }
      _broadcastPosition(effectiveStartPosition, force: true);
      _broadcastState();
      _lastPeriodicPersistAt = DateTime.now();
      unawaited(_persistSession(position: effectiveStartPosition));
      // Some files do not emit onDurationChanged reliably (stuck at 0:00);
      // poll the engine for the real duration as a fallback.
      unawaited(_ensureDurationKnown(media, generation));
    } catch (e, stackTrace) {
      if (!_isCurrentPlayRequest(generation, media)) return;
      if (await _failures.skipMissing(
        media,
        resolved,
        generation,
        startPaused: startPaused,
      )) {
        return;
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
      if (await _formats.skipUnplayable(
        media,
        resolved,
        generation,
        startPaused: startPaused,
      )) {
        return;
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
      _reportPlaybackError(_player, e, stackTrace);
    } finally {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      if (_switchingGeneration == generation) {
        _switchingGeneration = 0;
      }
    }
  }

  Future<void> _recoverEmbeddedArtwork(
    PlayableMedia media,
    int generation,
  ) async {
    if (_runtime.arrivingFile(media.source) case final arriving?) {
      try {
        await arriving.done;
      } on Object {
        return;
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
    }
    final artwork = await resolveEmbeddedArtworkUri(
      media.source,
      media.artUri,
      keepRemoteArtwork: media.contextCover,
      remoteAvailable: contextCoverAvailable,
      extract: (source) =>
          DownloadedEmbeddedCoverResolver.resolveOrExtract(source),
    );
    if (!_isCurrentPlayRequest(generation, media)) return;
    final context = media.artUri ?? '';
    if (artwork == null && media.contextCover && context.startsWith('http')) {
      unawaited(cacheContextCover(context));
      await _offerEmbeddedFallback(media, generation);
      return;
    }
    if (artwork == null) return;
    final current = mediaItem.value;
    if (current == null) return;
    final updated = current.copyWith(artUri: Uri.parse(artwork));
    mediaItem.add(updated);
    _media[_index] = PlayableMedia.fromJson({
      ..._media[_index].toJson(),
      'artUri': artwork,
    })!;
    final old = _queueItems[_index];
    _queueItems[_index] = updated;
    final original = _originalQueueOrder;
    if (original != null) {
      final i = original.indexWhere((item) => identical(item, old));
      if (i >= 0) original[i] = updated;
    }
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> _offerEmbeddedFallback(
    PlayableMedia media,
    int generation,
  ) async {
    final cover = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      media.source,
    );
    if (cover == null || !_isCurrentPlayRequest(generation, media)) return;
    final current = mediaItem.value;
    if (current == null) return;
    final fallback = Uri.file(cover).toString();
    if (current.extras?['fallbackArt'] == fallback) return;
    final updated = current.copyWith(
      extras: {...?current.extras, 'fallbackArt': fallback},
    );
    mediaItem.add(updated);
    final old = _queueItems[_index];
    _queueItems[_index] = updated;
    final original = _originalQueueOrder;
    if (original != null) {
      final i = original.indexWhere((item) => identical(item, old));
      if (i >= 0) original[i] = updated;
    }
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
  }

  Future<void> _loadNetworkMetadata(PlayableMedia media, int generation) async {
    try {
      final metadata = await _dependencies.readNetworkMetadata(media.source);
      if (!_isCurrentPlayRequest(generation, media)) return;
      final cover = await _covers.readTagCover(
        media,
        metadata['cover_path'] as String?,
      );
      if (!_isCurrentPlayRequest(generation, media)) return;
      final current = mediaItem.value;
      if (current == null) return;
      String text(String key, String fallback) {
        final value = metadata[key]?.toString().trim() ?? '';
        return value.isEmpty ? fallback : value;
      }

      final updated = current.copyWith(
        title: text('title', current.title),
        artist: text('artist', current.artist ?? ''),
        album: text('album', current.album ?? ''),
        artUri: cover ?? current.artUri,
        extras: {
          ...?current.extras,
          for (final key in ['bit_depth', 'sample_rate', 'bitrate', 'format'])
            if (metadata[key] != null) key: metadata[key],
        },
      );
      mediaItem.add(updated);
      _media[_index] = PlayableMedia.fromJson({
        ...media.toJson(),
        'title': updated.title,
        'artist': updated.artist,
        'album': updated.album,
        'bitDepth': metadata['bit_depth'] ?? media.bitDepth,
        'sampleRate': metadata['sample_rate'] ?? media.sampleRate,
        'bitrate': metadata['bitrate'] ?? media.bitrate,
        'format': metadata['format'] ?? media.format,
      })!;
      // Keep the saved shuffle order paired with the updated queue entry.
      final old = _queueItems[_index];
      _queueItems[_index] = updated;
      final original = _originalQueueOrder;
      if (original != null) {
        final i = original.indexWhere((item) => identical(item, old));
        if (i >= 0) original[i] = updated;
      }
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      unawaited(_persistSession(position: playbackState.value.position));
    } catch (_) {
      _log.w('Network tags unavailable; keeping playback metadata');
    }
  }

  /// Resolves the real track duration when the initial metadata had none and
  /// the duration-changed event did not fire, so the seek bar and total time
  /// do not get stuck at 0:00.
  Future<void> _ensureDurationKnown(PlayableMedia media, int generation) async {
    for (var attempt = 0; attempt < 15; attempt++) {
      if (!_isCurrentPlayRequest(generation, media)) return;
      final current = mediaItem.value;
      final existing = current?.duration;
      if (existing != null && existing > Duration.zero) return;

      try {
        final d = await _player.getDuration();
        if (!_isCurrentPlayRequest(generation, media)) return;
        if (d != null && d > Duration.zero) {
          final item = mediaItem.value;
          if (item != null) {
            mediaItem.add(item.copyWith(duration: d));
          }
          return;
        }
      } catch (_) {
        // Duration probing is best-effort; retry until the bounded loop ends.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  void _recordPlayHistory(int index) {
    _playHistory.add(index);
    if (_playHistory.length > 200) _playHistory.removeAt(0);
  }

  Future<void> _onComplete() async {
    if (_repeatMode == AudioServiceRepeatMode.one &&
        _index >= 0 &&
        _index < _media.length) {
      await _playIndex(_index, recordHistory: false);
      return;
    }
    if (_index == _media.length - 1 &&
        _repeatMode == AudioServiceRepeatMode.none) {
      final generation = _playRequestGeneration;
      await _autoplay.fill();
      if (_disposed ||
          generation != _playRequestGeneration ||
          _shouldIgnoreComplete) {
        return;
      }
    }
    if (_index >= 0 && _index < _media.length - 1) {
      await _playIndex(_index + 1);
    } else if (_repeatMode == AudioServiceRepeatMode.all && _media.isNotEmpty) {
      await _playIndex(_beginRepeatPass(_repeatPassStart()));
    } else {
      await _finishCatalogListening();
      _broadcastState(playerState: PlaybackDeckState.completed);
    }
  }

  Future<void> _handlePlayerComplete() async {
    if (_completing) return;
    if (_shouldIgnoreComplete) {
      // A natively chained next song must not keep playing unseen.
      unawaited(_gapless.cancel());
      if (_userPaused || _interruptionActive) {
        _broadcastState(playerState: PlaybackDeckState.paused);
      }
      return;
    }

    _completing = true;
    try {
      _runtime.personalization.finish();
      if (await _gapless.handoff()) return;
      await _onComplete();
    } finally {
      _completing = false;
    }
  }

  @override
  Future<void> play() async {
    _playbackAutomation.manualPlaybackRequested();
    if (_experimentalRetiringGeneration != 0 &&
        _experimentalRetiringGeneration == _playRequestGeneration &&
        !_stopRequested) {
      _userPaused = false;
      _broadcastState(loading: true);
      return;
    }
    if (_experimentalAttempt != null &&
        _sourceReady &&
        _userPaused &&
        !_stopRequested) {
      final generation = _playRequestGeneration;
      _userPaused = false;
      if (!await _activateAudioSession(generation) ||
          generation != _playRequestGeneration ||
          _disposed)
        return;
      await _player.resume();
      if (generation == _playRequestGeneration && !_disposed) _broadcastState();
      return;
    }
    final activeOperation = _activePlayOperation;
    if (activeOperation != null &&
        activeOperation.generation == _playRequestGeneration &&
        !_userPaused &&
        !_stopRequested) {
      await activeOperation.future;
      return;
    }

    final future = _playInternal();
    final operation = (future: future, generation: _playRequestGeneration);
    _activePlayOperation = operation;
    try {
      await future;
    } finally {
      if (identical(_activePlayOperation?.future, future)) {
        _activePlayOperation = null;
      }
    }
  }

  Future<void> _playInternal() async {
    final wasUserPaused = _userPaused;
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;
    // The outgoing Cast deck can require reload while the local handoff
    // already owns the source and its requested position.
    if (!_stopRequested && !_cast.changingOutput && _player.needsSourceReload) {
      final generation = _playRequestGeneration;
      final index = _index;
      final position =
          await _player.getCurrentPosition() ?? playbackState.value.position;
      if (generation != _playRequestGeneration || _disposed) return;
      await _playIndex(
        index,
        recordHistory: false,
        startPosition: position,
        preserveListeningSession: true,
      );
      return;
    }
    if ((_stopRequested ||
            !_sourceReady ||
            (_player.state == PlaybackDeckState.stopped &&
                !identical(_player, _preparedPausedDeck)) ||
            _player.state == PlaybackDeckState.completed) &&
        _index >= 0 &&
        _index < _media.length) {
      await _playIndex(
        _index,
        recordHistory: false,
        startPosition: _stopRequested && _sourceReady
            ? playbackState.value.position
            : _pendingSeekPosition ?? _pendingRestorePosition ?? Duration.zero,
        resumeOccurrence:
            !_stopRequested &&
            !_sourceReady &&
            (wasUserPaused || _cast.changingOutput),
      );
      return;
    }
    final generation = _playRequestGeneration;
    await _serializeSourceChange(() async {
      if (generation != _playRequestGeneration || _disposed) return;
      if (_dependencies.isAndroid) {
        _broadcastState(playerState: PlaybackDeckState.playing, loading: true);
      }
      final focusGranted = await _activateAudioSession(generation);
      if (generation != _playRequestGeneration || _disposed) return;
      if (!focusGranted) {
        await _player.pause();
        if (generation == _playRequestGeneration && !_disposed) {
          _broadcastState(playerState: PlaybackDeckState.paused);
        }
        return;
      }
      await _claimHardwareMediaButtons();
      if (generation != _playRequestGeneration || _disposed) return;
      try {
        await _player.resume();
        if (identical(_player, _preparedPausedDeck)) {
          _preparedPausedDeck = null;
        }
      } catch (error, stackTrace) {
        if (generation != _playRequestGeneration || _disposed) return;
        if (_player.needsSourceReload) {
          _broadcastState(playerState: PlaybackDeckState.paused);
        } else {
          _reportPlaybackError(_player, error, stackTrace);
        }
        return;
      }
      if (generation != _playRequestGeneration || _disposed) {
        await _player.pause();
        return;
      }
      if (_index >= 0 && _index < _media.length) {
        final track = _media[_index].catalogTrack;
        if (track != null) {
          if (_catalogLease case final lease?) {
            _catalogPlayback.selectLease(track, lease);
          }
          _audibleCatalogTrack = track;
          await _recordCatalogPlayback(track);
          if (generation != _playRequestGeneration || _disposed) return;
        }
      }
      _broadcastState(playerState: PlaybackDeckState.playing);
    });
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (playbackState.value.playing) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  @override
  Future<void> pause() async {
    _playbackAutomation.cancelPendingActions();
    _pausedByInterruption = false;
    await _pausePlayback();
  }

  Future<void> _pausePlayback() async {
    if (_experimentalRetiringGeneration != 0 &&
        _experimentalRetiringGeneration == _playRequestGeneration &&
        !_stopRequested) {
      _userPaused = true;
      if (_sourceReady) {
        try {
          await _player.pause();
        } catch (_) {
          _sourceReady = false;
        }
      }
      _broadcastState(playerState: PlaybackDeckState.paused);
      return;
    }
    if (_experimentalAttempt != null && _sourceReady && !_stopRequested) {
      _userPaused = true;
      try {
        await _player.pause();
      } catch (_) {
        _sourceReady = false;
      }
      _broadcastState(playerState: PlaybackDeckState.paused);
      return;
    }
    final preparing = _preparingCatalogTrack;
    if (preparing != null) unawaited(_catalogPlayback.cancel(preparing));
    _runtime.personalization.updatePlayback(
      source: mediaItem.value?.extras?['source'] as String?,
      playing: false,
    );
    unawaited(_runtime.personalization.flush());
    unawaited(_runtime.taste.flush());
    unawaited(_runtime.ranker.flush());
    final pausedLoad =
        !_sourceReady &&
        (_switchingGeneration == _playRequestGeneration ||
            _pausedLoadGeneration == _playRequestGeneration) &&
        _playRequestGeneration != 0;
    _userPaused = true;
    final changingOutput = _cast.changingOutput;
    if (!changingOutput && pausedLoad) {
      // Pause invalidates the queued seek along with the load. Keep its
      // position for the next Play of this occurrence.
      _pendingRestorePosition = _pendingSeekPosition ?? _pendingRestorePosition;
    }
    // A pending Cast handoff must still replace the output. It reads the
    // current pause intent before starting preparation on the new deck.
    final generation = changingOutput
        ? _playRequestGeneration
        : ++_playRequestGeneration;
    if (!changingOutput) {
      _pausedLoadGeneration = pausedLoad ? generation : 0;
      _carryLoadingPermanentOffer(generation);
      _switchingGeneration = 0;
      await _player.cancelPreparation();
      await _cancelTransitions();
    }
    await _serializeSourceChange(() async {
      if (generation != _playRequestGeneration || _disposed) return;
      await _player.pause();
      await _finishCatalogListening();
      if (generation != _playRequestGeneration || _disposed) return;
      final restorePosition = _pendingRestorePosition;
      if (!_sourceReady && restorePosition != null) {
        _broadcastPosition(restorePosition, force: true);
      }
      _broadcastState(playerState: PlaybackDeckState.paused);
      await _persistSession(position: await _currentPositionForPersist());
    });
    if (_disposed || generation != _playRequestGeneration) return;
    final offer = _pendingPermanentOffer;
    _pendingPermanentOffer = null;
    if (offer != null && _playbackInstance == offer.instance) {
      await onPermanentDownloadReady(offer.track, offer.path);
    } else {
      await _drainLoadingPermanentOffer(generation);
    }
  }

  Duration? get _pendingSeekPosition {
    final seek = _pendingSeek;
    if (seek == null) return null;
    final instance = seek.playbackInstance;
    return instance == null || instance == _playbackInstance
        ? seek.position
        : null;
  }

  @override
  Future<void> seek(Duration position) async {
    final generation = _playRequestGeneration;
    if (_experimentalRetiringGeneration != 0 &&
        _experimentalRetiringGeneration == generation) {
      if (position < Duration.zero) position = Duration.zero;
      final duration = _index >= 0 && _index < _media.length
          ? _media[_index].duration
          : null;
      if (duration != null && duration > Duration.zero && position > duration)
        position = duration;
      _experimentalRetirementSeek = position;
    }
    // Cast can supersede the queued seek before the outgoing deck publishes it.
    // Keep its target until it settles or this queue occurrence is replaced.
    final request = (
      position: position,
      token: Object(),
      playbackInstance: _sourceReady ? _playbackInstance : null,
    );
    _pendingSeek = request;
    try {
      await _autoMix.cancel();
      await _serializeSourceChange(() async {
        if (generation != _playRequestGeneration ||
            _disposed ||
            _pendingSeek?.token != request.token) {
          return;
        }
        if (!_sourceReady) {
          // Restored sessions have no engine source yet. Retain the requested
          // position, including zero, for the first play instead of the old save.
          _pendingRestorePosition = position;
          _broadcastPosition(position, force: true);
          await _persistSession(position: position);
          return;
        }
        await _player.seek(position);
        if (generation != _playRequestGeneration || _disposed) return;
        _broadcastPosition(position, force: true);
      });
    } finally {
      if (_pendingSeek?.token == request.token) _pendingSeek = null;
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _rejectLocalJamQueueEdit();
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    if (enabled && _shuffle) return;
    await setShuffleStrategy(
      enabled ? ShuffleStrategy.random : ShuffleStrategy.off,
    );
  }

  Future<void> setShuffleStrategy(ShuffleStrategy strategy) async {
    _rejectLocalJamQueueEdit();
    final generation = ++_shuffleRequestGeneration;
    if (strategy == ShuffleStrategy.smart) await _refreshListeningSignals();
    await _cancelTransitions();
    // Jam can take ownership while transition cancellation is in flight.
    _rejectLocalJamQueueEdit();
    if (generation != _shuffleRequestGeneration ||
        _disposed ||
        strategy == _shuffleStrategy) {
      return;
    }
    _setShuffleStrategy(strategy);
    if (strategy.enabled) {
      _shuffleQueue();
    } else {
      final original = _originalQueueOrder;
      if (original != null) _applyQueueOrder(List.of(original));
      _originalQueueOrder = null;
    }
    _upcoming.refresh();
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    if (_media.isNotEmpty && _index >= 0) {
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _cancelTransitions();
    // Group repeat has no meaning for a flat queue; treat it as all.
    _repeatMode = repeatMode == AudioServiceRepeatMode.group
        ? AudioServiceRepeatMode.all
        : repeatMode;
    _autoplay.updateMode();
    _upcoming.refresh();
    _broadcastState();
    if (_media.isNotEmpty && _index >= 0) {
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  @override
  Future<void> stop({bool keepResume = false}) async {
    final experimental = _experimentalAttempt;
    final pendingExperimental = _experimentalPendingStart;
    _experimentalAttempt = null;
    if (experimental != null) {
      _beginExperimentalClose(experimental);
    } else if (pendingExperimental != null) {
      _trackExperimentalClose(
        pendingExperimental
            .then((attempt) => attempt?.cancel() ?? Future.value(true))
            .catchError((Object _) => false),
      );
    }
    // The ready source still owns the position that keepResume persists.
    _stopRequested = true;
    _newPlaybackOccurrence();
    _preparedPausedDeck = null;
    final preparing = _preparingCatalogTrack;
    if (preparing != null) unawaited(_catalogPlayback.cancel(preparing));
    _runtime.personalization.finish();
    unawaited(_runtime.personalization.flush());
    unawaited(_runtime.taste.flush());
    unawaited(_runtime.ranker.flush());
    _playbackAutomation.cancelPendingActions();
    _autoplay.reset();
    _prefetch.stop();
    cancelSleepTimer();
    final generation = ++_playRequestGeneration;
    _switchingGeneration = 0;
    _userPaused = true;
    final closeBarrier = _experimentalCloseBarrier;
    if (closeBarrier != null) {
      var timedOut = false;
      final closed = await closeBarrier.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          timedOut = true;
          return false;
        },
      );
      if (!closed) {
        if (!_disposed && generation == _playRequestGeneration) {
          _progressiveCloseUnconfirmed = true;
          _playbackError = StateError(
            'Progressive source close was not confirmed; audio may still be playing',
          );
          _broadcastState();
        }
        if (timedOut) {
          unawaited(
            closeBarrier.then((confirmed) {
              if (confirmed &&
                  !_disposed &&
                  _stopRequested &&
                  generation == _playRequestGeneration) {
                final deferredStop = stop(keepResume: keepResume);
                final deferredGeneration = _playRequestGeneration;
                unawaited(
                  deferredStop.catchError((
                    Object error,
                    StackTrace stackTrace,
                  ) {
                    if (!_disposed &&
                        deferredGeneration == _playRequestGeneration) {
                      _progressiveCloseUnconfirmed = false;
                      _playbackError = error;
                      _broadcastState();
                    }
                  }),
                );
              }
            }),
          );
        }
        return;
      }
    }
    if (generation != _playRequestGeneration || _disposed) return;
    if (identical(_experimentalCloseBarrier, closeBarrier))
      _experimentalCloseBarrier = null;
    final cancellation = _stopPreparation ??= _player.cancelPreparation();
    try {
      await cancellation;
    } finally {
      if (identical(_stopPreparation, cancellation)) _stopPreparation = null;
    }
    if (generation != _playRequestGeneration || _disposed) return;
    await _serializeSourceChange(() async {
      if (generation != _playRequestGeneration || _disposed) return;
      await _cancelTransitions();
      await _stopSession(generation, keepResume: keepResume);
    });
  }

  Future<void> _stopSession(int generation, {bool keepResume = false}) async {
    if (generation != _playRequestGeneration || _disposed) return;
    Map<String, dynamic>? resumeMedia;
    if (keepResume && _index >= 0 && _index < _media.length) {
      final position = await _currentPositionForPersist();
      if (generation != _playRequestGeneration || _disposed) return;
      await _persistSession(position: position);
      if (generation != _playRequestGeneration || _disposed) return;
      resumeMedia = _media[_index].toJson();
    }
    await _player.stop();
    await _retireCatalogListening();
    if (generation != _playRequestGeneration || _disposed) return;
    _sourceReady = false;
    _playbackError = null;
    _progressiveCloseUnconfirmed = false;
    _activeResolvedPath = null;
    await _cleanupPendingResolvedPaths();
    if (generation != _playRequestGeneration || _disposed) return;
    _index = -1;
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;
    _playHistory.clear();
    _pendingRestorePosition = null;
    await _sessionWriter.clear(resumeMedia: resumeMedia);
    if (generation != _playRequestGeneration || _disposed) return;
    // A stopped session has no current item; this also hides the mini player.
    mediaItem.add(null);
    _broadcastState(playerState: PlaybackDeckState.stopped);
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_index >= 0 && _index == _media.length - 1) {
      final generation = _playRequestGeneration;
      await _autoplay.fill();
      if (_disposed || generation != _playRequestGeneration) return;
    }
    if (_index < _media.length - 1) {
      await _playIndex(_index + 1, userSkip: true);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    await _cancelTransitions();
    if (playbackState.value.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      _broadcastPosition(Duration.zero, force: true);
      _runtime.personalization.replayed();
      return;
    }
    if (_shuffle) {
      if (_playHistory.length >= 2) {
        _playHistory.removeLast();
        final prev = _playHistory.last;
        await _playIndex(prev, recordHistory: false, userSkip: true);
      } else {
        await _player.seek(Duration.zero);
        _broadcastPosition(Duration.zero, force: true);
      }
      _runtime.personalization.replayed();
      return;
    }
    if (_index > 0) {
      await _playIndex(_index - 1, userSkip: true);
      _runtime.personalization.replayed();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => _playIndex(index, userSkip: true);

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    // Media resumption asks for the song to resume, which a cold start has
    // only once the saved session is back.
    if (parentMediaId == AudioService.recentRootId) {
      await _runtime.restoreSession();
      final item = mediaItem.value;
      return item == null ? const [] : [item];
    }
    return _runtime.browser.children(parentMediaId, options);
  }

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) => _runtime.browser.search(query);

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final index = _media.indexWhere((m) => m.id == mediaId);
    if (index < 0) return null;
    return _queueItems[index];
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    if (MediaLibraryBrowser.isBrowserId(mediaId)) {
      await _playBrowserQueue(await _runtime.browser.queueFor(mediaId));
      return;
    }
    final index = _media.indexWhere((m) => m.id == mediaId);
    if (index >= 0) await _playIndex(index);
  }

  /// Plays a spoken request. Without words it resumes the queue, or shuffles
  /// the Library when there is none.
  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    if (query.trim().isEmpty) {
      await _runtime.restoreSession();
      if (_media.isNotEmpty) return play();
    }
    await _playBrowserQueue(
      await _runtime.browser.queueForSearch(query, extras),
    );
  }

  Future<void> _playBrowserQueue(BrowserQueue? queue) async {
    if (queue == null || _disposed) return;
    if (queue.shuffle) await setShuffleMode(AudioServiceShuffleMode.all);
    await setQueueAndPlay(queue.items, initialIndex: queue.index);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      playFromMediaId(mediaItem.id);

  void _relocateQueuedSource(
    String previous,
    String replacement, {
    String? origin,
  }) {
    _normalizationCache.invalidate(previous);
    unawaited(_sourceCache.invalidate(previous));
    for (var i = 0; i < _media.length; i++) {
      final media = _media[i];
      if (media.source != previous) continue;
      _media[i] = PlayableMedia.fromJson({
        ...media.toJson(),
        'source': replacement,
        'originSource': ?origin,
      })!;
      final old = _queueItems[i];
      final next = old.copyWith(
        extras: {
          ...?old.extras,
          'source': replacement,
          'resolvedSource': null,
          'originSource': ?origin,
        },
      );
      _queueItems[i] = next;
      final original = _originalQueueOrder?.indexWhere(
        (item) => identical(item, old),
      );
      if (original != null && original >= 0) {
        _originalQueueOrder![original] = next;
      }
    }
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
  }

  /// Updates queued and persisted sources without restarting the decoder.
  Future<void> onSourceRelocated(String previous, String replacement) async {
    if (_disposed || !_media.any((item) => item.source == previous)) return;
    _relocateQueuedSource(previous, replacement);
    if (_index >= 0 && _index < _queueItems.length) {
      mediaItem.add(_queueItems[_index]);
    }
    await _persistSession(position: playbackState.value.position);
  }

  /// Switches only an already prepared catalog source. Preparing a separate
  /// deck keeps the temporary source intact if the download cannot be opened.
  void onPermanentDownloadSelected(Track track) {
    final loading = _loadingPermanentOffer;
    if (loading != null && _samePermanentTrack(loading.track, track)) {
      _loadingPermanentOffer = null;
    }
    final offer = _pendingPermanentOffer;
    if (offer != null && _samePermanentTrack(offer.track, track)) {
      _pendingPermanentOffer = null;
    }
  }

  Track? get currentCatalogTrack {
    if (_index < 0 || _index >= _media.length) return null;
    return _media[_index].catalogTrack ??
        (_permanentCatalogInstance == _playbackInstance
            ? _permanentCatalogTrack
            : null);
  }

  ValueListenable<CatalogPreparation?> get catalogPreparation =>
      _catalogPlayback.preparation;

  ({String service, String quality})? catalogPlayingRequest(Track track) =>
      _catalogPlayback.playingRequest(track);

  int _handoffCommits = 0;

  Future<bool> switchPlaybackSource(
    Track track,
    String path, {
    String? replacing,
    String? sourceKind,
  }) async {
    final before = _handoffCommits;
    await onPermanentDownloadReady(
      track,
      path,
      replacingSource: replacing,
      sourceKind: sourceKind,
    );
    return _handoffCommits != before;
  }

  Future<void> cancelCatalogQualitySwitch(Track track) =>
      _catalogPlayback.cancel(track);

  Future<bool> switchCatalogQuality(
    Track track,
    String qualityId, {
    String? service,
  }) async => (await switchCatalogQualityResult(
    track,
    qualityId,
    service: service,
  )).ok;

  void _qualityStage(Stopwatch watch, String stage) =>
      debugPrint('quality-switch: t=${watch.elapsedMilliseconds} stage=$stage');

  /// Switches the playing song to the format [candidates] name, asking the
  /// providers in the order given and moving to the next one only when the
  /// previous does not give that format. It never settles for another format.
  Future<QualitySwitchResult> switchCatalogQualityAcrossProviders(
    Track track,
    List<({String service, String id})> candidates,
  ) async {
    final tried = <String>[];
    QualitySwitchResult? last;
    for (final candidate in candidates) {
      tried.add('${candidate.service}/${candidate.id}');
      final result = await switchCatalogQualityResult(
        track,
        candidate.id,
        service: candidate.service,
      );
      last = result;
      if (result.ok) {
        debugPrint(
          'quality-switch: format=${candidate.id} '
          'provider=${candidate.service} tried=${tried.join(',')}',
        );
        return result;
      }
      final failure = result.failure;
      if (failure != QualitySwitchFailure.unavailable &&
          failure != QualitySwitchFailure.timedOut &&
          failure != QualitySwitchFailure.unsupportedFormat &&
          failure != QualitySwitchFailure.other) {
        break;
      }
    }
    debugPrint(
      'quality-switch: format=${candidates.isEmpty ? '' : candidates.first.id} '
      'provider=none tried=${tried.join(',')}',
    );
    return last ??
        const QualitySwitchResult.failed(QualitySwitchFailure.unavailable);
  }

  Future<QualitySwitchResult> switchCatalogQualityResult(
    Track track,
    String qualityId, {
    String? service,
  }) async {
    final guard = _qualitySwitchGuard(track);
    if (guard != null) {
      debugPrint(
        'quality-switch: guard=${guard.name} index=$_index '
        'queue=${_media.length} ready=$_sourceReady cast=${_cast.active} '
        'direct=${_player.isDirect} catalog=${currentCatalogTrack != null}',
      );
      return QualitySwitchResult.failed(guard);
    }
    final watch = Stopwatch()..start();
    _upcoming.prefetcher.hold();
    try {
      return await _switchCatalogQualityHeld(
        track,
        qualityId,
        service,
        watch,
      );
    } finally {
      if (!_disposed) _upcoming.refresh();
    }
  }

  Future<QualitySwitchResult> _switchCatalogQualityHeld(
    Track track,
    String qualityId,
    String? service,
    Stopwatch watch,
  ) async {
    final guard = _qualitySwitchGuard(track);
    if (guard != null) {
      debugPrint(
        'quality-switch: guard=${guard.name} index=$_index '
        'queue=${_media.length} ready=$_sourceReady cast=${_cast.active} '
        'direct=${_player.isDirect} catalog=${currentCatalogTrack != null}',
      );
      return QualitySwitchResult.failed(guard);
    }
    final previous = _catalogPlayback.qualityOverrideFor(track);
    final previousService = _catalogPlayback.serviceOverrideFor(track);
    final previousRequest = _catalogPlayback.playingRequest(track);
    if (isSpatialQualityId(qualityId)) {
      return _switchSpatialQuality(
        track,
        qualityId,
        service,
        watch,
        previous: previous,
        previousService: previousService,
        previousRequest: previousRequest,
      );
    }
    _catalogPlayback.setQualityOverride(track, qualityId, service: service);
    CatalogAudioLease? lease;
    try {
      lease = await _catalogPlayback.acquire(
        track,
        relay: false,
        engineFallback: false,
      );
      debugPrint(
        'quality-switch: t=${ProviderRequestGate.instance.lastForegroundWait.inMilliseconds} stage=gate',
      );
      _qualityStage(watch, 'download');
      if (lease.qualityMetadata['quality_fallback_used'] == true) {
        final degraded = lease;
        lease = null;
        final tried = (degraded.qualityMetadata['provider'] ?? service ?? '')
            .toString()
            .trim()
            .toLowerCase();
        await degraded.release();
        lease = await _relayQualitySwitch(track, qualityId, tried);
        if (lease == null) {
          _catalogPlayback.setQualityOverride(
            track,
            previous,
            service: previousService,
          );
          _catalogPlayback.restorePlayingRequest(track, previousRequest);
          return const QualitySwitchResult.failed(
            QualitySwitchFailure.unavailable,
          );
        }
      }
      final handedOff = await switchPlaybackSource(track, lease.path);
      _qualityStage(watch, 'handoff');
      if (!handedOff) {
        debugPrint('quality-switch: guard=handoffRejected');
        await lease.release();
        _catalogPlayback.setQualityOverride(
          track,
          previous,
          service: previousService,
        );
        _catalogPlayback.restorePlayingRequest(track, previousRequest);
        return const QualitySwitchResult.failed(
          QualitySwitchFailure.handoffRejected,
        );
      }
      _catalogLease = lease;
      return const QualitySwitchResult.success();
    } catch (error) {
      final acquired = lease != null;
      await lease?.release();
      _catalogPlayback.setQualityOverride(
        track,
        previous,
        service: previousService,
      );
      if (acquired) {
        _catalogPlayback.restorePlayingRequest(track, previousRequest);
      }
      final block = _catalogPlayback.verificationBlock.value;
      return qualitySwitchResultForError(
        error,
        verificationProvider: block?.trackKey == _catalogPlayback.key(track)
            ? block?.extensionId
            : null,
      );
    }
  }

  QualitySwitchFailure? _qualitySwitchGuard(Track track) {
    final current = currentCatalogTrack;
    if (current == null) return QualitySwitchFailure.notCatalogTrack;
    if (!_samePermanentTrack(current, track)) {
      return QualitySwitchFailure.identityMismatch;
    }
    if (_cast.active) return QualitySwitchFailure.casting;
    if (_player.isDirect) return QualitySwitchFailure.directMode;
    if (!_sourceReady) return QualitySwitchFailure.sourceNotReady;
    return null;
  }

  Future<List<StreamingRequest>> _spatialCandidates(
    String qualityId,
    String? service,
  ) async {
    final out = <StreamingRequest>[];
    final seen = <String>{};
    void add(String serviceId, String id) {
      final provider = normalizeAvailabilityProvider(serviceId);
      if (provider == null ||
          !atmosCapableProviders.contains(provider) ||
          !isSpatialQualityId(id)) {
        return;
      }
      if (seen.add(serviceId.trim().toLowerCase())) {
        out.add(StreamingRequest(serviceId, id));
      }
    }

    if (service != null && service.trim().isNotEmpty) add(service, qualityId);
    final alternatives = _catalogPlayback.streamingAlternatives;
    if (alternatives != null) {
      try {
        final others = await alternatives(
          StreamingRequest(service ?? '', qualityId),
          qualityId,
          true,
        );
        for (final candidate in others) {
          add(candidate.serviceId, candidate.qualityId);
        }
      } catch (_) {}
    }
    return out;
  }

  Future<QualitySwitchResult> _switchSpatialQuality(
    Track track,
    String qualityId,
    String? service,
    Stopwatch watch, {
    required String? previous,
    required String? previousService,
    required ({String service, String quality})? previousRequest,
  }) async {
    void restore({bool request = true}) {
      _catalogPlayback.setQualityOverride(
        track,
        previous,
        service: previousService,
      );
      if (request) _catalogPlayback.restorePlayingRequest(track, previousRequest);
    }

    final candidates = await _spatialCandidates(qualityId, service);
    _qualityStage(watch, 'probe');
    final started = DateTime.now();
    CatalogAudioLease? lease;
    Object? lastError;
    for (final candidate in candidates) {
      if (_catalogPlayback.providerResting(track, candidate.serviceId)) {
        continue;
      }
      if (DateTime.now().difference(started) >= _catalogPlayback.relayBudget) {
        break;
      }
      _catalogPlayback.setQualityOverride(
        track,
        candidate.qualityId,
        service: candidate.serviceId,
      );
      final native = await _catalogPlayback.nativeIdFor(
        track,
        candidate.serviceId,
      );
      CatalogAudioLease? attempt;
      try {
        attempt = await _catalogPlayback.acquire(
          track,
          relay: false,
          engineFallback: false,
          forced: candidate,
          nativeId: native,
        );
        if (attempt.qualityMetadata['quality_fallback_used'] != true) {
          lease = attempt;
          break;
        }
        await attempt.release();
      } catch (error) {
        lastError = error;
        await attempt?.release();
      }
    }
    if (lease == null) {
      restore(request: false);
      _catalogPlayback.restorePlayingRequest(track, previousRequest);
      final block = _catalogPlayback.verificationBlock.value;
      return lastError == null
          ? const QualitySwitchResult.failed(QualitySwitchFailure.unavailable)
          : qualitySwitchResultForError(
              lastError,
              verificationProvider: block?.trackKey == _catalogPlayback.key(track)
                  ? block?.extensionId
                  : null,
            );
    }
    _qualityStage(watch, 'download');
    try {
      final handedOff = await switchPlaybackSource(track, lease.path);
      _qualityStage(watch, 'handoff');
      if (!handedOff) {
        debugPrint('quality-switch: guard=handoffRejected');
        await lease.release();
        restore();
        return const QualitySwitchResult.failed(
          QualitySwitchFailure.handoffRejected,
        );
      }
      _catalogLease = lease;
      return const QualitySwitchResult.success();
    } catch (error) {
      await lease.release();
      restore();
      return qualitySwitchResultForError(error);
    }
  }

  Future<CatalogAudioLease?> _relayQualitySwitch(
    Track track,
    String qualityId,
    String triedService,
  ) async {
    final alternatives = _catalogPlayback.streamingAlternatives;
    if (alternatives == null || !_catalogPlayback.useFallback) return null;
    List<StreamingRequest> candidates;
    try {
      candidates = await alternatives(
        StreamingRequest(triedService, qualityId),
        qualityId,
        true,
      );
    } catch (_) {
      return null;
    }
    final started = DateTime.now();
    for (final candidate in candidates) {
      if (candidate.serviceId.trim().toLowerCase() == triedService) continue;
      if (ProviderCooldown.instance.isCoolingDown(
        candidate.serviceId,
        trace: true,
      )) {
        continue;
      }
      if (DateTime.now().difference(started) >= _catalogPlayback.relayBudget) {
        break;
      }
      _catalogPlayback.setQualityOverride(
        track,
        candidate.qualityId,
        service: candidate.serviceId,
      );
      CatalogAudioLease? attempt;
      try {
        attempt = await _catalogPlayback.acquire(
          track,
          relay: false,
          engineFallback: false,
        );
        if (attempt.qualityMetadata['quality_fallback_used'] != true) {
          return attempt;
        }
        await attempt.release();
      } catch (_) {
        await attempt?.release();
      }
    }
    return null;
  }

  Future<void> cancelCurrentPreparation() async {
    final preparing = _preparingCatalogTrack;
    final track = preparing ?? currentCatalogTrack;
    final pausing = pause();
    if (track != null && preparing == null) {
      await _catalogPlayback.cancel(track);
    }
    await pausing;
    _playbackError = null;
  }

  Future<void> retryCurrentPreparation() async {
    final index = _index;
    if (_disposed || index < 0 || index >= _media.length) return;
    await cancelCurrentPreparation();
    if (_disposed || index != _index) return;
    await _playIndex(
      index,
      startPosition: _pendingRestorePosition ?? Duration.zero,
      forceReload: true,
    );
  }

  static const _relayFocusRetryDelays = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 750),
  ];
  static const _handoffFade = Duration(milliseconds: 180);
  static const _handoffFadeSteps = 8;
  static const _handoffDriftTolerance = Duration(milliseconds: 20);
  static const _handoffDipTolerance = Duration(milliseconds: 80);
  static const _handoffLatencyMin = Duration(milliseconds: 150);
  static const _handoffLatencyMax = Duration(milliseconds: 1500);
  static const _handoffInitialCold = Duration(milliseconds: 450);
  static const _handoffInitialWarm = Duration(milliseconds: 250);
  static const _handoffAcceptDrift = Duration(milliseconds: 150);
  static const _handoffLandingTolerance = Duration(milliseconds: 150);
  static const _handoffRunTimeout = Duration(milliseconds: 1500);
  static const _handoffPollInterval = Duration(milliseconds: 25);
  static const _handoffSettleBudget = Duration(seconds: 4);
  static const _handoffMaxCorrections = 2;
  static const _handoffAbortDrift = Duration(milliseconds: 600);
  static const _handoffFreshTimeout = Duration(milliseconds: 600);
  static const _handoffFreshPoll = Duration(milliseconds: 20);
  static const _handoffSampleAttempts = 6;
  static const _handoffSampleSpacing = Duration(milliseconds: 50);
  static const _handoffStartTimeout = Duration(milliseconds: 600);
  final _handoffLatencies = <String, ({Duration cold, Duration warm})>{};
  final _handoffMasterOffsets = <String, Duration>{};
  static const _handoffStaticLatencyLimit = Duration(milliseconds: 400);
  Duration _handoffStaticLatency = Duration.zero;

  Duration _clampHandoffLatency(Duration value, Duration limit) {
    if (value < Duration.zero) return Duration.zero;
    return value > limit ? limit : value;
  }

  static String _handoffKindOf(
    PlaybackDeck deck,
    String path,
    String? sourceKind,
  ) {
    final clean = path.split('?').first;
    final dot = clean.lastIndexOf('.');
    final slash = clean.lastIndexOf('/');
    final container = dot > slash && dot >= 0
        ? clean.substring(dot + 1).toLowerCase()
        : 'raw';
    final origin = path.startsWith('content://') ? 'content' : 'file';
    return '${deck.runtimeType}:${sourceKind ?? 'audio'}:$container:$origin';
  }

  ({Duration cold, Duration warm}) _handoffLatencyFor(String kind) =>
      _handoffLatencies[kind] ??
      (cold: _handoffInitialCold, warm: _handoffInitialWarm);

  static Duration _clampLatency(Duration value) {
    if (value < _handoffLatencyMin) return _handoffLatencyMin;
    return value > _handoffLatencyMax ? _handoffLatencyMax : value;
  }

  @visibleForTesting
  static Duration learnHandoffLatency(Duration current, Duration drift) {
    final implied = current - drift;
    return _clampLatency(
      Duration(
        microseconds: (current.inMicroseconds + implied.inMicroseconds) ~/ 2,
      ),
    );
  }

  @visibleForTesting
  Duration handoffLatencyFor(String kind, {required bool cold}) {
    final latency = _handoffLatencyFor(kind);
    return cold ? latency.cold : latency.warm;
  }

  @visibleForTesting
  String handoffKindFor(PlaybackDeck deck, String path, {String? sourceKind}) =>
      _handoffKindOf(deck, path, sourceKind);

  void _learnHandoffLatency(
    String kind,
    Duration drift, {
    required bool cold,
  }) {
    final latency = _handoffLatencyFor(kind);
    _handoffLatencies[kind] = cold
        ? (cold: learnHandoffLatency(latency.cold, drift), warm: latency.warm)
        : (cold: latency.cold, warm: learnHandoffLatency(latency.warm, drift));
  }

  Duration masterOffsetFor({
    required String trackKey,
    required String kindA,
    required String kindB,
  }) => _handoffMasterOffsets['$trackKey|$kindA|$kindB'] ?? Duration.zero;

  @visibleForTesting
  static ({double incoming, double outgoing}) handoffFadeGains(
    double t, {
    required bool correlated,
  }) {
    final progress = t.clamp(0.0, 1.0);
    if (correlated) return (incoming: progress, outgoing: 1 - progress);
    return (incoming: sin(progress * pi / 2), outgoing: cos(progress * pi / 2));
  }

  void _handoffTrace(String message) {
    debugPrint('handoff: $message');
    _log.i('handoff: $message');
  }

  Future<bool> _handoffReferenceAdvances(PlaybackDeck outgoing) async {
    try {
      final first = await outgoing.getCurrentPosition();
      if (first == null) return false;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final second = await outgoing.getCurrentPosition();
      if (second == null) return false;
      return second - first >= const Duration(milliseconds: 10);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _awaitHandoffRunning(
    PlaybackDeck incoming,
    bool Function() stillWanted,
  ) async {
    final watch = Stopwatch()..start();
    var previous = await incoming.getCurrentPosition();
    var previousAt = watch.elapsed;
    var steady = 0;
    while (watch.elapsed < _handoffRunTimeout) {
      await Future<void>.delayed(_handoffPollInterval);
      if (!stillWanted()) return false;
      final current = await incoming.getCurrentPosition();
      final now = watch.elapsed;
      if (current != null && previous != null) {
        final wall = (now - previousAt).inMicroseconds;
        final moved = (current - previous).inMicroseconds;
        steady = wall > 0 && moved >= wall * 0.6 && moved <= wall * 1.4
            ? steady + 1
            : 0;
      } else {
        steady = 0;
      }
      previous = current;
      previousAt = now;
      if (steady >= 2) {
        _handoffTrace(
          'running after ${watch.elapsedMilliseconds} '
          'in=${current?.inMilliseconds}',
        );
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return stillWanted();
      }
    }
    _handoffTrace('not running after ${watch.elapsedMilliseconds}');
    return false;
  }

  Future<bool> _awaitHandoffFreshClock(
    PlaybackDeck incoming,
    bool Function() stillWanted, {
    required Duration target,
  }) async {
    final watch = Stopwatch()..start();
    var movedOffTarget = false;
    var previous = await incoming.getCurrentPosition();
    while (watch.elapsed < _handoffFreshTimeout) {
      await Future<void>.delayed(_handoffFreshPoll);
      if (!stillWanted()) return false;
      final current = await incoming.getCurrentPosition();
      if (current != null && previous != null && current != previous) {
        movedOffTarget = true;
        final low = target - _handoffLandingTolerance;
        final high = target + watch.elapsed + _handoffLandingTolerance;
        if (current >= low && current <= high) return true;
        _handoffTrace(
          'off target in=${current.inMilliseconds} '
          'target=${target.inMilliseconds}',
        );
      } else {
        _handoffTrace('stale in=${current?.inMilliseconds}');
      }
      previous = current;
    }
    _handoffTrace('stale timeout after ${watch.elapsedMilliseconds}');
    return movedOffTarget;
  }

  Future<Duration?> _measureHandoffDrift(
    PlaybackDeck outgoing,
    PlaybackDeck incoming, {
    int pass = 1,
  }) async {
    final valid = <int>[];
    final watch = Stopwatch()..start();
    try {
      var previous = await incoming.getCurrentPosition();
      var previousAt = watch.elapsed;
      for (var i = 1; i <= _handoffSampleAttempts; i++) {
        await Future<void>.delayed(_handoffSampleSpacing);
        final before = await outgoing.getCurrentPosition();
        final heard = await incoming.getCurrentPosition();
        final heardAt = watch.elapsed;
        final after = await outgoing.getCurrentPosition();
        final earlier = previous;
        final earlierAt = previousAt;
        previous = heard;
        previousAt = heardAt;
        if (before == null || heard == null || after == null) {
          _handoffTrace('sample#$i valid=false (no reading)');
          continue;
        }
        if (earlier != null && heard == earlier) {
          _handoffTrace(
            'sample#$i valid=false stale in=${heard.inMilliseconds}',
          );
          continue;
        }
        final wall = (heardAt - earlierAt).inMicroseconds;
        final moved = earlier == null ? 0 : (heard - earlier).inMicroseconds;
        final clockOk =
            earlier != null &&
            wall >= 40000 &&
            moved >= wall * 0.7 &&
            moved <= wall * 1.3;
        final tight =
            after >= before &&
            after - before <= const Duration(milliseconds: 25);
        final sample =
            heard.inMicroseconds -
            (before.inMicroseconds + after.inMicroseconds) ~/ 2;
        final ok = clockOk && tight;
        _handoffTrace(
          'sample#$i drift=${sample ~/ 1000} valid=$ok'
          '${clockOk ? '' : ' clock moved=${moved ~/ 1000} wall=${wall ~/ 1000}'}'
          '${tight ? '' : ' bracket'}',
        );
        if (ok) valid.add(sample);
        if (valid.length >= 3) break;
      }
    } catch (_) {}
    if (valid.length < 2) {
      _handoffTrace('drift#$pass=n/a valid=false samples=${valid.length}');
      return null;
    }
    valid.sort();
    final drift = Duration(microseconds: valid[valid.length ~/ 2]);
    _handoffTrace(
      'drift#$pass=${drift.inMilliseconds} valid=true samples=${valid.length}',
    );
    return drift;
  }

  Future<
    ({Duration? drift, bool live, bool running, bool abort, String reason})
  >
  _settleHandoffDeck(
    PlaybackDeck outgoing,
    PlaybackDeck incoming,
    bool Function() stillWanted, {
    required String kind,
    required Duration coldUsed,
  }) async {
    ({Duration? drift, bool live, bool running, bool abort, String reason})
    result(
      Duration? drift,
      String reason, {
      bool running = true,
      bool abort = false,
    }) => (
      drift: drift,
      live: true,
      running: running,
      abort: abort,
      reason: reason,
    );
    if (!stillWanted() || outgoing.state != PlaybackDeckState.playing) {
      return result(null, 'outgoing_stopped', running: false);
    }
    if (!await _awaitHandoffRunning(incoming, stillWanted)) {
      return result(null, 'incoming_not_running', running: false, abort: true);
    }
    final budget = Stopwatch()..start();
    Duration? best;
    Duration? previous;
    var corrections = 0;
    var warmUsed = _handoffLatencyFor(kind).warm;
    var measured = await _measureHandoffDrift(outgoing, incoming, pass: 1);
    while (true) {
      if (!stillWanted()) return result(best, 'superseded');
      if (measured == null) {
        return result(
          best,
          best == null ? 'no_valid_measurement' : 'stale_after_correction',
        );
      }
      final drift = measured;
      if (corrections == 0) {
        _learnHandoffLatency(kind, drift, cold: true);
        _handoffTrace(
          'learned kind=$kind cold=${coldUsed.inMilliseconds}'
          '->${handoffLatencyFor(kind, cold: true).inMilliseconds} '
          'drift=${drift.inMilliseconds}',
        );
      } else {
        _learnHandoffLatency(kind, drift, cold: false);
        _handoffTrace(
          'learned kind=$kind warm=${warmUsed.inMilliseconds}'
          '->${handoffLatencyFor(kind, cold: false).inMilliseconds} '
          'drift=${drift.inMilliseconds}',
        );
        warmUsed = warmUsed - drift;
      }
      if (best == null || drift.abs() < best.abs()) best = drift;
      if (drift.abs() > _handoffAbortDrift &&
          previous != null &&
          previous.abs() > _handoffAbortDrift) {
        return result(drift, 'drift_over_limit', abort: true);
      }
      if (drift.abs() <= _handoffDipTolerance) {
        return result(drift, 'aligned');
      }
      if (corrections >= _handoffMaxCorrections ||
          budget.elapsed > _handoffSettleBudget) {
        return result(drift, 'correction_budget');
      }
      if (previous != null && drift.abs() >= previous.abs()) {
        return result(drift, 'correction_not_improving');
      }
      previous = drift;
      final heard = await incoming.getCurrentPosition();
      if (heard == null || outgoing.state != PlaybackDeckState.playing) {
        return result(best, 'reference_lost');
      }
      corrections++;
      final target = heard - drift + warmUsed;
      _handoffTrace(
        'correct#$corrections seek=${target.inMilliseconds} '
        'in=${heard.inMilliseconds} drift=${drift.inMilliseconds} '
        'kind=$kind warm=${warmUsed.inMilliseconds}',
      );
      await incoming.seek(target);
      if (!await _awaitHandoffFreshClock(
        incoming,
        stillWanted,
        target: target,
      )) {
        return result(best, 'stale_after_correction');
      }
      measured = await _measureHandoffDrift(
        outgoing,
        incoming,
        pass: corrections + 1,
      );
    }
  }

  Future<void> _traceHandoffPositions(
    String label,
    PlaybackDeck outgoing,
    PlaybackDeck incoming, {
    Stopwatch? took,
  }) async {
    try {
      final out = await outgoing.getCurrentPosition();
      final inc = await incoming.getCurrentPosition();
      final drift = out == null || inc == null
          ? 'n/a'
          : '${(inc - out).inMilliseconds}';
      _handoffTrace(
        '$label out=${out?.inMilliseconds} in=${inc?.inMilliseconds} '
        'drift=$drift'
        '${took == null ? '' : ' took=${took.elapsedMilliseconds}'}',
      );
    } catch (_) {}
  }

  Future<void> _dipSwitchDecks(
    PlaybackDeck outgoing,
    PlaybackDeck incoming,
    double volume, {
    required bool Function() stillWanted,
  }) async {
    const step = Duration(milliseconds: 15);
    const downSteps = 4;
    const upSteps = 6;
    for (var i = 1; i <= downSteps; i++) {
      if (!stillWanted()) return;
      if (outgoing.state != PlaybackDeckState.playing) return;
      await outgoing.setVolume(
        volume * (1 - PlaybackRamp.curve(i / downSteps)),
      );
      await Future<void>.delayed(step);
    }
    for (var i = 1; i <= upSteps; i++) {
      if (!stillWanted()) return;
      await incoming.setVolume(volume * PlaybackRamp.curve(i / upSteps));
      if (i < upSteps) await Future<void>.delayed(step);
    }
  }

  Future<void> _crossfadeDecks(
    PlaybackDeck outgoing,
    PlaybackDeck incoming,
    double volume, {
    required bool Function() stillWanted,
    bool correlated = true,
  }) async {
    final step = Duration(
      microseconds: _handoffFade.inMicroseconds ~/ _handoffFadeSteps,
    );
    for (var i = 1; i <= _handoffFadeSteps; i++) {
      if (!stillWanted()) return;
      if (outgoing.state != PlaybackDeckState.playing) return;
      final gains = handoffFadeGains(
        i / _handoffFadeSteps,
        correlated: correlated,
      );
      await Future.wait([
        incoming.setVolume(volume * gains.incoming),
        outgoing.setVolume(volume * gains.outgoing),
      ]);
      if (i == _handoffFadeSteps ~/ 2) {
        await _traceHandoffPositions('mid', outgoing, incoming);
      }
      if (i < _handoffFadeSteps) await Future<void>.delayed(step);
    }
  }

  Future<void> onPermanentDownloadReady(
    Track track,
    String path, {
    String? replacingSource,
    String? sourceKind,
  }) async {
    if (_disposed ||
        _stopRequested ||
        !_cast.localRequested ||
        playbackExclusiveOutput.value ||
        path.trim().isEmpty ||
        (path.startsWith('content://') && !_dependencies.isAndroid) ||
        _index < 0 ||
        _index >= _media.length) {
      return;
    }
    final media = _media[_index];
    final generation = _playRequestGeneration;
    if (!_sourceReady) {
      // The old playback instance can still be active while cancellation of
      // its preparation awaits. Only the requested catalog track may defer.
      final current = media.catalogTrack;
      if ((_switchingGeneration == generation ||
              _pausedLoadGeneration == generation) &&
          generation != 0 &&
          current != null &&
          _samePermanentTrack(current, track)) {
        _loadingPermanentOffer = (
          track: track,
          path: path,
          occurrence: _playOccurrence,
          generation: generation,
        );
      }
      return;
    }
    if (_cast.active || _player.isDirect) return;
    final current =
        media.catalogTrack ??
        (_permanentCatalogInstance == _playbackInstance
            ? _permanentCatalogTrack
            : null) ??
        (replacingSource != null && media.source == replacingSource
            ? track
            : null);
    if (current == null) return;
    if (!identical(current, track) && !_samePermanentTrack(current, track)) {
      return;
    }
    _loadingPermanentOffer = null;
    final existingOffer = _pendingPermanentOffer;
    if (existingOffer != null &&
        existingOffer.instance == _playbackInstance &&
        existingOffer.path == path)
      return;
    final offer = (track: track, path: path, instance: _playbackInstance);
    _pendingPermanentOffer = offer;
    await _serializeSourceChange(() async {
      final outgoing = _player;
      if (_index < 0 || _index >= _media.length) return;
      final activeMedia = _media[_index];
      bool sameSession() =>
          !_disposed &&
          generation == _playRequestGeneration &&
          offer.instance == _playbackInstance &&
          _index >= 0 &&
          _index < _media.length &&
          identical(_media[_index], activeMedia) &&
          identical(_player, outgoing);
      bool currentRequest() =>
          sameSession() &&
          identical(_pendingPermanentOffer, offer) &&
          _sourceReady &&
          !_failures.checking &&
          _playbackError == null &&
          !_cast.active &&
          !playbackExclusiveOutput.value &&
          !outgoing.isDirect &&
          !_completing &&
          (outgoing.state == PlaybackDeckState.playing ||
              outgoing.state == PlaybackDeckState.paused ||
              (outgoing.state == PlaybackDeckState.stopped &&
                  identical(outgoing, _preparedPausedDeck)));
      if (!currentRequest()) return;
      PlaybackDeck? incoming;
      ContentUriPlaybackLease? lease;
      var incomingResumeAttempted = false;
      var outgoingPaused = false;
      var outgoingFaded = false;
      var committed = false;
      try {
        await _cancelTransitions();
        if (!currentRequest()) return;
        var resolved = path;
        if (path.startsWith('content://')) {
          lease = await PlatformBridge.openContentUriPlaybackLease(path);
          if (lease == null || !currentRequest()) return;
          resolved = lease.path;
        }
        incoming = _dependencies.createDeck(
          'music-permanent-${DateTime.now().microsecondsSinceEpoch}',
        );
        if (identical(incoming, outgoing)) {
          incoming = null;
          return;
        }
        _listenToPlayer(incoming);
        await incoming.configureOutput();
        await incoming.setVolume(
          outgoing.state == PlaybackDeckState.playing
              ? 0
              : _normalizationVolume,
        );
        await incoming.setFileSource(resolved);
        if (!currentRequest()) return;
        Duration? incomingDuration;
        try {
          incomingDuration = await incoming.getDuration();
        } catch (_) {
          // Duration is best effort; the decoder may report it later.
        }
        if (!currentRequest()) return;
        var wasPlaying = outgoing.state == PlaybackDeckState.playing;
        var position =
            await outgoing.getCurrentPosition() ?? playbackState.value.position;
        if (!currentRequest()) return;
        await incoming.seek(position);
        await Future<void>.delayed(Duration.zero);
        if (!currentRequest()) return;
        if (wasPlaying) {
          incomingResumeAttempted = true;
          outgoingFaded = true;
          final live = await _handoffReferenceAdvances(outgoing);
          _handoffTrace('reference advancing=$live');
          if (!currentRequest()) return;
          final latest = await outgoing.getCurrentPosition();
          if (!currentRequest()) return;
          final handoffWatch = Stopwatch()..start();
          final startWatch = Stopwatch()..start();
          final kind = _handoffKindOf(incoming, path, sourceKind);
          final latencies = _handoffLatencyFor(kind);
          final startLatency = live ? latencies.cold : _handoffStaticLatency;
          final masterOffset = masterOffsetFor(
            trackKey: track.id,
            kindA: _handoffKindOf(outgoing, replacingSource ?? '', null),
            kindB: kind,
          );
          final startTarget =
              (latest ?? position) + startLatency + masterOffset;
          _handoffTrace(
            'start out=${(latest ?? position).inMilliseconds} '
            'seek=${startTarget.inMilliseconds} '
            'kind=$kind cold=${startLatency.inMilliseconds} '
            'warm=${latencies.warm.inMilliseconds}',
          );
          await incoming.seek(startTarget);
          await incoming.resume().timeout(_handoffStartTimeout);
          _handoffTrace(
            'resume returned after ${startWatch.elapsedMilliseconds}',
          );
          if (!live) {
            _handoffStaticLatency = _clampHandoffLatency(
              startWatch.elapsed,
              _handoffStaticLatencyLimit,
            );
          }
          if (!currentRequest()) return;
          final settled = live
              ? await _settleHandoffDeck(
                  outgoing,
                  incoming,
                  currentRequest,
                  kind: kind,
                  coldUsed: startLatency,
                )
              : (
                  drift: null,
                  live: false,
                  running: false,
                  abort: false,
                  reason: 'static_reference',
                );
          if (!currentRequest()) return;
          final drift = settled.drift;
          final String mode;
          if (!settled.live) {
            mode = 'legacy';
          } else if (settled.abort) {
            mode = 'abort';
          } else if (!settled.running) {
            mode = incoming.state == PlaybackDeckState.playing
                ? 'dip'
                : 'abort';
          } else if (settled.reason == 'stale_after_correction') {
            mode = 'dip';
          } else if (drift == null) {
            mode = 'legacy';
          } else if (drift.abs() <= _handoffDriftTolerance) {
            mode = 'crossfade';
          } else if (drift.abs() <= _handoffAcceptDrift) {
            mode = 'dip';
          } else {
            mode = 'abort';
          }
          _handoffTrace(
            'mode=$mode reason=${settled.reason} '
            'drift=${drift == null ? 'n/a' : drift.inMilliseconds}',
          );
          if (mode == 'abort') {
            _log.w('Could not align the audio for the source switch');
            return;
          }
          if (mode == 'dip') {
            await _dipSwitchDecks(
              outgoing,
              incoming,
              _normalizationVolume,
              stillWanted: currentRequest,
            );
          } else {
            await _crossfadeDecks(
              outgoing,
              incoming,
              _normalizationVolume,
              stillWanted: currentRequest,
            );
          }
          if (!currentRequest()) return;
          if (outgoing.state == PlaybackDeckState.playing) {
            await outgoing.pause();
            outgoingPaused = true;
          } else {
            wasPlaying = false;
            await incoming.pause();
            await incoming.setVolume(_normalizationVolume);
          }
          position = await incoming.getCurrentPosition() ?? position;
          await _traceHandoffPositions(
            'end',
            outgoing,
            incoming,
            took: handoffWatch,
          );
        }
        if (!currentRequest()) return;
        final completedBeforeCommit =
            wasPlaying && incoming.state == PlaybackDeckState.completed;
        if (wasPlaying &&
            !completedBeforeCommit &&
            incoming.state != PlaybackDeckState.playing) {
          return;
        }
        _player = incoming;
        _preparedPausedDeck = wasPlaying ? null : incoming;
        incoming = null;
        committed = true;
        _handoffCommits++;
        _activeResolvedPath = null;
        _permanentCatalogTrack = current;
        _permanentCatalogInstance = offer.instance;
        _relocateQueuedSource(
          activeMedia.source,
          path,
          origin: activeMedia.originSource ?? activeMedia.source,
        );
        final relocatedItem = _toMediaItem(_media[_index]);
        mediaItem.add(
          incomingDuration != null && incomingDuration > Duration.zero
              ? relocatedItem.copyWith(duration: incomingDuration)
              : relocatedItem,
        );
        _broadcastPosition(position, force: true);
        _broadcastState(
          playerState: completedBeforeCommit
              ? PlaybackDeckState.completed
              : wasPlaying
              ? PlaybackDeckState.playing
              : PlaybackDeckState.paused,
        );
        if (completedBeforeCommit) unawaited(_handlePlayerComplete());
        try {
          await _disposeDeck(outgoing);
        } catch (error) {
          _log.w('Could not dispose outgoing playback deck: $error');
        }
        try {
          await _retireCatalogListening();
        } finally {
          await _persistSession(position: position);
        }
      } catch (error) {
        _log.w('Permanent playback handoff failed: $error');
      } finally {
        var incomingSilent = !incomingResumeAttempted;
        try {
          if (incoming != null) {
            if (incomingResumeAttempted) {
              try {
                await incoming.stop();
                incomingSilent = true;
              } catch (_) {
                try {
                  await incoming.setVolume(0);
                  incomingSilent = true;
                } catch (_) {}
              }
            }
            try {
              await _disposeDeck(incoming);
              incomingSilent = true;
            } catch (error) {
              _log.w('Could not dispose incoming playback deck: $error');
            }
          }
        } finally {
          if (lease != null) {
            await PlatformBridge.closeContentUriPlaybackLease(lease.token);
          }
        }
        if (!committed && outgoingFaded) {
          try {
            await outgoing.setVolume(_normalizationVolume);
          } catch (_) {}
        }
        if (!committed &&
            incomingSilent &&
            (outgoingPaused || outgoingFaded) &&
            sameSession() &&
            _sourceReady &&
            !_failures.checking &&
            _playbackError == null &&
            !_cast.active &&
            !_userPaused &&
            !_interruptionActive &&
            !_completing &&
            (outgoing.state == PlaybackDeckState.paused ||
                (playbackExclusiveOutput.value &&
                    (outgoing.state == PlaybackDeckState.stopped ||
                        outgoingFaded)))) {
          try {
            await outgoing.resume();
          } catch (_) {}
        }
      }
    });
    if (identical(_pendingPermanentOffer, offer) &&
        (generation == _playRequestGeneration || _disposed)) {
      _pendingPermanentOffer = null;
    }
  }

  /// Refreshes every occurrence without reopening the decoder or seeking.
  Future<void> onSourceMetadataChanged(String source) async {
    // An edited network file must not play from its copy before the edit.
    await _prefetch.invalidate(source);
    if (_disposed || !_media.any((item) => item.source == source)) return;
    final token = Object();
    _metadataChanges[source] = token;
    try {
      final metadata = source.startsWith('network://')
          ? await _dependencies.readNetworkMetadata(source)
          : await _dependencies.readMetadata(source);
      if (metadata['error'] != null) return;
      final cover = metadata['cover_path'] as String?;
      String? artwork;
      Uri? networkCover;
      if (source.startsWith('network://')) {
        final media = _media.where((item) => item.source == source).firstOrNull;
        // The song left the queue, or a newer change reads its tags again.
        if (media == null ||
            _disposed ||
            !identical(_metadataChanges[source], token)) {
          return;
        }
        // The store keeps a network song's covers, which its items show.
        networkCover = await _covers.readTagCover(media, cover);
        _covers.invalidate(media.coverReference);
      } else if (cover != null && cover.isNotEmpty) {
        artwork = normalizeArtUri(cover);
      }
      if (_disposed || !identical(_metadataChanges[source], token)) return;
      var changed = false;
      for (var i = 0; i < _media.length; i++) {
        final previous = _media[i];
        if (previous.source != source) continue;
        final duration = readPositiveInt(metadata['duration']);
        final updated = PlayableMedia.fromJson({
          ...previous.toJson(),
          for (final field in const ['title', 'artist', 'album', 'genre'])
            if (metadata[field] != null) field: metadata[field].toString(),
          if (duration != null) 'durationMs': duration * 1000,
          'artUri': ?(artwork ?? previous.artUri),
          'bitDepth': metadata['bit_depth'] ?? previous.bitDepth,
          'sampleRate': metadata['sample_rate'] ?? previous.sampleRate,
          'bitrate': metadata['bitrate'] ?? previous.bitrate,
          'format': metadata['format'] ?? previous.format,
          'explicit': metadata['explicit'] ?? previous.explicit,
        })!;
        final facts = _toMediaItem(updated);
        MediaItem replace(MediaItem item) => item.copyWith(
          title: facts.title,
          artist: facts.artist,
          album: facts.album,
          duration: facts.duration ?? item.duration,
          artUri:
              networkCover ?? (artwork == null ? item.artUri : facts.artUri),
          extras: {
            ...?item.extras,
            ...?facts.extras,
            'explicit': updated.explicit,
          },
        );
        final old = _queueItems[i];
        final next = replace(old);
        _media[i] = updated;
        _queueItems[i] = next;
        final originalIndex = _originalQueueOrder?.indexWhere(
          (item) => identical(item, old),
        );
        if (originalIndex != null && originalIndex >= 0) {
          _originalQueueOrder![originalIndex] = next;
        }
        final current = mediaItem.value;
        if (i == _index && current != null) {
          mediaItem.add(replace(current));
        }
        changed = true;
      }
      if (changed) {
        _markSessionQueueChanged();
        queue.add(List.unmodifiable(_queueItems));
        await _persistSession(position: playbackState.value.position);
      }
    } finally {
      if (identical(_metadataChanges[source], token)) {
        _metadataChanges.remove(source);
      }
    }
  }

  /// Release native file handles before unlinking a local song. Stop alone can
  /// retain the source in AVPlayer/MediaPlayer, so retire the owning deck.
  /// Keep the queue until deletion succeeds; a failed delete remains resumable.
  Future<void> prepareSourceDeletion(String source) async {
    if (_disposed ||
        _cast.active ||
        !_media.any((item) => item.source == source)) {
      return;
    }
    final isCurrent =
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].source == source;
    final generation = isCurrent
        ? ++_playRequestGeneration
        : _playRequestGeneration;
    if (isCurrent) {
      _newPlaybackOccurrence();
      _sourceReady = false;
      _userPaused = true;
      _pendingRestorePosition = playbackState.value.position;
      _playbackAutomation.cancelPendingActions();
      await _player.cancelPreparation();
    }
    await _serializeSourceChange(() async {
      if (_disposed || generation != _playRequestGeneration) return;
      await _cancelTransitions();
      if (!isCurrent || _disposed || generation != _playRequestGeneration) {
        return;
      }
      try {
        await _disposeDeck(_player);
      } finally {
        if (!_disposed) {
          _player = _dependencies.createDeck('music-player-delete-$generation');
          _listenToPlayer(_player);
          _activeResolvedPath = null;
          _broadcastState(playerState: PlaybackDeckState.paused);
        }
      }
      await _cleanupPendingResolvedPaths();
    });
  }

  /// Invalidates a deleted source and removes it from the local queue. During
  /// Jam the shared queue remains authoritative, even if the file is missing.
  Future<void> onSourceDeleted(String source) async {
    final target = source.trim();
    if (_disposed || target.isEmpty) return;
    await _prefetch.invalidate(target);
    if (target.startsWith('network://')) {
      try {
        if (await _dependencies.offlineCopy(target) != null) return;
      } catch (_) {}
    }

    final hadPendingResolution = await _sourceCache.invalidate(target);

    // Check after the awaits: a Jam session may have started while caches were
    // being invalidated. Only Jam reconciliation may edit its shared queue.
    if (_jamQueueActive || _disposed) return;
    final removed = _pruneQueuedSource(target);
    if (removed == null) return;

    Future<void>? reaction;
    if (_media.isEmpty) {
      reaction = stop();
    } else if (removed.wasCurrent) {
      reaction = _playIndex(removed.nextIndex.clamp(0, _media.length - 1));
    } else {
      _index = removed.nextIndex.clamp(0, _media.length - 1);
      _broadcastState();
      unawaited(_persistSession(position: playbackState.value.position));
    }
    if (!hadPendingResolution) {
      await reaction;
    } else {
      // Queue invalidation must not wait behind an unavailable SAF provider.
      unawaited(
        reaction?.catchError((Object error) {
          _log.w('Could not update playback after source deletion: $error');
        }),
      );
    }
  }

  ({bool wasCurrent, int nextIndex})? _pruneQueuedSource(String target) {
    final wasCurrent =
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].source == target;

    var removedBeforeCurrent = 0;
    final kept = <PlayableMedia>[];
    final keptQueue = <MediaItem>[];
    final newIndices = <int, int>{};
    for (var i = 0; i < _media.length; i++) {
      if (_media[i].source == target) {
        if (i < _index) removedBeforeCurrent++;
        continue;
      }
      newIndices[i] = kept.length;
      kept.add(_media[i]);
      keptQueue.add(_queueItems[i]);
    }

    if (kept.length == _media.length) return null;

    _media
      ..clear()
      ..addAll(kept);
    _queueItems
      ..clear()
      ..addAll(keptQueue);
    final keptSet = Set<MediaItem>.identity()..addAll(keptQueue);
    _originalQueueOrder?.removeWhere((item) => !keptSet.contains(item));
    _markSessionQueueChanged();
    final keptHistory = [for (final index in _playHistory) ?newIndices[index]];
    _playHistory
      ..clear()
      ..addAll(keptHistory);
    queue.add(List<MediaItem>.unmodifiable(_queueItems));

    return (wasCurrent: wasCurrent, nextIndex: _index - removedBeforeCurrent);
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) =>
      _cast.setVolume(volumeIndex);

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) =>
      _cast.adjustVolume(direction);

  Future<void> _dispose() async {
    await _experimentalTransfer?.dispose();
    _experimentalTransfer = null;
    _experimentalAttempt = null;
    final preparing = _preparingCatalogTrack;
    if (preparing != null) unawaited(_catalogPlayback.cancel(preparing));
    _autoplay.reset();
    _prefetch.stop();
    _upcoming.stop();
    _disposed = true;
    unawaited(_shuffleStrategyEvents.close());
    await _cast.dispose();
    _runtime.personalization.finish();
    await _runtime.personalization.flush();
    if (_dependencies.isIOS || _dependencies.isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
    }
    if (identical(musicPlayerRuntime.handler, this)) {
      autoMixStatus.value = AutoMixStatus.idle;
      autoMixPreparing.value = false;
    }
    _runtime.detach(this);
    cancelSleepTimer();
    _listeningTimer?.cancel();
    _dependencies.recorder.update(null, playing: false, ended: true);
    await _dependencies.recorder.flush();
    _playRequestGeneration++;
    _headphoneMonitoringRevision++;
    await _automationDevicesSubscription?.cancel();
    await _playbackAutomation.dispose();
    await _player.cancelPreparation();
    await _sourceChangeTail;
    await _autoMix.dispose();
    await _gapless.dispose();
    _haptics.dispose();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _sourceReady = false;
    for (final player in _playerSubscriptions.keys.toList()) {
      await _disposeDeck(player);
    }
    await _retireCatalogListening();
    _activeResolvedPath = null;
    await _sourceCache.dispose();
    await _formats.dispose();
  }
}

Future<MusicPlayerHandler> initMusicPlayer() => musicPlayerRuntime.initialize();

/// Restores the last persisted playback session (if any) into a freshly
/// initialized handler, paused. Entries whose plain file paths no longer
/// exist are dropped; content URIs are kept and fail gracefully at play time.
Future<void> restorePersistedPlaybackSession() =>
    musicPlayerRuntime.restoreSession();
