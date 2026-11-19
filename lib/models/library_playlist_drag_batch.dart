import 'package:mornye/models/unified_library_item.dart';

/// One gesture owns one authoritative snapshot, shared by feedback and drop.
class LibraryPlaylistDragBatch {
  Future<LibraryPlaylistDragResult>? _result;
  Object? _selectionToken;
  List<String> _selectedIds = const [];
  Set<String>? _selectedIdSet;

  bool containsId(String id) =>
      (_selectedIdSet ??= Set.unmodifiable(_selectedIds)).contains(id);

  Future<LibraryPlaylistDragResult> get result => _result!;

  void freeze(
    Iterable<String> selectedIds,
    Future<List<UnifiedLibraryItem>> Function(List<String>) load, {
    Object? selectionToken,
  }) {
    if (_result != null) return;
    final ids = List<String>.unmodifiable(selectedIds);
    _selectedIds = ids;
    _selectedIdSet = null;
    _selectionToken = selectionToken;
    _result = _load(ids, load);
  }

  /// A newer selection or gesture owns the UI even when it has identical IDs.
  bool ownsSelection(Object token, Set<String> selectedIds) =>
      identical(_selectionToken, token) &&
      _selectedIds.length == selectedIds.length &&
      _selectedIds.every(selectedIds.contains);

  static Future<LibraryPlaylistDragResult> _load(
    List<String> ids,
    Future<List<UnifiedLibraryItem>> Function(List<String>) load,
  ) async {
    try {
      final loaded = await load(ids);
      final byId = {for (final item in loaded) item.id: item};
      // A removed song invalidates the whole gesture; never silently add a
      // smaller batch than the user selected. Do not deduplicate by ISRC/title.
      if (ids.any((id) => !byId.containsKey(id))) {
        return const LibraryPlaylistDragResult.failed();
      }
      return LibraryPlaylistDragResult([for (final id in ids) byId[id]!]);
    } catch (_) {
      return const LibraryPlaylistDragResult.failed();
    }
  }
}

class LibraryPlaylistDragResult {
  LibraryPlaylistDragResult(List<UnifiedLibraryItem> items)
    : items = List.unmodifiable(items),
      failed = false;

  const LibraryPlaylistDragResult.failed() : items = const [], failed = true;

  final List<UnifiedLibraryItem> items;
  final bool failed;
}
