import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/overflow_marquee.dart';

/// Height of the title line and the smaller line of artists and album.
const double playerTrackLineHeight = 48;

/// The title in one line, scaled down to show it whole, with the artists and
/// the album below in smaller type. The smaller line scrolls when it does not
/// fit; with reduced motion it ends in an ellipsis instead.
class PlayerTrackLine extends StatelessWidget {
  const PlayerTrackLine({
    super.key,
    required this.mediaItem,
    required this.metadata,
    required this.colorScheme,
    this.fontSize = 21,
    this.onTap,
  });

  final MediaItem mediaItem;
  final PlayerMetadataController metadata;
  final ColorScheme colorScheme;
  final double fontSize;
  final VoidCallback? onTap;

  static String semanticLabel(MediaItem item) => [
    item.title,
    if ((item.album ?? '').trim().isNotEmpty) item.album!.trim(),
    if ((item.artist ?? '').trim().isNotEmpty) item.artist!.trim(),
  ].join(', ');

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: metadata,
    builder: (context, _) {
      final source = mediaItem.extras?['source']?.toString();
      final loaded = source == metadata.source ? metadata.metadata : null;
      final explicit =
          parseExplicitFlag(loaded?['explicit']) ??
          parseExplicitFlag(mediaItem.extras?['explicit']) ??
          false;
      final album = (mediaItem.album ?? '').trim();
      final artist = (mediaItem.artist ?? '').trim();
      final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
      final titleStyle = TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: colorScheme.onSurface,
      );
      final subStyle = TextStyle(
        fontSize: fontSize * 0.62,
        fontWeight: FontWeight.w500,
        height: 1.2,
        color: colorScheme.onSurface.withValues(alpha: 0.7),
      );
      final reduce = MediaQuery.disableAnimationsOf(context);
      final subtitle = [
        if (artist.isNotEmpty) artist,
        if (album.isNotEmpty) album,
      ].join(' · ');
      final title = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (explicit)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ExplicitBadge(colorScheme: colorScheme),
            ),
          Text(
            mediaItem.title,
            maxLines: 1,
            softWrap: false,
            style: titleStyle,
            textScaler: scaler,
          ),
        ],
      );
      final line = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: playerTrackLineHeight * 0.58,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: title,
            ),
          ),
          if (subtitle.isNotEmpty)
            SizedBox(
              height: playerTrackLineHeight * 0.42,
              width: double.infinity,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: OverflowMarquee(
                  resetKey: (mediaItem.id, mediaItem.title, album, artist),
                  pause: const Duration(milliseconds: 1500),
                  speed: 30,
                  gap: 40,
                  continuous: true,
                  fadeBothEdges: true,
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: reduce ? TextOverflow.ellipsis : TextOverflow.clip,
                    style: subStyle,
                    textScaler: scaler,
                  ),
                ),
              ),
            ),
        ],
      );
      return Semantics(
        label: semanticLabel(mediaItem),
        button: onTap != null,
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            height: playerTrackLineHeight,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: line,
            ),
          ),
        ),
      );
    },
  );
}
