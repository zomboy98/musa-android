import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reattached saved playback verifies using the active consumer',
    () async {
      final root = await Directory.systemTemp.createTemp('saved-reattach-');
      addTearDown(() => root.delete(recursive: true));
      const track = Track(
        id: 'saved',
        source: 'spotify',
        name: 'A',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final started = Completer<void>();
      final challenge = Completer<void>();
      var transfers = 0;
      var verifications = 0;
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => true,
        preparerFactoryWithVerification: (track, verify) =>
            TemporaryTrackPreparer.platform(
              stagingRoot: Directory(p.join(root.path, 'staging')),
              payload: (dir, id) => DownloadRequestPayload(
                trackName: track.name,
                artistName: '',
                albumName: '',
                outputDir: dir.path,
                filenameFormat: 'track',
                itemId: id,
              ),
              acquireDirectory: (_) async => 'scope',
              releaseDirectory: (_) async {},
              transfer: (request) async {
                transfers++;
                if (transfers == 1) {
                  started.complete();
                  await challenge.future;
                  return {
                    'success': false,
                    'error_type': 'verification_required',
                    'service': 'provider',
                  };
                }
                final file = File(p.join(request.outputDir, 'source'));
                await file.writeAsString('audio');
                return {'success': true, 'file_path': file.path};
              },
              verify: verify,
              cancelTransfer: (_) async {},
              codec: (_) async => 'aac',
              validate: (_) async => true,
            ),
      );
      playback.verifyExtension = (_, _) async {
        verifications++;
        return true;
      };
      final first = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await started.future;
      await playback.cancel(track);
      expect(await first, isA<CatalogPlaybackException>());
      final second = playback.acquire(track);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      challenge.complete();
      final lease = await second;
      expect(verifications, 1);
      expect(transfers, 2);
      await lease.release();
    },
  );

  test('cancelled playback cannot start late verification', () async {
    final consumer = Completer<void>()..complete();
    final task = Completer<void>();
    var opened = false;
    final result = await runCatalogVerification(
      extensionId: 'provider',
      consumerCancellation: consumer,
      taskCancellation: task.future,
      verify: (_, _) async {
        opened = true;
        return true;
      },
    );
    expect(result, isFalse);
    expect(opened, isFalse);
    expect(task.isCompleted, isFalse);
  });

  test('cancelling playback stops only its verification waiter', () async {
    final consumer = Completer<void>();
    final task = Completer<void>();
    final started = Completer<void>();
    final signalReceived = Completer<void>();
    final result = runCatalogVerification(
      extensionId: 'provider',
      consumerCancellation: consumer,
      taskCancellation: task.future,
      verify: (_, signal) async {
        started.complete();
        await signal;
        signalReceived.complete();
        return false;
      },
    );
    await started.future;
    consumer.complete();
    expect(await result, isFalse);
    await signalReceived.future;
    expect(task.isCompleted, isFalse);
  });

  test('late cancellation does not cancel a restarted preparation', () async {
    final root = await Directory.systemTemp.createTemp('cancel-restart-');
    addTearDown(() => root.delete(recursive: true));
    const track = Track(
      id: 'a',
      source: 'spotify',
      name: 'A',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 1,
    );
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: Directory(p.join(root.path, 'library')),
    );
    await store.initialize();
    final oldStarted = Completer<void>();
    final oldFinish = Completer<void>();
    final newStarted = Completer<void>();
    final newFinish = Completer<void>();
    final cancelLookup = Completer<bool>();
    var blockLookup = false;
    var cancelledNew = false;
    var count = 0;
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) {
        if (blockLookup) {
          blockLookup = false;
          return cancelLookup.future;
        }
        return Future.value(false);
      },
      preparerFactory: (_) {
        final number = ++count;
        return TemporaryTrackPreparer(
          stagingRoot: Directory(p.join(root.path, 'staging')),
          download: (directory, _) async {
            if (number == 1) {
              oldStarted.complete();
              await oldFinish.future;
              throw StateError('old download finished');
            }
            newStarted.complete();
            await newFinish.future;
            final file = File(p.join(directory.path, 'input'));
            await file.writeAsBytes([1]);
            return file;
          },
          cancelDownload: (_) async {
            if (number == 2) cancelledNew = true;
          },
          codec: (_) async => 'aac',
          validate: (_) async => true,
        );
      },
    );
    final first = playback
        .acquire(track)
        .then<Object>((v) => v, onError: (Object e) => e);
    await oldStarted.future;
    blockLookup = true;
    final cancellation = playback.cancel(track);
    oldFinish.complete();
    expect(await first, isA<CatalogPlaybackException>());
    final second = playback
        .acquire(track)
        .then<Object>((v) => v, onError: (Object e) => e);
    await newStarted.future;
    cancelLookup.complete(false);
    await cancellation;
    expect(cancelledNew, isFalse);
    newFinish.complete();
    final result = await second;
    expect(result, isA<CatalogAudioLease>());
    if (result is CatalogAudioLease) await result.release();
  });
}
