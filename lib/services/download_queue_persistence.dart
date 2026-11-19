import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/download_queue_codec.dart';
import 'package:mornye/utils/chunked_list.dart';

export 'package:mornye/services/download_queue_codec.dart'
    show downloadQueuePersistenceStatus, encodeDownloadQueueItemForPersistence;

class _SelectionBatch {
  _SelectionBatch(
    this.items,
    this.events, {
    this.discardRunId,
    this.discardRequestIds = const {},
    this.discardAllRequests = false,
  });
  final List<DownloadItem> items;
  final List<Map<String, dynamic>> events;
  final String? discardRunId;
  final Set<String> discardRequestIds;
  final bool discardAllRequests;
}

/// Owns durable queue snapshots, including corrupt-row cleanup and write order.
/// A failed write leaves the previous snapshot intact so a later flush retries.
class DownloadQueuePersistence {
  DownloadQueuePersistence({
    required this.currentItems,
    required this.onError,
    this.loadRows = _loadRows,
    this.applyChanges = _applyChanges,
    this.loadSelectionEvents = _loadSelectionEvents,
    this.applySelectionChanges = _applySelectionChanges,
    this.applyNativeDiscardChanges = _applyNativeDiscardChanges,
    this.loadNativeDiscardsFromStorage = _loadNativeDiscards,
    this.ackNativeDiscardsInStorage = _ackNativeDiscards,
  });

  final List<DownloadItem> Function() currentItems;
  final void Function(Object error) onError;
  final Future<List<Map<String, dynamic>>> Function() loadRows;
  final Future<void> Function({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  })
  applyChanges;
  final Future<List<Map<String, dynamic>>> Function() loadSelectionEvents;
  final Future<void> Function({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
    required List<Map<String, dynamic>> selectionEvents,
  })
  applySelectionChanges;
  final Future<void> Function({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
    required String runId,
    required Set<String> requestIds,
    required bool allRequests,
  })
  applyNativeDiscardChanges;
  final Future<({bool allRequests, Set<String> requestIds})> Function(
    String runId,
  )
  loadNativeDiscardsFromStorage;
  final Future<void> Function(
    String runId, {
    required Set<String> requestIds,
    required bool allRequests,
  })
  ackNativeDiscardsInStorage;
  static const _pausedKey = 'download_queue_user_paused_v1';
  Timer? _debounce;
  List<DownloadItem>? _pendingItems;
  Future<void> _write = Future<void>.value();
  Future<void> _pauseWrite = Future<void>.value();
  Map<String, DownloadQueueSavedItem> _saved = {};
  List<DownloadItem>? _savedSnapshot;
  final _pendingSelectionBatches = <_SelectionBatch>[];
  bool _selectionBlocked = false;
  int _nativeDiscardReservations = 0;
  bool _disposed = false;

  static Future<List<Map<String, dynamic>>> _loadRows() async {
    final database = AppStateDatabase.instance;
    await database.migrateQueueFromSharedPreferences();
    return database.getPendingDownloadQueueRows();
  }

  static Future<void> _applyChanges({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  }) => AppStateDatabase.instance.applyPendingDownloadQueueChanges(
    upserts: upserts,
    deletedIds: deletedIds,
  );

  static Future<List<Map<String, dynamic>>> _loadSelectionEvents() =>
      AppStateDatabase.instance.getDownloadQueueSelectionEvents();

  static Future<void> _applySelectionChanges({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
    required List<Map<String, dynamic>> selectionEvents,
  }) => AppStateDatabase.instance.applyPendingDownloadQueueChanges(
    upserts: upserts,
    deletedIds: deletedIds,
    selectionEvents: selectionEvents,
  );

  static Future<void> _applyNativeDiscardChanges({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
    required String runId,
    required Set<String> requestIds,
    required bool allRequests,
  }) => AppStateDatabase.instance.applyPendingDownloadQueueChanges(
    upserts: upserts,
    deletedIds: deletedIds,
    discardRunId: runId,
    discardRequestIds: requestIds,
    discardAllRequests: allRequests,
  );
  static Future<({bool allRequests, Set<String> requestIds})>
  _loadNativeDiscards(String runId) =>
      AppStateDatabase.instance.loadNativeDiscards(runId);
  static Future<void> _ackNativeDiscards(
    String runId, {
    required Set<String> requestIds,
    required bool allRequests,
  }) => AppStateDatabase.instance.ackNativeDiscards(
    runId,
    requestIds: requestIds,
    allRequests: allRequests,
  );

  /// Called synchronously at the discard gesture, before awaiting a run ID.
  /// Later queue schedules must remain pending behind that discard.
  void reserveNativeDiscard() {
    _nativeDiscardReservations++;
    _debounce?.cancel();
    _debounce = null;
    _pendingItems = null;
  }

  void releaseNativeDiscard() {
    if (_nativeDiscardReservations == 0) return;
    _nativeDiscardReservations--;
    if (_nativeDiscardReservations != 0) return;
    final pending = _pendingItems;
    if (pending == null) return;
    if (_disposed) {
      _pendingItems = null;
      unawaited(_enqueue(pending));
    } else {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), flush);
    }
  }

  Future<void> persistNativeDiscard(
    String runId, {
    required List<DownloadItem> snapshot,
    Set<String> requestIds = const {},
    bool allRequests = false,
  }) {
    if (runId.isEmpty || requestIds.any((id) => id.isEmpty)) {
      throw ArgumentError('Invalid native discard identity');
    }
    if (requestIds.isEmpty && !allRequests) {
      throw ArgumentError('Empty native discard');
    }
    final batch = _SelectionBatch(
      List<DownloadItem>.of(snapshot),
      const [],
      discardRunId: runId,
      discardRequestIds: Set<String>.of(requestIds),
      discardAllRequests: allRequests,
    );
    _pendingSelectionBatches.add(batch);
    final write = _enqueue(
      batch.items,
      requireDurable: true,
      selectionBatch: batch,
    );
    releaseNativeDiscard();
    return write;
  }

  Future<({bool allRequests, Set<String> requestIds})> loadNativeDiscards(
    String runId,
  ) {
    final read = _write.then((_) => loadNativeDiscardsFromStorage(runId));
    _write = read.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return read;
  }

  Future<void> ackNativeDiscards(
    String runId, {
    Set<String> requestIds = const {},
    bool allRequests = false,
  }) {
    final ids = Set<String>.of(requestIds);
    final write = _write.then((_) async {
      if (_selectionBlocked) {
        throw StateError('Download selection requires an explicit retry');
      }
      await ackNativeDiscardsInStorage(
        runId,
        requestIds: ids,
        allRequests: allRequests,
      );
    });
    _write = write.catchError(onError);
    return write;
  }

  /// Reads the durable ledger in commit order, serialized with queue writes.
  Future<List<Map<String, dynamic>>> restoreSelectionEvents() {
    final read = _write.then((_) => loadSelectionEvents());
    _write = read.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return read;
  }

  /// The event payloads and queue snapshot are frozen at the call site. A
  /// failed batch remains pending and is retried ahead of newer intentions.
  Future<void> persistSelectionEvents(
    List<Map<String, dynamic>> events, {
    List<DownloadItem>? snapshot,
  }) {
    // A retry replays old snapshots and must preserve any newer debounced
    // queue mutation, which the writer will serialize after that replay.
    if (events.isEmpty) return _retrySelectionBatches();
    _debounce?.cancel();
    _debounce = null;
    _pendingItems = null;
    final batch = _SelectionBatch(
      List<DownloadItem>.of(snapshot ?? currentItems()),
      events.map(Map<String, dynamic>.of).toList(),
    );
    _pendingSelectionBatches.add(batch);
    return _enqueue(batch.items, requireDurable: true, selectionBatch: batch);
  }

  Future<void> _retrySelectionBatches() async {
    final batches = List<_SelectionBatch>.of(_pendingSelectionBatches);
    // Reserve the complete ordered retry in the writer before yielding, so a
    // newer gesture cannot overtake an older failed batch between awaits.
    await Future.wait([
      for (var i = 0; i < batches.length; i++)
        _enqueue(
          batches[i].items,
          requireDurable: true,
          allowSelectionRetry: i == 0,
          selectionBatch: batches[i],
        ),
    ]);
    // A debounce may have expired while selection writes were blocked.
    // Persist its still-pending state after the historical gesture snapshots.
    if (_pendingItems != null && _nativeDiscardReservations == 0) {
      await flush(requireDurable: true);
    }
  }

  Future<bool> loadUserPaused() async =>
      (await SharedPreferences.getInstance()).getBool(_pausedKey) == true;

  void setUserPaused(bool paused) {
    _pauseWrite = _pauseWrite
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (paused) {
            await prefs.setBool(_pausedKey, true);
          } else {
            await prefs.remove(_pausedKey);
          }
        })
        .catchError(onError);
  }

  Future<List<DownloadItem>> restore() {
    final restored = _write.then((_) async {
      _savedSnapshot = null;
      final decoded = await decodeDownloadQueueRows(await loadRows());
      _saved = decoded.saved;
      return decoded.items;
    });
    // Serialize restore with durable writes because decoding can yield to a
    // worker. Its error reaches the caller without preventing later retries.
    _write = restored.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return restored;
  }

  void schedule() {
    _debounce?.cancel();
    _pendingItems = currentItems();
    if (_nativeDiscardReservations == 0) {
      _debounce = Timer(const Duration(milliseconds: 350), flush);
    }
  }

  Future<void> flush({bool requireDurable = false}) async {
    _debounce?.cancel();
    _debounce = null;
    if (_nativeDiscardReservations != 0) {
      if (requireDurable) throw StateError('Native discard is being prepared');
      return;
    }
    final pending = _pendingItems;
    try {
      await _enqueue(currentItems(), requireDurable: true);
      if (identical(_pendingItems, pending)) _pendingItems = null;
    } catch (_) {
      if (requireDurable) rethrow;
    }
    await _pauseWrite;
  }

  void dispose() {
    _disposed = true;
    final pending = _pendingItems;
    // Selection calls invalidate earlier debounce snapshots; a remaining
    // snapshot therefore follows the selection and waits behind its write.
    if (pending != null && _nativeDiscardReservations == 0) {
      unawaited(_enqueue(pending));
    }
    _debounce?.cancel();
    _debounce = null;
    if (_nativeDiscardReservations == 0) _pendingItems = null;
  }

  Future<void> _enqueue(
    List<DownloadItem> items, {
    bool requireDurable = false,
    bool allowSelectionRetry = false,
    _SelectionBatch? selectionBatch,
  }) {
    final selections = selectionBatch?.events ?? const <Map<String, dynamic>>[];
    final write = _write.then((_) async {
      if (selectionBatch != null &&
          !_pendingSelectionBatches.contains(selectionBatch)) {
        return;
      }
      if (_selectionBlocked && !allowSelectionRetry) {
        throw StateError('Download selection requires an explicit retry');
      }
      // Queue states use immutable storage. Repeated lifecycle/debounce
      // flushes of an already committed snapshot need no diff or encoding.
      if (selectionBatch == null && identical(items, _savedSnapshot)) return;
      final seenIds = <String>{};
      final savedUpdates = <String, DownloadQueueSavedItem>{};
      final upserts = <Map<String, dynamic>>[];
      final now = DateTime.now().toIso8601String();
      final changed = <DownloadItem>[];
      for (final item in items) {
        if (item.status == DownloadStatus.completed ||
            (item.status == DownloadStatus.failed &&
                item.errorType != DownloadErrorType.verificationRequired &&
                !isRestorableProviderDownloadFailure(item))) {
          continue;
        }
        final saved = _saved[item.id];
        final cached = identical(saved?.item, item) && saved?.payload != null;
        seenIds.add(item.id);
        if (!cached) {
          savedUpdates[item.id] = (item: item, payload: null);
          changed.add(item);
        } else if (savedUpdates.containsKey(item.id)) {
          // Preserve the last non-terminal occurrence for malformed input
          // with repeated request IDs, just as the full snapshot did.
          savedUpdates[item.id] = saved!;
        }
      }
      final encoded = await encodeDownloadQueueItems(changed);
      for (var index = 0; index < changed.length; index++) {
        final item = changed[index];
        final saved = _saved[item.id];
        final payload = encoded[index];
        if (identical(savedUpdates[item.id]?.item, item)) {
          savedUpdates[item.id] = (item: item, payload: payload);
        }
        if (saved?.payload == payload) continue;
        upserts.add({
          'id': item.id,
          'item_json': payload,
          'status': downloadQueuePersistenceStatus(
            item.status,
            errorType: item.errorType,
          ).name,
          'created_at': item.createdAt.toIso8601String(),
          'updated_at': now,
        });
      }
      final deletedIds = _saved.keys
          .where((id) => !seenIds.contains(id))
          .toList(growable: false);
      if (selectionBatch != null) {
        try {
          final discardRunId = selectionBatch.discardRunId;
          if (discardRunId != null) {
            await applyNativeDiscardChanges(
              upserts: upserts,
              deletedIds: deletedIds,
              runId: discardRunId,
              requestIds: selectionBatch.discardRequestIds,
              allRequests: selectionBatch.discardAllRequests,
            );
          } else {
            await applySelectionChanges(
              upserts: upserts,
              deletedIds: deletedIds,
              selectionEvents: selections,
            );
          }
        } catch (_) {
          _selectionBlocked = true;
          rethrow;
        }
        _selectionBlocked = false;
        _pendingSelectionBatches.remove(selectionBatch);
      } else if (upserts.isNotEmpty || deletedIds.isNotEmpty) {
        await applyChanges(upserts: upserts, deletedIds: deletedIds);
      }
      // Keep the last durable cache intact until the complete write has
      // succeeded, so failed changes are still retried by the next flush.
      for (final id in deletedIds) {
        _saved.remove(id);
      }
      _saved.addAll(savedUpdates);
      // Callers outside the notifier may supply a mutable List. Its
      // identity alone never proves that its contents stayed unchanged.
      _savedSnapshot = items is ChunkedList<DownloadItem> ? items : null;
    });
    // The writer stays usable after failure, but external-app handoffs must
    // know whether their snapshot actually reached disk before opening a URL.
    _write = write.catchError((Object error, StackTrace stack) {
      if (selectionBatch != null) _selectionBlocked = true;
      onError(error);
    });
    return requireDurable ? write : _write;
  }
}
