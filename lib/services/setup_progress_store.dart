import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists the first-run setup draft so an interrupted setup can resume.
class SetupProgressStore {
  SetupProgressStore() : _prefs = SharedPreferences.getInstance() {
    // Capture this instance's generation as soon as its preferences load.
    _coordinator;
  }

  static const _progressKey = 'setup_progress_v1';

  final Future<SharedPreferences> _prefs;
  static final _coordinators = Expando<_DraftCoordinator>();
  late final Future<_DraftCoordinator> _coordinator = _prefs.then((prefs) {
    final coordinator = _coordinators[prefs] ??= _DraftCoordinator();
    _generation = coordinator.generation;
    return coordinator;
  });
  late int _generation;

  /// The stored draft as raw JSON text, or null when none was saved.
  Future<String?> readDraft() async => (await _prefs).getString(_progressKey);

  Future<void> writeDraft(Map<String, Object?> draft) async {
    final encoded = jsonEncode(draft);
    final coordinator = await _coordinator;
    if (!coordinator.validGenerations.contains(_generation)) return;
    return coordinator.enqueue(() async {
      if (!await (await _prefs).setString(_progressKey, encoded)) {
        throw StateError('Could not save setup progress');
      }
    });
  }

  Future<void> clear() async {
    final coordinator = await _coordinator;
    final previousGenerations = Set<int>.of(coordinator.validGenerations);
    final generation = ++coordinator.generation;
    coordinator.validGenerations = {generation};
    return coordinator.enqueue(() async {
      try {
        if (!await (await _prefs).remove(_progressKey)) {
          throw StateError('Could not clear setup progress');
        }
      } catch (_) {
        if (coordinator.generation == generation) {
          coordinator.validGenerations.addAll(previousGenerations);
        }
        rethrow;
      }
    });
  }
}

class _DraftCoordinator {
  Future<void> _operations = Future.value();
  int generation = 0;
  Set<int> validGenerations = {0};

  Future<void> enqueue(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
