import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';

/// Reading-direction aware [TextAlign] for a chosen alignment: left and right
/// follow the start and end edges so right-to-left text keeps its meaning.
TextAlign lyricsTextAlignFor(LyricsTextAlign align, TextDirection direction) {
  final ltr = direction == TextDirection.ltr;
  return switch (align) {
    LyricsTextAlign.left => ltr ? TextAlign.start : TextAlign.end,
    LyricsTextAlign.center => TextAlign.center,
    LyricsTextAlign.right => ltr ? TextAlign.end : TextAlign.start,
    LyricsTextAlign.justify => TextAlign.justify,
  };
}

IconData lyricsAlignIcon(LyricsTextAlign align) => switch (align) {
  LyricsTextAlign.left => Icons.format_align_left,
  LyricsTextAlign.center => Icons.format_align_center,
  LyricsTextAlign.right => Icons.format_align_right,
  LyricsTextAlign.justify => Icons.format_align_justify,
};

String lyricsAlignLabel(BuildContext context, LyricsTextAlign align) {
  final l10n = context.l10n;
  return switch (align) {
    LyricsTextAlign.left => l10n.lyricsAlignLeft,
    LyricsTextAlign.center => l10n.lyricsAlignCenter,
    LyricsTextAlign.right => l10n.lyricsAlignRight,
    LyricsTextAlign.justify => l10n.lyricsAlignJustify,
  };
}

/// Four alignment icons, plus an "automatic" choice when [auto] is set.
class LyricsAlignSelector extends StatelessWidget {
  const LyricsAlignSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.auto = false,
  });

  /// Selected alignment, or null for "automatic".
  final LyricsTextAlign? value;
  final ValueChanged<LyricsTextAlign?> onChanged;
  final bool auto;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: SegmentedButton<LyricsTextAlign?>(
      key: const ValueKey('lyrics-align-selector'),
      showSelectedIcon: false,
      emptySelectionAllowed: false,
      segments: [
        if (auto)
          ButtonSegment(
            value: null,
            label: Text(context.l10n.lyricsAlignAuto),
            tooltip: context.l10n.lyricsAlignAuto,
          ),
        for (final align in LyricsTextAlign.values)
          ButtonSegment(
            value: align,
            icon: Icon(lyricsAlignIcon(align)),
            tooltip: lyricsAlignLabel(context, align),
          ),
      ],
      selected: {value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    ),
  );
}

/// Short invented lyric laid out with [align], to show what it does.
class LyricsAlignSample extends StatelessWidget {
  const LyricsAlignSample({super.key, required this.align});

  final TextAlign align;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      context.l10n.lyricsAlignSample,
      textAlign: align,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
    ),
  );
}

/// Settings footer: the selector with a live sample under it.
class LyricsAlignSettingFooter extends StatelessWidget {
  const LyricsAlignSettingFooter({
    super.key,
    required this.value,
    required this.onChanged,
    this.auto = false,
  });

  final LyricsTextAlign? value;
  final ValueChanged<LyricsTextAlign?> onChanged;
  final bool auto;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: LyricsAlignSelector(
            value: value,
            onChanged: onChanged,
            auto: auto,
          ),
        ),
        const SizedBox(height: 10),
        LyricsAlignSample(
          align: value == null
              ? TextAlign.start
              : lyricsTextAlignFor(value!, direction),
        ),
      ],
    );
  }
}
