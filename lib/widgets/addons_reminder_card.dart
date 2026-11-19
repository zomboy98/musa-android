import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String addonsRequestUrl = 'https://musa.heyshin.app/#descarga';
const String _dismissedKey = 'addons_reminder_dismissed';

/// Reminder shown while no add-on is installed, for people who skipped the
/// code step: where to get a code and where to enter it.
class AddonsReminderCard extends ConsumerStatefulWidget {
  const AddonsReminderCard({
    super.key,
    required this.onEnterCode,
    this.margin = EdgeInsets.zero,
  });

  final VoidCallback onEnterCode;
  final EdgeInsetsGeometry margin;

  @override
  ConsumerState<AddonsReminderCard> createState() => _AddonsReminderCardState();
}

class _AddonsReminderCardState extends ConsumerState<AddonsReminderCard> {
  bool _dismissed = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissed = prefs.getBool(_dismissedKey) ?? false;
      if (mounted) setState(() => _dismissed = dismissed);
    } catch (_) {
      if (mounted) setState(() => _dismissed = false);
    }
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_dismissedKey, true);
    } catch (_) {}
  }

  Future<void> _openSite() async {
    try {
      await launchUrl(
        Uri.parse(addonsRequestUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final ext = ref.watch(extensionProvider);
    if (_dismissed || ext.isLoading || ext.extensions.isNotEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: widget.margin,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration: BoxDecoration(
          color: colors.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_outlined, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.addonsReminderTitle,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: l10n.addonsCodeClose,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: _dismiss,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                l10n.addonsReminderBody,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _openSite,
                  child: Text(l10n.addonsReminderGetCode),
                ),
                TextButton(
                  onPressed: widget.onEnterCode,
                  child: Text(l10n.addonsReminderHaveCode),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
