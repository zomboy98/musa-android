import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/open_current_player.dart';
import 'package:mornye/providers/library_playlist_order_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/download_file_recovery.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/track_file_resolver.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('PlaybackProvider');

class LocalTrackUnavailableException implements Exception {
  const LocalTrackUnavailableException();
  @override
  String toString() => 'El archivo local no está disponible.';
}

class PlaybackState {
  const PlaybackState();
}

class PlaybackController extends Notifier<PlaybackState> {
  PlaybackController({LibraryDatabase? library, HistoryDatabase? history})
    : _library = library ?? LibraryDatabase.instance,
      _history = history ?? HistoryDatabase.instance;

  final LibraryDatabase _library;
  final HistoryDatabase _history;
  int _requestGeneration = 0;

  @override
  PlaybackState build() => const PlaybackState();

  Future<bool> openPlayerIfCurrent({
    Track? track,
    PlaybackRowKey? row,
    String? listContext,
    String? listOccurrence,
  }) async {
    try {
      final item = ref.read(currentMediaItemProvider).value;
      if (item == null) return false;
      var isCurrent = row != null && mediaItemPlaysRow(item, row);
      if (!isCurrent && listContext != null && listOccurrence != null) {
        final extras = item.extras;
        isCurrent =
            extras?['listContext'] == listContext &&
            extras?['listOccurrence'] == listOccurrence;
      }
      if (!isCurrent && track != null) {
        final identity = await ref.read(currentTrackIdentityProvider.future);
        isCurrent = identity?.matches(catalogTrackKey(track)) ?? false;
      }
      if (!isCurrent) return false;
      ref.read(openNowPlayingProvider)();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _useInternalPlayer({String? source, bool force = false}) async {
    final mode = ref.read(settingsProvider).playerMode;
    if (!force &&
        mode != 'internal' &&
        source?.startsWith('network://') != true) {
      return false;
    }
    return await ref.read(musicPlayerControllerProvider).ensureInitialized() !=
        null;
  }

  Future<bool> _stopInternalBeforeExternal(int generation) async {
    if (generation != _requestGeneration) return false;
    final handler = ref.read(musicPlayerRuntimeProvider).handler;
    if (handler != null) {
      final pendingStop = handler.stop();
      final stopGeneration = handler.playbackRequestGeneration;
      await pendingStop;
      if (!identical(handler, ref.read(musicPlayerRuntimeProvider).handler) ||
          handler.playbackRequestGeneration != stopGeneration)
        return false;
    }
    if (generation != _requestGeneration) return false;
    ref.read(internalCatalogSessionProvider.notifier).setActive(false);
    return true;
  }

  Future<void> playLocalPath({
    required String path,
    required String title,
    required String artist,
    String album = '',
    String coverUrl = '',
    Duration? duration,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    String? format,
    bool? explicit,
  }) async {
    final generation = ++_requestGeneration;
    if (isCueVirtualPath(path)) {
      throw Exception(cueVirtualTrackRequiresSplitMessage);
    }

    if (await _useInternalPlayer(source: path)) {
      if (generation != _requestGeneration) return;
      if (ref.read(settingsProvider).playerMode != 'internal') {
        ref.read(internalCatalogSessionProvider.notifier).setActive(true);
      }
      _log.d('Playing "$title" in the internal player: $path');
      await ref
          .read(musicPlayerControllerProvider)
          .playSingle(
            PlayableMedia(
              id: path,
              source: path,
              title: title,
              artist: artist,
              album: album,
              artUri: normalizeArtUri(coverUrl),
              duration: duration,
              bitDepth: bitDepth,
              sampleRate: sampleRate,
              bitrate: bitrate,
              format: format,
              explicit: explicit ?? false,
            ),
            isCurrentRequest: () => generation == _requestGeneration,
          );
      return;
    }

    _log.d('Opening external player for "$title" by $artist: $path');
    if (!await _stopInternalBeforeExternal(generation)) return;
    final recovered = Platform.isAndroid
        ? await DownloadFileRecovery.instance.recover(
            path,
            settings: ref.read(settingsProvider),
          )
        : null;
    if (generation == _requestGeneration) await openFile(recovered ?? path);
  }

  /// Plays a local-library album/list starting at [startItem], queuing the rest
  /// so playback continues to the next track automatically. Honors player mode.
  Future<void> playLocalLibraryQueue(
    List<LocalLibraryItem> items, {
    required LocalLibraryItem startItem,
    int? startIndex,
  }) => _playQueue(
    items,
    (i) => i.id == startItem.id,
    (i) => i.filePath,
    playableFromLocal,
    startIndex: startIndex,
  );

  /// Plays a downloaded-history album/list starting at [startItem], queuing the
  /// rest. Honors player mode.
  Future<void> playHistoryQueue(
    List<DownloadHistoryItem> items, {
    required DownloadHistoryItem startItem,
    int? startIndex,
  }) => _playQueue(
    items,
    (i) => i.id == startItem.id,
    (i) => i.filePath,
    playableFromHistory,
    startIndex: startIndex,
  );

  Future<void> _playQueue<T>(
    List<T> items,
    bool Function(T item) isStart,
    String Function(T item) path,
    PlayableMedia Function(T item) toMedia, {
    int? startIndex,
  }) async {
    final playable = items
        .where((i) => path(i).trim().isNotEmpty && !isCueVirtualPath(path(i)))
        .toList();
    if (playable.isEmpty) return;
    var playableIndex =
        startIndex != null && startIndex >= 0 && startIndex < items.length
        ? (path(items[startIndex]).trim().isEmpty ||
                  isCueVirtualPath(path(items[startIndex])))
              ? 0
              : items
                    .take(startIndex)
                    .where(
                      (i) =>
                          path(i).trim().isNotEmpty &&
                          !isCueVirtualPath(path(i)),
                    )
                    .length
        : playable.indexWhere(isStart);
    if (playableIndex < 0 || playableIndex >= playable.length) {
      playableIndex = 0;
    }
    await playMediaQueue(
      playable.map(toMedia),
      startIndex: playableIndex,
      externalPath: path(playable[playableIndex]),
    );
  }

  /// Plays a prebuilt media queue starting at [startIndex]. Honors player mode
  /// ([externalPath] is opened externally when the built-in player is off).
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
    String? playlistId,
  }) async {
    final generation = ++_requestGeneration;
    if (await _useInternalPlayer(source: externalPath)) {
      if (generation != _requestGeneration) return;
      if (ref.read(settingsProvider).playerMode != 'internal') {
        ref.read(internalCatalogSessionProvider.notifier).setActive(true);
      }
      final items = queue.toList(growable: false);
      if (items.isEmpty) return;
      final i = startIndex.clamp(0, items.length - 1);
      final controller = ref.read(musicPlayerControllerProvider);
      if (playlistId == null) {
        await controller.playAll(
          items,
          initialIndex: i,
          isCurrentRequest: () => generation == _requestGeneration,
        );
      } else {
        final order = ref.read(libraryPlaylistOrderProvider.notifier);
        await controller.playAllFromPlaylist(
          items,
          initialIndex: i,
          isCurrentRequest: () => generation == _requestGeneration,
          onStarted: () async {
            try {
              await order.recordPlayback(playlistId);
            } catch (error) {
              _log.w('Could not save playlist playback order: $error');
            }
          },
        );
      }
    } else {
      if (!await _stopInternalBeforeExternal(generation)) return;
      final recovered = Platform.isAndroid
          ? await DownloadFileRecovery.instance.recover(
              externalPath,
              settings: ref.read(settingsProvider),
            )
          : null;
      if (generation == _requestGeneration)
        await openFile(recovered ?? externalPath);
    }
  }

  Future<void> playTrackList(
    List<Track> tracks, {
    int startIndex = 0,
    String? playlistId,
    bool exactStart = false,
    bool requireLocalStart = false,
    String? listContext,
    List<String>? listOccurrences,
  }) async {
    assert(listOccurrences == null || listOccurrences.length == tracks.length);
    if (tracks.isEmpty) return;
    final generation = ++_requestGeneration;

    final safeStart = startIndex.clamp(0, tracks.length - 1);
    final localRequired =
        requireLocalStart ||
        tracks[safeStart].source?.trim().toLowerCase() == 'local';
    List<String?>? resolvedPaths;
    String? networkSource;
    int? networkStart;
    var forceCatalogSession = false;
    if (ref.read(settingsProvider).playerMode != 'internal') {
      final selectedPath = (await resolveTrackFilePaths([
        tracks[safeStart],
      ])).single;
      if (generation != _requestGeneration) return;
      if (selectedPath == null) {
        if (localRequired) throw const LocalTrackUnavailableException();
        // A catalog-only selection must not silently skip to a later local song.
        forceCatalogSession = true;
      } else if (selectedPath.startsWith('network://')) {
        networkSource = selectedPath;
        networkStart = safeStart;
      } else if (isCueVirtualPath(selectedPath)) {
        throw Exception(cueVirtualTrackRequiresSplitMessage);
      } else {
        if (!await _stopInternalBeforeExternal(generation)) return;
        await openFile(selectedPath);
        return;
      }
    }
    resolvedPaths ??= await resolveTrackFilePaths(tracks);
    if (generation != _requestGeneration) return;
    if (localRequired && resolvedPaths[safeStart] == null) {
      throw const LocalTrackUnavailableException();
    }
    if ((exactStart || localRequired) &&
        isCueVirtualPath(resolvedPaths[safeStart] ?? '')) {
      throw Exception(cueVirtualTrackRequiresSplitMessage);
    }

    if (await _useInternalPlayer(
      source: networkSource ?? resolvedPaths[safeStart],
      force: forceCatalogSession,
    )) {
      if (generation != _requestGeneration) return;
      if (forceCatalogSession || networkSource != null) {
        ref.read(internalCatalogSessionProvider.notifier).setActive(true);
      }
      catalogPlayback.defaultService = ref
          .read(settingsProvider)
          .defaultService;
      catalogPlayback.quality = ref.read(settingsProvider).playbackQuality;
      catalogPlayback.useExtensions = ref
          .read(settingsProvider)
          .useExtensionProviders;
      catalogPlayback.useFallback = ref.read(settingsProvider).autoFallback;
      final queue = <PlayableMedia>[];
      int? initialIndex;
      var skippedCueVirtualTrack = false;
      PlayableMedia contextualize(PlayableMedia media, int index) =>
          PlayableMedia.fromJson({
            ...media.toJson(),
            if (listContext != null) 'listContext': listContext,
            if (listOccurrences != null)
              'listOccurrence': listOccurrences[index],
          })!;
      for (var index = 0; index < tracks.length; index++) {
        final track = tracks[index];
        final resolvedPath = resolvedPaths[index];
        if (resolvedPath == null) {
          if (track.source?.trim().toLowerCase() == 'local') continue;
          if (networkSource != null) continue;
          if (index >= safeStart) initialIndex ??= queue.length;
          queue.add(contextualize(playableFromCatalogTrack(track), index));
          continue;
        }
        if (isCueVirtualPath(resolvedPath)) {
          skippedCueVirtualTrack = true;
          continue;
        }
        // Keep the playlist's original order so Previous can reach earlier
        // tracks and reaching its end still respects the player's repeat mode.
        if (index >= (networkStart ?? safeStart)) initialIndex ??= queue.length;
        queue.add(contextualize(playableFromTrack(track, resolvedPath), index));
      }

      if (queue.isNotEmpty) {
        _log.d('Playing ${queue.length} tracks in the internal player');
        final controller = ref.read(musicPlayerControllerProvider);
        if (playlistId == null) {
          await controller.playAll(
            queue,
            initialIndex: initialIndex ?? 0,
            isCurrentRequest: () => generation == _requestGeneration,
          );
        } else {
          final order = ref.read(libraryPlaylistOrderProvider.notifier);
          await controller.playAllFromPlaylist(
            queue,
            initialIndex: initialIndex ?? 0,
            isCurrentRequest: () => generation == _requestGeneration,
            onStarted: () async {
              try {
                await order.recordPlayback(playlistId);
              } catch (error) {
                _log.w('Could not save playlist playback order: $error');
              }
            },
          );
        }
        return;
      }
      if (skippedCueVirtualTrack) {
        throw Exception(cueVirtualTrackRequiresSplitMessage);
      }
      throw Exception(
        'No local audio file is available to play. Download the track first.',
      );
    }

    if (forceCatalogSession || networkSource != null) {
      throw StateError('No se pudo iniciar el reproductor de MUSA.');
    }
    if (generation != _requestGeneration) return;
    var skippedCueVirtualTrack = false;
    for (var offset = 0; offset < tracks.length; offset++) {
      final index = (safeStart + offset) % tracks.length;
      final track = tracks[index];
      final resolvedPath = resolvedPaths[index];
      if (resolvedPath == null) {
        continue;
      }
      if (isCueVirtualPath(resolvedPath)) {
        skippedCueVirtualTrack = true;
        continue;
      }

      _log.d(
        'Opening first available external track for list playback: '
        '"${track.name}" by ${track.artistName} -> $resolvedPath',
      );
      if (!await _stopInternalBeforeExternal(generation)) return;
      await openFile(resolvedPath);
      return;
    }

    if (skippedCueVirtualTrack) {
      throw Exception(cueVirtualTrackRequiresSplitMessage);
    }

    throw Exception(
      'No local audio file is available to open. Download the track first.',
    );
  }

  /// Public wrapper so non-playback features (e.g. M3U export) reuse the
  /// same library+history file resolution.
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) =>
      _resolveTrackPaths(tracks);

  Future<List<String?>> _resolveTrackPaths(List<Track> tracks) async {
    if (tracks.isEmpty) return const [];
    final recovery = DownloadFileRecovery(history: _history);
    final (:paths, :missingHistoryIds) = await resolveTrackFiles(
      tracks,
      library: _library,
      history: _history,
      includeLocal: ref.read(settingsProvider).localLibraryEnabled,
      recoverDownload: (source, id) => recovery.recover(
        source,
        historyId: id,
        settings: ref.read(settingsProvider),
        knownMissing: true,
      ),
    );
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    await historyNotifier.removeManyFromHistory(missingHistoryIds);
    return paths;
  }
}

final playbackProvider = NotifierProvider<PlaybackController, PlaybackState>(
  PlaybackController.new,
);
