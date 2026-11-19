import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'catalog_file_publication.dart';
import 'catalog_audio_stage.dart';

class _CatalogStoreState {
  final pins = <String, int>{};
  final versions = <String, int>{};
  final retired = <String>{};
  final unrecordedPlayback = <String>{};
  Map<String, List<File>>? manifestIndex;
  DateTime? manifestDirectoryModified;
}

class _PromotionWork {
  _PromotionWork(
    this.key,
    this.sourceId,
    this.source,
    this.created,
    this.stage,
    this.destination,
    this.originalTarget,
    this.lease,
    this.targetVersion,
    this.sourceVersion,
  );
  final String key;
  final String sourceId;
  final CatalogAudioEntry source;
  final DateTime created;
  final CatalogAudioStage stage;
  final String destination;
  final String? originalTarget;
  final CatalogAudioLease? lease;
  final int targetVersion;
  final int sourceVersion;
}

class CatalogAudioEntry {
  const CatalogAudioEntry(
    this.path,
    this.persistent,
    this.lastPlayed, {
    this.qualityMetadata = const {},
    this.variantId,
  });
  final String? variantId;
  final Map<String, Object> qualityMetadata;
  final String path;
  final bool persistent;
  final DateTime? lastPlayed;
}

class CatalogAudioLease {
  CatalogAudioLease._(
    this.path,
    this.id,
    this._release,
    this._snapshot,
    this._created,
  );
  final String path;
  final String id;
  final Future<void> Function() _release;
  final CatalogAudioEntry _snapshot;
  final DateTime _created;
  bool _released = false;
  bool get released => _released;
  bool get isTemporary => !_snapshot.persistent;
  Object? get provider => _snapshot.qualityMetadata['provider'];
  Map<String, Object> get qualityMetadata => _snapshot.qualityMetadata;
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

/// Single-isolate, single-process store, as enforced by the production app's
/// singleton playback service and platform single-instance runners. Multiple
/// objects in that isolate share leases. This is not a multiprocess database.
/// The caller must hold a lease while a deck uses a file.
/// A successful playback event must explicitly call [recordPlayback].
class CatalogAudioStore {
  CatalogAudioStore({
    required Directory cacheDirectory,
    required Directory libraryDirectory,
    DateTime Function()? clock,
    Future<File> Function(File, String)? copyFile,
    Future<void> Function(File, String)? writeManifest,
    Future<void> Function(File, DateTime)? touchFile,
    Future<void> Function(String key, String keep)? pruneManifests,
    void Function()? afterAudioPublication,
  }) : _cacheDirectory = cacheDirectory,
       _libraryDirectory = libraryDirectory,
       _clock = clock ?? DateTime.now,
       _copyFile = copyFile ?? _defaultCopy,
       _writeManifest = writeManifest ?? _defaultWriteManifest,
       _touchFile = touchFile ?? _defaultTouch,
       _pruneOverride = pruneManifests,
       _afterAudioPublication = afterAudioPublication;
  static Future<void> _defaultTouch(File file, DateTime time) =>
      file.setLastModified(time);
  static Future<File> _defaultCopy(File source, String destination) async {
    final file = File(destination);
    // File.copy can replace the destination inode on Windows. Keep the staged
    // inode (and its ownership anchor) by writing through its existing handle.
    final output = file.openWrite();
    try {
      await output.addStream(source.openRead());
      await output.flush();
    } finally {
      await output.close();
    }
    return file;
  }

  static Future<void> _defaultWriteManifest(File file, String content) async {
    await file.writeAsString(content, flush: true);
  }

  Directory _cacheDirectory;
  Directory _libraryDirectory;
  Directory get cacheDirectory => _cacheDirectory;
  Directory get libraryDirectory => _libraryDirectory;
  final DateTime Function() _clock;
  final Future<File> Function(File, String) _copyFile;
  final Future<void> Function(File, String) _writeManifest;
  final Future<void> Function(File, DateTime) _touchFile;
  final Future<void> Function(String, String)? _pruneOverride;
  final void Function()? _afterAudioPublication;
  static final _states = <String, WeakReference<_CatalogStoreState>>{};
  _CatalogStoreState _state = _CatalogStoreState();
  Map<String, int> get _pins => _state.pins;
  Set<String> get _retired => _state.retired;
  Set<String> get _unrecordedPlayback => _state.unrecordedPlayback;
  // All instances in this isolate share serialization for the same roots.
  static Future<void> _tail = Future.value();
  static int _revision = 0;
  final _publications = StreamController<String>.broadcast(sync: true);
  Stream<String> get publications => _publications.stream;
  String publicationKey(String id) => _key(id);
  Map<String, List<File>>? get _manifestIndex => _state.manifestIndex;
  set _manifestIndex(Map<String, List<File>>? value) =>
      _state.manifestIndex = value;
  DateTime? get _manifestDirectoryModified => _state.manifestDirectoryModified;
  set _manifestDirectoryModified(DateTime? value) =>
      _state.manifestDirectoryModified = value;
  static const ttl = Duration(days: 7);

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  String _key(String id) {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    return sha256.convert(utf8.encode(id)).toString();
  }

  Future<void> initialize() => _locked(() async {
    final cache = p.normalize(p.absolute(cacheDirectory.path));
    final library = p.normalize(p.absolute(libraryDirectory.path));
    if (cache == library ||
        p.isWithin(cache, library) ||
        p.isWithin(library, cache)) {
      throw ArgumentError('Cache and library directories must be separate');
    }
    await cacheDirectory.create(recursive: true);
    await libraryDirectory.create(recursive: true);
    if (await FileSystemEntity.type(cache, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(library, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw StateError('Store roots must be directories, not links');
    }
    // Canonical paths keep lease paths identical across relative/case aliases.
    _cacheDirectory = Directory(await cacheDirectory.resolveSymbolicLinks());
    _libraryDirectory = Directory(
      await libraryDirectory.resolveSymbolicLinks(),
    );
    var cacheRoot = p.normalize(cacheDirectory.path);
    var libraryRoot = p.normalize(libraryDirectory.path);
    if (Platform.isWindows) {
      cacheRoot = cacheRoot.toLowerCase();
      libraryRoot = libraryRoot.toLowerCase();
      _cacheDirectory = Directory(cacheRoot);
      _libraryDirectory = Directory(libraryRoot);
    }
    if (cacheRoot == libraryRoot ||
        p.isWithin(cacheRoot, libraryRoot) ||
        p.isWithin(libraryRoot, cacheRoot)) {
      throw ArgumentError('Canonical cache and library roots must be separate');
    }
    final roots = jsonEncode([cacheRoot, libraryRoot]);
    _states.removeWhere((_, reference) => reference.target == null);
    _state = _states[roots]?.target ?? _CatalogStoreState();
    _states[roots] = WeakReference(_state);
    // Recover the largest published or interrupted revision before allocating
    // another one, even when the wall clock moved backwards across restarts.
    for (final directory in [cacheDirectory, libraryDirectory]) {
      await for (final entity in directory.list(followLinks: false)) {
        final match = RegExp(
          r'^[0-9a-f]{64}\.([0-9]{20})\.(?:json|tmp|' +
              catalogAudioExtensionPattern +
              r'(?:\.part)?)$',
        ).firstMatch(p.basename(entity.path));
        if (match != null) {
          final revision = int.parse(match.group(1)!);
          if (revision > _revision) _revision = revision;
        }
      }
    }
    await _recover();
  });

  String _revisionName() {
    final current = _clock().toUtc().microsecondsSinceEpoch;
    _revision = current > _revision ? current : _revision + 1;
    return _revision.toString().padLeft(20, '0');
  }

  Future<({CatalogAudioEntry entry, DateTime created})?> _read(
    String key, {
    List<File>? indexed,
  }) async {
    final modified = indexed == null
        ? (await libraryDirectory.stat()).modified
        : null;
    if (indexed == null &&
        (_manifestIndex == null || modified != _manifestDirectoryModified)) {
      final index = <String, List<File>>{};
      await for (final entity in libraryDirectory.list(followLinks: false)) {
        if (entity is File) {
          final match = RegExp(
            r'^([0-9a-f]{64})\.[0-9]{20}\.json$',
          ).firstMatch(p.basename(entity.path));
          if (match != null) (index[match.group(1)!] ??= []).add(entity);
        }
      }
      _manifestIndex = index;
      _manifestDirectoryModified = modified;
    }
    final manifests = List<File>.of(
      indexed ?? _manifestIndex?[key] ?? const [],
    );
    manifests.sort((a, b) => b.path.compareTo(a.path));
    for (final manifest in manifests) {
      try {
        final data =
            jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        final filename = data['file'] as String;
        final persistent = data['persistent'] as bool;
        if (!RegExp(
          '^$key\\.[0-9]+\\.' + catalogAudioExtensionPattern + r'$',
        ).hasMatch(filename)) {
          continue;
        }
        final path = p.join(
          persistent ? libraryDirectory.path : cacheDirectory.path,
          filename,
        );
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
          return null;
        }
        final created = DateTime.parse(data['created'] as String).toUtc();
        final last = data['lastPlayed'] == null
            ? null
            : DateTime.parse(data['lastPlayed'] as String).toUtc();
        return (
          entry: CatalogAudioEntry(
            path,
            persistent,
            last,
            qualityMetadata: _qualityMetadata(data['qualityMetadata']),
            variantId:
                data['variantId'] is String &&
                    _key(data['variantId'] as String) == key
                ? data['variantId'] as String
                : null,
          ),
          created: created,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<bool> _write(
    String key,
    CatalogAudioEntry entry,
    DateTime created, {
    Future<bool> Function()? canPublish,
    bool Function()? stillValid,
  }) async {
    final name = '$key.${_revisionName()}';
    final stage = await CatalogAudioStage.create(
      libraryDirectory,
      'manifest.tmp',
      manifests: libraryDirectory,
    );
    final temp = stage.file;
    try {
      await _writeManifest(
        temp,
        jsonEncode({
          'file': p.basename(entry.path),
          'persistent': entry.persistent,
          'created': created.toUtc().toIso8601String(),
          'lastPlayed': entry.lastPlayed?.toUtc().toIso8601String(),
          if (entry.variantId != null) 'variantId': entry.variantId,
          if (entry.qualityMetadata.isNotEmpty)
            'qualityMetadata': _qualityMetadata(entry.qualityMetadata),
        }),
      );
      if (canPublish != null && !await canPublish()) return false;
      await stage.verifyIdentity();
      if (stillValid != null && !stillValid()) return false;
      publishCatalogFileNew(
        temp.path,
        p.join(libraryDirectory.path, '$name.json'),
      );
      _manifestIndex = null;
      _state.versions[key] = (_state.versions[key] ?? 0) + 1;
      // Manifest installation is the commit point.
      // Maintenance failure must never turn a
      // successful commit into an error that makes a caller remove its audio.
      _manifestIndex = null;
      try {
        if (_pruneOverride != null) {
          await _pruneOverride(key, '$name.json');
        } else {
          await _pruneManifests(key, '$name.json');
        }
      } catch (_) {
        // An older manifest is harmless; retry on subsequent publication.
      }
      if (entry.persistent) _publications.add(key);
      return true;
    } finally {
      await stage.remove();
    }
  }

  Future<void> _pruneManifests(String key, String keep) async {
    await for (final entity in libraryDirectory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name != keep &&
          RegExp('^$key\\.[0-9]{20}\\.json\$').hasMatch(name)) {
        try {
          await entity.delete();
        } on FileSystemException {
          /* Retry on recovery. */
        }
      }
    }
  }

  /// Only files bearing this store's exact generated names are candidates.
  /// Committed persistent audio and unjournaled legacy orphans are preserved.
  /// A journal may prove ownership of an interrupted, uncommitted publication.
  Future<void> _recover() async {
    await CatalogAudioStage.recoverRoot(cacheDirectory, libraryDirectory);
    await CatalogAudioStage.recoverRoot(libraryDirectory, libraryDirectory);
    final manifests = <String, List<File>>{};
    await for (final entity in libraryDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final match = RegExp(
        r'^([0-9a-f]{64})\.[0-9]{20}\.json$',
      ).firstMatch(name);
      if (match != null) (manifests[match.group(1)!] ??= []).add(entity);
      if (RegExp(
        r'^[0-9a-f]{64}\.[0-9]{20}\.(?:tmp|' +
            catalogAudioExtensionPattern +
            r'\.part)$',
      ).hasMatch(name)) {
        try {
          await entity.delete();
        } on FileSystemException {
          /* Retry later. */
        }
      }
    }
    // Cache orphans are collected only by explicit cleanup, which knows the
    // protected IDs and applies the same age policy as normal entries.
  }

  Future<void> _discard(String path) async {
    if ((_pins[path] ?? 0) > 0) {
      _retired.add(path);
      return;
    }
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.file) {
      try {
        await file.delete();
      } on FileSystemException {
        // Collection is maintenance, never a failed publication.
      }
    }
  }

  Future<CatalogAudioEntry?> lookup(String id) =>
      _locked(() async => (await _read(_key(id)))?.entry);

  /// Finds the most recently played candidate, falling back to creation time.
  Future<String?> latestAvailableId(
    Iterable<String> ids, {
    bool permanentOnly = false,
  }) => _locked(() async {
    String? best;
    DateTime? bestTime;
    for (final id in ids) {
      final item = await _read(_key(id));
      if (item == null) continue;
      if (permanentOnly &&
          !catalogAudioCanBeSaved(item.entry.qualityMetadata, id))
        continue;
      final when = item.entry.lastPlayed ?? item.created;
      if (bestTime == null || when.isAfter(bestTime)) {
        best = id;
        bestTime = when;
      }
    }
    return best;
  });

  /// Recover v2 and v3 variant identities after a restart, including provider-defined
  /// quality IDs. Each identity is verified against its manifest filename.
  Future<Map<String, List<String>>> variantsForTracks(Set<String> trackIds) =>
      _locked(() async {
        final manifests = <String, List<File>>{};
        await for (final entity in libraryDirectory.list(followLinks: false)) {
          if (entity is! File) continue;
          final match = RegExp(
            r'^([0-9a-f]{64})\.[0-9]{20}\.json$',
          ).firstMatch(p.basename(entity.path));
          if (match != null) (manifests[match.group(1)!] ??= []).add(entity);
        }
        final result = <String, List<String>>{};
        for (final entry in manifests.entries) {
          final id = (await _read(
            entry.key,
            indexed: entry.value,
          ))?.entry.variantId;
          if (id == null) continue;
          try {
            final parts = jsonDecode(id);
            if (parts is List &&
                ((parts.length == 4 && parts[0] == 'catalog-aac-v2') ||
                    (parts.length == 5 &&
                        parts[0] == 'catalog-aac-v3' &&
                        parts[4] is String) ||
                    (parts.length == 6 &&
                        (parts[0] == 'catalog-aac-v4' ||
                            parts[0] == 'catalog-audio-v5') &&
                        parts[4] is String &&
                        parts[5] is bool)) &&
                parts[1] is String &&
                trackIds.contains(parts[1]) &&
                parts[2] is int &&
                parts[3] is String)
              (result[parts[1] as String] ??= []).add(id);
          } catch (_) {
            /* Ignore invalid metadata. */
          }
        }
        return result;
      });

  Future<List<String>> variantsForTrack(String trackId) async =>
      (await variantsForTracks({trackId}))[trackId] ?? [];

  Future<CatalogAudioEntry> putTemporary(
    String id,
    File sourceFile, {
    String extension = '.opus',
    Map<String, Object> qualityMetadata = const {},
  }) => _locked(() async {
    if (RegExp(
          r'^\.' + catalogAudioExtensionPattern + r'$',
        ).firstMatch(extension)?.group(0) !=
        extension) {
      throw ArgumentError.value(extension, 'extension');
    }
    final key = _key(id);
    final old = await _read(key);
    if (old?.entry.persistent == true) return old!.entry;
    if (await FileSystemEntity.type(sourceFile.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await sourceFile.length() == 0) {
      throw ArgumentError('Source must be a non-empty regular file');
    }
    final base = '$key.${_revisionName()}$extension';
    final dest = p.join(cacheDirectory.path, base);
    final stage = await CatalogAudioStage.create(
      cacheDirectory,
      'audio.part',
      manifests: libraryDirectory,
      destination: dest,
    );
    final temp = stage.file;
    try {
      await _copyFile(sourceFile, temp.path);
      await stage.verifyIdentity();
      await temp.setLastModified(_clock().toUtc());
      publishCatalogFileNew(temp.path, dest);
      _afterAudioPublication?.call();
      final entry = CatalogAudioEntry(
        dest,
        false,
        null,
        qualityMetadata: _qualityMetadata(qualityMetadata),
        variantId:
            id.startsWith('["catalog-aac-v2",') ||
                id.startsWith('["catalog-aac-v3",') ||
                id.startsWith('["catalog-aac-v4",') ||
                id.startsWith('["catalog-audio-v5",')
            ? id
            : null,
      );
      await _write(key, entry, _clock().toUtc());
      if (old != null) await _discard(old.entry.path);
      return entry;
    } finally {
      await stage.remove();
    }
  });

  Future<CatalogAudioEntry?> promote(
    String id, {
    Future<bool> Function()? canPublish,
  }) => _promoteTwoPhase(id, id, canPublish: canPublish);

  /// Saves the exact file held by the active playback lease.
  Future<CatalogAudioEntry?> promoteLease(
    String id,
    CatalogAudioLease lease, {
    Future<bool> Function()? canPublish,
  }) => _promoteTwoPhase(id, lease.id, lease: lease, canPublish: canPublish);

  /// Publish the selected variant under the stable track identity.
  Future<CatalogAudioEntry?> promoteVariant(
    String id,
    String variantId, {
    Future<bool> Function()? canPublish,
  }) => _promoteTwoPhase(id, variantId, canPublish: canPublish);

  // The store is single-isolate/single-process. External writers and other
  // isolates/processes are outside its contract; a pin protects against store
  // cleanup, not modification by such writers.
  Future<CatalogAudioEntry?> _promoteTwoPhase(
    String id,
    String sourceId, {
    CatalogAudioLease? lease,
    Future<bool> Function()? canPublish,
  }) async {
    CatalogAudioEntry? existingPermanent;
    final work = await _locked(() async {
      final key = _key(id);
      final target = await _read(key);
      if (target?.entry.persistent == true) {
        existingPermanent = target!.entry;
        return null;
      }
      if (lease != null && (lease.released || (_pins[lease.path] ?? 0) <= 0))
        return null;
      final sourceRecord = await _read(_key(sourceId));
      final same = lease == null || sourceRecord?.entry.path == lease.path;
      final source = same ? sourceRecord?.entry : lease._snapshot;
      if (source == null ||
          !catalogAudioCanBeSaved(source.qualityMetadata, sourceId))
        return null;
      final created = same ? sourceRecord!.created : lease._created;
      final destination = p.join(
        libraryDirectory.path,
        '$key.${_revisionName()}${p.extension(source.path)}',
      );
      final stage = await CatalogAudioStage.create(
        libraryDirectory,
        'audio.part',
        manifests: libraryDirectory,
        destination: destination,
      );
      _pins[source.path] = (_pins[source.path] ?? 0) + 1;
      return _PromotionWork(
        key,
        sourceId,
        source,
        created,
        stage,
        destination,
        target?.entry.path,
        lease,
        _state.versions[key] ?? 0,
        _state.versions[_key(sourceId)] ?? 0,
      );
    });
    if (work == null) return existingPermanent;
    try {
      final file = File(work.source.path);
      final before = await sha256.bind(file.openRead()).first;
      await _copyFile(file, work.stage.file.path);
      await work.stage.verifyIdentity();
      final copied = await sha256.bind(work.stage.file.openRead()).first;
      final after = await sha256.bind(file.openRead()).first;
      if (before != copied || before != after) {
        throw FileSystemException('Catalog promotion copy mismatch', file.path);
      }
      return await _locked(() async {
        final current = await _read(work.key);
        if (current?.entry.persistent == true) return current!.entry;
        if (current?.entry.path != work.originalTarget ||
            (_state.versions[work.key] ?? 0) != work.targetVersion ||
            (work.lease == null &&
                (_state.versions[_key(work.sourceId)] ?? 0) !=
                    work.sourceVersion) ||
            (work.lease != null && work.lease!.released)) {
          return null;
        }
        if (work.lease == null) {
          final selected = await _read(_key(work.sourceId));
          if (selected?.entry.path != work.source.path) return null;
        } else {
          final selected = await _read(_key(work.sourceId));
          if (selected?.entry.path == work.source.path &&
              (_state.versions[_key(work.sourceId)] ?? 0) !=
                  work.sourceVersion) {
            return null;
          }
        }
        await work.stage.verifyIdentity();
        if (canPublish != null && !await canPublish()) return null;
        if (work.lease?.released == true) return null;
        publishCatalogFileNew(work.stage.file.path, work.destination);
        _afterAudioPublication?.call();
        final saved = CatalogAudioEntry(
          work.destination,
          true,
          work.source.lastPlayed,
          qualityMetadata: work.source.qualityMetadata,
        );
        if (!await _write(
          work.key,
          saved,
          work.created,
          canPublish: () async =>
              work.lease?.released != true &&
              (canPublish == null || await canPublish()),
          stillValid: () => work.lease?.released != true,
        )) {
          return null;
        }
        if (current != null && !current.entry.persistent) {
          await _discard(current.entry.path);
        }
        return saved;
      });
    } finally {
      await _locked(() async {
        try {
          await work.stage.remove();
        } finally {
          final remaining = (_pins[work.source.path] ?? 1) - 1;
          if (remaining > 0) {
            _pins[work.source.path] = remaining;
          } else {
            _pins.remove(work.source.path);
            if (_retired.remove(work.source.path))
              await _discard(work.source.path);
          }
        }
      });
    }
  }

  Future<void> recordPlayback(String id) => _locked(() async {
    final key = _key(id);
    final old = await _read(key);
    if (old != null) {
      // Persist the playback timestamp on the audio before publishing the
      // manifest. It survives a failed manifest write and process restart.
      if (!old.entry.persistent) {
        if (await FileSystemEntity.type(old.entry.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw FileSystemException('Temporary audio is not a regular file');
        }
        _unrecordedPlayback.add(key);
        await _touchFile(File(old.entry.path), _clock().toUtc());
      }
      _unrecordedPlayback.add(key);
      await _write(
        key,
        CatalogAudioEntry(
          old.entry.path,
          old.entry.persistent,
          _clock().toUtc(),
          qualityMetadata: old.entry.qualityMetadata,
          variantId: old.entry.variantId,
        ),
        old.created,
      );
      _unrecordedPlayback.remove(key);
    }
  });

  /// Record the exact file used by a deck, even if its ID now points elsewhere.
  Future<void> recordPlaybackLease(CatalogAudioLease lease) =>
      _locked(() async {
        final key = _key(lease.id);
        if (lease.released || (_pins[lease.path] ?? 0) <= 0) {
          throw StateError('Playback lease is no longer active');
        }
        final current = await _read(key);
        final hadPendingPlayback = _unrecordedPlayback.contains(key);
        final isTemporary = p.isWithin(
          p.normalize(p.absolute(cacheDirectory.path)),
          p.normalize(p.absolute(lease.path)),
        );
        if (isTemporary) {
          if (await FileSystemEntity.type(lease.path, followLinks: false) !=
              FileSystemEntityType.file) {
            throw FileSystemException('Temporary audio is not a regular file');
          }
          _unrecordedPlayback.add(key);
          await _touchFile(File(lease.path), _clock().toUtc());
        }
        if (current?.entry.path == lease.path) {
          _unrecordedPlayback.add(key);
          await _write(
            key,
            CatalogAudioEntry(
              lease.path,
              current!.entry.persistent,
              _clock().toUtc(),
              qualityMetadata: current.entry.qualityMetadata,
              variantId: current.entry.variantId,
            ),
            current.created,
          );
        }
        // A retired lease cannot reconcile a persistence failure for the
        // replacement now addressed by this ID.
        if (current?.entry.path == lease.path || !hadPendingPlayback) {
          _unrecordedPlayback.remove(key);
        }
      });

  Future<CatalogAudioLease?> acquire(String id, {String? requiredProvider}) =>
      _locked(() async {
        final current = await _read(_key(id));
        if (current == null) return null;
        final entry = current.entry;
        if (requiredProvider != null) {
          final provider = entry.qualityMetadata['provider'];
          if (provider is! String ||
              provider.trim().isEmpty ||
              provider.trim().toLowerCase() !=
                  requiredProvider.trim().toLowerCase())
            return null;
        }
        _pins[entry.path] = (_pins[entry.path] ?? 0) + 1;
        return CatalogAudioLease._(
          entry.path,
          id,
          () => _locked(() async {
            final remaining = (_pins[entry.path] ?? 1) - 1;
            if (remaining > 0) {
              _pins[entry.path] = remaining;
            } else {
              _pins.remove(entry.path);
              if (_retired.remove(entry.path)) await _discard(entry.path);
            }
          }),
          CatalogAudioEntry(
            entry.path,
            entry.persistent,
            entry.lastPlayed,
            qualityMetadata: Map.unmodifiable(entry.qualityMetadata),
          ),
          current.created,
        );
      });

  Future<int> cleanupExpired({Set<String> protectedIds = const {}}) =>
      _locked(() async {
        return _cleanTemporary(expiredOnly: true, protectedIds: protectedIds);
      });

  /// Keeps the temporary audio under [maxBytes] by dropping the least recently
  /// used entries first. Entries held by a lease, or whose track is listed in
  /// [protectedTracks], are never removed. Returns the evicted entry count.
  Future<int> enforceTemporaryBudget({
    required int maxBytes,
    Set<String> protectedTracks = const {},
    void Function(String line)? trace,
  }) => _locked(() async {
    final manifests = <String, List<File>>{};
    await for (final entity in libraryDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = RegExp(
        r'^([0-9a-f]{64})\.[0-9]{20}\.json$',
      ).firstMatch(p.basename(entity.path));
      if (match != null) (manifests[match.group(1)!] ??= []).add(entity);
    }
    final candidates =
        <({String key, List<File> files, String path, int size, DateTime use})>[];
    var total = 0;
    for (final key in manifests.keys) {
      final files = manifests[key]!;
      final item = await _read(key, indexed: files);
      if (item == null || item.entry.persistent) continue;
      final stat = await File(item.entry.path).stat();
      if (stat.type != FileSystemEntityType.file) continue;
      total += stat.size;
      if ((_pins[item.entry.path] ?? 0) > 0 ||
          _unrecordedPlayback.contains(key)) {
        continue;
      }
      final variant = item.entry.variantId;
      if (variant != null) {
        try {
          final decoded = jsonDecode(variant);
          if (decoded is List &&
              decoded.length > 1 &&
              protectedTracks.contains(decoded[1])) {
            continue;
          }
        } catch (_) {
          continue;
        }
      } else if (protectedTracks.isNotEmpty) {
        continue;
      }
      final modified = stat.modified.toUtc();
      final recorded = item.entry.lastPlayed ?? item.created;
      candidates.add((
        key: key,
        files: files,
        path: item.entry.path,
        size: stat.size,
        use: modified.isAfter(recorded) ? modified : recorded,
      ));
    }
    if (total <= maxBytes) return 0;
    candidates.sort((a, b) => a.use.compareTo(b.use));
    var evicted = 0;
    for (final item in candidates) {
      if (total <= maxBytes) break;
      var temporaryOnly = true;
      for (final manifest in item.files) {
        try {
          final data =
              jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
          if (data['persistent'] != false) temporaryOnly = false;
        } catch (_) {
          temporaryOnly = false;
        }
      }
      if (!temporaryOnly) continue;
      try {
        await _discard(item.path);
        if (await FileSystemEntity.type(item.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        for (final manifest in item.files) {
          await manifest.delete();
        }
        _state.versions[item.key] = (_state.versions[item.key] ?? 0) + 1;
        total -= item.size;
        evicted++;
        trace?.call('retention: evict reason=budget bytes=${item.size}');
      } on FileSystemException {
        continue;
      }
    }
    return evicted;
  });

  /// Removes temporary entries that are not held by a playback lease.
  Future<int> clearTemporary({Set<String> protectedIds = const {}}) =>
      _locked(() async {
        return _cleanTemporary(expiredOnly: false, protectedIds: protectedIds);
      });

  Future<int> _cleanTemporary({
    required bool expiredOnly,
    required Set<String> protectedIds,
  }) async {
    await _recover();
    final manifests = <String, List<File>>{};
    await for (final entity in libraryDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = RegExp(
        r'^([0-9a-f]{64})\.[0-9]{20}\.json$',
      ).firstMatch(p.basename(entity.path));
      if (match != null) (manifests[match.group(1)!] ??= []).add(entity);
    }
    final protectedKeys = protectedIds.map(_key).toSet();
    final uncertainTargets = await CatalogAudioStage.uncertainTargets(
      cacheDirectory,
    );
    var removed = 0;
    for (final key in manifests.keys) {
      if (protectedKeys.contains(key) || _unrecordedPlayback.contains(key)) {
        continue;
      }
      final files = manifests[key]!;
      final item = await _read(key, indexed: files);
      if (item == null ||
          item.entry.persistent ||
          uncertainTargets == null ||
          uncertainTargets.contains(p.basename(item.entry.path)) ||
          (_pins[item.entry.path] ?? 0) > 0) {
        continue;
      }
      final modified = (await File(item.entry.path).stat()).modified.toUtc();
      final recorded = item.entry.lastPlayed ?? item.created;
      final lastUse = modified.isAfter(recorded) ? modified : recorded;
      if (expiredOnly && _clock().toUtc().difference(lastUse) < ttl) {
        continue;
      }
      // Every surviving manifest must be unambiguously temporary. Older
      // persistent or damaged records may represent a saved publication.
      var safe = true;
      for (final manifest in files) {
        try {
          final data =
              jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
          final filename = data['file'] as String;
          if (data['persistent'] != false ||
              !RegExp(
                '^$key\\.[0-9]{20}\\.' + catalogAudioExtensionPattern + r'$',
              ).hasMatch(filename)) {
            safe = false;
            break;
          }
          final path = p.join(cacheDirectory.path, filename);
          if (path != item.entry.path &&
              await FileSystemEntity.type(path, followLinks: false) !=
                  FileSystemEntityType.notFound) {
            safe = false;
            break;
          }
        } catch (_) {
          safe = false;
          break;
        }
      }
      if (!safe) continue;
      try {
        await _discard(item.entry.path);
        if (await FileSystemEntity.type(item.entry.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        for (final manifest in files) {
          await manifest.delete();
        }
        _state.versions[key] = (_state.versions[key] ?? 0) + 1;
        removed++;
      } on FileSystemException {
        /* Preserve records and retry later. */
      }
    }
    // A generated cache file without a usable manifest may be an interrupted
    // publication. Preserve ambiguous records and honour protection and age.
    await for (final entity in cacheDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (uncertainTargets == null ||
          uncertainTargets.contains(p.basename(entity.path))) {
        continue;
      }
      final match = RegExp(
        r'^([0-9a-f]{64})\.[0-9]{20}\.' +
            catalogAudioExtensionPattern +
            r'(?:\.part)?$',
      ).firstMatch(p.basename(entity.path));
      if (match == null) continue;
      final key = match.group(1)!;
      if (protectedKeys.contains(key) ||
          _unrecordedPlayback.contains(key) ||
          (_pins[entity.path] ?? 0) > 0) {
        continue;
      }
      if (manifests.containsKey(key)) {
        var ambiguousOrReferenced = false;
        for (final manifest in manifests[key]!) {
          try {
            final data =
                jsonDecode(await manifest.readAsString())
                    as Map<String, dynamic>;
            final filename = data['file'] as String;
            if (!RegExp(
                  '^$key\\.[0-9]{20}\\.' + catalogAudioExtensionPattern + r'$',
                ).hasMatch(filename) ||
                data['persistent'] is! bool ||
                (data['persistent'] == false &&
                    filename == p.basename(entity.path))) {
              ambiguousOrReferenced = true;
              break;
            }
          } catch (_) {
            ambiguousOrReferenced = true;
            break;
          }
        }
        if (ambiguousOrReferenced) continue;
      }
      final modified = (await entity.stat()).modified.toUtc();
      if (expiredOnly && _clock().toUtc().difference(modified) < ttl) continue;
      try {
        await _discard(entity.path);
        if (!await entity.exists()) removed++;
      } on FileSystemException {
        // Retry later.
      }
    }
    return removed;
  }
}

bool catalogAudioCanBeSaved(Map<String, Object> metadata, String id) {
  // Provider identity does not determine whether audio may be retained.
  // Matching a download's format and quality requires a separate contract.
  return true;
}

Map<String, Object> _qualityMetadata(Object? input) {
  if (input is! Map) return const {};
  final result = <String, Object>{};
  for (final key in [
    'requested_quality',
    'resolved_quality',
    'provider',
    'output_codec',
    'output_container',
    'output_validation',
  ]) {
    final value = input[key];
    if (value is String && RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(value)) {
      result[key] = value;
    }
  }
  final formats = input['output_container'];
  if (formats is String &&
      RegExp(r'^[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*$').hasMatch(formats) &&
      formats.length <= 128) {
    result['output_container'] = formats;
  }
  final fallback = input['quality_fallback_used'];
  if (fallback is bool) result['quality_fallback_used'] = fallback;
  final identityUnverified = input['quality_identity_unverified'];
  if (identityUnverified is bool)
    result['quality_identity_unverified'] = identityUnverified;
  final validated = input['output_decode_validated'];
  if (validated is bool) result['output_decode_validated'] = validated;
  return result;
}
