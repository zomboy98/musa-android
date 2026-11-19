import 'package:flutter/material.dart';
import 'package:mornye/widgets/player_artwork.dart';

/// First [limit] distinct, nonempty artwork sources in playlist order.
List<String> playlistCollageSources(
  Iterable<String?> sources, {
  int limit = 4,
}) {
  final unique = <String>{};
  for (final source in sources) {
    final value = source?.trim();
    if (value != null && value.isNotEmpty) unique.add(value);
    if (unique.length == limit) break;
  }
  return unique.toList(growable: false);
}

class PlaylistCoverCollage extends StatelessWidget {
  const PlaylistCoverCollage({super.key, required this.sources})
    : assert(sources.length > 0 && sources.length <= 4);

  final List<String> sources;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget artwork(String source) =>
        PlayerArtwork(artUri: source, colorScheme: scheme, iconSize: 24);
    if (sources.length == 1) return artwork(sources.first);
    return Column(
      children: [
        for (var row = 0; row < 2; row++)
          Expanded(
            child: Row(
              children: [
                for (var col = 0; col < 2; col++)
                  Expanded(
                    child: artwork(sources[(row * 2 + col) % sources.length]),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
