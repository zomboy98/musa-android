import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/sources_page.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/utils/download_quality_options.dart';
import 'package:mornye/utils/playback_quality_options.dart';
import 'package:mornye/utils/quality_selection.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/download_service_picker.dart';

class MusicPreferencesPage extends StatelessWidget {
  const MusicPreferencesPage({super.key, this.expandSectionsForTest});

  /// Forces every section open or closed; null uses the real defaults.
  @visibleForTesting
  final bool? expandSectionsForTest;

  @override
  Widget build(BuildContext context) {
    final expandAll = expandSectionsForTest;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.listenTitle),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              24 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 12),
                const _SourcesLink(),
                _SectionHeader(
                  title: context.l10n.listenMediaQualityTitle,
                  hint: context.l10n.listenMediaQualityHint,
                ),
                _StreamingQualitySection(expanded: expandAll),
                const _Hairline(),
                _DownloadQualitySection(expanded: expandAll),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

const _openDuration = Duration(milliseconds: 180);

Color _line(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.32);

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, thickness: 0.5, color: _line(context));
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 28, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              height: 1.3,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandableRow extends StatefulWidget {
  const _ExpandableRow({
    required this.id,
    required this.title,
    required this.summary,
    required this.child,
    this.initiallyExpanded = false,
  });

  final String id;
  final String title;
  final String summary;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<_ExpandableRow> createState() => _ExpandableRowState();
}

class _ExpandableRowState extends State<_ExpandableRow> {
  late bool _expanded = widget.initiallyExpanded;
  late bool _built = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          button: true,
          expanded: _expanded,
          label: '${widget.title}, ${widget.summary}',
          hint: _expanded
              ? context.l10n.musicPrefsTapToCollapse
              : context.l10n.musicPrefsTapToExpand,
          excludeSemantics: true,
          onTap: _toggle,
          child: InkWell(
            key: ValueKey('section_header_${widget.id}'),
            onTap: _toggle,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 60),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (widget.summary.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                widget.summary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 12.5,
                                  color: muted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      curve: Curves.easeOutCubic,
                      turns: _expanded ? 0.5 : 0,
                      duration: _openDuration,
                      child: Icon(
                        Symbols.expand_more_rounded,
                        weight: 300,
                        size: 22,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ClipRect(
          child: AnimatedSize(
            duration: _openDuration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _built
                ? Visibility(
                    visible: _expanded,
                    maintainState: true,
                    child: RepaintBoundary(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: widget.child,
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ),
      ],
    );
  }

  void _toggle() => setState(() {
    _expanded = !_expanded;
    _built = _built || _expanded;
  });
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          height: 1.3,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: onTap != null,
      selected: selected,
      excludeSemantics: true,
      label: subtitle.isEmpty ? title : '$title, $subtitle',
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 12,
                              height: 1.3,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 22,
                  child: AnimatedOpacity(
                    opacity: selected ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: Icon(
                      Symbols.check_rounded,
                      weight: 300,
                      size: 20,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourcesLink extends StatelessWidget {
  const _SourcesLink();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      key: const ValueKey('listen_sources_link'),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SourcesPage())),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.sourcesTitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    context.l10n.sourcesEntryHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Symbols.chevron_right_rounded,
              weight: 300,
              size: 22,
              color: muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _ListenQualityBase {
  static ({Extension? provider, List<QualityOption> options}) of(
    WidgetRef ref,
  ) {
    final view = ref.watch(extensionProvider.select(extensionQualityView));
    final (defaultService, autoFallback) = ref.watch(
      settingsProvider.select((s) => (s.defaultService, s.autoFallback)),
    );
    final service = resolveQualityService(view, defaultService, autoFallback);
    final provider = audioProviders(view.$1, view.$2)
        .where((e) => e.id.trim().toLowerCase() == service.trim().toLowerCase())
        .firstOrNull;
    return (
      provider: provider,
      options: provider == null
          ? const []
          : distinctDownloadQualityOptions(provider.qualityOptions).toList(),
    );
  }
}

class _StreamingQualitySection extends ConsumerStatefulWidget {
  const _StreamingQualitySection({this.expanded});

  final bool? expanded;

  @override
  ConsumerState<_StreamingQualitySection> createState() =>
      _StreamingQualitySectionState();
}

class _StreamingQualitySectionState
    extends ConsumerState<_StreamingQualitySection> {
  String? _reconciledFor;

  @override
  Widget build(BuildContext context) {
    final (:provider, :options) = _ListenQualityBase.of(ref);
    final saved = ref.watch(
      settingsProvider.select((s) => s.playbackQuality.trim()),
    );
    if (provider != null && _reconciledFor != provider.id) {
      _reconciledFor = provider.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        reconcileListenQualities(
          ref.read(settingsProvider.notifier),
          ref.read(settingsProvider),
          provider,
        );
      });
    }
    final isAuto = saved.isEmpty || saved == autoLightStreamingQuality;
    final matched = isAuto ? null : findDownloadQualityOption(options, saved);
    final single = options.length == 1 ? options.single : null;
    final summary = single != null
        ? qualityOptionDisplay(context, single, extensionId: provider?.id).label
        : matched == null
        ? context.l10n.musicPrefsLightAutomatic
        : qualityOptionDisplay(
            context,
            matched,
            extensionId: provider?.id,
          ).label;
    final notifier = ref.read(settingsProvider.notifier);
    return _ExpandableRow(
      id: 'streaming',
      title: context.l10n.musicPrefsStreamingQuality,
      summary: summary,
      initiallyExpanded: widget.expanded ?? false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Hint(context.l10n.musicPrefsQualityRequestedFromTheProviderTo),
          if (single != null)
            _Choice(
              key: const ValueKey('streaming_quality_single'),
              title: qualityOptionDisplay(
                context,
                single,
                extensionId: provider?.id,
              ).label,
              subtitle: qualityOptionDisplay(
                context,
                single,
                extensionId: provider?.id,
              ).description,
              selected: true,
              onTap: null,
            )
          else
            Column(
              key: const ValueKey('streaming_quality_section'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Choice(
                  key: const ValueKey('streaming_quality_auto_light'),
                  title: context.l10n.musicPrefsLightAutomaticAacOpus,
                  subtitle: context.l10n.musicPrefsRequestsTheLightFormatOfThe,
                  selected: matched == null,
                  onTap: () =>
                      notifier.setPlaybackQuality(autoLightStreamingQuality),
                ),
                for (final quality in options)
                  if (qualityOptionDisplay(
                        context,
                        quality,
                        extensionId: provider?.id,
                      )
                      case final display)
                    _Choice(
                      key: ValueKey('streaming_quality_${quality.id}'),
                      title: display.label,
                      subtitle: display.description,
                      selected: matched?.id == quality.id,
                      onTap: () => notifier.setPlaybackQuality(quality.id),
                    ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DownloadQualitySection extends ConsumerStatefulWidget {
  const _DownloadQualitySection({this.expanded});

  final bool? expanded;

  @override
  ConsumerState<_DownloadQualitySection> createState() =>
      _DownloadQualitySectionState();
}

class _DownloadQualitySectionState
    extends ConsumerState<_DownloadQualitySection> {
  @override
  Widget build(BuildContext context) {
    final (:provider, :options) = _ListenQualityBase.of(ref);
    final (defaultService, audioQuality, byProvider) = ref.watch(
      settingsProvider.select(
        (s) => (s.defaultService, s.audioQuality, s.downloadQualityByProvider),
      ),
    );
    if (provider == null || options.isEmpty) {
      return _ExpandableRow(
        id: 'download',
        title: context.l10n.musicPrefsDownloadQuality,
        summary: '',
        initiallyExpanded: widget.expanded ?? false,
        child: _Hint(context.l10n.musicPrefsSelectAProviderWithQualityOptions),
      );
    }
    final group = PlaybackQualityGroup(provider, options);
    final selected = downloadQualitySelection(
      defaultService,
      audioQuality,
      byProvider,
      group,
    );
    final single = options.length == 1 ? options.single : null;
    return _ExpandableRow(
      id: 'download',
      title: context.l10n.musicPrefsDownloadQuality,
      summary: qualityOptionDisplay(
        context,
        selected,
        extensionId: provider.id,
      ).label,
      initiallyExpanded: widget.expanded ?? false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Hint(context.l10n.musicPrefsQualityRequestedFromTheProviderWhen),
          if (single != null)
            _Choice(
              key: const ValueKey('download_quality_single'),
              title: qualityOptionDisplay(
                context,
                single,
                extensionId: provider.id,
              ).label,
              subtitle: qualityOptionDisplay(
                context,
                single,
                extensionId: provider.id,
              ).description,
              selected: true,
              onTap: null,
            )
          else ...[
            for (final quality in options)
              if (qualityOptionDisplay(
                    context,
                    quality,
                    extensionId: provider.id,
                  )
                  case final display)
                _Choice(
                  key: ValueKey(
                    'download_quality_${provider.id}_${quality.id}',
                  ),
                  title: display.label,
                  subtitle: display.description,
                  selected: selected.id == quality.id,
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setAudioQualityForProvider(
                        provider.id,
                        manifestQualityId(quality.id),
                        option: quality,
                      ),
                ),
          ],
        ],
      ),
    );
  }
}
