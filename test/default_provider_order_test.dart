import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/utils/download_provider_order.dart';

typedef _Quality = (String, String, String);

Extension _ext(
  String id, {
  bool metadata = false,
  bool download = false,
  bool skip = false,
  bool search = true,
  bool primary = false,
  bool home = false,
  bool related = false,
  bool url = true,
  List<String> features = const [],
  List<_Quality> quality = const [],
}) => Extension.fromJson({
  'id': id,
  'name': id,
  'version': '1',
  'status': 'loaded',
  'enabled': true,
  'has_metadata_provider': metadata,
  'has_download_provider': download,
  'skip_metadata_enrichment': skip,
  'required_runtime_features': features,
  'quality_options': [
    for (final q in quality) {'id': q.$1, 'label': q.$2, 'kind': q.$3},
  ],
  'search_behavior': {'enabled': search, 'primary': primary},
  'url_handler': {'enabled': url},
  'capabilities': {'homeFeed': home, 'relatedTracks': related},
});

const _session = ['signedSession@1', 'sessionGrant@1'];
const _atmos = [('ATMOS', 'Dolby Atmos', 'spatial')];
const _flac = [('FLAC', 'FLAC', 'lossless')];
const _aac = [('AAC_320', 'AAC 320 kbps', 'lossy')];

List<Extension> _realManifests() => [
  _ext(
    'amazon',
    metadata: true,
    download: true,
    home: true,
    features: _session,
    quality: const [
      ('best', 'FLAC Best Available', 'lossless'),
      ('opus', 'Opus 320kbps', 'lossy'),
      ('eac3', 'Dolby Digital Plus', 'spatial'),
      ('ac4', 'Dolby Atmos (AC-4)', 'spatial'),
    ],
  ),
  _ext('apple-music', metadata: true, home: true, related: true),
  _ext(
    'beatport',
    metadata: true,
    download: true,
    skip: true,
    features: _session,
    quality: const [
      ('LOSSLESS', 'FLAC Lossless', 'lossless'),
      ('HIGH', 'AAC 256 kbps', 'lossy'),
    ],
  ),
  _ext('bugs-music', metadata: true, home: true, related: true),
  _ext(
    'deezer',
    metadata: true,
    download: true,
    primary: true,
    related: true,
    features: _session,
    quality: const [('flac', 'FLAC / Hi-Res', '')],
  ),
  _ext('genie-music', metadata: true, home: true),
  _ext(
    'jiosaavn',
    metadata: true,
    download: true,
    home: true,
    related: true,
    quality: const [
      ('AAC_320', 'AAC 320 kbps', 'lossy'),
      ('AAC_160', 'AAC 160 kbps', 'lossy'),
      ('AAC_96', 'AAC 96 kbps', 'lossy'),
    ],
  ),
  _ext('melon-music', metadata: true, home: true),
  _ext(
    'qobuz-web',
    metadata: true,
    download: true,
    skip: true,
    features: _session,
    quality: const [
      ('HI_RES_LOSSLESS', '24-Bit Max', 'lossless'),
      ('HI_RES', '24-Bit', 'lossless'),
      ('LOSSLESS', 'Lossless', 'lossless'),
    ],
  ),
  _ext(
    'soundcloud',
    metadata: true,
    download: true,
    related: true,
    quality: const [('aac_160', 'AAC up to 160kbps', '')],
  ),
  _ext('spotify-web', metadata: true, skip: true, home: true, related: true),
  _ext(
    'tidal-web',
    metadata: true,
    download: true,
    related: true,
    features: _session,
    quality: const [
      ('DOLBY_ATMOS', 'Dolby Atmos', 'spatial'),
      ('HI_RES_LOSSLESS', 'HiRes FLAC', 'lossless'),
      ('LOSSLESS', 'Lossless', 'lossless'),
      ('HIGH', 'High', 'lossy'),
    ],
  ),
  _ext(
    'ytmusic-spotiflac',
    metadata: true,
    download: true,
    home: true,
    related: true,
    quality: const [('best', 'Best Audio', '')],
  ),
];

void main() {
  group('audio order', () {
    test('spatial, then lossless, then lossy, then nothing declared', () {
      final order = defaultDownloadProviderOrder([
        _ext('none', download: true),
        _ext('lossy', download: true, quality: _aac),
        _ext('lossless', download: true, quality: _flac),
        _ext('spatial', download: true, quality: _atmos),
      ]);
      expect(order, ['spatial', 'lossless', 'lossy', 'none']);
    });

    test(
      'without an active session, providers that need none go first in a tier',
      () {
        final extensions = [
          _ext(
            'needs-session',
            download: true,
            quality: _flac,
            features: _session,
          ),
          _ext('open', download: true, quality: _flac),
        ];
        expect(defaultDownloadProviderOrder(extensions), [
          'open',
          'needs-session',
        ]);
      },
    );

    test('an active session removes the penalty', () {
      final extensions = [
        _ext(
          'needs-session',
          download: true,
          quality: _flac,
          features: _session,
        ),
        _ext('open', download: true, quality: _flac),
      ];
      expect(
        defaultDownloadProviderOrder(
          extensions,
          activeSessionIds: {'needs-session'},
        ),
        ['needs-session', 'open'],
      );
    });

    test('a session never outranks a better quality tier', () {
      final extensions = [
        _ext('open-lossy', download: true, quality: _aac),
        _ext(
          'session-lossless',
          download: true,
          quality: _flac,
          features: _session,
        ),
      ];
      expect(defaultDownloadProviderOrder(extensions), [
        'session-lossless',
        'open-lossy',
      ]);
    });

    test('an unknown provider is placed by what it declares', () {
      final order = defaultDownloadProviderOrder([
        _ext('jiosaavn', download: true, quality: _aac),
        _ext('brand-new', download: true, quality: _flac),
        _ext('tidal-web', download: true, quality: _atmos),
      ]);
      expect(order, ['tidal-web', 'brand-new', 'jiosaavn']);
    });

    test('the known list only breaks ties between equal declarations', () {
      final order = defaultDownloadProviderOrder([
        _ext('zzz', download: true, quality: _atmos),
        _ext('tidal-web', download: true, quality: _atmos),
        _ext('amazon', download: true, quality: _atmos),
      ]);
      expect(order, ['amazon', 'tidal-web', 'zzz']);
    });

    test('real manifests order from best quality to the lightest', () {
      final order = defaultDownloadProviderOrder(
        _realManifests().where((ext) => ext.hasDownloadProvider),
      );
      expect(order, [
        'amazon',
        'tidal-web',
        'deezer',
        'qobuz-web',
        'beatport',
        'jiosaavn',
        'ytmusic-spotiflac',
        'soundcloud',
      ]);
    });
  });

  group('music order', () {
    test('providers that skip enrichment go after those with full data', () {
      final order = defaultMetadataProviderOrder([
        _ext('flagged', metadata: true, skip: true, home: true, related: true),
        _ext('complete', metadata: true),
      ]);
      expect(order, ['complete', 'flagged']);
    });

    test('an unknown provider without ISRC data goes last by its flag', () {
      final order = defaultMetadataProviderOrder([
        _ext('newcomer', metadata: true, skip: true),
        _ext('deezer', metadata: true),
        _ext('other-new', metadata: true),
      ]);
      expect(order, ['deezer', 'other-new', 'newcomer']);
    });

    test('unknown providers are ordered by declared capabilities', () {
      final order = defaultMetadataProviderOrder([
        _ext('plain', metadata: true, search: false, url: false),
        _ext('rich', metadata: true, home: true, related: true, primary: true),
        _ext('mid', metadata: true, home: true),
      ]);
      expect(order, ['rich', 'mid', 'plain']);
    });

    test('known providers that return no ISRC go to the end', () {
      final order = defaultMetadataProviderOrder([
        _ext('amazon', metadata: true, download: true, home: true),
        _ext('soundcloud', metadata: true),
        _ext(
          'spotify-web',
          metadata: true,
          skip: true,
          home: true,
          related: true,
        ),
      ]);
      expect(order, ['soundcloud', 'spotify-web', 'amazon']);
    });

    test('real manifests put ISRC-rich sources first and the rest last', () {
      final order = defaultMetadataProviderOrder(_realManifests());
      expect(order, [
        'deezer',
        'apple-music',
        'tidal-web',
        'qobuz-web',
        'ytmusic-spotiflac',
        'soundcloud',
        'jiosaavn',
        'bugs-music',
        'genie-music',
        'melon-music',
        'spotify-web',
        'amazon',
        'beatport',
      ]);
    });
  });
}
