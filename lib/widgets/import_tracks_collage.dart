import 'package:flutter/material.dart';
import 'package:mornye/models/track.dart';

List<String> importCoverUrls(Iterable<Track> tracks, {int limit = 9}) {
  final urls = <String>[];
  for (final track in tracks) {
    final url = track.coverUrl?.trim() ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      continue;
    }
    if (urls.contains(url)) continue;
    urls.add(url);
    if (urls.length >= limit) break;
  }
  return urls;
}

String importDisplayName(String name, String fallback) {
  final readable = RegExp(r'[\p{L}\p{N}]', unicode: true);
  return readable.hasMatch(name) ? name : fallback;
}

class ImportCoverImage extends StatelessWidget {
  const ImportCoverImage({
    super.key,
    required this.url,
    this.borderRadius = 8,
    this.cacheWidth,
  });

  final String url;
  final double borderRadius;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: colors.onSurfaceVariant),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.network(
        url,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }
}
