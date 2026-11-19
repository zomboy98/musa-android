import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/app_update_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_update_actions.dart';

/// Home notice while a published build is waiting. Hiding it lasts for the
/// session only; it comes back the next time the app opens.
class AppUpdateBanner extends ConsumerWidget {
  const AppUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateProvider);
    final offer = state.offer;
    if (!state.showBanner || offer == null) return const SizedBox.shrink();
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final inset = 16 + wideListInset(context);
    final busy = state.busy;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 8),
      child: AppContentCard(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: colorScheme.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: tokens.borderRadiusCard),
        onTap: busy ? null : () => startAppUpdateFlow(context, ref),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.gapLg,
            tokens.gapSm,
            tokens.gapSm,
            tokens.gapSm,
          ),
          child: Row(
            children: [
              AppIcon(
                Icons.system_update_alt_rounded,
                color: colorScheme.onSecondaryContainer,
              ),
              SizedBox(width: tokens.gapMd),
              Expanded(
                child: Text(
                  l10n.appUpdateBannerText(offer.label),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: busy ? null : () => startAppUpdateFlow(context, ref),
                child: Text(l10n.appUpdateInstall),
              ),
              IconButton(
                tooltip: l10n.appUpdateDismiss,
                visualDensity: VisualDensity.compact,
                onPressed: ref.read(appUpdateProvider.notifier).dismissBanner,
                icon: AppIcon(
                  Icons.close_rounded,
                  size: 20,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
