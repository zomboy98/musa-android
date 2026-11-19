import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/utils/download_quality_options.dart';
import 'package:mornye/utils/playback_quality_options.dart';
import 'package:mornye/utils/quality_selection.dart';
import 'package:mornye/widgets/download_service_picker.dart'
    show qualityOptionDisplay;

/// Listening step of the first-run setup: provider, streaming quality and
/// download quality, with the same settings and defaults as the Listening
/// page. The default provider is preselected; the qualities are exactly the
/// ones it declares. Until the real options arrive (first launch) generic
/// defaults are shown as selected and nothing is written.
class SetupQualityStep extends ConsumerStatefulWidget {
  const SetupQualityStep({super.key, this.enabled = true});

  /// False while the setup is saving a step; taps are ignored.
  final bool enabled;

  @override
  ConsumerState<SetupQualityStep> createState() => _SetupQualityStepState();
}

class _SetupQualityStepState extends ConsumerState<SetupQualityStep> {
  String? _reconciledFor;
  bool _gaveUpWaiting = false;
  Timer? _waitTimer;

  @override
  void initState() {
    super.initState();
    // If providers never report, stop spinning and keep the generic defaults.
    _waitTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _gaveUpWaiting = true);
    });
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final view = ref.watch(extensionProvider.select(extensionQualityView));
    final (
      defaultService,
      autoFallback,
      savedStreaming,
      audioQuality,
      byProvider,
    ) = ref.watch(
      settingsProvider.select(
        (s) => (
          s.defaultService,
          s.autoFallback,
          s.playbackQuality.trim(),
          s.audioQuality,
          s.downloadQualityByProvider,
        ),
      ),
    );
    final service = resolveQualityService(view, defaultService, autoFallback);
    final groups = playbackQualityGroups(
      view.$1,
      configuredService: service,
      providerPriority: view.$2,
    );
    final group =
        groups
            .where(
              (g) =>
                  g.extension.id.trim().toLowerCase() ==
                  service.trim().toLowerCase(),
            )
            .firstOrNull ??
        groups.firstOrNull;
    final loading = group == null && !_gaveUpWaiting && (!view.$3 || view.$4);

    final providers = audioProviders(view.$1, view.$2);
    if (group != null && _reconciledFor != group.extension.id) {
      final target = group.extension;
      _reconciledFor = target.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        reconcileListenQualities(
          ref.read(settingsProvider.notifier),
          ref.read(settingsProvider),
          target,
        );
      });
    }
    final isAuto =
        savedStreaming.isEmpty || savedStreaming == autoLightStreamingQuality;
    final matched = isAuto || group == null
        ? null
        : findDownloadQualityOption(group.options, savedStreaming);
    final singleOption = group != null && group.options.length == 1
        ? group.options.single
        : null;
    final streamingSelected =
        singleOption?.id ?? matched?.id ?? autoLightStreamingQuality;
    final downloadSelected = group == null
        ? null
        : downloadQualitySelection(
            defaultService,
            audioQuality,
            byProvider,
            group,
          );

    void pickStreaming(String id) {
      if (!widget.enabled) return;
      ref.read(settingsProvider.notifier).setPlaybackQuality(id);
    }

    void pickDownload(QualityOption option) {
      if (!widget.enabled || group == null) return;
      // Same storage and meaning as Download settings.
      ref
          .read(settingsProvider.notifier)
          .setAudioQualityForProvider(
            group.extension.id,
            manifestQualityId(option.id),
            option: option,
          );
    }

    void pickProvider(Extension provider) {
      if (!widget.enabled) return;
      ref.read(extensionProvider.notifier).selectPlaybackProvider(provider.id);
      reconcileListenQualities(
        ref.read(settingsProvider.notifier),
        ref.read(settingsProvider),
        provider,
      );
    }

    final providerTiles = <Widget>[
      for (final provider in providers)
        _QualityTile(
          key: ValueKey('setup_provider_${provider.id}'),
          title: provider.displayName,
          subtitle: '',
          selected:
              group != null &&
              provider.id.trim().toLowerCase() ==
                  group.extension.id.trim().toLowerCase(),
          onTap: () => pickProvider(provider),
        ),
    ];
    final streamingTiles = <Widget>[
      if (singleOption == null)
        _QualityTile(
          key: const ValueKey('setup_streaming_auto_light'),
          title: l10n.setupQualityLightAuto,
          subtitle: l10n.setupQualityLightAutoHint,
          selected: streamingSelected == autoLightStreamingQuality,
          onTap: () => pickStreaming(autoLightStreamingQuality),
        ),
      if (group != null)
        for (final option in group.options)
          if (qualityOptionDisplay(
                context,
                option,
                extensionId: group.extension.id,
              )
              case final display)
            _QualityTile(
              key: ValueKey('setup_streaming_${option.id}'),
              title: display.label,
              subtitle: display.description,
              selected:
                  matched != null &&
                  sameManifestQualityId(option.id, matched.id),
              onTap: () => pickStreaming(option.id),
            ),
    ];
    final downloadTiles = <Widget>[
      if (group == null)
        _QualityTile(
          key: const ValueKey('setup_download_best_available'),
          title: l10n.setupQualityBestAvailable,
          subtitle: l10n.setupQualityBestAvailableHint,
          selected:
              audioQuality.trim().isEmpty ||
              sameManifestQualityId(audioQuality, 'best'),
          onTap: () {
            if (!widget.enabled) return;
            ref.read(settingsProvider.notifier).setAudioQuality('best');
          },
        )
      else
        for (final option in group.options)
          if (qualityOptionDisplay(
                context,
                option,
                extensionId: group.extension.id,
              )
              case final display)
            _QualityTile(
              key: ValueKey('setup_download_${option.id}'),
              title: display.label,
              subtitle: display.description,
              selected: sameManifestQualityId(option.id, downloadSelected!.id),
              onTap: () => pickDownload(option),
            ),
    ];

    final loadingNote = AnimatedSize(
      curve: Curves.easeOutCubic,
      duration: AppMotion.effectsFast(
        context,
        const AppMotionSpec(Duration(milliseconds: 200), Curves.easeOut),
      ).duration,
      alignment: Alignment.topCenter,
      child: loading
          ? Padding(
              key: const ValueKey('setup_quality_loading'),
              padding: const EdgeInsets.only(bottom: 16),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.setupQualityLoading,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox(width: double.infinity),
    );

    final gaveUpNote = _gaveUpWaiting && group == null
        ? Padding(
            key: const ValueKey('setup_quality_gave_up'),
            padding: const EdgeInsets.only(bottom: 16),
            child: Semantics(
              liveRegion: true,
              child: Text(
                l10n.setupQualityGaveUp,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          )
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WaitNotice(
          title: l10n.setupQualityWaitTitle,
          text: l10n.setupQualityWaitNotice,
        ),
        const SizedBox(height: 24),
        loadingNote,
        ?gaveUpNote,
        if (providerTiles.isNotEmpty) ...[
          _SectionHeader(
            title: l10n.settingsMainProvider,
            subtitle: l10n.settingsMainProviderSubtitle,
          ),
          _TileGroup(
            key: const ValueKey('setup_provider_list'),
            children: providerTiles,
          ),
          const SizedBox(height: 24),
        ],
        _SectionHeader(
          title: l10n.musicPrefsStreamingQuality,
          subtitle: l10n.setupQualityStreamingHint,
        ),
        _TileGroup(
          key: const ValueKey('setup_streaming_quality_list'),
          children: streamingTiles,
        ),
        const SizedBox(height: 24),
        _SectionHeader(
          title: l10n.musicPrefsDownloadQuality,
          subtitle: l10n.setupQualityDownloadHint,
        ),
        _TileGroup(
          key: const ValueKey('setup_download_quality_list'),
          children: downloadTiles,
        ),
      ],
    );
  }
}

class _WaitNotice extends StatelessWidget {
  const _WaitNotice({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      label: '$title. $text',
      excludeSemantics: true,
      child: DecoratedBox(
        key: const ValueKey('setup_quality_wait_notice'),
        decoration: BoxDecoration(
          color: colors.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                key: const ValueKey('setup_quality_wait_notice_accent'),
                width: 3,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.7),
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(12),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        header: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TileGroup extends StatelessWidget {
  const _TileGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            child,
          ],
        ],
      ),
    );
  }
}

class _QualityTile extends StatelessWidget {
  const _QualityTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final motion = AppMotion.effectsFast(
      context,
      const AppMotionSpec(Duration(milliseconds: 180), Curves.easeOut),
    );
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : motion.duration;
    final fg = selected ? colors.onPrimaryContainer : colors.onSurface;
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      selected: selected,
      checked: selected,
      label: subtitle.isEmpty ? title : '$title. $subtitle',
      onTap: onTap,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: duration,
        curve: motion.curve,
        decoration: BoxDecoration(
          color: selected
              ? colors.primaryContainer
              : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: fg,
                            ),
                          ),
                          if (subtitle.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: selected
                                    ? colors.onPrimaryContainer
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    AnimatedOpacity(
                      curve: Curves.easeOutCubic,
                      duration: duration,
                      opacity: selected ? 1 : 0,
                      child: Icon(Icons.check_circle, size: 22, color: fg),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
