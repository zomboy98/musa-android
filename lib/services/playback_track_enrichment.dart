import 'dart:async';

import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/isrc_utils.dart';

final _isrcShape = RegExp(r'^[A-Z]{2}[A-Z0-9]{3}\d{7}$');

bool playbackTrackNeedsEnrichment(Track track) {
  final source = (track.source ?? '').trim();
  if (source.isEmpty || track.id.trim().isEmpty) return false;
  return !_isrcShape.hasMatch(normalizeIsrc(track.isrc)) || track.duration <= 0;
}

/// Fills a missing ISRC or duration from the provider that listed the track.
/// Never replaces existing values and returns [track] unchanged on any failure.
Future<Track> enrichTrackForPlayback(
  Track track, {
  Future<Map<String, dynamic>> Function(String, String, String)? loadMetadata,
  Duration timeout = const Duration(seconds: 4),
}) async {
  if (!playbackTrackNeedsEnrichment(track)) return track;
  final providerId = track.source!.trim().toLowerCase();
  final rawId = track.id.trim();
  final nativeId = rawId.toLowerCase().startsWith('$providerId:')
      ? rawId.substring(providerId.length + 1)
      : rawId;
  if (nativeId.isEmpty) return track;
  try {
    final response = await (loadMetadata ?? PlatformBridge.getProviderMetadata)(
      providerId,
      'track',
      nativeId,
    ).timeout(timeout);
    final nested = response['track'];
    final data = nested is Map<String, dynamic> ? nested : response;
    final current = normalizeIsrc(track.isrc);
    final found = normalizeIsrc(data['isrc']?.toString());
    final hasIsrc = _isrcShape.hasMatch(current);
    final foundValid = _isrcShape.hasMatch(found);
    final newIsrc = !hasIsrc && foundValid ? found : null;
    final foundMs = extractDurationMs(data);
    final newDuration = track.duration <= 0 && foundMs > 0
        ? (foundMs / 1000).round()
        : null;
    if (newIsrc == null && newDuration == null) return track;
    return track.copyWith(isrc: newIsrc, duration: newDuration);
  } catch (_) {
    return track;
  }
}
