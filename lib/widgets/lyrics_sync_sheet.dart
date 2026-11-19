import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_timing_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_sync.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

/// Opens the per-track lyrics timing control for the song playing.
Future<void> showLyricsSyncSheet(
  BuildContext context,
  PlayerMetadataController metadata,
) => showAppBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  title: context.l10n.lyricsSyncTitle,
  builder: (_) => LyricsSyncControl(metadata: metadata),
);

String _signedSeconds(int ms) {
  final text = (ms.abs() / 1000).toStringAsFixed(1);
  return ms > 0 ? '+$text' : (ms < 0 ? '-$text' : text);
}

/// Nudge buttons, reset and tap-to-sync for the timing of one track. The
/// shift is stored per track and added to the global lyrics timing setting.
class LyricsSyncControl extends ConsumerStatefulWidget {
  const LyricsSyncControl({super.key, required this.metadata});

  final PlayerMetadataController metadata;

  @override
  ConsumerState<LyricsSyncControl> createState() => _LyricsSyncControlState();
}

class _LyricsSyncControlState extends ConsumerState<LyricsSyncControl> {
  int? _tapLine;

  List<LyricLine> get _lines => [
    for (final line in widget.metadata.lyrics.lines)
      if (!line.isBackground && line.text.trim().isNotEmpty) line,
  ];

  /// What the track is shifted by now, apart from the global setting.
  int get _visibleMs =>
      widget.metadata.trackOffsetMs ??
      widget.metadata.autoOffsetMs +
          (ref.read(lyricsBluetoothRouteProvider)
              ? kBluetoothLyricsCompensationMs
              : 0);

  Duration get _position =>
      ref.read(playbackStateProvider).value?.position ?? Duration.zero;

  int _defaultLine(List<LyricLine> lines) {
    final global = ref.read(themeProvider).lyricsOffsetMs;
    final shift = global + _visibleMs;
    final index = lines.indexWhere(
      (line) => line.time + Duration(milliseconds: shift) > _position,
    );
    return index < 0 ? lines.length - 1 : index;
  }

  Future<void> _nudge(int deltaMs) =>
      widget.metadata.setTrackOffset(_visibleMs + deltaMs);

  Future<void> _tap(List<LyricLine> lines, int index) async {
    final offset = trackOffsetFromTap(
      tapPosition: _position,
      lineTime: lines[index].time,
      globalMs: ref.read(themeProvider).lyricsOffsetMs,
    );
    await widget.metadata.setTrackOffset(offset);
    if (mounted) {
      showAppSnackBar(context, content: Text(context.l10n.lyricsSyncSaved));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.metadata,
    builder: (context, _) {
      final l10n = context.l10n;
      final lines = _lines;
      final track = widget.metadata.trackOffsetMs;
      final index = lines.isEmpty
          ? -1
          : (_tapLine ?? _defaultLine(lines)).clamp(0, lines.length - 1);
      Widget nudge(String key, String label, int delta) => OutlinedButton(
        key: ValueKey(key),
        onPressed: () => _nudge(delta),
        child: Text(label),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              key: const ValueKey('lyrics-sync-value'),
              track == null
                  ? '${l10n.lyricsSyncAutomatic} '
                        '(${l10n.lyricsSyncValue(_signedSeconds(_visibleMs))})'
                  : l10n.lyricsSyncValue(_signedSeconds(track)),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                nudge('lyrics-sync-minus-1', '-1 s', -1000),
                nudge('lyrics-sync-minus-01', '-0,1 s', -100),
                nudge('lyrics-sync-plus-01', '+0,1 s', 100),
                nudge('lyrics-sync-plus-1', '+1 s', 1000),
                TextButton(
                  key: const ValueKey('lyrics-sync-reset'),
                  onPressed: track == null
                      ? null
                      : () => widget.metadata.setTrackOffset(null),
                  child: Text(l10n.lyricsSyncReset),
                ),
              ],
            ),
            if (index >= 0) ...[
              const Divider(height: 32),
              Text(
                l10n.lyricsSyncTap,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                l10n.lyricsSyncTapHint,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('lyrics-sync-line-previous'),
                    onPressed: index > 0
                        ? () => setState(() => _tapLine = index - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      lines[index].text,
                      key: const ValueKey('lyrics-sync-line'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('lyrics-sync-line-next'),
                    onPressed: index < lines.length - 1
                        ? () => setState(() => _tapLine = index + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              FilledButton(
                key: const ValueKey('lyrics-sync-now'),
                onPressed: () => _tap(lines, index),
                child: Text(l10n.lyricsSyncNow),
              ),
            ],
            const Divider(height: 24),
            SwitchListTile(
              key: const ValueKey('lyrics-sync-estimated'),
              contentPadding: EdgeInsets.zero,
              value: widget.metadata.estimatedSyncEnabled,
              onChanged: widget.metadata.setEstimatedSyncEnabled,
              title: Text(l10n.lyricsSyncEstimatedSetting),
            ),
          ],
        ),
      );
    },
  );
}
