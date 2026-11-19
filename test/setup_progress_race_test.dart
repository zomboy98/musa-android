import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/setup_progress_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The platform interface lets the test control completion of actual writes.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class DelayedStore extends SharedPreferencesStorePlatform {
  final started = Completer<void>();
  final release = Completer<void>();
  final values = <String, Object>{};
  Completer<void>? removeStarted;
  Completer<void>? releaseRemove;
  bool failRemove = false;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    removeStarted?.complete();
    await releaseRemove?.future;
    if (failRemove) return false;
    values.remove(key);
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }
}

void main() {
  test('clear waits for an in-flight write and leaves no draft', () async {
    SharedPreferences.setMockInitialValues({});
    final platform = DelayedStore();
    SharedPreferencesStorePlatform.instance = platform;
    final store = SetupProgressStore();
    final otherStore = SetupProgressStore();
    final write = store.writeDraft({'step': 4});
    await platform.started.future;
    final clear = otherStore.clear();
    final lateWrite = store.writeDraft({'step': 5});
    await Future<void>.delayed(Duration.zero);
    platform.release.complete();
    await Future.wait([write, clear, lateWrite]);
    expect(platform.values['flutter.setup_progress_v1'], isNull);

    final nextSetup = SetupProgressStore();
    await nextSetup.writeDraft({'step': 1});
    expect(platform.values['flutter.setup_progress_v1'], '{"step":1}');
  });

  test(
    'failed clear permits old instances to retry without reviving writes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final platform = DelayedStore()
        ..release.complete()
        ..removeStarted = Completer<void>()
        ..releaseRemove = Completer<void>()
        ..failRemove = true;
      SharedPreferencesStorePlatform.instance = platform;
      final first = SetupProgressStore();
      final second = SetupProgressStore();
      await first.writeDraft({'step': 1});
      await second.writeDraft({'step': 2});

      final clearing = second.clear();
      final failure = expectLater(clearing, throwsStateError);
      await platform.removeStarted!.future;
      await first.writeDraft({'step': 3});
      platform.releaseRemove!.complete();
      await failure;
      expect(platform.values['flutter.setup_progress_v1'], '{"step":2}');

      await first.writeDraft({'step': 4});
      expect(platform.values['flutter.setup_progress_v1'], '{"step":4}');
      await second.writeDraft({'step': 5});
      expect(platform.values['flutter.setup_progress_v1'], '{"step":5}');
    },
  );
}
