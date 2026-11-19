import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/settings/music_preferences_page.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

Future<bool> showPlaybackProviderSetup(
  BuildContext context, {
  bool sourceNeedsAttention = false,
}) async =>
    await showAppModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          PlaybackProviderSetup(sourceNeedsAttention: sourceNeedsAttention),
    ) ??
    false;

enum _SetupFailure { restore, noSources }

class PlaybackProviderSetup extends ConsumerStatefulWidget {
  const PlaybackProviderSetup({super.key, this.sourceNeedsAttention = false});
  final bool sourceNeedsAttention;

  @override
  ConsumerState<PlaybackProviderSetup> createState() =>
      _PlaybackProviderSetupState();
}

class _PlaybackProviderSetupState extends ConsumerState<PlaybackProviderSetup> {
  bool _busy = false;
  _SetupFailure? _failure;

  String _failureText(_SetupFailure failure) => switch (failure) {
    _SetupFailure.restore => context.l10n.playbackSetupRestoreFailed,
    _SetupFailure.noSources => context.l10n.playbackSetupStillNoSources,
  };

  Future<void> _restore() async {
    final current = ref.read(extensionProvider);
    if (_busy || current.isLoading || !current.isInitialized) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref
          .read(extensionProvider.notifier)
          .installBundledExtensions(reconcilePreferences: false);
      if (!mounted) return;
      final result = ref.read(extensionProvider);
      setState(
        () => _failure = result.error != null
            ? _SetupFailure.restore
            : !result.extensions.any((ext) => ext.hasDownloadProvider)
            ? _SetupFailure.noSources
            : null,
      );
    } catch (_) {
      if (mounted) setState(() => _failure = _SetupFailure.restore);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSettings() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    await navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const MusicPreferencesPage()),
    );
    if (mounted) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final extensionState = ref.watch(extensionProvider);
    final hasSources = extensionState.extensions.any(
      (extension) => extension.hasDownloadProvider,
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.playbackSetupSetUpPlayback,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.sourceNeedsAttention
                  ? context.l10n.playbackSetupTheSourceCouldNotBeAccessed
                  : context.l10n.playbackSetupChooseInSettings,
            ),
            const SizedBox(height: 16),
            if (_busy || (!hasSources && extensionState.isLoading))
              const Center(child: CircularProgressIndicator())
            else if (!hasSources) ...[
              Text(context.l10n.playbackSetupNoAudioSourcesAreInstalled),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: extensionState.isInitialized ? _restore : null,
                child: Text(context.l10n.playbackSetupRestoreBuiltInSources),
              ),
              Text(
                context
                    .l10n
                    .playbackSetupRestorationTakesEffectImmediatelyCancelDoes,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_failure case final failure?) ...[
              const SizedBox(height: 12),
              Text(
                _failureText(failure),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(context.l10n.dialogCancel),
                ),
                FilledButton(
                  onPressed: _busy || extensionState.isLoading
                      ? null
                      : _openSettings,
                  child: Text(context.l10n.playbackSetupOpenSettings),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
