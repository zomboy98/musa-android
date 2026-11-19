import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/library_native_adapter.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LibraryDatabase');

/// Temp tables holding staged Library rows and their path keys.
typedef _ScanStage = ({String rows, String keys});

/// Scan and incremental ingestion writes. The connection and the lazy
/// History attachment stay owned by LibraryDatabase and are passed in.
class LibraryIngestionStore {
  static const _ScanStage _scanStage = (
    rows: 'library_scan_stage',
    keys: 'library_scan_path_keys_stage',
  );
  static const _ScanStage _incrementalStage = (
    rows: 'library_incremental_stage',
    keys: 'library_incremental_path_keys_stage',
  );
  static const String _downloadedLibraryIdsStageTable =
      'library_downloaded_ids_stage';

  final Future<Database> Function() _openDatabase;
  final Future<void> Function(Database db) _attachHistory;

  LibraryIngestionStore({
    required Future<Database> Function() openDatabase,
    required Future<void> Function(Database db) ensureHistoryAttached,
  }) : _openDatabase = openDatabase,
       _attachHistory = ensureHistoryAttached;

  Future<Database> get database => _openDatabase();

  Future<void> _ensureHistoryAttached(Database db) => _attachHistory(db);

  /// The scanner requests at most one small listing batch at a time.
  Future<Map<String, Map<String, dynamic>>> readNetworkScanRows(
    String sourceId,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return {};
    if (paths.length > 64) throw ArgumentError('Too many network scan paths');
    final db = await database;
    // Without statistics SQLite can prefer source_id and revisit every track
    // in the source for each batch. Seek only the requested paths instead.
    final rows = await db.rawQuery(
      'SELECT * FROM library INDEXED BY idx_library_file_path '
      'WHERE source_id = ? '
      'AND file_path IN (${List.filled(paths.length, '?').join(',')})',
      [sourceId, ...paths],
    );
    return {
      for (final row in rows)
        row['file_path'] as String: LibraryRowMapper.decode(row),
    };
  }

  /// Keeps native scan output native through parsing, indexing and the atomic
  /// source swap. The stream implementation remains the desktop/test adapter.
  Future<({int inserted, int skipped})> replaceSourceScanFile(
    String sourceId,
    LibraryScanNDJSONFile scan, {
    required String requestId,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) throw StateError('Library scan cancelled');
    if (PlatformBridge.supportsCoreBackend) {
      final db = await database;
      await _ensureHistoryAttached(db);
      final result = await LibraryNativeAdapter(db).importScanFile(
        sourceId,
        scan,
        requestId: requestId,
        isCancelled: isCancelled,
      );
      return (
        inserted: (result['inserted'] as num).toInt(),
        skipped: (result['skipped'] as num).toInt(),
      );
    }
    Stream<Map<String, dynamic>> validatedRows() async* {
      var count = 0;
      await for (final row in scan.rows()) {
        if (isCancelled()) {
          throw StateError('Library scan cancelled during ingestion');
        }
        count++;
        yield row;
      }
      if (count != scan.expectedCount) {
        throw FormatException(
          'Library scan row count mismatch: decoded $count, '
          'expected ${scan.expectedCount}',
        );
      }
    }

    return replaceSourceStream(
      sourceId,
      validatedRows(),
      preserveMissing: scan.errorCount > 0,
      preserveMissingPaths: scan.preserveMissingPaths,
    );
  }

  /// Native folder scanning and delta ingestion share one operation, so delta
  /// track maps never return to Flutter. SAF traversal stays in its OS adapter.
  Future<Map<String, dynamic>> scanIncrementalNative(
    String sourceId,
    String folderPath,
    String snapshotPath, {
    required bool isSaf,
    required String requestId,
    required bool Function() isCancelled,
  }) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    return LibraryNativeAdapter(db).scanIncremental(
      sourceId,
      folderPath,
      snapshotPath,
      isSaf: isSaf,
      requestId: requestId,
      isCancelled: isCancelled,
    );
  }

  /// Removes rows from one source whose normalized path keys already exist in
  /// download History, without materializing either database's paths in Dart.
  Future<int> deleteDownloadedRowsForSource(String sourceId) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    const downloadedMatch = '''
      EXISTS (
        SELECT 1
        FROM library_path_keys lk
        JOIN history_db.history_path_keys hk ON hk.path_key = lk.path_key
        WHERE lk.item_id = library.id
      )
    ''';
    await db.execute('DROP TABLE IF EXISTS $_downloadedLibraryIdsStageTable');
    await db.execute(
      'CREATE TEMP TABLE $_downloadedLibraryIdsStageTable '
      '(id TEXT PRIMARY KEY)',
    );
    try {
      await db.rawInsert(
        'INSERT INTO $_downloadedLibraryIdsStageTable(id) '
        'SELECT id FROM library '
        'WHERE source_id = ? AND $downloadedMatch',
        [sourceId],
      );
      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_downloadedLibraryIdsStageTable',
      );
      final count = Sqflite.firstIntValue(countRows) ?? 0;
      if (count == 0) return 0;

      await sqlite.transactionWithBusyRetry(db, (txn) async {
        await txn.rawDelete(
          'DELETE FROM library_path_keys WHERE item_id IN '
          '(SELECT id FROM $_downloadedLibraryIdsStageTable)',
        );
        await txn.rawDelete(
          'DELETE FROM library WHERE id IN '
          '(SELECT id FROM $_downloadedLibraryIdsStageTable)',
        );
      });
      return count;
    } finally {
      await db.execute('DROP TABLE IF EXISTS $_downloadedLibraryIdsStageTable');
    }
  }

  /// Upserts incremental scan rows after filtering them through the attached
  /// History path-key index. This keeps the hot incremental path independent
  /// of total History size.
  Future<({int upserted, int skipped})> upsertBatchExcludingHistory(
    List<Map<String, dynamic>> items, {
    required String sourceId,
  }) async {
    if (items.isEmpty) return (upserted: 0, skipped: 0);
    final db = await database;
    await _ensureHistoryAttached(db);
    await _createScanStage(db, _incrementalStage);
    try {
      final batch = db.batch();
      final stagedIds = <String>{};
      for (final json in items) {
        _stageScanRow(batch, _incrementalStage, json, sourceId, stagedIds);
      }
      await batch.commit(noResult: true);
      final (:staged, :skipped) = await _mergeStageExcludingHistory(
        db,
        _incrementalStage,
      );
      return (upserted: staged - skipped, skipped: skipped);
    } finally {
      await db.execute('DROP TABLE IF EXISTS ${_incrementalStage.keys}');
      await db.execute('DROP TABLE IF EXISTS ${_incrementalStage.rows}');
    }
  }

  Future<void> _createScanStage(Database db, _ScanStage stage) async {
    await db.execute('DROP TABLE IF EXISTS ${stage.rows}');
    await db.execute('DROP TABLE IF EXISTS ${stage.keys}');
    await db.execute(
      'CREATE TEMP TABLE ${stage.rows} AS SELECT * FROM library WHERE 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${stage.rows}_id ON ${stage.rows}(id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${stage.rows}_path ON ${stage.rows}(file_path)',
    );
    await db.execute('''
      CREATE TEMP TABLE ${stage.keys} (
        item_id TEXT NOT NULL,
        path_key TEXT NOT NULL,
        PRIMARY KEY (item_id, path_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_${stage.keys}_key ON ${stage.keys}(path_key)',
    );
  }

  void _stageScanRow(
    Batch batch,
    _ScanStage stage,
    Map<String, dynamic> json,
    String sourceId,
    Set<String> stagedIds,
  ) {
    final id = json['id'] as String?;
    if (id == null || id.trim().isEmpty) {
      throw const FormatException('Library scan row has no valid id');
    }
    batch.insert(
      stage.rows,
      LibraryRowMapper.encode(json, sourceId: sourceId),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    sqlite.putPathKeysInBatch(
      batch,
      stage.keys,
      id,
      json['filePath'] as String?,
      // The stage starts empty: only a repeated id has keys to replace.
      replaceExisting: !stagedIds.add(id),
    );
  }

  /// Counts the staged rows, then merges those without a History file into
  /// the Library in one transaction, after [beforeMerge] when given.
  Future<({int staged, int skipped})> _mergeStageExcludingHistory(
    Database db,
    _ScanStage stage, {
    Future<void> Function(Transaction txn)? beforeMerge,
  }) async {
    final historyMatch =
        '''
      EXISTS (
        SELECT 1
        FROM ${stage.keys} sk
        JOIN history_db.history_path_keys hk ON hk.path_key = sk.path_key
        WHERE sk.item_id = s.id
      )
    ''';
    final skippedRows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM ${stage.rows} s '
      'WHERE $historyMatch',
    );
    final skipped = Sqflite.firstIntValue(skippedRows) ?? 0;
    final stagedRows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM ${stage.rows}',
    );
    final staged = Sqflite.firstIntValue(stagedRows) ?? 0;
    final columns = (await db.rawQuery(
      'PRAGMA table_info(library)',
    )).map((row) => row['name'] as String).toList(growable: false);
    final columnList = columns.join(', ');
    final selectedColumns = columns.map((column) => 's.$column').join(', ');

    await sqlite.transactionWithBusyRetry(db, (txn) async {
      // Both id and file_path are globally unique. REPLACE would otherwise
      // silently delete another source's row, including its metadata. Check
      // before any order transfer or source deletion in the same transaction.
      final conflicts = await txn.rawQuery('''
        SELECT s.id AS incoming_id, s.source_id AS incoming_source,
               old.id AS existing_id, old.source_id AS existing_source
        FROM ${stage.rows} s
        JOIN library old ON old.id = s.id OR old.file_path = s.file_path
        WHERE old.source_id != s.source_id AND NOT $historyMatch
        LIMIT 1
      ''');
      if (conflicts.isNotEmpty) {
        final conflict = conflicts.first;
        throw StateError(
          'Library scan source conflict: incoming '
          '${conflict['incoming_id']} from ${conflict['incoming_source']} '
          'conflicts with ${conflict['existing_id']} owned by '
          '${conflict['existing_source']}; existing Library data was preserved',
        );
      }
      // A scanner may assign a new ID to the same exact path. Transfer only
      // within the same source and only to an unclaimed ID. This runs before
      // the source swap so partial scans retain all unrelated orphan keys.
      await txn.rawUpdate('''
        UPDATE library_manual_order
        SET unified_id = 'local_' || (
          SELECT s.id FROM library old
          JOIN ${stage.rows} s ON s.source_id = old.source_id
            AND s.file_path = old.file_path
          WHERE 'local_' || old.id = library_manual_order.unified_id
        )
        WHERE EXISTS (
          SELECT 1 FROM library old
          JOIN ${stage.rows} s ON s.source_id = old.source_id
            AND s.file_path = old.file_path
          WHERE 'local_' || old.id = library_manual_order.unified_id
            AND old.id != s.id AND NOT $historyMatch
            AND NOT EXISTS (SELECT 1 FROM library current WHERE current.id = s.id)
            AND NOT EXISTS (
              SELECT 1 FROM library_manual_order claimed
              WHERE claimed.unified_id = 'local_' || s.id
            )
        )
      ''');
      if (beforeMerge != null) await beforeMerge(txn);
      await txn.rawDelete('''
        DELETE FROM library_path_keys
        WHERE item_id IN (
          SELECT s.id FROM ${stage.rows} s WHERE NOT $historyMatch
        )
      ''');
      await txn.rawInsert('''
        INSERT OR REPLACE INTO library ($columnList)
        SELECT $selectedColumns FROM ${stage.rows} s
        WHERE NOT $historyMatch
      ''');
      await txn.rawInsert('''
        INSERT OR IGNORE INTO library_path_keys(item_id, path_key)
        SELECT sk.item_id, sk.path_key
        FROM ${stage.keys} sk
        JOIN ${stage.rows} s ON s.id = sk.item_id
        WHERE NOT $historyMatch
      ''');
    });
    return (staged: staged, skipped: skipped);
  }

  /// Stages scan rows in bounded, independently committed batches, then swaps
  /// only this source in one short transaction. Download-history exclusion is
  /// an indexed SQLite anti-join, avoiding a full History path set in Dart.
  Future<({int inserted, int skipped})> replaceSourceStream(
    String sourceId,
    Stream<Map<String, dynamic>> items, {
    int batchSize = 300,
    bool preserveMissing = false,
    List<String>? preserveMissingPaths,
  }) async {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'Must be positive');
    }
    final db = await database;
    await _ensureHistoryAttached(db);
    await _createScanStage(db, _scanStage);
    var streamed = 0;
    try {
      var batch = db.batch();
      var pending = 0;
      Future<void> flush() async {
        if (pending == 0) return;
        await batch.commit(noResult: true);
        batch = db.batch();
        pending = 0;
      }

      final stagedIds = <String>{};
      await for (final json in items) {
        _stageScanRow(batch, _scanStage, json, sourceId, stagedIds);
        streamed++;
        pending++;
        if (pending >= batchSize) await flush();
      }
      await flush();
      final (:staged, :skipped) = await _mergeStageExcludingHistory(
        db,
        _scanStage,
        beforeMerge: (txn) => deleteReplacedLibraryScanRows(
          txn,
          sourceId,
          stageTable: _scanStage.rows,
          preserveMissing: preserveMissing,
          preserveMissingPaths: preserveMissingPaths,
        ),
      );
      final inserted = staged - skipped;
      _log.i(
        'Streamed $streamed rows, staged $staged unique rows, and swapped '
        '$inserted into Library source '
        '$sourceId ($skipped downloads excluded)',
      );
      return (inserted: inserted, skipped: skipped);
    } finally {
      await db.execute('DROP TABLE IF EXISTS ${_scanStage.keys}');
      await db.execute('DROP TABLE IF EXISTS ${_scanStage.rows}');
    }
  }
}
