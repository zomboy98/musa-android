import 'package:mornye/widgets/guided_tour/guided_tour_anchor.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_anchors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/repo_tab.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/settings/lyrics_provider_priority_page.dart';
import 'package:mornye/widgets/plugin_code_card.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/extension_error_message.dart';
import 'package:mornye/utils/lyrics_provider_names.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/utils/quality_selection.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/home_feed_region_setting.dart';
import 'package:mornye/widgets/provider_cooldown_panel.dart';
import 'package:mornye/widgets/provider_icon.dart';
import 'package:mornye/widgets/search_region_settings.dart';
import 'package:mornye/widgets/settings_group.dart';

part 'sources_page_widgets.dart';

/// The two ordered lists, with the saved order first and anything installed
/// but not yet listed appended.
@visibleForTesting
List<String> orderedSources(List<String> saved, List<String> available) {
  final allowed = available.toSet();
  final result = <String>[
    for (final id in saved)
      if (allowed.contains(id)) id,
  ];
  for (final id in available) {
    if (!result.contains(id)) result.add(id);
  }
  return result.toSet().toList();
}

/// Fallback switch state: a null saved list means every provider may serve.
@visibleForTesting
List<String>? fallbackIdsAfterToggle(
  List<String> audioOrder,
  List<String>? saved,
  String id,
  bool enabled,
) {
  final selected = <String>[
    for (final other in audioOrder)
      if (other == id ? enabled : (saved == null || saved.contains(other)))
        other,
  ];
  return selected.length == audioOrder.length ? null : selected;
}

class SourcesPage extends ConsumerStatefulWidget {
  const SourcesPage({super.key});

  @override
  ConsumerState<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends ConsumerState<SourcesPage> {
  List<String>? _musicLocal;
  List<String>? _audioLocal;
  bool _musicRecommended = true;
  bool _audioRecommended = true;
  bool _advancedOpen = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final notifier = ref.read(extensionProvider.notifier);
    if (!ref.read(extensionProvider).isInitialized) {
      try {
        await notifier.ensureInitialized();
      } catch (_) {}
    }
    await _refreshFlags();
  }

  Future<void> _refreshFlags() async {
    final flags = await ref
        .read(extensionProvider.notifier)
        .recommendedOrderFlags();
    if (!mounted) return;
    setState(() {
      _musicRecommended = flags.metadata;
      _audioRecommended = flags.audio;
    });
  }

  List<String> _musicOrder(ExtensionState state) {
    return _musicLocal ??
        orderedSources(
          state.metadataProviderPriority,
          ref.read(extensionProvider.notifier).getAllMetadataProviders(),
        );
  }

  List<String> _audioOrder(ExtensionState state) {
    return _audioLocal ??
        orderedSources(
          state.providerPriority,
          ref.read(extensionProvider.notifier).getAllDownloadProviders(),
        );
  }

  void _failed() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.sourcesSaveFailed)));
  }

  Future<void> _reorderMusic(List<String> current, int from, int to) async {
    final next = List<String>.of(current);
    next.insert(to, next.removeAt(from));
    setState(() => _musicLocal = next);
    final saved = await ref
        .read(extensionProvider.notifier)
        .setMetadataProviderPriority(next);
    if (!mounted) return;
    setState(() => _musicLocal = null);
    if (!saved) _failed();
    await _refreshFlags();
  }

  Future<void> _reorderAudio(List<String> current, int from, int to) async {
    final next = List<String>.of(current);
    next.insert(to, next.removeAt(from));
    setState(() => _audioLocal = next);
    final saved = await ref
        .read(extensionProvider.notifier)
        .setProviderPriority(next);
    if (!mounted) return;
    setState(() => _audioLocal = null);
    if (!saved) {
      _failed();
    } else if (next.first != current.first) {
      _reconcileQualities(next.first);
    }
    await _refreshFlags();
  }

  void _reconcileQualities(String id) {
    final provider = ref
        .read(extensionProvider)
        .extensions
        .where((ext) => ext.id == id)
        .firstOrNull;
    if (provider == null) return;
    reconcileListenQualities(
      ref.read(settingsProvider.notifier),
      ref.read(settingsProvider),
      provider,
    );
  }

  Future<void> _restoreMusic() async {
    await ref
        .read(extensionProvider.notifier)
        .resetMetadataProviderPriorityToRecommended();
    await _refreshFlags();
  }

  Future<void> _restoreAudio() async {
    final notifier = ref.read(extensionProvider.notifier);
    await notifier.resetProviderPriorityToRecommended();
    final first = ref.read(extensionProvider).providerPriority.firstOrNull;
    if (first != null) _reconcileQualities(first);
    await _refreshFlags();
  }

  void _setFallback(List<String> audio, String id, bool enabled) {
    final saved = ref.read(settingsProvider).downloadFallbackExtensionIds;
    ref
        .read(settingsProvider.notifier)
        .setDownloadFallbackExtensionIds(
          fallbackIdsAfterToggle(audio, saved, id, enabled),
        );
  }

  void _confirmDefault(String id) {
    final selected = ref
        .read(extensionProvider.notifier)
        .selectPlaybackProvider(id);
    if (selected) _reconcileQualities(id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final state = ref.watch(extensionProvider);
    final settings = ref.watch(settingsProvider);
    final inset = 16 + wideListInset(context);
    final music = _musicOrder(state);
    final audio = _audioOrder(state);
    final byId = {for (final ext in state.extensions) ext.id: ext};
    final fallbackIds = settings.downloadFallbackExtensionIds;

    Widget text(String value, {Color? color, double top = 0}) =>
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(inset + 4, top, inset + 4, 8),
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                height: 1.35,
                color: color ?? muted,
              ),
            ),
          ),
        );

    Widget emptyNote(String value) => SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: inset, vertical: 8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(value, style: TextStyle(color: muted)),
        ),
      ),
    );

    Widget restore(bool recommended, VoidCallback onRestore) =>
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(inset + 4, 0, inset, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    recommended
                        ? l10n.sourcesRecommendedNote
                        : l10n.sourcesCustomNote,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
                if (!recommended)
                  TextButton(
                    onPressed: onRestore,
                    child: Text(l10n.sourcesRestoreOrder),
                  ),
              ],
            ),
          ),
        );

    final lyricsNames = <String, String>{
      for (final ext in state.extensions)
        'extension:${ext.id.toLowerCase()}': ext.displayName,
    };
    final lyricsSummary = settings.lyricsProviders.isEmpty
        ? l10n.downloadProvidersNoneEnabled
        : settings.lyricsProviders
              .map((id) => lyricsProviderDisplayName(id, lyricsNames))
              .join(' > ');
    final firstAudio = audio.firstOrNull == null ? null : byId[audio.first];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.sourcesTitle),
          text(l10n.sourcesIntro),
          if (state.extensions.isEmpty && !state.isLoading)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: inset, vertical: 8),
                child: const _AddAddonShortcuts(),
              ),
            ),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: l10n.sourcesMusicTitle),
          ),
          text(l10n.sourcesMusicHint),
          const SliverToBoxAdapter(
            child: SettingsGroup(
              connected: true,
              children: [
                TourAnchor(
                  target: GuidedTourTarget.catalog,
                  child: _CatalogProviderSelector(),
                ),
                TourAnchor(
                  target: GuidedTourTarget.homeSource,
                  child: _HomeFeedProviderSelector(),
                ),
                HomeFeedRegionSetting(),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (music.isEmpty)
            emptyNote(l10n.extensionsNoMetadataProvider)
          else ...[
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              sliver: SliverReorderableList(
                itemCount: music.length,
                onReorderItem: (from, to) => _reorderMusic(music, from, to),
                itemBuilder: (context, index) {
                  final id = music[index];
                  return _SourceRow(
                    key: ValueKey('source_music_$id'),
                    index: index,
                    extension: byId[id],
                    id: id,
                    badge: index == 0 ? l10n.sourcesMainBadge : null,
                  );
                },
              ),
            ),
            restore(_musicRecommended, _restoreMusic),
          ],
          SliverToBoxAdapter(
            child: _AdvancedToggle(
              open: _advancedOpen,
              onTap: () => setState(() => _advancedOpen = !_advancedOpen),
            ),
          ),
          if (_advancedOpen) ...[
            text(l10n.sourcesAdvancedHint),
            const SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [_DefaultSearchTabSelector()],
              ),
            ),
          ],
          const SliverToBoxAdapter(
            child: SettingsGroup(
              connected: true,
              children: [SearchRegionSelector(), PersonalizeSearchSwitch()],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: l10n.sourcesAudioTitle),
          ),
          text(l10n.sourcesAudioHint),
          if (audio.isEmpty)
            emptyNote(
              noDownloadProviderMessage(l10n, noDownloadProviderCause(state)),
            )
          else ...[
            SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [
                  SettingsSwitchItem(
                    key: const ValueKey('sources_try_next'),
                    icon: Icons.sync,
                    title: l10n.optionsAutoFallback,
                    subtitle: l10n.optionsAutoFallbackSubtitle,
                    value: settings.autoFallback,
                    showDivider: false,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setAutoFallback(value),
                  ),
                ],
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              sliver: SliverReorderableList(
                itemCount: audio.length,
                onReorderItem: (from, to) => _reorderAudio(audio, from, to),
                itemBuilder: (context, index) {
                  final id = audio[index];
                  final first = index == 0;
                  return _SourceRow(
                    key: ValueKey('source_audio_$id'),
                    index: index,
                    extension: byId[id],
                    id: id,
                    badge: first ? l10n.sourcesDefaultBadge : null,
                    backupLabel: first ? null : l10n.sourcesUseAsBackup,
                    backupValue:
                        fallbackIds == null || fallbackIds.contains(id),
                    backupEnabled: settings.autoFallback,
                    onBackupChanged: (value) => _setFallback(audio, id, value),
                  );
                },
              ),
            ),
            restore(_audioRecommended, _restoreAudio),
            if (!settings.playbackProviderConfirmed && firstAudio != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonal(
                      key: const ValueKey('sources_confirm_default'),
                      onPressed: () => _confirmDefault(firstAudio.id),
                      child: Text(
                        l10n.sourcesConfirmDefault(firstAudio.displayName),
                      ),
                    ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: ProviderCooldownPanel()),
          ],
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: l10n.settingsLyrics),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              connected: true,
              children: [
                SettingsItem(
                  key: const ValueKey('sources_lyrics'),
                  icon: Icons.lyrics_outlined,
                  title: l10n.lyricsProvidersTitle,
                  subtitle: lyricsSummary,
                  showDivider: false,
                  onTap: () => pushPage<void>(
                    context,
                    (_) => const LyricsProviderPriorityPage(),
                  ),
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

/// What to do when no add-on is installed: the three ways to add one.
class _AddAddonShortcuts extends StatelessWidget {
  const _AddAddonShortcuts();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.sourcesAddAddonTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            l10n.homeNoAddonsSubtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const Key('sources-add-code'),
                icon: const Icon(Icons.pin_outlined, size: 18),
                label: Text(l10n.sourcesAddByCode),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(l10n.sourcesAddByCode)),
                      body: const SingleChildScrollView(
                        child: PluginCodeCard(),
                      ),
                    ),
                  ),
                ),
              ),
              FilledButton.tonalIcon(
                key: const Key('sources-add-file'),
                icon: const Icon(Icons.file_open_outlined, size: 18),
                label: Text(l10n.sourcesAddByFile),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(builder: (_) => const ExtensionsPage()),
                ),
              ),
              FilledButton.tonalIcon(
                key: const Key('sources-add-repo'),
                icon: const Icon(Icons.storefront_outlined, size: 18),
                label: Text(l10n.sourcesAddByRepo),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(l10n.storeTitle)),
                      body: const RepoTab(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
