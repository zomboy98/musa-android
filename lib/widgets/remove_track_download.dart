import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/track_download_removal.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';

/// Deletes the local files of [track] everywhere it shows as downloaded and
/// tells the user what happened. With [confirm] the user is asked first, for
/// controls that are not obviously a delete button.
Future<void> removeTrackDownloadWithFeedback(
  BuildContext context,
  Track track, {
  bool confirm = false,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  if (confirm) {
    final accepted = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(dialogContext.l10n.trackRemoveFromDevice),
        content: Text('${track.name} • ${track.artistName}'),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDestructive: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.dialogDelete),
          ),
        ],
      ),
    );
    if (accepted != true) return;
  }
  try {
    final removed = await removeTrackDownloads(container, track);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          removed > 0
              ? l10n.snackbarDeletedTracks(1)
              : l10n.trackFileUnavailable,
        ),
      ),
    );
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.trackFileUnavailable)));
  }
}
