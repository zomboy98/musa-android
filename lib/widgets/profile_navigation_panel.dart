import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:mornye/constants/support_links.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/settings_group.dart' show VisionGlassCard;
import 'package:mornye/widgets/support_project_card.dart';

const double kProfilePanelDarkFillAlpha = .70;
const double kProfilePanelLightFillAlpha = .72;
const double kProfilePanelBlurSigma = 32;

enum ProfilePanelDestination {
  profile,
  statistics,
  recentListening,
  yearly,
  settings,
  extensions,
}

Future<ProfilePanelDestination?> showMusaProfilePanel(
  BuildContext context, {
  required String name,
  required Widget avatar,
  required bool profileAvailable,
}) {
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  final direction = Directionality.of(context);
  return showGeneralDialog<ProfilePanelDestination>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(
      alpha: Theme.of(context).brightness == Brightness.dark ? .34 : .22,
    ),
    transitionDuration: reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 240),
    pageBuilder: (context, _, _) => Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: math.min(MediaQuery.sizeOf(context).width * .88, 360),
        child: MusaProfileNavigationPanel(
          name: name,
          avatar: avatar,
          profileAvailable: profileAvailable,
          onClose: () => Navigator.pop(context),
          onSelected: (destination) => Navigator.pop(context, destination),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: Offset(direction == TextDirection.rtl ? 1 : -1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

/// Local destinations only: no account tier, remote activity or invented data.
class MusaProfileNavigationPanel extends StatelessWidget {
  const MusaProfileNavigationPanel({
    super.key,
    required this.name,
    required this.avatar,
    required this.onSelected,
    required this.onClose,
    this.profileAvailable = true,
  });
  final String name;
  final Widget avatar;
  final bool profileAvailable;
  final ValueChanged<ProfilePanelDestination> onSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final secondaryText = colors.onSurface.withValues(alpha: .76);
    final type = Theme.of(context).textTheme;
    final glass =
        MornyeTheme.glassClarityOf(context) > .2 &&
        !MediaQuery.highContrastOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    final dark = colors.brightness == Brightness.dark;
    final panelFill = colors.surface.withValues(
      alpha: glass
          ? (dark ? kProfilePanelDarkFillAlpha : kProfilePanelLightFillAlpha)
          : 1,
    );
    final outline = colors.onSurface.withValues(alpha: .12);
    Widget group(Widget child, {bool accent = false}) => VisionGlassCard(
      accent: accent,
      radius: 24,
      child: Material(type: MaterialType.transparency, child: child),
    );
    Widget destination(
      ProfilePanelDestination destination,
      IconData icon,
      String label, {
      String? subtitle,
    }) => ListTile(
      key: ValueKey(destination),
      minTileHeight: 72,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: colors.primary, size: 22),
      ),
      title: Text(
        label,
        style: type.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: type.bodyMedium?.copyWith(color: secondaryText),
            ),
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: colors.onSurfaceVariant,
      ),
      onTap: () => onSelected(destination),
    );
    final content = Material(
      key: const ValueKey('profile-panel-material'),
      color: panelFill,
      child: SafeArea(
        child: FocusTraversalGroup(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: 24,
                  end: 12,
                  top: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        namesRoute: true,
                        header: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'MUSA',
                              style: type.labelSmall?.copyWith(
                                letterSpacing: 2,
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.profileTitle,
                              style: type.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('close-profile-panel'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: onClose,
                      style: IconButton.styleFrom(
                        backgroundColor: colors.onSurface.withValues(
                          alpha: .10,
                        ),
                        side: BorderSide(color: outline),
                        shape: const CircleBorder(),
                      ),
                      icon: const Icon(Icons.close, size: 20),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                  children: [
                    group(
                      ListTile(
                        key: const ValueKey('profile-panel-identity'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 18,
                        ),
                        leading: Container(
                          width: 56,
                          height: 56,
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: colors.primary.withValues(alpha: .55),
                            ),
                          ),
                          child: avatar,
                        ),
                        title: Text(
                          name.trim().isEmpty ? l10n.profileSetUp : name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            l10n.profileEntrySubtitle,
                            style: type.bodyMedium?.copyWith(
                              color: secondaryText,
                            ),
                          ),
                        ),
                        trailing: Icon(
                          Icons.arrow_outward_rounded,
                          color: colors.primary,
                          size: 20,
                        ),
                        enabled: profileAvailable,
                        onTap: profileAvailable
                            ? () => onSelected(ProfilePanelDestination.profile)
                            : null,
                      ),
                      accent: true,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 28, 8, 12),
                      child: Text(
                        context.l10n.profileNavYourMusic,
                        style: type.labelLarge?.copyWith(
                          color: secondaryText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    group(
                      Column(
                        children: [
                          destination(
                            ProfilePanelDestination.statistics,
                            Icons.insights_outlined,
                            l10n.listeningStats,
                          ),
                          Divider(
                            height: 1,
                            indent: 70,
                            endIndent: 16,
                            color: outline,
                          ),
                          destination(
                            ProfilePanelDestination.recentListening,
                            Icons.history,
                            l10n.homeRecentlyPlayed,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    group(
                      destination(
                        ProfilePanelDestination.yearly,
                        Icons.auto_awesome_outlined,
                        l10n.listeningRewind,
                      ),
                      accent: true,
                    ),
                    const SizedBox(height: 24),
                    group(
                      destination(
                        ProfilePanelDestination.settings,
                        Icons.settings_outlined,
                        l10n.settingsTitle,
                      ),
                    ),
                    if (supportDonationUrl.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const SupportProjectCard(url: supportDonationUrl),
                    ],
                    const SizedBox(height: 12),
                    group(
                      destination(
                        ProfilePanelDestination.extensions,
                        Icons.extension_rounded,
                        l10n.settingsExtensions,
                        subtitle: l10n.profileNavAddonsSubtitle,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Semantics(
                      enabled: false,
                      label:
                          context.l10n.profileNavMessagesComingSoonUnavailable,
                      child: ExcludeSemantics(
                        child: ListTile(
                          key: const ValueKey('profile-panel-future'),
                          enabled: false,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          leading: Icon(
                            Icons.chat_bubble_outline,
                            color: colors.onSurface.withValues(alpha: .45),
                          ),
                          title: Text(
                            context.l10n.profileNavMessages,
                            style: TextStyle(
                              color: colors.onSurface.withValues(alpha: .45),
                            ),
                          ),
                          subtitle: Text(
                            context.l10n.profileNavComingSoon,
                            style: TextStyle(
                              color: colors.onSurface.withValues(alpha: .45),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: const BorderRadiusDirectional.only(
        topEnd: Radius.circular(28),
        bottomEnd: Radius.circular(28),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BorderDirectional(end: BorderSide(color: outline)),
        ),
        child: glass
            ? BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: kProfilePanelBlurSigma,
                  sigmaY: kProfilePanelBlurSigma,
                ),
                child: content,
              )
            : content,
      ),
    );
  }
}
