enum NativeIdDelivery { nativeField, directSource }

enum NativeIdField { tidal, qobuz, deezer }

enum NativeIdLookup { none, deezerIsrc, extensionSearch }

class ProviderRequestSpec {
  const ProviderRequestSpec({
    required this.providerId,
    required this.idPattern,
    this.idPrefix = '',
    required this.delivery,
    this.field,
    required this.lookup,
    this.searchFilter = '',
    this.searchLimit = 10,
    required this.qualities,
    this.qualityAliases = const {},
  });

  final String providerId;
  final String idPattern;
  final String idPrefix;
  final NativeIdDelivery delivery;
  final NativeIdField? field;
  final NativeIdLookup lookup;
  final String searchFilter;
  final int searchLimit;
  final List<String> qualities;
  final Map<String, String> qualityAliases;

  String? nativeId(String raw) {
    var value = raw.trim();
    if (idPrefix.isNotEmpty &&
        value.toLowerCase().startsWith(idPrefix.toLowerCase())) {
      value = value.substring(idPrefix.length);
    }
    return RegExp(idPattern).hasMatch(value) ? value : null;
  }

  String quality(String requested) {
    final value = requested.trim();
    final lower = value.toLowerCase();
    for (final known in qualities) {
      if (known.toLowerCase() == lower) return known;
    }
    final alias = qualityAliases[value.toUpperCase()];
    return alias ?? requested;
  }
}

const providerRequestSpecVersion = 1;

const sourcesForbiddingReplacement = {'soundcloud'};

const providerRequestSpecs = <String, ProviderRequestSpec>{
  'tidal-web': ProviderRequestSpec(
    providerId: 'tidal-web',
    idPattern: r'^[1-9]\d{0,14}$',
    idPrefix: 'tidal:',
    delivery: NativeIdDelivery.nativeField,
    field: NativeIdField.tidal,
    lookup: NativeIdLookup.extensionSearch,
    searchFilter: 'track',
    qualities: ['DOLBY_ATMOS', 'HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH', 'LOW'],
    qualityAliases: {
      'HIRES': 'HI_RES_LOSSLESS',
      'HI_RES': 'HI_RES_LOSSLESS',
      'MASTER': 'HI_RES_LOSSLESS',
      'FLAC': 'LOSSLESS',
      'DOLBY': 'DOLBY_ATMOS',
      'ATMOS': 'DOLBY_ATMOS',
      'EAC3': 'DOLBY_ATMOS',
      'EC3': 'DOLBY_ATMOS',
      'EAC3_JOC': 'DOLBY_ATMOS',
    },
  ),
  'qobuz-web': ProviderRequestSpec(
    providerId: 'qobuz-web',
    idPattern: r'^[1-9]\d{0,14}$',
    idPrefix: 'qobuz:',
    delivery: NativeIdDelivery.nativeField,
    field: NativeIdField.qobuz,
    lookup: NativeIdLookup.extensionSearch,
    searchFilter: 'track',
    qualities: ['HI_RES_LOSSLESS', 'HI_RES', 'LOSSLESS'],
    qualityAliases: {'DEFAULT': 'HI_RES_LOSSLESS'},
  ),
  'deezer': ProviderRequestSpec(
    providerId: 'deezer',
    idPattern: r'^[1-9]\d{0,18}$',
    idPrefix: 'deezer:',
    delivery: NativeIdDelivery.nativeField,
    field: NativeIdField.deezer,
    lookup: NativeIdLookup.deezerIsrc,
    qualities: ['flac'],
  ),
  'beatport': ProviderRequestSpec(
    providerId: 'beatport',
    idPattern: r'^[1-9]\d{0,14}$',
    idPrefix: 'beatport:',
    delivery: NativeIdDelivery.directSource,
    lookup: NativeIdLookup.extensionSearch,
    searchFilter: 'track',
    qualities: ['LOSSLESS', 'HIGH'],
    qualityAliases: {
      'FLAC': 'LOSSLESS',
      'BEST': 'LOSSLESS',
      'HI_RES': 'LOSSLESS',
      'HI_RES_LOSSLESS': 'LOSSLESS',
      'AAC': 'HIGH',
      '256': 'HIGH',
    },
  ),
  'jiosaavn': ProviderRequestSpec(
    providerId: 'jiosaavn',
    idPattern: r'^[A-Za-z0-9_-]{1,32}$',
    delivery: NativeIdDelivery.directSource,
    lookup: NativeIdLookup.extensionSearch,
    searchFilter: 'tracks',
    qualities: ['AAC_320', 'AAC_160', 'AAC_96', 'AAC_48', 'AAC_12'],
  ),
  'soundcloud': ProviderRequestSpec(
    providerId: 'soundcloud',
    idPattern: r'^\d{5,20}$',
    delivery: NativeIdDelivery.directSource,
    lookup: NativeIdLookup.extensionSearch,
    searchFilter: 'tracks',
    qualities: ['aac_160'],
  ),
  'amazon': ProviderRequestSpec(
    providerId: 'amazon',
    idPattern: r'^B[0-9A-Z]{9}$',
    delivery: NativeIdDelivery.directSource,
    lookup: NativeIdLookup.none,
    qualities: ['best', 'opus', 'eac3', 'ac4'],
  ),
  'ytmusic-spotiflac': ProviderRequestSpec(
    providerId: 'ytmusic-spotiflac',
    idPattern: r'^[A-Za-z0-9_-]{11}$',
    delivery: NativeIdDelivery.directSource,
    lookup: NativeIdLookup.none,
    qualities: ['best'],
  ),
};

ProviderRequestSpec? providerRequestSpecFor(String serviceId) =>
    providerRequestSpecs[serviceId.trim().toLowerCase()];
