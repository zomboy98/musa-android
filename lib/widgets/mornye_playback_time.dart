import 'package:flutter/material.dart';
import 'package:mornye/utils/string_utils.dart';

class MornyePlaybackTime extends StatelessWidget {
  const MornyePlaybackTime({
    super.key,
    required this.seconds,
    required this.style,
    this.remaining = false,
  });

  final int seconds;
  final TextStyle? style;
  final bool remaining;

  @override
  Widget build(BuildContext context) {
    final label = '${remaining ? '-' : ''}${formatClock(seconds)}';
    final resolved = (style ?? const TextStyle()).copyWith(
      fontFeatures: [
        ...?style?.fontFeatures,
        const FontFeature.tabularFigures(),
      ],
    );
    return Text(
      label,
      style: resolved,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      softWrap: false,
    );
  }
}
