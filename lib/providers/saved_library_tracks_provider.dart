import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/library_home.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/keep_downloaded_provider.dart'
    show keepDownloadedControllerProvider, keepLibraryScope;
import 'package:mornye/services/catalog_playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

final promoteSavedCatalogAudioProvider = Provider<Future<bool> Function(Track)>(
  (ref) =>
      (track) => catalogPlayback.promote(
        track,
        saveIntention: ref
            .read(savedLibraryTracksProvider.notifier)
            .currentSaveIntention(track),
      ),
);
final pendingSavedCatalogPromotionProvider =
    Provider<Future<bool>? Function(Track)>(
      (ref) => catalogPlayback.pendingSavedPromotion,
    );
typedef RetentionLock = Future<T> Function<T>(Future<T> Function());

class SavedAudioPreparationException implements Exception {
  const SavedAudioPreparationException();
}

final savedCatalogRetentionLockProvider = Provider<RetentionLock>(
  (ref) => catalogPlayback.withRetentionLock,
);

/// Catalog references saved by the listener, independently of local files.
class SavedLibraryTracksNotifier extends AsyncNotifier<List<Track>> {
  static const storageKey = 'saved_library_tracks_v1';
  Future<void> _tail = Future.value();
  late Future<List<Track>> _initialLoad;
  final Map<String, Object> _membershipVersions = {};

  @override
  Future<List<Track>> build() => _initialLoad = _load();

  Future<List<Track>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null) return const [];
    final rows = jsonDecode(raw) as List<dynamic>;
    return List.unmodifiable(
      rows.map((row) => Track.fromJson(Map<String, dynamic>.from(row as Map))),
    );
  }

  /// Returns true when this newly committed reference is still current after
  /// retention preparation. A remove and re-add is a separate save intention.
  Future<bool> add(Track track) async {
    final result = await addWithRetention(track);
    if (result.retentionError case final error?) throw error;
    return result.added;
  }

  Future<({bool added, bool promoted, Object? retentionError})>
  addWithRetention(Track track) async {
    final result = await ref.read(savedCatalogRetentionLockProvider)(() async {
      final added = await _mutate((tracks) {
        if (tracks.any(
          (item) => trackCollectionKey(item) == trackCollectionKey(track),
        )) {
          return null;
        }
        return [track, ...tracks];
      });
      if (!added) {
        return (
          added: false,
          promoted: false,
          retentionError: null as Object?,
          pending: null as Future<bool>?,
          version: null as Object?,
        );
      }
      final version = _membershipVersions[trackCollectionKey(track)];
      try {
        final promoted = await ref.read(promoteSavedCatalogAudioProvider)(
          track,
        );
        final pending = promoted
            ? null
            : ref.read(pendingSavedCatalogPromotionProvider)(track);
        return (
          added: true,
          promoted: promoted,
          retentionError: null as Object?,
          pending: pending,
          version: version,
        );
      } catch (error) {
        return (
          added: true,
          promoted: false,
          retentionError: error,
          pending: null as Future<bool>?,
          version: version,
        );
      }
    });
    final promoted = result.pending == null
        ? result.promoted
        : await result.pending!;
    final current =
        result.added &&
        identical(
          result.version,
          _membershipVersions[trackCollectionKey(track)],
        );
    if (current) _keepDownloaded([track]);
    return (
      added: current,
      promoted: promoted,
      retentionError: !current
          ? null
          : result.retentionError ??
                (result.pending != null && !promoted
                    ? const SavedAudioPreparationException()
                    : null),
    );
  }

  /// Keeps references for [tracks] that are not saved yet, in one write and
  /// without preparing audio. Saved tracks are left untouched, so repeating
  /// the call changes nothing. Returns how many references were added.
  Future<int> ensureSaved(Iterable<Track> tracks) async {
    final candidates = tracks.toList(growable: false);
    if (candidates.isEmpty) return 0;
    var added = 0;
    await _mutate((current) {
      final missing = favoritesMissingFromSaved(
        saved: current,
        favorites: candidates,
      );
      if (missing.isEmpty) return null;
      added = missing.length;
      return [...missing, ...current];
    });
    if (added > 0) _keepDownloaded(candidates);
    return added;
  }

  /// Si la biblioteca mantiene sus descargas, encola las canciones nuevas.
  void _keepDownloaded(List<Track> tracks) {
    if (!ref.mounted) return;
    unawaited(
      ref
          .read(keepDownloadedControllerProvider)
          .onTracksAdded(keepLibraryScope, tracks),
    );
  }

  Future<bool> remove(Track track) => _mutate((tracks) {
    final next = tracks
        .where((item) => trackCollectionKey(item) != trackCollectionKey(track))
        .toList();
    return next.length == tracks.length ? null : next;
  });

  /// Captures this membership, so a later remove and re-add cannot revive it.
  bool Function() currentSaveIntention(Track track) {
    final key = trackCollectionKey(track);
    final version = _membershipVersions[key];
    return () =>
        version != null && identical(version, _membershipVersions[key]);
  }

  /// Replace references from a validated backup, preserving their order.
  Future<void> restoreFromBackup(List<Track> tracks) async {
    final snapshot = List<Track>.of(tracks);
    await ref.read(savedCatalogRetentionLockProvider)(
      () => _mutate((_) => snapshot, replaceExisting: true),
    );
  }

  Future<bool> _mutate(
    List<Track>? Function(List<Track>) change, {
    bool replaceExisting = false,
  }) {
    final operation = _tail.then((_) async {
      List<Track> tracks;
      if (replaceExisting) {
        // Let the initial read settle before publishing the replacement. Use
        // the read itself so corrupt data cannot trap restore in provider retries.
        try {
          await _initialLoad;
        } catch (_) {
          // A validated backup explicitly replaces unreadable stored data.
        }
        tracks = const [];
      } else {
        if (state.hasError) {
          Error.throwWithStackTrace(state.error!, state.stackTrace!);
        }
        tracks = await future;
      }
      final next = change(tracks);
      if (next == null) return false;
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setString(
        storageKey,
        jsonEncode(next.map((track) => track.toJson()).toList()),
      );
      if (!saved) throw StateError('Could not save library references');
      if (replaceExisting) _membershipVersions.clear();
      final before = tracks.map(trackCollectionKey).toSet();
      final after = next.map(trackCollectionKey).toSet();
      for (final key in before.difference(after)) {
        _membershipVersions.remove(key);
      }
      for (final key in after.difference(before)) {
        _membershipVersions[key] = Object();
      }
      state = AsyncData(List.unmodifiable(next));
      return true;
    });
    _tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    return operation;
  }
}

final savedLibraryTracksProvider =
    AsyncNotifierProvider<SavedLibraryTracksNotifier, List<Track>>(
      SavedLibraryTracksNotifier.new,
    );

final savedLibraryTrackKeysProvider = Provider<Set<String>>((ref) {
  final tracks = ref.watch(savedLibraryTracksProvider).value;
  if (tracks == null) return const <String>{};
  return {for (final track in tracks) trackCollectionKey(track)};
});

final savedLibraryTracksUnavailableProvider = Provider<bool>((ref) {
  final saved = ref.watch(savedLibraryTracksProvider);
  return saved.isLoading || saved.hasError;
});

/// Keeps favorites inside the library: a starred song is also a "+" song, and
/// removing the star leaves it there.
final favoriteLibrarySyncProvider =
    Provider<Future<void> Function(List<Track>)>(
      (ref) => (tracks) async {
        await ref.read(savedLibraryTracksProvider.notifier).ensureSaved(tracks);
      },
    );
