import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/prefetch_planner.dart';
import 'package:mornye/widgets/app_choice_chip.dart';

/// How many songs after the current one are prepared while it plays.
class UpcomingPrefetchSettings extends ConsumerWidget {
  const UpcomingPrefetchSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      settingsProvider.select((s) => s.playbackPrefetchCount),
    );
    final notifier = ref.read(settingsProvider.notifier);
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.prefetchUpcoming, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 4),
          Text(
            l10n.prefetchUpcomingDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (var value = 0; value <= maxPrefetchWindow; value++)
                AppChoiceChip(
                  label: Text(value == 0 ? l10n.prefetchUpcomingOff : '$value'),
                  selected: count == value,
                  singleChoice: true,
                  onSelected: (_) => notifier.setPlaybackPrefetchCount(value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
