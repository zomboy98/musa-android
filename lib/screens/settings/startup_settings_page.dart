import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/settings_group.dart';

class StartupSettingsPage extends ConsumerWidget {
  const StartupSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.settingsStartup),
          SliverToBoxAdapter(
            child: SettingsGroup(
              connected: true,
              children: [
                SettingsSwitchItem(
                  icon: Icons.play_circle_outline,
                  title: context.l10n.startupAnimation,
                  subtitle: context.l10n.startupAnimationSubtitle,
                  value: settings.startupAnimation,
                  onChanged: notifier.setStartupAnimation,
                ),
                SettingsSwitchItem(
                  icon: Icons.volume_up_outlined,
                  title: context.l10n.startupSound,
                  subtitle: context.l10n.startupSoundSubtitle,
                  value: settings.startupSound,
                  onChanged: notifier.setStartupSound,
                  showDivider: false,
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}
