import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/settings_group.dart' show VisionGlassCard;
import 'package:url_launcher/url_launcher.dart';

typedef SupportLinkLauncher = Future<bool> Function(Uri uri);

Future<bool> _launchExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

class SupportProjectCard extends StatelessWidget {
  const SupportProjectCard({
    super.key,
    required this.url,
    this.launcher = _launchExternally,
  });

  final String url;
  final SupportLinkLauncher launcher;

  static const Color _amber = Color(0xFFE0A93B);
  static const Color _gold = Color(0xFFF2C36B);
  static const Color _deepAmber = Color(0xFF8F5E00);

  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(url.trim());
    var opened = false;
    if (uri != null && uri.hasScheme) {
      try {
        opened = await launcher(uri);
      } catch (_) {
        opened = false;
      }
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.announcementUnableToOpenLink)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final accent = dark ? _gold : _deepAmber;
    const radius = 24.0;
    return Semantics(
      container: true,
      button: true,
      link: true,
      label: l10n.profileSupportSemanticLabel,
      excludeSemantics: true,
      onTap: () => _open(context),
      child: VisionGlassCard(
        radius: radius,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _amber.withValues(alpha: dark ? .16 : .14),
                      _amber.withValues(alpha: .02),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: _amber.withValues(alpha: dark ? .28 : .30),
                  ),
                ),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: const ValueKey('profile-panel-support'),
                borderRadius: BorderRadius.circular(radius),
                onTap: () => _open(context),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 72),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: _amber.withValues(alpha: .18),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _amber.withValues(alpha: .30),
                            ),
                          ),
                          child: Icon(
                            Icons.favorite_rounded,
                            color: accent,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                l10n.profileSupportTitle,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l10n.profileSupportSubtitle,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.onSurface.withValues(
                                    alpha: .72,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.arrow_outward_rounded,
                          size: 20,
                          color: accent.withValues(alpha: .85),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
