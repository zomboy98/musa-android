import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/constants/feature_flags.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/app_update_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/screens/settings/profile_settings_page.dart';
import 'package:mornye/screens/report/report_page.dart';
import 'package:mornye/screens/settings/about_page.dart';
import 'package:mornye/screens/settings/app_settings_page.dart';
import 'package:mornye/screens/settings/appearance_settings_page.dart';
import 'package:mornye/screens/settings/backup_restore_page.dart';
import 'package:mornye/screens/settings/cache_management_page.dart';
import 'package:mornye/screens/settings/download_settings_page.dart';
import 'package:mornye/screens/tutorial_screen.dart';
import 'package:mornye/screens/settings/files_settings_page.dart';
import 'package:mornye/screens/settings/keyboard_shortcuts_page.dart';
import 'package:mornye/screens/settings/library_settings_page.dart';
import 'package:mornye/screens/settings/link_desktop_settings_page.dart';
import 'package:mornye/screens/settings/link_settings_page.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/screens/settings/log_screen.dart';
import 'package:mornye/screens/settings/bug_log_page.dart';
import 'package:mornye/screens/settings/lyrics_settings_page.dart';
import 'package:mornye/screens/settings/metadata_settings_page.dart';
import 'package:mornye/screens/settings/music_preferences_page.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/screens/settings/startup_settings_page.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/no_scrollbars.dart';

/// One entry on the Settings tab.
class _Destination {
  const _Destination({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.pageBuilder,
    this.keywords = const [],
    this.searchEntries = const [],
    this.beta = false,
  });

  final IconData icon;
  final MaterialColor iconColor;
  final String title;
  final String subtitle;
  final Widget Function() pageBuilder;

  /// Marks the entry with a Beta tag in the phone list. The desktop category
  /// column is too narrow for it, so those pages show the tag themselves.
  final bool beta;

  /// Extra search terms for things the title does not spell out (e.g. "SAF"
  /// for the Files page), so a user can find a page by what it does.
  final List<String> keywords;
  final List<SettingsSearchEntry> searchEntries;

  bool matches(SettingsSearchQuery query) {
    return query.matches([title, subtitle, ...keywords]);
  }
}

class _SearchResult {
  const _SearchResult(this.destination, [this.entry]);

  final _Destination destination;
  final SettingsSearchEntry? entry;
}

/// Destinations that stay visually connected inside one settings card.
class _Group {
  const _Group({required this.destinations, this.title});

  final List<_Destination> destinations;
  final String? title;
}

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({
    super.key,
    this.asPage = false,
    this.remoteConfigService,
    this.isTabActive = true,
  });

  final bool asPage;
  final bool isTabActive;
  final AppRemoteConfigService? remoteConfigService;

  static Route<void> glassRoute() => _SettingsTabState.glassRoute();

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  late final ValueNotifier<bool> _tabActive = ValueNotifier(widget.isTabActive);
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  AppLocalizations? _cachedLocalizations;
  List<_Group>? _cachedGroups;
  bool _cachedUpdateAvailable = false;
  String _query = '';

  /// Desktop list-detail: the selected category ([_profileSelection] for the
  /// profile), the setting a search result points at, and the detail pane's
  /// navigator. Each selection gets a fresh navigator, so the pages pushed
  /// for the previous category close. Opens on the first page in the list.
  int _selected = 0;
  String? _selectedTarget;
  var _detailNavigatorKey = GlobalKey<NavigatorState>();
  static const int _profileSelection = -1;

  bool get _supportsListDetail => isDesktopPlatform && !widget.asPage;

  @override
  void initState() {
    super.initState();
    if (_supportsListDetail) {
      ShellNavigationService.registerSettingsDetailNavigator(
        owner: this,
        navigator: () => _detailNavigatorKey.currentState,
      );
    }
  }

  @override
  void didUpdateWidget(covariant SettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _tabActive.value = widget.isTabActive;
  }

  @override
  void dispose() {
    _tabActive.dispose();
    ShellNavigationService.unregisterSettingsDetailNavigator(this);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// Related destinations share one card. MUSA adds quiet, localized headings
  /// so the full settings catalogue is easier to scan.
  List<_Group> _groups(BuildContext context) {
    final l10n = context.l10n;
    final updateAvailable = ref.watch(
      appUpdateProvider.select((s) => s.hasOffer),
    );
    if (identical(_cachedLocalizations, l10n) &&
        _cachedUpdateAvailable == updateAvailable &&
        _cachedGroups != null) {
      return _cachedGroups!;
    }

    final searchCatalog = SettingsSearchCatalog(
      l10n,
      androidAudio: Platform.isAndroid,
    );
    final groups = [
      _Group(
        title: l10n.settingsGroupPlayback,
        destinations: [
          _Destination(
            icon: Icons.music_note_outlined,
            iconColor: Colors.pink,
            title: l10n.listenTitle,
            subtitle: l10n.settingsListenSubtitle,
            keywords: const ['quality', 'calidad'],
            searchEntries: searchCatalog.musicPreferences,
            pageBuilder: () => const MusicPreferencesPage(),
          ),
          _Destination(
            icon: Icons.play_circle_outline,
            iconColor: Colors.indigo,
            title: l10n.libraryPlayback,
            subtitle: l10n.settingsPlaybackSubtitle,
            keywords: const ['player', 'audio', 'playback', 'pemutaran'],
            searchEntries: searchCatalog.playback,
            pageBuilder: () => const PlaybackSettingsPage(),
          ),
          _Destination(
            icon: Icons.lyrics_outlined,
            iconColor: Colors.cyan,
            title: l10n.settingsLyrics,
            subtitle: l10n.settingsLyricsSubtitle,
            keywords: const ['lrc', 'synced', 'provider'],
            searchEntries: searchCatalog.lyrics,
            pageBuilder: () => const LyricsSettingsPage(),
          ),
        ],
      ),
      _Group(
        title: l10n.settingsGroupLibraryStorage,
        destinations: [
          _Destination(
            icon: Icons.library_music_outlined,
            iconColor: Colors.blue,
            title: l10n.settingsLocalLibrary,
            subtitle: l10n.settingsLocalLibrarySubtitle,
            keywords: const ['scan', 'local', 'duplicate'],
            searchEntries: searchCatalog.library,
            pageBuilder: () => const LibrarySettingsPage(),
          ),
          _Destination(
            icon: Icons.dns_outlined,
            iconColor: Colors.blueGrey,
            title: l10n.networkStorage,
            subtitle: 'SMB · WebDAV · HTTP(S) · Subsonic',
            keywords: const [
              'nas',
              'server',
              'network',
              'smb',
              'webdav',
              'http',
            ],
            pageBuilder: () => const NetworkStorageScreen(),
          ),
          if (linkDesktopMenuEnabled && (Platform.isAndroid || Platform.isIOS))
            _Destination(
              icon: Icons.computer,
              iconColor: Colors.deepPurple,
              title: l10n.linkSettingsTitle,
              subtitle: l10n.linkSettingsSubtitle,
              keywords: const [
                'computer',
                'desktop',
                'pc',
                'mac',
                'pair',
                'link',
                'komputer',
              ],
              pageBuilder: () => const LinkSettingsPage(),
              beta: true,
            ),
          if (linkDesktopMenuEnabled && isDesktopPlatform)
            _Destination(
              icon: Icons.phone_android,
              iconColor: Colors.lightBlue,
              title: l10n.linkDesktopSettingsTitle,
              subtitle: l10n.linkDesktopSettingsSubtitle,
              keywords: const [
                'phone',
                'mobile',
                'pair',
                'remote',
                'handoff',
                'subsonic',
                'ponsel',
              ],
              pageBuilder: () => const LinkDesktopSettingsPage(),
            ),
          _Destination(
            icon: Icons.download_outlined,
            iconColor: Colors.green,
            title: l10n.settingsDownload,
            subtitle: l10n.settingsDownloadSubtitle,
            keywords: const ['concurrent', 'network', 'wifi', 'region'],
            searchEntries: searchCatalog.download,
            pageBuilder: () => const DownloadSettingsPage(),
          ),
          _Destination(
            icon: Icons.folder_outlined,
            iconColor: Colors.orange,
            title: l10n.settingsFiles,
            subtitle: l10n.settingsFilesSubtitle,
            keywords: const [
              'saf',
              'storage',
              'folder',
              'filename',
              'path',
              'permission',
            ],
            searchEntries: searchCatalog.files,
            pageBuilder: () => const FilesSettingsPage(),
          ),
          _Destination(
            icon: Icons.sell_outlined,
            iconColor: Colors.amber,
            title: l10n.settingsMetadata,
            subtitle: l10n.settingsMetadataSubtitle,
            keywords: const ['tag', 'cover', 'artwork', 'isrc', 'provider'],
            searchEntries: searchCatalog.metadata,
            pageBuilder: () => const MetadataSettingsPage(),
          ),
          _Destination(
            icon: Icons.storage_outlined,
            iconColor: Colors.indigo,
            title: l10n.settingsCache,
            subtitle: l10n.settingsCacheSubtitle,
            keywords: const ['clear', 'space', 'image', 'temp'],
            searchEntries: searchCatalog.cache,
            pageBuilder: () => const CacheManagementPage(),
          ),
          _Destination(
            icon: Icons.settings_backup_restore,
            iconColor: Colors.teal,
            title: l10n.settingsBackup,
            subtitle: l10n.settingsBackupSubtitle,
            keywords: const ['export', 'import', 'restore', 'json'],
            searchEntries: searchCatalog.backup,
            pageBuilder: () => const BackupRestorePage(),
          ),
        ],
      ),
      _Group(
        title: l10n.settingsAppearance,
        destinations: [
          _Destination(
            icon: Icons.palette_outlined,
            iconColor: Colors.purple,
            title: l10n.settingsAppearance,
            subtitle: l10n.settingsAppearanceSubtitle,
            keywords: const [
              'theme',
              'dark',
              'light',
              'amoled',
              'color',
              'language',
              'locale',
              'layout',
              'grid',
            ],
            searchEntries: searchCatalog.appearance,
            pageBuilder: () => const AppearanceSettingsPage(),
          ),
          _Destination(
            icon: Icons.power_settings_new,
            iconColor: Colors.deepOrange,
            title: l10n.settingsStartup,
            subtitle: l10n.settingsStartupSubtitle,
            keywords: const [
              'welcome',
              'intro',
              'splash',
              'animation',
              'sound',
            ],
            searchEntries: searchCatalog.startup,
            pageBuilder: () => const StartupSettingsPage(),
          ),
        ],
      ),
      _Group(
        title: l10n.settingsGroupAdvancedAbout,
        destinations: [
          _Destination(
            icon: Icons.tune_outlined,
            iconColor: Colors.blueGrey,
            title: l10n.settingsApp,
            subtitle: l10n.settingsAppSubtitle,
            keywords: const ['update', 'channel', 'debug', 'logging'],
            searchEntries: searchCatalog.app,
            pageBuilder: () => const AppSettingsPage(),
          ),
          if (isDesktopPlatform)
            _Destination(
              icon: Icons.keyboard_outlined,
              iconColor: Colors.blueGrey,
              title: l10n.settingsKeyboardShortcuts,
              subtitle: l10n.settingsKeyboardShortcutsSubtitle,
              keywords: const ['hotkey', 'keys', 'keybinding', 'pintasan'],
              pageBuilder: () => const KeyboardShortcutsPage(),
            ),
          _Destination(
            icon: Icons.bug_report_outlined,
            iconColor: Colors.orange,
            title: context.l10n.settingsTabBugLog,
            subtitle: context.l10n.settingsTabLocalErrorHistory,
            keywords: const ['bug', 'crash', 'error', 'fallos'],
            pageBuilder: () => const BugLogPage(),
          ),
          _Destination(
            icon: Icons.article_outlined,
            iconColor: Colors.brown,
            title: l10n.logTitle,
            subtitle: l10n.settingsLogsSubtitle,
            keywords: const ['debug', 'error', 'report'],
            searchEntries: searchCatalog.logs,
            pageBuilder: () => const LogScreen(),
          ),
          _Destination(
            icon: Icons.rate_review_outlined,
            iconColor: Colors.teal,
            title: l10n.reportTitle,
            subtitle: l10n.reportEntrySubtitle,
            keywords: const [
              'report',
              'informe',
              'ayuda',
              'help',
              'feedback',
              'comentarios',
              'reportes',
              'bug',
              'error',
              'captura',
              'sugerencia',
            ],
            pageBuilder: () => const ReportPage(),
          ),
          _Destination(
            icon: Icons.help_outline,
            iconColor: Colors.blue,
            title: l10n.settingsTutorial,
            subtitle: l10n.settingsTutorialSubtitle,
            keywords: const [
              'help',
              'ayuda',
              'tutorial',
              'guide',
              'guía',
              'onboarding',
            ],
            pageBuilder: () => const TutorialScreen(),
          ),
          _Destination(
            icon: Icons.info_outline,
            iconColor: Colors.grey,
            title: l10n.settingsAbout,
            subtitle: updateAvailable
                ? l10n.appUpdateNotificationTitle
                : '${l10n.aboutVersion} ${AppInfo.displayVersion}',
            keywords: const ['version', 'license', 'contributor'],
            searchEntries: searchCatalog.about,
            pageBuilder: () => const AboutPage(),
          ),
        ],
      ),
    ];
    _cachedLocalizations = l10n;
    _cachedGroups = groups;
    _cachedUpdateAvailable = updateAvailable;
    return groups;
  }

  Future<void> _navigateTo(
    BuildContext context,
    Widget page, {
    String? targetLabel,
  }) async {
    _searchFocusNode.unfocus();
    _searchFocusNode.canRequestFocus = false;
    FocusManager.instance.primaryFocus?.unfocus();
    final destination = targetLabel == null
        ? page
        : SettingsSearchHighlightScope(targetLabel: targetLabel, child: page);
    await Navigator.of(
      context,
    ).push(slidePageRoute<void>(page: MornyeSettingsTheme(child: destination)));
    if (!mounted) return;

    // A route's focus scope remembers its previously focused child. Keep the
    // search field out of that restoration cycle while the child page is open,
    // then re-enable it without requesting focus when Settings becomes active.
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.canRequestFocus = true;
      _searchFocusNode.unfocus();
    });
  }

  Color _iconColorFor(_Destination destination) => context.isMornye
      ? destination.iconColor[Theme.of(context).brightness == Brightness.dark
            ? 300
            : 800]!
      : Theme.of(context).colorScheme.onSurfaceVariant;

  Widget _itemFor(_Destination destination, {required bool showDivider}) {
    return SettingsItem(
      icon: destination.icon,
      iconColor: _iconColorFor(destination),
      showIconInMornye: true,
      title: destination.title,
      titleTrailing: destination.beta ? const BetaBadge() : null,
      subtitle: destination.subtitle,
      showDivider: showDivider,
      onTap: () => _navigateTo(context, destination.pageBuilder()),
    );
  }

  Widget _searchItemFor(_SearchResult result, {required bool showDivider}) {
    final entry = result.entry;
    if (entry == null) {
      return _itemFor(result.destination, showDivider: showDivider);
    }

    return SettingsItem(
      key: ValueKey(
        'settings-search:${result.destination.title}:${entry.title}',
      ),
      icon: entry.icon,
      iconColor: _iconColorFor(result.destination),
      showIconInMornye: true,
      title: entry.title,
      subtitle: result.destination.title,
      showDivider: showDivider,
      onTap: () => _navigateTo(
        context,
        result.destination.pageBuilder(),
        targetLabel: entry.targetLabel,
      ),
    );
  }

  /// Content pane width from which desktop Settings shows its categories
  /// beside the selected page.
  static const double listDetailMinWidth = 720;

  @override
  Widget build(BuildContext context) {
    // Settings reads as chrome; its pages scroll without a bar.
    if (!_supportsListDetail) {
      return NoScrollbars(
        child: widget.asPage ? _buildGlassList(context) : _buildList(context),
      );
    }
    return NoScrollbars(
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth >= listDetailMinWidth
            ? _buildListDetail(context)
            : _buildList(context),
      ),
    );
  }

  /// Selects the category at [index] (or [_profileSelection]) for the
  /// detail pane. Selecting the open category again returns its pane to the
  /// top page.
  void _select(int index, {String? target}) {
    _searchFocusNode.unfocus();
    if (index == _selected && target == null && _selectedTarget == null) {
      _detailNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() {
      _selected = index;
      _selectedTarget = target;
      _detailNavigatorKey = GlobalKey<NavigatorState>();
    });
  }

  Widget _detailPage() {
    final Widget page;
    if (_selected == _profileSelection) {
      final profile = ref.read(userProfileProvider).value;
      page = profile == null
          ? const SizedBox.shrink()
          : ProfileSettingsPage(profile: profile);
    } else {
      final destinations = [
        for (final group in _groups(context)) ...group.destinations,
      ];
      page = destinations[_selected.clamp(0, destinations.length - 1)]
          .pageBuilder();
    }
    final target = _selectedTarget;
    return MornyeSettingsTheme(
      child: target == null
          ? page
          : SettingsSearchHighlightScope(targetLabel: target, child: page),
    );
  }

  /// Desktop Settings: categories on the leading side and the selected page
  /// beside them, whose own links open inside the detail pane. Material
  /// follows the M3 list-detail layout; Mornye follows the System Settings
  /// sidebar.
  Widget _buildListDetail(BuildContext context) {
    final mornye = context.isMornye;
    return MornyeSettingsTheme(
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: const ValueKey('settings-category-list'),
                width: mornye ? 260 : 320,
                child: Material(
                  color: mornye
                      ? theme.scaffoldBackgroundColor
                      : theme.colorScheme.surfaceContainerLow,
                  child: _buildCategoryList(context),
                ),
              ),
              if (mornye)
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: MornyeTheme.metadataDividerColor(context),
                ),
              Expanded(
                child: ClipRect(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final mediaQuery = MediaQuery.of(context);
                      // Pages measure the detail pane, not the window.
                      return MediaQuery(
                        data: mediaQuery.copyWith(
                          size: Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          ),
                        ),
                        // A semantics container keeps the detail routes'
                        // modal barriers from hiding the category list.
                        child: Semantics(
                          container: true,
                          child: HeroControllerScope.none(
                            child: Navigator(
                              key: _detailNavigatorKey,
                              onGenerateInitialRoutes: (_, _) => [
                                PageRouteBuilder<void>(
                                  transitionDuration: Duration.zero,
                                  reverseTransitionDuration: Duration.zero,
                                  pageBuilder: (_, _, _) => _detailPage(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCategoryList(BuildContext context) {
    final mornye = context.isMornye;
    final theme = Theme.of(context);
    final query = SettingsSearchQuery(_query);
    final groups = _groups(context);
    final destinations = [for (final group in groups) ...group.destinations];

    Widget categoryRow(
      _Destination destination, {
      bool first = true,
      bool last = true,
    }) {
      final index = destinations.indexOf(destination);
      return _CategoryRow(
        key: ValueKey('settings-category:${destination.title}'),
        first: first,
        last: last,
        leading: _CategoryIcon(
          icon: destination.icon,
          color: destination.iconColor,
          selected: index == _selected,
        ),
        title: destination.title,
        selected: index == _selected,
        onTap: () => _select(index),
      );
    }

    final children = <Widget>[
      if (!mornye)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
          child: Semantics(
            header: true,
            child: Text(
              context.l10n.settingsTitle,
              style: theme.textTheme.headlineSmall,
            ),
          ),
        ),
      Padding(
        padding: EdgeInsets.only(top: mornye ? 12 : 0, bottom: 12),
        child: AppSearchField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          hintText: context.l10n.settingsSearchHint,
          clearTooltip: context.l10n.dialogClear,
          samplesBackdrop: false,
          onChanged: (value) => setState(() => _query = value),
          onClear: () => setState(() => _query = ''),
        ),
      ),
      Consumer(
        builder: (context, ref, _) {
          final profile = ref.watch(userProfileProvider).value;
          final named = profile?.name.isNotEmpty == true;
          if (!query.isEmpty &&
              !query.matches([
                named ? profile!.name : context.l10n.profileSetUp,
                context.l10n.profileEdit,
              ])) {
            return const SizedBox.shrink();
          }
          return _CategoryRow(
            key: const ValueKey('settings-category:profile'),
            leading: ProfileAvatar(
              name: profile?.name ?? '',
              photoPath: profile?.photoPath,
              size: mornye ? 36 : 40,
            ),
            title: named ? profile!.name : context.l10n.profileSetUp,
            subtitle: context.l10n.profileEdit,
            selected: _selected == _profileSelection,
            onTap: profile == null ? null : () => _select(_profileSelection),
          );
        },
      ),
    ];

    if (query.isEmpty) {
      for (final group in groups) {
        children.add(SizedBox(height: mornye ? 16 : 12));
        if (mornye && group.title != null) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Semantics(
                header: true,
                child: Text(
                  group.title!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        }
        final last = group.destinations.length - 1;
        for (final (index, destination) in group.destinations.indexed) {
          children.add(
            categoryRow(destination, first: index == 0, last: index == last),
          );
        }
      }
    } else {
      final matches = <_SearchResult>[
        for (final destination in destinations) ...[
          if (destination.matches(query)) _SearchResult(destination),
          for (final entry in destination.searchEntries)
            if (entry.matches(query)) _SearchResult(destination, entry),
        ],
      ];
      children.add(const SizedBox(height: 12));
      if (matches.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              context.l10n.settingsSearchNoResults(_query.trim()),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      for (final (position, result) in matches.indexed) {
        final first = position == 0;
        final last = position == matches.length - 1;
        final entry = result.entry;
        if (entry == null) {
          children.add(
            categoryRow(result.destination, first: first, last: last),
          );
          continue;
        }
        final index = destinations.indexOf(result.destination);
        children.add(
          _CategoryRow(
            key: ValueKey(
              'settings-search:${result.destination.title}:${entry.title}',
            ),
            first: first,
            last: last,
            leading: _CategoryIcon(
              icon: entry.icon,
              color: result.destination.iconColor,
              selected: false,
            ),
            title: entry.title,
            subtitle: result.destination.title,
            selected: false,
            onTap: () => _select(index, target: entry.targetLabel),
          ),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      children: children,
    );
  }

  /// Route for the root Settings panel opened over the home screen. It is
  /// not opaque, so the page underneath shows through the translucent scrim.
  static Route<void> glassRoute() => PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => const Scaffold(
      backgroundColor: Colors.transparent,
      body: SettingsTab(asPage: true),
    ),
    transitionsBuilder: (context, animation, _, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, .04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );

  Widget _glassHeader(BuildContext context, double side) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: side + 8,
        end: side - 4,
        top: MediaQuery.paddingOf(context).top + 12,
        bottom: 8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              namesRoute: true,
              header: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MUSA',
                    style: type.labelSmall?.copyWith(
                      letterSpacing: 2,
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.settingsTitle,
                    style: type.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('close-settings-panel'),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.maybePop(context),
            style: IconButton.styleFrom(
              backgroundColor: colors.onSurface.withValues(alpha: .07),
              side: BorderSide(color: colors.onSurface.withValues(alpha: .10)),
              shape: const CircleBorder(),
            ),
            icon: const Icon(Icons.close, size: 20),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
        ],
      ),
    );
  }

  Widget _glassProfileCard(
    BuildContext context,
    EdgeInsets margin,
    UserProfile? profile,
  ) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final named = profile?.name.isNotEmpty == true;
    final onTap = profile == null
        ? null
        : () => _navigateTo(context, ProfileSettingsPage(profile: profile));
    return Padding(
      padding: margin,
      child: VisionGlassCard(
        accent: true,
        child: Material(
          type: MaterialType.transparency,
          child: Semantics(
            button: true,
            enabled: onTap != null,
            child: InkWell(
              key: const ValueKey('settings-profile-card'),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colors.primary.withValues(alpha: .55),
                        ),
                      ),
                      child: ProfileAvatar(
                        name: profile?.name ?? '',
                        photoPath: profile?.photoPath,
                        size: 56,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            named ? profile!.name : context.l10n.profileSetUp,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: type.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            context.l10n.profileEdit,
                            style: type.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.arrow_outward_rounded,
                      size: 20,
                      color: colors.primary,
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

  Widget _buildGlassList(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final query = SettingsSearchQuery(_query);
    final groups = _groups(context);
    final side = 16.0 + wideListInset(context);
    final margin = EdgeInsets.fromLTRB(side, 4, side, 4);
    final strong =
        MediaQuery.highContrastOf(context) ||
        MediaQuery.accessibleNavigationOf(context);

    final List<Widget> body;
    if (query.isEmpty) {
      body = [
        for (final group in groups)
          SliverToBoxAdapter(
            child: RepaintBoundary(
              child: Column(
                children: [
                  if (group.title != null)
                    SettingsSectionHeader(title: group.title!, vision: true),
                  SettingsGroup(
                    vision: true,
                    margin: margin,
                    children: [
                      for (var i = 0; i < group.destinations.length; i++)
                        _itemFor(
                          group.destinations[i],
                          showDivider: i != group.destinations.length - 1,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ];
    } else {
      final matches = <_SearchResult>[
        for (final group in groups)
          for (final destination in group.destinations) ...[
            if (destination.matches(query)) _SearchResult(destination),
            for (final entry in destination.searchEntries)
              if (entry.matches(query)) _SearchResult(destination, entry),
          ],
      ];
      body = [
        SliverToBoxAdapter(
          child: matches.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    context.l10n.settingsSearchNoResults(_query.trim()),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                )
              : SettingsGroup(
                  vision: true,
                  margin: margin,
                  children: [
                    for (final (index, result) in matches.indexed)
                      _searchItemFor(
                        result,
                        showDivider: index != matches.length - 1,
                      ),
                  ],
                ),
        ),
      ];
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colors.surface.withValues(alpha: strong ? 1 : .94),
            colors.surface.withValues(alpha: strong ? 1 : .97),
          ],
        ),
      ),
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _glassHeader(context, side)),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(side, 8, side, 8),
              child: AppSearchField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                hintText: context.l10n.settingsSearchHint,
                clearTooltip: context.l10n.dialogClear,
                samplesBackdrop: false,
                onChanged: (value) => setState(() => _query = value),
                onClear: () => setState(() => _query = ''),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Consumer(
              builder: (context, ref, _) {
                final profile = ref.watch(userProfileProvider).value;
                if (!query.isEmpty &&
                    !query.matches([
                      profile?.name.isNotEmpty == true
                          ? profile!.name
                          : context.l10n.profileSetUp,
                      context.l10n.profileEdit,
                    ])) {
                  return const SizedBox.shrink();
                }
                return _glassProfileCard(context, margin, profile);
              },
            ),
          ),
          ...body,
          SliverToBoxAdapter(
            child: SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final tokens = context.tokens;
    final wideInset = wideListInset(context);
    final query = SettingsSearchQuery(_query);
    final groups = _groups(context);

    final margin = EdgeInsets.fromLTRB(
      tokens.gapLg + wideInset,
      context.isMornye ? 12 : tokens.gapSm,
      tokens.gapLg + wideInset,
      context.isMornye ? 12 : tokens.gapSm,
    );

    final List<Widget> body;
    if (query.isEmpty) {
      body = [
        for (final group in groups)
          SliverToBoxAdapter(
            child: Column(
              children: [
                if (context.isMornye && group.title != null)
                  SettingsSectionHeader(title: group.title!),
                SettingsGroup(
                  margin: margin,
                  children: [
                    for (var i = 0; i < group.destinations.length; i++)
                      _itemFor(
                        group.destinations[i],
                        showDivider: i != group.destinations.length - 1,
                      ),
                  ],
                ),
              ],
            ),
          ),
      ];
    } else {
      final matches = <_SearchResult>[
        for (final group in groups)
          for (final destination in group.destinations) ...[
            if (destination.matches(query)) _SearchResult(destination),
            for (final entry in destination.searchEntries)
              if (entry.matches(query)) _SearchResult(destination, entry),
          ],
      ];
      body = matches.isEmpty
          ? [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(tokens.gapXl),
                  child: Text(
                    context.l10n.settingsSearchNoResults(_query.trim()),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ]
          : [
              SliverSettingsGroup(
                margin: margin,
                itemCount: matches.length,
                itemBuilder: (context, index) => _searchItemFor(
                  matches[index],
                  showDivider: index != matches.length - 1,
                ),
              ),
            ];
    }

    return MornyeSettingsTheme(
      child: CustomScrollView(
        slivers: [
          if (widget.asPage)
            AppSliverHeader.page(title: context.l10n.settingsTitle)
          else
            AppSliverHeader.tabRoot(
              title: context.l10n.settingsTitle,
              alignToContent: true,
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.gapLg + wideInset,
                tokens.gapSm,
                tokens.gapLg + wideInset,
                tokens.gapSm,
              ),
              child: AppSearchField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                hintText: context.l10n.settingsSearchHint,
                clearTooltip: context.l10n.dialogClear,
                onChanged: (value) => setState(() => _query = value),
                onClear: () => setState(() => _query = ''),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Consumer(
              builder: (context, ref, _) {
                final profile = ref.watch(userProfileProvider).value;
                if (!query.isEmpty &&
                    !query.matches([
                      profile?.name.isNotEmpty == true
                          ? profile!.name
                          : context.l10n.profileSetUp,
                      context.l10n.profileEdit,
                    ])) {
                  return const SizedBox.shrink();
                }
                return SettingsGroup(
                  margin: margin,
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      leading: ProfileAvatar(
                        name: profile?.name ?? '',
                        photoPath: profile?.photoPath,
                        size: context.isMornye ? 52 : 64,
                      ),
                      title: Text(
                        profile?.name.isNotEmpty == true
                            ? profile!.name
                            : context.l10n.profileSetUp,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      subtitle:
                          profile?.name.isNotEmpty == true ||
                              profile?.photoPath?.isNotEmpty == true
                          ? null
                          : Text(context.l10n.profileEdit),
                      trailing: const AppIcon(Icons.chevron_right),
                      onTap: profile == null
                          ? null
                          : () => _navigateTo(
                              context,
                              ProfileSettingsPage(profile: profile),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          ...body,
          const NavBarSliverSpacer(),
          const SliverFillRemaining(hasScrollBody: false, child: SizedBox()),
        ],
      ),
    );
  }
}

/// A category in the desktop settings list. Material lays each group out as
/// an expressive connected list, like the settings pages beside it, and
/// marks the selected row with a fully rounded `secondaryContainer` tile;
/// Mornye fills it with a quiet gray like the System Settings sidebar.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    super.key,
    required this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.first = true,
    this.last = true,
  });

  final Widget leading;
  final String title;
  final String? subtitle;

  final bool selected;
  final VoidCallback? onTap;

  /// The row's place in its Material connected group.
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final radius = mornye
        ? BorderRadius.circular(8)
        : selected
        ? BorderRadius.circular(context.tokens.radiusCard)
        : connectedRowRadius(context, first: first, last: last);
    // Mornye selects with the app sidebar's quiet gray fill, so the colored
    // category tiles keep their own color.
    final dark = colorScheme.brightness == Brightness.dark;
    final mornyeFill = colorScheme.onSurface.withValues(
      alpha: dark ? 0.12 : 0.08,
    );
    final foreground = selected && !mornye
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurface;
    final secondary = selected
        ? foreground.withValues(alpha: 0.8)
        : colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: mornye || !last ? 2 : 0),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected
              ? (mornye ? mornyeFill : colorScheme.secondaryContainer)
              : (mornye ? Colors.transparent : settingsGroupColor(context)),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            hoverColor: mornye
                ? colorScheme.onSurface.withValues(alpha: 0.05)
                : null,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: mornye ? 48 : 56),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: mornye ? 8 : 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    IconTheme.merge(
                      data: IconThemeData(color: foreground),
                      child: leading,
                    ),
                    SizedBox(width: mornye ? 10 : 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style:
                                (mornye
                                        ? textTheme.bodyMedium
                                        : textTheme.labelLarge)
                                    ?.copyWith(
                                      color: foreground,
                                      fontWeight: selected
                                          ? (mornye
                                                ? FontWeight.w600
                                                : FontWeight.w700)
                                          : null,
                                    ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              style: textTheme.bodySmall?.copyWith(
                                color: secondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
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

/// A category glyph: Material's plain icon, or Mornye's white symbol on a
/// tile in the category's color, as in System Settings.
class _CategoryIcon extends StatelessWidget {
  const _CategoryIcon({
    required this.icon,
    required this.color,
    required this.selected,
  });

  final IconData icon;
  final MaterialColor color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!context.isMornye) {
      return AppIcon.adaptive(
        icon,
        size: 24,
        color: selected
            ? colorScheme.onSecondaryContainer
            : colorScheme.onSurfaceVariant,
      );
    }
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color[600],
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: AppIcon.adaptive(icon, size: 15, color: Colors.white),
    );
  }
}
