import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Future<String?> _fakeContainer(String _) async => 'mp4';

List<int> _box(String type, List<int> body) {
  final size = body.length + 8;
  return [
    (size >> 24) & 255,
    (size >> 16) & 255,
    (size >> 8) & 255,
    size & 255,
    ...type.codeUnits,
    ...body,
  ];
}

List<int> _ac4Mp4({
  int duration = 480000,
  bool dac4 = true,
  bool truncate = false,
  int mdatBytes = 4096,
}) {
  final mvhd = _box('mvhd', [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0xbb,
    0x80,
    (duration >> 24) & 255,
    (duration >> 16) & 255,
    (duration >> 8) & 255,
    duration & 255,
    ...List.filled(80, 0),
  ]);
  final entry = _box('ac-4', [
    ...List.filled(28, 0),
    ..._box('dac4', [1, 2, 3]),
  ]);
  final trak = _box('trak', dac4 ? entry : _box('mp4a', List.filled(28, 0)));
  final bytes = [
    ..._box('ftyp', 'isom'.codeUnits + [0, 0, 0, 0] + 'isom'.codeUnits),
    ..._box('moov', [...mvhd, ...trak]),
    ..._box('mdat', List.filled(mdatBytes, 7)),
  ];
  return truncate ? bytes.sublist(0, bytes.length - 100) : bytes;
}

Future<Object> _prepareWith(
  Directory root,
  List<int> bytes,
  String codec,
  List<List<String>> sessions,
) async {
  final service = TemporaryTrackPreparer(
    container: _fakeContainer,
    stagingRoot: root,
    download: (dir, _) async =>
        File(p.join(dir.path, 'source')).writeAsBytes(bytes),
    cancelDownload: (_) async {},
    codec: (_) async => codec,
    startSession: (args) async {
      sessions.add(args);
      return (
        id: 1,
        completed: Future.value(
          FFmpegSessionResult(returnCode: 0, logs: () async => ''),
        ),
      );
    },
  );
  try {
    final result = await service.prepare('track');
    final name = p.extension(result.file.path);
    await result.dispose();
    return name;
  } on TemporaryTrackException catch (error) {
    return error;
  }
}

void main() {
  late Directory root;
  setUp(() async {
    ProviderRequestGate.instance = ProviderRequestGate();
    root = await Directory.systemTemp.createTemp('temporary-track-test-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('startup recovery removes marked abandoned staging only', () async {
    final abandoned = await Directory(
      p.join(root.path, 'track-abandoned'),
    ).create();
    await File(
      p.join(abandoned.path, '.temporary-track-lock'),
    ).writeAsString('');
    final legacy = await Directory(p.join(root.path, 'track-legacy')).create();
    final quarantine = await Directory(
      p.join(root.path, 'track-quarantine'),
    ).create();
    await File(
      p.join(quarantine.path, '.temporary-track-lock'),
    ).writeAsString('');
    await File(
      p.join(quarantine.path, '.temporary-quarantine'),
    ).writeAsString('');
    final service = TemporaryTrackPreparer(
      container: _fakeContainer,
      stagingRoot: root,
      download: (_, _) async => throw StateError('unused'),
      cancelDownload: (_) async {},
    );
    await service.recoverAbandoned();
    expect(await abandoned.exists(), isFalse);
    expect(await legacy.exists(), isTrue);
    expect(await quarantine.exists(), isTrue);
  });

  test('marker write failure prevents starting the download', () async {
    var downloaded = false;
    final service = TemporaryTrackPreparer(
      container: _fakeContainer,
      stagingRoot: root,
      createQuarantineMarker: (_) async => throw FileSystemException('failed'),
      download: (_, _) async {
        downloaded = true;
        throw StateError('must not start');
      },
      cancelDownload: (_) async {},
    );
    await expectLater(
      service.prepare('track'),
      throwsA(isA<TemporaryTrackException>()),
    );
    expect(downloaded, isFalse);
    expect((await root.list().toList()).whereType<Directory>(), isEmpty);
  });

  for (final outcome in ['success', 'failure', 'cancel']) {
    test('platform scope is released after $outcome', () async {
      final events = <String>[];
      final started = Completer<void>();
      final gate = Completer<void>();
      final service = TemporaryTrackPreparer.platform(
        container: _fakeContainer,
        stagingRoot: root,
        payload: (dir, id) => DownloadRequestPayload(
          trackName: 'track',
          artistName: '',
          albumName: '',
          outputDir: dir.path,
          filenameFormat: 'track',
          itemId: id,
        ),
        acquireDirectory: (path) async {
          expect(p.dirname(path), root.path);
          events.add('acquire');
          return 'scope';
        },
        releaseDirectory: (token) async {
          expect(token, 'scope');
          events.add('release');
        },
        transfer: (request) async {
          events.add('transfer');
          started.complete();
          if (outcome == 'cancel') await gate.future;
          if (outcome == 'failure') return {'success': false};
          final file = File(p.join(request.outputDir, 'source'));
          await file.writeAsString('audio');
          return {
            'success': true,
            'file_path': file.path,
            'requested_quality': 'LOSSLESS',
            'resolved_quality': 'aac_160',
            'quality_fallback_used': true,
            'provider': 'soundcloud',
          };
        },
        cancelTransfer: (_) async {
          if (!gate.isCompleted) gate.complete();
        },
        codec: (_) async => 'aac',
        validate: (_) async => true,
      );
      final future = service.prepare('track');
      if (outcome == 'success') {
        final result = await future;
        expect(result.qualityMetadata, {
          'requested_quality': 'LOSSLESS',
          'resolved_quality': 'aac_160',
          'quality_fallback_used': true,
          'provider': 'soundcloud',
          'output_codec': 'aac',
          'output_decode_validated': true,
          'output_container': 'mp4',
        });
        await result.dispose();
      } else {
        final checked = expectLater(
          future,
          throwsA(isA<TemporaryTrackException>()),
        );
        if (outcome == 'cancel') {
          await started.future;
          await service.cancel('track');
        }
        await checked;
      }
      expect(events, ['acquire', 'transfer', 'release']);
    });
  }

  for (final scenario in [
    'success',
    'declined',
    'exception',
    'network',
    'missing-id',
    'retry-fails',
  ]) {
    test('temporary verification $scenario', () async {
      SharedPreferences.setMockInitialValues({});
      final bugLog = BugLog();
      var attempts = 0;
      var verifications = 0;
      final service = TemporaryTrackPreparer.platform(
        container: _fakeContainer,
        stagingRoot: root,
        bugLog: bugLog,
        payload: (dir, id) => DownloadRequestPayload(
          trackName: 'track',
          artistName: '',
          albumName: '',
          outputDir: dir.path,
          filenameFormat: 'track',
          itemId: id,
        ),
        acquireDirectory: (_) async => 'scope',
        releaseDirectory: (_) async {},
        transfer: (request) async {
          attempts++;
          if (attempts == 1 || scenario == 'retry-fails') {
            return {
              'success': false,
              'error_type': scenario == 'network'
                  ? 'network'
                  : 'verification_required',
              if (scenario != 'missing-id') 'service': 'amazon-extension',
            };
          }
          final file = File(p.join(request.outputDir, 'source'));
          await file.writeAsString('audio');
          return {
            'success': true,
            'file_path': file.path,
            'provider': 'Deezer',
          };
        },
        verify: (id, cancelled) async {
          verifications++;
          expect(id, 'amazon-extension');
          if (scenario == 'exception') throw StateError('private');
          return scenario != 'declined';
        },
        cancelTransfer: (_) async {},
        codec: (_) async => 'aac',
        validate: (_) async => true,
      );
      if (scenario == 'success') {
        final result = await service.prepare('track');
        await result.dispose();
      } else {
        await expectLater(
          service.prepare('track'),
          throwsA(isA<TemporaryTrackException>()),
        );
      }
      final frames = (await bugLog.entries())
          .where((entry) => entry['type'] == 'TemporaryPipelineOutcome')
          .map((entry) => entry['frames']!)
          .toList();
      if (scenario == 'success') {
        expect(
          frames,
          containsAll([
            'stage_verification, provider_amazon, outcome_accepted',
            'stage_download, provider_deezer, outcome_completed',
            'stage_finalization, provider_deezer, outcome_completed',
            'stage_file_access, provider_deezer, outcome_completed',
          ]),
        );
      } else if (scenario == 'exception' || scenario == 'declined') {
        expect(
          frames,
          contains('stage_verification, provider_amazon, outcome_failed'),
        );
      }
      expect(frames.join(), isNot(contains(root.path)));
      expect(frames.join(), isNot(contains('private')));
      expect(
        verifications,
        scenario == 'network' || scenario == 'missing-id' ? 0 : 1,
      );
      expect(
        attempts,
        scenario == 'success' || scenario == 'retry-fails' ? 2 : 1,
      );
    });
  }

  for (final (scenario, verifyInTime, lateResult) in [
    (
      'verification preserves the active deadline remaining for the retry',
      true,
      false,
    ),
    ('verification times out while waiting for foreground', false, false),
    (
      'successful retry is rejected after a delayed deadline callback',
      true,
      true,
    ),
  ]) {
    test(scenario, () async {
      var now = Duration.zero;
      Duration? due;
      Timer? intercepted;
      void Function()? fire;
      void advance(Duration duration) {
        now += duration;
        if (intercepted?.isActive == true && now >= due!) {
          intercepted!.cancel();
          fire!();
        }
      }

      final firstStarted = Completer<void>();
      final firstResult = Completer<Map<String, Object>>();
      final verificationStarted = Completer<void>();
      final verificationResult = Completer<bool>();
      final retryStarted = Completer<void>();
      final retryResult = Completer<Map<String, Object>>();
      final cancelled = Completer<void>();
      var transfers = 0;
      late String retryDirectory;
      final preparer = TemporaryTrackPreparer.platform(
        container: _fakeContainer,
        stagingRoot: root,
        monotonicNow: () => now,
        payload: (dir, id) => DownloadRequestPayload(
          trackName: 'fixture',
          artistName: '',
          albumName: '',
          outputDir: dir.path,
          filenameFormat: 'fixture',
          itemId: id,
        ),
        acquireDirectory: (_) async => 'scope',
        releaseDirectory: (_) async {},
        transfer: (request) {
          if (++transfers == 1) {
            firstStarted.complete();
            return firstResult.future;
          }
          retryDirectory = request.outputDir;
          retryStarted.complete();
          return retryResult.future;
        },
        verify: (_, _) {
          verificationStarted.complete();
          return verificationResult.future;
        },
        cancelTransfer: (_) async => cancelled.complete(),
        codec: (_) async => 'aac',
        validate: (_) async => true,
      );

      final preparation = runZoned(
        () => preparer.prepare('fixture'),
        zoneSpecification: ZoneSpecification(
          createTimer: (_, parent, zone, duration, callback) {
            if (duration < const Duration(minutes: 1) ||
                duration == const Duration(minutes: 5, seconds: 15)) {
              return parent.createTimer(zone, duration, callback);
            }
            due = now + duration;
            fire = () => zone.run(callback);
            return intercepted = parent.createTimer(zone, duration, () {});
          },
        ),
      );
      if (lateResult) {
        unawaited(
          preparation.then(
            (result) => result.dispose(),
            onError: (Object _) {},
          ),
        );
      }
      final outcome = expectLater(
        preparation,
        throwsA(
          isA<TemporaryTrackException>().having(
            (error) => error.reason,
            'reason',
            verifyInTime ? 'preparation timed out' : 'verification timed out',
          ),
        ),
      );
      try {
        await firstStarted.future;
        advance(const Duration(minutes: 2));
        firstResult.complete({
          'success': false,
          'error_type': 'verification_required',
          'service': 'deezer',
        });
        await verificationStarted.future;
        advance(const Duration(minutes: 2, seconds: 50));
        expect(cancelled.isCompleted, isFalse);
        if (verifyInTime) {
          verificationResult.complete(true);
          await retryStarted.future;
          advance(const Duration(seconds: 10));
          expect(cancelled.isCompleted, isFalse);
          if (lateResult) {
            // Model a suspended isolate whose completion arrives before
            // the expired timer callback is dispatched.
            now += const Duration(minutes: 3);
            final input = File(p.join(retryDirectory, 'source'));
            await input.writeAsString('fixture audio');
            retryResult.complete({'success': true, 'file_path': input.path});
          } else {
            advance(const Duration(minutes: 2, seconds: 50));
          }
        } else {
          advance(const Duration(seconds: 10));
          expect(retryStarted.isCompleted, isFalse);
        }
        await outcome;
        await cancelled.future;
        if (!lateResult) {
          expect(
            (await root.list().toList()).whereType<Directory>(),
            hasLength(1),
          );
        }
      } finally {
        intercepted?.cancel();
        if (!verificationResult.isCompleted) verificationResult.complete(true);
        if (!retryResult.isCompleted) {
          retryResult.complete({'success': false, 'error_type': 'network'});
        }
      }
      for (var i = 0; i < 100; i++) {
        if ((await root.list().toList()).whereType<Directory>().isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await root.list().toList()).whereType<Directory>(), isEmpty);
      expect(transfers, verifyInTime ? 2 : 1);
    });
  }

  test('cancelling verification does not retry the transfer', () async {
    final started = Completer<void>();
    var attempts = 0;
    final service = TemporaryTrackPreparer.platform(
      container: _fakeContainer,
      stagingRoot: root,
      payload: (dir, id) => DownloadRequestPayload(
        trackName: 'track',
        artistName: '',
        albumName: '',
        outputDir: dir.path,
        filenameFormat: 'track',
        itemId: id,
      ),
      acquireDirectory: (_) async => 'scope',
      releaseDirectory: (_) async {},
      transfer: (_) async {
        attempts++;
        return {
          'success': false,
          'error_type': 'verification_required',
          'service': 'amazon-extension',
        };
      },
      verify: (_, cancelled) async {
        started.complete();
        await cancelled;
        return false;
      },
      cancelTransfer: (_) async {},
    );
    final result = service.prepare('track');
    final checked = expectLater(
      result,
      throwsA(isA<TemporaryTrackException>()),
    );
    await started.future;
    await service.cancel('track');
    await checked;
    expect(attempts, 1);
  });

  for (final type in [
    'verification_required',
    'auth',
    'authentication_error',
    'provider_auth_failed',
    'request_auth_invalid',
    'provider_reauth_required',
    'network',
    'not_found',
    'provider_unavailable',
  ]) {
    test('provider failure category is sanitized for $type', () async {
      const secret = 'https://example.invalid/?token=private-secret';
      final service = TemporaryTrackPreparer.platform(
        container: _fakeContainer,
        stagingRoot: root,
        payload: (dir, id) => DownloadRequestPayload(
          trackName: 'track',
          artistName: '',
          albumName: '',
          outputDir: dir.path,
          filenameFormat: 'track',
          itemId: id,
        ),
        acquireDirectory: (_) async => 'scope',
        releaseDirectory: (_) async {},
        transfer: (_) async => {
          'success': false,
          'error_type': type,
          'error': secret,
        },
        cancelTransfer: (_) async {},
      );
      await expectLater(
        service.prepare('track'),
        throwsA(
          isA<TemporaryTrackException>()
              .having((error) => error.reason, 'reason', switch (type) {
                'verification_required' => 'provider intervention required',
                'provider_reauth_required' => 'provider reauth required',
                'auth' ||
                'authentication_error' ||
                'provider_auth_failed' ||
                'request_auth_invalid' => 'provider session expired',
                _ => providerFailureReasonFor(type),
              })
              .having(
                (error) => error.toString(),
                'sanitized',
                isNot(contains(secret)),
              ),
        ),
      );
    });
  }

  for (final metadata in [
    {
      'decryption': {'strategy': 'ffmpeg.mov_key', 'key': 'test-key'},
    },
    {'decryption_key': 'test-key'},
  ]) {
    for (final finalized in [true, false]) {
      test(
        'platform handles finalized=$finalized decryption metadata ${metadata.keys.first}',
        () async {
          var validated = false;
          var finalizedCalls = 0;
          final service = TemporaryTrackPreparer.platform(
            container: _fakeContainer,
            stagingRoot: root,
            payload: (dir, id) => DownloadRequestPayload(
              trackName: 'track',
              artistName: '',
              albumName: '',
              outputDir: dir.path,
              filenameFormat: 'track',
              itemId: id,
            ),
            acquireDirectory: (_) async => 'scope',
            releaseDirectory: (_) async {},
            transfer: (request) async {
              final file = File(p.join(request.outputDir, 'source'));
              await file.writeAsString('complete audio');
              return {
                'success': true,
                'file_path': file.path,
                'native_finalized': finalized,
                ...metadata,
              };
            },
            cancelTransfer: (_) async {},
            startFinalization: (args) async {
              finalizedCalls++;
              expect(args[args.indexOf('-decryption_key') + 1], 'test-key');
              await File(args[args.length - 2]).writeAsString('complete audio');
              return (
                id: 1,
                completed: Future.value(
                  FFmpegSessionResult(returnCode: 0, logs: () async => ''),
                ),
              );
            },
            codec: (_) async => 'aac',
            validate: (_) async {
              validated = true;
              return true;
            },
          );
          final result = await service.prepare('track');
          expect(validated, isTrue);
          expect(finalizedCalls, finalized ? 0 : 1);
          await result.dispose();
        },
      );
    }
  }

  for (final mode in ['ac4', 'aac', 'repair-failure']) {
    test('private finalization handles $mode before conversion', () async {
      var repairs = 0;
      late File original;
      final service = TemporaryTrackPreparer.platform(
        container: _fakeContainer,
        stagingRoot: root,
        payload: (dir, id) => DownloadRequestPayload(
          trackName: 'track',
          artistName: '',
          albumName: '',
          outputDir: dir.path,
          filenameFormat: 'track',
          itemId: id,
        ),
        acquireDirectory: (_) async => 'scope',
        releaseDirectory: (_) async {},
        transfer: (request) async {
          original = File(p.join(request.outputDir, 'source'));
          await original.writeAsString('encrypted');
          return {
            'success': true,
            'file_path': original.path,
            'decryption': {
              'strategy': 'ffmpeg.mov_key',
              'key': 'test-key',
              'output_extension': '.m4a',
            },
          };
        },
        cancelTransfer: (_) async {},
        startFinalization: (args) async {
          await File(args[args.length - 2]).writeAsString('decrypted');
          return (
            id: 1,
            completed: Future.value(
              FFmpegSessionResult(returnCode: 0, logs: () async => ''),
            ),
          );
        },
        codec: (path) async => path.endsWith('source.bin')
            ? 'aac'
            : (mode == 'aac' ? 'aac' : 'ac4'),
        repairAc4: (path, source) async {
          repairs++;
          expect(source, original.path);
          expect(await original.readAsString(), 'encrypted');
          if (mode == 'repair-failure') return {'success': false};
          await File(path).writeAsString('repaired');
          return {'success': true};
        },
        validate: (_) async => true,
      );
      if (mode == 'repair-failure') {
        await expectLater(
          service.prepare('track'),
          throwsA(
            isA<TemporaryTrackException>().having(
              (e) => e.reason,
              'reason',
              'AC-4 repair failed',
            ),
          ),
        );
      } else {
        final result = await service.prepare('track');
        expect(
          await result.file.readAsString(),
          mode == 'ac4' ? 'repaired' : 'decrypted',
        );
        await result.dispose();
      }
      expect(repairs, mode == 'aac' ? 0 : 1);
      expect((await root.list().toList()).whereType<Directory>(), isEmpty);
    });
  }

  test(
    'lost finalization callback times out while staging stays locked',
    () async {
      final completion = Completer<FFmpegSessionResult>();
      final started = Completer<void>();
      var cancelled = false;
      final service = TemporaryTrackPreparer.platform(
        container: _fakeContainer,
        stagingRoot: root,
        timeout: const Duration(milliseconds: 100),
        payload: (dir, id) => DownloadRequestPayload(
          trackName: 'track',
          artistName: '',
          albumName: '',
          outputDir: dir.path,
          filenameFormat: 'track',
          itemId: id,
        ),
        acquireDirectory: (_) async => 'scope',
        releaseDirectory: (_) async {},
        transfer: (request) async {
          final source = File(p.join(request.outputDir, 'source'));
          await source.writeAsString('encrypted');
          return {
            'success': true,
            'file_path': source.path,
            'decryption_key': 'test-key',
          };
        },
        cancelTransfer: (_) async {},
        startFinalization: (_) async {
          started.complete();
          return (id: 77, completed: completion.future);
        },
        cancelFinalization: (id) async {
          cancelled = true;
        },
      );
      final future = service.prepare('track');
      final checked = expectLater(
        future,
        throwsA(
          isA<TemporaryTrackException>().having(
            (e) => e.reason,
            'reason',
            'preparation timed out',
          ),
        ),
      );
      await started.future;
      await checked;
      expect(cancelled, isTrue);
      expect((await root.list().toList()).whereType<Directory>(), hasLength(1));
      await service.recoverAbandoned();
      expect((await root.list().toList()).whereType<Directory>(), hasLength(1));
      completion.complete(
        FFmpegSessionResult(returnCode: 1, logs: () async => ''),
      );
      for (var i = 0; i < 100; i++) {
        if ((await root.list().toList()).whereType<Directory>().isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await root.list().toList()).whereType<Directory>(), isEmpty);
    },
  );

  for (final finalization in [true, false]) {
    test(
      'cancel failure during gated start retains staging: $finalization',
      () async {
        final startEntered = Completer<void>();
        final startGate = Completer<void>();
        final cancelAttempted = Completer<void>();
        final completed = Completer<FFmpegSessionResult>();
        Future<({int id, Future<FFmpegSessionResult> completed})> start(
          List<String> _,
        ) async {
          startEntered.complete();
          await startGate.future;
          return (id: 91, completed: completed.future);
        }

        Future<void> cancelSession(int id) async {
          expect(id, 91);
          cancelAttempted.complete();
          throw StateError('cancel failed');
        }

        final service = finalization
            ? TemporaryTrackPreparer.platform(
                container: _fakeContainer,
                stagingRoot: root,
                timeout: const Duration(milliseconds: 300),
                payload: (dir, id) => DownloadRequestPayload(
                  trackName: 'track',
                  artistName: '',
                  albumName: '',
                  outputDir: dir.path,
                  filenameFormat: 'track',
                  itemId: id,
                ),
                acquireDirectory: (_) async => 'scope',
                releaseDirectory: (_) async {},
                transfer: (request) async {
                  final source = File(p.join(request.outputDir, 'source'));
                  await source.writeAsString('encrypted');
                  return {
                    'success': true,
                    'file_path': source.path,
                    'decryption_key': 'test-key',
                  };
                },
                cancelTransfer: (_) async {},
                startFinalization: start,
                cancelFinalization: cancelSession,
              )
            : TemporaryTrackPreparer(
                container: _fakeContainer,
                stagingRoot: root,
                timeout: const Duration(milliseconds: 300),
                download: (dir, _) =>
                    File(p.join(dir.path, 'source')).writeAsString('audio'),
                cancelDownload: (_) async {},
                codec: (_) async => 'aac',
                startSession: start,
                cancelSession: cancelSession,
              );
        final visible = expectLater(
          service.prepare('track'),
          throwsA(isA<TemporaryTrackException>()),
        );
        await startEntered.future;
        await service.cancel('track');
        startGate.complete();
        await cancelAttempted.future;
        await visible;
        final dirs = (await root.list().toList())
            .whereType<Directory>()
            .toList();
        expect(dirs, hasLength(1));
        expect(
          await File(
            p.join(dirs.single.path, '.temporary-quarantine'),
          ).exists(),
          isTrue,
        );
        await service.recoverAbandoned();
        expect(await dirs.single.exists(), isTrue);
        completed.complete(
          FFmpegSessionResult(returnCode: 1, logs: () async => ''),
        );
        for (var i = 0; i < 100 && await dirs.single.exists(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await dirs.single.exists(), isFalse);
      },
    );
  }

  test(
    'hung cancellation returns while session retains staging until completion',
    () async {
      final started = Completer<void>();
      final cancellation = Completer<void>();
      final completed = Completer<FFmpegSessionResult>();
      final service = TemporaryTrackPreparer(
        container: _fakeContainer,
        stagingRoot: root,
        download: (dir, _) =>
            File(p.join(dir.path, 'source')).writeAsString('audio'),
        cancelDownload: (_) async {},
        codec: (_) async => 'aac',
        startSession: (_) async {
          started.complete();
          return (id: 91, completed: completed.future);
        },
        cancelSession: (_) => cancellation.future,
      );
      final visible = expectLater(
        service.prepare('track'),
        throwsA(isA<TemporaryTrackException>()),
      );
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.cancel('track').timeout(const Duration(seconds: 4));
      await visible;
      final dir = (await root.list().toList()).whereType<Directory>().single;
      expect(
        await File(p.join(dir.path, '.temporary-quarantine')).exists(),
        isTrue,
      );
      await service.recoverAbandoned();
      expect(await dir.exists(), isTrue);
      cancellation.completeError(StateError('late private error'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await dir.exists(), isTrue);
      completed.complete(
        FFmpegSessionResult(returnCode: 1, logs: () async => ''),
      );
      for (var i = 0; i < 100 && await dir.exists(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await dir.exists(), isFalse);
    },
  );

  test(
    'synchronous cancellation errors do not prevent other cancellation',
    () async {
      final started = Completer<void>();
      final completed = Completer<FFmpegSessionResult>();
      var sessionCancelCalled = false;
      final service = TemporaryTrackPreparer(
        container: _fakeContainer,
        stagingRoot: root,
        download: (dir, _) =>
            File(p.join(dir.path, 'source')).writeAsString('audio'),
        cancelDownload: (_) => throw StateError('private transfer error'),
        codec: (_) async => 'aac',
        startSession: (_) async {
          started.complete();
          return (id: 91, completed: completed.future);
        },
        cancelSession: (_) {
          sessionCancelCalled = true;
          throw StateError('private session error');
        },
      );
      final visible = expectLater(
        service.prepare('track'),
        throwsA(isA<TemporaryTrackException>()),
      );
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.cancel('track');
      expect(sessionCancelCalled, isTrue);
      final dir = (await root.list().toList()).whereType<Directory>().single;
      expect(await dir.exists(), isTrue);
      completed.complete(
        FFmpegSessionResult(returnCode: 1, logs: () async => ''),
      );
      await visible;
      expect(await dir.exists(), isFalse);
    },
  );

  test('platform rejects invalid finalized decryption metadata', () async {
    final service = TemporaryTrackPreparer.platform(
      container: _fakeContainer,
      stagingRoot: root,
      payload: (dir, id) => DownloadRequestPayload(
        trackName: 'track',
        artistName: '',
        albumName: '',
        outputDir: dir.path,
        filenameFormat: 'track',
        itemId: id,
      ),
      acquireDirectory: (_) async => 'scope',
      releaseDirectory: (_) async {},
      transfer: (request) async {
        final file = File(p.join(request.outputDir, 'source'));
        await file.writeAsString('audio');
        return {
          'success': true,
          'file_path': file.path,
          'native_finalized': true,
          'decryption': {'strategy': 'unsupported', 'key': 'test-key'},
        };
      },
      cancelTransfer: (_) async {},
    );
    await expectLater(
      service.prepare('track'),
      throwsA(isA<TemporaryTrackException>()),
    );
  });

  for (final mode in [
    'failure',
    'cancel',
    'hostile-path',
    'hostile-extension',
    'hostile-token',
    'hostile-format',
  ]) {
    test('pending finalization rejects $mode and removes staging', () async {
      final started = Completer<void>();
      final completed = Completer<FFmpegSessionResult>();
      final diagnostics = <String>[];
      final outside = File(p.join(root.path, 'outside'));
      await outside.writeAsString('outside remains');
      var cancelled = false;
      final service = TemporaryTrackPreparer.platform(
        container: _fakeContainer,
        stagingRoot: Directory(p.join(root.path, 'staging')),
        payload: (dir, id) => DownloadRequestPayload(
          trackName: 'track',
          artistName: '',
          albumName: '',
          outputDir: dir.path,
          filenameFormat: 'track',
          itemId: id,
        ),
        acquireDirectory: (_) async => 'scope',
        releaseDirectory: (_) async {},
        transfer: (request) async {
          final input = mode == 'hostile-path'
              ? outside
              : File(p.join(request.outputDir, 'source'));
          if (mode != 'hostile-path') await input.writeAsString('encrypted');
          return {
            'success': true,
            'file_path': input.path,
            'native_finalized': false,
            'decryption': {
              'strategy': 'ffmpeg.mov_key',
              'key': mode == 'hostile-token'
                  ? 'private-key" -i https://secret.invalid'
                  : 'private-key',
              'input_format': mode == 'hostile-format'
                  ? 'mov -i https://secret.invalid'
                  : 'mov',
              'output_extension': mode == 'hostile-extension'
                  ? '../../outside'
                  : '.flac',
            },
          };
        },
        cancelTransfer: (_) async {},
        startFinalization: (args) async {
          if (!started.isCompleted) started.complete();
          if (mode == 'failure') {
            return (
              id: 42,
              completed: Future.value(
                FFmpegSessionResult(
                  returnCode: 1,
                  logs: () async => 'private-key https://secret.invalid',
                ),
              ),
            );
          }
          return (id: 42, completed: completed.future);
        },
        cancelFinalization: (id) async {
          expect(id, 42);
          cancelled = true;
          if (!completed.isCompleted) {
            completed.complete(
              FFmpegSessionResult(
                returnCode: 1,
                logs: () async => 'private-key',
              ),
            );
          }
        },
        diagnostic: diagnostics.add,
      );
      final future = service.prepare('track');
      final checked = expectLater(
        future,
        throwsA(isA<TemporaryTrackException>()),
      );
      if (mode == 'cancel') {
        await started.future;
        await service.cancel('track');
      }
      await checked;
      if (mode == 'cancel') expect(cancelled, isTrue);
      expect(await outside.readAsString(), 'outside remains');
      expect(diagnostics.join(), isNot(contains('private-key')));
      expect(diagnostics.join(), isNot(contains('secret.invalid')));
      final staging = Directory(p.join(root.path, 'staging'));
      expect((await staging.list().toList()).whereType<Directory>(), isEmpty);
    });
  }

  test('rejects a finalizer output symlink outside staging', () async {
    final outside = File(p.join(root.path, 'outside.flac'));
    await outside.writeAsString('external');
    final probe = Link(p.join(root.path, 'symlink-probe'));
    try {
      await probe.create(outside.path);
      await probe.delete();
    } on FileSystemException {
      // Windows may not grant the test process permission to create symlinks.
      return;
    }
    final service = TemporaryTrackPreparer.platform(
      container: _fakeContainer,
      stagingRoot: Directory(p.join(root.path, 'staging')),
      payload: (dir, id) => DownloadRequestPayload(
        trackName: 'track',
        artistName: '',
        albumName: '',
        outputDir: dir.path,
        filenameFormat: 'track',
        itemId: id,
      ),
      acquireDirectory: (_) async => 'scope',
      releaseDirectory: (_) async {},
      transfer: (request) async {
        final input = File(p.join(request.outputDir, 'source'));
        await input.writeAsString('encrypted');
        return {
          'success': true,
          'file_path': input.path,
          'decryption_key': 'test-key',
        };
      },
      cancelTransfer: (_) async {},
      startFinalization: (args) async {
        final path = args[args.length - 2];
        await File(path).delete();
        await Link(path).create(outside.path);
        return (
          id: 1,
          completed: Future.value(
            FFmpegSessionResult(returnCode: 0, logs: () async => ''),
          ),
        );
      },
    );
    await expectLater(
      service.prepare('track'),
      throwsA(isA<TemporaryTrackException>()),
    );
    expect(await outside.readAsString(), 'external');
  });

  test('request diagnostics expose only fixed labels', () async {
    SharedPreferences.setMockInitialValues({});
    final diagnostics = <String>[];
    final service = TemporaryTrackPreparer.platform(
      container: _fakeContainer,
      stagingRoot: root,
      payload: (dir, id) => DownloadRequestPayload(
        trackName: 'Hidden Title (from Hidden Album)',
        artistName: 'Hidden One, Hidden Two',
        albumName: '',
        isrc: 'us-at2-26-07218',
        service: 'tidal',
        source: 'deezer',
        deezerId: '987654321',
        outputDir: dir.path,
        filenameFormat: '{title}',
        itemId: id,
      ),
      acquireDirectory: (_) async => 'scope',
      releaseDirectory: (_) async {},
      transfer: (_) async => {'success': false},
      cancelTransfer: (_) async {},
      diagnostic: diagnostics.add,
      bugLog: BugLog(),
    );
    await expectLater(
      service.prepare('track'),
      throwsA(isA<TemporaryTrackException>()),
    );
    final line = diagnostics.singleWhere(
      (entry) => entry.startsWith('stage=request'),
    );
    expect(line, contains('source=deezer service=tidal'));
    expect(
      line,
      contains(
        'provider_track_id=empty deezer_id=present tidal_id=empty '
        'qobuz_id=empty spotify_id=empty isrc=hyphenated '
        'title_annotated=true artists=2',
      ),
    );
    expect(line, isNot(contains('Hidden')));
    expect(line, isNot(contains('987654321')));
    expect(line.toLowerCase(), isNot(contains('us-at2')));
  });

  test('provider diagnostics contain only safe states', () async {
    const secret = 'secret-key-url-song-user-credential';
    SharedPreferences.setMockInitialValues({});
    final bugLog = BugLog();
    final diagnostics = <String>[];
    final service = TemporaryTrackPreparer.platform(
      container: _fakeContainer,
      stagingRoot: root,
      payload: (dir, id) => DownloadRequestPayload(
        trackName: secret,
        artistName: secret,
        albumName: secret,
        service: secret,
        downloadProvider: 'tidal',
        coverUrl: 'https://example.invalid/$secret',
        outputDir: dir.path,
        filenameFormat: secret,
        itemId: id,
      ),
      acquireDirectory: (_) async => secret,
      releaseDirectory: (_) async {},
      transfer: (request) async => {
        'success': true,
        'file_path': '${request.outputDir}/$secret',
        'service': secret,
        'native_finalized': false,
        'decryption': {'strategy': secret, 'key': secret},
        'error': secret,
        'error_type': secret,
      },
      cancelTransfer: (_) async {},
      diagnostic: diagnostics.add,
      bugLog: bugLog,
    );
    await expectLater(
      service.prepare(secret),
      throwsA(isA<TemporaryTrackException>()),
    );
    expect(diagnostics, hasLength(2));
    expect(diagnostics.join(), isNot(contains(secret)));
    final providerResult = diagnostics.singleWhere(
      (line) => line.startsWith('stage=provider_result'),
    );
    expect(providerResult, contains('requested_provider=tidal'));
    expect(providerResult, contains('result_service=unknown'));
    expect(providerResult, contains('native_finalized=false'));
    expect(providerResult, contains('structured_metadata=true'));
    expect(providerResult, contains('metadata_rejected=true'));
    expect(providerResult, contains('error_type=unknown'));
    expect(providerResult, contains('reason=encrypted_output_unsupported'));
    final entries = await bugLog.entries();
    expect(entries.toString(), isNot(contains(secret)));
    expect(
      entries.singleWhere(
        (row) => row['type'] == 'TemporaryPipelineOutcome',
      )['frames'],
      'stage_finalization, provider_unknown, outcome_failed',
    );
    entries.removeWhere((row) => row['type'] == 'TemporaryPipelineOutcome');
    expect(entries, hasLength(1));
    expect(entries.single['type'], 'TemporaryTrackProviderFailure');
    expect(entries.single['frames'], contains('provider_tidal'));
    expect(entries.single['frames'], contains('finalized_false'));
    expect(entries.single['frames'], contains('rejected_true'));
    expect(entries.single['frames'], contains('stage_provider_result'));
    expect(entries.single['frames'], contains('error_type_unknown'));
    expect(
      entries.single['frames'],
      contains('reason_encrypted_output_unsupported'),
    );
  });

  for (final type in [
    'verification_required',
    'provider_unavailable',
    'not_found',
    'quality_unavailable',
    'network',
    'https://secret.invalid/?token=private',
  ]) {
    test(
      'provider failure diagnostics safely preserve category: $type',
      () async {
        SharedPreferences.setMockInitialValues({});
        final log = BugLog();
        final diagnostics = <String>[];
        final service = TemporaryTrackPreparer.platform(
          container: _fakeContainer,
          stagingRoot: root,
          payload: (dir, id) => DownloadRequestPayload(
            trackName: 'private song',
            artistName: 'private artist',
            albumName: 'private album',
            outputDir: dir.path,
            filenameFormat: '{title}',
            itemId: id,
          ),
          acquireDirectory: (_) async => 'private token',
          releaseDirectory: (_) async {},
          transfer: (_) async => {
            'success': false,
            'error_type': type,
            'error': 'https://secret.invalid/?token=private',
          },
          cancelTransfer: (_) async {},
          diagnostic: diagnostics.add,
          bugLog: log,
        );
        await expectLater(
          service.prepare('private track'),
          throwsA(isA<TemporaryTrackException>()),
        );
        final expected = type.startsWith('https:') ? 'unknown' : type;
        final entries = await log.entries();
        expect(
          diagnostics.singleWhere(
            (line) => line.startsWith('stage=provider_result'),
          ),
          contains('error_type=$expected'),
        );
        final stage = switch (type) {
          'verification_required' => 'verification',
          'provider_unavailable' => 'provider',
          'not_found' => 'matching',
          'quality_unavailable' => 'quality',
          _ => 'download',
        };
        final outcome = type == 'verification_required' ? 'required' : 'failed';
        expect(
          entries.singleWhere(
            (row) => row['type'] == 'TemporaryPipelineOutcome',
          )['frames'],
          'stage_$stage, provider_unknown, outcome_$outcome',
        );
        final providerFailure = entries.singleWhere(
          (row) => row['type'] == 'TemporaryTrackProviderFailure',
        );
        expect(providerFailure['frames'], contains('error_type_$expected'));
        expect(
          providerFailure['frames'],
          contains(switch (type) {
            'verification_required' => 'reason_provider_intervention_required',
            'not_found' => 'reason_provider_track_not_found',
            'provider_unavailable' => 'reason_provider_unavailable',
            'quality_unavailable' => 'reason_provider_quality_unavailable',
            'rate_limited' => 'reason_provider_rate_limited',
            'timeout' => 'reason_provider_timed_out',
            'network' => 'reason_provider_network_failed',
            _ => 'reason_provider_download_failed',
          }),
        );
        expect('${diagnostics.join()} $entries', isNot(contains('private')));
        expect(
          '${diagnostics.join()} $entries',
          isNot(contains('secret.invalid')),
        );
      },
    );
  }

  test('provider may return a file named prepared.m4a', () async {
    final service = TemporaryTrackPreparer(
      container: _fakeContainer,
      stagingRoot: root,
      download: (dir, id) =>
          File(p.join(dir.path, 'prepared.m4a')).writeAsString('source'),
      cancelDownload: (_) async {},
      codec: (_) async => 'aac',
      validate: (_) async => true,
    );
    final result = await service.prepare('track');
    expect(await result.file.readAsString(), 'source');
    await result.dispose();
  });

  test('shares a transfer and preserves verified AAC', () async {
    var downloads = 0;
    var conversions = 0;
    final gate = Completer<void>();
    final service = TemporaryTrackPreparer(
      container: _fakeContainer,
      stagingRoot: root,
      download: (dir, id) async {
        downloads++;
        await gate.future;
        return File(p.join(dir.path, 'source.flac')).writeAsString('audio');
      },
      cancelDownload: (_) async {},
      codec: (_) async => 'aac',
      validate: (_) async => true,
    );
    final a = service.prepare('track');
    final b = service.prepare('track');
    gate.complete();
    final result = await a;
    expect(identical(result, await b), isTrue);
    expect(downloads, 1);
    expect(conversions, 0);
    expect(await result.file.exists(), isTrue);
    expect(
      await File(
        p.join(p.dirname(p.dirname(result.file.path)), '.temporary-quarantine'),
      ).exists(),
      isFalse,
    );
    await result.dispose();
    expect(await result.file.exists(), isFalse);
  });

  test('rejects unidentifiable audio and deletes staging', () async {
    final service = TemporaryTrackPreparer(
      container: _fakeContainer,
      stagingRoot: root,
      download: (dir, id) =>
          File(p.join(dir.path, 'source')).writeAsString('audio'),
      cancelDownload: (_) async {},
      codec: (_) async => null,
    );
    await expectLater(
      service.prepare('track'),
      throwsA(isA<TemporaryTrackException>()),
    );
    expect((await root.list().toList()).whereType<Directory>(), isEmpty);
  });

  for (final conversionFails in [true, false]) {
    test(
      'unidentified audio is categorized without secrets: $conversionFails',
      () async {
        const secret = 'https://example.com/?token=secret';
        SharedPreferences.setMockInitialValues({});
        final log = BugLog();
        final service = TemporaryTrackPreparer(
          container: _fakeContainer,
          stagingRoot: root,
          download: (dir, _) =>
              File(p.join(dir.path, 'input')).writeAsString(secret),
          cancelDownload: (_) async {},
          codec: (_) async => null,
          bugLog: log,
        );
        await expectLater(
          service.prepare(secret),
          throwsA(
            isA<TemporaryTrackException>().having(
              (e) => e.reason,
              'category',
              'audio stream not identified',
            ),
          ),
        );
        final entries = await log.entries();
        expect(entries, isNotEmpty);
        expect(entries.toString(), isNot(contains(secret)));
        expect(entries.toString(), isNot(contains('Opus')));
        final expectedStage = 'file_access';
        expect(
          entries.singleWhere(
            (row) => row['type'] == 'TemporaryPipelineOutcome',
          )['frames'],
          'stage_$expectedStage, provider_unknown, outcome_failed',
        );
        final preparationFailure = entries.singleWhere(
          (row) => row['type'] != 'TemporaryPipelineOutcome',
        );
        expect(preparationFailure['frames'], contains('stage_preparation'));
        expect(
          preparationFailure['frames'],
          contains('reason_audio_stream_not_identified'),
        );
      },
    );
  }

  test('cancels a shared transfer and cleans staging', () async {
    final gate = Completer<void>();
    var cancellations = 0;
    final service = TemporaryTrackPreparer(
      container: _fakeContainer,
      stagingRoot: root,
      download: (dir, id) async {
        await gate.future;
        return File(p.join(dir.path, 'source')).writeAsString('audio');
      },
      cancelDownload: (_) async {
        cancellations++;
        gate.complete();
      },
      codec: (_) async => 'aac',
      validate: (_) async => true,
    );
    final future = service.prepare('track');
    final checked = expectLater(
      future,
      throwsA(isA<TemporaryTrackException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.cancel('track');
    await checked;
    expect(cancellations, 1);
    expect((await root.list().toList()).whereType<Directory>(), isEmpty);
  });

  test('ac4 valido pasa sin decodificar con ffmpeg', () async {
    final sessions = <List<String>>[];
    final outcome = await _prepareWith(root, _ac4Mp4(), 'ac4', sessions);
    expect(outcome, '.m4a');
    expect(sessions, isEmpty);
  });

  test('ac4 truncado, sin dac4 o sin duracion falla', () async {
    for (final bytes in [
      _ac4Mp4(truncate: true),
      _ac4Mp4(dac4: false),
      _ac4Mp4(duration: 0),
      _ac4Mp4(mdatBytes: 0),
      List<int>.filled(2048, 1),
    ]) {
      final sessions = <List<String>>[];
      final outcome = await _prepareWith(root, bytes, 'ac4', sessions);
      expect(outcome, isA<TemporaryTrackException>());
      expect(
        (outcome as TemporaryTrackException).reason,
        'invalid audio output',
      );
      expect(sessions, isEmpty);
    }
  });

  test('otros codecs siguen decodificando completo con ffmpeg', () async {
    final sessions = <List<String>>[];
    final outcome = await _prepareWith(root, _ac4Mp4(), 'aac', sessions);
    expect(outcome, isA<String>());
    expect(sessions, hasLength(1));
    expect(sessions.single, contains('-xerror'));
    expect(sessions.single, containsAllInOrder(['-f', 'null']));
  });
}
