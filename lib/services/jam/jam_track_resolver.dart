import 'jam_playback.dart';
import 'jam_track_reference.dart';

/// One independently playable entry already present in the host library.
class JamLocalCandidate<T extends Object> {
  const JamLocalCandidate({required this.reference, required this.value});
  final JamTrackReference reference;
  final T value;
}

/// Resolves solely against a caller-supplied local inventory. Ambiguous matches,
/// malformed references, legacy opaque IDs and conflicting identities fail closed.
class JamLibraryTrackResolver<T extends Object> implements JamTrackResolver<T> {
  JamLibraryTrackResolver(this.loadLocalCandidates);
  final Future<List<JamLocalCandidate<T>>> Function() loadLocalCandidates;

  @override
  Future<T?> resolveLocal(String trackId) async {
    final ref = JamTrackReference.tryDecode(trackId);
    if (ref == null) return null;
    T? match;
    var count = 0;
    for (final candidate in await loadLocalCandidates()) {
      final local = candidate.reference;
      final providerMatch =
          ref.provider != null &&
          ref.provider == local.provider &&
          ref.externalId == local.externalId;
      final isrcMatch = ref.isrc != null && ref.isrc == local.isrc;
      if (!providerMatch && !isrcMatch) continue;
      if (ref.provider != null &&
          ref.provider == local.provider &&
          ref.externalId != local.externalId)
        continue;
      if (ref.isrc != null && local.isrc != null && ref.isrc != local.isrc)
        continue;
      match = candidate.value;
      if (++count > 1) return null;
    }
    return match;
  }
}
