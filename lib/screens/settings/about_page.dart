import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/guided_tour_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:mornye/services/cover_cache_manager.dart';
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
import 'package:mornye/services/app_update_service.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_update_dialog.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

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
              title: context.l10n.aboutContributors,
              connected: true,
              children: [
                _ContributorItem(
                  name: 'Amonoman',
                  description: context.l10n.aboutLogoArtist,
                  githubUsername: 'Amonoman',
                  showDivider: true,
                ),
                _ContributorItem(
                  name: 'Ruubiiiii',
                  description: context.l10n.aboutRuubiiiiDesc,
                  githubUsername: 'Ruubiiiii',
                  showDivider: false,
                ),
              ],
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.aboutTranslators,
              ),
            ),
            const SliverToBoxAdapter(child: _TranslatorsSection()),

            ...settingsSectionSlivers(
              title: context.l10n.aboutSpecialThanks,
              connected: true,
              children: [
                _ContributorItem(
                  name: 'binimum',
                  description: context.l10n.aboutBinimumDesc,
                  githubUsername: 'binimum',
                  showDivider: true,
                ),
                _ContributorItem(
                  name: 'sachinsenal0x64',
                  description: context.l10n.aboutSachinsenalDesc,
                  githubUsername: 'sachinsenal0x64',
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.swap_horiz_rounded,
                  title: 'UniTune',
                  subtitle: context.l10n.aboutUnituneDesc,
                  onTap: () =>
                      _launchUrl('https://github.com/FlazeIGuess/unitune-api'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.library_music_outlined,
                  title: 'MusicBrainz',
                  subtitle: context.l10n.aboutMusicBrainzDesc,
                  onTap: () => _launchUrl('https://musicbrainz.org'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.hub_outlined,
                  title: 'Squigly',
                  subtitle: context.l10n.aboutSquiglyDesc,
                  onTap: () => _launchUrl('https://squigly.link'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.lyrics_outlined,
                  title: 'Paxsenix',
                  subtitle: context.l10n.aboutPaxsenixSubtitle,
                  onTap: () => _launchUrl('https://lyrics.paxsenix.org'),
                  showDivider: false,
                ),
              ],
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
                if (Platform.isAndroid) const _UpdateCheckItem(),
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

class _ContributorItem extends StatelessWidget {
  final String name;
  final String description;
  final String githubUsername;
  final bool showDivider;

  const _ContributorItem({
    required this.name,
    required this.description,
    required this.githubUsername,
    this.showDivider = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => _launchUrl('https://github.com/$githubUsername'),
          splashColor: colorScheme.primary.withValues(alpha: 0.12),
          highlightColor: colorScheme.primary.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: 'https://github.com/$githubUsername.png',
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    memCacheWidth: 120,
                    memCacheHeight: 120,
                    cacheManager: CoverCacheManager.instance,
                    placeholder: (context, url) => Container(
                      width: 40,
                      height: 40,
                      color: colorScheme.surfaceContainerHighest,
                      child: AppIcon(
                        Icons.person,
                        color: colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                    ),
                    errorWidget: (context, url, error) => Container(
                      width: 40,
                      height: 40,
                      color: colorScheme.surfaceContainerHighest,
                      child: AppIcon(
                        Icons.person,
                        color: colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
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
            indent: 76,
            endIndent: 20,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
  }
}

class _Translator {
  final String name;
  final String crowdinUsername;
  final String flag;

  const _Translator({
    required this.name,
    required this.crowdinUsername,
    required this.flag,
  });
}

class _TranslatorsSection extends StatelessWidget {
  const _TranslatorsSection();

  static const List<_Translator> _translators = [
    _Translator(
      name: 'Pedro Marcondes',
      crowdinUsername: 'justapedro',
      flag: '🇵🇹',
    ),
    _Translator(
      name: 'Credits 125',
      crowdinUsername: 'credits125',
      flag: '🇪🇸',
    ),
    _Translator(
      name: 'Владислав',
      crowdinUsername: 'odinokiy_kot',
      flag: '🇷🇺',
    ),
    _Translator(name: 'Amonoman', crowdinUsername: 'amonoman', flag: '🇩🇪'),
    _Translator(
      name: 'Re*Index.(ot_inc)',
      crowdinUsername: 'ot_inc',
      flag: '🇯🇵',
    ),
    _Translator(name: 'unkn0wn', crowdinUsername: 'rdclvi', flag: '🇮🇩'),
    _Translator(
      name: 'lunching1272',
      crowdinUsername: 'lunching1272',
      flag: '🇨🇳',
    ),
    _Translator(
      name: 'Serhii Ilchenko',
      crowdinUsername: 'Sega_Mostky',
      flag: '🇺🇦',
    ),
    _Translator(
      name: 'Serhii Ilchenko',
      crowdinUsername: 'Sega_Mostky',
      flag: '🇷🇺',
    ),
    _Translator(name: 'Girl-lass', crowdinUsername: 'Girl-lass', flag: '🇨🇳'),
    _Translator(name: 'Kaan', crowdinUsername: 'glai', flag: '🇹🇷'),
    _Translator(
      name: 'BedirhanGltkn',
      crowdinUsername: 'bedirhangltkn',
      flag: '🇹🇷',
    ),
    _Translator(name: 'Mickael81', crowdinUsername: 'Mickael81', flag: '🇫🇷'),
    _Translator(name: 'BrandQc', crowdinUsername: 'BrandQc', flag: '🇫🇷'),
    _Translator(
      name: 'blackgold8282',
      crowdinUsername: 'blackgold8282',
      flag: '🇰🇷',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final cardColor = !context.isMornye
        ? settingsGroupColor(context)
        : isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            colorScheme.surface,
          )
        : colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _translators
              .map((translator) => _TranslatorChip(translator: translator))
              .toList(),
        ),
      ),
    );
  }
}

class _TranslatorChip extends StatelessWidget {
  final _Translator translator;

  const _TranslatorChip({required this.translator});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: () => _launchUrl(
          'https://crowdin.com/profile/${translator.crowdinUsername}',
        ),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 10,
                backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                child: Text(
                  translator.name.isNotEmpty
                      ? translator.name[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                translator.name,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Text(translator.flag, style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpdateCheckItem extends StatefulWidget {
  const _UpdateCheckItem();

  @override
  State<_UpdateCheckItem> createState() => _UpdateCheckItemState();
}

class _UpdateCheckItemState extends State<_UpdateCheckItem> {
  bool _checking = false;
  String? _result;

  Future<void> _check() async {
    if (_checking) return;
    final l10n = context.l10n;
    setState(() {
      _checking = true;
      _result = null;
    });
    final service = AppUpdateService();
    final check = await service.checkForUpdate(ignoreSnooze: true);
    if (!mounted) return;
    final offer = check.offer;
    setState(() {
      _checking = false;
      _result = switch (check.status) {
        AppUpdateStatus.upToDate => l10n.appUpdateUpToDate,
        AppUpdateStatus.available || AppUpdateStatus.snoozed => null,
        AppUpdateStatus.unavailable => l10n.appUpdateCheckFailed,
      };
    });
    if (offer != null) {
      await showAppUpdateDialog(context, service: service, offer: offer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _AboutSettingsItem(
      icon: Icons.system_update_alt_rounded,
      title: l10n.appUpdateCheck,
      subtitle: _checking ? l10n.appUpdateChecking : _result,
      onTap: _check,
      showDivider: true,
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
