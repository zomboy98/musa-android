import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/library_playlist_order_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('pins and playback order survive a new provider container', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    await first.read(libraryPlaylistOrderProvider.future);
    await first.read(libraryPlaylistOrderProvider.notifier).togglePin('a');
    await first.read(libraryPlaylistOrderProvider.notifier).recordPlayback('b');
    first.dispose();
    final second = ProviderContainer();
    final restored = await second.read(libraryPlaylistOrderProvider.future);
    expect(restored.pinned, {'a'});
    expect(restored.played['b'], greaterThan(0));
    await second.read(libraryPlaylistOrderProvider.notifier).togglePin('a');
    expect(second.read(libraryPlaylistOrderProvider).requireValue.pinned, isEmpty);
    second.dispose();
  });
}
