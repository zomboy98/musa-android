import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/utils/history_track.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';

const _tidal = [
  QualityOption(id: 'DOLBY_ATMOS', label: 'Dolby Atmos', kind: 'spatial'),
  QualityOption(id: 'HI_RES_LOSSLESS', label: 'MAX', kind: 'lossless'),
  QualityOption(id: 'LOSSLESS', label: 'FLAC', kind: 'lossless'),
  QualityOption(id: 'HIGH', label: 'AAC 320', kind: 'lossy'),
  QualityOption(id: 'LOW', label: 'AAC 96', kind: 'lossy'),
];
const _amazon = [
  QualityOption(id: 'best', label: 'FLAC Best Available', kind: 'lossless'),
  QualityOption(id: 'opus', label: 'Opus 320kbps', kind: 'lossy'),
  QualityOption(id: 'eac3', label: 'Dolby Digital Plus', kind: 'spatial'),
  QualityOption(id: 'ac4', label: 'Dolby Atmos (AC-4)', kind: 'spatial'),
];
const _deezer = [QualityOption(id: 'flac', label: 'FLAC', kind: 'lossless')];
const _qobuz = [
  QualityOption(id: 'HI_RES_LOSSLESS', label: 'Hi-Res', kind: 'lossless'),
  QualityOption(id: 'LOSSLESS', label: 'FLAC', kind: 'lossless'),
];
const _beatport = [
  QualityOption(id: 'LOSSLESS', label: 'FLAC', kind: 'lossless'),
  QualityOption(id: 'HIGH', label: 'AAC 256', kind: 'lossy'),
];

final _providers = [
  (service: 'amazon', options: _amazon),
  (service: 'deezer', options: _deezer),
  (service: 'tidal-web', options: _tidal),
  (service: 'qobuz-web', options: _qobuz),
  (service: 'beatport', options: _beatport),
];

Track _track({String? source, String? modes, String? isrc}) => Track(
  id: 'x1',
  name: 'Pues ya ni pedo',
  artistName: 'Artista',
  albumName: 'Album',
  duration: 180,
  audioModes: modes,
  source: source,
  isrc: isrc,
);

SpecialQualityAvailability _offline() => SpecialQualityAvailability(
  loadMetadata: (_, _, _) async => throw StateError('offline'),
  probeEnabled: false,
);

List<TrackQualityChoice> _merge(
  Track track,
  SpecialQualityAvailability registry, {
  QualityMark? currentMark,
  String? currentService,
  String? currentId,
}) => mergeProviderQualityChoices(
  _providers,
  track: track,
  availability: registry,
  currentMark: currentMark,
  currentService: currentService,
  currentId: currentId,
);

List<TrackQualityChoice> _spatial(List<TrackQualityChoice> choices) =>
    choices.where((e) => e.format == QualityBadgeFormat.spatial).toList();

void main() {
  test('the three spatial formats are three distinct rows', () {
    final rows = _spatial(
      _merge(_track(source: 'tidal-web', modes: 'DOLBY_ATMOS'), _offline()),
    );
    expect(rows.map((e) => e.spatialCodec).toSet(), {
      'AC-4',
      'E-AC-3 JOC',
      'E-AC-3',
    });
    expect(rows, hasLength(3));
    final ac4 = rows.firstWhere((e) => e.spatialCodec == 'AC-4');
    final joc = rows.firstWhere((e) => e.spatialCodec == 'E-AC-3 JOC');
    final ddp = rows.firstWhere((e) => e.spatialCodec == 'E-AC-3');
    expect(ac4.mark, QualityMark.atmos);
    expect(joc.mark, QualityMark.atmos);
    expect(ddp.mark, QualityMark.dolbyPlus);
    expect(ac4.candidates.map((c) => c.service), ['amazon']);
    expect(joc.candidates.map((c) => c.service), ['tidal-web']);
    expect(ddp.candidates.map((c) => c.service), ['amazon']);
    expect(rows.every((e) => e.tag == null), isTrue);
  });

  test('without confirmation the three spatial rows are offered on request', () {
    final rows = _spatial(_merge(_track(source: 'deezer'), _offline()));
    expect(rows.map((e) => e.spatialCodec).toSet(), {
      'AC-4',
      'E-AC-3 JOC',
      'E-AC-3',
    });
  });

  test('the other formats keep one row each and a single row is current', () {
    final choices = _merge(
      _track(source: 'tidal-web', modes: 'DOLBY_ATMOS'),
      _offline(),
      currentMark: QualityMark.atmos,
      currentService: 'amazon',
      currentId: 'ac4',
    );
    final current = choices.where((e) => e.current).toList();
    expect(current, hasLength(1));
    expect(current.single.id, 'ac4');
    expect(
      choices.where((e) => e.mark == QualityMark.flac),
      hasLength(1),
    );
  });

  test('the playing atmos row is the one of the stream that plays', () {
    final choices = _merge(
      _track(source: 'deezer'),
      _offline(),
      currentMark: QualityMark.atmos,
      currentService: 'tidal-web',
      currentId: 'DOLBY_ATMOS_OTHER',
    );
    expect(choices.where((e) => e.current), hasLength(1));
  });

  test('album track with modes that do not name atmos keeps atmos on request', () {
    final rows = _spatial(
      _merge(_track(modes: 'STEREO'), _offline()),
    );
    expect(rows.map((e) => e.spatialCodec).toSet(), {
      'AC-4',
      'E-AC-3 JOC',
      'E-AC-3',
    });
  });

  test('a tidal track that lists only stereo hides only the tidal atmos', () {
    final rows = _spatial(
      _merge(_track(source: 'tidal-web', modes: 'STEREO'), _offline()),
    );
    expect(rows.map((e) => e.spatialCodec).toSet(), {'AC-4', 'E-AC-3'});
  });

  test('the codec of a spatial option comes from its id and label', () {
    expect(spatialCodecLabelFor(QualityMark.atmos, 'ac4'), 'AC-4');
    expect(
      spatialCodecLabelFor(QualityMark.atmos, 'DOLBY_ATMOS', 'Dolby Atmos'),
      'E-AC-3 JOC',
    );
    expect(spatialCodecLabelFor(QualityMark.dolbyPlus, 'eac3'), 'E-AC-3');
    expect(spatialCodecLabelFor(QualityMark.flac, 'flac'), isNull);
  });

  test('a track rebuilt from a download keeps the ids a request needs', () {
    final item = DownloadHistoryItem(
      id: 'h1',
      trackName: 'Pues ya ni pedo',
      artistName: 'Artista',
      albumName: 'Album',
      filePath: '/music/a.m4a',
      service: 'amazon',
      downloadedAt: DateTime(2026, 11, 19),
      isrc: 'USABC1234567',
      spotifyId: 'B0GYQKTXH3',
    );
    final track = trackFromHistoryItem(item);
    expect(track.id, 'B0GYQKTXH3');
    expect(track.isrc, 'USABC1234567');
  });
}
