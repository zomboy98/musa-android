import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:path/path.dart' as p;

// A second store object intentionally shares failed-playback protection. A new
// isolate models losing that memory; OS-process death is covered separately by
// support/catalog_audio_crash_probe.dart (the playback checkpoint).
Future<({int beforeTtl, int atTtl, List<int> bytes})> _afterMemoryRestart(
  String rootPath,
  DateTime playedAt,
  String audioPath,
) => Isolate.run(() async {
  var now = playedAt;
  final store = CatalogAudioStore(
    cacheDirectory: Directory(p.join(rootPath, 'cache')),
    libraryDirectory: Directory(p.join(rootPath, 'library')),
    clock: () => now,
  );
  await store.initialize();
  now = now.add(const Duration(days: 6));
  final beforeTtl = await store.cleanupExpired();
  final bytes = await File(audioPath).readAsBytes();
  now = now.add(const Duration(days: 1));
  final atTtl = await store.cleanupExpired();
  return (beforeTtl: beforeTtl, atTtl: atTtl, bytes: bytes);
});

void main() {
  late Directory root;
  late DateTime now;
  late File source;
  CatalogAudioStore makeStore({
    Future<void> Function(File, String)? writeManifest,
    Future<void> Function(File, DateTime)? touchFile,
  }) => CatalogAudioStore(
    cacheDirectory: Directory(p.join(root.path, 'cache')),
    libraryDirectory: Directory(p.join(root.path, 'library')),
    clock: () => now,
    writeManifest: writeManifest,
    touchFile: touchFile,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('catalog_safety_');
    now = DateTime.now().toUtc().subtract(const Duration(days: 20));
    source = File(p.join(root.path, 'source'));
    await source.writeAsBytes([1, 2, 3]);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'failed manifest survives restart using persisted playback time',
    () async {
      var fail = false;
      final store = makeStore(
        writeManifest: (file, value) async {
          if (fail) throw FileSystemException('write failed');
          await file.writeAsString(value, flush: true);
        },
      );
      await store.initialize();
      final entry = await store.putTemporary('song', source);
      now = now.add(const Duration(days: 8));
      fail = true;
      await expectLater(
        store.recordPlayback('song'),
        throwsA(isA<FileSystemException>()),
      );
      final playedAt = now;
      final sameIsolate = makeStore();
      await sameIsolate.initialize();
      now = now.add(const Duration(days: 7));
      expect(await sameIsolate.cleanupExpired(), 0);
      expect(await sameIsolate.clearTemporary(), 0);
      final restarted = await _afterMemoryRestart(
        root.path,
        playedAt,
        entry.path,
      );
      expect(restarted.beforeTtl, 0);
      expect(restarted.bytes, [1, 2, 3]);
      expect(restarted.atTtl, 1);
    },
  );

  test('failed timestamp protects the file for the current process', () async {
    final store = makeStore(
      touchFile: (_, _) async {
        throw FileSystemException('touch failed');
      },
      writeManifest: (file, value) async {
        await file.writeAsString(value, flush: true);
      },
    );
    await store.initialize();
    final entry = await store.putTemporary('song', source);
    now = now.add(const Duration(days: 8));
    await expectLater(
      store.recordPlayback('song'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await store.cleanupExpired(), 0);
    expect(await File(entry.path).exists(), isTrue);
  });

  test(
    'lease promotion saves playing bytes after variant replacement',
    () async {
      final store = makeStore();
      await store.initialize();
      await store.putTemporary('variant', source);
      final lease = (await store.acquire('variant'))!;
      await source.writeAsBytes([9, 8, 7]);
      await store.putTemporary('variant', source);
      final saved = (await store.promoteLease('song', lease))!;
      expect(await File(saved.path).readAsBytes(), [1, 2, 3]);
      await lease.release();
    },
  );

  test('promotion leaves a preexisting .part untouched', () async {
    final store = makeStore();
    await store.initialize();
    await store.putTemporary('variant', source);
    final lease = (await store.acquire('variant'))!;
    final foreign = File(p.join(root.path, 'library', '.part'));
    await foreign.writeAsBytes([42]);
    final saved = (await store.promoteLease('song', lease))!;
    expect(await File(saved.path).readAsBytes(), [1, 2, 3]);
    expect(await foreign.readAsBytes(), [42]);
    await lease.release();
  });

  test('two store instances promote without clobbering staging', () async {
    final first = makeStore();
    final second = makeStore();
    await first.initialize();
    await second.initialize();
    await first.putTemporary('one', source);
    await source.writeAsBytes([9]);
    await second.putTemporary('two', source);
    final one = (await first.acquire('one'))!;
    final two = (await second.acquire('two'))!;
    final saved = await Future.wait([
      first.promoteLease('saved-one', one),
      second.promoteLease('saved-two', two),
    ]);
    expect(await File(saved[0]!.path).readAsBytes(), [1, 2, 3]);
    expect(await File(saved[1]!.path).readAsBytes(), [9]);
    await one.release();
    await two.release();
  });

  test('older surviving manifest protects its referenced audio', () async {
    final store = makeStore();
    await store.initialize();
    final old = await store.putTemporary('song', source);
    final manifest =
        (await Directory(
              p.join(root.path, 'library'),
            ).list().where((e) => e.path.endsWith('.json')).first)
            as File;
    final contents = await manifest.readAsString();
    final path = manifest.path;
    final lease = (await store.acquire('song'))!;
    await source.writeAsBytes([8]);
    await store.putTemporary('song', source);
    await File(path).writeAsString(contents);
    await File(old.path).setLastModified(now.subtract(const Duration(days: 8)));
    // Simulate a restart with both manifests present.
    final restarted = makeStore();
    await restarted.initialize();
    expect(await restarted.clearTemporary(), 0);
    expect(await File(old.path).readAsBytes(), [1, 2, 3]);
    await lease.release();
  });

  test('recording old lease does not update replacement', () async {
    final store = makeStore();
    await store.initialize();
    final old = await store.putTemporary('song', source);
    final lease = (await store.acquire('song'))!;
    await source.writeAsBytes([8]);
    final replacement = await store.putTemporary('song', source);
    now = now.add(const Duration(days: 1));
    await store.recordPlaybackLease(lease);
    expect(
      (await File(old.path).stat()).modified.toUtc().difference(now).abs(),
      lessThan(const Duration(seconds: 2)),
    );
    expect((await store.lookup('song'))!.lastPlayed, isNull);
    expect(await File(replacement.path).readAsBytes(), [8]);
    await lease.release();
  });

  test(
    'orphan collection respects age, protection and unrelated files',
    () async {
      final store = makeStore();
      await store.initialize();
      final entry = await store.putTemporary('song', source);
      final lease = (await store.acquire('song'))!;
      await store.promote('song');
      await lease.release();
      // Simulate a retained orphan from an interrupted previous process.
      await File(entry.path).writeAsBytes([4]);
      await File(entry.path).setLastModified(now);
      final unrelated = File(p.join(root.path, 'cache', 'unrelated.opus'));
      await unrelated.writeAsBytes([5]);
      now = now.add(const Duration(days: 6));
      expect(await store.cleanupExpired(), 0);
      now = now.add(const Duration(days: 1));
      expect(await store.cleanupExpired(protectedIds: {'song'}), 0);
      expect(await store.cleanupExpired(), 1);
      expect(await unrelated.exists(), isTrue);
    },
  );
}
