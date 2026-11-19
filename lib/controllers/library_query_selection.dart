/// Resolves IDs without loading song models. The caller owns the selection
/// token and query scope, so a late result cannot replace a newer gesture.
class LibraryQuerySelection {
  Object? _scope;
  Set<String> _ids = const {};

  bool covers(Object scope, Set<String> selected) =>
      _scope == scope &&
      _ids.isNotEmpty &&
      _ids.length == selected.length &&
      _ids.every(selected.contains);

  Future<Set<String>?> resolve({
    required Object scope,
    required Future<List<String>> Function() load,
    required bool Function() isCurrent,
  }) async {
    final ids = (await load()).toSet();
    if (!isCurrent()) return null;
    _scope = scope;
    _ids = ids;
    return ids;
  }
}

/// Never dispatch an action with a partial selection after a lookup failure or
/// concurrent selection change. The loaded order is normalized to selected IDs.
Future<List<T>?> resolveLibrarySelectionItems<T>({
  required List<String> selectedIds,
  required Future<List<T>> Function() load,
  required String Function(T) idOf,
  required bool Function() isCurrent,
}) async {
  final items = await load();
  if (!isCurrent()) return null;
  final byId = {for (final item in items) idOf(item): item};
  if (!selectedIds.every(byId.containsKey)) {
    throw StateError('Could not load every selected Library song');
  }
  return [for (final id in selectedIds) byId[id]!];
}
