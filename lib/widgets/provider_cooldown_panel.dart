import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/provider_cooldown_provider.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/widgets/settings_group.dart';

class ProviderCooldownPanel extends ConsumerStatefulWidget {
  const ProviderCooldownPanel({super.key});

  @override
  ConsumerState<ProviderCooldownPanel> createState() =>
      _ProviderCooldownPanelState();
}

class _ProviderCooldownPanelState extends ConsumerState<ProviderCooldownPanel> {
  bool _expanded = false;

  String _providerName(String id, List<Extension> extensions) {
    for (final extension in extensions) {
      final extensionId = extension.id.toLowerCase();
      if (extensionId == id || extensionId.endsWith('.$id')) {
        final name = extension.displayName.trim();
        return name.isEmpty ? id : name;
      }
    }
    return id;
  }

  String _time(BuildContext context, Duration remaining) {
    final l10n = context.l10n;
    final total = remaining.inSeconds < 1 ? 1 : remaining.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    if (hours > 0) return l10n.extensionsCooldownHoursMinutes(hours, minutes);
    if (minutes > 0) {
      return l10n.extensionsCooldownMinutesSeconds(minutes, total % 60);
    }
    return l10n.extensionsCooldownSeconds(total);
  }

  String _clock(DateTime moment) {
    final local = moment.toLocal();
    final hours = local.hour.toString().padLeft(2, '0');
    final minutes = local.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }

  String _failure(BuildContext context, ProviderFailure failure) {
    final l10n = context.l10n;
    var text = l10n.extensionsLastFailure(failure.type, _clock(failure.at));
    final code = failure.httpCode;
    final retry = failure.retryAfterSeconds;
    if (code != null) {
      text = l10n.extensionsLastFailureHttp(text, code);
    } else if (retry != null) {
      text = l10n.extensionsLastFailureRetry(text, retry);
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final muted = theme.colorScheme.onSurfaceVariant;
    final children = <Widget>[
      InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.hourglass_bottom, color: muted),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  l10n.extensionsCooldownSection,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
      ),
    ];
    if (_expanded) {
      final extensions = ref.watch(extensionProvider).extensions;
      final status =
          ref.watch(providerStatusProvider).value ?? const ProviderStatusView();
      final ids = {...status.until.keys, ...status.failures.keys}.toList()
        ..sort();
      final lines = <String>[];
      final failureLines = <String>[];
      for (final id in ids) {
        final until = status.until[id];
        final failure = status.failures[id];
        final name = _providerName(id, extensions);
        if (until != null) {
          final left = status.remaining[id] ?? Duration.zero;
          lines.add(
            l10n.extensionsCooldownEntry(
              name,
              l10n.extensionsCooldownPausedUntil(
                _clock(until),
                _time(context, left),
              ),
            ),
          );
        } else if (failure != null) {
          failureLines.add(
            l10n.extensionsCooldownEntry(name, _failure(context, failure)),
          );
        }
      }
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (lines.isEmpty)
                Text(l10n.extensionsCooldownNone)
              else
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(line),
                  ),
              const SizedBox(height: 12),
              Text(
                l10n.extensionsCooldownExplanation,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              if (failureLines.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  l10n.extensionsLastFailuresHeading,
                  style: theme.textTheme.titleSmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 6),
                for (final line in failureLines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      line,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    }
    return SettingsGroup(connected: true, children: children);
  }
}
