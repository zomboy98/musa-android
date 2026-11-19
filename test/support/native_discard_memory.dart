class NativeDiscardMemory {
  final Map<String, Map<String, dynamic>> rows = {};
  final Map<String, Set<String>> _ids = {};
  final Set<String> _all = {};

  Future<void> apply({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
    required String runId,
    required Set<String> requestIds,
    required bool allRequests,
  }) async {
    for (final id in deletedIds) {
      rows.remove(id);
    }
    for (final row in upserts) {
      rows[row['id'] as String] = Map.of(row);
    }
    if (allRequests) _all.add(runId);
    (_ids[runId] ??= {}).addAll(requestIds);
  }

  Future<({bool allRequests, Set<String> requestIds})> load(
    String runId,
  ) async => (
    allRequests: _all.contains(runId),
    requestIds: Set.of(_ids[runId] ?? const <String>{}),
  );

  Future<void> ack(
    String runId, {
    required Set<String> requestIds,
    required bool allRequests,
  }) async {
    if (allRequests) _all.remove(runId);
    _ids[runId]?.removeAll(requestIds);
  }
}
