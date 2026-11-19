import 'package:flutter/widgets.dart';

const _kinds = {
  'label',
  'description',
  'setting_title',
  'setting_description',
  'status',
};

String _normalize(String text) => text
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\.+$'), '');

String _key(String extensionId, String optionId, String kind) =>
    '${extensionId.trim().toLowerCase()}|'
    '${optionId.trim().toLowerCase()}|$kind';

Locale _localeOf(Object localeOrContext) {
  if (localeOrContext is Locale) return localeOrContext;
  if (localeOrContext is BuildContext) {
    return Localizations.maybeLocaleOf(localeOrContext) ?? const Locale('en');
  }
  return const Locale('en');
}

String? _lookup({
  String? extensionId,
  String? optionId,
  required String kind,
  required String original,
}) {
  if (!_kinds.contains(kind)) return null;
  if (extensionId != null && optionId != null) {
    final exact = _byId[_key(extensionId, optionId, kind)];
    if (exact != null) return exact;
  }
  return _byText[_normalize(original)];
}

bool hasProviderTextTranslation({
  String? extensionId,
  String? optionId,
  required String kind,
  required String original,
}) =>
    _lookup(
      extensionId: extensionId,
      optionId: optionId,
      kind: kind,
      original: original,
    ) !=
    null;

String localizedProviderText(
  Object localeOrContext, {
  String? extensionId,
  String? optionId,
  required String kind,
  required String original,
}) {
  if (original.isEmpty || _localeOf(localeOrContext).languageCode != 'es') {
    return original;
  }
  return _lookup(
        extensionId: extensionId,
        optionId: optionId,
        kind: kind,
        original: original,
      ) ??
      original;
}

String localizedExtensionDescription(
  Object localeOrContext,
  String extensionId,
  String original,
) => localizedProviderText(
  localeOrContext,
  extensionId: extensionId,
  optionId: 'description',
  kind: 'description',
  original: original,
);

const Map<String, String> _byId = {
  'amazon|best|label': 'FLAC (mejor disponible)',
  'amazon|best|description': 'Mejor calidad disponible (hasta 24 bits/192 kHz)',
  'amazon|opus|label': 'Opus 320 kbps',
  'amazon|opus|description': 'Audio Opus de alta calidad a 320 kbps',
  'amazon|eac3|label': 'Dolby Digital Plus',
  'amazon|eac3|description': 'Sonido envolvente Dolby Digital Plus (E-AC-3)',
  'amazon|ac4|label': 'Dolby Atmos (AC-4)',
  'amazon|ac4|description':
      'Audio inmersivo Dolby Atmos (AC-4, paso directo MP4)',
  'amazon|homecountry|setting_title': 'País del feed de inicio',
  'amazon|homecountry|setting_description':
      'País usado para las recomendaciones de inicio. La búsqueda y las '
      'descargas mantienen su catálogo actual. No se necesita VPN.',
  'beatport|lossless|label': 'FLAC sin pérdida',
  'beatport|lossless|description': 'Audio original sin pérdida. No baja a AAC.',
  'beatport|high|label': 'AAC 256 kbps',
  'beatport|high|description': 'AAC original en M4A, sin recodificar.',
  'deezer|flac|label': 'FLAC / Hi-Res',
  'deezer|flac|description':
      'Mejor audio sin pérdida disponible, hasta 24 bits/192 kHz en pistas '
      'compatibles. La resolución real varía según la fuente.',
  'deezer|apibaseurl|setting_title': 'URL de la API de resolución',
  'deezer|apibaseurl|setting_description':
      'URL base de la API de resolución de Deezer.',
  'jiosaavn|aac_320|label': 'AAC 320 kbps',
  'jiosaavn|aac_320|description': 'La mayor calidad que ofrece JioSaavn',
  'jiosaavn|aac_160|label': 'AAC 160 kbps',
  'jiosaavn|aac_160|description': 'Buena calidad, archivos más pequeños',
  'jiosaavn|aac_96|label': 'AAC 96 kbps',
  'jiosaavn|aac_96|description': 'Ahorro de datos',
  'jiosaavn|aac_48|label': 'AAC 48 kbps',
  'jiosaavn|aac_48|description': 'Calidad baja',
  'jiosaavn|aac_12|label': 'AAC 12 kbps',
  'jiosaavn|aac_12|description': 'La tasa de bits más baja',
  'jiosaavn|lang|setting_title': 'Idiomas',
  'jiosaavn|lang|setting_description': 'Idiomas separados por comas',
  'jiosaavn|clear_cache|setting_title': 'Borrar caché',
  'jiosaavn|clear_cache|setting_description':
      'Elimina todos los datos en caché',
  'qobuz-web|hi_res_lossless|label': '24 bits máx.',
  'qobuz-web|hi_res_lossless|description':
      'Intenta primero la mayor calidad Hi-Res de Qobuz',
  'qobuz-web|hi_res|label': '24 bits',
  'qobuz-web|hi_res|description': 'Prefiere la calidad de 24 bits de Qobuz',
  'qobuz-web|lossless|label': 'Sin pérdida',
  'qobuz-web|lossless|description':
      'Recurre a la calidad sin pérdida estándar de Qobuz',
  'qobuz-web|appid|setting_title': 'ID de app de Qobuz',
  'qobuz-web|appid|setting_description':
      'ID de app enviado a la API principal de metadatos.',
  'qobuz-web|countrycode|setting_title': 'Código de país',
  'qobuz-web|countrycode|setting_description':
      'Código de país usado en las solicitudes al proveedor que lo requieren.',
  'soundcloud|aac_160|label': 'AAC hasta 160 kbps',
  'soundcloud|aac_160|description':
      'Calidad actual de SoundCloud, guardada como M4A sin recodificar; si no '
      'está disponible, usa la transmisión completa disponible',
  'tidal-web|dolby_atmos|label': 'Dolby Atmos',
  'tidal-web|dolby_atmos|description':
      'Exigir Dolby Atmos cuando esté disponible; si no, bajar solo al mejor '
      'nivel FLAC disponible',
  'tidal-web|hi_res_lossless|label': 'Hi-Res FLAC',
  'tidal-web|hi_res_lossless|description':
      'Preferir FLAC Hi-Res de 24 bits; bajar solo a FLAC sin pérdida cuando '
      'la pista se limite a 16 bits',
  'tidal-web|lossless|label': 'FLAC sin pérdida',
  'tidal-web|lossless|description':
      'Exigir TIDAL sin pérdida sin bajar a un nivel comprimido',
  'tidal-web|high|label': 'Alta (AAC 320 kbps)',
  'tidal-web|high|description': 'Exigir TIDAL Alta sin bajar a Baja',
  'tidal-web|low|label': 'Baja (AAC 96 kbps)',
  'tidal-web|low|description': 'Exigir TIDAL Baja',
  'tidal-web|publictoken|setting_title': 'Token web público',
  'tidal-web|publictoken|setting_description':
      'Token web público de TIDAL usado en las solicitudes de metadatos y '
      'búsqueda.',
  'tidal-web|countrycode|setting_title': 'Código de país',
  'tidal-web|countrycode|setting_description':
      'Código de país enviado a los endpoints públicos de TIDAL.',
  'tidal-web|locale|setting_title': 'Configuración regional',
  'tidal-web|locale|setting_description':
      'Configuración regional enviada a los endpoints públicos de TIDAL.',
  'tidal-web|devicetype|setting_title': 'Tipo de dispositivo',
  'tidal-web|devicetype|setting_description':
      'Tipo de dispositivo enviado a los endpoints públicos de TIDAL.',
  'tidal-web|downloadapiurl|setting_title': 'URL de la API de descarga',
  'tidal-web|downloadapiurl|setting_description':
      'API principal de descarga de TIDAL usada para la selección estricta de '
      'calidad y el paso de Dolby a FLAC.',
  'tidal-web|customendpoint|setting_title': 'Endpoint de descarga propio',
  'tidal-web|customendpoint|setting_description':
      'Opcional. URL base de tu propio servidor compatible con hifi-api '
      '(https://github.com/binimum/hifi-api), por ejemplo '
      'http://192.168.1.10:8000. Se prueba antes que la API de descarga '
      'predeterminada. Un servidor de tu red doméstica también necesita '
      'tener activado Permitir acceso a la red local en los ajustes de '
      'descarga.',
  'ytmusic-spotiflac|best|label': 'Mejor audio',
  'ytmusic-spotiflac|best|description': 'Audio Opus/M4A directo de YouTube',
  'ytmusic-spotiflac|homecountry|setting_title': 'País del feed de inicio',
  'ytmusic-spotiflac|homecountry|setting_description':
      'País usado para las recomendaciones de inicio. No se necesita VPN.',
  'ytmusic-spotiflac|potokenmode|setting_title': 'Modo de token PO',
  'ytmusic-spotiflac|potokenmode|setting_description':
      'Compatibilidad opcional con token PO de GVS. Déjalo desactivado salvo '
      'que las descargas directas de YouTube empiecen a devolver 403.',
  'ytmusic-spotiflac|potokenproviderurl|setting_title':
      'URL del proveedor de token PO',
  'ytmusic-spotiflac|potokenproviderurl|setting_description':
      'URL base opcional de un proveedor compatible con BgUtils o endpoint '
      '/get_pot. Se usa para obtener tokens PO de GVS nuevos cuando las '
      'descargas directas de YouTube los necesitan.',
  'ytmusic-spotiflac|manualgvspotoken|setting_title': 'Token PO de GVS manual',
  'ytmusic-spotiflac|manualgvspotoken|setting_description':
      'Token sin procesar opcional o CLIENT.gvs+TOKEN. Los tokens manuales '
      'pueden caducar o estar ligados a un video.',
  'ytmusic-spotiflac|loglevel|setting_title': 'Nivel de registro',
  'ytmusic-spotiflac|loglevel|setting_description':
      'Controla el detalle del registro de la extensión. Usa debug solo '
      'mientras diagnosticas problemas de YouTube Music.',
  'apple-music|storefront|setting_title': 'Tienda / región',
  'apple-music|storefront|setting_description':
      'País usado para las recomendaciones de inicio, la búsqueda y la '
      'disponibilidad del catálogo. No se necesita VPN.',
  'apple-music|mediausertoken|setting_title': 'Token de usuario de medios',
  'apple-music|mediausertoken|setting_description':
      'Necesario para las letras. Obtenlo desde la consola del navegador en '
      'music.apple.com: MusicKit.getInstance().musicUserToken. Requiere '
      'una suscripción activa a Apple Music.',
  'apple-music|lyricstranslation|setting_title':
      'Idioma de traducción de letras',
  'apple-music|lyricstranslation|setting_description':
      'Código de idioma para las letras traducidas (p. ej. en, zh-Hans, ja, '
      'ko, id). Déjalo vacío para desactivarlo. Usa las traducciones '
      'integradas de Apple Music.',
  'apple-music|lyricspronunciation|setting_title':
      'Idioma de pronunciación de letras',
  'apple-music|lyricspronunciation|setting_description':
      'Código de idioma para la pronunciación romanizada (p. ej. ja-Latn para '
      'romaji, ko-Latn para coreano). Déjalo vacío para desactivarlo.',
  'amazon|description|description':
      'Proveedor de metadatos y descargas de Amazon Music. Explora pistas, '
      'álbumes, artistas y listas desde enlaces y búsquedas de Amazon '
      'Music. Descarga audio sin pérdida y Dolby Atmos.',
  'apple-music|description|description':
      'Proveedor de metadatos y letras de Apple Music con coincidencia de '
      'pistas protegida, caché acotada, solicitudes resilientes y '
      'metadatos de lanzamiento completos.',
  'beatport|description|description':
      'Búsqueda de pistas, artistas y lanzamientos de Beatport, discografías '
      'de artistas y descargas originales en FLAC o AAC 256 kbps.',
  'bugs-music|description|description':
      'Búsqueda, metadatos de pistas y álbumes, catálogos de artistas, listas '
      'de éxitos, listas por género e importación por URL de Bugs Music',
  'deezer|description|description':
      'Metadatos de Deezer y descargas sin pérdida Hi-Res, con la calidad de '
      'audio medida a partir de cada archivo descargado y metadatos de '
      'lanzamiento completos.',
  'genie-music|description|description':
      'Metadatos de pistas y álbumes de Genie Music, catálogos de artistas '
      'paginados, listas de éxitos e importación por URL',
  'jiosaavn|description|description':
      'Busca y descarga pistas AAC de JioSaavn; explora álbumes, listas, '
      'artistas y el feed de inicio.',
  'melon-music|description|description':
      'Proveedor de metadatos de Melon Music con listas de éxitos, catálogos '
      'de álbumes y artistas, listas de DJ e importación por URL',
  'qobuz-web|description|description':
      'Proveedor de metadatos y descargas de Qobuz con búsqueda de álbumes '
      'resiliente y recuperación de pistas, metadatos de lanzamiento '
      'completos, créditos, totales de varios discos y carátulas '
      'originales.',
  'soundcloud|description|description':
      'Proveedor de metadatos y descargas de SoundCloud. Busca pistas, '
      'álbumes, listas y artistas. Descarga mediante transmisiones '
      'directas de SoundCloud.',
  'spotify-web|description|description':
      'Proveedor de metadatos de Spotify con lanzamientos nativos completos, '
      'discos, ID de catálogo, créditos y carátulas, además de '
      'enriquecimiento de género protegido.',
  'tidal-web|description|description':
      'Proveedor de metadatos y búsqueda de TIDAL que usa los endpoints web '
      'públicos de TIDAL.',
  'ytmusic-spotiflac|description|description':
      'Proveedor de metadatos y descargas de YouTube Music con metadatos '
      'nativos de álbum, artista, contenido explícito, lanzamiento y '
      'créditos de canciones, más enriquecimiento de catálogo validado.',
};

const Map<String, String> _byTextSource = {
  'Best Audio': 'Mejor audio',
  'Hi-Res FLAC': 'Hi-Res FLAC',
  'HiRes FLAC': 'Hi-Res FLAC',
  'FLAC Lossless': 'FLAC sin pérdida',
  'Lossless': 'Sin pérdida',
  'High': 'Alta',
  'Low': 'Baja',
  'Require TIDAL High without falling back to Low':
      'Exigir TIDAL Alta sin bajar a Baja',
  'Require TIDAL Low': 'Exigir TIDAL Baja',
  'Require TIDAL lossless without falling back to a compressed tier':
      'Exigir TIDAL sin pérdida sin bajar a un nivel comprimido',
  'Require Dolby Atmos when supported; otherwise fall back only to the best available FLAC tier':
      'Exigir Dolby Atmos cuando esté disponible; si no, bajar solo al mejor '
      'nivel FLAC disponible',
  'Prefer 24-bit Hi-Res FLAC; fall back only to Lossless FLAC when the track is limited to 16-bit':
      'Preferir FLAC Hi-Res de 24 bits; bajar solo a FLAC sin pérdida cuando '
      'la pista se limite a 16 bits',
  'Best available quality (up to 24-bit/192kHz)':
      'Mejor calidad disponible (hasta 24 bits/192 kHz)',
  'High quality Opus audio at 320kbps': 'Audio Opus de alta calidad a 320 kbps',
  'Opus/M4A audio direct from YouTube': 'Audio Opus/M4A directo de YouTube',
  'Highest quality JioSaavn offers': 'La mayor calidad que ofrece JioSaavn',
  'Good quality, smaller files': 'Buena calidad, archivos más pequeños',
  'Data saver': 'Ahorro de datos',
  'Low quality': 'Calidad baja',
  'Lowest bitrate': 'La tasa de bits más baja',
  'FLAC Best Available': 'FLAC (mejor disponible)',
  'FLAC / Hi-Res': 'FLAC / Hi-Res',
  'Home feed country': 'País del feed de inicio',
  'Country Code': 'Código de país',
  'Enabled': 'Activada',
  'Disabled': 'Desactivada',
  'Needs verification': 'Requiere verificación',
  'Verified': 'Verificada',
  'Healthy': 'Funciona',
  'Unavailable': 'No disponible',
};

final Map<String, String> _byText = {
  for (final entry in _byTextSource.entries) _normalize(entry.key): entry.value,
};
