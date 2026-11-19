import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/setup_progress_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'clearing the setup draft leaves stored music preferences alone',
    () async {
      SharedPreferences.setMockInitialValues({
        'music_preferences_v1': '{"genres":["Rock"],"artists":[]}',
      });
      final store = SetupProgressStore();
      await store.writeDraft({'step': 1});
      expect(await store.readDraft(), isNotNull);
      await store.clear();

      final prefs = await SharedPreferences.getInstance();
      expect(await store.readDraft(), isNull);
      expect(
        prefs.getString('music_preferences_v1'),
        '{"genres":["Rock"],"artists":[]}',
      );
    },
  );
}
