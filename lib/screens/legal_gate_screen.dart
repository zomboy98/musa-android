import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/app_version.dart';
import 'package:mornye/constants/build_profile.dart';
import 'package:mornye/constants/legal_links.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:url_launcher/url_launcher.dart';

typedef LegalUrlOpener = Future<void> Function(String url);

Future<void> openLegalUrl(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

class LegalBetaTag extends StatelessWidget {
  const LegalBetaTag({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          '${context.l10n.legalBetaTag} $musaPublicLabel',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

/// First-run step: the terms and the privacy policy must be accepted before
/// anything else. It is asked again whenever [legalPolicyVersion] changes.
class LegalGateScreen extends ConsumerStatefulWidget {
  const LegalGateScreen({super.key, this.onDecline, this.openUrl});

  final VoidCallback? onDecline;
  final LegalUrlOpener? openUrl;

  @override
  ConsumerState<LegalGateScreen> createState() => _LegalGateScreenState();
}

class _LegalGateScreenState extends ConsumerState<LegalGateScreen> {
  bool _accepted = false;
  bool _saving = false;

  Future<void> _continue() async {
    if (!_accepted || _saving) return;
    setState(() => _saving = true);
    await ref.read(settingsProvider.notifier).acceptLegal();
    if (mounted) setState(() => _saving = false);
  }

  void _decline() {
    final onDecline = widget.onDecline;
    if (onDecline != null) {
      onDecline();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final open = widget.openUrl ?? openLegalUrl;
    final points = [
      l10n.legalPoint1,
      l10n.legalPoint2,
      l10n.legalPoint3,
      l10n.legalPoint4,
      l10n.legalPoint5,
      l10n.legalPoint6,
      l10n.legalPoint7,
    ];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        l10n.legalGateTitle,
                        style: theme.textTheme.headlineSmall,
                      ),
                      if (isBetaBuild) const LegalBetaTag(),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(l10n.legalGateIntro, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 16),
                  for (final point in points)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 1, right: 10),
                            child: Text('•'),
                          ),
                          Expanded(
                            child: Text(
                              point,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      TextButton.icon(
                        key: const Key('legal-open-privacy'),
                        onPressed: () => open(legalPrivacyUrl),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(l10n.legalOpenPrivacy),
                      ),
                      TextButton.icon(
                        key: const Key('legal-open-terms'),
                        onPressed: () => open(legalTermsUrl),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(l10n.legalOpenTerms),
                      ),
                      TextButton.icon(
                        key: const Key('legal-read-here'),
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => LegalTextsScreen(openUrl: open),
                          ),
                        ),
                        icon: const Icon(Icons.article_outlined, size: 18),
                        label: Text(l10n.legalReadHere),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const Key('legal-accept-checkbox'),
                    value: _accepted,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (value) =>
                        setState(() => _accepted = value ?? false),
                    title: Text(l10n.legalAcceptCheckbox),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('legal-continue'),
                    onPressed: _accepted && !_saving ? _continue : null,
                    child: Text(l10n.legalContinue),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('legal-decline'),
                    onPressed: _decline,
                    child: Text(l10n.legalDecline),
                  ),
                  Text(
                    l10n.legalDeclineNote,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Local copy of both texts, readable without a connection.
class LegalTextsScreen extends StatelessWidget {
  const LegalTextsScreen({super.key, this.openUrl});

  final LegalUrlOpener? openUrl;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final open = openUrl ?? openLegalUrl;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.legalTextsTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.legalTermsHeading, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(l10n.legalTermsBody, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 24),
              Text(
                l10n.legalPrivacyHeading,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(l10n.legalPrivacyBody, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => open(legalPrivacyUrl),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.legalOpenPrivacy),
                  ),
                  TextButton.icon(
                    onPressed: () => open(legalTermsUrl),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.legalOpenTerms),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
