import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/guided_tour_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/constants/build_profile.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/legal_gate_screen.dart';
import 'package:mornye/constants/app_version.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/report/report_page.dart';
import 'package:mornye/screens/settings/musa_license_page.dart';
import 'package:mornye/screens/whats_new_screen.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_update_section.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.showUpdates});

  /// The Updates section; defaults to Android, the only platform that installs
  /// its own updates.
  final bool? showUpdates;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.aboutTitle),

            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16 + wideListInset(context),
                  16,
                  16 + wideListInset(context),
                  8,
                ),
                child: _AppHeaderCard(),
              ),
            ),

            const SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [_TourReplayItem()],
              ),
            ),

            ...settingsSectionSlivers(
              title: context.l10n.aboutLinks,
              connected: true,
              children: [
                _AboutSettingsItem(
                  icon: Icons.bug_report_outlined,
                  title: context.l10n.aboutReportIssue,
                  subtitle: context.l10n.aboutReportIssueSubtitle,
                  onTap: () => ReportPage.open(context),
                  showDivider: false,
                ),
              ],
            ),

            if (showUpdates ?? Platform.isAndroid)
              const SliverToBoxAdapter(child: AppUpdateSection()),

            ...settingsSectionSlivers(
              title: context.l10n.aboutApp,
              connected: true,
              children: [
                _AboutSettingsItem(
                  icon: Icons.info_outline,
                  title: context.l10n.aboutVersion,
                  subtitle:
                      '${AppInfo.displayVersion == 'Internal' ? 'vInternal' : musaPublicLabel} (build ${AppInfo.buildNumber})'
                      '${isBetaBuild ? ' · ${context.l10n.legalBetaTag}' : ''}',
                  showDivider: true,
                ),
                if (isBetaBuild)
                  _AboutSettingsItem(
                    icon: Icons.science_outlined,
                    title: context.l10n.legalBetaTag,
                    subtitle: context.l10n.aboutBetaNote,
                    showDivider: true,
                  ),
                const _LegalAboutItem(),
                _AboutSettingsItem(
                  icon: Icons.new_releases,
                  title: context.l10n.whatsNewAboutTitle(
                    AppInfo.whatsNewRelease,
                  ),
                  // Above the shell, as it shows after an update.
                  onTap: () => isDesktopPlatform
                      ? showWhatsNewDialog(context)
                      : Navigator.of(context, rootNavigator: true).push(
                          slidePageRoute<void>(page: const WhatsNewScreen()),
                        ),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.policy_outlined,
                  title: MaterialLocalizations.of(context).licensesPageTitle,
                  subtitle: AppInfo.license,
                  onTap: () => showMusaLicensePage(context),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.code,
                  title: context.l10n.licenseSourceCodeTitle,
                  subtitle: AppInfo.sourceCodeUrl,
                  onTap: () => _launchUrl(AppInfo.sourceCodeUrl),
                  showDivider: false,
                ),
              ],
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    AppInfo.shortGitCommit.isEmpty
                        ? AppInfo.copyright
                        : '${AppInfo.copyright} · ${AppInfo.shortGitCommit}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 16)),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }
}

Future<void> _launchUrl(String url) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
}

class _LegalAboutItem extends ConsumerWidget {
  const _LegalAboutItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(
      settingsProvider.select(
        (s) => (s.acceptedLegalVersion, s.acceptedLegalAt),
      ),
    );
    final at = DateTime.tryParse(settings.$2)?.toLocal();
    final subtitle = settings.$1 > 0 && at != null
        ? l10n.legalAboutAccepted(
            MaterialLocalizations.of(context).formatShortDate(at),
            settings.$1,
          )
        : l10n.legalAboutNotAccepted;
    return _AboutSettingsItem(
      icon: Icons.privacy_tip_outlined,
      title: l10n.legalTextsTitle,
      subtitle: subtitle,
      showDivider: true,
      onTap: () => Navigator.of(
        context,
      ).push<void>(MaterialPageRoute(builder: (_) => const LegalTextsScreen())),
    );
  }
}

class _TourReplayItem extends ConsumerWidget {
  const _TourReplayItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return _AboutSettingsItem(
      icon: Icons.slideshow_rounded,
      title: l10n.tourReplayTitle,
      subtitle: l10n.tourReplaySubtitle,
      showDivider: false,
      onTap: () {
        ref.read(guidedTourProvider.notifier).replay();
        Navigator.of(context).popUntil((route) => route.isFirst);
        Navigator.of(
          context,
          rootNavigator: true,
        ).popUntil((route) => route.isFirst);
      },
    );
  }
}

class _AppHeaderCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Material sits on the settings group tier beside the groups below.
    final cardColor = !context.isMornye
        ? settingsGroupColor(context)
        : isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            colorScheme.surface,
          )
        : colorScheme.surfaceContainerHighest;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final textScale = MediaQuery.textScalerOf(
          context,
        ).scale(1.0).clamp(1.0, 1.4);
        final logoSize = (shortestSide * 0.22).clamp(72.0, 88.0);
        final contentPadding = (cardWidth * 0.06).clamp(16.0, 24.0);
        final titleGap = (16 * (1 + ((textScale - 1) * 0.2))).clamp(12.0, 20.0);

        return Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: EdgeInsets.all(contentPadding),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(logoSize * 0.28),
                child: Image.asset(
                  'assets/images/musa-icon.png',
                  width: logoSize,
                  height: logoSize,
                  fit: BoxFit.contain,
                ),
              ),
              SizedBox(height: titleGap),
              Text(
                AppInfo.appName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  AppInfo.displayVersion == 'Internal' ? 'vInternal' : musaPublicLabel,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(height: titleGap),
              Text(
                context.l10n.aboutAppDescription,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AboutSettingsItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool showDivider;

  const _AboutSettingsItem({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          splashColor: colorScheme.primary.withValues(alpha: 0.12),
          highlightColor: colorScheme.primary.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: AppIcon(
                    context.adaptiveIcon(icon),
                    color: context.isMornye
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.bodyLarge),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onTap != null)
                  AppIcon(
                    Icons.chevron_right,
                    color: colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          Divider(
            height: 1,
            thickness: 1,
            indent: 76, // 20 + 40 + 16 = 76 (same as contributor item)
            endIndent: 20,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
    return SettingsSearchTarget(label: title, child: content);
  }
}
