import 'dart:async';

import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/isrc_utils.dart';

typedef IsrcBackendLookup = Future<Map<String, dynamic>> Function(String isrc);

const isrcLookupTimeout = Duration(seconds: 6);

/// Resolves a single track from an ISRC typed in the search box. Returns null
/// when the query is not an ISRC, nothing matches, or the lookup fails or
/// times out, so the caller can fall back to the regular text search.
Future<Track?> lookupTrackByIsrc(
  String query, {
  IsrcBackendLookup? lookup,
  Duration timeout = isrcLookupTimeout,
}) async {
  final isrc = isrcFromSearchQuery(query);
  if (isrc == null) return null;
  try {
    final result = await (lookup ?? PlatformBridge.searchDeezerByISRC)(
      isrc,
    ).timeout(timeout);
    if (result['success'] != true) return null;
    final track = Track.fromBackendMap(result);
    if (track.id.isEmpty || track.name.trim().isEmpty) return null;
    return normalizeIsrc(track.isrc) == isrc
        ? track
        : track.copyWith(isrc: isrc);
  } catch (_) {
    return null;
  }
}
