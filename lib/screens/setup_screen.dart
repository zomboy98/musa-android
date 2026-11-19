import 'package:mornye/constants/storage_defaults.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';
import 'package:mornye/widgets/provider_icon.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/plugin_code_provider.dart';
import 'package:mornye/services/plugin_code_service.dart';
import 'package:mornye/widgets/plugin_code_card.dart';
import 'package:mornye/widgets/setup_quality_step.dart';
import 'package:path_provider/path_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mornye/services/setup_progress_store.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/storage_access_provider.dart';
import 'package:mornye/widgets/storage_access_widgets.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SetupScreen');

// Height of the back-button/progress header row above the PageView
// (16 vertical padding * 2 + 48 button).

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _progressStore = SetupProgressStore();
  final _platform = defaultTargetPlatform;
  // Desktop has no runtime storage permission: setup skips that step and
  // picks a plain folder.
  final _isDesktop = isDesktopPlatform;
  PageController? _pageController;
  bool _initializing = true;
  int _currentStep = 0;

  String? _selectedDirectory;
  String? _selectedDirectoryBookmark;
  String? _selectedTreeUri;
  bool _isLoading = false;
  bool _settingsLoaded = false;
  bool _inCodeGate = false;
  bool _codePassed = false;
  bool _codeUnlocked = false;

  // Quality, import.
  static const _totalSteps = 2;
  static const _flowVersion = 4;
  // Drafts from flow 3 and earlier counted the retired taste steps.
  static const _retiredLeadingSteps = 2;
  static const _legacyQualityStep = 2;

  @override
  void initState() {
    super.initState();
    unawaited(_initDeviceInfo());
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _initDeviceInfo() async {
    try {
      try {
        await ref.read(settingsProvider.notifier).ensureLoaded();
        _settingsLoaded = true;
      } catch (error, stack) {
        _log.e('Failed to load import settings', error, stack);
      }
      final saved = await _progressStore.readDraft();
      if (!mounted) return;
      final draft = saved == null
          ? <String, dynamic>{}
          : jsonDecode(saved) as Map<String, dynamic>;
      _inCodeGate = draft.isEmpty;
      // Legacy steps preceded music with platform-specific permissions/folder.
      // Only query SDK for migration; fresh installs touch no permission API.
      var legacyBase = _isDesktop || isAndroidTv ? 3 : 4;
      if (draft['flowVersion'] != 2 &&
          draft['flowVersion'] != 3 &&
          draft['flowVersion'] != _flowVersion &&
          draft.isNotEmpty &&
          _platform == TargetPlatform.android &&
          !isAndroidTv) {
        final sdk =
            await PlatformBridge.getAndroidSdkVersion() ??
            (await DeviceInfoPlugin().androidInfo).version.sdkInt;
        legacyBase = sdk >= 37
            ? 6
            : sdk >= 33
            ? 5
            : 4;
      }
      if (!mounted) return;
      final step = draft['step'] as int? ?? 0;
      final version = draft['flowVersion'];
      final stepBeforeQuality = version == 2 || version == 3 || version == 4
          ? step
          : step - legacyBase;
      // Drafts that predate the quality step: later steps shift by one.
      final legacyStep =
          version == 3 || version == 4 || stepBeforeQuality < _legacyQualityStep
          ? stepBeforeQuality
          : stepBeforeQuality + 1;
      // Flow 4 drafts already use the current numbering.
      final migrated = version == _flowVersion
          ? legacyStep
          : legacyStep - _retiredLeadingSteps;
      _currentStep = migrated.clamp(0, _totalSteps - 1);
      _selectedDirectory = draft['directory'] as String?;
      _selectedDirectoryBookmark = draft['bookmark'] as String?;
      _selectedTreeUri = draft['treeUri'] as String?;
      if (draft.isNotEmpty &&
          draft['flowVersion'] != 2 &&
          draft['flowVersion'] != 3 &&
          draft['flowVersion'] != _flowVersion &&
          _platform == TargetPlatform.android) {
        await _recoverLegacyFolderSelection();
      }
    } catch (e, stack) {
      _log.e('Failed to restore setup progress', e, stack);
    } finally {
      if (mounted) {
        _pageController = PageController(initialPage: _currentStep);
        setState(() => _initializing = false);
      }
    }
  }

  Future<void> _recoverLegacyFolderSelection() async {
    final settings = ref.read(settingsProvider);
    // A durable Dart or settings choice wins over an undated native payload.
    if ((_selectedDirectory?.isNotEmpty ?? false) ||
        (_selectedTreeUri?.isNotEmpty ?? false) ||
        (_selectedDirectoryBookmark?.isNotEmpty ?? false) ||
        settings.downloadDirectory.isNotEmpty ||
        settings.downloadTreeUri.isNotEmpty ||
        settings.downloadDirectoryBookmark.isNotEmpty ||
        settings.networkDownloadFolder.isNotEmpty) {
      return;
    }
    final payload = await PlatformBridge.readSetupFolderSelection();
    if (!mounted || payload == null) return;
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return;
    final tree = decoded['tree_uri'];
    if (tree is! String) return;
    final uri = Uri.tryParse(tree);
    if (uri == null ||
        uri.scheme != 'content' ||
        uri.host.isEmpty ||
        uri.pathSegments.length < 2 ||
        uri.pathSegments.first != 'tree' ||
        uri.pathSegments[1].isEmpty) {
      return;
    }
    final name = decoded['display_name'];
    _selectedTreeUri = tree;
    _selectedDirectory = name is String && name.isNotEmpty ? name : tree;
    // Persist recovered selection before acknowledging the native copy.
    await _saveProgress();
    await PlatformBridge.acknowledgeSetupFolderSelection(payload);
  }

  Future<void> _saveProgress({int? step}) async {
    await _progressStore.writeDraft({
      'flowVersion': _flowVersion,
      'step': step ?? _currentStep,
      'directory': _selectedDirectory,
      'bookmark': _selectedDirectoryBookmark,
      'treeUri': _selectedTreeUri,
    });
  }

  Future<void> _completeSetup() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      // A failed initial read leaves the provider with temporary defaults.
      // Never use those defaults to decide whether to replace user storage.
      await ref.read(settingsProvider.notifier).ensureLoaded();
      if (!mounted) return;
      _settingsLoaded = true;
      final settings = ref.read(settingsProvider);
      // Never replace a user's existing plain folder, SAF grant or bookmark.
      if (settings.downloadDirectory.isEmpty &&
          settings.downloadTreeUri.isEmpty &&
          settings.downloadDirectoryBookmark.isEmpty &&
          settings.networkDownloadFolder.isEmpty) {
        if (_platform == TargetPlatform.android &&
            (_selectedTreeUri?.isNotEmpty ?? false)) {
          ref.read(settingsProvider.notifier).setStorageMode('saf');
          ref
              .read(settingsProvider.notifier)
              .setDownloadTreeUri(
                _selectedTreeUri!,
                displayName: _selectedDirectory,
              );
        } else if (_platform == TargetPlatform.android &&
            _selectedDirectory == null) {
          // The default folder (Music/MUSA) resolves on its own; saving the
          // app's private folder here would pin downloads to it for good.
          ref.read(settingsProvider.notifier).setStorageMode('app');
        } else {
          final directory =
              _selectedDirectory ??
              (_isDesktop
                  ? await resolveDesktopDefaultOutputDirectory()
                  : '${(await getApplicationDocumentsDirectory()).path}/$defaultDownloadFolderName') ??
              '${(await getApplicationDocumentsDirectory()).path}/$defaultDownloadFolderName';
          // Legacy selected external folders keep their bookmark and access.
          ref.read(settingsProvider.notifier).setStorageMode('app');
          ref
              .read(settingsProvider.notifier)
              .setDownloadDirectory(
                directory,
                iosBookmark: _selectedDirectoryBookmark,
              );
        }
      }

      ref.read(settingsProvider.notifier).setTutorialComplete();
      await ref.read(settingsProvider.notifier).setFirstLaunchComplete();
      try {
        await _progressStore.clear();
      } catch (error, stack) {
        // Setup is already committed; a failed cleanup must not report that
        // setup failed or prevent navigation. The saved choices remain intact.
        _log.e('Failed to clear completed setup draft', error, stack);
      }

      if (mounted) context.go('/');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.snackbarError(context.friendlyError(e))),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _nextPage() {
    bool canProceed = false;
    if (_currentStep == 0) {
      canProceed = true;
    } else {
      canProceed = _isStepCompleted(_currentStep);
    }

    if (canProceed) {
      unawaited(_goToStep(_currentStep + 1));
    }
  }

  void _prevPage() {
    if (_currentStep == 0 && _codePassed) {
      setState(() => _inCodeGate = true);
      return;
    }
    unawaited(_goToStep(_currentStep - 1));
  }

  bool _redeemUnlocks(PluginCodeRedeemState state) =>
      state.phase == PluginCodePhase.done &&
      state.results.any(
        (result) =>
            result.outcome == PluginCodeOutcome.added ||
            result.outcome == PluginCodeOutcome.updated ||
            result.outcome == PluginCodeOutcome.alreadyAdded,
      );

  Future<void> _leaveCodeGate() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await _saveProgress(step: 0);
      if (!mounted) return;
      setState(() {
        _inCodeGate = false;
        _codePassed = true;
      });
    } catch (e, stack) {
      _log.e('Failed to save setup step', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.setupScreenCouldNotSaveProgressYourSelections,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _goToStep(int step) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await _saveProgress(step: step);
      if (!mounted) return;
      setState(() => _currentStep = step);
      if (MediaQuery.disableAnimationsOf(context)) {
        _pageController?.jumpToPage(step);
      } else {
        await _pageController?.animateToPage(
          step,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    } catch (e, stack) {
      _log.e('Failed to save setup step', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.setupScreenCouldNotSaveProgressYourSelections,
            ),
            action: SnackBarAction(
              label: context.l10n.dialogRetry,
              onPressed: () => unawaited(_goToStep(step)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool _isStepCompleted(int step) => true;

  Widget _buildExpressiveFab(ColorScheme colors) {
    final last = _currentStep == _totalSteps - 1;
    return MaterialExpressiveScope(
      child: M3EExtendedFab(
        label: last ? context.l10n.setupGetStarted : context.l10n.setupNext,
        icon: _isLoading
            ? AppLoadingIndicator(size: 24, color: colors.onPrimary)
            : AppIcon(last ? Icons.check : Icons.arrow_forward),
        color: M3EFabColor.primaryFilled,
        onPressed: _isLoading
            ? null
            : last
            ? _completeSetup
            : _nextPage,
      ),
    );
  }

  Widget _preferencePage(
    String title,
    String description,
    Widget content, {
    bool essentialDescription = false,
  }) {
    final theme = Theme.of(context);
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, largeText ? 8 : 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: largeText
                ? theme.textTheme.titleMedium
                : theme.textTheme.headlineMedium,
          ),
          if (!largeText || essentialDescription) ...[
            const SizedBox(height: 12),
            Text(description, style: theme.textTheme.bodyLarge),
          ],
          const SizedBox(height: 24),
          content,
        ],
      ),
    );
  }

  Widget _buildQualityStep(ColorScheme colors) => _preferencePage(
    context.l10n.setupQualityTitle,
    context.l10n.setupQualityDescription,
    SetupQualityStep(enabled: !_isLoading),
    essentialDescription: true,
  );

  bool get _asksStorageAccess =>
      _platform == TargetPlatform.android && !isAndroidTv;

  Widget _buildStorageAccessCard(ColorScheme colors) {
    final access = ref.watch(storageAccessProvider);
    if (!access.supported || !access.loaded) return const SizedBox.shrink();
    if (access.granted) {
      return ListTile(
        leading: Icon(Icons.check_circle, color: colors.primary),
        title: Text(context.l10n.allFilesAccessEnabledSubtitle),
      );
    }
    if (access.answered) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('setup_storage_access'),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.storageAccessPromptTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(context.l10n.storageAccessPromptMessage),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const ValueKey('setup_storage_not_now'),
                  onPressed: _isLoading ? null : _declineStorageAccess,
                  child: Text(context.l10n.storageAccessNotNow),
                ),
                FilledButton(
                  key: const ValueKey('setup_storage_allow'),
                  onPressed: _isLoading ? null : _allowStorageAccess,
                  child: Text(context.l10n.storageAccessAllow),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _allowStorageAccess() async {
    await requestAllFilesAccess(context, ref);
  }

  Future<void> _declineStorageAccess() =>
      ref.read(storageAccessProvider.notifier).decline();

  Widget _buildImportStep(ColorScheme colors) => _preferencePage(
    context.l10n.setupScreenImportLibrary,
    !_settingsLoaded
        ? context.l10n.setupScreenCouldNotLoadTheDownloadPreference
        : ref.watch(settingsProvider).autoDownloadSavedTracks
        ? context.l10n.setupScreenImportAPlaylistFromAFile
        : context.l10n.setupScreenImportAPlaylistFromAFile2,
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_asksStorageAccess) _buildStorageAccessCard(colors),
        if (!_settingsLoaded)
          TextButton(
            onPressed: _isLoading ? null : _retrySettingsLoad,
            child: Text(context.l10n.dialogRetry),
          ),
        ListTile(
          key: const ValueKey('setup_import_playlist_link'),
          enabled: !_isLoading && _settingsLoaded,
          leading: const Icon(Icons.link),
          title: Text(context.l10n.setupScreenImportPublicLink),
          onTap: _isLoading || !_settingsLoaded ? null : _importPlaylistLink,
        ),
        ListTile(
          key: const ValueKey('setup_import_playlist_file'),
          enabled: !_isLoading && _settingsLoaded,
          leading: const Icon(Icons.file_open_outlined),
          title: Text(context.l10n.setupScreenImportCsvOrM3uFile),
          onTap: _isLoading || !_settingsLoaded ? null : _importPlaylist,
        ),
        for (final platform in ['Spotify', 'Apple Music', 'YouTube Music'])
          ListTile(
            key: ValueKey('setup_import_$platform'),
            enabled: !_isLoading && _settingsLoaded,
            leading: _importSourceIcon(platform),
            title: Text(platform),
            onTap: _isLoading || !_settingsLoaded
                ? null
                : () => _importPlaylistLink(platform: platform),
          ),
      ],
    ),
    essentialDescription: true,
  );

  Future<void> _retrySettingsLoad() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await ref.read(settingsProvider.notifier).ensureLoaded();
      if (mounted) setState(() => _settingsLoaded = true);
    } catch (error, stack) {
      _log.e('Failed to load import settings', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.setupScreenCouldNotLoadTheDownloadPreference2,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _importSourceIcon(String platform) {
    final extensionId = switch (platform) {
      'Spotify' => 'spotify-web',
      'Apple Music' => 'apple-music',
      _ => 'ytmusic-spotiflac',
    };
    final extension = ref
        .watch(extensionProvider)
        .extensions
        .where((extension) => extension.id == extensionId)
        .firstOrNull;
    return ProviderIcon(
      provider: platform,
      filePath: extension?.iconPath,
      size: 40,
    );
  }

  Future<void> _importPlaylist() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await _saveProgress();
      if (!mounted) return;
      await importPlaylistFile(context, ref);
    } catch (e, stack) {
      _log.e('Failed to start playlist import', e, stack);
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.playlistImportFailed),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importPlaylistLink({String? platform}) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await _saveProgress();
      if (mounted) await importPlaylistLink(context, ref, platform: platform);
    } catch (e, stack) {
      _log.e('Failed to start playlist link import', e, stack);
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.playlistImportFailed),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_initializing) {
      return const Scaffold(body: Center(child: AppLoadingIndicator()));
    }

    if (_inCodeGate) return _buildCodeGate(colorScheme);
    final shownTotal = _codePassed ? _totalSteps + 1 : _totalSteps;
    final shownStep = _currentStep + 1 + (_codePassed ? 1 : 0);
    final progress = shownStep / shownTotal;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    final stepMotion = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );

    final isLastStep = _currentStep >= _totalSteps - 1;
    const isOptionalStep = true;
    final nextButton = materialExpressiveEnabled(context)
        ? _buildExpressiveFab(colorScheme)
        : !isLastStep
        ? FloatingActionButton.extended(
            onPressed: !_isLoading && _isStepCompleted(_currentStep)
                ? _nextPage
                : null,
            label: Row(
              children: [
                Text(context.l10n.setupNext),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward),
              ],
            ),
            icon: const SizedBox.shrink(), // Custom layout
          )
        : FloatingActionButton.extended(
            onPressed: _isLoading ? null : _completeSetup,
            label: _isLoading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: colorScheme.onPrimary,
                    ),
                  )
                : Text(context.l10n.setupGetStarted),
            icon: const Icon(Icons.check),
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
          );

    final navigation = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        if (isOptionalStep) ...[
          TextButton(
            onPressed: _isLoading
                ? null
                : isLastStep
                ? _completeSetup
                : _nextPage,
            child: Text(
              largeText
                  ? context.l10n.setupScreenSkip
                  : context.l10n.setupSkipForNow,
            ),
          ),
        ],
        nextButton,
      ],
    );

    Widget content = Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: largeText ? 4 : 16,
          ),
          child: Row(
            children: [
              if (_currentStep > 0 || _codePassed)
                AppIconButton.filledTonal(
                  onPressed: _isLoading ? null : _prevPage,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back),
                  style: IconButton.styleFrom(
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    foregroundColor: colorScheme.onSurfaceVariant,
                  ),
                )
              else
                const SizedBox(width: 48),
              const Spacer(),
              SizedBox(
                width: 48,
                height: 48,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Expressive steps fill on a spring around a wavy
                    // ring; the fallback jumps straight to the step.
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: progress),
                      duration: stepMotion.duration,
                      curve: stepMotion.curve,
                      builder: (context, value, _) =>
                          AppProgressIndicator.circular(
                            wavy: false,
                            value: value,
                            strokeWidth: 4,
                            trackColor: colorScheme.surfaceContainerHighest,
                            color: colorScheme.primary,
                            strokeCap: StrokeCap.round,
                          ),
                    ),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: FittedBox(
                          child: Text(
                            '$shownStep/$shownTotal',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: ExcludeFocus(
            excluding: _isLoading,
            child: AbsorbPointer(
              absorbing: _isLoading,
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildQualityStep(colorScheme),
                  _buildImportStep(colorScheme),
                ],
              ),
            ),
          ),
        ),
        // Reserve the actual navigation height, including wrapped actions at
        // large text sizes. Floating actions would cover the scroll viewport.
        Padding(
          key: const ValueKey('setup_navigation'),
          padding: EdgeInsets.fromLTRB(24, 8, 24, largeText ? 8 : 24),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: navigation,
          ),
        ),
      ],
    );
    if (_isDesktop) {
      content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: content,
        ),
      );
    }

    final scaffold = Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(child: content),
    );
    if (!_isDesktop) return scaffold;
    // Enter moves on, as the default button of a desktop window would.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _advanceFromKeyboard,
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            _advanceFromKeyboard,
      },
      child: Focus(autofocus: true, child: scaffold),
    );
  }

  Widget _buildCodeGate(ColorScheme colorScheme) {
    final state = ref.watch(pluginCodeRedeemProvider);
    final unlocked = _codeUnlocked || _redeemUnlocks(state);
    if (unlocked && !_codeUnlocked) _codeUnlocked = true;
    final total = unlocked ? _totalSteps + 1 : 1;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    final continueLabel = context.l10n.setupNext;
    Widget content = Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: largeText ? 4 : 16,
          ),
          child: Row(
            children: [
              const Spacer(),
              SizedBox(
                width: 48,
                height: 48,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AppProgressIndicator.circular(
                      wavy: false,
                      value: 1 / total,
                      strokeWidth: 4,
                      trackColor: colorScheme.surfaceContainerHighest,
                      color: colorScheme.primary,
                      strokeCap: StrokeCap.round,
                    ),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: FittedBox(
                          child: Text(
                            '1/$total',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ExcludeFocus(
            excluding: _isLoading,
            child: AbsorbPointer(
              absorbing: _isLoading,
              child: _preferencePage(
                context.l10n.setupCodeTitle,
                context.l10n.setupCodeDescription,
                const PluginCodeCard(embedded: true),
                essentialDescription: true,
              ),
            ),
          ),
        ),
        Padding(
          key: const ValueKey('setup_navigation'),
          padding: EdgeInsets.fromLTRB(24, 8, 24, largeText ? 8 : 24),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: _isLoading || state.running
                      ? null
                      : _completeSetup,
                  child: Text(
                    largeText
                        ? context.l10n.setupScreenSkip
                        : context.l10n.setupSkipForNow,
                  ),
                ),
                if (unlocked)
                  FilledButton.icon(
                    key: const ValueKey('setup_code_next'),
                    onPressed: _isLoading || state.running
                        ? null
                        : _leaveCodeGate,
                    icon: const Icon(Icons.arrow_forward),
                    iconAlignment: IconAlignment.end,
                    label: Text(continueLabel),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    if (_isDesktop) {
      content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: content,
        ),
      );
    }
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(child: content),
    );
  }

  void _advanceFromKeyboard() {
    if (_isLoading) return;
    if (_inCodeGate) return;
    if (_currentStep >= _totalSteps - 1) {
      unawaited(_completeSetup());
    } else if (_isStepCompleted(_currentStep)) {
      _nextPage();
    }
  }
}
