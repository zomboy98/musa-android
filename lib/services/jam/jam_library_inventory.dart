import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:path/path.dart' as p;

import 'jam_app_controller.dart';
import 'jam_playback.dart';
import 'jam_playback_runtime.dart';
import 'jam_track_reference.dart';
import 'jam_track_resolver.dart';
import 'jam_queue.dart';
import 'jam_host_queue_editor.dart';

/// Reads existing host inventory; legacy history IDs have mixed provenance.
class JamLibraryInventory
    implements
        JamTrackResolver<PlayableMedia>,
        JamBatchTrackResolver<PlayableMedia> {
  JamLibraryInventory({
    required this.includeLocalLibrary,
    LibraryDatabase? library,
    HistoryDatabase? history,
    Future<bool> Function(String)? fileExists,
    Future<bool> Function(String)? safCanOpenRead,
    this.hostTracks = const {},
    this.resolveHostTrack,
    this.hostRegistry,
    this.resolveRegisteredTrack,
  }) : _library = library ?? LibraryDatabase.instance,
       _history = history ?? HistoryDatabase.instance,
       _fileExists = fileExists ?? _exists,
       _safCanOpenRead = safCanOpenRead ?? PlatformBridge.safCanOpenRead;

  final bool Function() includeLocalLibrary;

  /// Ephemeral session tokens, never serialized media sources.
  final Map<String, PlayableMedia> hostTracks;
  final JamHostTrackRegistry<PlayableMedia>? hostRegistry;
  final PlayableMedia? Function(String, PlayableMedia)? resolveRegisteredTrack;
  final PlayableMedia? Function(String)? resolveHostTrack;
  final LibraryDatabase _library;
  final HistoryDatabase _history;
  final Future<bool> Function(String) _fileExists;
  final Future<bool> Function(String) _safCanOpenRead;

  static Future<bool> _exists(String path) async {
    try {
      final handle = await File(path).open(mode: FileMode.read);
      await handle.close();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static bool _localPath(String value) {
    final path = value.trim();
    return path.isNotEmpty &&
        (isContentUri(path) || p.isAbsolute(path)) &&
        !path.startsWith(r'\\') &&
        !path.startsWith('//') &&
        !isCueVirtualPath(path) &&
        Uri.tryParse(path)?.scheme != 'network';
  }

  Future<bool> canReadHostMedia(PlayableMedia media) async {
    if (!_localPath(media.source)) return false;
    try {
      return isContentUri(media.source)
          ? await _safCanOpenRead(media.source)
          : await _fileExists(media.source);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PlayableMedia?> resolveLocal(String trackId) async =>
      (await resolveLocalBatch([trackId])).single;

  @override
  Future<List<PlayableMedia?>> resolveLocalBatch(List<String> trackIds) async {
    if (trackIds.isEmpty) return [];
    final candidates =
        trackIds.every(
          (id) =>
              hostTracks.containsKey(id) ||
              (hostRegistry?.contains(id) ?? false),
        )
        ? <JamLocalCandidate<PlayableMedia>>[]
        : await _candidates();
    final byIsrc = <String, List<JamLocalCandidate<PlayableMedia>>>{};
    for (final candidate in candidates) {
      final isrc = candidate.reference.isrc;
      if (isrc != null) (byIsrc[isrc] ??= []).add(candidate);
    }
    final result = <PlayableMedia?>[];
    // Cache per batch, without retaining access decisions across inventory reads.
    final readableByIsrc =
        <String, Future<List<JamLocalCandidate<PlayableMedia>>>>{};
    Future<List<JamLocalCandidate<PlayableMedia>>> readableCandidates(
      String isrc,
    ) => readableByIsrc.putIfAbsent(isrc, () async {
      final unique = <String, JamLocalCandidate<PlayableMedia>>{};
      for (final candidate
          in byIsrc[isrc] ?? <JamLocalCandidate<PlayableMedia>>[]) {
        final source = candidate.value.source;
        if (!_localPath(source)) continue;
        // A lexical normalization can change meaning around symlinks, and
        // even Windows directories can be case-sensitive. SAF identifiers
        // are opaque too, so only identical sources are safe to merge.
        unique.putIfAbsent(source, () => candidate);
      }
      final readable = <JamLocalCandidate<PlayableMedia>>[];
      for (final candidate in unique.values) {
        if (await canReadHostMedia(candidate.value)) readable.add(candidate);
      }
      return readable;
    });
    for (final trackId in trackIds) {
      if (hostRegistry?.contains(trackId) ?? false) {
        final registered = hostRegistry!.resolve(trackId);
        final media = registered == null
            ? null
            : resolveRegisteredTrack?.call(trackId, registered) ?? registered;
        result.add(
          media != null && await canReadHostMedia(media) ? media : null,
        );
        continue;
      }
      if (hostTracks.containsKey(trackId)) {
        final imported = resolveHostTrack == null
            ? hostTracks[trackId]
            : resolveHostTrack!(trackId);
        result.add(
          imported != null && await canReadHostMedia(imported)
              ? imported
              : null,
        );
        continue;
      }
      final isrc = JamTrackReference.tryDecode(trackId)?.isrc;
      final resolver = JamLibraryTrackResolver<PlayableMedia>(
        () async => isrc == null ? [] : readableCandidates(isrc),
      );
      final media = await resolver.resolveLocal(trackId);
      result.add(media == null ? null : _withoutRemoteArtwork(media));
    }
    return result;
  }

  static PlayableMedia _withoutRemoteArtwork(PlayableMedia media) =>
      PlayableMedia(
        id: media.id,
        source: media.source,
        title: media.title,
        artist: media.artist,
        album: media.album,
        duration: media.duration,
        bitDepth: media.bitDepth,
        sampleRate: media.sampleRate,
        bitrate: media.bitrate,
        format: media.format,
        explicit: media.explicit,
        genre: media.genre,
      );

  Future<List<JamLocalCandidate<PlayableMedia>>> _candidates() async {
    final result = <JamLocalCandidate<PlayableMedia>>[];
    void add(String? isrc, String title, String artist, PlayableMedia media) {
      final reference = JamTrackReference.create(
        isrc: isrc,
        title: title,
        artist: artist,
      );
      if (reference != null) {
        result.add(JamLocalCandidate(reference: reference, value: media));
      }
    }

    for (final row in await _history.getAll()) {
      final item = DownloadHistoryItem.fromJson(row);
      add(
        item.isrc,
        item.trackName,
        item.artistName,
        playableFromHistory(item),
      );
    }
    if (includeLocalLibrary()) {
      final paths = await _library.getFilePathRows();
      final rows = await _library.getByIds(paths.map((row) => row.id).toList());
      for (final row in rows) {
        final item = LocalLibraryItem.fromJson(row);
        add(
          item.isrc,
          item.trackName,
          item.artistName,
          playableFromLocal(item),
        );
      }
    }
    return result;
  }
}

/// Explicit host-only opt-in. The local player must already be initialized.
void attachJamLibraryPlayback({
  required JamAppController controller,
  required MusicPlayerRuntime runtime,
  required bool Function() includeLocalLibrary,
}) {
  controller.attachHostPlayback<PlayableMedia>(
    resolver: JamLibraryInventory(includeLocalLibrary: includeLocalLibrary),
    port: RuntimeJamPlaybackPort(runtime),
  );
}

/// Imports the complete local queue without starting, seeking or loading audio.
/// Unsupported sources reject startup; they are never silently omitted.
Future<void> initializeJamLibraryPlayback({
  required JamAppController controller,
  required MusicPlayerRuntime runtime,
  required bool Function() includeLocalLibrary,
  JamHostTrackRegistry<PlayableMedia>? hostRegistry,
  Future<bool> Function(String)? fileExists,
  Future<bool> Function(String)? safCanOpenRead,
}) async {
  final generation = controller.sessionGeneration;
  final registry = hostRegistry ?? JamHostTrackRegistry<PlayableMedia>();
  final handler = runtime.handler;
  if (handler == null) throw StateError('Local player is not initialized');
  final snapshot = handler.captureJamQueue();
  if (snapshot.entries.length > JamQueue.maxEntries) {
    throw StateError('Local queue exceeds Jam capacity');
  }
  final random = Random.secure();
  String token() => base64Url
      .encode(List.generate(24, (_) => random.nextInt(256)))
      .replaceAll('=', '');
  final tracks = <String, PlayableMedia>{};
  final entries = <JamEntry>[];
  for (final media in snapshot.entries) {
    final id = 'jamhost1:${token()}';
    tracks[id] = media;
    entries.add(JamEntry(occurrenceId: token(), trackId: id));
  }
  controller.seedHostQueue(entries);
  final occurrences = {
    for (final entry in entries) entry.trackId: entry.occurrenceId,
  };
  final inventory = JamLibraryInventory(
    includeLocalLibrary: includeLocalLibrary,
    hostTracks: Map.unmodifiable(tracks),
    hostRegistry: registry,
    resolveRegisteredTrack: (id, original) {
      final entries = controller.snapshot?.entries ?? const <JamEntry>[];
      for (final entry in entries) {
        if (entry.trackId == id) {
          return handler.jamMediaForOccurrence(entry.occurrenceId) ?? original;
        }
      }
      return original;
    },
    fileExists: fileExists,
    safCanOpenRead: safCanOpenRead,
    resolveHostTrack: (id) =>
        handler.jamMediaForOccurrence(occurrences[id]!) ?? tracks[id],
  );
  final binding = controller.attachHostPlayback<PlayableMedia>(
    resolver: inventory,
    port: RuntimeJamPlaybackPort(
      runtime,
      initialQueueRevision: snapshot.revision,
      initialCurrentIndex: snapshot.currentIndex,
      initialCurrentOccurrenceId:
          snapshot.currentIndex >= 0 && snapshot.currentIndex < entries.length
          ? entries[snapshot.currentIndex].occurrenceId
          : null,
    ),
  );
  await binding.settled;
  if (controller.playbackState != JamPlaybackState.synchronized) {
    throw StateError('Cannot preserve the complete local queue for Jam');
  }
  if (controller.sessionGeneration != generation ||
      controller.phase != JamAppPhase.starting ||
      !identical(runtime.handler, handler)) {
    throw StateError('Host session changed during initialization');
  }
  JamHostQueueEditor<PlayableMedia>? editor;
  controller.installHostMediaEditor((media) async {
    if (controller.sessionGeneration != generation ||
        !identical(runtime.handler, handler)) {
      throw StateError('Host session or player changed');
    }
    if (!await inventory.canReadHostMedia(media)) {
      throw StateError('Local Jam source unavailable');
    }
    if (controller.sessionGeneration != generation ||
        controller.phase != JamAppPhase.hosting ||
        !identical(runtime.handler, handler)) {
      throw StateError('Host session or player changed');
    }
    editor ??= JamHostQueueEditor(controller: controller, registry: registry);
    return editor!.edit((draft) => draft.entries.add(draft.create(media)));
  });
  final current =
      snapshot.currentIndex >= 0 && snapshot.currentIndex < entries.length
      ? entries[snapshot.currentIndex].occurrenceId
      : null;
  controller.setHostCurrentOccurrence(current);
  handler.configureJamPlaybackOccurrences(
    current,
    controller.setHostPlaybackOccurrences,
  );
}
