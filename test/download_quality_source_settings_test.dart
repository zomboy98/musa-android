import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';

void main() {
  test('legacy settings do not invent source metadata', () {
    final settings = AppSettings.fromJson({
      'downloadQualityByProvider': {'source': 'hi'},
    });
    expect(settings.downloadQualitySourceFor('source', 'hi'), isNull);
  });

  test(
    'source metadata survives serialization and requires provider and id',
    () {
      const source = DownloadQualitySource(
        provider: 'Source',
        id: 'hi',
        kind: 'lossless',
        label: '24-bit',
      );
      const settings = AppSettings(
        downloadQualityByProvider: {'source': 'hi'},
        downloadQualitySourceByProvider: {'source': source},
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(
        restored.downloadQualitySourceFor('SOURCE', 'hi')?.label,
        '24-bit',
      );
      expect(restored.downloadQualitySourceFor('other', 'hi'), isNull);
      expect(restored.downloadQualitySourceFor('source', 'low'), isNull);
      expect(restored.downloadQualitySourceFor('source', 'HI'), isNull);
      expect(
        restored
            .copyWith(downloadQualityByProvider: {'source': 'low'})
            .downloadQualitySourceFor('source', 'hi'),
        isNull,
      );
    },
  );

  test('malformed and mismatched stored source metadata is ignored', () {
    final settings = AppSettings.fromJson({
      'downloadQualityByProvider': {'source': 'hi'},
      'downloadQualitySourceByProvider': {
        'source': {
          'provider': 'other',
          'id': 'hi',
          'kind': 'lossless',
          'label': 'Hi',
        },
      },
    });
    expect(settings.downloadQualitySourceFor('source', 'hi'), isNull);
  });
}
