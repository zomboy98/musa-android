import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/lyrics_editor_sheet.dart';
import 'package:mornye/widgets/lyrics_align_picker.dart';
import 'package:mornye/widgets/lyrics_line_correction.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/lyrics_text_scale.dart';

class PlayerLyricsSection extends ConsumerWidget {
  const PlayerLyricsSection({
    super.key,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.isActive,
    this.animateWords = true,
    this.options,
    this.onShareLyrics,
    this.showCorrectionHint = false,
  });

  final PlayerMetadataController metadata;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final bool isActive;
  final bool animateWords;
  final Widget? options;

  /// Long-pressing lyrics opens sharing, preselecting a timed line.
  final ValueChanged<LyricLine?>? onShareLyrics;

  /// Whether these lyrics are on screen, so the one-time tip on correcting a
  /// line may show.
  final bool showCorrectionHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibility = ref.watch(
      settingsProvider.select(
        (settings) =>
            (settings.playerShowPronunciation, settings.playerShowTranslation),
      ),
    );
    // The AI translation is keyed by these; a change picks another one.
    ref.watch(
      settingsProvider.select(
        (settings) => (
          settings.lyricsAiProvider,
          settings.lyricsAiModel,
          settings.lyricsAiBaseUrl,
          settings.lyricsTranslationLanguage,
          settings.locale,
          settings.lyricsAutoTranslate,
          settings.lyricsAiWordSync,
        ),
      ),
    );
    ref.watch(lyricsTranslationProvider.select((state) => state.results));
    final translation = ref.read(lyricsTranslationProvider.notifier);
    final chosenAlign = ref
        .watch(settingsProvider.select((s) => s.lyricsAlign))
        .explicit;
    return ListenableBuilder(
      listenable: metadata,
      builder: (context, _) => _buildLyricsSection(
        context,
        chosenAlign,
        visibility,
        translation.display(metadata.lyrics),
      ),
    );
  }

  Widget _buildLyricsSection(
    BuildContext context,
    LyricsTextAlign? chosenAlign,
    (bool, bool) visibility,
    ParsedLyrics lyrics,
  ) {
    // Center in the part the player's controls leave visible. Only these
    // states depend on it, so a lyric list does not rebuild as they fade.
    if (metadata.loading || metadata.searchingOnline) {
      return Builder(
        builder: (context) => Padding(
          padding: EdgeInsets.only(bottom: LyricsCoveredBottom.of(context)),
          child: const Center(child: AppLoadingIndicator()),
        ),
      );
    }
    if (metadata.lyrics.isEmpty) {
      // Scrolls when a short screen leaves too little room above the
      // controls, so the search button stays reachable.
      return LayoutBuilder(
        builder: (_, constraints) {
          final covered = LyricsCoveredBottom.of(context);
          return SingleChildScrollView(
            padding: EdgeInsets.only(bottom: covered),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                minHeight: constraints.hasBoundedHeight
                    ? (constraints.maxHeight - covered).clamp(
                        0.0,
                        double.infinity,
                      )
                    : 0,
              ),
              child: Center(child: _noLyrics(context)),
            ),
          );
        },
      );
    }
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: KeyedSubtree(
        key: ValueKey(lyrics.synced),
        child: _lyricsContent(context, chosenAlign, visibility, lyrics),
      ),
    );
  }

  Widget _noLyrics(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(
          Icons.lyrics_outlined,
          size: 40,
          color: colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          metadata.onlineInstrumental
              ? context.l10n.lyricsPickerInstrumental
              : metadata.onlineDeferredOffline
              ? context.l10n.extensionHealthOffline
              : metadata.onlineSearchFailed
              ? context.l10n.trackLyricsLoadFailed
              : metadata.onlineSearchMissed
              ? context.l10n.nowPlayingNoLyricsOnline
              : context.l10n.nowPlayingNoLyrics,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        if (metadata.canSearchOnline && !metadata.onlineInstrumental) ...[
          const SizedBox(height: 16),
          ExpressiveButton(
            tonal: true,
            onPressed: () async {
              await metadata.searchOnline();
              if (context.mounted && metadata.onlineLyricsSaveFailed) {
                showAppSnackBar(
                  context,
                  content: Text(context.l10n.snackbarFailedToEmbedLyrics),
                );
              }
            },
            icon: const Icon(Icons.manage_search),
            child: Text(context.l10n.nowPlayingSearchLyricsOnline),
          ),
        ],
        if (canEditPlayerLyrics(metadata)) ...[
          const SizedBox(height: 8),
          ExpressiveButton(
            key: const ValueKey('lyrics-write'),
            text: true,
            onPressed: () => openLyricsEditor(context, metadata),
            icon: const Icon(Icons.edit_note),
            child: Text(context.l10n.lyricsEditWrite),
          ),
        ],
      ],
    ),
  );

  Widget _lyricsContent(
    BuildContext context,
    LyricsTextAlign? chosenAlign,
    (bool, bool) visibility,
    ParsedLyrics lyrics,
  ) {
    if (metadata.lyrics.synced) {
      return Stack(
        fit: StackFit.expand,
        children: [
          SyncedLyricsView(
            lyrics: lyrics,
            trackOffsetMs: metadata.trackOffsetMs,
            autoOffsetMs: metadata.autoOffsetMs,
            seekPreview: seekPreview,
            credits: _lyricsCredits(),
            colorScheme: colorScheme,
            isActive: isActive,
            animateWords: animateWords,
            showPronunciation: visibility.$1,
            showTranslation: visibility.$2,
            onLongPressLine: metadata.canCorrectLines
                ? (line) => showLyricsLineActions(
                    context,
                    metadata,
                    line,
                    onShare: onShareLyrics,
                  )
                : onShareLyrics,
          ),
          if (options != null)
            PositionedDirectional(
              start: context.isMornye ? mornyeLyricsContentInset : 24,
              bottom: 8,
              child: options!,
            ),
          if (metadata.canCorrectLines)
            _CorrectionHint(enabled: showCorrectionHint && isActive),
        ],
      );
    }
    final plainAlign = chosenAlign == null
        ? TextAlign.center
        : lyricsTextAlignFor(chosenAlign, Directionality.of(context));
    final plain = SingleChildScrollView(
      // Leaves room for the options button over the end of the text.
      padding: EdgeInsets.fromLTRB(24, 16, 24, options == null ? 32 : 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onLongPress: onShareLyrics == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onShareLyrics!(null);
                  },
            child: LyricsTextScale(
              child: Text(
                metadata.lyrics.plainText,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  height: 1.6,
                  color: colorScheme.onSurface,
                ),
                textAlign: plainAlign,
              ),
            ),
          ),
          ?_lyricsCredits(),
        ],
      ),
    );
    if (options == null) return plain;
    return Stack(
      fit: StackFit.expand,
      children: [
        plain,
        PositionedDirectional(
          start: context.isMornye ? mornyeLyricsContentInset : 24,
          bottom: 8,
          child: options!,
        ),
      ],
    );
  }

  LyricsCredits? _lyricsCredits() {
    final (:writers, :provider) = metadata.credits;
    final estimated = metadata.lyricsEstimated;
    if (writers == null && provider == null && !estimated) return null;
    return LyricsCredits(
      writers: writers,
      provider: provider,
      estimated: estimated,
    );
  }
}

/// Tells once, the first time lyrics of a catalog track are on screen, that a
/// line can be corrected by holding it.
class _CorrectionHint extends ConsumerStatefulWidget {
  const _CorrectionHint({required this.enabled});

  final bool enabled;

  @override
  ConsumerState<_CorrectionHint> createState() => _CorrectionHintState();
}

class _CorrectionHintState extends ConsumerState<_CorrectionHint> {
  bool _scheduled = false;

  void _maybeShow() {
    if (_scheduled || !widget.enabled || !TickerMode.valuesOf(context).enabled)
      return;
    if (ref.read(settingsProvider).lyricsLineHintShown) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(settingsProvider).lyricsLineHintShown) return;
      ref.read(settingsProvider.notifier).markLyricsLineHintShown();
      showAppSnackBar(
        context,
        content: Text(context.l10n.lyricsLineCorrectHint),
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeShow();
  }

  @override
  void didUpdateWidget(_CorrectionHint old) {
    super.didUpdateWidget(old);
    _maybeShow();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
