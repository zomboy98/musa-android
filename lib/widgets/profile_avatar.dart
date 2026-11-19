import 'package:mornye/widgets/guided_tour/guided_tour_anchor.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_anchors.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/app_update_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/settings/profile_settings_page.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/widgets/profile_navigation_panel.dart';

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    this.name = '',
    this.photoPath,
    this.photo,
    this.size = 40,
  });

  final String name;
  final String? photoPath;
  final Uint8List? photo;
  final double size;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // ListTile can constrain height more than width. Keep the clipped
        // image square even when the surrounding slot is rectangular.
        final diameter = constraints.biggest.shortestSide.clamp(0.0, size);
        return Align(
          widthFactor: 1,
          heightFactor: 1,
          child: _buildAvatar(context, diameter),
        );
      },
    );
  }

  Widget _buildAvatar(BuildContext context, double diameter) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: scheme.primaryContainer,
      child: Center(
        child: name.trim().isEmpty
            ? Icon(
                Icons.person,
                size: diameter * 0.55,
                color: scheme.onPrimaryContainer,
              )
            : Text(
                name.trim().characters.first.toUpperCase(),
                style: TextStyle(
                  fontSize: diameter * 0.42,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
      ),
    );
    return ExcludeSemantics(
      child: ClipOval(
        child: SizedBox.square(
          dimension: diameter,
          child: photo != null
              ? Image.memory(
                  photo!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                )
              : photoPath != null
              ? Image.file(
                  File(photoPath!),
                  fit: BoxFit.cover,
                  cacheWidth:
                      (diameter * MediaQuery.devicePixelRatioOf(context))
                          .ceil(),
                  errorBuilder: (_, _, _) => fallback,
                )
              : fallback,
        ),
      ),
    );
  }
}

class HomeProfileButton extends ConsumerStatefulWidget {
  const HomeProfileButton({super.key});

  @override
  ConsumerState<HomeProfileButton> createState() => _HomeProfileButtonState();
}

class _HomeProfileButtonState extends ConsumerState<HomeProfileButton> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    if (!context.isMornye) {
      ShellNavigationService.requestTab(ShellTab.settings);
      return;
    }
    _opening = true;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final profile = await ref.read(userProfileProvider.future);
      if (!mounted) return;
      final destination = await showMusaProfilePanel(
        context,
        name: profile.name,
        profileAvailable: true,
        avatar: ProfileAvatar(
          name: profile.name,
          photoPath: profile.photoPath,
          size: 52,
        ),
      );
      if (!mounted || destination == null) return;
      if (destination == ProfilePanelDestination.settings) {
        ShellNavigationService.requestTab(ShellTab.settings);
        return;
      }
      final page = switch (destination) {
        ProfilePanelDestination.profile => ProfileSettingsPage(
          profile: profile,
        ),
        ProfilePanelDestination.statistics ||
        ProfilePanelDestination.recentListening =>
          const ListeningStatisticsScreen(),
        ProfilePanelDestination.yearly => const ListeningStatisticsScreen(
          initialYearly: true,
        ),
        ProfilePanelDestination.extensions => const ExtensionsPage(),
        ProfilePanelDestination.settings => null,
      };
      if (page != null) {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => page));
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(userProfileProvider).value;
    return TourAnchor(
      target: GuidedTourTarget.profile,
      child: IconButton(
        tooltip: context.isMornye
            ? context.l10n.profileAvatarOpenProfilePanel
            : context.l10n.settingsTitle,
        iconSize: 44,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
        visualDensity: VisualDensity.standard,
        onPressed: _open,
        icon: Badge(
          smallSize: 10,
          isLabelVisible: ref.watch(
            appUpdateProvider.select((s) => s.hasOffer),
          ),
          child: ProfileAvatar(
            name: profile?.name ?? '',
            photoPath: profile?.photoPath,
            size: 44,
          ),
        ),
      ),
    );
  }
}
