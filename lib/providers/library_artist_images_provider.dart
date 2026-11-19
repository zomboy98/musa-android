import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/setup_artist_catalog.dart';

/// Resolves only exact, unique catalog matches. The family key isolates old
/// results when listening history changes; the cache lives while observed.
final libraryArtistImagesProvider = FutureProvider.autoDispose
    .family<Map<String, String>, String>((ref, encodedNames) async {
      final enabled = ref.watch(
        settingsProvider.select(
          (s) =>
              s.listeningStatisticsEnabled &&
              s.homeFeedProvider != AppSettings.homeFeedProviderOff,
        ),
      );
      if (!enabled) {
        return const {};
      }
      final preferredId = ref.watch(
        settingsProvider.select((s) => s.searchProvider),
      );
      // Only changes that alter the chosen artist-search endpoint invalidate it.
      final endpoint = ref.watch(
        extensionProvider.select((state) {
          final selected = setupArtistCatalogProvider(
            state.extensions,
            preferredId,
          );
          return (
            selected?.id,
            selected?.searchBehavior?.filterIdForKind('artist'),
          );
        }),
      );
      final provider = setupArtistCatalogProvider(
        ref.read(extensionProvider).extensions,
        preferredId,
      );
      if (endpoint == (null, null)) return const {};
      if (provider == null) return const {};
      var disposed = false;
      // Disposal prevents further searches and discards results; it cannot cancel
      // a platform search already in flight.
      ref.onDispose(() => disposed = true);
      final names = (jsonDecode(encodedNames) as List).whereType<String>().take(
        4,
      );
      return resolveLibraryArtistImages(
        names,
        (name) => searchSetupArtistCatalog(provider, name),
        isCancelled: () => disposed,
      );
    });

Future<Map<String, String>> resolveLibraryArtistImages(
  Iterable<String> names,
  SetupArtistSearch search, {
  bool Function()? isCancelled,
}) async {
  final images = <String, String>{};
  final seen = <String>{};
  for (final name in names.take(4)) {
    final key = name.trim().toLowerCase();
    if (key.isEmpty || !seen.add(key) || (isCancelled?.call() ?? false)) {
      continue;
    }
    try {
      final results = await search(name).timeout(const Duration(seconds: 8));
      if (isCancelled?.call() ?? false) break;
      final matches = results
          .where((artist) => artist.name.trim().toLowerCase() == key)
          .toList();
      if (matches.length == 1 &&
          matches.single.imageUrl?.trim().isNotEmpty == true) {
        images[key] = matches.single.imageUrl!;
      }
    } catch (_) {
      // Offline, unavailable, or timed out: leave this artist without a photo.
    }
  }
  return images;
}

/// Merge only trimmed, case-insensitive variants; punctuation remains distinct.
List<String> rankLibraryArtists(Map<String, int> artists) {
  final totals = <String, int>{};
  final labels = <String, String>{};
  for (final entry in artists.entries) {
    final label = entry.key.trim();
    final key = label.toLowerCase();
    if (key.isEmpty) continue;
    totals[key] = (totals[key] ?? 0) + entry.value;
    labels.putIfAbsent(key, () => label);
  }
  final keys = totals.keys.toList()
    ..sort((a, b) {
      final byDuration = totals[b]!.compareTo(totals[a]!);
      return byDuration != 0 ? byDuration : a.compareTo(b);
    });
  return keys.take(4).map((key) => labels[key]!).toList(growable: false);
}
