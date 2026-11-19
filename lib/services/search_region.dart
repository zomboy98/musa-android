import 'dart:ui' show PlatformDispatcher;

/// Setting value that follows the device country.
const String searchRegionAuto = 'auto';

/// Setting value that disables any regional signal.
const String searchRegionNone = 'none';

/// Country used when the device does not tell its own.
const String searchRegionFallback = 'us';

/// Weight of the chosen region and of each neighbor in the regional signal.
const double searchRegionWeight = 1.0;
const double searchNeighborWeight = 0.6;

/// Neighbors that join the chosen region.
const int searchRegionMaxNeighbors = 2;

/// Neighboring countries (ISO 3166-1 alpha-2, lower case), geographic only
/// and in order of preference. A country that is missing has no neighbors.
const Map<String, List<String>> searchRegionNeighbors = {
  'us': ['ca', 'mx'],
  'ca': ['us'],
  'mx': ['us', 'gt', 'bz'],
  'gt': ['mx', 'sv', 'hn'],
  'bz': ['mx', 'gt'],
  'sv': ['gt', 'hn'],
  'hn': ['gt', 'sv', 'ni'],
  'ni': ['hn', 'cr'],
  'cr': ['ni', 'pa'],
  'pa': ['cr', 'co'],
  'co': ['ve', 'ec', 'pe'],
  've': ['co', 'br'],
  'ec': ['co', 'pe'],
  'pe': ['ec', 'co', 'bo'],
  'bo': ['pe', 'br', 'py'],
  'br': ['ar', 'uy', 'py'],
  'py': ['ar', 'br', 'bo'],
  'uy': ['ar', 'br'],
  'ar': ['uy', 'cl', 'py'],
  'cl': ['ar', 'pe', 'bo'],
  'do': ['pr', 'cu'],
  'pr': ['do'],
  'cu': ['do', 'us'],
  'es': ['pt', 'fr'],
  'pt': ['es'],
  'fr': ['es', 'be', 'de'],
  'be': ['nl', 'fr', 'de'],
  'nl': ['be', 'de'],
  'de': ['at', 'nl', 'fr'],
  'at': ['de', 'ch', 'it'],
  'ch': ['de', 'fr', 'it'],
  'it': ['ch', 'fr', 'at'],
  'gb': ['ie', 'fr'],
  'ie': ['gb'],
  'se': ['no', 'fi', 'dk'],
  'no': ['se', 'dk', 'fi'],
  'dk': ['se', 'de', 'no'],
  'fi': ['se', 'no', 'ee'],
  'pl': ['de', 'cz', 'sk'],
  'au': ['nz'],
  'nz': ['au'],
  'jp': ['kr'],
  'kr': ['jp'],
};

/// Countries the user can pick: code, English name, Spanish name.
const List<({String code, String en, String es})> searchRegionCountries = [
  (code: 'us', en: 'United States', es: 'Estados Unidos'),
  (code: 'ca', en: 'Canada', es: 'Canadá'),
  (code: 'mx', en: 'Mexico', es: 'México'),
  (code: 'gt', en: 'Guatemala', es: 'Guatemala'),
  (code: 'bz', en: 'Belize', es: 'Belice'),
  (code: 'sv', en: 'El Salvador', es: 'El Salvador'),
  (code: 'hn', en: 'Honduras', es: 'Honduras'),
  (code: 'ni', en: 'Nicaragua', es: 'Nicaragua'),
  (code: 'cr', en: 'Costa Rica', es: 'Costa Rica'),
  (code: 'pa', en: 'Panama', es: 'Panamá'),
  (code: 'co', en: 'Colombia', es: 'Colombia'),
  (code: 've', en: 'Venezuela', es: 'Venezuela'),
  (code: 'ec', en: 'Ecuador', es: 'Ecuador'),
  (code: 'pe', en: 'Peru', es: 'Perú'),
  (code: 'bo', en: 'Bolivia', es: 'Bolivia'),
  (code: 'br', en: 'Brazil', es: 'Brasil'),
  (code: 'py', en: 'Paraguay', es: 'Paraguay'),
  (code: 'uy', en: 'Uruguay', es: 'Uruguay'),
  (code: 'ar', en: 'Argentina', es: 'Argentina'),
  (code: 'cl', en: 'Chile', es: 'Chile'),
  (code: 'do', en: 'Dominican Republic', es: 'República Dominicana'),
  (code: 'pr', en: 'Puerto Rico', es: 'Puerto Rico'),
  (code: 'cu', en: 'Cuba', es: 'Cuba'),
  (code: 'es', en: 'Spain', es: 'España'),
  (code: 'pt', en: 'Portugal', es: 'Portugal'),
  (code: 'fr', en: 'France', es: 'Francia'),
  (code: 'be', en: 'Belgium', es: 'Bélgica'),
  (code: 'nl', en: 'Netherlands', es: 'Países Bajos'),
  (code: 'de', en: 'Germany', es: 'Alemania'),
  (code: 'at', en: 'Austria', es: 'Austria'),
  (code: 'ch', en: 'Switzerland', es: 'Suiza'),
  (code: 'it', en: 'Italy', es: 'Italia'),
  (code: 'gb', en: 'United Kingdom', es: 'Reino Unido'),
  (code: 'ie', en: 'Ireland', es: 'Irlanda'),
  (code: 'se', en: 'Sweden', es: 'Suecia'),
  (code: 'no', en: 'Norway', es: 'Noruega'),
  (code: 'dk', en: 'Denmark', es: 'Dinamarca'),
  (code: 'fi', en: 'Finland', es: 'Finlandia'),
  (code: 'pl', en: 'Poland', es: 'Polonia'),
  (code: 'au', en: 'Australia', es: 'Australia'),
  (code: 'nz', en: 'New Zealand', es: 'Nueva Zelanda'),
  (code: 'jp', en: 'Japan', es: 'Japón'),
  (code: 'kr', en: 'South Korea', es: 'Corea del Sur'),
];

/// A country of the signal and how much its ranking counts.
typedef RegionWeight = ({String code, double weight});

/// Normalizes a stored setting: `auto`, `none` or a known country code.
String sanitizeSearchRegion(String? value) {
  final text = value?.trim().toLowerCase();
  if (text == null || text.isEmpty || text == searchRegionAuto) {
    return searchRegionAuto;
  }
  if (text == searchRegionNone) return searchRegionNone;
  return searchRegionCountries.any((country) => country.code == text)
      ? text
      : searchRegionAuto;
}

/// Country of the device from its locales, lower case, or null.
String? deviceCountryCode() {
  final dispatcher = PlatformDispatcher.instance;
  for (final locale in [dispatcher.locale, ...dispatcher.locales]) {
    final code = locale.countryCode;
    if (code != null && code.length == 2) return code.toLowerCase();
  }
  return null;
}

/// The country the signal uses for [setting], or null when it is off.
String? resolveSearchRegion(String? setting, {String? deviceCountry}) {
  final value = sanitizeSearchRegion(setting);
  if (value == searchRegionNone) return null;
  if (value != searchRegionAuto) return value;
  final device = deviceCountry?.trim().toLowerCase();
  if (device != null &&
      searchRegionCountries.any((country) => country.code == device)) {
    return device;
  }
  return searchRegionFallback;
}

/// The chosen region (weight 1.0) followed by its neighbors (weight 0.6).
List<RegionWeight> searchRegionWeights(String region) {
  final code = region.trim().toLowerCase();
  return [
    (code: code, weight: searchRegionWeight),
    for (final neighbor
        in (searchRegionNeighbors[code] ?? const <String>[]).take(
          searchRegionMaxNeighbors,
        ))
      (code: neighbor, weight: searchNeighborWeight),
  ];
}

/// Display name of [code] in [languageCode] (Spanish or English).
String searchRegionName(String code, String languageCode) {
  for (final country in searchRegionCountries) {
    if (country.code == code.toLowerCase()) {
      return languageCode == 'es' ? country.es : country.en;
    }
  }
  return code.toUpperCase();
}
