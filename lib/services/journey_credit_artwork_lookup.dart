import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/journey_credit_lookup.dart';

enum JourneyCreditArtworkKind { logo, signature }

/// A directly linked Commons image with provenance for later attribution.
class JourneyCreditArtwork {
  const JourneyCreditArtwork({
    required this.imageUrl,
    required this.sourcePage,
    required this.license,
    required this.author,
    required this.kind,
    this.licenseUrl,
  });

  final Uri imageUrl;
  final Uri sourcePage;
  final String license;
  final String author;
  final JourneyCreditArtworkKind kind;
  final Uri? licenseUrl;
}

class JourneyCreditArtworkResult {
  const JourneyCreditArtworkResult({
    this.artists = const {},
    this.labels = const {},
    this.producers = const {},
  });
  final Map<String, JourneyCreditArtwork> artists;
  final Map<String, JourneyCreditArtwork> labels;
  final Map<String, JourneyCreditArtwork> producers;
}

/// Resolves artwork exclusively from a verified MusicBrainz identity.
///
/// No name-based artwork search is attempted: missing, ambiguous, uncredited,
/// non-raster or inaccessible assets are omitted. Failures never prevent the
/// caller from showing the ordinary text credit.
class JourneyCreditArtworkLookup {
  JourneyCreditArtworkLookup({
    http.Client? client,
    Future<http.Response> Function(Uri uri)? musicBrainzGet,
    this.timeout = const Duration(seconds: 8),
    this.cacheDuration = const Duration(hours: 6),
  }) : _client = client ?? http.Client(),
       _musicBrainzGet = musicBrainzGet;

  static final JourneyCreditArtworkLookup shared = JourneyCreditArtworkLookup();
  static final _mbid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    caseSensitive: false,
  );
  static const _contact = String.fromEnvironment('MUSA_MUSICBRAINZ_CONTACT');
  static final _headers = {
    'Accept': 'application/json',
    'User-Agent': _contact.trim().isEmpty
        ? 'MUSA/${AppInfo.version}'
        : 'MUSA/${AppInfo.version} (${_contact.trim()})',
  };
  static const _maxEntries = 128;
  final http.Client _client;
  final Future<http.Response> Function(Uri uri)? _musicBrainzGet;
  final Duration timeout;
  final Duration cacheDuration;
  final _pending = <String, Future<JourneyCreditArtwork?>>{};
  final _cache = <String, (JourneyCreditArtwork, DateTime)>{};

  Future<JourneyCreditArtworkResult> lookup({
    required Map<String, String> artistIds,
    required Map<String, String> labelIds,
    Map<String, String> producerIds = const {},
  }) async {
    Future<Map<String, JourneyCreditArtwork>> resolve(
      Map<String, String> ids,
      String type,
    ) async {
      final result = <String, JourneyCreditArtwork>{};
      // Scheduling is shared with metadata lookup. Avoid unbounded work from
      // malformed tags; the interface still displays every plain-text credit.
      for (final entry in ids.entries.take(12)) {
        final name = entry.key.trim();
        final id = entry.value.trim().toLowerCase();
        if (name.isEmpty || !_mbid.hasMatch(id)) continue;
        final art = await _cached(type, id);
        if (art != null) result[name] = art;
      }
      return Map.unmodifiable(result);
    }

    final artists = await resolve(artistIds, 'artist');
    final labels = await resolve(labelIds, 'label');
    final producers = await resolve(producerIds, 'artist');
    return JourneyCreditArtworkResult(
      artists: artists,
      labels: labels,
      producers: producers,
    );
  }

  Future<JourneyCreditArtwork?> _cached(String type, String id) {
    final key = '$type:$id';
    final cached = _cache[key];
    if (cached != null && DateTime.now().isBefore(cached.$2)) {
      return Future.value(cached.$1);
    }
    if (cached != null) _cache.remove(key);
    final existing = _pending[key];
    if (existing != null) return existing;
    late final Future<JourneyCreditArtwork?> future;
    future = _resolve(type, id)
        .then((value) {
          if (value != null) {
            if (_cache.length >= _maxEntries) _cache.remove(_cache.keys.first);
            _cache[key] = (value, DateTime.now().add(cacheDuration));
          }
          return value;
        })
        .whenComplete(() {
          if (identical(_pending[key], future)) _pending.remove(key);
        });
    _pending[key] = future;
    return future;
  }

  Future<JourneyCreditArtwork?> _resolve(String type, String id) async {
    try {
      final mbUri = Uri.https('musicbrainz.org', '/ws/2/$type/$id', {
        'inc': 'url-rels',
        'fmt': 'json',
      });
      final mbResponse = _musicBrainzGet != null
          ? await _musicBrainzGet(mbUri).timeout(timeout)
          : await scheduleMusicBrainzRequest(
              () => _client.get(mbUri, headers: _headers).timeout(timeout),
            );
      final mb = _json(mbResponse);
      if (mb == null ||
          mb['id'] is! String ||
          (mb['id'] as String).toLowerCase() != id) {
        return null;
      }
      final relations = mb['relations'];
      if (relations is! List) return null;
      final ids = <String>{};
      for (final relation in relations) {
        if (relation is! Map || relation['type'] != 'wikidata') continue;
        final url = relation['url'];
        if (url is! Map || url['resource'] is! String) continue;
        final uri = Uri.tryParse(url['resource'] as String);
        if (uri == null ||
            uri.scheme != 'https' ||
            (uri.host != 'www.wikidata.org' && uri.host != 'wikidata.org') ||
            uri.pathSegments.length != 2 ||
            uri.pathSegments.first != 'wiki' ||
            !RegExp(r'^Q[1-9][0-9]*$').hasMatch(uri.pathSegments.last)) {
          continue;
        }
        ids.add(uri.pathSegments.last);
      }
      if (ids.length != 1) return null;
      final qid = ids.single;
      final wdUri = Uri.https('www.wikidata.org', '/w/api.php', {
        'action': 'wbgetentities',
        'ids': qid,
        'props': 'claims',
        'format': 'json',
      });
      final wd = _json(
        await _client.get(wdUri, headers: _headers).timeout(timeout),
      );
      final entities = wd?['entities'];
      final entity = entities is Map ? entities[qid] : null;
      final claims = entity is Map ? entity['claims'] : null;
      if (claims is! Map) return null;
      final properties = type == 'artist' ? ['P109', 'P154'] : ['P154'];
      for (final property in properties) {
        final values = <String>{};
        final statements = claims[property];
        if (statements is! List) continue;
        for (final statement in statements) {
          if (statement is! Map || statement['rank'] == 'deprecated') continue;
          final main = statement['mainsnak'];
          final data = main is Map ? main['datavalue'] : null;
          final value = data is Map ? data['value'] : null;
          if (value is String && value.trim().isNotEmpty) {
            values.add(value.trim());
          }
        }
        if (values.length != 1) continue;
        final artwork = await _commons(
          values.single,
          property == 'P109'
              ? JourneyCreditArtworkKind.signature
              : JourneyCreditArtworkKind.logo,
        );
        if (artwork != null) return artwork;
      }
      return null;
    } catch (_) {
      // A temporary network failure is not cached as an absent asset.
      return null;
    }
  }

  Map<String, dynamic>? _json(http.Response response) {
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 2 * 1024 * 1024) {
      return null;
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<JourneyCreditArtwork?> _commons(
    String file,
    JourneyCreditArtworkKind kind,
  ) async {
    final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'titles': 'File:$file',
      'prop': 'imageinfo',
      'iiprop': 'url|extmetadata|mime',
      'iiurlwidth': '512',
      'format': 'json',
      'formatversion': '2',
    });
    final json = _json(
      await _client.get(uri, headers: _headers).timeout(timeout),
    );
    final query = json?['query'];
    final pages = query is Map ? query['pages'] : null;
    if (pages is! List || pages.length != 1 || pages.first is! Map) return null;
    final images = (pages.first as Map)['imageinfo'];
    if (images is! List || images.length != 1 || images.first is! Map) {
      return null;
    }
    final image = images.first as Map;
    final rawUrl = image['thumburl'] ?? image['url'];
    final imageUrl = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    final source = image['descriptionurl'] is String
        ? Uri.tryParse(image['descriptionurl'] as String)
        : null;
    if (imageUrl == null ||
        imageUrl.scheme != 'https' ||
        imageUrl.host != 'upload.wikimedia.org' ||
        source == null ||
        source.scheme != 'https' ||
        source.host != 'commons.wikimedia.org') {
      return null;
    }
    // SVG originals cannot be decoded by Flutter Image.network: use a verified
    // raster thumbnail when Commons supplies one.
    final mime = image['thumbmime'] ?? image['mime'];
    if (!const {
      'image/png',
      'image/jpeg',
      'image/webp',
      'image/gif',
    }.contains(mime)) {
      return null;
    }
    final metadata = image['extmetadata'];
    if (metadata is! Map) return null;
    String clean(String name) {
      final item = metadata[name];
      final raw = item is Map ? item['value'] : null;
      if (raw is! String) return '';
      return (html.parseFragment(raw).text ?? '').trim().replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
    }

    final author = clean('Artist');
    final license = clean('LicenseShortName');
    if (author.isEmpty ||
        license.isEmpty ||
        author.length > 500 ||
        license.length > 150) {
      return null;
    }
    final licenseValue = clean('LicenseUrl');
    final parsedLicense = Uri.tryParse(licenseValue);
    final normalized = license.trim();
    final publicDomain = RegExp(
      r'^(?:public domain|cc0(?:[ -]1\.0)?)$',
      caseSensitive: false,
    ).hasMatch(normalized);
    final cc = RegExp(
      r'^CC BY(-SA)? ([0-9]+\.[0-9]+)$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (!publicDomain) {
      if (cc == null ||
          parsedLicense == null ||
          parsedLicense.scheme != 'https' ||
          parsedLicense.host != 'creativecommons.org' ||
          parsedLicense.userInfo.isNotEmpty ||
          parsedLicense.hasPort) {
        return null;
      }
      final expectedPath =
          '/licenses/by${cc.group(1)?.toLowerCase() ?? ''}/${cc.group(2)}';
      final actualPath = parsedLicense.path.replaceFirst(RegExp(r'/+$'), '');
      if (actualPath != expectedPath) return null;
    }
    return JourneyCreditArtwork(
      imageUrl: imageUrl,
      sourcePage: source,
      author: author,
      license: license,
      kind: kind,
      licenseUrl:
          parsedLicense != null &&
              parsedLicense.scheme == 'https' &&
              parsedLicense.host == 'creativecommons.org' &&
              parsedLicense.userInfo.isEmpty &&
              !parsedLicense.hasPort
          ? parsedLicense
          : null,
    );
  }
}
