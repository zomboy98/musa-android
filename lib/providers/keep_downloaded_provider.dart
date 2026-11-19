import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/keep_downloaded.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:mornye/models/keep_downloaded.dart';

final _log = AppLogger('KeepDownloaded');

/// Alcances (biblioteca general y playlists) con "Mantener descarga activa".
/// Se guarda en preferencias: no cambia el esquema de colecciones.
class KeepDownloadedNotifier extends Notifier<Set<String>> {
  static const storageKey = 'keep_downloaded_scopes_v1';

  Future<void> _tail = Future.value();

  /// Termina cuando se leyo lo guardado: quien decide por el estado debe
  /// esperarlo, o vera todo apagado justo despues de abrir la app.
  Future<void> ready = Future.value();

  @override
  Set<String> build() {
    ready = _restore();
    return const <String>{};
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final stored = prefs.getStringList(storageKey) ?? const <String>[];
      // Lo activado durante la lectura inicial no se pierde.
      state = {...stored, ...state};
    } catch (error, stack) {
      _log.e('No se pudo leer el estado de descargas activas', error, stack);
    }
  }

  bool isActive(String scope) => state.contains(scope);

  /// Cambia el estado y lo persiste en orden; devuelve false si no se guardo.
  Future<bool> setActive(String scope, bool active) {
    if (state.contains(scope) == active) return Future.value(true);
    state = active ? {...state, scope} : ({...state}..remove(scope));
    final snapshot = state.toList()..sort();
    final write = _tail.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        return await prefs.setStringList(storageKey, snapshot);
      } catch (error, stack) {
        _log.e(
          'No se pudo guardar el estado de descargas activas',
          error,
          stack,
        );
        return false;
      }
    });
    _tail = write.then<void>((_) {});
    return write;
  }
}

final keepDownloadedProvider =
    NotifierProvider<KeepDownloadedNotifier, Set<String>>(
      KeepDownloadedNotifier.new,
    );

/// Si el interruptor de [scope] esta encendido.
final keepDownloadedActiveProvider = Provider.autoDispose.family<bool, String>(
  (ref, scope) =>
      ref.watch(keepDownloadedProvider.select((s) => s.contains(scope))),
);

/// Operaciones sobre descargas que usa el controlador; los tests las sustituyen.
abstract class KeepDownloadedBackend {
  /// Archivos descargados y accesibles de [track].
  Future<List<String>> downloadedPaths(Track track);

  /// Borra los archivos y limpia el historial; devuelve los realmente borrados.
  Future<List<String>> deletePaths(List<String> paths);

  /// Encola la descarga con el flujo normal (proveedor, relevo y calidad
  /// configurados). No hace nada si la cancion ya esta descargada o en cola.
  Future<void> enqueue(Track track, {DownloadOrigin? origin});
}

class _AppKeepDownloadedBackend implements KeepDownloadedBackend {
  _AppKeepDownloadedBackend(this.ref);

  final Ref ref;

  @override
  Future<List<String>> downloadedPaths(Track track) async {
    final candidates = await ref
        .read(downloadHistoryProvider.notifier)
        .findTrackCandidatesAsync(historyLookupForTrack(track));
    final paths = <String>[];
    for (final item in candidates) {
      if (item.filePath.isNotEmpty &&
          historyMatchesTrack(track, item) &&
          await savedDownloadFileAccessible(item.filePath)) {
        paths.add(item.filePath);
      }
    }
    return paths;
  }

  @override
  Future<List<String>> deletePaths(List<String> paths) async {
    final container = ref.container;
    final deleted = <String>[];
    for (final path in paths) {
      if (await deleteFile(path)) deleted.add(path);
    }
    await removeDeletedLibraryFileEntries(container, deleted);
    return deleted;
  }

  @override
  Future<void> enqueue(Track track, {DownloadOrigin? origin}) async {
    final settings = ref.read(settingsProvider);
    final service = resolveConfiguredDownloadService(
      settings.defaultService,
      ref.read(extensionProvider),
      autoFallback: settings.autoFallback,
    );
    if (service.isEmpty) return;
    await ref
        .read(downloadQueueProvider.notifier)
        .addSavedTrackToQueue(track, service, origin: origin);
  }
}

final keepDownloadedBackendProvider = Provider<KeepDownloadedBackend>(
  _AppKeepDownloadedBackend.new,
);

/// Canciones de [scope] ahora mismo (la general o una playlist).
Future<List<Track>> keepDownloadedScopeTracks(Ref ref, String scope) async {
  if (scope == keepLibraryScope) {
    try {
      await ref.read(savedLibraryTracksProvider.future);
    } catch (_) {
      // Se usa lo que haya cargado.
    }
    return [for (final song in ref.read(librarySongsProvider)) song.track];
  }
  final playlistId = keepScopePlaylistId(scope);
  if (playlistId == null) return const [];
  final notifier = ref.read(libraryCollectionsProvider.notifier);
  await notifier.ensurePlaylistLoaded(playlistId);
  final playlist = ref
      .read(libraryCollectionsProvider)
      .playlistById(playlistId);
  return [
    for (final entry in playlist?.tracks ?? const <CollectionTrackEntry>[])
      entry.track,
  ];
}

/// Activa, desactiva y mantiene las descargas por alcance.
class KeepDownloadedController {
  KeepDownloadedController(this._ref);

  final Ref _ref;

  int lastEnqueueFailures = 0;

  KeepDownloadedBackend get _backend =>
      _ref.read(keepDownloadedBackendProvider);

  bool isActive(String scope) =>
      _ref.read(keepDownloadedProvider).contains(scope);

  /// Enciende el alcance y encola lo que aun no esta descargado.
  /// Devuelve cuantas canciones se pidieron a la cola.
  Future<int> activate(String scope) async {
    await _ref.read(keepDownloadedProvider.notifier).ready;
    final saved = await _ref
        .read(keepDownloadedProvider.notifier)
        .setActive(scope, true);
    if (!saved) return -1;
    return _enqueueAll(await keepDownloadedScopeTracks(_ref, scope), scope);
  }

  Future<int> _enqueueAll(Iterable<Track> tracks, String scope) async {
    final origin = DownloadOrigin.playlistOf(keepScopePlaylistId(scope));
    var requested = 0;
    lastEnqueueFailures = 0;
    for (final track in tracks) {
      try {
        if ((await _backend.downloadedPaths(track)).isNotEmpty) continue;
        await _backend.enqueue(track, origin: origin);
        requested++;
      } catch (error, stack) {
        lastEnqueueFailures++;
        _log.e('No se pudo encolar ${track.id}', error, stack);
      }
    }
    return requested;
  }

  /// Llamar tras agregar [tracks] a [scope]: si el interruptor esta
  /// encendido, se encola su descarga. Nunca lanza.
  Future<void> onTracksAdded(String scope, Iterable<Track> tracks) async {
    try {
      await _ref.read(keepDownloadedProvider.notifier).ready;
      if (!isActive(scope)) return;
      await _enqueueAll(tracks, scope);
    } catch (error, stack) {
      _log.e('Descarga automatica de $scope fallo', error, stack);
    }
  }

  /// Calcula que se borraria al apagar [scope], sin tocar nada.
  Future<KeepDownloadedPreview> previewDeactivation(String scope) async {
    await _ref.read(keepDownloadedProvider.notifier).ready;
    final active = _ref.read(keepDownloadedProvider);
    final tracksByKey = <String, Track>{};
    final keysByScope = <String, Set<String>>{};
    for (final id in {scope, ...active}) {
      final tracks = await keepDownloadedScopeTracks(_ref, id);
      keysByScope[id] = {for (final track in tracks) trackCollectionKey(track)};
      for (final track in tracks) {
        tracksByKey.putIfAbsent(trackCollectionKey(track), () => track);
      }
    }
    final plan = planKeepDownloadedRemoval(
      scope: scope,
      activeScopes: active,
      keysByScope: keysByScope,
    );
    final paths = <String>[];
    var deletable = 0;
    for (final key in plan.toDelete) {
      final found = await _backend.downloadedPaths(tracksByKey[key]!);
      if (found.isEmpty) continue;
      deletable++;
      paths.addAll(found);
    }
    var shared = 0;
    for (final key in plan.shared) {
      if ((await _backend.downloadedPaths(tracksByKey[key]!)).isNotEmpty) {
        shared++;
      }
    }
    return KeepDownloadedPreview(
      scope: scope,
      deletableTracks: deletable,
      deletePaths: paths,
      sharedDownloadedCount: shared,
    );
  }

  /// Apaga el alcance y borra solo los archivos de [preview]. Devuelve
  /// cuantos archivos se borraron.
  Future<int> deactivate(KeepDownloadedPreview preview) async {
    final saved = await _ref
        .read(keepDownloadedProvider.notifier)
        .setActive(preview.scope, false);
    if (!saved) return -1;
    if (preview.deletePaths.isEmpty) return 0;
    return (await _backend.deletePaths(preview.deletePaths)).length;
  }
}

final keepDownloadedControllerProvider = Provider<KeepDownloadedController>(
  KeepDownloadedController.new,
);
