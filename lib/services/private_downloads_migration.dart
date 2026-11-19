import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_reorganizer.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('PrivateDownloadsMigration');

typedef RowPage =
    Future<List<Map<String, dynamic>>> Function(int limit, int offset);

class PrivateDownloadsPlan {
  const PrivateDownloadsPlan({required this.plan, this.missing = 0});

  /// Moves into the shared folder, ready for [LibraryReorganizer.run].
  final LibraryReorganizationPlan plan;

  /// Rows whose file is gone from private storage.
  final int missing;

  int get count => plan.moves.length;
  bool get isEmpty => plan.moves.isEmpty;
}

/// Finds the tracks stored in the private download folders so they can be
/// copied into [targetRoot] with the same relative layout. Nothing is moved
/// here; [LibraryReorganizer] copies each file, checks the copy, points the
/// history and library rows at it and deletes the original only after that.
Future<PrivateDownloadsPlan> buildPrivateDownloadsPlan({
  required List<String> privateFolders,
  required String targetRoot,
  RowPage? historyRows,
  RowPage? libraryRows,
  Future<bool> Function(String path)? fileExists,
}) async {
  final history =
      historyRows ??
      (limit, offset) =>
          HistoryDatabase.instance.getAll(limit: limit, offset: offset);
  final library =
      libraryRows ??
      (limit, offset) =>
          LibraryDatabase.instance.getPage(limit: limit, offset: offset);
  final exists = fileExists ?? (path) => File(path).exists();

  final roots = [for (final folder in privateFolders) p.normalize(folder)];
  final movesBySource = <String, LibraryReorganizationMove>{};
  final idsBySource = <String, List<String>>{};
  var missing = 0;

  String? rootOf(String path) {
    final normalized = p.normalize(path);
    for (final root in roots) {
      if (p.isWithin(root, normalized)) return root;
    }
    return null;
  }

  Future<void> consider({
    required String filePath,
    required String trackName,
    required List<String> historyIds,
  }) async {
    final root = rootOf(filePath);
    if (root == null) return;
    final normalized = p.normalize(filePath);
    if (!await exists(normalized)) {
      missing++;
      return;
    }
    final relativeDir = p.relative(p.dirname(normalized), from: root);
    movesBySource[normalized] = LibraryReorganizationMove(
      historyIds: historyIds,
      trackName: trackName,
      sourcePath: filePath,
      sourceRelativeDir: normalizeRelativeLibraryDir(
        relativeDir == '.' ? '' : relativeDir,
      ),
      sourceFileName: p.basename(normalized),
      targetRelativeDir: normalizeRelativeLibraryDir(
        relativeDir == '.' ? '' : relativeDir,
      ),
      targetFileName: p.basename(normalized),
    );
  }

  const pageSize = 500;
  for (var offset = 0; ; offset += pageSize) {
    final rows = await history(pageSize, offset);
    if (rows.isEmpty) break;
    for (final row in rows) {
      final DownloadHistoryItem item;
      try {
        item = DownloadHistoryItem.fromJson(row);
      } catch (e) {
        _log.w('Skipping unreadable history row: $e');
        continue;
      }
      final path = item.filePath.trim();
      if (path.isEmpty || rootOf(path) == null) continue;
      final key = p.normalize(path);
      final shared = idsBySource[key];
      if (shared != null) {
        shared.add(item.id);
        continue;
      }
      final ids = idsBySource[key] = [item.id];
      await consider(
        filePath: path,
        trackName: item.trackName,
        historyIds: ids,
      );
    }
    if (rows.length < pageSize) break;
  }

  for (var offset = 0; ; offset += pageSize) {
    final rows = await library(pageSize, offset);
    if (rows.isEmpty) break;
    for (final row in rows) {
      final LocalLibraryItem item;
      try {
        item = LocalLibraryItem.fromJson(row);
      } catch (e) {
        _log.w('Skipping unreadable library row: $e');
        continue;
      }
      final path = item.filePath.trim();
      if (path.isEmpty || rootOf(path) == null) continue;
      final key = p.normalize(path);
      if (idsBySource.containsKey(key)) continue;
      idsBySource[key] = const [];
      await consider(
        filePath: path,
        trackName: item.trackName,
        historyIds: const [],
      );
    }
    if (rows.length < pageSize) break;
  }

  final moves = resolveLibraryReorganizationConflicts(
    movesBySource.values.toList(growable: false),
  );
  return PrivateDownloadsPlan(
    plan: LibraryReorganizationPlan(
      root: p.normalize(targetRoot),
      safMode: false,
      moves: moves,
      missing: missing,
    ),
    missing: missing,
  );
}
