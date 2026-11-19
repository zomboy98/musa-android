import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const track = Track(id: 'unverified', source: 'spotify', name: 'Track', artistName: 'Artist', albumName: 'Album', duration: 1);

  test('saved reference does not promote temporary without download evidence', () async {
    final root = await Directory.systemTemp.createTemp('catalog-save-match-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(cacheDirectory: Directory('${root.path}/cache'), libraryDirectory: Directory('${root.path}/library'));
    await store.initialize();
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => true,
      preparerFactory: (_) => TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/stage'),
        download: (dir, _) => File('${dir.path}/source').writeAsString('audio'),
        cancelDownload: (_) async {},
        codec: (_) async => 'aac',
        container: (_) async => 'mp4',
        validate: (_) async => true,
      ),
    );
    final lease = await playback.acquire(track);
    expect(await File(lease.path).readAsString(), 'audio');
    expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
    expect(await playback.promote(track), isFalse);
    await lease.release();
  });

  test('saving does not wait for in-flight playback preparation', () async {
    final root = await Directory.systemTemp.createTemp('catalog-save-inflight-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(cacheDirectory: Directory('${root.path}/cache'), libraryDirectory: Directory('${root.path}/library'));
    await store.initialize();
    final started = Completer<void>();
    final finish = Completer<void>();
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
      preparerFactory: (_) => TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/stage'),
        download: (dir, _) async {
          started.complete();
          await finish.future;
          return File('${dir.path}/source').writeAsString('playing');
        },
        cancelDownload: (_) async {},
        codec: (_) async => 'aac',
        container: (_) async => 'mp4',
        validate: (_) async => true,
      ),
    );
    final acquiring = playback.acquire(track);
    await started.future;
    expect(playback.pendingSavedPromotion(track), isNull);
    expect(await playback.promote(track).timeout(const Duration(seconds: 2)), isFalse);
    finish.complete();
    final lease = await acquiring;
    expect(await File(lease.path).readAsString(), 'playing');
    await lease.release();
  });

  test('store refuses permanent publication when save is withdrawn during copy', () async {
    final root = await Directory.systemTemp.createTemp('catalog-store-save-race-');
    addTearDown(() => root.delete(recursive: true));
    final copying = Completer<void>();
    final resume = Completer<void>();
    var current = true;
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
      copyFile: (source, destination) async {
        if (destination.contains('${Platform.pathSeparator}library${Platform.pathSeparator}')) {
          copying.complete();
          await resume.future;
        }
        final output = File(destination).openWrite();
        await output.addStream(source.openRead());
        await output.close();
        return File(destination);
      },
    );
    await store.initialize();
    final input = await File('${root.path}/source').writeAsString('original');
    await store.putTemporary('variant', input, extension: '.m4a');
    final lease = (await store.acquire('variant'))!;
    final promotion = store.promoteVariant('saved', 'variant', canPublish: () async => current);
    await copying.future.timeout(const Duration(seconds: 5));
    current = false;
    resume.complete();
    expect(await promotion, isNull);
    expect(await store.lookup('saved'), isNull);
    expect(await File(lease.path).readAsString(), 'original');
    await lease.release();
  });
}
