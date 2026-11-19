import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/lyrics_align_picker.dart';
import 'package:mornye/widgets/lyrics_sync_sheet.dart';

enum _LineAction { share, correct, restore, sync }

/// What a long press on a sung line offers when its text comes from a
/// provider: sharing it, correcting it on this device, or going back to the
/// provider's wording.
Future<void> showLyricsLineActions(
  BuildContext context,
  PlayerMetadataController metadata,
  LyricLine line, {
  ValueChanged<LyricLine?>? onShare,
  bool previewAlign = false,
}) async {
  final slot = metadata.correctionSlot(line.time);
  final canSync = metadata.canAdjustSync;
  final l10n = context.l10n;
  final corrected =
      slot != null && metadata.correctedLineTimesMs.contains(slot);
  final action = await showAppBottomSheet<_LineAction>(
    context: context,
    useRootNavigator: true,
    title: line.text,
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _AlignOption(preview: previewAlign),
        if (canSync)
          AppSheetOption(
            key: const ValueKey('lyrics-line-sync'),
            leading: const Icon(Icons.sync),
            title: Text(l10n.lyricsSyncTitle),
            onTap: () => Navigator.pop(sheetContext, _LineAction.sync),
          ),
        if (slot != null)
          AppSheetOption(
            key: const ValueKey('lyrics-line-correct'),
            leading: const Icon(Icons.edit_outlined),
            title: Text(l10n.lyricsLineCorrect),
            onTap: () => Navigator.pop(sheetContext, _LineAction.correct),
          ),
        if (corrected)
          AppSheetOption(
            key: const ValueKey('lyrics-line-restore'),
            leading: const Icon(Icons.restore),
            title: Text(l10n.lyricsLineRestore),
            onTap: () => Navigator.pop(sheetContext, _LineAction.restore),
          ),
        if (onShare != null)
          AppSheetOption(
            leading: const Icon(Icons.ios_share),
            title: Text(l10n.lyricsShareTitle),
            onTap: () => Navigator.pop(sheetContext, _LineAction.share),
          ),
      ],
    ),
  );
  if (!context.mounted || action == null) return;
  switch (action) {
    case _LineAction.share:
      onShare?.call(line);
    case _LineAction.sync:
      await showLyricsSyncSheet(context, metadata);
    case _LineAction.correct:
      await _correct(context, metadata, slot!);
    case _LineAction.restore:
      await _run(
        context,
        () => metadata.restoreLyricsLine(slot!),
        l10n.lyricsLineRestored,
      );
  }
}

class _AlignOption extends ConsumerWidget {
  const _AlignOption({required this.preview});

  final bool preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return Padding(
      key: const ValueKey('lyrics-line-align'),
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.lyricsAlignTitle,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          if (preview)
            LyricsAlignSelector(
              value: settings.playerLyricsPreviewAlign,
              onChanged: (align) =>
                  notifier.setPlayerLyricsPreviewAlign(align!),
            )
          else
            LyricsAlignSelector(
              auto: true,
              value: settings.lyricsAlign.explicit,
              onChanged: (align) => notifier.setLyricsAlign(
                align == null
                    ? LyricsViewAlign.auto
                    : LyricsViewAlign.values.byName(align.name),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> _correct(
  BuildContext context,
  PlayerMetadataController metadata,
  int slot,
) async {
  final current = metadata.lyrics.lines
      .where((line) => metadata.correctionSlot(line.time) == slot)
      .map((line) => line.text)
      .firstOrNull;
  final text = await showAppDialog<String>(
    context: context,
    builder: (_) => _LineCorrectionDialog(
      initial: current ?? metadata.originalLineText(slot) ?? '',
    ),
  );
  if (!context.mounted || text == null) return;
  await _run(
    context,
    () => metadata.correctLyricsLine(slot, text),
    context.l10n.lyricsLineCorrectionSaved,
  );
}

Future<void> _run(
  BuildContext context,
  Future<void> Function() change,
  String done,
) async {
  final l10n = context.l10n;
  try {
    await change();
    if (context.mounted) showAppSnackBar(context, content: Text(done));
  } catch (_) {
    if (context.mounted) {
      showAppSnackBar(context, content: Text(l10n.lyricsLineCorrectionFailed));
    }
  }
}

class _LineCorrectionDialog extends StatefulWidget {
  const _LineCorrectionDialog({required this.initial});

  final String initial;

  @override
  State<_LineCorrectionDialog> createState() => _LineCorrectionDialogState();
}

class _LineCorrectionDialogState extends State<_LineCorrectionDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: Text(context.l10n.lyricsLineCorrect),
    content: TextField(
      key: const ValueKey('lyrics-line-field'),
      controller: _controller,
      autofocus: true,
      minLines: 1,
      maxLines: 4,
      textInputAction: TextInputAction.done,
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      AppDialogAction(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: true,
        onPressed: () => Navigator.pop(context, _controller.text),
        child: Text(context.l10n.dialogSave),
      ),
    ],
  );
}
