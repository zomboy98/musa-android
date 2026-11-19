import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = Track(
    id: '1',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 120,
    source: 'spotify',
    isrc: 'USAAA1234567',
  );
  const second = Track(
    id: '2',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 120,
    source: 'tidal',
    isrc: 'USAAA1234567',
  );

  test(
    'cleanup preserves matching saved audio and stops on corrupt references',
    () async {
      final root = await Directory.systemTemp.createTemp('catalog-retention-');
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previous;
        await root.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({});
      final playback = CatalogPlayback();
      final store = await playback.store;
      final input = File('${root.path}/input.opus');
      await input.writeAsBytes([1, 2, 3]);
      final original = await store.putTemporary(playback.key(first), input);
      SharedPreferences.setMockInitialValues({
        SavedLibraryTracksNotifier.storageKey: 'bad',
      });
      await expectLater(playback.clearTemporary(), throwsFormatException);
      expect(await File(original.path).exists(), isTrue);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        SavedLibraryTracksNotifier.storageKey,
        '[${_trackJson(second)}]',
      );
      await playback.clearTemporary();
      final retained = await store.lookup(playback.key(first));
      expect(retained?.persistent, isTrue);
      expect(await File(retained!.path).exists(), isTrue);
    },
  );
}

String _trackJson(Track track) => jsonEncode(track.toJson());
