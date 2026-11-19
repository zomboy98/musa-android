import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/provider_request_spec.dart';

ProviderRequestSpec _spec(String id) => providerRequestSpecFor(id)!;

void main() {
  test('validates identifier formats', () {
    final tidal = _spec('tidal-web');
    expect(tidal.nativeId('568276392'), '568276392');
    expect(tidal.nativeId('tidal:568276392'), '568276392');
    expect(tidal.nativeId('B0HMDH7PHM'), isNull);
    expect(tidal.nativeId(''), isNull);
    expect(tidal.nativeId('0123'), isNull);
    expect(_spec('deezer').nativeId('4337604802'), '4337604802');
    final beatport = _spec('beatport');
    expect(beatport.nativeId('30982448'), '30982448');
    expect(beatport.nativeId('beatport:30982448'), '30982448');
    final amazon = _spec('amazon');
    expect(amazon.nativeId('B0HMDH7PHM'), 'B0HMDH7PHM');
    expect(amazon.nativeId('568276392'), isNull);
    expect(amazon.nativeId('b0hmdh7phm'), isNull);
    expect(_spec('soundcloud').nativeId('1234'), isNull);
    expect(_spec('ytmusic-spotiflac').nativeId('ENXLhu3UYto'), 'ENXLhu3UYto');
  });

  test('maps qualities to the exact manifest identifier', () {
    expect(_spec('tidal-web').quality('hi_res_lossless'), 'HI_RES_LOSSLESS');
    expect(_spec('tidal-web').quality('FLAC'), 'LOSSLESS');
    expect(_spec('beatport').quality('hi_res_lossless'), 'LOSSLESS');
    expect(_spec('soundcloud').quality('AAC_160'), 'aac_160');
    expect(_spec('amazon').quality('desconocida'), 'desconocida');
  });

  test('table rows are internally consistent', () {
    for (final spec in providerRequestSpecs.values) {
      if (spec.delivery == NativeIdDelivery.nativeField) {
        expect(spec.field, isNotNull, reason: spec.providerId);
      } else {
        expect(spec.field, isNull, reason: spec.providerId);
      }
      if (spec.lookup == NativeIdLookup.extensionSearch) {
        expect(spec.searchFilter, isNotEmpty, reason: spec.providerId);
      }
      expect(providerRequestSpecs[spec.providerId], same(spec));
    }
  });

  test('matches the bundled extension manifests', () {
    final index =
        jsonDecode(
              File(
                'assets/bundled_extensions/manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final files = {
      for (final entry
          in (index['extensions'] as List).cast<Map<String, dynamic>>())
        entry['id'] as String: entry['file'] as String,
    };
    for (final spec in providerRequestSpecs.values) {
      final file = files[spec.providerId];
      expect(file, isNotNull, reason: spec.providerId);
      final archive = ZipDecoder().decodeBytes(
        File('assets/bundled_extensions/$file').readAsBytesSync(),
      );
      final manifest =
          jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content))
              as Map<String, dynamic>;
      expect(manifest['name'], spec.providerId);
      final qualityIds = {
        for (final option in (manifest['qualityOptions'] as List? ?? const []))
          (option as Map)['id'].toString(),
      };
      expect(qualityIds, spec.qualities.toSet(), reason: spec.providerId);
      expect(
        manifest['type'].toString(),
        contains('download_provider'),
        reason: spec.providerId,
      );
      if (spec.lookup == NativeIdLookup.extensionSearch) {
        final behavior = manifest['searchBehavior'] as Map?;
        final filterIds = {
          for (final filter in (behavior?['filters'] as List? ?? const []))
            (filter as Map)['id'].toString(),
        };
        expect(filterIds, contains(spec.searchFilter), reason: spec.providerId);
      }
    }
  });
}
