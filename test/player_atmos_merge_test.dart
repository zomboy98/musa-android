import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';

const _tidal = [
  QualityOption(id: 'HI_RES_LOSSLESS', label: 'MAX', kind: 'lossless'),
  QualityOption(id: 'LOSSLESS', label: 'FLAC', kind: 'lossless'),
  QualityOption(id: 'DOLBY_ATMOS', label: 'Dolby Atmos', kind: 'spatial'),
];
const _amazon = [
  QualityOption(id: 'best', label: 'FLAC', kind: 'lossless'),
  QualityOption(id: 'opus', label: 'OPUS 320', kind: 'lossy'),
  QualityOption(id: 'ac4', label: 'Dolby Atmos (AC-4)', kind: 'spatial'),
  QualityOption(id: 'eac3', label: 'Dolby Digital Plus', kind: 'spatial'),
];

Track _track({String? source, String? modes = 'DOLBY_ATMOS', String? isrc}) =>
    Track(
      id: 'x1',
      name: 'Adiccion',
      artistName: 'Jasiel Nunez',
      albumName: 'Adiccion',
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
  List<({String service, Iterable<QualityOption> options})>? providers,
}) => mergeProviderQualityChoices(
  providers ??
      [
        (service: 'amazon', options: _amazon),
        (service: 'tidal-web', options: _tidal),
      ],
  track: track,
  availability: registry,
);

bool _hasAtmos(List<TrackQualityChoice> c) =>
    c.any((e) => e.format == QualityBadgeFormat.spatial);

void main() {
  for (final source in ['amazon', 'tidal-web', 'deezer', 'spotify', null]) {
    test('atmos declared by the catalog is offered, source $source', () {
      expect(_hasAtmos(_merge(_track(source: source), _offline())), isTrue);
    });
  }

  test('atmos is offered when the catalog says nothing about it', () {
    final t = _track(source: 'deezer', modes: null);
    expect(_hasAtmos(_merge(t, _offline())), isTrue);
  });

  test('atmos stays offered by the provider not ruled out', () {
    final r = _offline();
    final t = _track(source: 'deezer', modes: null, isrc: 'USABC1234567');
    r.markUnavailable(t, 'tidal-web');
    final c = _merge(t, r);
    expect(c.where((e) => e.format == QualityBadgeFormat.spatial), isNotEmpty);
    expect(
      c
          .where((e) => e.format == QualityBadgeFormat.spatial)
          .every((e) => e.service == 'amazon'),
      isTrue,
    );
  });

  test('atmos is hidden once every capable provider is ruled out', () {
    final r = _offline();
    final t = _track(source: 'deezer', modes: null, isrc: 'USABC1234567');
    r.markUnavailable(t, 'tidal-web');
    r.markUnavailable(t, 'amazon');
    expect(_hasAtmos(_merge(t, r)), isFalse);
  });

  test('a stereo catalog entry of the same provider hides its atmos', () {
    final t = _track(source: 'amazon', modes: 'STEREO');
    final c = _merge(
      t,
      _offline(),
      providers: [(service: 'amazon', options: _amazon)],
    );
    expect(_hasAtmos(c), isFalse);
  });

  test('amazon offers two distinct dolby entries with their own ids', () {
    final c = _merge(
      _track(source: 'amazon'),
      _offline(),
      providers: [(service: 'amazon', options: _amazon)],
    );
    final dolby = c.where((e) => e.format == QualityBadgeFormat.spatial);
    expect(dolby.map((e) => e.id).toSet(), {'ac4', 'eac3'});
    expect(dolby.firstWhere((e) => e.id == 'ac4').mark, QualityMark.atmos);
    expect(dolby.firstWhere((e) => e.id == 'eac3').mark, QualityMark.dolbyPlus);
  });

  test('dolby ids and labels map to the mark that really plays', () {
    expect(qualityMarkFor('ac4', 'Dolby Atmos (AC-4)'), QualityMark.atmos);
    expect(qualityMarkFor('eac3', 'Dolby Digital Plus'), QualityMark.dolbyPlus);
    expect(qualityMarkFor('', 'E-AC-3'), QualityMark.dolbyPlus);
    expect(qualityMarkFor('DOLBY_ATMOS', 'Dolby Atmos'), QualityMark.atmos);
    expect(
      verifiedQualityMark(declared: QualityMark.dolbyPlus, codec: 'eac3'),
      QualityMark.dolbyPlus,
    );
    expect(
      verifiedQualityMark(declared: QualityMark.atmos, codec: 'ac4'),
      QualityMark.atmos,
    );
  });
}
