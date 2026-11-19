import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart'
    show playbackResumeProvider;
import 'package:mornye/providers/storage_access_provider.dart';
import 'package:mornye/services/app_private_storage.dart';
import 'package:mornye/services/private_downloads_migration.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/batch_progress_dialog.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/settings_group.dart';

const _moveOfferDeclinedKey = 'private_downloads_move_offer_declined_v1';

/// Number of downloads still kept in the private folders of the app.
final privateDownloadsCountProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  if (!Platform.isAndroid) return 0;
  final folders = await const AppPrivateStorage().downloadFolders();
  if (folders.isEmpty) return 0;
  final plan = await buildPrivateDownloadsPlan(
    privateFolders: folders,
    targetRoot: folders.first,
  );
  return plan.count;
});

/// Asks for access to all files and opens the system screen on "Allow".
/// Returns whether the access ends up granted.
Future<bool> showAllFilesAccessPrompt(
  BuildContext context,
  WidgetRef ref,
) async {
  final access = ref.read(storageAccessProvider.notifier);
  final allow = await showAppConfirmDialog(
    context,
    title: context.l10n.storageAccessPromptTitle,
    message: context.l10n.storageAccessPromptMessage,
    confirmLabel: context.l10n.storageAccessAllow,
    cancelLabel: context.l10n.storageAccessNotNow,
    confirmIsDefault: true,
    barrierDismissible: false,
  );
  if (!allow) {
    await access.decline();
    return false;
  }
  if (!context.mounted) return false;
  return requestAllFilesAccess(context, ref);
}

/// Requests the permission through the system screen. When it was denied for
/// good, offers the app settings page.
Future<bool> requestAllFilesAccess(BuildContext context, WidgetRef ref) async {
  final access = ref.read(storageAccessProvider.notifier);
  final result = await access.request();
  if (result == AllFilesAccessResult.permanentlyDenied && context.mounted) {
    final shouldOpen = await showAppConfirmDialog(
      context,
      title: context.l10n.setupStorageAccessRequired,
      message: context.l10n.allFilesAccessDeniedMessage,
      confirmLabel: context.l10n.setupOpenSettings,
      confirmIsDefault: true,
    );
    if (shouldOpen) await openAppSettings();
  }
  return result == AllFilesAccessResult.granted;
}

/// Warning shown while downloads are kept in private app storage.
class PrivateStorageBanner extends ConsumerWidget {
  const PrivateStorageBanner({super.key, this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(storageAccessProvider);
    if (!access.supported || !access.loaded) return const SizedBox.shrink();
    final count = ref.watch(privateDownloadsCountProvider).value ?? 0;
    if (count == 0 && !(access.usingPrivateFallback && !access.granted)) {
      return const SizedBox.shrink();
    }
    final Widget action = access.granted
        ? ExpressiveButton(
            tonal: true,
            onPressed: () => movePrivateDownloadsToShared(context, ref),
            child: Text(context.l10n.privateStorageMoveAction),
          )
        : ExpressiveButton(
            tonal: true,
            onPressed: () async {
              await showAllFilesAccessPrompt(context, ref);
              ref.invalidate(privateDownloadsCountProvider);
            },
            child: Text(context.l10n.privateStorageAllowAction),
          );
    return SettingsInfoCard(
      icon: Icons.warning_amber_outlined,
      tone: SettingsInfoTone.warning,
      message: context.l10n.privateStorageWarning,
      margin: margin ?? const EdgeInsets.fromLTRB(16, 8, 16, 4),
      action: action,
    );
  }
}

/// Offers the move once, when access exists and downloads are still private.
Future<void> offerPrivateDownloadsMove(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!Platform.isAndroid) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_moveOfferDeclinedKey) ?? false) return;
  } catch (_) {}
  if (!context.mounted) return;
  final access = ref.read(storageAccessProvider.notifier);
  if (!await access.refresh() || !context.mounted) return;
  await movePrivateDownloadsToShared(context, ref, offer: true);
}

/// Plan → explicit confirmation → copy, verify, relink, delete → summary.
/// Nothing is moved or deleted before the user confirms.
Future<void> movePrivateDownloadsToShared(
  BuildContext context,
  WidgetRef ref, {
  bool offer = false,
}) async {
  final queue = ref.read(downloadQueueProvider.notifier);
  final history = ref.read(downloadHistoryProvider.notifier);
  final library = ref.read(localLibraryProvider.notifier);
  final collections = ref.read(libraryCollectionsProvider.notifier);
  final access = ref.read(storageAccessProvider.notifier);
  final messenger = ScaffoldMessenger.of(context);
  if (queue.hasActiveDownloads) {
    if (!offer) {
      messenger.showSnackBar(
        SnackBar(content: Text(context.l10n.reorganizeLibraryBusy)),
      );
    }
    return;
  }
  if (!await access.refresh()) {
    if (offer || !context.mounted) return;
    if (!await showAllFilesAccessPrompt(context, ref)) return;
  }
  if (!context.mounted) return;

  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AppAlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Text(dialogContext.l10n.reorganizeLibraryScanning),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  PrivateDownloadsPlan? plan;
  Object? planError;
  try {
    plan = await queue.planPrivateDownloadsMove();
  } catch (e) {
    planError = e;
  }
  if (navigator.mounted) navigator.pop();
  if (!context.mounted) return;
  ref.invalidate(privateDownloadsCountProvider);

  if (plan == null) {
    if (!offer) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.reorganizeLibraryFailed(
              context.friendlyError(planError ?? 'unknown'),
            ),
          ),
        ),
      );
    }
    return;
  }
  if (plan.isEmpty) return;
  final ready = plan.plan;

  final confirmed = await showAppConfirmDialog(
    context,
    title: context.l10n.privateStorageMoveTitle(plan.count),
    message: context.l10n.privateStorageMoveMessage,
    confirmLabel: context.l10n.privateStorageMoveConfirm,
    confirmIsDefault: true,
  );
  if (!confirmed) {
    if (offer) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_moveOfferDeclinedKey, true);
      } catch (_) {}
    }
    return;
  }
  if (!context.mounted) return;

  var cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: context.l10n.reorganizeLibraryMoving,
    total: ready.moves.length,
    icon: Icons.drive_file_move_outlined,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  final LibraryReorganizationResult result;
  try {
    result = await queue.applyLibraryReorganization(
      ready,
      isCancelled: () => cancelled,
      onProgress: (done, move) =>
          BatchProgressDialog.update(current: done, detail: move.trackName),
    );
    await history.reloadFromStorage();
    await library.reloadFromStorage();
    await collections.reloadFromDatabase();
    if (context.mounted) ref.invalidate(playbackResumeProvider);
  } catch (error) {
    if (context.mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.reorganizeLibraryFailed(context.friendlyError(error)),
          ),
        ),
      );
    }
    return;
  } finally {
    if (context.mounted && !cancelled) BatchProgressDialog.dismiss(context);
    ref.invalidate(privateDownloadsCountProvider);
  }

  if (!context.mounted) return;
  final failed = result.failed + result.missing;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? context.l10n.reorganizeLibraryDone(
                  result.moved,
                  ready.moves.length,
                )
              : context.l10n.reorganizeLibraryDoneWithFailures(
                  result.moved,
                  ready.moves.length,
                  failed,
                ),
        ),
      ),
    );
}
