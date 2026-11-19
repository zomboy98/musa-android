import 'package:mornye/models/extension.dart';
import 'package:mornye/utils/download_quality_options.dart';

const _downloadPreferredProviderIds = ['amazon', 'tidal-web', 'tidal'];

int _downloadPreferredRank(String id) {
  final index = _downloadPreferredProviderIds.indexOf(id.toLowerCase());
  return index < 0 ? _downloadPreferredProviderIds.length : index;
}

int _qualityTier(int ceiling) => ceiling >= spatialStrength
    ? 2
    : ceiling >= losslessStrength
    ? 1
    : 0;

/// Audio order computed from what each provider declares: best quality tier
/// first (spatial, then lossless or hi-res, then lossy or undeclared), then
/// providers that need no signed session before those whose session is not
/// active, then the strongest declared quality. The known preference list only
/// breaks the remaining ties, so an unknown provider is placed by its manifest.
List<String> defaultDownloadProviderOrder(
  Iterable<Extension> providers, {
  Set<String> activeSessionIds = const {},
}) {
  final active = {for (final id in activeSessionIds) id.trim().toLowerCase()};
  final entries = [
    for (final entry in providers.indexed)
      (
        index: entry.$1,
        id: entry.$2.id.trim(),
        rank: _downloadPreferredRank(entry.$2.id.trim()),
        strength: downloadQualityCeiling(entry.$2.qualityOptions),
        sessionMissing:
            entry.$2.usesSignedSession &&
                !active.contains(entry.$2.id.trim().toLowerCase())
            ? 1
            : 0,
      ),
  ]..removeWhere((entry) => entry.id.isEmpty);
  entries.sort((a, b) {
    final byTier = _qualityTier(b.strength).compareTo(_qualityTier(a.strength));
    if (byTier != 0) return byTier;
    final bySession = a.sessionMissing.compareTo(b.sessionMissing);
    if (bySession != 0) return bySession;
    final byStrength = b.strength.compareTo(a.strength);
    if (byStrength != 0) return byStrength;
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    final byName = a.id.toLowerCase().compareTo(b.id.toLowerCase());
    return byName != 0 ? byName : a.index.compareTo(b.index);
  });
  final seen = <String>{};
  return [
    for (final entry in entries)
      if (seen.add(entry.id)) entry.id,
  ];
}

const _metadataKnownOrder = [
  'deezer',
  'apple-music',
  'tidal-web',
  'qobuz-web',
  'ytmusic-spotiflac',
  'soundcloud',
  'jiosaavn',
];

const _metadataKnownWithoutIsrc = {'spotify-web', 'amazon', 'beatport'};

int _metadataTier(Extension extension) {
  final id = extension.id.trim().toLowerCase();
  if (_metadataKnownOrder.contains(id)) return 0;
  if (_metadataKnownWithoutIsrc.contains(id)) return 1;
  return extension.skipMetadataEnrichment ? 1 : 0;
}

int _metadataCapabilities(Extension extension) =>
    (extension.hasCustomSearch ? 1 : 0) +
    (extension.searchBehavior?.primary == true ? 1 : 0) +
    (extension.hasHomeFeed ? 1 : 0) +
    (extension.hasRelatedTracks ? 1 : 0) +
    (extension.hasURLHandler ? 1 : 0);

int _metadataRank(String id) {
  final index = _metadataKnownOrder.indexOf(id.toLowerCase());
  return index < 0 ? _metadataKnownOrder.length : index;
}

/// Information order: providers that return complete data (ISRC, covers,
/// labels) come first; those that skip enrichment or return no ISRC go last.
/// Inside each group, the capabilities a provider declares decide, and the
/// known preference list only breaks ties.
List<String> defaultMetadataProviderOrder(Iterable<Extension> providers) {
  final entries = [
    for (final entry in providers.indexed)
      (
        index: entry.$1,
        id: entry.$2.id.trim(),
        tier: _metadataTier(entry.$2),
        rank: _metadataRank(entry.$2.id.trim()),
        capabilities: _metadataCapabilities(entry.$2),
      ),
  ]..removeWhere((entry) => entry.id.isEmpty);
  entries.sort((a, b) {
    final byTier = a.tier.compareTo(b.tier);
    if (byTier != 0) return byTier;
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    final byCapabilities = b.capabilities.compareTo(a.capabilities);
    if (byCapabilities != 0) return byCapabilities;
    final byName = a.id.toLowerCase().compareTo(b.id.toLowerCase());
    return byName != 0 ? byName : a.index.compareTo(b.index);
  });
  final seen = <String>{};
  return [
    for (final entry in entries)
      if (seen.add(entry.id)) entry.id,
  ];
}

bool isAlphabeticalDownloadOrder(
  List<String> saved,
  Iterable<Extension> installed,
) {
  final byId = <String, Extension>{
    for (final ext in installed)
      if (ext.id.trim().isNotEmpty) ext.id.trim(): ext,
  };
  if (saved.isEmpty ||
      saved.toSet().length != saved.length ||
      !byId.keys.toSet().containsAll(saved)) {
    return false;
  }
  final omitted = byId.values.where((ext) => !saved.contains(ext.id.trim()));
  if (omitted.any((ext) => !ext.enabled)) return false;

  bool sortedBy(String Function(Extension) key) {
    for (var i = 1; i < saved.length; i++) {
      if (key(byId[saved[i - 1]]!).compareTo(key(byId[saved[i]]!)) > 0) {
        return false;
      }
    }
    return true;
  }

  return sortedBy((e) => e.id.trim().toLowerCase()) ||
      sortedBy((e) => e.displayName.trim().toLowerCase());
}
