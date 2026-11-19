part of 'sources_page.dart';

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.index,
    required this.id,
    required this.extension,
    this.badge,
    this.backupLabel,
    this.backupValue = true,
    this.backupEnabled = true,
    this.onBackupChanged,
  });

  final int index;
  final String id;
  final Extension? extension;
  final String? badge;
  final String? backupLabel;
  final bool backupValue;
  final bool backupEnabled;
  final ValueChanged<bool>? onBackupChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final first = index == 0;
    final name = extension?.displayName ?? id;
    final caption = badge ?? backupLabel;
    final background = theme.brightness == Brightness.dark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.05), scheme.surface)
        : scheme.surfaceContainerHigh;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: first
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: first
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ProviderIcon(
                provider: id,
                filePath: extension?.iconPath,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (caption != null)
                      Text(
                        caption,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: badge != null
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontWeight: badge != null
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                  ],
                ),
              ),
              if (backupLabel != null)
                AppSwitch(
                  key: ValueKey('source_backup_$id'),
                  value: backupValue,
                  semanticLabel: '$backupLabel: $name',
                  onChanged: backupEnabled ? onBackupChanged : null,
                ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    Icons.drag_handle,
                    color: scheme.onSurfaceVariant,
                    semanticLabel: name,
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

class _AdvancedToggle extends StatelessWidget {
  const _AdvancedToggle({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: const ValueKey('sources_advanced_toggle'),
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 20 + wideListInset(context),
          vertical: 14,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.sourcesAdvancedTitle,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              open ? Icons.expand_less : Icons.expand_more,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
List<Extension> catalogProviderChoices(ExtensionState state) => [
  for (final ext in state.extensions)
    if (ext.enabled && ext.hasCustomSearch && ext.hasMetadataProvider) ext,
];

Extension? automaticCatalogProvider(ExtensionState state) {
  for (final id in state.metadataProviderPriority) {
    final match = state.extensions
        .where((ext) => ext.id == id && ext.enabled && ext.hasCustomSearch)
        .firstOrNull;
    if (match != null) return match;
  }
  return defaultSearchExtension(state.extensions);
}

class _CatalogProviderSelector extends ConsumerWidget {
  const _CatalogProviderSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final extState = ref.watch(extensionProvider);
    final choices = catalogProviderChoices(extState);
    final pinned = _pinnedChoice(settings, choices);
    final automatic = automaticCatalogProvider(extState);
    final subtitle = pinned != null
        ? pinned.displayName
        : automatic != null
        ? context.l10n.sourcesAutomaticNow(automatic.displayName)
        : context.l10n.sourcesNoCatalogProvider;
    return SettingsItem(
      key: const ValueKey('sources_catalog_provider'),
      icon: Icons.manage_search,
      title: context.l10n.sourcesCatalogTitle,
      subtitle: subtitle,
      showDivider: false,
      onTap: choices.isEmpty
          ? null
          : () => _showPicker(context, ref, pinned, choices),
    );
  }

  Extension? _pinnedChoice(AppSettings settings, List<Extension> choices) {
    if (!settings.searchProviderPinned) return null;
    return choices
        .where((ext) => ext.id == settings.searchProvider?.trim())
        .firstOrNull;
  }

  void _showPicker(
    BuildContext context,
    WidgetRef ref,
    Extension? pinned,
    List<Extension> choices,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget check(bool selected) => selected
        ? AppIcon(Icons.check_circle, color: colorScheme.primary)
        : AppIcon(Icons.circle_outlined, color: colorScheme.outline);

    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.sourcesCatalogTitle,
      subtitle: context.l10n.sourcesCatalogHint,
      builder: (ctx, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSheetOption(
              key: const ValueKey('sources_catalog_auto'),
              leading: AppIcon(Icons.auto_awesome, color: colorScheme.primary),
              title: Text(ctx.l10n.sourcesCatalogAuto),
              subtitle: Text(ctx.l10n.sourcesCatalogAutoSubtitle),
              selected: pinned == null,
              trailing: check(pinned == null),
              onTap: () {
                ref.read(settingsProvider.notifier).setCatalogProvider(null);
                ref.read(extensionProvider.notifier).reconcileSearchProvider();
                ref.read(exploreProvider.notifier).refresh();
                Navigator.pop(ctx);
              },
            ),
            for (final ext in choices)
              AppSheetOption(
                key: ValueKey('sources_catalog_${ext.id}'),
                leading: AppIcon(Icons.extension, color: colorScheme.secondary),
                title: Text(ext.displayName),
                selected: pinned?.id == ext.id,
                trailing: check(pinned?.id == ext.id),
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setCatalogProvider(ext.id);
                  ref.read(exploreProvider.notifier).refresh();
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _HomeFeedProviderSelector extends ConsumerWidget {
  const _HomeFeedProviderSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final extState = ref.watch(extensionProvider);

    final homeFeedProviders = extState.extensions
        .where((e) => e.enabled && e.hasHomeFeed)
        .toList();

    final hasAnyProvider = homeFeedProviders.isNotEmpty;
    final homeFeedDisabled =
        settings.homeFeedProvider == AppSettings.homeFeedProviderOff;

    final followed = ref.watch(homeFeedExtensionProvider);
    String currentProviderName = followed == null
        ? context.l10n.extensionsHomeFeedAuto
        : context.l10n.sourcesAutomaticNow(followed.displayName);
    if (homeFeedDisabled) {
      currentProviderName = context.l10n.extensionsHomeFeedOff;
    } else if (settings.homeFeedProvider != null &&
        settings.homeFeedProvider!.isNotEmpty) {
      final ext = homeFeedProviders
          .where((e) => e.id == settings.homeFeedProvider)
          .firstOrNull;
      currentProviderName = ext?.displayName ?? settings.homeFeedProvider!;
    }

    return SettingsItem(
      key: const ValueKey('sources_home_provider'),
      icon: Icons.explore_outlined,
      title: context.l10n.sourcesHomeTitle,
      subtitle: !hasAnyProvider && !homeFeedDisabled
          ? context.l10n.extensionsNoHomeFeedExtensions
          : currentProviderName,
      showDivider: false,
      onTap: () => _showHomeFeedProviderPicker(
        context,
        ref,
        settings,
        homeFeedProviders,
      ),
    );
  }

  void _showHomeFeedProviderPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    List<Extension> homeFeedProviders,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.sourcesHomeTitle,
      subtitle: context.l10n.sourcesHomeHint,
      builder: (ctx, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSheetOption(
              leading: AppIcon(Icons.auto_awesome, color: colorScheme.primary),
              title: Text(ctx.l10n.extensionsHomeFeedAuto),
              subtitle: Text(ctx.l10n.extensionsHomeFeedAutoSubtitle),
              trailing:
                  (settings.homeFeedProvider == null ||
                      settings.homeFeedProvider!.isEmpty)
                  ? AppIcon(Icons.check_circle, color: colorScheme.primary)
                  : AppIcon(Icons.circle_outlined, color: colorScheme.outline),
              onTap: () {
                ref.read(settingsProvider.notifier).setHomeFeedProvider(null);
                ref.read(exploreProvider.notifier).refresh();
                Navigator.pop(ctx);
              },
            ),
            AppSheetOption(
              leading: AppIcon(Icons.block, color: colorScheme.error),
              title: Text(ctx.l10n.extensionsHomeFeedOff),
              subtitle: Text(ctx.l10n.extensionsHomeFeedOffSubtitle),
              selected:
                  settings.homeFeedProvider == AppSettings.homeFeedProviderOff,
              trailing:
                  settings.homeFeedProvider == AppSettings.homeFeedProviderOff
                  ? AppIcon(Icons.check_circle, color: colorScheme.primary)
                  : AppIcon(Icons.circle_outlined, color: colorScheme.outline),
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setHomeFeedProvider(AppSettings.homeFeedProviderOff);
                ref.read(exploreProvider.notifier).clear();
                Navigator.pop(ctx);
              },
            ),
            if (homeFeedProviders.isEmpty)
              AppSheetOption(
                enabled: false,
                leading: AppIcon(
                  Icons.extension_off,
                  color: colorScheme.outline,
                ),
                title: Text(ctx.l10n.extensionsNoHomeFeedExtensions),
              ),
            ...homeFeedProviders.map(
              (ext) => AppSheetOption(
                leading: AppIcon(Icons.extension, color: colorScheme.secondary),
                title: Text(ext.displayName),
                subtitle: Text(ctx.l10n.extensionsHomeFeedUse(ext.displayName)),
                selected: settings.homeFeedProvider == ext.id,
                trailing: settings.homeFeedProvider == ext.id
                    ? AppIcon(Icons.check_circle, color: colorScheme.primary)
                    : AppIcon(
                        Icons.circle_outlined,
                        color: colorScheme.outline,
                      ),
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setHomeFeedProvider(ext.id);
                  ref.read(exploreProvider.notifier).refresh();
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _DefaultSearchTabSelector extends ConsumerWidget {
  const _DefaultSearchTabSelector();

  String _labelForTab(BuildContext context, String tab) {
    return switch (tab) {
      'track' => context.l10n.searchTracks,
      'artist' => context.l10n.searchArtists,
      'album' => context.l10n.searchAlbums,
      'playlist' => context.l10n.searchPlaylists,
      _ => context.l10n.historyFilterAll,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final current = settings.defaultSearchTab;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.optionsDefaultSearchTab,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.optionsDefaultSearchTabSubtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SettingsChoiceGrid(
            children: [
              for (final tab in const [
                'all',
                'track',
                'artist',
                'album',
                'playlist',
              ])
                SettingsChoiceChip(
                  icon: switch (tab) {
                    'track' => Icons.music_note,
                    'artist' => Icons.person,
                    'album' => Icons.album,
                    'playlist' => Icons.queue_music,
                    _ => Icons.grid_view,
                  },
                  label: _labelForTab(context, tab),
                  isSelected: current == tab,
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setDefaultSearchTab(tab),
                ),
            ],
          ),
        ],
      ),
    );
    return SettingsSearchTarget(
      label: context.l10n.optionsDefaultSearchTab,
      child: content,
    );
  }
}
