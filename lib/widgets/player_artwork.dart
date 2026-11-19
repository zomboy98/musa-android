import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager;
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/cover_image_frame.dart';

class PlayerArtwork extends StatelessWidget {
  /// Shared decode for the mini player and the full player's blurred cover.
  static const miniCacheWidth = 132;

  /// An HTTP(S) URL, file URI, absolute local artwork path, or `network://`
  /// cover reference.
  final String? artUri;
  final ColorScheme colorScheme;
  final int? cacheWidth;
  final double iconSize;

  /// Paints the whole cover through [CoverImageFrame] instead of cropping it.
  final bool complete;

  /// Shown instead of the placeholder when an online [artUri] fails to load,
  /// such as the file's own embedded cover.
  final String? fallbackUri;

  @visibleForTesting
  final BaseCacheManager? cacheManager;

  const PlayerArtwork({
    super.key,
    required this.artUri,
    required this.colorScheme,
    this.cacheWidth,
    this.iconSize = 40,
    this.complete = false,
    this.fallbackUri,
    this.cacheManager,
  });

  /// Share one full-size decode while artwork moves between player panels.
  static int transitionCacheWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).shortestSide *
              MediaQuery.devicePixelRatioOf(context))
          .round();

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: colorScheme.surfaceContainerHighest,
      child: AppIcon(
        Icons.music_note,
        size: iconSize,
        color: colorScheme.onSurfaceVariant,
      ),
    );

    final uri = artUri;
    if (isHttpCoverUrl(uri)) {
      final fallback = fallbackUri;
      final onError = fallback == null || fallback.isEmpty
          ? placeholder
          : PlayerArtwork(
              artUri: fallback,
              colorScheme: colorScheme,
              cacheWidth: cacheWidth,
              iconSize: iconSize,
              complete: complete,
              cacheManager: cacheManager,
            );
      return CachedNetworkImage(
        imageUrl: uri!,
        fit: BoxFit.cover,
        imageBuilder: complete
            ? (_, provider) => CoverImageFrame(
                image: provider,
                errorBuilder: (_, _, _) => onError,
              )
            : null,
        cacheManager: cacheManager ?? CoverCacheManager.instance,
        memCacheWidth: cacheWidth,
        fadeInDuration: Duration.zero,
        fadeOutDuration: const Duration(milliseconds: 0),
        useOldImageOnUrlChange: true,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => onError,
      );
    }
    final image = coverImageProvider(uri, cacheWidth: cacheWidth);
    if (image == null) {
      return pendingCover(uri, placeholder: placeholder, builder: build);
    }
    if (complete) {
      return CoverImageFrame(
        image: image,
        errorBuilder: (_, _, _) => placeholder,
      );
    }
    return Image(
      image: image,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}
