import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/plugin_code_api.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/plugin_code_provider.dart';
import 'package:mornye/services/plugin_code_service.dart';
import 'package:mornye/utils/adaptive_layout.dart';

String pluginCodeFailureMessage(AppLocalizations l10n, PluginCodeFailure f) =>
    switch (f) {
      PluginCodeFailure.invalidFormat ||
      PluginCodeFailure.notFound => l10n.addonsCodeInvalid,
      PluginCodeFailure.network => l10n.addonsCodeNetworkError,
      PluginCodeFailure.malformed => l10n.addonsCodeMalformedError,
      _ => l10n.addonsCodeServerError,
    };

String pluginCodeItemReason(AppLocalizations l10n, PluginCodeFailure? f) =>
    switch (f) {
      PluginCodeFailure.hashMismatch => l10n.addonsCodeReasonHash,
      PluginCodeFailure.insecureUrl => l10n.addonsCodeReasonInsecure,
      PluginCodeFailure.tooLarge => l10n.addonsCodeReasonTooLarge,
      PluginCodeFailure.installFailed => l10n.addonsCodeReasonInstall,
      PluginCodeFailure.timeout => l10n.addonsCodeReasonTimeout,
      _ => l10n.addonsCodeReasonGeneric,
    };

List<String> pluginCodeReportLines(
  AppLocalizations l10n,
  List<PluginCodeItemResult> results,
) => [
  for (final result in results)
    switch (result.outcome) {
      PluginCodeOutcome.added => l10n.addonsCodeResultAdded(result.item.name),
      PluginCodeOutcome.updated => l10n.addonsCodeResultUpdated(
        result.item.name,
      ),
      PluginCodeOutcome.alreadyAdded => l10n.addonsCodeResultAlreadyAdded(
        result.item.name,
      ),
      PluginCodeOutcome.failed => l10n.addonsCodeResultFailed(
        result.item.name,
        pluginCodeItemReason(l10n, result.failure),
      ),
    },
];

class PluginCodeCard extends ConsumerStatefulWidget {
  const PluginCodeCard({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<PluginCodeCard> createState() => _PluginCodeCardState();
}

class _PluginCodeCardState extends ConsumerState<PluginCodeCard> {
  late final TextEditingController _controller = TextEditingController(
    text: ref.read(pluginCodeRedeemProvider).input,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final state = ref.read(pluginCodeRedeemProvider);
    if (state.running) return;
    final notifier = ref.read(pluginCodeRedeemProvider.notifier);
    notifier.setInput(_controller.text);
    unawaited(notifier.redeem());
  }

  String? _errorText(AppLocalizations l10n, PluginCodeRedeemState state) {
    final failure = state.failure;
    if (state.phase != PluginCodePhase.failed || failure == null) return null;
    return pluginCodeFailureMessage(l10n, failure);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(pluginCodeRedeemProvider);
    ref.listen<PluginCodeRedeemState>(pluginCodeRedeemProvider, (
      previous,
      next,
    ) {
      if (previous?.running == true &&
          !next.running &&
          next.input != _controller.text) {
        _controller.text = next.input;
      }
    });
    final busy = state.running;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.embedded) ...[
          Text(l10n.addonsCodeTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            l10n.addonsCodeHelp,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('plugin-code-field'),
                controller: _controller,
                enabled: !busy,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: pluginCodeMaxLength,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                  TextInputFormatter.withFunction(
                    (old, value) =>
                        value.copyWith(text: value.text.toUpperCase()),
                  ),
                ],
                decoration: InputDecoration(
                  labelText: l10n.addonsCodeHint,
                  errorText: _errorText(l10n, state),
                  counterText: '',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) {
                  final notifier = ref.read(pluginCodeRedeemProvider.notifier);
                  notifier.setInput(value);
                  if (state.phase == PluginCodePhase.failed) {
                    notifier.dismiss();
                  }
                },
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: FilledButton(
                key: const ValueKey('plugin-code-add'),
                onPressed: busy ? null : _submit,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.addonsCodeAdd),
              ),
            ),
          ],
        ),
        if (busy) ...[
          const SizedBox(height: 8),
          Text(
            l10n.addonsCodeProgress(
              state.current == 0 ? 1 : state.current,
              state.total == 0 ? 1 : state.total,
            ),
            key: const ValueKey('plugin-code-progress'),
            style: theme.textTheme.bodySmall,
          ),
          if (state.currentName != null)
            Text(
              state.currentName!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: state.total == 0
                ? null
                : (state.current - 1 + 0.5) / state.total,
          ),
        ],
        if (state.phase == PluginCodePhase.done) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.addonsCodeResultTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (!widget.embedded)
                TextButton(
                  key: const ValueKey('plugin-code-dismiss'),
                  onPressed: ref
                      .read(pluginCodeRedeemProvider.notifier)
                      .dismiss,
                  child: Text(l10n.addonsCodeClose),
                ),
            ],
          ),
          Column(
            key: const ValueKey('plugin-code-results'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in pluginCodeReportLines(l10n, state.results))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(line),
                ),
            ],
          ),
        ],
      ],
    );
    // Progress and results appear and disappear: animate the height instead
    // of snapping, so the page below does not jump.
    final body = AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: content,
    );
    if (widget.embedded) return body;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16 + wideListInset(context),
        8,
        16 + wideListInset(context),
        8,
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
        ),
        child: body,
      ),
    );
  }
}
