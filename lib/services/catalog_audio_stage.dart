import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog_file_publication.dart';

// Suffixes are untrusted labels, never evidence of codec or playability.
// Reserve journal, manifest, and playlist names for their own purposes.
const catalogAudioExtensionPattern =
    r'(?!(?:json|tmp|part|m3u|m3u8|pls|xspf|asx|cue)(?:[.]|$))[a-z0-9]{1,10}';

enum _ReferenceState { referenced, unreferenced, ambiguous }

/// Private staging with a durable ownership record and an identity anchor.
/// Android pins identity with an open descriptor, which cannot survive restart;
/// its interrupted stages are preserved when identity is no longer provable.
/// Only used under CatalogAudioStore's single-isolate serialization. Recovery
/// runs after a process restart, never alongside an active store operation.
/// This is process-crash recovery, not a power-loss durability protocol.
/// Checking identity and then deleting requires this exclusive store ownership;
/// it is not atomic against a hostile process replacing filesystem entries.
class CatalogAudioStage {
  // Active stages are protected only within the owning isolate/process.
  static final Set<String> _active = {};
  CatalogAudioStage._(
    this.directory,
    this.file,
    this.manifests,
    this._identity,
  );
  final Directory directory;
  final File file;
  final Directory manifests;
  final AndroidCatalogFileIdentity? _identity;
  static const prefix = '.catalog-stage-v2-';
  static const _magic = 'musa-catalog-owned-stage-v2';

  static Future<CatalogAudioStage> create(
    Directory root,
    String leaf, {
    required Directory manifests,
    String? destination,
  }) async {
    if (leaf != 'audio.part' && leaf != 'manifest.tmp') {
      throw ArgumentError.value(leaf, 'leaf');
    }
    final target = destination == null ? null : p.basename(destination);
    if (target != null &&
        (leaf != 'audio.part' ||
            p.dirname(destination!) != root.path ||
            !RegExp(
              r'^[0-9a-f]{64}\.[0-9]{20}\.' +
                  catalogAudioExtensionPattern +
                  r'$',
            ).hasMatch(target))) {
      throw ArgumentError.value(destination, 'destination');
    }
    final directory = await root.createTemp(prefix);
    final file = File(p.join(directory.path, leaf));
    final anchor = File(p.join(directory.path, 'identity'));
    final journal = File(p.join(directory.path, 'owner.json'));
    AndroidCatalogFileIdentity? identity;
    try {
      await file.create(exclusive: true);
      if (Platform.isAndroid) {
        identity = AndroidCatalogFileIdentity.open(file.path);
      } else {
        linkCatalogFileNew(file.path, anchor.path);
      }
      await journal.writeAsString(
        jsonEncode({
          'magic': _magic,
          'directory': p.basename(directory.path),
          'leaf': leaf,
          'target': target,
        }),
        flush: true,
      );
      _active.add(p.normalize(p.absolute(directory.path)));
      return CatalogAudioStage._(directory, file, manifests, identity);
    } catch (_) {
      identity?.close();
      // Nothing has been handed to a writer. Remove only these allocated names.
      for (final allocated in [journal, anchor, file]) {
        try {
          await allocated.delete();
        } on FileSystemException {
          /* absent */
        }
      }
      try {
        await directory.delete();
      } on FileSystemException {
        /* preserve */
      }
      rethrow;
    }
  }

  Future<void> remove() async {
    try {
      _active.remove(p.normalize(p.absolute(directory.path)));
      await recover(directory, manifests, identity: _identity);
    } finally {
      _identity?.close();
    }
  }

  Future<void> verifyIdentity() async {
    final anchor = p.join(directory.path, 'identity');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        (_identity == null &&
            await FileSystemEntity.type(anchor, followLinks: false) !=
                FileSystemEntityType.file) ||
        !(_identity?.matches(file.path) ??
            await FileSystemEntity.identical(file.path, anchor))) {
      throw FileSystemException('Catalog stage identity changed', file.path);
    }
  }

  static Future<void> recover(
    Directory directory,
    Directory manifests, {
    AndroidCatalogFileIdentity? identity,
  }) async {
    try {
      if (identity == null &&
          _active.contains(p.normalize(p.absolute(directory.path))))
        return;
      if (!p.basename(directory.path).startsWith(prefix) ||
          await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.directory) {
        return;
      }
      final journal = File(p.join(directory.path, 'owner.json'));
      final anchor = File(p.join(directory.path, 'identity'));
      if (await FileSystemEntity.type(journal.path, followLinks: false) !=
              FileSystemEntityType.file ||
          (identity == null &&
              await FileSystemEntity.type(anchor.path, followLinks: false) !=
                  FileSystemEntityType.file)) {
        return;
      }
      final record = jsonDecode(await journal.readAsString());
      if (record is! Map ||
          record.length != 4 ||
          record['magic'] != _magic ||
          record['directory'] != p.basename(directory.path)) {
        return;
      }
      final leaf = record['leaf'];
      if (leaf != 'audio.part' && leaf != 'manifest.tmp') return;
      final target = record['target'];
      if (target != null &&
          (leaf != 'audio.part' ||
              target is! String ||
              !RegExp(
                r'^[0-9a-f]{64}\.[0-9]{20}\.' +
                    catalogAudioExtensionPattern +
                    r'$',
              ).hasMatch(target))) {
        return;
      }
      final file = File(p.join(directory.path, leaf as String));
      final entries = await directory.list(followLinks: false).toList();
      // Unexpected files, links or subdirectories make ownership ambiguous.
      for (final entry in entries) {
        if (entry is! File ||
            !{
              leaf,
              'identity',
              'owner.json',
            }.contains(p.basename(entry.path)) ||
            await FileSystemEntity.type(entry.path, followLinks: false) !=
                FileSystemEntityType.file) {
          return;
        }
      }
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (type != FileSystemEntityType.file ||
            !(identity?.matches(file.path) ??
                await FileSystemEntity.identical(file.path, anchor.path))) {
          return;
        }
      }
      if (target is String) {
        final published = File(p.join(directory.parent.path, target));
        final publishedType = await FileSystemEntity.type(
          published.path,
          followLinks: false,
        );
        if (publishedType != FileSystemEntityType.notFound) {
          // A collision/replacement belongs to someone else. Never delete it.
          if (publishedType == FileSystemEntityType.file &&
              (identity?.matches(published.path) ??
                  await FileSystemEntity.identical(
                    published.path,
                    anchor.path,
                  ))) {
            final reference = await _referenceState(
              manifests,
              target,
              persistent: p.equals(directory.parent.path, manifests.path),
            );
            if (reference == _ReferenceState.ambiguous) {
              // Retain the ownership proof too: a later repair can then either
              // confirm publication or safely roll back this same file.
              return;
            }
            if (reference == _ReferenceState.unreferenced) {
              await published.delete();
            }
          }
        }
      }
      if (type == FileSystemEntityType.file) await file.delete();
      // Removing private aliases never deletes the published audio/manifest
      // name, even when Unix publication retained a second hard link here.
      if (identity == null) await anchor.delete();
      await journal.delete();
      await directory.delete();
    } on FileSystemException {
      // Preserve uncertain ownership and retry a known stage on next startup.
    } on FormatException {
      // An invalid journal is not evidence of ownership.
    }
  }

  static Future<_ReferenceState> _referenceState(
    Directory manifests,
    String target, {
    required bool persistent,
  }) async {
    var ambiguous = false;
    await for (final entity in manifests.list(followLinks: false)) {
      final match = RegExp(
        r'^([0-9a-f]{64})\.[0-9]{20}\.json$',
      ).firstMatch(p.basename(entity.path));
      if (match == null) continue;
      if (entity is! File ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
        ambiguous = true;
        continue;
      }
      try {
        final record = jsonDecode(await entity.readAsString());
        if (record is! Map ||
            record['file'] is! String ||
            record['persistent'] is! bool ||
            record['created'] is! String ||
            DateTime.tryParse(record['created'] as String) == null ||
            (record['lastPlayed'] != null &&
                (record['lastPlayed'] is! String ||
                    DateTime.tryParse(record['lastPlayed'] as String) ==
                        null)) ||
            !RegExp(
              '^${match.group(1)}\\.[0-9]{20}\\.' +
                  catalogAudioExtensionPattern +
                  r'$',
            ).hasMatch(record['file'] as String)) {
          ambiguous = true;
          continue;
        }
        if (record['file'] == target && record['persistent'] == persistent) {
          return _ReferenceState.referenced;
        }
      } on FormatException {
        ambiguous = true;
      } on FileSystemException {
        ambiguous = true;
      }
    }
    return ambiguous ? _ReferenceState.ambiguous : _ReferenceState.unreferenced;
  }

  static Future<void> recoverRoot(Directory root, Directory manifests) async {
    await for (final entry in root.list(followLinks: false)) {
      if (entry is Directory && p.basename(entry.path).startsWith(prefix)) {
        await recover(entry, manifests);
      }
    }
  }

  /// Targets of stages still present after recovery. Null means a journal
  /// cannot be interpreted, so callers must preserve all unreferenced audio.
  static Future<Set<String>?> uncertainTargets(Directory root) async {
    final targets = <String>{};
    try {
      await for (final entry in root.list(followLinks: false)) {
        if (!p.basename(entry.path).startsWith(prefix)) continue;
        if (await FileSystemEntity.type(entry.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          return null;
        }
        final journal = File(p.join(entry.path, 'owner.json'));
        if (await FileSystemEntity.type(journal.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return null;
        }
        final record = jsonDecode(await journal.readAsString());
        if (record is! Map ||
            record.length != 4 ||
            record['magic'] != _magic ||
            record['directory'] != p.basename(entry.path) ||
            (record['leaf'] != 'audio.part' &&
                record['leaf'] != 'manifest.tmp')) {
          return null;
        }
        final target = record['target'];
        if (target != null) {
          if (record['leaf'] != 'audio.part' ||
              target is! String ||
              !RegExp(
                r'^[0-9a-f]{64}\.[0-9]{20}\.' +
                    catalogAudioExtensionPattern +
                    r'$',
              ).hasMatch(target)) {
            return null;
          }
          targets.add(target);
        }
      }
      return targets;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
