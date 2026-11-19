import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/file_access.dart';

/// Keeps one file lookup for an unchanged, ordered collection selection.
@immutable
class CollectionTrackFilesRequest {
  CollectionTrackFilesRequest(
    Iterable<Track> tracks, {
    this.listContext,
    Iterable<String>? listOccurrences,
  }) : tracks = List.unmodifiable(tracks),
       listOccurrences = listOccurrences == null
           ? null
           : List.unmodifiable(listOccurrences) {
    assert(
      this.listOccurrences == null ||
          this.listOccurrences!.length == this.tracks.length,
    );
  }

  final List<Track> tracks;
  final String? listContext;
  final List<String>? listOccurrences;

  @override
  bool operator ==(Object other) =>
      other is CollectionTrackFilesRequest &&
      listEquals(tracks, other.tracks) &&
      listContext == other.listContext &&
      listEquals(listOccurrences, other.listOccurrences);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(tracks),
    listContext,
    listOccurrences == null ? null : Object.hashAll(listOccurrences!),
  );
}

final collectionTrackFilesProvider = FutureProvider.autoDispose
    .family<List<PlayableMedia>, CollectionTrackFilesRequest>((
      ref,
      request,
    ) async {
      final tracks = request.tracks;
      final paths = await ref
          .watch(playbackProvider.notifier)
          .resolveTrackFilePaths(tracks);
      return [
        for (var index = 0; index < tracks.length; index++)
          if (paths[index] case final path?)
            if (path.isNotEmpty && !isCueVirtualPath(path))
              playableFromTrack(
                tracks[index],
                path,
                listContext: request.listContext,
                listOccurrence: request.listOccurrences?[index],
              ),
      ];
    });
