import 'package:mornye/widgets/guided_tour/guided_tour_anchor.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_anchors.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mornye/utils/extension_error_message.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/extension_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/settings/extension_detail_page.dart';
import 'package:mornye/screens/settings/sources_page.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/plugin_code_card.dart';
import 'package:mornye/screens/repo_tab.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/extension_storage_setting.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/extension_health.dart';
import 'package:mornye/services/foreground_session_renewal.dart';
import 'package:mornye/services/bundled_extensions.dart';
import 'package:mornye/services/platform_bridge.dart';

part 'extensions_page_widgets.dart';

final _hasBundledProvider = FutureProvider<bool>(
  (ref) => hasBundledExtensions(),
);

String _sessionDiagnosticText(
  BuildContext context,
  ForegroundSessionDiagnostic diagnostic,
) {
  if (diagnostic.checking) {
    return context.l10n.extensionsPageCheckingSessions;
  }
  if (diagnostic.counts.isEmpty && diagnostic.unknown == 0) {
    return context.l10n.extensionsPageNoCheckAvailable;
  }
  final parts = <String>[];
  void add(SessionRenewalStatus status, String label) {
    final count = diagnostic.counts[status] ?? 0;
    if (count > 0) parts.add('$label: $count');
  }

  add(SessionRenewalStatus.refreshed, context.l10n.extensionsPageRefreshed);
  add(SessionRenewalStatus.validUntil, context.l10n.extensionsPageValid);
  add(SessionRenewalStatus.blocked, context.l10n.extensionsPageBlocked);
  add(SessionRenewalStatus.missing, context.l10n.extensionsPageNoSession);
  add(
    SessionRenewalStatus.invalid,
    context.l10n.extensionsPageInvalidOrExpired,
  );
  add(SessionRenewalStatus.unavailable, context.l10n.extensionsPageUnavailable);
  add(
    SessionRenewalStatus.notApplicable,
    context.l10n.extensionsPageNotApplicable,
  );
  add(SessionRenewalStatus.disabled, context.l10n.extensionsPageDisabled);
  if (diagnostic.unknown > 0) {
    parts.add('${context.l10n.extensionsPageUnknown}: ${diagnostic.unknown}');
  }
  final expiry = diagnostic.earliestExpiry?.toLocal();
  if (expiry != null) {
    final locale = MaterialLocalizations.of(context);
    parts.add(
      '${context.l10n.extensionsPageEarliestExpiry}: ${locale.formatMediumDate(expiry)} ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(expiry))}',
    );
  }
  return '${context.l10n.extensionsPageLastCheck}: ${parts.join(' · ')}';
}

class ForegroundSessionDiagnosticView extends StatelessWidget {
  const ForegroundSessionDiagnosticView({super.key, required this.diagnostic});
  final ForegroundSessionDiagnostic diagnostic;

  @override
  Widget build(BuildContext context) => Text(
    _sessionDiagnosticText(context, diagnostic),
    style: Theme.of(context).textTheme.bodySmall,
  );
}

/// Explains the scope of the existing per-extension switches.
class ExtensionActivationSummary extends StatelessWidget {
  const ExtensionActivationSummary({super.key, required this.activeNames});

  final List<String> activeNames;

  @override
  Widget build(BuildContext context) {
    final active = activeNames.isEmpty
        ? context.l10n.extensionsPageNone
        : activeNames.join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Text(
        context.l10n.extensionsPageActiveActiveUseTheSwitchesTo(active),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class ExtensionsPage extends ConsumerStatefulWidget {
  const ExtensionsPage({super.key});

  @override
  ConsumerState<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends ConsumerState<ExtensionsPage> {
  bool? _foregroundSessionRenewal;

  Future<void> _loadForegroundSessionRenewal() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(
        () => _foregroundSessionRenewal =
            prefs.getBool(foregroundSessionRenewalPreference) ?? true,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeExtensions();
    if (Platform.isAndroid) _loadForegroundSessionRenewal();
  }

  Future<void> _initializeExtensions() async {
    final extState = ref.read(extensionProvider);
    if (!extState.isInitialized) {
      try {
        await ref.read(extensionProvider.notifier).ensureInitialized();
      } catch (_) {
        // The provider exposes preparation failures in the existing error UI.
      }
    } else {
      ref.read(extensionProvider.notifier).refreshEnabledExtensionHealth();
    }
  }

  @override
  Widget build(BuildContext context) {
    final extState = ref.watch(extensionProvider);
    final sessionDiagnostic = ref.watch(foregroundSessionDiagnosticProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final installButton = AppActionButton(
      onPressed: _installExtension,
      icon: const AppIcon(Icons.add),
      label: Text(context.l10n.extensionsInstallButton),
      outlined: context.isMornye,
      glass: false,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.extensionsTitle),

            const SliverToBoxAdapter(child: ExtensionStorageSetting()),
            if (Platform.isAndroid)
              SliverToBoxAdapter(
                child: SettingsGroup(
                  children: [
                    SettingsSwitchItem(
                      icon: Icons.refresh,
                      title: context
                          .l10n
                          .extensionsPageRenewSessionsWhileAppIsOpen,
                      subtitle: context
                          .l10n
                          .extensionsPageChecksExistingSessionsWhileTheApp,
                      value: _foregroundSessionRenewal ?? false,
                      enabled: _foregroundSessionRenewal != null,
                      onChanged: (value) async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool(
                          foregroundSessionRenewalPreference,
                          value,
                        );
                        if (!mounted) return;
                        setState(() => _foregroundSessionRenewal = value);
                        if (!value) {
                          ref
                              .read(extensionProvider.notifier)
                              .stopForegroundSessionChecks();
                        }
                        if (value) {
                          ref
                              .read(extensionProvider.notifier)
                              .checkForegroundSessions();
                        }
                      },
                      showDivider: false,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: ForegroundSessionDiagnosticView(
                        diagnostic: sessionDiagnostic,
                      ),
                    ),
                  ],
                ),
              ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [
                  SettingsItem(
                    icon: Icons.swap_vert,
                    title: context.l10n.sourcesAndOrderTitle,
                    subtitle: context.l10n.sourcesEntryHint,
                    onTap: () =>
                        pushPage<void>(context, (_) => const SourcesPage()),
                  ),
                  SettingsItem(
                    icon: Icons.storefront_outlined,
                    title: context.l10n.storeTitle,
                    subtitle: context.l10n.settingsRepoSubtitle,
                    showDivider: false,
                    onTap: () => pushPage<void>(
                      context,
                      (_) => Scaffold(
                        appBar: AppBar(title: Text(context.l10n.storeTitle)),
                        body: const RepoTab(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SliverToBoxAdapter(
              child: TourAnchor(
                target: GuidedTourTarget.code,
                child: PluginCodeCard(),
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.extensionsInstalledSection,
              ),
            ),

            if (extState.isLoading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: AppLoadingIndicator()),
                ),
              ),

            if (extState.error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        AppIcon(
                          Icons.error_outline,
                          color: colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                extensionErrorTitle(
                                  context.l10n,
                                  extState.errorOrigin,
                                ),
                                style: TextStyle(
                                  color: colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                context.friendlyError(extState.error),
                                style: TextStyle(
                                  color: colorScheme.onErrorContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            if (extState.extensions.isEmpty && !extState.isLoading)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 16 + wideListInset(context),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        AppIcon(
                          Icons.extension_outlined,
                          size: 48,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          context.l10n.extensionsNoExtensions,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.l10n.extensionsNoExtensionsSubtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            if (extState.extensions.isNotEmpty)
              SliverToBoxAdapter(
                child: ExtensionActivationSummary(
                  activeNames: extState.extensions
                      .where((extension) => extension.enabled)
                      .map((extension) => extension.displayName)
                      .toList(),
                ),
              ),

            if (extState.extensions.isNotEmpty)
              SliverToBoxAdapter(
                child: SettingsGroup(
                  connected: true,
                  children: extState.extensions.asMap().entries.map((entry) {
                    final index = entry.key;
                    final ext = entry.value;
                    return _ExtensionItem(
                      extension: ext,
                      healthStatus: extState.healthStatuses[ext.id],
                      showDivider: index < extState.extensions.length - 1,
                      onTap: () => pushPage<void>(
                        context,
                        (_) => ExtensionDetailPage(extensionId: ext.id),
                      ),
                      onToggle: (enabled) => ref
                          .read(extensionProvider.notifier)
                          .setExtensionEnabled(ext.id, enabled),
                    );
                  }).toList(),
                ),
              ),

            SliverToBoxAdapter(
              child: SettingsSearchTarget(
                label: context.l10n.extensionsInstallButton,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Same edges as the extension group above.
                    final inset = settingsHorizontalInset(
                      context,
                      constraints.maxWidth,
                    );
                    return Padding(
                      padding: EdgeInsets.fromLTRB(inset, 16, inset, 16),
                      child: context.isMornye
                          ? MornyeGlassPanel.overlay(
                              radius: 28,
                              samplesBackdrop: false,
                              child: installButton,
                            )
                          : installButton,
                    );
                  },
                ),
              ),
            ),

            if (ref.watch(_hasBundledProvider).value ?? false)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextButton.icon(
                    onPressed: extState.isLoading || !extState.isInitialized
                        ? null
                        : _installBundledExtensions,
                    icon: const AppIcon(Icons.inventory_2_outlined),
                    label: Text(context.l10n.extensionsBundledInstall),
                  ),
                ),
              ),

            SliverToBoxAdapter(
              child: SettingsInfoCard(
                glass: true,
                icon: Icons.info_outline,
                tone: SettingsInfoTone.warning,
                message: context.l10n.extensionsInfoTip,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _installBundledExtensions() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.extensionsBundledInstall),
        content: Text(context.l10n.extensionsBundledConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.extensionsBundledInstall),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(extensionProvider.notifier).installBundledExtensions();
  }

  Future<void> _installExtension() async {
    final selectedFiles = await FilePicker.pickFiles(type: FileType.any);
    if (selectedFiles.isEmpty) return;

    final hasInvalidFile = selectedFiles.any((file) {
      final lowerName = file.name.toLowerCase();
      return !lowerName.endsWith('.mornye-ext') &&
          !lowerName.endsWith('.spotiflac-ext') &&
          !lowerName.endsWith('.sflx');
    });
    if (hasInvalidFile) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.snackbarSelectExtFile),
        );
      }
      return;
    }

    Directory? materializedDir;
    try {
      final extensionPaths = <String>[];
      for (final selectedFile in selectedFiles) {
        final localPath = selectedFile.path;
        if (localPath != null && localPath.isNotEmpty) {
          extensionPaths.add(localPath);
          continue;
        }

        materializedDir ??= await Directory.systemTemp.createTemp(
          'mornye_extension_import_',
        );
        final safeName = p.basename(selectedFile.name);
        final materializedFile = File(
          p.join(materializedDir.path, '${extensionPaths.length}_$safeName'),
        );
        await materializedFile.writeAsBytes(
          await selectedFile.readAsBytes(),
          flush: true,
        );
        extensionPaths.add(materializedFile.path);
      }

      final installResult = await ref
          .read(extensionProvider.notifier)
          .installExtensions(extensionPaths);

      if (mounted) {
        final message = _getInstallResultMessage(installResult);
        ref.read(extensionProvider.notifier).clearError();

        showAppSnackBar(context, content: Text(message));
      }
    } finally {
      try {
        if (materializedDir != null && await materializedDir.exists()) {
          await materializedDir.delete(recursive: true);
        }
      } catch (_) {
        // The extension has already been copied into app storage.
      }
    }
  }

  String _getInstallResultMessage(ExtensionInstallBatchResult result) {
    if (result.attempted == 0) {
      return context.l10n.snackbarSelectExtFile;
    }

    if (!result.hasFailures) {
      if (result.installed == 1) {
        return context.l10n.extensionsInstalledSuccess;
      }
      return context.l10n.extensionsInstalledCount(result.installed);
    }

    if (result.anyInstalled) {
      return context.l10n.extensionsInstallPartialSuccess(
        result.installed,
        result.attempted,
      );
    }

    final firstError = result.failures.values.firstOrNull;
    return _getFriendlyErrorMessage(firstError);
  }

  String _getFriendlyErrorMessage(String? error) {
    return context.friendlyError(
      error,
      fallback: context.l10n.snackbarFailedToInstall,
    );
  }
}
