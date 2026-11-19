import 'dart:convert';

import '../../models/track.dart';

/// A bounded, portable identity. Never contains playback URLs or file paths.
class JamTrackReference {
  JamTrackReference._(
    this.provider,
    this.externalId,
    this.isrc,
    this.title,
    this.artist,
  );

  final String? provider;
  final String? externalId;
  final String? isrc;
  final String title;
  final String artist;
  static const prefix = 'jamref1:';

  static JamTrackReference? create({
    String? provider,
    String? externalId,
    String? isrc,
    required String title,
    required String artist,
  }) {
    final p = provider?.trim().toLowerCase();
    final id = externalId?.trim();
    final code = isrc?.trim().toUpperCase();
    final t = title.trim();
    final a = artist.trim();
    final validId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
    final validProvider = RegExp(r'^(spotify|deezer|tidal|qobuz|youtube)$');
    if ((p == null) != (id == null) ||
        (p != null && (!validProvider.hasMatch(p) || !validId.hasMatch(id!))))
      return null;
    if (p != null &&
        !(switch (p) {
          'spotify' => RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(id!),
          'youtube' => RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id!),
          'deezer' ||
          'tidal' ||
          'qobuz' => RegExp(r'^[0-9]{1,20}$').hasMatch(id!),
          _ => false,
        }))
      return null;
    if (code != null &&
        !RegExp(r'^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$').hasMatch(code))
      return null;
    if (p == null && code == null) return null;
    bool safeText(String s) =>
        s.isNotEmpty &&
        s.length <= 100 &&
        !RegExp(r'[\x00-\x1f\\]').hasMatch(s) &&
        !s.contains('://') &&
        !RegExp(
          r'(^/|(^|\s)\.{1,2}/|^[A-Za-z]:|/[^/]+/|/[^/]+\.(mp3|flac|wav|m4a|ogg|aac)$)',
          caseSensitive: false,
        ).hasMatch(s);
    if (!safeText(t) || !safeText(a)) return null;
    final ref = JamTrackReference._(p, id, code, t, a);
    if (ref.encode().length > 256) return null;
    return ref;
  }

  static JamTrackReference? fromTrack(Track track) {
    final code = track.isrc == null || track.isrc!.trim().isEmpty
        ? null
        : track.isrc;
    return create(
          provider: track.source,
          externalId: track.id,
          isrc: code,
          title: track.name,
          artist: track.artistName,
        ) ??
        create(isrc: code, title: track.name, artist: track.artistName);
  }

  String encode() =>
      '$prefix${base64Url.encode(utf8.encode(jsonEncode({if (provider != null) 'p': provider, if (externalId != null) 'i': externalId, if (isrc != null) 's': isrc, 't': title, 'a': artist}))).replaceAll('=', '')}';

  static JamTrackReference? tryDecode(String encoded) {
    if (!encoded.startsWith(prefix) || encoded.length > 256) return null;
    try {
      final raw = encoded.substring(prefix.length);
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw)) return null;
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw))),
      );
      if (value is! Map<String, dynamic> ||
          value.keys.any((k) => !const {'p', 'i', 's', 't', 'a'}.contains(k)))
        return null;
      if (value['t'] is! String ||
          value['a'] is! String ||
          (value['p'] != null && value['p'] is! String) ||
          (value['i'] != null && value['i'] is! String) ||
          (value['s'] != null && value['s'] is! String))
        return null;
      return create(
        provider: value['p'] as String?,
        externalId: value['i'] as String?,
        isrc: value['s'] as String?,
        title: value['t'] as String,
        artist: value['a'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}
