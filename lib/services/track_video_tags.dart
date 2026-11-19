import 'dart:async';
import 'dart:convert';

import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/track_video_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The positive tag of a song: a video exists, its id, and when it was found.
/// Songs without a video are never tagged.
class TrackVideoTag {
  const TrackVideoTag({
    required this.hasVideo,
    required this.checkedAt,
    this.videoId,
    this.provider,
  });

  final bool hasVideo;
  final String? videoId;
  final String? provider;
  final DateTime checkedAt;

  Map<String, dynamic> toJson() => {
    'hasVideo': hasVideo,
    if (videoId != null) 'videoId': videoId,
    if (provider != null) 'provider': provider,
    'checkedAt': checkedAt.toIso8601String(),
  };

  static TrackVideoTag? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final has = raw['hasVideo'];
    final at = DateTime.tryParse('${raw['checkedAt']}');
    if (has != true || at == null) return null;
    final id = raw['videoId'];
    final provider = raw['provider'];
    return TrackVideoTag(
      hasVideo: true,
      checkedAt: at,
      videoId: id is String && id.isNotEmpty ? id : null,
      provider: provider is String && provider.isNotEmpty ? provider : null,
    );
  }
}

/// Tags of downloaded songs and of temporary streaming songs still kept. A
/// tag leaves with its song: see [prune].
class TrackVideoTags {
  TrackVideoTags({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const _prefsKey = 'track_video_tags_v1';
  final DateTime Function() _now;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<Map<String, dynamic>> _load(SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Future<TrackVideoTag?> read(Track track) => _serial(() async {
    final map = await _load(await SharedPreferences.getInstance());
    return TrackVideoTag.fromJson(map[trackCollectionKey(track)]);
  });

  Future<TrackVideoTag> write(Track track, {required TrackVideoOffer offer}) =>
      _serial(() async {
        final prefs = await SharedPreferences.getInstance();
        final map = await _load(prefs);
        final tag = TrackVideoTag(
          hasVideo: true,
          videoId: offer.videoId,
          provider: offer.provider,
          checkedAt: _now(),
        );
        map[trackCollectionKey(track)] = tag.toJson();
        await prefs.setString(_prefsKey, jsonEncode(map));
        return tag;
      });

  Future<void> forget(Track track) => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _load(prefs);
    if (map.remove(trackCollectionKey(track)) != null) {
      await prefs.setString(_prefsKey, jsonEncode(map));
    }
  });

  /// Drops the tags whose song is gone: [alive] answers for each stored key.
  Future<int> prune(Future<bool> Function(String key) alive) =>
      _serial(() async {
        final prefs = await SharedPreferences.getInstance();
        final map = await _load(prefs);
        var removed = 0;
        for (final key in map.keys.toList()) {
          if (!await alive(key)) {
            map.remove(key);
            removed++;
          }
        }
        if (removed > 0) await prefs.setString(_prefsKey, jsonEncode(map));
        return removed;
      });
}

final trackVideoTags = TrackVideoTags();

/// Looks for a song's video in the background each time it plays, never
/// twice at the same time for one song. A song with a tag is not searched. A
/// search that finds nothing tags nothing, so a video published later is
/// found on a later play.
class TrackVideoLookup {
  TrackVideoLookup({TrackVideoTags? tags, TrackVideoSource? Function()? source})
    : _tags = tags ?? trackVideoTags,
      _source = source ?? (() => trackVideoSource);

  final TrackVideoTags _tags;
  final TrackVideoSource? Function() _source;
  final Map<String, _Search> _searching = {};

  /// The tag of [track], searching when it has none. Null when it has no
  /// video, there is no provider to ask, or the search failed or was cancelled.
  Future<TrackVideoTag?> tagFor(Track track) async {
    final existing = await _tags.read(track);
    if (existing != null) return existing;
    final source = _source();
    if (source == null) return null;
    final key = trackCollectionKey(track);
    final running = _searching[key];
    if (running != null) return running.future;
    final search = _Search();
    _searching[key] = search;
    search.future = () async {
      try {
        final offer = await source.offerFor(track);
        if (search.cancelled || offer == null) return null;
        return await _tags.write(track, offer: offer);
      } catch (_) {
        return null;
      } finally {
        if (identical(_searching[key], search)) _searching.remove(key);
      }
    }();
    return search.future;
  }

  /// Discards the result of the search for [track], if one is running.
  void cancel(Track track) {
    final search = _searching.remove(trackCollectionKey(track));
    search?.cancelled = true;
  }
}

class _Search {
  bool cancelled = false;
  late final Future<TrackVideoTag?> future;
}
