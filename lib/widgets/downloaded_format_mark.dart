import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/widgets/remove_track_download.dart';
import 'package:mornye/widgets/tap_target_expander.dart';
import 'package:mornye/widgets/quality_mark_art.dart';

const double downloadedFormatMarkWidth = 56;
const double downloadedFormatMarkHeight = 16;
const double _iconSize = 14;
const double _textSize = 10;

/// Format of a downloaded file; a null [mark] is a download whose format is
/// unknown.
class DownloadedFormat {
  const DownloadedFormat(this.mark, [this.detail]);

  static const neutral = DownloadedFormat(null);

  final QualityMark? mark;
  final String? detail;

  factory DownloadedFormat.fromHistory(DownloadHistoryItem item) =>
      DownloadedFormat.fromFile(
        filePath: item.filePath,
        format: item.format,
        quality: item.quality,
        bitDepth: item.bitDepth,
        sampleRate: item.sampleRate,
        bitrate: item.bitrate,
      );

  factory DownloadedFormat.fromFile({
    required String filePath,
    String? format,
    String? quality,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
  }) {
    final codec = _codecOf(format, filePath);
    if (codec.isEmpty && (quality ?? '').trim().isEmpty) {
      return neutral;
    }
    final stored = quality ?? '';
    var declared = qualityMarkFor(stored, codec);
    if (isDolbyMark(declared) && !isDolbyCodec(codec)) {
      declared = qualityMarkFor('', codec);
    }
    var mark = verifiedQualityMark(
      declared: declared,
      codec: codec,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
    );
    final unmeasured = bitDepth == null && sampleRate == null;
    if (unmeasured &&
        (declared == QualityMark.hiRes || declared == QualityMark.max) &&
        (codec.contains('flac') || codec.contains('alac'))) {
      mark = declared;
    }
    if (mark == QualityMark.m4a &&
        (stored.toLowerCase().contains('lossless') || (bitDepth ?? 0) >= 24)) {
      mark = QualityMark.alac;
    }
    if (isDolbyMark(mark) && !isDolbyCodec(codec)) {
      mark = QualityMark.lossy;
    }
    return DownloadedFormat(
      mark,
      qualityDetailFor(
        stored,
        codec,
        sampleRate: sampleRate,
        bitDepth: bitDepth,
        bitrateKbps: bitrate,
        lossy: isLossyMark(mark),
      ),
    );
  }

  static String _codecOf(String? declared, String path) {
    final format = declared?.trim().toLowerCase() ?? '';
    if (format.isNotEmpty) return format;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || path.length - dot > 6) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadedFormat && other.mark == mark && other.detail == detail;

  @override
  int get hashCode => Object.hash(mark, detail);
}

/// Format of the downloaded file of a track, read from the in-memory download
/// history; null when the history holds no file for it.
final trackDownloadedFormatProvider = Provider.autoDispose
    .family<DownloadedFormat?, Track>(
      (ref, track) => ref.watch(
        downloadHistoryProvider.select((state) {
          final isrc = track.isrc;
          final item =
              state.getBySpotifyId(track.id) ??
              (isrc == null || isrc.isEmpty ? null : state.getByIsrc(isrc)) ??
              state.findByTrackAndArtist(track.name, track.artistName);
          return item == null ? null : DownloadedFormat.fromHistory(item);
        }),
      ),
    );

/// Micro logo of the real format of a downloaded file. It lives in a fixed
/// box of [downloadedFormatMarkWidth] by [downloadedFormatMarkHeight], so it
/// never wraps or changes the height of its row.
class DownloadedFormatMark extends ConsumerWidget {
  const DownloadedFormatMark({
    super.key,
    this.track,
    this.format,
    this.onArtwork = false,
    this.removable = false,
  });

  final Track? track;
  final DownloadedFormat? format;
  final bool onArtwork;

  /// Tapping the mark of a [track] offers to delete its local files. Only
  /// for rows whose mark is not mistaken for a plain label.
  final bool removable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved =
        format ??
        (track == null
            ? null
            : ref.watch(trackDownloadedFormatProvider(track!)));
    final mark = resolved?.mark;
    final l10n = context.l10n;
    final downloaded = l10n.librarySourceDownloaded;
    final name = mark == null ? null : qualityMarkText(context, mark).name;
    final label = name == null ? downloaded : '$downloaded · $name';
    final scheme = Theme.of(context).colorScheme;
    final fg = onArtwork ? Colors.white : scheme.onSurfaceVariant;
    final glyph = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerEnd,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mark == null)
            Icon(Icons.download_done_rounded, size: _iconSize, color: fg)
          else ...[
            QualityMarkIcon(mark: mark, size: _iconSize, color: fg),
            const SizedBox(width: 3),
            Text(
              name!,
              maxLines: 1,
              softWrap: false,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: fg,
                fontSize: _textSize,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ],
        ],
      ),
    );
    final markWidget = Semantics(
      label: label,
      container: true,
      child: ExcludeSemantics(
        child: Tooltip(
          message: resolved?.detail == null
              ? label
              : '$label (${resolved!.detail})',
          excludeFromSemantics: true,
          child: SizedBox(
            key: ValueKey(
              mark == null
                  ? 'downloaded-format-mark-neutral'
                  : 'downloaded-format-mark-${mark.name}',
            ),
            width: downloadedFormatMarkWidth,
            height: downloadedFormatMarkHeight,
            child: DecoratedBox(
              decoration: onArtwork
                  ? BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                    )
                  : const BoxDecoration(),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: onArtwork ? 3 : 0),
                child: glyph,
              ),
            ),
          ),
        ),
      ),
    );
    final target = track;
    if (!removable || target == null) return markWidget;
    void remove() =>
        removeTrackDownloadWithFeedback(context, target, confirm: true);
    return TapTargetExpander(
      child: Semantics(
        button: true,
        onTap: remove,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: remove,
          child: markWidget,
        ),
      ),
    );
  }
}
