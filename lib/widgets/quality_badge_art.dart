import 'package:flutter/material.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';
import 'package:mornye/widgets/quality_mark_art.dart';

String qualityBadgeName(BuildContext context, QualityBadgeFormat format) =>
    qualityMarkText(context, qualityMarkForFormat(format)).name;

/// Compact logo of a format: its vector glyph and its name, without a plate.
/// [mark] picks any of the supported formats; without it the badge format
/// decides. [size] is the height; the width follows the name. The glyphs do
/// not follow text scaling, like a logo.
class QualityBadgeArt extends StatelessWidget {
  const QualityBadgeArt({
    super.key,
    required this.format,
    this.mark,
    this.size = 20,
    this.color,
    this.semanticLabel,
    this.iconOnly = false,
  });

  final QualityBadgeFormat format;
  final QualityMark? mark;
  final double size;
  final Color? color;

  /// Overrides the spoken name, which is the format's name by default.
  final String? semanticLabel;

  /// Draws the glyph without its name.
  final bool iconOnly;

  QualityMark get resolvedMark => mark ?? qualityMarkForFormat(format);

  static double widthFor(QualityBadgeFormat format, double size) =>
      switch (format) {
        QualityBadgeFormat.spatial => size * 3.6,
        QualityBadgeFormat.hiRes => size * 3.4,
        QualityBadgeFormat.max => size * 2.8,
        QualityBadgeFormat.lossless => size * 4.6,
        QualityBadgeFormat.flac => size * 2.9,
        QualityBadgeFormat.aac => size * 2.6,
        QualityBadgeFormat.lossy => size * 3.6,
      };

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    final value = resolvedMark;
    final name = qualityMarkText(context, value).name;
    return Semantics(
      label: semanticLabel ?? name,
      image: true,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            QualityMarkIcon(mark: value, size: size, color: fg),
            if (!iconOnly) SizedBox(width: size * 0.28),
            if (!iconOnly)
              Text(
                name,
                maxLines: 1,
                softWrap: false,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: fg,
                  fontSize: size * (name.length > 5 ? 0.5 : 0.62),
                  fontWeight: FontWeight.w800,
                  height: 1,
                  letterSpacing: size * 0.02,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
