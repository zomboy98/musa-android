import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_playlist_order_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The platform interface is supplied transitively by shared_preferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class ControlledStore extends InMemorySharedPreferencesStore {
  ControlledStore() : super.empty();
  final writes = <Completer<bool>>[];
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    final result = Completer<bool>();
    writes.add(result);
    if (await result.future) return super.setValue(type, key, value);
    return false;
  }
}

void main() {
  test(
    'false and exception leave state unchanged and queue continues',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = ControlledStore();
      SharedPreferencesStorePlatform.instance = store;
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(libraryPlaylistOrderProvider.future);
      final n = c.read(libraryPlaylistOrderProvider.notifier);
      final first = n.togglePin('a');
      final firstCheck = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      store.writes[0].complete(false);
      await firstCheck;
      expect(c.read(libraryPlaylistOrderProvider).requireValue.pinned, isEmpty);
      final afterFalse = ProviderContainer();
      expect(
        (await afterFalse.read(libraryPlaylistOrderProvider.future)).pinned,
        isEmpty,
      );
      afterFalse.dispose();
      final second = n.recordPlayback('b');
      final secondCheck = expectLater(second, throwsA(isA<Exception>()));
      await Future<void>.delayed(Duration.zero);
      store.writes[1].completeError(Exception('disk'));
      await secondCheck;
      expect(c.read(libraryPlaylistOrderProvider).requireValue.played, isEmpty);
      final afterException = ProviderContainer();
      expect(
        (await afterException.read(libraryPlaylistOrderProvider.future)).played,
        isEmpty,
      );
      afterException.dispose();
      final third = n.togglePin('c');
      final fourth = n.recordPlayback('d');
      await Future<void>.delayed(Duration.zero);
      expect(store.writes.length, 3);
      store.writes[2].complete(true);
      await third;
      await Future<void>.delayed(Duration.zero);
      store.writes[3].complete(true);
      await fourth;
      final value = c.read(libraryPlaylistOrderProvider).requireValue;
      expect(value.pinned, {'c'});
      expect(value.played.keys, ['d']);
      final restored = ProviderContainer();
      final persisted = await restored.read(
        libraryPlaylistOrderProvider.future,
      );
      expect(persisted.pinned, {'c'});
      expect(persisted.played.keys, ['d']);
      restored.dispose();
    },
  );
}
