import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';

class SetupArtistChoice {
  const SetupArtistChoice(
    this.name, {
    this.imageUrl,
    this.deezerId,
    this.catalog,
    this.catalogArtistId,
  });

  final String name;
  final String? imageUrl;
  final String? deezerId;
  final String? catalog;
  final String? catalogArtistId;
}

typedef SetupArtistSearch = Future<List<SetupArtistChoice>> Function(String);

/// Only advertise artist search when the extension declares a matching filter.
Extension? setupArtistCatalogProvider(
  List<Extension> extensions,
  String? preferredId,
) {
  final capable = extensions
      .where(
        (extension) =>
            extension.enabled &&
            extension.hasCustomSearch &&
            extension.searchBehavior?.filterIdForKind('artist') != null,
      )
      .toList();
  return capable
          .where((extension) => extension.id == preferredId)
          .firstOrNull ??
      defaultSearchExtension(capable);
}

Future<List<SetupArtistChoice>> searchSetupArtistCatalog(
  Extension provider,
  String query, {
  Future<List<Map<String, dynamic>>> Function(
    String providerId,
    String query,
    Map<String, dynamic> options,
  )?
  search,
}) async {
  final normalizedQuery = query.trim();
  final filter = provider.searchBehavior?.filterIdForKind('artist');
  if (normalizedQuery.length < 2 ||
      !provider.enabled ||
      !provider.hasCustomSearch ||
      filter == null) {
    return const [];
  }
  final options = <String, dynamic>{'filter': filter};
  final results = search != null
      ? await search(provider.id, normalizedQuery, options)
      : await PlatformBridge.customSearchWithExtension(
          provider.id,
          normalizedQuery,
          options: options,
        );
  final tracks = results
      .map((result) => Track.fromBackendMap(result, source: provider.id))
      .where((track) => track.isArtistItem)
      .toList();
  final counts = <String, int>{};
  for (final track in tracks) {
    final name = track.name.trim().toLowerCase();
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return tracks.map((track) {
    final match =
        provider.id == 'deezer' && counts[track.name.trim().toLowerCase()] == 1
        ? RegExp(r'^deezer:([0-9]+)$').firstMatch(track.id)
        : null;
    return SetupArtistChoice(
      track.name,
      imageUrl: track.coverUrl,
      deezerId: match?.group(1),
      catalog: provider.id,
      catalogArtistId: match?.group(1) ?? track.id,
    );
  }).toList();
}
