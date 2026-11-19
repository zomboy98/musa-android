import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/utils/track_quality_choices.dart';

const _tidal = [
  QualityOption(id: 'HI_RES_LOSSLESS', label: 'Max · Hi-Res 24-bit', kind: 'lossless'),
  QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(id: 'HIGH', label: 'AAC 320 kbps', kind: 'lossy'),
];
const _deezer = [
  QualityOption(id: 'hires', label: 'Hi-Res 24-bit', kind: 'lossless'),
  QualityOption(id: 'flac', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(id: 'mp3', label: 'AAC 320 kbps', kind: 'lossy'),
];
const _qobuz = [
  QualityOption(id: 'hires', label: 'Hi-Res 24-bit', kind: 'lossless'),
  QualityOption(id: 'cd', label: 'FLAC 16-bit', kind: 'lossless'),
];
const _beatport = [
  QualityOption(id: 'flac', label: 'FLAC 16-bit', kind: 'lossless'),
];
const _amazon = [
  QualityOption(id: 'best', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(id: 'aac', label: 'AAC 320 kbps', kind: 'lossy'),
];

final _providers = [
  (service: 'tidal-web', options: _tidal),
  (service: 'deezer', options: _deezer),
  (service: 'qobuz', options: _qobuz),
  (service: 'beatport', options: _beatport),
  (service: 'amazon', options: _amazon),
];

void main() {
  List<TrackQualityChoice> merge({String? service, String? id}) =>
      mergeProviderQualityChoices(
        _providers,
        currentService: service,
        currentId: id,
      );

  test('one row per format, without repeating by provider', () {
    final rows = merge();
    final keys = [for (final c in rows) '${c.mark.name}|${c.detail}'];
    expect(keys.toSet().length, keys.length, reason: keys.join(', '));
  });

  test('the row keeps its providers in priority order', () {
    final rows = merge();
    final flac = rows.firstWhere((c) => c.mark.name == 'flac');
    expect(flac.candidates.map((c) => c.service).toList(), [
      'tidal-web',
      'deezer',
      'qobuz',
      'beatport',
      'amazon',
    ]);
    expect(flac.service, 'tidal-web');
  });

  test('only one row is current, the one the playing request belongs to', () {
    for (final entry in [
      ('tidal-web', 'HI_RES_LOSSLESS'),
      ('deezer', 'hires'),
      ('qobuz', 'hires'),
      ('amazon', 'best'),
      ('beatport', 'flac'),
    ]) {
      final rows = merge(service: entry.$1, id: entry.$2);
      expect(
        rows.where((c) => c.current).length,
        lessThanOrEqualTo(1),
        reason: '$entry',
      );
      final current = rows.where((c) => c.current).firstOrNull;
      if (current != null) {
        expect(
          current.candidates.contains(QualityCandidate(entry.$1, entry.$2)),
          isTrue,
          reason: '$entry',
        );
      }
    }
  });

  test('with provider twins kept the list repeats formats', () {
    final rows = mergeProviderQualityChoices(
      _providers,
      keepProviderTwins: true,
    );
    expect(rows.length, greaterThan(merge().length));
  });

  test('Max and the same Hi-Res 24-bit from others are one row', () {
    final rows = merge(service: 'deezer', id: 'hires');
    final hi = rows
        .where((c) => c.detail == '24-bit' && c.mark.name != 'flac')
        .toList();
    expect(hi.length, 1);
    expect(hi.single.candidates.map((c) => '${c.service}/${c.id}'), [
      'tidal-web/HI_RES_LOSSLESS',
      'deezer/hires',
      'qobuz/hires',
    ]);
    expect(hi.single.current, isTrue);
    expect(rows.where((c) => c.current).length, 1);
  });

  test('the list has one row per format and no provider rows', () {
    expect(
      [for (final c in merge()) '${c.detail}|${c.candidates.length}'],
      ['24-bit|3', '16-bit|5', '320 kbps|2', '320 kbps|1'],
    );
  });
}
