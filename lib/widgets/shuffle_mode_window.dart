import 'dart:math';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/services/shuffle_strategy.dart';
import 'package:mornye/widgets/app_icon.dart';

class ShuffleStrategyIcon extends StatelessWidget {
  const ShuffleStrategyIcon({
    super.key,
    required this.strategy,
    this.size,
    this.color,
    this.icon = Icons.shuffle,
  });

  final ShuffleStrategy strategy;
  final IconData icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final glyph = size ?? iconTheme.size ?? 24;
    final tint = color ?? iconTheme.color;
    return SizedBox.square(
      dimension: glyph,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AppIcon(icon, size: glyph, color: tint),
          if (strategy == ShuffleStrategy.smart)
            Positioned(
              top: -glyph * 0.22,
              right: -glyph * 0.26,
              child: AppIcon(
                Icons.auto_awesome,
                size: glyph * 0.58,
                color: tint,
              ),
            ),
        ],
      ),
    );
  }
}

String shuffleStrategyLabel(BuildContext context, ShuffleStrategy strategy) {
  final l10n = context.l10n;
  return switch (strategy) {
    ShuffleStrategy.off => l10n.shuffleModeOff,
    ShuffleStrategy.random => l10n.shuffleModeOnRandom,
    ShuffleStrategy.smart => l10n.shuffleModeOnSmart,
  };
}

bool queueAllowsSmartShuffle(List<MediaItem> queue) {
  final albums = <String>{};
  final artists = <String>{};
  for (final item in queue) {
    if (item.extras?['autoplay'] == true) continue;
    albums.add(
      item.extras?['albumId']?.toString() ??
          (item.album ?? '').trim().toLowerCase(),
    );
    artists.add((item.artist ?? '').trim().toLowerCase());
    if (albums.length > 1 && artists.length > 1) return true;
  }
  return false;
}

Future<ShuffleStrategy?> showShuffleModeWindow(
  BuildContext context, {
  required ShuffleStrategy current,
  required bool smartAvailable,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<ShuffleStrategy>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black38,
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) =>
        _ShuffleModeWindow(current: current, smartAvailable: smartAvailable),
    transitionBuilder: (context, animation, _, child) {
      if (reduceMotion) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

Future<void> chooseShuffleStrategy(
  BuildContext context, {
  required ShuffleStrategy current,
  required bool smartAvailable,
  required Future<void> Function(ShuffleStrategy strategy) apply,
}) async {
  final picked = await showShuffleModeWindow(
    context,
    current: current,
    smartAvailable: smartAvailable,
  );
  if (picked == null) return;
  await apply(picked == current ? ShuffleStrategy.off : picked);
}

class _ShuffleModeWindow extends StatelessWidget {
  const _ShuffleModeWindow({
    required this.current,
    required this.smartAvailable,
  });

  final ShuffleStrategy current;
  final bool smartAvailable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            key: const ValueKey('shuffle-mode-window'),
            constraints: const BoxConstraints(maxWidth: 360),
            child: Material(
              color: scheme.surfaceContainerHigh,
              elevation: 8,
              shadowColor: Colors.black54,
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                      child: Semantics(
                        header: true,
                        child: Text(
                          l10n.shuffleModeTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ),
                    _ShuffleOption(
                      key: const ValueKey('shuffle-option-random'),
                      strategy: ShuffleStrategy.random,
                      name: l10n.shuffleModeRandomName,
                      description: l10n.shuffleModeRandomDescription,
                      selected: current == ShuffleStrategy.random,
                    ),
                    if (smartAvailable)
                      _ShuffleOption(
                        key: const ValueKey('shuffle-option-smart'),
                        strategy: ShuffleStrategy.smart,
                        name: l10n.shuffleModeSmartName,
                        description: l10n.shuffleModeSmartDescription,
                        selected: current == ShuffleStrategy.smart,
                      ),
                    if (current != ShuffleStrategy.off)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                        child: Text(
                          l10n.shuffleModeHoldToTurnOff,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShuffleOption extends StatelessWidget {
  const _ShuffleOption({
    super.key,
    required this.strategy,
    required this.name,
    required this.description,
    required this.selected,
  });

  final ShuffleStrategy strategy;
  final String name;
  final String description;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$name. $description',
      excludeSemantics: true,
      onTap: () => Navigator.of(context).pop(strategy),
      child: InkWell(
        onTap: () => Navigator.of(context).pop(strategy),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                  ),
                  child: Center(
                    child: ShuffleStrategyIcon(
                      strategy: strategy,
                      size: 22,
                      color: selected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        style: text.titleSmall?.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Icon(Icons.check_rounded, color: scheme.primary),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> shuffleTrackCollection(
  BuildContext context,
  WidgetRef ref, {
  required List<Track> tracks,
  required bool smartAvailable,
  String? listContext,
  List<String>? listOccurrences,
}) async {
  if (tracks.isEmpty) return;
  final strategy = await showShuffleModeWindow(
    context,
    current: ref.read(shuffleStrategyProvider).value ?? ShuffleStrategy.off,
    smartAvailable: smartAvailable,
  );
  if (strategy == null || !context.mounted) return;
  try {
    await ref.read(musicPlayerControllerProvider).setShuffleStrategy(strategy);
    await ref
        .read(playbackProvider.notifier)
        .playTrackList(
          tracks,
          startIndex: Random().nextInt(tracks.length),
          exactStart: true,
          listContext: listContext,
          listOccurrences: listOccurrences,
        );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.snackbarCannotOpenFile('$error'))),
    );
  }
}
