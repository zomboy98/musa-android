import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/constants/app_version.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/app_update_provider.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_update_actions.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Settings > About > Updates: installed version, last query, status, the
/// published build with its notes, and the button that looks again.
class AppUpdateSection extends ConsumerWidget {
  const AppUpdateSection({super.key});

  static String _when(BuildContext context, DateTime at) {
    final material = MaterialLocalizations.of(context);
    final local = at.toLocal();
    return '${material.formatShortDate(local)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  static String _published(BuildContext context, String raw) {
    final parsed = DateTime.tryParse(raw);
    return parsed == null
        ? raw
        : MaterialLocalizations.of(context).formatMediumDate(parsed);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = ref.watch(appUpdateProvider);
    final notifier = ref.read(appUpdateProvider.notifier);
    final offer = state.hasOffer ? state.offer : null;
    final installedBuild =
        state.installedBuild ?? int.tryParse(AppInfo.buildNumber) ?? 0;
    final checking = state.stage == AppUpdateStage.checking;
    final downloading = state.stage == AppUpdateStage.downloading;

    final String statusTitle;
    if (offer != null) {
      statusTitle = l10n.appUpdateAvailableLabel(offer.label);
    } else {
      statusTitle = switch (state.stage) {
        AppUpdateStage.checking => l10n.appUpdateChecking,
        AppUpdateStage.upToDate => l10n.appUpdateUpToDate,
        AppUpdateStage.error => l10n.appUpdateCheckFailed,
        _ => l10n.appUpdateNeverChecked,
      };
    }

    final details = <String>[
      if (offer != null && offer.publishedAt.isNotEmpty)
        l10n.appUpdatePublishedOn(_published(context, offer.publishedAt)),
      if (offer != null) '${l10n.appUpdateSize}: ${formatBytes(offer.sizeBytes)}',
    ];

    final checkedAt = state.checkedAt;
    final lastChecked = checking
        ? l10n.appUpdateChecking
        : checkedAt == null
        ? l10n.appUpdateNeverChecked
        : l10n.appUpdateLastChecked(_when(context, checkedAt));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsSectionHeader(title: l10n.appUpdateSectionTitle),
        SettingsGroup(
          connected: true,
          children: [
            SettingsItem(
              icon: Icons.info_outline,
              title: l10n.appUpdateInstalledVersion,
              subtitle: l10n.appUpdateInstalledValue(
                musaPublicLabel,
                installedBuild,
              ),
            ),
            SettingsItem(
              icon: Icons.system_update_alt_rounded,
              title: statusTitle,
              subtitle: offer != null ? details.join(' · ') : null,
              footer: offer == null
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (offer.notes.isNotEmpty) Text(offer.notes),
                        if (state.checkFailed) ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.appUpdateOfferedLastKnown,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (downloading) ...[
                          const SizedBox(height: 12),
                          AppProgressIndicator.linear(
                            value: state.progress,
                            wavy: false,
                          ),
                        ],
                        const SizedBox(height: 12),
                        ExpressiveButton(
                          onPressed: state.busy
                              ? null
                              : () => startAppUpdateFlow(context, ref),
                          child: Text(l10n.appUpdateInstall),
                        ),
                      ],
                    ),
            ),
            SettingsItem(
              icon: Icons.refresh_rounded,
              title: l10n.appUpdateCheck,
              subtitle: lastChecked,
              onTap: state.busy ? null : notifier.checkNow,
              showDivider: false,
            ),
          ],
        ),
      ],
    );
  }
}
