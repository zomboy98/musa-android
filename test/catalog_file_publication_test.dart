import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_file_publication.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('catalog-publication-');
    now = DateTime.utc(2026);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'retired playback preserves replacement persistence protection',
    () async {
      var fail = false;
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
        clock: () => now,
        writeManifest: (file, text) async {
          if (fail) throw const FileSystemException('manifest failed');
          await file.writeAsString(text, flush: true);
        },
      );
      await store.initialize();
      final source = await File(
        p.join(root.path, 'source'),
      ).writeAsString('first');
      await store.putTemporary('track', source);
      final lease = (await store.acquire('track'))!;
      await source.writeAsString('replacement');
      final replacement = await store.putTemporary('track', source);
      fail = true;
      await expectLater(
        store.recordPlayback('track'),
        throwsA(isA<FileSystemException>()),
      );
      await store.recordPlaybackLease(lease);
      await lease.release();
      expect(await store.clearTemporary(), 0);
      expect(await File(replacement.path).exists(), isTrue);
      fail = false;
      await store.recordPlayback('track');
      expect(await store.clearTemporary(), 1);
    },
  );

  CatalogAudioStore makeStore({Future<void> Function(String, String)? prune}) =>
      CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
        clock: () => now,
        pruneManifests: prune,
      );

  test('promotion copy does not block acquisition or recovery', () async {
    final started = Completer<void>();
    final resume = Completer<void>();
    final library = Directory(p.join(root.path, 'library'));
    String? staged;
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: library,
      copyFile: (source, destination) async {
        final output = File(destination).openWrite();
        await output.addStream(source.openRead());
        await output.close();
        if (p.isWithin(library.path, destination)) {
          staged = destination;
          started.complete();
          await resume.future;
        }
        return File(destination);
      },
    );
    await store.initialize();
    final input = await File(p.join(root.path, 'input')).writeAsString('original');
    await store.putTemporary('variant', input);
    final lease = (await store.acquire('variant'))!;
    final pending = store.promoteLease('saved', lease);
    await started.future;
    try {
      final other = await store.acquire('variant').timeout(const Duration(seconds: 2));
      expect(other, isNotNull);
      await other!.release();
      await store.cleanupExpired().timeout(const Duration(seconds: 2));
      expect(await File(staged!).exists(), isTrue);
    } finally {
      resume.complete();
      await pending;
    }
    expect(await pending, isNotNull);
    await lease.release();
  });

  for (final changed in [false, true]) {
    test('promotion rejects ${changed ? 'altered' : 'truncated'} copy', () async {
      final library = Directory(p.join(root.path, 'library'));
      final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')), libraryDirectory: library,
        copyFile: (source, destination) async {
          final out = File(destination).openWrite();
          if (p.isWithin(library.path, destination)) { out.write(changed ? 'Original' : 'orig'); } else { await out.addStream(source.openRead()); }
          await out.close();
          return File(destination);
        });
      await store.initialize();
      final input = await File(p.join(root.path, 'input')).writeAsString('original');
      await store.putTemporary('variant', input);
      final lease = (await store.acquire('variant'))!;
      await expectLater(store.promoteLease('saved', lease), throwsA(isA<FileSystemException>()));
      expect(await store.lookup('saved'), isNull);
      expect(await File(lease.path).readAsString(), 'original');
      await lease.release();
    });
  }

  for (final action in ['release', 'replace', 'cancel', 'target']) {
    test('promotion revalidates $action during copy', () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final library = Directory(p.join(root.path, 'library'));
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: library,
        copyFile: (source, destination) async {
          final output = File(destination).openWrite();
          await output.addStream(source.openRead());
          await output.close();
          if (p.isWithin(library.path, destination)) {
            entered.complete();
            await resume.future;
          }
          return File(destination);
        },
      );
      await store.initialize();
      final input = await File(p.join(root.path, 'input')).writeAsString('original');
      await store.putTemporary('variant', input);
      final lease = (await store.acquire('variant'))!;
      var allowed = true;
      final pending = action == 'replace'
          ? store.promoteVariant('saved', 'variant', canPublish: () async => allowed)
          : store.promoteLease('saved', lease, canPublish: () async => allowed);
      await entered.future;
      if (action == 'release') await lease.release();
      if (action == 'cancel') allowed = false;
      if (action == 'replace') {
        await input.writeAsString('replacement');
        await store.putTemporary('variant', input);
      }
      if (action == 'target') {
        await input.writeAsString('new target');
        await store.putTemporary('saved', input);
      }
      resume.complete();
      expect(await pending, isNull);
      if (action == 'target') {
        final current = await store.lookup('saved');
        expect(current?.persistent, false);
        expect(await File(current!.path).readAsString(), 'new target');
      } else {
        expect(await store.lookup('saved'), isNull);
      }
      await lease.release();
    });
  }

  test('competing promotions retain the first committed permanent file', () async {
    final entered = Completer<void>();
    final resume = Completer<void>();
    var copies = 0;
    final library = Directory(p.join(root.path, 'library'));
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: library,
      copyFile: (source, destination) async {
        final output = File(destination).openWrite();
        await output.addStream(source.openRead());
        await output.close();
        if (p.isWithin(library.path, destination)) {
          if (++copies == 2) entered.complete();
          await resume.future;
        }
        return File(destination);
      },
    );
    await store.initialize();
    final input = await File(p.join(root.path, 'input')).writeAsString('original');
    await store.putTemporary('variant', input);
    final one = store.promoteVariant('saved', 'variant');
    final two = store.promoteVariant('saved', 'variant');
    await entered.future.timeout(const Duration(seconds: 3));
    resume.complete();
    final first = await one;
    final second = await two;
    expect(first, isNotNull);
    expect(second?.path, first!.path);
    expect((await store.lookup('saved'))?.path, first.path);
  });

  test('destination created then cleared cannot be resurrected by promotion', () async {
    final entered = Completer<void>();
    final resume = Completer<void>();
    final library = Directory(p.join(root.path, 'library'));
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: library,
      copyFile: (source, destination) async {
        final output = File(destination).openWrite();
        await output.addStream(source.openRead());
        await output.close();
        if (p.isWithin(library.path, destination)) { entered.complete(); await resume.future; }
        return File(destination);
      },
    );
    await store.initialize();
    final input = await File(p.join(root.path, 'input')).writeAsString('original');
    await store.putTemporary('variant', input);
    final lease = (await store.acquire('variant'))!;
    final pending = store.promoteLease('saved', lease);
    await entered.future;
    await store.putTemporary('saved', input);
    await store.clearTemporary();
    expect(await store.lookup('saved'), isNull);
    resume.complete();
    expect(await pending, isNull);
    expect(await store.lookup('saved'), isNull);
    await lease.release();
  });

  test('lease release during manifest authorization prevents commit', () async {
    final entered = Completer<void>();
    final resume = Completer<void>();
    var calls = 0;
    final store = makeStore();
    await store.initialize();
    final input = await File(p.join(root.path, 'input')).writeAsString('original');
    await store.putTemporary('variant', input);
    final lease = (await store.acquire('variant'))!;
    final pending = store.promoteLease('saved', lease, canPublish: () async {
      if (++calls == 2) { entered.complete(); await resume.future; }
      return true;
    });
    await entered.future;
    final released = lease.release();
    resume.complete();
    expect(await pending, isNull);
    await released;
    expect(await store.lookup('saved'), isNull);
  });

  test('promotion does not overwrite concurrent playback timestamp', () async {
    final entered = Completer<void>();
    final resume = Completer<void>();
    final library = Directory(p.join(root.path, 'library'));
    final store = CatalogAudioStore(cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: library, clock: () => now,
      copyFile: (source, destination) async {
        final output = File(destination).openWrite();
        await output.addStream(source.openRead());
        await output.close();
        if (p.isWithin(library.path, destination)) { entered.complete(); await resume.future; }
        return File(destination);
      });
    await store.initialize();
    final input = await File(p.join(root.path, 'input')).writeAsString('original');
    await store.putTemporary('variant', input);
    final pending = store.promote('variant');
    await entered.future;
    now = now.add(const Duration(days: 1));
    await store.recordPlayback('variant');
    resume.complete();
    expect(await pending, isNull);
    expect((await store.lookup('variant'))?.lastPlayed, now);
  });

  test(
    'native publication installs complete bytes and refuses collision',
    () async {
      final source = await File(
        p.join(root.path, 'stage'),
      ).writeAsString('selected');
      final destination = File(p.join(root.path, 'audio'));
      publishCatalogFileNew(source.path, destination.path);
      expect(await destination.readAsString(), 'selected');
      final other = await File(
        p.join(root.path, 'other'),
      ).writeAsString('different');
      expect(
        () => publishCatalogFileNew(other.path, destination.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await destination.readAsString(), 'selected');
      expect(await other.readAsString(), 'different');
    },
  );

  for (final dangling in [false, true]) {
    test(
      'native publication refuses ${dangling ? 'dangling' : 'live'} destination symlink',
      () async {
        final source = await File(
          p.join(root.path, 'stage'),
        ).writeAsString('selected');
        final alien = File(p.join(root.path, 'alien'));
        if (!dangling) await alien.writeAsString('do not modify');
        final destination = Link(p.join(root.path, 'audio'));
        await destination.create(alien.path);
        expect(
          () => publishCatalogFileNew(source.path, destination.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(await destination.target(), alien.path);
        expect(await source.readAsString(), 'selected');
        if (dangling) {
          expect(await alien.exists(), isFalse);
        } else {
          expect(await alien.readAsString(), 'do not modify');
        }
      },
    );
  }

  test('two stores share leases through cleanup and replacement', () async {
    final first = makeStore();
    await first.initialize();
    final source = await File(
      p.join(root.path, 'source'),
    ).writeAsString('original');
    const originalMetadata = {
      'provider': 'provider_a',
      'resolved_quality': 'aac_128',
    };
    const replacementMetadata = {
      'provider': 'provider_b',
      'resolved_quality': 'aac_256',
    };
    final old = await first.putTemporary(
      'track',
      source,
      qualityMetadata: originalMetadata,
    );
    final lease = (await first.acquire('track'))!;
    final second = makeStore();
    await second.initialize();
    now = now.add(const Duration(days: 8));
    expect(await second.cleanupExpired(), 0);
    expect(await second.clearTemporary(), 0);
    await source.writeAsString('replacement');
    await second.putTemporary(
      'track',
      source,
      qualityMetadata: replacementMetadata,
    );
    expect(await File(old.path).readAsString(), 'original');
    final exact = await second.promoteLease('saved', lease);
    expect(await File(exact!.path).readAsString(), 'original');
    expect(exact.qualityMetadata, originalMetadata);
    expect(
      (await second.lookup('track'))!.qualityMetadata,
      replacementMetadata,
    );
    expect((await second.lookup('saved'))!.qualityMetadata, originalMetadata);
    await lease.release();
    expect(await File(old.path).exists(), isFalse);
  });

  test(
    'manifest pruning failure cannot roll back committed lease audio',
    () async {
      final store = makeStore(
        prune: (_, _) async => throw const FileSystemException('prune failed'),
      );
      await store.initialize();
      final source = await File(
        p.join(root.path, 'source'),
      ).writeAsString('selected');
      await store.putTemporary('variant', source);
      final lease = (await store.acquire('variant'))!;
      final saved = (await store.promoteLease('track', lease))!;
      expect(await File(saved.path).readAsString(), 'selected');
      final reopened = makeStore();
      await reopened.initialize();
      expect((await reopened.lookup('track'))!.path, saved.path);
      await lease.release();
    },
  );

  test(
    'released and missing playback do not permanently protect cache',
    () async {
      final store = makeStore();
      await store.initialize();
      final source = await File(
        p.join(root.path, 'source'),
      ).writeAsString('selected');
      await store.recordPlayback('missing');
      await store.putTemporary('missing', source);
      await store.putTemporary('released', source);
      final lease = (await store.acquire('released'))!;
      await lease.release();
      await expectLater(store.recordPlaybackLease(lease), throwsStateError);
      now = now.add(const Duration(days: 8));
      expect(await store.cleanupExpired(), 2);
    },
  );
}
