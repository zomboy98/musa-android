import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/temporary_track_preparer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => ProviderRequestGate.instance = ProviderRequestGate());
  test(
    'settings change during preparation keeps each profile isolated',
    () async {
      final root = await Directory.systemTemp.createTemp('musa-bitrate-race-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      const track = Track(
        id: 'race',
        source: 'spotify',
        name: 'Race',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      final firstStarted = Completer<void>();
      final firstFinish = Completer<void>();
      var downloads = 0;
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            final number = ++downloads;
            if (number == 1) {
              firstStarted.complete();
              await firstFinish.future;
            }
            return File('${dir.path}/input').writeAsString('copy-$number');
          },
          cancelDownload: (_) async {},
          codec: (_) async => 'aac', container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      );
      final first = playback.acquire(track);
      await firstStarted.future;
      playback.playbackBitrateKbps = 256;
      final secondPending = playback.acquire(track);
      firstFinish.complete();
      final original = await first;
      final second = await secondPending;
      expect(
        original.id,
        jsonEncode([
          'catalog-audio-v5',
          playback.key(track),
          128,
          'LOSSLESS',
          '',
          true,
        ]),
      );
      expect(
        second.id,
        jsonEncode([
          'catalog-audio-v5',
          playback.key(track),
          256,
          'LOSSLESS',
          '',
          true,
        ]),
      );
      expect(original.path, isNot(second.path));
      playback.selectLease(track, original);
      expect(await playback.promote(track), isFalse);
      expect(await store.lookup(playback.key(track)), isNull);
      expect(await File(original.path).readAsString(), 'copy-1');
      expect(await File(second.path).exists(), isTrue);
      await original.release();
      await second.release();
      final restarted = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await restarted.initialize();
      expect(await restarted.lookup(playback.key(track)), isNull);
      expect(await restarted.lookup(original.id), isNotNull);
      expect(await restarted.lookup(second.id), isNotNull);
    },
  );
}
