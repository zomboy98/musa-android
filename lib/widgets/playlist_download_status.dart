import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/download_file_inventory.dart';

final _downloadInventoryChanges = StreamProvider.autoDispose<void>(
  (ref) => DownloadFileInventory.changes,
);

final catalogAudioStoreProvider = Provider<Future<CatalogAudioStore>>(
  (ref) => catalogPlayback.store,
);

final _catalogPublicationProvider = StreamProvider.autoDispose
    .family<int, String>((ref, id) async* {
      try {
        final store = await ref.watch(catalogAudioStoreProvider);
        var revision = 0;
        await for (final key in store.publications) {
          if (key == store.publicationKey(id)) yield ++revision;
        }
      } catch (_) {
        // A catalog store may be unavailable while history remains usable.
      }
    });

class _ResumeObserver extends WidgetsBindingObserver {
  _ResumeObserver(this.onResume);
  final VoidCallback onResume;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}

final _resumeVersionProvider =
    NotifierProvider.autoDispose<_ResumeVersion, int>(_ResumeVersion.new);

class _ResumeVersion extends Notifier<int> {
  @override
  int build() {
    final observer = _ResumeObserver(() => state++);
    WidgetsBinding.instance.addObserver(observer);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
    return 0;
  }
}

final persistentCatalogAudioProvider = Provider<Future<bool> Function(Track)>(
  (ref) => (track) async {
    final entry = await (await ref.read(
      catalogAudioStoreProvider,
    )).lookup(catalogPlayback.key(track));
    return entry != null &&
        entry.persistent &&
        await savedDownloadFileAccessible(entry.path);
  },
);

/// Checks accessible downloads and persistent catalog audio.
/// Auto-disposal limits work to mounted playlist rows.
final playlistRealDownloadProvider = FutureProvider.autoDispose
    .family<bool, Track>((ref, track) async {
      ref.watch(_resumeVersionProvider);
      ref.watch(_downloadInventoryChanges);
      ref.watch(_catalogPublicationProvider(catalogPlayback.key(track)));
      ref.watch(
        downloadHistoryProvider.select((state) => state.loadedIndexVersion),
      );
      // A completed download can be prepended without changing the index version.
      ref.watch(
        downloadHistoryProvider.select(
          (state) =>
              state.getBySpotifyId(track.id) ??
              (track.isrc == null ? null : state.getByIsrc(track.isrc!)) ??
              state.findByTrackAndArtist(track.name, track.artistName),
        ),
      );
      final trackKey = trackCollectionKey(track);
      ref.watch(
        savedLibraryTrackKeysProvider.select((keys) => keys.contains(trackKey)),
      );
      try {
        if (await DownloadFileInventory.containsAccessible(
          track,
          savedDownloadFileAccessible,
        )) {
          return true;
        }
      } catch (_) {
        // Other sources may still be available.
      }
      final history = ref.read(downloadHistoryProvider.notifier);
      try {
        final candidates = await history.findTrackCandidatesAsync(
          HistoryLookupRequest(
            spotifyId: track.id,
            isrc: track.isrc,
            trackName: track.name,
            artistName: track.artistName,
          ),
        );
        for (final item in candidates) {
          if (historyMatchesTrack(track, item) &&
              await savedDownloadFileAccessible(item.filePath))
            return true;
        }
      } catch (_) {
        /* Other sources may still be available. */
      }
      return false;
    });

final playlistOfflineAudioProvider = FutureProvider.autoDispose
    .family<bool, Track>((ref, track) async {
      ref.watch(_resumeVersionProvider);
      ref.watch(_catalogPublicationProvider(catalogPlayback.key(track)));
      final trackKey = trackCollectionKey(track);
      ref.watch(
        savedLibraryTrackKeysProvider.select((keys) => keys.contains(trackKey)),
      );
      try {
        return await ref.read(persistentCatalogAudioProvider)(track);
      } catch (_) {
        return false;
      }
    });

// Preserve the existing availability contract for callers of this provider.
final playlistDownloadedFileProvider = FutureProvider.autoDispose
    .family<bool, Track>((ref, track) async {
      final realDownload = ref.watch(
        playlistRealDownloadProvider(track).future,
      );
      final offlineAudio = ref.watch(
        playlistOfflineAudioProvider(track).future,
      );
      if (await realDownload) {
        return true;
      }
      return offlineAudio;
    });

class PlaylistDownloadedIndicator extends ConsumerWidget {
  const PlaylistDownloadedIndicator({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloaded =
        ref.watch(playlistRealDownloadProvider(track)).value == true;
    final offline =
        ref.watch(playlistOfflineAudioProvider(track)).value == true;
    if (!downloaded && !offline) {
      return const SizedBox.shrink();
    }
    return Semantics(
      label: downloaded
          ? context.l10n.trackDownloaded
          : context.l10n.trackAvailableOffline,
      child: Icon(
        Icons.download_done_rounded,
        size: 14,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
