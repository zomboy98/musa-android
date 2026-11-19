part of 'main_shell.dart';

extension _MainShellStartupPrompts on _MainShellState {
  Future<void> _repairSafAccessIfNeeded({bool knownLost = false}) async {
    if (!Platform.isAndroid || _safRepairDialogVisible) return;

    var accessLost = knownLost;
    if (!accessLost) {
      final settings = ref.read(settingsProvider);
      if (settings.storageMode != 'saf' || settings.downloadTreeUri.isEmpty) {
        return;
      }
      accessLost = !await PlatformBridge.isSafTreeAccessible(
        settings.downloadTreeUri,
      );
    }
    if (!accessLost || !mounted) return;

    _safRepairDialogVisible = true;
    try {
      await showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var isPickingFolder = false;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return PopScope(
                canPop: false,
                child: AppAlertDialog(
                  icon: AppIcon(
                    Icons.folder_off_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(context.l10n.downloadFolderAccessLostTitle),
                  content: Text(context.l10n.downloadFolderAccessLostSubtitle),
                  actions: [
                    AppDialogAction(
                      onPressed: isPickingFolder
                          ? null
                          : () {
                              final notifier = ref.read(
                                settingsProvider.notifier,
                              );
                              notifier.setStorageMode('app');
                              notifier.setDownloadTreeUri('');
                              notifier.setDownloadDirectory('');
                              Navigator.of(dialogContext).pop();
                            },
                      child: Text(context.l10n.storageAutomaticFolder),
                    ),
                    AppDialogAction(
                      filled: true,
                      onPressed: isPickingFolder
                          ? null
                          : () async {
                              setDialogState(() => isPickingFolder = true);
                              try {
                                if (!await pickAndStoreSafDownloadTree(ref)) {
                                  return;
                                }
                                if (dialogContext.mounted) {
                                  Navigator.of(dialogContext).pop();
                                }
                              } catch (e) {
                                _log.w(
                                  'Failed to repair SAF access from startup: $e',
                                );
                                if (context.mounted) {
                                  showCannotOpenFileSnackBar(context, e);
                                }
                              } finally {
                                if (dialogContext.mounted) {
                                  setDialogState(() => isPickingFolder = false);
                                }
                              }
                            },
                      child: isPickingFolder
                          ? const AppLoadingIndicator(size: 18, strokeWidth: 2)
                          : Text(context.l10n.downloadFolderReselect),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    } finally {
      _safRepairDialogVisible = false;
    }
  }

  /// Asks for access to all files once when downloads would land in private
  /// storage, and offers to move the ones already there once it is granted.
  Future<void> _promptStorageAccessIfNeeded() async {
    if (!Platform.isAndroid) return;
    final settings = ref.read(settingsProvider);
    if (settings.storageMode == 'saf' ||
        settings.networkDownloadFolder.isNotEmpty) {
      return;
    }
    if (settings.downloadDirectory.isNotEmpty) {
      final roots = await const AppPrivateStorage().roots();
      if (!mounted ||
          !isAppPrivateStoragePath(settings.downloadDirectory, roots)) {
        return;
      }
    }
    final access = ref.read(storageAccessProvider.notifier);
    await access.promptIfNeeded();
    if (!mounted) return;
    if (ref.read(storageAccessProvider).granted) {
      await offerPrivateDownloadsMove(context, ref);
    }
  }

  Future<void> _showStorageAccessPrompt() async {
    if (_storageAccessPromptVisible || !mounted) return;
    _storageAccessPromptVisible = true;
    ref.read(storageAccessProvider.notifier).clearPrompt();
    try {
      await showAllFilesAccessPrompt(context, ref);
    } finally {
      _storageAccessPromptVisible = false;
    }
  }

  Future<bool> _checkForUpdates() async {
    if (_hasCheckedUpdate) return false;
    _hasCheckedUpdate = true;

    if (!ref.read(settingsProvider).checkForUpdates) return false;

    final updates = ref.read(appUpdateProvider.notifier);
    await updates.checkAutomatically();
    if (!mounted || !updates.startupDialogPending) return false;

    await updates.markOfferSeen();
    if (!mounted) return false;
    unawaited(startAppUpdateFlow(context, ref));
    return true;
  }

  Future<void> _checkUpdatesOnResume() async {
    if (!_hasCheckedUpdate || !ref.read(settingsProvider).checkForUpdates) {
      return;
    }
    final updates = ref.read(appUpdateProvider.notifier);
    await updates.refreshInstalledBuild();
    await updates.checkOnResume();
    if (!mounted || !await updates.claimNotification()) return;
    final offer = ref.read(appUpdateProvider).offer;
    if (offer == null) return;
    await NotificationService().showAppUpdateAvailable(label: offer.label);
  }

  void _openUpdatesPage() {
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).push(
      slidePageRoute<void>(page: const MornyeSettingsTheme(child: AboutPage())),
    );
  }

  Future<void> _checkAppAnnouncement() async {
    if (_hasCheckedAppAnnouncement) return;
    _hasCheckedAppAnnouncement = true;

    final locale = Localizations.localeOf(context).toLanguageTag();
    final remoteConfigService = AppRemoteConfigService();
    final announcement = await remoteConfigService.fetchActiveAnnouncement(
      locale: locale,
    );
    if (announcement == null || !mounted) return;

    showAppAnnouncementDialog(
      context,
      announcement: announcement,
      onDismiss: () {
        remoteConfigService.markAnnouncementDismissed(announcement.id);
      },
    );
  }

  static const _safMigrationPromptStore = SafMigrationPromptStore();

  Future<void> _checkSafMigration() async {
    if (!Platform.isAndroid || isAndroidTv) return;

    final settings = ref.read(settingsProvider);
    if (!SafMigrationPromptStore.isCandidate(
      settings.storageMode,
      settings.downloadDirectory,
    )) {
      return;
    }

    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    if (androidInfo.version.sdkInt < 29) return;

    if (!await _safMigrationPromptStore.markShownIfNeeded(
      settings.downloadDirectory,
      storageMode: settings.storageMode,
    )) {
      return;
    }

    if (!mounted) return;

    final colorScheme = Theme.of(context).colorScheme;

    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AppAlertDialog(
        icon: AppIcon(
          Icons.folder_special_outlined,
          size: 32,
          color: colorScheme.primary,
        ),
        title: Text(context.l10n.safMigrationTitle),
        content: ConstrainedBox(
          // Keeps the text column readable on tablets/landscape.
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.safMigrationMessage1),
              const SizedBox(height: 12),
              Text(context.l10n.safMigrationMessage2),
            ],
          ),
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.updateLater),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () async {
              Navigator.pop(ctx);
              final saved = await pickAndStoreSafDownloadTree(
                ref,
                setStorageModeFirst: false,
              );
              if (saved) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.safMigrationSuccess)),
                  );
                }
              }
            },
            child: Text(context.l10n.setupSelectFolder),
          ),
        ],
      ),
    );
  }
}
