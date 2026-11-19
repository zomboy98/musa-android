import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/settings_group.dart';

const _channel = MethodChannel('musa/launcher_icon');
const _icons = <String, String>{
  'original': 'Original',
  'chrome': 'Cromo',
  'brushed': 'Metal',
  'glass': 'Cristal',
  'neon': 'Neón',
  'pearl': 'Nácar',
};

class LauncherIconSetting extends StatefulWidget {
  const LauncherIconSetting({super.key});

  @override
  State<LauncherIconSetting> createState() => _LauncherIconSettingState();
}

class _LauncherIconSettingState extends State<LauncherIconSetting> {
  String? _current;
  bool _busy = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) _read();
  }

  Future<void> _read() async {
    try {
      final value = await _channel.invokeMethod<String>('get');
      if (mounted) {
        setState(() {
          _current = value;
          _failed = !_icons.containsKey(value);
          _busy = false;
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    }
  }

  Future<void> _select(String id) async {
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<String>('set', {'id': id});
      await _read();
    } on PlatformException {
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    return SettingsGroup(
      children: [
        ListTile(
          leading: const Icon(Icons.apps),
          title: Text(context.l10n.launcherIconAppIcon),
          subtitle: Text(
            _failed
                ? context.l10n.launcherIconCouldNotReadOrChangeThe
                : context.l10n.launcherIconTheLauncherMayTakeTimeTo,
          ),
          trailing: _busy
              ? const CircularProgressIndicator()
              : const Icon(Icons.chevron_right),
          onTap: _busy ? null : () => _showChoices(context),
        ),
      ],
    );
  }

  void _showChoices(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                context.l10n.launcherIconAppIcon,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final entry in _icons.entries)
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    entry.key == 'original'
                        ? 'assets/images/musa-icon.png'
                        : 'assets/images/musa_icon_${entry.key}.png',
                    width: 48,
                    height: 48,
                  ),
                ),
                title: Text(switch (entry.key) {
                  'chrome' => context.l10n.launcherIconChrome,
                  'brushed' => context.l10n.launcherIconBrushed,
                  'glass' => context.l10n.launcherIconGlass,
                  'neon' => context.l10n.launcherIconNeon,
                  'pearl' => context.l10n.launcherIconPearl,
                  _ => context.l10n.launcherIconOriginal,
                }),
                selected: entry.key == _current,
                trailing: entry.key == _current
                    ? const Icon(Icons.check_circle)
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _select(entry.key);
                },
              ),
          ],
        ),
      ),
    );
  }
}
