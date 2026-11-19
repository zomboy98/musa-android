import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';

String albumQualityKey(String albumName, String? artistName) =>
    '${albumName.trim().toLowerCase()}|${(artistName ?? '').trim().toLowerCase()}';

const _formatRank = {
  QualityBadgeFormat.lossy: 0,
  QualityBadgeFormat.aac: 1,
  QualityBadgeFormat.flac: 2,
  QualityBadgeFormat.lossless: 3,
  QualityBadgeFormat.hiRes: 4,
  QualityBadgeFormat.max: 5,
  QualityBadgeFormat.spatial: 6,
};

class AlbumQualityView {
  const AlbumQualityView({
    required this.format,
    required this.label,
    required this.mark,
    this.detail,
    this.choiceId,
    this.mixed = false,
    this.downloaded = false,
  });

  final QualityBadgeFormat format;
  final String label;
  final QualityMark mark;
  final String? detail;
  final String? choiceId;
  final bool mixed;
  final bool downloaded;
}

TrackQualityChoice? findQualityChoice(
  List<TrackQualityChoice> choices,
  String? value,
) {
  final key = value?.trim().toLowerCase() ?? '';
  if (key.isEmpty) return null;
  return choices
      .where(
        (choice) =>
            choice.id.trim().toLowerCase() == key ||
            choice.label.trim().toLowerCase() == key,
      )
      .firstOrNull;
}

bool downloadHasQuality(DownloadHistoryItem item, TrackQualityChoice choice) {
  final quality = item.quality?.trim().toLowerCase() ?? '';
  return quality.isNotEmpty &&
      (quality == choice.id.trim().toLowerCase() ||
          quality == choice.label.trim().toLowerCase());
}

typedef _DownloadFormat = ({
  QualityBadgeFormat format,
  TrackQualityChoice? choice,
  String label,
  QualityMark mark,
  String? detail,
});

_DownloadFormat? _downloadFormat(
  DownloadHistoryItem item,
  List<TrackQualityChoice> choices,
) {
  final quality = item.quality?.trim() ?? '';
  final choice = findQualityChoice(choices, quality);
  final codec = item.format;
  final mark = verifiedQualityMark(
    declared: choice?.mark ?? qualityMarkFor(quality, quality),
    codec: codec,
    sampleRate: item.sampleRate,
    bitDepth: item.bitDepth,
  );
  final detail =
      qualityDetailFor(
        '',
        '',
        sampleRate: item.sampleRate,
        bitDepth: item.bitDepth,
        bitrateKbps: item.bitrate,
      ) ??
      (choice != null && choice.mark == mark ? choice.detail : null);
  if (choice != null) {
    return (
      format: qualityFormatForMark(mark),
      choice: choice,
      label: choice.label,
      mark: mark,
      detail: detail,
    );
  }
  if (quality.isNotEmpty) {
    return (
      format: qualityFormatForMark(mark),
      choice: null,
      label: quality,
      mark: mark,
      detail: detail,
    );
  }
  final hint = [
    codec?.trim() ?? '',
    if ((item.bitDepth ?? 0) > 0) '${item.bitDepth}-bit',
  ].where((part) => part.isNotEmpty).join(' ');
  if (hint.isEmpty) return null;
  final hinted = verifiedQualityMark(
    declared: qualityMarkFor(hint, hint),
    codec: codec,
    sampleRate: item.sampleRate,
    bitDepth: item.bitDepth,
  );
  return (
    format: qualityFormatForMark(hinted),
    choice: null,
    label: hint,
    mark: hinted,
    detail: detail,
  );
}

AlbumQualityView? resolveAlbumQuality({
  required List<DownloadHistoryItem> downloads,
  required List<TrackQualityChoice> choices,
  List<Track> catalogTracks = const [],
  String? chosenId,
  String? defaultId,
}) {
  final counts = <QualityBadgeFormat, int>{};
  final samples = <QualityBadgeFormat, _DownloadFormat>{};
  for (final item in downloads) {
    final found = _downloadFormat(item, choices);
    if (found == null) continue;
    counts.update(found.format, (n) => n + 1, ifAbsent: () => 1);
    samples.putIfAbsent(found.format, () => found);
  }
  if (counts.isNotEmpty) {
    final ordered = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0
            ? byCount
            : _formatRank[a]!.compareTo(_formatRank[b]!);
      });
    final format = ordered.first;
    final mixed = counts.length > 1;
    final sample = samples[format]!;
    return AlbumQualityView(
      format: format,
      label: sample.label,
      mark: sample.mark,
      detail: sample.detail,
      choiceId: mixed ? null : sample.choice?.id,
      mixed: mixed,
      downloaded: true,
    );
  }
  for (final id in [chosenId, defaultId]) {
    final choice = findQualityChoice(choices, id);
    if (choice != null) {
      return AlbumQualityView(
        format: choice.format,
        label: choice.label,
        mark: choice.mark,
        detail: choice.detail,
        choiceId: choice.id,
      );
    }
  }
  final catalog = <String, int>{};
  for (final track in catalogTracks) {
    final quality = (track.audioQuality ?? '').trim();
    final key = track.isDolbyAtmos ? 'atmos' : quality;
    if (key.isNotEmpty) catalog.update(key, (n) => n + 1, ifAbsent: () => 1);
  }
  if (catalog.isEmpty) return null;
  final top = catalog.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  final topMark = top == 'atmos' ? QualityMark.atmos : qualityMarkFor(top, top);
  return AlbumQualityView(
    format: qualityFormatForMark(topMark),
    label: top == 'atmos' ? 'Dolby Atmos' : top,
    mark: topMark,
    detail: qualityDetailFor(top, top),
  );
}

List<({Track track, DownloadHistoryItem item})> albumDownloadsFor(
  List<Track> tracks,
  Iterable<DownloadHistoryItem> history,
  String albumName,
) {
  final album = albumName.trim().toLowerCase();
  final candidates = history
      .where(
        (item) =>
            item.albumName.trim().toLowerCase() == album &&
            !item.filePath.startsWith('network://'),
      )
      .toList();
  final result = <({Track track, DownloadHistoryItem item})>[];
  for (final track in tracks) {
    final matches =
        candidates.where((item) => historyMatchesTrack(track, item)).toList()
          ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    if (matches.isNotEmpty) result.add((track: track, item: matches.first));
  }
  return result;
}
