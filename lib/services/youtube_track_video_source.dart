import 'dart:async';
import 'dart:io';

import 'package:mornye/models/track.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/services/track_video_source.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const youtubeVideoProviderId = 'ytmusic-spotiflac';
const videosSearchFilter = 'videos';

typedef VideoSearch =
    Future<List<Map<String, dynamic>>> Function(String query, {String? filter});
typedef VideoFetch = Future<String?> Function(Track track, String videoId);
typedef VideoProbe = Future<bool> Function(String path);

final _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

String _plain(String value) {
  var text = value.toLowerCase();
  text = text.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ');
  text = text.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
  return text.trim().replaceAll(RegExp(r'\s+'), ' ');
}

String? _videoIdOf(Map<String, dynamic> item) {
  for (final key in const ['video_id', 'videoId', 'id']) {
    var raw = item[key]?.toString().trim() ?? '';
    final colon = raw.indexOf(':');
    if (colon > 0) raw = raw.substring(colon + 1);
    if (_videoIdPattern.hasMatch(raw)) return raw;
  }
  return null;
}

bool _isMotionVideo(Map<String, dynamic> item) {
  if (item['is_video'] == true) return true;
  final type = (item['item_type'] ?? item['type'])?.toString().toLowerCase();
  if (type == 'video') return true;
  final kind =
      (item['music_video_type'] ?? item['musicVideoType'] ?? item['video_type'])
          ?.toString()
          .toUpperCase();
  if (kind == null || kind.isEmpty) return false;
  return kind.contains('OMV') ||
      kind.contains('UGC') ||
      kind.contains('OFFICIAL_SOURCE_MUSIC') ||
      kind == 'MUSIC_VIDEO' ||
      kind == 'LIVE';
}

bool _isAudioOnlyEntry(Map<String, dynamic> item) {
  if (item['is_video'] == false) return true;
  final type = (item['item_type'] ?? item['type'])?.toString().toLowerCase();
  if (type == 'album' || type == 'artist' || type == 'playlist') return true;
  final kind =
      (item['music_video_type'] ?? item['musicVideoType'] ?? item['video_type'])
          ?.toString()
          .toUpperCase();
  return kind != null && kind.contains('ATV');
}

Duration? _durationOf(Map<String, dynamic> item) {
  final ms = num.tryParse('${item['duration_ms'] ?? ''}');
  if (ms != null && ms > 0) return Duration(milliseconds: ms.round());
  final seconds = num.tryParse('${item['duration'] ?? ''}');
  if (seconds != null && seconds > 0) {
    return Duration(milliseconds: (seconds * 1000).round());
  }
  return null;
}

class YoutubeTrackVideoSource implements TrackVideoSource {
  YoutubeTrackVideoSource({
    required this.isAvailable,
    required this.networkAllowed,
    required this.search,
    required this.fetch,
    required this.probe,
    this.durationTolerance = const Duration(seconds: 3),
  });

  final bool Function() isAvailable;
  final Future<bool> Function() networkAllowed;
  final VideoSearch search;
  final VideoFetch fetch;
  final VideoProbe probe;
  final Duration durationTolerance;

  @override
  Future<TrackVideoOffer?> offerFor(Track track) async {
    if (!isAvailable() || track.name.trim().isEmpty) return null;
    if (!await networkAllowed()) return null;
    final query = '${track.name} ${track.artistName}'.trim();
    for (final filter in const <String?>[videosSearchFilter, null]) {
      List<Map<String, dynamic>> results;
      try {
        results = await search(query, filter: filter);
      } catch (_) {
        continue;
      }
      for (final item in results) {
        final id = _videoIdOf(item);
        final isVideo =
            _isMotionVideo(item) ||
            (filter == videosSearchFilter && !_isAudioOnlyEntry(item));
        if (id != null && isVideo && _matches(track, item)) {
          return TrackVideoOffer(provider: youtubeVideoProviderId, videoId: id);
        }
      }
    }
    return null;
  }

  bool _matches(Track track, Map<String, dynamic> item) {
    final title = _plain('${item['name'] ?? item['title'] ?? ''}');
    final wanted = _plain(track.name);
    if (title.isEmpty || wanted.isEmpty) return false;
    if (!title.contains(wanted) && !wanted.contains(title)) return false;
    final artists = _plain('${item['artists'] ?? item['artist'] ?? ''}');
    final artist = _plain(track.artistName.split(RegExp(r'[,&;]')).first);
    if (artist.isEmpty || !artists.contains(artist)) return false;
    final found = _durationOf(item);
    if (found != null && track.duration > 0) {
      final delta = (found - Duration(seconds: track.duration)).abs();
      if (delta > durationTolerance) return false;
    }
    return true;
  }

  @override
  Future<String?> prepare(Track track, TrackVideoOffer offer) async {
    if (!isAvailable() || !_videoIdPattern.hasMatch(offer.videoId)) {
      return null;
    }
    if (!await networkAllowed()) throw const TrackVideoNeedsNetwork();
    final path = await fetch(track, offer.videoId);
    if (path == null || !await probe(path)) return null;
    return path;
  }
}

Future<List<Map<String, dynamic>>> _platformSearch(
  String query, {
  String? filter,
}) => PlatformBridge.customSearchWithExtension(
  youtubeVideoProviderId,
  query,
  options: filter == null ? null : {'filter': filter},
);

Future<bool> _platformProbe(String path) async {
  try {
    final info = await FFmpegExecution.mediaInformation(path);
    if (info == null) return false;
    for (final stream in info.getStreams()) {
      final props = stream.getAllProperties() ?? const <String, dynamic>{};
      if (props['codec_type']?.toString() != 'video') continue;
      final codec = props['codec_name']?.toString().toLowerCase() ?? '';
      if (const {'mjpeg', 'png', 'bmp', 'gif', 'webp'}.contains(codec)) {
        continue;
      }
      final disposition = props['disposition'];
      if (disposition is Map && '${disposition['attached_pic']}' == '1') {
        continue;
      }
      final frames = int.tryParse('${props['nb_frames'] ?? ''}') ?? 0;
      final rate = '${props['avg_frame_rate'] ?? ''}'.split('/');
      final numerator = double.tryParse(rate.first) ?? 0;
      final denominator = rate.length > 1 ? double.tryParse(rate[1]) ?? 1 : 1;
      final fps = denominator == 0 ? 0 : numerator / denominator;
      if (frames > 1 || fps > 1) return true;
    }
  } catch (_) {
    return false;
  }
  return false;
}

Future<String?> _platformFetch(Track track, String videoId) async {
  final root = Directory(
    p.join((await getTemporaryDirectory()).path, 'musa_video'),
  );
  final target = File(p.join(root.path, '$videoId.mp4'));
  if (await target.exists() && await target.length() > 0) {
    return target.path;
  }
  await root.create(recursive: true);
  final preparer = TemporaryTrackPreparer.platform(
    stagingRoot: Directory(p.join(root.path, 'staging')),
    payload: (directory, transferId) => DownloadRequestPayload(
      trackName: track.name,
      artistName: track.artistName,
      albumName: track.albumName,
      outputDir: directory.path,
      filenameFormat: '{title}',
      itemId: transferId,
      service: youtubeVideoProviderId,
      downloadProvider: youtubeVideoProviderId,
      providerTrackId: videoId,
      source: youtubeVideoProviderId,
      durationMs: track.duration * 1000,
      quality: 'best',
      useExtensions: true,
      useFallback: false,
      allowQualityFallback: true,
      embedLyrics: false,
      embedMetadata: false,
    ),
  );
  await preparer.recoverAbandoned();
  final prepared = await preparer.prepare('video:$videoId');
  try {
    final partial = File('${target.path}.part');
    await prepared.file.copy(partial.path);
    await partial.rename(target.path);
    return target.path;
  } finally {
    await prepared.dispose();
  }
}

YoutubeTrackVideoSource createYoutubeTrackVideoSource({
  required bool Function() isAvailable,
  required Future<bool> Function() networkAllowed,
  VideoSearch? search,
  VideoFetch? fetch,
  VideoProbe? probe,
}) => YoutubeTrackVideoSource(
  isAvailable: isAvailable,
  networkAllowed: networkAllowed,
  search: search ?? _platformSearch,
  fetch: fetch ?? _platformFetch,
  probe: probe ?? _platformProbe,
);
