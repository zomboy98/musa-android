import 'dart:io';
import 'package:flutter/material.dart';

/// Uses verified service artwork only for exact built-in identifiers.
class ProviderIcon extends StatelessWidget {
  const ProviderIcon({
    super.key,
    required this.provider,
    this.filePath,
    this.size = 24,
  });
  final String provider;
  final String? filePath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = switch (provider) {
      'Spotify' || 'spotify-web' => 'assets/images/provider-spotify.png',
      'Apple Music' ||
      'apple-music' => 'assets/images/provider-apple-music.png',
      'YouTube Music' ||
      'ytmusic-spotiflac' => 'assets/images/provider-youtube-music.png',
      'deezer' => 'assets/images/provider-deezer.png',
      'tidal-web' => 'assets/images/provider-tidal.png',
      'qobuz-web' => 'assets/images/provider-qobuz.png',
      'soundcloud' => 'assets/images/provider-soundcloud.png',
      'amazon' => 'assets/images/provider-amazon.png',
      'beatport' => 'assets/images/provider-beatport.png',
      'bugs-music' => 'assets/images/provider-bugs.png',
      'genie-music' => 'assets/images/provider-genie.png',
      'jiosaavn' => 'assets/images/provider-jiosaavn.png',
      'melon-music' => 'assets/images/provider-melon.png',
      _ => null,
    };
    Widget fallback() => Icon(Icons.extension_outlined, size: size);
    final Widget artwork;
    if (asset != null) {
      artwork = Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => fallback(),
      );
    } else if (filePath != null && filePath!.isNotEmpty) {
      artwork = Image.file(
        File(filePath!),
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => fallback(),
      );
    } else {
      artwork = fallback();
    }
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: provider == 'tidal-web'
            ? ColoredBox(color: Colors.white, child: artwork)
            : artwork,
      ),
    );
  }
}
