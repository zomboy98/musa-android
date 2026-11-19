import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:mornye/services/connectivity_monitor.dart';
import 'package:mornye/services/lyrics_corrections_store.dart';
import 'package:mornye/services/lyrics_sync_store.dart';
import 'package:mornye/services/music_player_runtime.dart'
    show musicPlayerRuntime;
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/player_lyrics_persistence.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_corrections.dart';
import 'package:mornye/utils/lyrics_draft.dart';
import 'package:mornye/utils/lyrics_estimated_sync.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_sync.dart';

final _log = AppLogger('PlayerMetadata');

/// Returns LRC text from the configured lyrics providers, or empty.
typedef OnlineLyricsFetcher = Future<String> Function(MediaItem item);

/// Another provider's synced lyrics for [item], other than [exclude], used
/// only to measure the timing of the lyrics being shown.
typedef SecondaryLyricsFetcher =
    Future<({String provider, String raw})?> Function(
      MediaItem item,
      String exclude,
    );

/// Every provider answer for [item] that may carry synced lyrics, tried in
/// turn within a small request budget.
typedef UpgradeLyricsFetcher =
    Future<List<({String provider, String raw})>> Function(MediaItem item);
typedef OnlineLyricsSaver = Future<void> Function(String source, String lyrics);

Map<dynamic, dynamic>? _catalogData(String source) {
  if (!source.startsWith('catalog:')) return null;
  try {
    return jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(source.substring(8))),
          ),
        )
        as Map;
  } catch (_) {
    return null;
  }
}

(String, String) _lyricsIdentity(MediaItem item, String source) {
  final data = _catalogData(source);
  final id = data?['id']?.toString().trim() ?? '';
  if (id.isNotEmpty) {
    return (
      'catalog:${data?['source']?.toString().trim().toLowerCase() ?? ''}',
      id,
    );
  }
  return (item.id, source);
}

/// The recording's ISRC, from the queue item or the catalog entry it plays.
String lyricsIsrc(MediaItem item) {
  final extras = item.extras;
  final display = extras?['displayMetadata'];
  for (final value in [
    extras?['isrc'],
    if (display is Map) display['isrc'],
    _catalogData(extras?['source']?.toString() ?? '')?['isrc'],
  ]) {
    final isrc = normalizeIsrc(value?.toString());
    if (isrc.isNotEmpty) return isrc;
  }
  return '';
}

Future<String> _fetchOnlineLyrics(MediaItem item) async {
  // The bridge's spotify_id field also carries namespaced Deezer IDs.
  var lyricsTrackId = '';
  final source = item.extras?['source']?.toString() ?? '';
  final track = _catalogData(source);
  if (track != null) {
    final provider = track['source']?.toString().toLowerCase() ?? '';
    final id = track['id']?.toString() ?? '';
    if (id.startsWith('spotify:')) {
      lyricsTrackId = id.substring(8);
    } else if (provider.trim() == 'deezer' ||
        id.trim().toLowerCase().startsWith('deezer:')) {
      final trimmedId = id.trim();
      final deezerId = trimmedId.toLowerCase().startsWith('deezer:')
          ? trimmedId.substring(7).trim()
          : trimmedId;
      if (RegExp(r'^[0-9]+$').hasMatch(deezerId)) {
        lyricsTrackId = 'deezer:$deezerId';
      }
    } else if (provider == 'spotify') {
      lyricsTrackId = id;
    }
  }
  final result = await PlatformBridge.getLyricsLRCWithSource(
    lyricsTrackId,
    item.title,
    item.artist ?? '',
    durationMs: item.duration?.inMilliseconds ?? 0,
    isrc: lyricsIsrc(item),
    refresh: item.extras?['lyricsRefresh'] == true,
  ).timeout(const Duration(seconds: 30));
  final raw = result['lyrics']?.toString() ?? '';
  if (raw.trim().isNotEmpty &&
      raw.trim().toLowerCase() != '[instrumental:true]' &&
      !LyricsParser.parse(raw).isEmpty) {
    _log.i(
      'Lyrics shown: provider=${result['source']} '
      'sync=${result['sync_type']} isrc=${lyricsIsrc(item).isNotEmpty}',
    );
    return raw;
  }
  return result['instrumental'] == true ? '[instrumental:true]' : '';
}

Future<({String provider, String raw})?> _fetchSecondaryLyrics(
  MediaItem item,
  String exclude,
) async {
  final current = exclude.toLowerCase();
  final enabled = await PlatformBridge.getEnabledLyricsProviders();
  final others = [
    for (final name in enabled)
      if (current.isEmpty || !current.contains(name.toLowerCase())) name,
  ];
  if (others.isEmpty) return null;
  final provider = others.firstWhere(
    (name) => name.toLowerCase() == 'lrclib',
    orElse: () => others.first,
  );
  final result = await PlatformBridge.getLyricsFromProvider(
    provider,
    trackName: item.title,
    artistName: item.artist ?? '',
    durationMs: item.duration?.inMilliseconds ?? 0,
  ).timeout(const Duration(seconds: 20));
  final raw = result['lyrics']?.toString() ?? '';
  return raw.trim().isEmpty ? null : (provider: provider, raw: raw);
}

const _upgradeRequestBudget = 4;
const _upgradeMissTtl = Duration(minutes: 45);
final _upgradeMisses = <String, DateTime>{};

Future<List<({String provider, String raw})>> _fetchUpgradeCandidates(
  MediaItem item,
) async {
  final found = <({String provider, String raw})>[];
  final providers = await PlatformBridge.getEnabledLyricsProviders();
  for (final provider in providers.take(_upgradeRequestBudget)) {
    try {
      final result = await PlatformBridge.getLyricsFromProvider(
        provider,
        trackName: item.title,
        artistName: item.artist ?? '',
        durationMs: item.duration?.inMilliseconds ?? 0,
      ).timeout(const Duration(seconds: 12));
      final raw = result['lyrics']?.toString() ?? '';
      if (raw.trim().isNotEmpty) found.add((provider: provider, raw: raw));
    } catch (_) {}
  }
  return found;
}

Future<bool> _defaultOnlineAvailable() async {
  try {
    return !(await Connectivity().checkConnectivity()).contains(
      ConnectivityResult.none,
    );
  } catch (_) {
    // Unknown transport is not evidence of being offline.
    return true;
  }
}

/// Owns file metadata and lyrics for the full player. Requests are scoped to
/// the current queue item so a late probe cannot replace another track's data.
class PlayerMetadataController extends ChangeNotifier {
  PlayerMetadataController({
    PlaybackMetadataReader? readMetadata,
    Future<ParsedLyrics> Function(String?)? parseLyrics,
    OnlineLyricsFetcher? fetchOnlineLyrics,
    OnlineLyricsSaver? saveOnlineLyrics,
    LyricsCorrectionsStore? corrections,
    LyricsSyncStore? syncStore,
    SecondaryLyricsFetcher? fetchSecondaryLyrics,
    UpgradeLyricsFetcher? fetchUpgradeCandidates,
    DateTime Function()? clock,
    SourceMetadataEvents? metadataEvents,
    this.automaticOnlineSearch = true,
    Future<bool> Function()? onlineAvailable,
    Stream<bool>? onlineChanges,
  }) : _readMetadata = readMetadata ?? readPlaybackFileMetadataWithRetry,
       _parseLyrics = parseLyrics ?? LyricsParser.parseAsyncNative,
       _fetchOnline = fetchOnlineLyrics ?? _fetchOnlineLyrics,
       _saveOnline = saveOnlineLyrics ?? persistPlayerLyrics,
       _corrections = corrections ?? const LyricsCorrectionsStore(),
       _syncStore = syncStore ?? const LyricsSyncStore(),
       _fetchSecondary = fetchSecondaryLyrics ?? _fetchSecondaryLyrics,
       _fetchUpgrade = fetchUpgradeCandidates ?? _fetchUpgradeCandidates,
       _clock = clock ?? DateTime.now,
       _metadataEvents = metadataEvents ?? SourceMetadataEvents.instance,
       _onlineAvailable = onlineAvailable ?? _defaultOnlineAvailable,
       _onlineChanges = onlineChanges {
    _unsubscribeMetadata = _metadataEvents.subscribe((changed) async {
      if (_disposed ||
          changed != source ||
          _savingLyricsSources.contains(changed)) {
        return;
      }
      _requestKey = null;
      await load(_item);
    });
  }

  late final void Function() _unsubscribeMetadata;

  final PlaybackMetadataReader _readMetadata;
  final Future<ParsedLyrics> Function(String?) _parseLyrics;
  final OnlineLyricsFetcher _fetchOnline;
  final OnlineLyricsSaver _saveOnline;
  final LyricsCorrectionsStore _corrections;
  final LyricsSyncStore _syncStore;
  final SecondaryLyricsFetcher _fetchSecondary;
  final UpgradeLyricsFetcher _fetchUpgrade;
  final DateTime Function() _clock;
  final SourceMetadataEvents _metadataEvents;
  final bool automaticOnlineSearch;
  final Future<bool> Function() _onlineAvailable;
  final Stream<bool>? _onlineChanges;
  StreamSubscription<bool>? _connectivitySubscription;
  (String, String)? _onlineIdentity;
  int _onlineGeneration = 0;
  int _onlineAttemptRevision = 0;
  bool _automaticAttempted = false;
  bool _durationRetryAttempted = false;
  bool _automaticCheckPending = false;
  int? _lastSearchedDurationMs;
  bool _onlineSearchFailed = false;
  bool _onlineDeferredOffline = false;
  ParsedLyrics? _fetchedLyrics;
  (String, String)? _searchedLyricsIdentity;
  String _fetchedRaw = '';
  bool _hasEditedLyrics = false;
  String _servedRaw = '';
  List<LyricsLinePatch> _patches = const [];
  int _staleCorrections = 0;
  bool _onlineLyricsProvisional = false;
  bool _onlineInstrumental = false;
  final _savingLyricsSources = <String>{};
  MediaItem? _item;
  bool _searchingOnline = false;
  bool _onlineSearchMissed = false;
  bool _onlineLyricsSaveFailed = false;
  (String, String, String?)? _requestKey;
  String? _loadedPath;
  Map<String, dynamic> _fallback = const {};
  int _generation = 0;
  int _metadataRevision = 0;
  String _lyricsRaw = '';
  bool _probePending = false;
  bool _disposed = false;

  String? get source => _requestKey?.$2;

  /// The queue item whose file this controller reads, or null for an item
  /// without one.
  MediaItem? get item => _item;

  /// The lyrics as stored: LRC, TTML or plain text, empty when none.
  String get rawLyrics => _lyricsRaw;

  /// The path the current metadata was probed from: the resolved copy of a
  /// document, or the source itself.
  String? get filePath => _loadedPath;
  Map<String, dynamic>? _metadata;
  ParsedLyrics _lyrics = ParsedLyrics.empty;
  bool _loading = false;
  Map<String, dynamic>? get metadata => _metadata;
  ParsedLyrics get lyrics => _estimatedLyrics ?? _lyrics;
  bool get loading => _loading;
  bool get searchingOnline => _searchingOnline || _automaticCheckPending;
  bool get onlineLyricsProvisional => _onlineLyricsProvisional;
  bool get onlineInstrumental => _onlineInstrumental;

  /// The last online search for this track found nothing.
  bool get onlineSearchMissed => _onlineSearchMissed;
  bool get onlineSearchFailed => _onlineSearchFailed;
  bool get onlineDeferredOffline => _onlineDeferredOffline;
  bool get onlineLyricsSaveFailed => _onlineLyricsSaveFailed;

  bool _usableLyricsField(String value) {
    final normalized = value.trim().toLowerCase();
    const placeholders = {
      'unknown',
      'unknown title',
      'unknown track',
      'unknown artist',
      'titulo desconocido',
      'título desconocido',
      'pista desconocida',
      'artista desconocido',
    };
    return normalized.isNotEmpty &&
        !placeholders.contains(normalized) &&
        normalized != musicPlayerRuntime.unknownTitle.trim().toLowerCase() &&
        normalized != musicPlayerRuntime.unknownArtist.trim().toLowerCase();
  }

  MediaItem? get _lyricsRequestItem {
    final item = _item;
    if (item == null) return null;
    String choose(String? original, Object? tag) {
      final value = original?.trim() ?? '';
      if (_usableLyricsField(value)) return value;
      final fallback = tag is String ? tag.trim() : '';
      return _usableLyricsField(fallback) ? fallback : value;
    }

    final duration = item.duration;
    final seconds = readPositiveInt(_metadata?['duration']);
    return item.copyWith(
      title: choose(item.title, _metadata?['title']),
      artist: choose(item.artist, _metadata?['artist']),
      duration: duration != null && duration > Duration.zero
          ? duration
          : seconds != null
          ? Duration(seconds: seconds)
          : duration,
    );
  }

  bool get canSearchOnline {
    final item = _lyricsRequestItem;
    return item != null &&
        _usableLyricsField(item.title) &&
        _usableLyricsField(item.artist ?? '');
  }

  (String, String)? get _currentLyricsIdentity {
    final item = _lyricsRequestItem;
    if (item == null || !canSearchOnline) return null;
    return (item.title.trim().toLowerCase(), item.artist!.trim().toLowerCase());
  }

  /// Displays fetched lyrics. Explicit requests can also embed them in an
  /// editable source; automatic lookups are display-only (`persist: false`).
  Future<void> searchOnline() => _searchOnline(persist: true);

  Future<void> _searchOnline({required bool persist}) async {
    final item = _lyricsRequestItem;
    if (_disposed ||
        item == null ||
        _searchingOnline ||
        _savingLyricsSources.contains(this.source) ||
        !canSearchOnline) {
      return;
    }
    final requestedDurationMs = item.duration?.inMilliseconds ?? 0;
    if (_lastSearchedDurationMs != null &&
        _lastSearchedDurationMs! <= 0 &&
        requestedDurationMs > 0) {
      _durationRetryAttempted = true;
    }
    _automaticCheckPending = false;
    _automaticAttempted = true;
    _searchedLyricsIdentity = _currentLyricsIdentity;
    _onlineAttemptRevision++;
    _lastSearchedDurationMs = requestedDurationMs;
    unawaited(_connectivitySubscription?.cancel());
    _connectivitySubscription = null;
    _onlineDeferredOffline = false;
    final generation = _onlineGeneration;
    final metadataRevision = _metadataRevision;
    final source = this.source!;
    _searchingOnline = true;
    _onlineSearchMissed = false;
    _onlineSearchFailed = false;
    _onlineLyricsSaveFailed = false;
    notifyListeners();
    var parsed = ParsedLyrics.empty;
    var raw = '';
    var served = '';
    try {
      raw = await _fetchOnline(
        persist
            ? item.copyWith(extras: {...?item.extras, 'lyricsRefresh': true})
            : item,
      );
      if (_disposed || generation != _onlineGeneration) return;
      if (raw.trim().isNotEmpty &&
          raw.trim().toLowerCase() != '[instrumental:true]') {
        served = raw;
        parsed = await _parseLyrics(raw);
      }
    } catch (error) {
      _log.w('Failed to search lyrics online: $error');
      if (!_disposed && generation == _onlineGeneration) {
        _onlineSearchFailed = true;
      }
    }
    if (_disposed || generation != _onlineGeneration) return;
    _searchingOnline = false;
    final currentRequest = _lyricsRequestItem;
    if (_probePending ||
        currentRequest == null ||
        currentRequest.title != item.title ||
        currentRequest.artist != item.artist) {
      _automaticAttempted = false;
      _maybeSearchAutomatically();
      return;
    }
    // A fresh file probe or tag edit may have supplied authoritative embedded
    // lyrics while the online provider was still answering.
    if (metadataRevision != _metadataRevision &&
        !_lyrics.isEmpty &&
        _fetchedLyrics == null) {
      notifyListeners();
      return;
    }
    if (automaticOnlineSearch &&
        requestedDurationMs <= 0 &&
        (_lyricsRequestItem?.duration?.inMilliseconds ?? 0) > 0 &&
        !_durationRetryAttempted) {
      // Even a successful no-duration match may name another recording.
      // Revalidate it once against the duration received during this request,
      // without ever showing its unverified text.
      _onlineSearchMissed = true;
      _onlineSearchFailed = false;
      _maybeSearchAutomatically();
      return;
    }
    _onlineInstrumental = raw.trim().toLowerCase() == '[instrumental:true]';
    if (_onlineInstrumental) {
      _onlineLyricsProvisional = requestedDurationMs <= 0;
      _onlineSearchMissed = false;
      _lyrics = ParsedLyrics.empty;
      _lyricsRaw = '';
      _fetchedLyrics = null;
      _fetchedRaw = '';
      _metadata = Map.unmodifiable({...?_metadata}..remove('lyrics'));
      notifyListeners();
      return;
    }
    if (parsed.isEmpty) {
      _onlineSearchMissed = !_onlineSearchFailed;
    } else {
      _lyrics = parsed;
      _lyricsRaw = raw;
      _servedRaw = served;
      _patches = const [];
      _staleCorrections = 0;
      _fetchedLyrics = parsed;
      _fetchedRaw = raw;
      _onlineLyricsProvisional = requestedDurationMs <= 0;
      _metadata = Map.unmodifiable({...?_metadata, 'lyrics': raw});
    }
    notifyListeners();
    if (parsed.isEmpty) {
      // Duration can arrive while this request is answering. A miss made
      // without it gets one new attempt with the now-known recording length.
      _maybeSearchAutomatically();
      return;
    }
    if (!_editableSource(source)) {
      unawaited(_applyStoredCorrections(generation, served));
    }
    if (!persist || !_editableSource(source) || _onlineLyricsProvisional) {
      return;
    }

    _savingLyricsSources.add(source);
    try {
      await _saveOnline(source, raw);
      await _metadataEvents.publish(source);
      if (_disposed || generation != _onlineGeneration) return;
      _metadata = Map.unmodifiable({...?_metadata, 'lyrics': raw});
      _lyrics = parsed;
      _lyricsRaw = raw;
    } catch (error) {
      _log.w('Could not embed online lyrics: $error');
      if (_disposed || generation != _onlineGeneration) return;
      _onlineLyricsSaveFailed = true;
    } finally {
      _savingLyricsSources.remove(source);
    }
    if (!_disposed && generation == _onlineGeneration) notifyListeners();
  }

  String? _syncKey;
  int? _trackOffsetMs;
  int _autoOffsetMs = 0;
  ParsedLyrics? _reportedLyrics;
  int _reportedDurationMs = -1;
  LyricsSyncConfidence _syncConfidence = LyricsSyncConfidence.unknown;

  /// The listener's own shift for this track, or null when they have none.
  int? get trackOffsetMs => _trackOffsetMs;

  /// The shift measured against a second provider for this track, or 0.
  int get autoOffsetMs => _autoOffsetMs;

  LyricsSyncConfidence get syncConfidence => _syncConfidence;

  /// Whether the timing of the shown lyrics can be adjusted for this track.
  bool get canAdjustSync => _syncKey != null && lyrics.synced;

  ParsedLyrics? _estimatedLyrics;
  ParsedLyrics? _plainPlanned;
  int _plannedDurationMs = -1;
  bool _plannedEnabled = true;
  bool _estimatedEnabled = true;
  bool _estimatedLoaded = false;
  String _upgrade = 'none';

  /// The shown lyrics are plain text with approximate timing.
  bool get lyricsEstimated => _estimatedLyrics != null;

  bool get estimatedSyncEnabled => _estimatedEnabled;

  /// `none`, `pending` while other providers are asked for synced lyrics, or
  /// `done` once synced lyrics replaced the plain ones.
  String get upgradeState => _upgrade;

  @visibleForTesting
  static void resetUpgradeMisses() => _upgradeMisses.clear();

  Future<void> setEstimatedSyncEnabled(bool enabled) async {
    if (_estimatedEnabled == enabled) return;
    _estimatedEnabled = enabled;
    notifyListeners();
    await _syncStore.writeEstimatedEnabled(enabled);
  }

  Future<void> _loadEstimatedEnabled() async {
    final stored = await _syncStore.readEstimatedEnabled();
    if (_disposed || stored == _estimatedEnabled) return;
    _estimatedEnabled = stored;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) _planPlain();
    super.notifyListeners();
    if (!_disposed) _checkSync();
  }

  String? get _upgradeMissKey {
    final item = _lyricsRequestItem;
    if (item == null) return null;
    return '${item.title.trim().toLowerCase()}|'
        '${(item.artist ?? '').trim().toLowerCase()}|'
        '${item.duration?.inSeconds ?? 0}';
  }

  /// Plain lyrics get approximate timing straight away and, in the
  /// background, one more look for synced lyrics.
  void _planPlain() {
    final plain = _lyrics;
    if (plain.synced ||
        plain.isEmpty ||
        _onlineInstrumental ||
        _hasEditedLyrics) {
      _estimatedLyrics = null;
      _plainPlanned = null;
      return;
    }
    if (!_estimatedLoaded) {
      _estimatedLoaded = true;
      unawaited(_loadEstimatedEnabled());
    }
    final duration = _lyricsRequestItem?.duration;
    final durationMs = duration?.inMilliseconds ?? 0;
    final fresh = !identical(_plainPlanned, plain);
    if (!fresh &&
        _plannedDurationMs == durationMs &&
        _plannedEnabled == _estimatedEnabled) {
      return;
    }
    _plainPlanned = plain;
    _plannedDurationMs = durationMs;
    _plannedEnabled = _estimatedEnabled;
    _estimatedLyrics = _estimatedEnabled
        ? estimatedLyricsFor(plain, duration)
        : null;
    if (!fresh) return;
    _upgrade = 'none';
    final missKey = _upgradeMissKey;
    final missUntil = missKey == null ? null : _upgradeMisses[missKey];
    if (!automaticOnlineSearch ||
        !canSearchOnline ||
        (missUntil != null && _clock().isBefore(missUntil))) {
      return;
    }
    _upgrade = 'pending';
    scheduleMicrotask(() => unawaited(_upgradeToSynced(plain)));
  }

  Future<void> _upgradeToSynced(ParsedLyrics plain) async {
    final item = _lyricsRequestItem;
    final missKey = _upgradeMissKey;
    if (_disposed || item == null || missKey == null) return;
    try {
      if (!await _onlineAvailable()) {
        _upgrade = 'none';
        return;
      }
      final candidates = await _fetchUpgrade(
        item,
      ).timeout(const Duration(seconds: 45));
      for (final candidate in candidates) {
        final parsed = await _parseLyrics(candidate.raw);
        if (_disposed || !identical(_lyrics, plain)) return;
        if (!parsed.synced || parsed.lines.isEmpty) continue;
        final confidence = lyricsDurationConfidence(
          lines: parsed.lines,
          trackDuration: item.duration,
          declaredLength: lrcDeclaredLength(candidate.raw),
        );
        if (confidence == LyricsSyncConfidence.suspect ||
            !lyricsUpgradeAllowed(current: _lyrics, candidate: parsed)) {
          continue;
        }
        _upgrade = 'done';
        _lyrics = parsed;
        _lyricsRaw = candidate.raw;
        _servedRaw = candidate.raw;
        _patches = const [];
        _staleCorrections = 0;
        _fetchedLyrics = parsed;
        _fetchedRaw = candidate.raw;
        _metadata = Map.unmodifiable({...?_metadata, 'lyrics': candidate.raw});
        notifyListeners();
        return;
      }
      _upgradeMisses[missKey] = _clock().add(_upgradeMissTtl);
    } catch (error) {
      _log.w('Could not look for synced lyrics: $error');
    }
    if (!_disposed && identical(_lyrics, plain) && _upgrade == 'pending') {
      _upgrade = 'none';
    }
  }

  void _checkSync() {
    final key = _correctionKey;
    if (key != _syncKey) {
      _syncKey = key;
      _trackOffsetMs = null;
      _autoOffsetMs = 0;
      _reportedLyrics = null;
      if (key != null) unawaited(_loadTrackOffset(key));
    }
    final lyrics = this.lyrics;
    if (!lyrics.synced || lyrics.lines.isEmpty) return;
    final duration = _lyricsRequestItem?.duration;
    final durationMs = duration?.inMilliseconds ?? 0;
    if (identical(_reportedLyrics, lyrics) &&
        _reportedDurationMs == durationMs) {
      return;
    }
    if (!identical(_reportedLyrics, lyrics)) _autoOffsetMs = 0;
    _reportedLyrics = lyrics;
    _reportedDurationMs = durationMs;
    _syncConfidence = lyricsDurationConfidence(
      lines: lyrics.lines,
      trackDuration: duration,
      declaredLength: lyrics.estimated ? null : lrcDeclaredLength(_lyricsRaw),
    );
    _log.i(
      lyricsSyncLogLine(
        provider: lyrics.provider,
        trackDuration: duration,
        span: lyricsSpan(lyrics.lines),
        confidence: _syncConfidence,
        autoMs: _autoOffsetMs,
        trackMs: _trackOffsetMs,
        kind: lyrics.estimated ? 'estimated' : 'synced',
        upgrade: _upgrade,
      ),
    );
    if (identical(lyrics, _fetchedLyrics) &&
        (_syncConfidence == LyricsSyncConfidence.low ||
            _syncConfidence == LyricsSyncConfidence.suspect)) {
      unawaited(_estimateAutoOffset(lyrics, _syncConfidence));
    }
  }

  Future<void> _loadTrackOffset(String key) async {
    final stored = await _syncStore.read(key);
    if (_disposed || key != _syncKey || stored == _trackOffsetMs) return;
    _trackOffsetMs = stored;
    notifyListeners();
  }

  Future<void> _estimateAutoOffset(
    ParsedLyrics lyrics,
    LyricsSyncConfidence confidence,
  ) async {
    final item = _lyricsRequestItem;
    if (item == null || !canSearchOnline) return;
    try {
      final other = await _fetchSecondary(item, lyrics.provider ?? '');
      if (other == null) return;
      final parsed = await _parseLyrics(other.raw);
      if (_disposed || !identical(_lyrics, lyrics) || !parsed.synced) return;
      final otherConfidence = lyricsDurationConfidence(
        lines: parsed.lines,
        trackDuration: item.duration,
        declaredLength: lrcDeclaredLength(other.raw),
      );
      if (!lyricsConfidenceBeats(otherConfidence, confidence)) return;
      final offset = estimateConstantOffsetMs(
        reference: parsed.lines,
        candidate: lyrics.lines,
      );
      _log.i(
        'lyrics-sync: reference=${other.provider} '
        'conf=${otherConfidence.name} auto=${offset ?? 0}',
      );
      if (offset == null || offset == _autoOffsetMs) return;
      _autoOffsetMs = offset;
      notifyListeners();
    } catch (error) {
      _log.w('Could not measure lyrics timing: $error');
    }
  }

  /// Stores [offsetMs] as this track's own shift; null goes back to the
  /// automatic timing.
  Future<void> setTrackOffset(int? offsetMs) async {
    final key = _syncKey;
    if (_disposed || key == null) return;
    final value = offsetMs == null ? null : clampTrackLyricsOffsetMs(offsetMs);
    _trackOffsetMs = value;
    notifyListeners();
    await _syncStore.write(key, value);
  }

  String? get _correctionKey {
    final item = _lyricsRequestItem;
    final source = this.source;
    if (item == null || source == null) return null;
    final catalog = _catalogData(source);
    return lyricsCorrectionKey(
      isrc: lyricsIsrc(item),
      catalogSource: catalog?['source']?.toString(),
      catalogId: catalog?['id']?.toString(),
      artist: item.artist ?? '',
      title: item.title,
      durationMs: item.duration?.inMilliseconds ?? 0,
    );
  }

  bool get _hasServedLyrics =>
      _fetchedLyrics != null &&
      _servedRaw.isNotEmpty &&
      !_editableSource(source ?? '') &&
      LyricsDraft.canEdit(_servedRaw);

  /// Whether single lines of the shown lyrics can be corrected on this
  /// device: provider text of a track that has no file of its own to edit.
  bool get canCorrectLines => _hasServedLyrics && _lyrics.synced;

  /// Corrections saved for this track whose provider line has since changed
  /// and so are not applied.
  int get staleCorrections => _staleCorrections;

  /// Times, in ms, of the shown lines that carry a correction.
  Set<int> get correctedLineTimesMs {
    final served = _servedRaw;
    if (!_hasServedLyrics) return const {};
    return {
      for (final patch in _patches)
        if (servedLyricsLine(served, patch.timeMs) != null &&
            lyricsLineHash(servedLyricsLine(served, patch.timeMs)!) ==
                patch.originalHash)
          patch.timeMs,
    };
  }

  /// The slot of the provider line sung at [time], within a few ms.
  int? correctionSlot(Duration time) => _hasServedLyrics
      ? nearestLyricsSlot(_servedRaw, time.inMilliseconds)
      : null;

  /// What the provider served for the line at [slot], before any correction.
  String? originalLineText(int slot) =>
      _hasServedLyrics ? servedLyricsLine(_servedRaw, slot) : null;

  /// Corrects the line at [slot] on this device, over what the provider
  /// serves. Throws when there is nothing to correct or it can't be stored.
  Future<void> correctLyricsLine(int slot, String text) async {
    final original = originalLineText(slot);
    if (original == null) {
      throw UnsupportedError('This line has no provider text to correct');
    }
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final patches = await _storedPatches(slot);
    if (cleaned.isNotEmpty &&
        lyricsLineHash(cleaned) != lyricsLineHash(original)) {
      patches.add(
        LyricsLinePatch(
          timeMs: slot,
          originalHash: lyricsLineHash(original),
          text: cleaned,
        ),
      );
    }
    await _commitCorrections(patches);
  }

  /// Drops the correction of the line at [slot], showing the provider's text.
  Future<void> restoreLyricsLine(int slot) async =>
      _commitCorrections(await _storedPatches(slot));

  /// The stored corrections other than the one at [slot].
  Future<List<LyricsLinePatch>> _storedPatches(int slot) async {
    final key = _correctionKey;
    if (key == null) return [];
    return [
      for (final patch in await _corrections.read(key))
        if (patch.timeMs != slot) patch,
    ];
  }

  /// Applies the stored corrections to the provider text just shown. The
  /// lookup never waits for storage; a track with corrections swaps its
  /// lines as soon as they are read, unless the user changed the lyrics since.
  Future<void> _applyStoredCorrections(int generation, String served) async {
    final key = _correctionKey;
    if (key == null || served.isEmpty) return;
    final patches = await _corrections.read(key);
    if (_disposed ||
        patches.isEmpty ||
        generation != _onlineGeneration ||
        _hasEditedLyrics ||
        _servedRaw != served) {
      return;
    }
    final result = applyLyricsPatches(served, patches);
    _log.i(
      'Lyrics corrections: applied=${result.applied} '
      'obsolete=${result.obsolete}',
    );
    _patches = patches;
    _staleCorrections = result.obsolete;
    if (result.applied == 0) {
      notifyListeners();
      return;
    }
    final parsed = await _parseLyrics(result.raw);
    if (_disposed ||
        generation != _onlineGeneration ||
        _hasEditedLyrics ||
        _servedRaw != served) {
      return;
    }
    _lyrics = parsed;
    _lyricsRaw = result.raw;
    _fetchedLyrics = parsed;
    _fetchedRaw = result.raw;
    _metadata = Map.unmodifiable({...?_metadata, 'lyrics': result.raw});
    notifyListeners();
  }

  Future<void> _commitCorrections(List<LyricsLinePatch> patches) async {
    final key = _correctionKey;
    if (_disposed || key == null || !_hasServedLyrics) {
      throw StateError('No provider lyrics are loaded');
    }
    final generation = _onlineGeneration;
    await _corrections.write(key, patches);
    if (_disposed || generation != _onlineGeneration) return;
    final result = applyLyricsPatches(_servedRaw, patches);
    final parsed = await _parseLyrics(result.raw);
    if (_disposed || generation != _onlineGeneration) return;
    _patches = patches;
    _staleCorrections = result.obsolete;
    _adoptEditedLyrics(result.raw, parsed);
  }

  /// Stores the lines [edited] changed against the provider's text and
  /// returns the lyrics those corrections produce.
  Future<String> _storeCorrections(String edited) async {
    final key = _correctionKey;
    if (key == null || !_hasServedLyrics) {
      throw UnsupportedError(
        'The playing source is not an editable audio file',
      );
    }
    final patches = diffLyricsPatches(_servedRaw, edited);
    await _corrections.write(key, patches);
    _patches = patches;
    _staleCorrections = 0;
    return applyLyricsPatches(_servedRaw, patches).raw;
  }

  /// Embeds [raw] in the original audio file and shows it; a track without
  /// a file of its own keeps the lines it changed as local corrections.
  /// Throws when it can't be stored, leaving the current lyrics in place.
  Future<void> saveEditedLyrics(String raw) async {
    final source = this.source;
    if (_disposed || _item == null || source == null) {
      throw StateError('No editable track is loaded');
    }
    final generation = _onlineGeneration;
    final correction = !_editableSource(source);
    if (correction) {
      raw = await _storeCorrections(raw);
      if (_disposed || generation != _onlineGeneration) return;
    }
    final parsed = raw.trim().isEmpty
        ? ParsedLyrics.empty
        : await _parseLyrics(raw);
    if (!correction) {
      // A document plays from a copy, so reloading after the save would read
      // the old lyrics back; show what was written instead.
      _savingLyricsSources.add(source);
      var saved = false;
      try {
        await _saveOnline(source, raw);
        await _metadataEvents.publish(source);
        saved = true;
      } finally {
        _savingLyricsSources.remove(source);
        // A duration update deferred by this write remains eligible if the
        // edit fails. Successful edits invalidate this check below.
        if (!saved) _maybeSearchAutomatically();
      }
    }
    if (_disposed || generation != _onlineGeneration) return;
    _adoptEditedLyrics(raw, parsed);
  }

  void _adoptEditedLyrics(String raw, ParsedLyrics parsed) {
    // Invalidate a pending lookup only after the edit was successfully saved.
    _onlineGeneration++;
    _onlineAttemptRevision++;
    _metadataRevision++;
    _automaticAttempted = true;
    _automaticCheckPending = false;
    _searchingOnline = false;
    _onlineDeferredOffline = false;
    unawaited(_connectivitySubscription?.cancel());
    _connectivitySubscription = null;
    _fetchedLyrics = raw.trim().isEmpty ? null : parsed;
    _fetchedRaw = raw;
    _hasEditedLyrics = true;
    _onlineLyricsProvisional = false;
    _onlineInstrumental = false;
    _metadata = Map.unmodifiable({...?_metadata, 'lyrics': raw});
    _lyrics = parsed;
    _lyricsRaw = raw;
    _onlineSearchMissed = false;
    _onlineSearchFailed = false;
    _onlineLyricsSaveFailed = false;
    notifyListeners();
  }

  /// Reads deferred file tags when opening technical details. Already loaded
  /// metadata, including online lyrics, stays cached for the current item.
  Future<void> ensureFileMetadata() async {
    if (_disposed || _item == null || _loadedPath != null) return;
    await load(_item, inspectUnresolvedContentUri: true);
  }

  Future<void> load(
    MediaItem? item, {
    bool inspectUnresolvedContentUri = false,
  }) async {
    if (_disposed) return;
    final source = item?.extras?['source']?.toString() ?? '';
    final identity = item == null ? null : _lyricsIdentity(item, source);
    final sameLogicalItem = identity == _onlineIdentity;
    if (!sameLogicalItem) {
      _onlineIdentity = identity;
      _onlineGeneration++;
      _automaticAttempted = false;
      _durationRetryAttempted = false;
      _automaticCheckPending = false;
      _lastSearchedDurationMs = null;
      _fetchedLyrics = null;
      _fetchedRaw = '';
      _servedRaw = '';
      _patches = const [];
      _staleCorrections = 0;
      _searchedLyricsIdentity = null;
      _hasEditedLyrics = false;
      _onlineLyricsProvisional = false;
      _onlineInstrumental = false;
      unawaited(_connectivitySubscription?.cancel());
      _connectivitySubscription = null;
      _resetOnlineSearch();
    }
    if (item != null &&
        source.isEmpty &&
        item.extras?['displayMetadata'] is Map) {
      _generation++;
      _probePending = false;
      _item = null;
      _requestKey = (item.id, source, null);
      _loadedPath = null;
      _fallback = Map.unmodifiable(playbackAudioMetadataFromMediaItem(item));
      final pending = _replaceMetadata(_fallback);
      if (pending != null) await pending;
      return;
    }
    if (item == null || source.isEmpty) {
      _item = null;
      if (_requestKey == null) return;
      _generation++;
      _probePending = false;
      _requestKey = null;
      _loadedPath = null;
      final pending = _replaceMetadata(const {});
      if (pending != null) await pending;
      return;
    }
    final resolvedSource = item.extras?['resolvedSource']?.toString().trim();
    final key = (item.id, source, resolvedSource);
    final sameItem = key == _requestKey;
    final previousVerifiedCodec = _item?.extras?['verifiedAudioCodec'];
    final previousVerifiedRate = _item?.extras?['verifiedAudioSampleRate'];
    _item = item;
    final verifiedQualityChanged =
        previousVerifiedCodec != item.extras?['verifiedAudioCodec'] ||
        previousVerifiedRate != item.extras?['verifiedAudioSampleRate'];
    final newFallback = playbackAudioMetadataFromMediaItem(item);
    final fallbackChanged = !mapEquals(_fallback, newFallback);
    _fallback = Map.unmodifiable(newFallback);
    if (sameLogicalItem &&
        !_hasEditedLyrics &&
        (_fetchedLyrics != null || _onlineInstrumental || _lyrics.isEmpty)) {
      _reconcileSearchedIdentity();
    }
    if (!sameItem) {
      _generation++;
      _probePending = false;
      _requestKey = key;
      _loadedPath = null;
    }
    if (source.startsWith('catalog:') ||
        const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme)) {
      _loadedPath = source;
      if (!sameLogicalItem ||
          metadata == null ||
          fallbackChanged ||
          verifiedQualityChanged ||
          (_loading && !sameItem)) {
        final refreshed = <String, dynamic>{..._fallback};
        if (sameLogicalItem &&
            (_hasEditedLyrics ||
                (!_lyrics.isEmpty &&
                    (_fetchedLyrics != null ||
                        !refreshed.containsKey('lyrics') ||
                        refreshed['lyrics'] == _lyricsRaw)))) {
          refreshed['lyrics'] = _lyricsRaw;
          _metadataRevision++;
          _metadata = Map.unmodifiable(refreshed);
          _loading = false;
          notifyListeners();
        } else {
          final pending = _replaceMetadata(refreshed);
          if (pending != null) await pending;
        }
      }
      _maybeSearchAutomatically();
      return;
    }
    final path = _metadataPath(source, resolvedSource);
    final unresolved = path == source && source.startsWith('content://');
    if (sameItem) {
      if (metadata == null && _fallback.isNotEmpty) {
        _metadata = _fallback;
        notifyListeners();
      }
      if (loading || _loadedPath == path) {
        _maybeSearchAutomatically();
        return;
      }
    } else if (!sameLogicalItem || metadata == null) {
      final pending = _replaceMetadata(_fallback);
      // A fallback parse must never postpone the file probe. Its revision
      // guard discards it as soon as richer metadata supersedes it.
      if (pending != null) unawaited(pending);
    }
    // Opening the player must not copy an unresolved SAF document. Lyrics
    // requests may inspect it until playback publishes its resolved source.
    if (unresolved && !inspectUnresolvedContentUri) return;
    _probePending = true;
    _loading = true;
    notifyListeners();
    final generation = _generation;
    try {
      final probed = await _readMetadata(path);
      if (_disposed || generation != _generation) return;
      _probePending = false;
      _loadedPath = path;
      final pending = _replaceMetadata(
        mergePlaybackFileMetadata(_fallback, probed),
      );
      if (pending != null) await pending;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _probePending = false;
      _log.w('Failed to read metadata: $error');
      final pending = _replaceMetadata(_fallback);
      if (pending != null) await pending;
    }
    _maybeSearchAutomatically();
  }

  bool _editableSource(String source) {
    final scheme = Uri.tryParse(source)?.scheme ?? '';
    return source.isNotEmpty &&
        !source.startsWith('catalog:') &&
        !const {'http', 'https'}.contains(scheme);
  }

  void _maybeSearchAutomatically() {
    final durationRetry =
        _automaticAttempted &&
        !_durationRetryAttempted &&
        (_lastSearchedDurationMs != null && _lastSearchedDurationMs! <= 0) &&
        (_lyricsRequestItem?.duration?.inMilliseconds ?? 0) > 0 &&
        (_onlineSearchMissed ||
            _onlineSearchFailed ||
            _onlineLyricsProvisional);
    if (!automaticOnlineSearch ||
        _disposed ||
        (_automaticAttempted && !durationRetry) ||
        _automaticCheckPending ||
        _onlineDeferredOffline ||
        _savingLyricsSources.contains(source) ||
        (_onlineInstrumental && !durationRetry) ||
        _loading ||
        _searchingOnline ||
        (!_lyrics.isEmpty && !(_onlineLyricsProvisional && durationRetry)) ||
        !canSearchOnline) {
      return;
    }
    // Claim before awaiting availability so repeated media events cannot race.
    _automaticAttempted = true;
    _automaticCheckPending = true;
    if (_onlineLyricsProvisional && durationRetry) {
      // Once the recording length is known, unverified text must not remain
      // visible if the provider later rejects it or cannot be reached.
      _onlineLyricsProvisional = false;
      _onlineInstrumental = false;
      _fetchedLyrics = null;
      _fetchedRaw = '';
      _lyrics = ParsedLyrics.empty;
      _lyricsRaw = '';
      _onlineSearchMissed = true;
      _metadata = Map.unmodifiable({...?_metadata}..remove('lyrics'));
      notifyListeners();
    }
    final generation = _onlineGeneration;
    final attemptRevision = _onlineAttemptRevision;
    unawaited(() async {
      var available = true;
      try {
        available = await _onlineAvailable();
      } catch (_) {
        // A failing transport probe does not prove the provider is offline.
      }
      if (_disposed ||
          generation != _onlineGeneration ||
          attemptRevision != _onlineAttemptRevision) {
        return;
      }
      _automaticCheckPending = false;
      if (!_lyrics.isEmpty) {
        notifyListeners();
        return;
      }
      if (!available) {
        _onlineDeferredOffline = true;
        notifyListeners();
        final changes =
            _onlineChanges ??
            ConnectivityMonitor.instance.changes.map(
              (values) => !values.contains(ConnectivityResult.none),
            );
        _connectivitySubscription ??= changes.listen((available) {
          if (!available ||
              _disposed ||
              generation != _onlineGeneration ||
              attemptRevision != _onlineAttemptRevision) {
            return;
          }
          unawaited(_connectivitySubscription?.cancel());
          _connectivitySubscription = null;
          if (!_lyrics.isEmpty || _searchingOnline) return;
          if (_savingLyricsSources.contains(source)) {
            // The write decides whether this pending lookup is still needed.
            _onlineDeferredOffline = false;
            _automaticAttempted = false;
            return;
          }
          if (!canSearchOnline) {
            // The connection returned before enough identity was available.
            // Let a later metadata update start a fresh availability check.
            _onlineDeferredOffline = false;
            _automaticAttempted = false;
            notifyListeners();
            return;
          }
          unawaited(_searchOnline(persist: false));
        });
        return;
      }
      if (_lyrics.isEmpty && !_searchingOnline) {
        await _searchOnline(persist: false);
      }
    }());
  }

  Future<void>? _replaceMetadata(Map<String, dynamic> value) {
    final revision = ++_metadataRevision;
    final raw = (value['lyrics'] ?? '').toString();
    // Empty fallback metadata stays synchronous, so file probes start at the
    // same point and changing tracks clears the previous lyrics immediately.
    if (raw.isEmpty) {
      _publishMetadata(value, ParsedLyrics.empty);
      return null;
    }
    _metadata = value.isEmpty ? null : Map.unmodifiable(value);
    if (raw != _lyricsRaw) _lyrics = ParsedLyrics.empty;
    _loading = true;
    notifyListeners();
    return _parseAndReplaceMetadata(value, raw, _generation, revision);
  }

  Future<void> _parseAndReplaceMetadata(
    Map<String, dynamic> value,
    String raw,
    int generation,
    int revision,
  ) async {
    try {
      final parsed = await _parseLyrics(raw);
      if (_disposed ||
          generation != _generation ||
          revision != _metadataRevision) {
        return;
      }
      _publishMetadata(value, parsed, raw: raw);
    } catch (error) {
      if (_disposed ||
          generation != _generation ||
          revision != _metadataRevision) {
        return;
      }
      _log.w('Failed to parse lyrics: $error');
      _publishMetadata(value, ParsedLyrics.empty);
    }
  }

  void _publishMetadata(
    Map<String, dynamic> value,
    ParsedLyrics parsed, {
    String raw = '',
  }) {
    _metadata = value.isEmpty ? null : Map.unmodifiable(value);
    if (parsed.isEmpty && !_hasEditedLyrics) {
      _reconcileSearchedIdentity();
    }
    if (!parsed.isEmpty) {
      // Embedded lyrics are authoritative and never duration-revalidated.
      _fetchedLyrics = null;
      _fetchedRaw = '';
      _onlineLyricsProvisional = false;
      _onlineInstrumental = false;
    }
    _lyrics = parsed.isEmpty ? (_fetchedLyrics ?? parsed) : parsed;
    _lyricsRaw = parsed.isEmpty && _fetchedLyrics != null ? _fetchedRaw : raw;
    _loading = _probePending;
    notifyListeners();
  }

  void _reconcileSearchedIdentity() {
    final previousIdentity = _searchedLyricsIdentity;
    final item = _lyricsRequestItem;
    final title = item?.title.trim().toLowerCase() ?? '';
    final artist = item?.artist?.trim().toLowerCase() ?? '';
    if (previousIdentity != null &&
        ((_usableLyricsField(title) && previousIdentity.$1 != title) ||
            (_usableLyricsField(artist) && previousIdentity.$2 != artist))) {
      // A completed lookup belongs to its searched tags, not the file path.
      // Retire it before publishing the new metadata or allowing a retry.
      _onlineGeneration++;
      _onlineAttemptRevision++;
      _searchedLyricsIdentity = null;
      _automaticAttempted = false;
      _durationRetryAttempted = false;
      _automaticCheckPending = false;
      _lastSearchedDurationMs = null;
      _fetchedLyrics = null;
      _fetchedRaw = '';
      _lyrics = ParsedLyrics.empty;
      _lyricsRaw = '';
      _metadata = Map.unmodifiable({...?_metadata}..remove('lyrics'));
      _onlineLyricsProvisional = false;
      _onlineInstrumental = false;
      unawaited(_connectivitySubscription?.cancel());
      _connectivitySubscription = null;
      _resetOnlineSearch();
      notifyListeners();
    }
  }

  void _resetOnlineSearch() {
    _searchingOnline = false;
    _onlineSearchMissed = false;
    _onlineSearchFailed = false;
    _onlineDeferredOffline = false;
    _onlineLyricsSaveFailed = false;
  }

  String _metadataPath(String source, String? resolved) =>
      resolved?.isNotEmpty == true &&
          (!source.startsWith('network://') ||
              !const {
                'http',
                'https',
                'network',
              }.contains(Uri.tryParse(resolved!)?.scheme))
      ? resolved!
      : source;

  Map<String, dynamic> detailsSnapshot(MediaItem? item) {
    if (item == null) return const {};
    final source = item.extras?['source']?.toString() ?? '';
    final resolved = item.extras?['resolvedSource']?.toString().trim();
    final sameItem = _requestKey == (item.id, source, resolved);
    return {
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      ...playbackAudioMetadataFromMediaItem(item),
      if (sameItem) ...?metadata,
    };
  }

  /// A details sheet owns this snapshot, independently of later track changes.
  /// Probing an unresolved document here does not alter the lyrics lifecycle.
  Future<Map<String, dynamic>> readDetails(MediaItem? item) async {
    final fallback = detailsSnapshot(item);
    final source = item?.extras?['source']?.toString() ?? '';
    final resolved = item?.extras?['resolvedSource']?.toString().trim();
    final path = _metadataPath(source, resolved);
    if (_disposed ||
        path.isEmpty ||
        source.startsWith('catalog:') ||
        const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme) ||
        (_requestKey == (item?.id, source, resolved) && _loadedPath == path)) {
      return fallback;
    }
    try {
      return mergePlaybackFileMetadata(fallback, await _readMetadata(path));
    } catch (error) {
      _log.w('Failed to read details metadata: $error');
      return fallback;
    }
  }

  ({String? writers, String? provider}) get credits {
    String? field(String key) {
      final value = metadata?[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    return (
      writers: lyrics.writers ?? field('lyricist') ?? field('composer'),
      provider: lyrics.provider ?? field('lyrics_provider'),
    );
  }

  /// What the active decoder probe verified for a catalog song, shaped like
  /// file metadata so facts read the same as for a local file.
  Map<String, dynamic> get verifiedAudioMetadata {
    final extras = _item?.extras;
    if (source?.startsWith('catalog:') != true || extras == null) {
      return const {};
    }
    final codec = extras['verifiedAudioCodec'];
    final rate = extras['verifiedAudioSampleRate'];
    return {
      if (codec is String && RegExp(r'^[a-zA-Z0-9_]{1,32}$').hasMatch(codec))
        'audio_codec': codec,
      if (rate is int && rate > 0 && rate <= 768000) 'sample_rate': rate,
    };
  }

  String? get qualityLabel {
    if (source?.startsWith('catalog:') == true) {
      // Provider metadata describes the catalog entry, not necessarily the
      // bytes that were played. Only the active decoder probe is authoritative.
      final extras = _item?.extras;
      final rawCodec = extras?['verifiedAudioCodec'];
      final codec = rawCodec is String ? rawCodec.trim() : '';
      final rate = extras?['verifiedAudioSampleRate'];
      final parts = <String>[];
      if (RegExp(r'^[a-zA-Z0-9_]{1,32}$').hasMatch(codec)) {
        parts.add(codec.toUpperCase());
      }
      if (rate is int && rate > 0 && rate <= 768000) {
        final khz = rate / 1000;
        parts.add(
          '${khz.toStringAsFixed(khz == khz.roundToDouble() ? 0 : 1)} kHz',
        );
      }
      return parts.isEmpty ? null : parts.join('  ·  ');
    }
    final meta = metadata;
    if (meta == null) return null;
    final parts = <String>[];
    final format = (meta['format'] ?? meta['audio_codec'] ?? '')
        .toString()
        .trim()
        .toUpperCase();
    if (format.isNotEmpty) parts.add(format);
    final bitDepth = readPositiveInt(meta['bit_depth']) ?? 0;
    if (bitDepth > 0) parts.add('$bitDepth-bit');
    final sampleRate = readPositiveInt(meta['sample_rate']) ?? 0;
    if (sampleRate > 0) {
      final khz = sampleRate / 1000;
      parts.add(
        '${khz.toStringAsFixed(khz == khz.roundToDouble() ? 0 : 1)} kHz',
      );
    }
    final bitrate = readPositiveInt(meta['bitrate']) ?? 0;
    if (bitDepth == 0 && bitrate > 0) parts.add('$bitrate kbps');
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  @override
  void dispose() {
    _disposed = true;
    _unsubscribeMetadata();
    unawaited(_connectivitySubscription?.cancel());
    _onlineGeneration++;
    _generation++;
    super.dispose();
  }
}
