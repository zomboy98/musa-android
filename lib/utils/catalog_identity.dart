import 'package:mornye/utils/isrc_utils.dart';

/// Two lengths this close (seconds) are the same recording; it is what lets
/// a song keep one identity when each release carries its own ISRC.
const sameRecordingDurationTolerance = 2;

/// Whether a local file described by [isrc], [title], [artist] and
/// [durationSeconds] is the wanted song. Equal ISRCs always match; without
/// both ISRCs the title and artist decide; another ISRC is another recording
/// unless the same title, artist and length prove otherwise.
bool sameCatalogRecording({
  required String? wantedIsrc,
  required String wantedTitle,
  required String wantedArtist,
  required int wantedDurationSeconds,
  required String? isrc,
  required String title,
  required String artist,
  int? durationSeconds,
}) {
  final wanted = normalizeIsrc(wantedIsrc);
  final candidate = normalizeIsrc(isrc);
  final hasBothIsrc = wanted.isNotEmpty && candidate.isNotEmpty;
  if (hasBothIsrc && wanted == candidate) return true;
  final name = wantedTitle.trim().toLowerCase();
  final by = wantedArtist.trim().toLowerCase();
  final sameNames =
      name.isNotEmpty &&
      by.isNotEmpty &&
      name == title.trim().toLowerCase() &&
      by == artist.trim().toLowerCase();
  if (!hasBothIsrc) return sameNames;
  return sameNames &&
      wantedDurationSeconds > 0 &&
      durationSeconds != null &&
      durationSeconds > 0 &&
      (wantedDurationSeconds - durationSeconds).abs() <=
          sameRecordingDurationTolerance;
}
