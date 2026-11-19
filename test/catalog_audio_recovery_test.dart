import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/catalog_audio_stage.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_file_publication.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory cache;
  late Directory library;
  late File source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('catalog-recovery-');
    cache = await Directory(p.join(root.path, 'cache')).create();
    library = await Directory(p.join(root.path, 'library')).create();
    source = await File(
      p.join(root.path, 'input'),
    ).writeAsString('selected audio');
  });
  tearDown(() => root.delete(recursive: true));

  for (final corrupt in [false, true]) {
    test('uncertain stage protects cache orphan, corrupt=$corrupt', () async {
      final store = CatalogAudioStore(
        cacheDirectory: cache,
        libraryDirectory: library,
      );
      await store.initialize();
      final key = store.publicationKey('interrupted');
      final name = '$key.00000000000000000001.opus';
      final orphan = await File(
        p.join(cache.path, name),
      ).writeAsString('foreign');
      final stage = await cache.createTemp(CatalogAudioStage.prefix);
      await File(p.join(stage.path, 'owner.json')).writeAsString(
        corrupt
            ? '{'
            : jsonEncode({
                'magic': 'musa-catalog-owned-stage-v2',
                'directory': p.basename(stage.path),
                'leaf': 'audio.part',
                'target': name,
              }),
      );
      await store.clearTemporary();
      expect(await orphan.readAsString(), 'foreign');
      expect(await stage.exists(), isTrue);
    });
  }

  test(
    'uncertain target survives cleanup even when a manifest refers to it',
    () async {
      final store = CatalogAudioStore(
        cacheDirectory: cache,
        libraryDirectory: library,
      );
      await store.initialize();
      final entry = await store.putTemporary('interrupted', source);
      final name = p.basename(entry.path);
      final stage = await cache.createTemp(CatalogAudioStage.prefix);
      await File(p.join(stage.path, 'owner.json')).writeAsString(
        jsonEncode({
          'magic': 'musa-catalog-owned-stage-v2',
          'directory': p.basename(stage.path),
          'leaf': 'audio.part',
          'target': name,
        }),
      );
      await store.clearTemporary();
      expect(await File(entry.path).readAsString(), 'selected audio');
    },
  );

  test(
    'a readable uncertain journal does not protect unrelated cache',
    () async {
      final store = CatalogAudioStore(
        cacheDirectory: cache,
        libraryDirectory: library,
      );
      await store.initialize();
      final entry = await store.putTemporary('unrelated', source);
      final key = store.publicationKey('interrupted');
      final stage = await cache.createTemp(CatalogAudioStage.prefix);
      await File(p.join(stage.path, 'owner.json')).writeAsString(
        jsonEncode({
          'magic': 'musa-catalog-owned-stage-v2',
          'directory': p.basename(stage.path),
          'leaf': 'audio.part',
          'target': '$key.00000000000000000001.opus',
        }),
      );
      expect(await store.clearTemporary(), 1);
      expect(await File(entry.path).exists(), isFalse);
    },
  );

  test(
    'recovery preserves all references, corrupt metadata and substituted destinations',
    () async {
      final store = CatalogAudioStore(
        cacheDirectory: cache,
        libraryDirectory: library,
      );
      await store.initialize();
      for (final mode in ['older-reference', 'corrupt', 'replaced']) {
        final key = store.publicationKey(mode);
        final name = '$key.00000000000000000001.opus';
        final destination = File(p.join(library.path, name));
        final stage = await CatalogAudioStage.create(
          library,
          'audio.part',
          manifests: library,
          destination: destination.path,
        );
        await stage.file.writeAsString('owned original');
        publishCatalogFileNew(stage.file.path, destination.path);
        if (mode == 'replaced') {
          await destination.delete();
          await destination.writeAsString('foreign replacement');
        } else {
          final manifest = File(
            p.join(library.path, '$key.00000000000000000002.json'),
          );
          await manifest.writeAsString(
            mode == 'corrupt'
                ? '{broken'
                : jsonEncode({
                    'file': name,
                    'persistent': true,
                    'created': DateTime.utc(2026).toIso8601String(),
                  }),
          );
          if (mode == 'older-reference') {
            await File(
              p.join(library.path, '$key.00000000000000000004.json'),
            ).writeAsString(
              jsonEncode({
                'file': '$key.00000000000000000003.opus',
                'persistent': true,
                'created': DateTime.utc(2026).toIso8601String(),
              }),
            );
          }
        }
        await CatalogAudioStage.recoverRoot(library, library);
        expect(
          await destination.readAsString(),
          mode == 'replaced' ? 'foreign replacement' : 'owned original',
        );
        expect(await stage.directory.exists(), mode == 'corrupt');
      }
    },
  );

  for (final referencesAudio in [true, false]) {
    test(
      'ambiguous recovery retries after metadata repair: referenced=$referencesAudio',
      () async {
        final store = CatalogAudioStore(
          cacheDirectory: cache,
          libraryDirectory: library,
        );
        await store.initialize();
        final key = store.publicationKey('ambiguous');
        final name = '$key.00000000000000000001.opus';
        final destination = File(p.join(library.path, name));
        final stage = await CatalogAudioStage.create(
          library,
          'audio.part',
          manifests: library,
          destination: destination.path,
        );
        await stage.file.writeAsString('owned pending audio');
        publishCatalogFileNew(stage.file.path, destination.path);
        final manifest = File(
          p.join(library.path, '$key.00000000000000000002.json'),
        );
        await manifest.writeAsString('{broken');
        await CatalogAudioStage.recoverRoot(library, library);
        final anchor = File(p.join(stage.directory.path, 'identity'));
        final journal = File(p.join(stage.directory.path, 'owner.json'));
        expect(await destination.readAsString(), 'owned pending audio');
        expect(await journal.exists(), isTrue);
        expect(
          await FileSystemEntity.identical(anchor.path, destination.path),
          isTrue,
        );
        await manifest.writeAsString(
          jsonEncode({
            'file': referencesAudio ? name : '$key.00000000000000000003.opus',
            'persistent': true,
            'created': DateTime.utc(2026).toIso8601String(),
          }),
        );
        await CatalogAudioStage.recoverRoot(library, library);
        expect(await destination.exists(), referencesAudio);
        if (referencesAudio) {
          expect(await destination.readAsString(), 'owned pending audio');
        }
        expect(await stage.directory.exists(), isFalse);
        expect(await manifest.exists(), isTrue);
      },
    );
  }

  test('callback replacing staged inode fails before publication', () async {
    final store = CatalogAudioStore(
      cacheDirectory: cache,
      libraryDirectory: library,
      copyFile: (source, destination) async {
        await File(destination).delete();
        return File(destination).writeAsString('replacement inode');
      },
    );
    await store.initialize();
    await expectLater(
      store.putTemporary('track', source),
      throwsA(isA<FileSystemException>()),
    );
    expect(await store.lookup('track'), isNull);
    expect(
      await cache
          .list()
          .where((e) => e is File && e.path.endsWith('.opus'))
          .length,
      0,
    );
  });
  CatalogAudioStore makeStore() =>
      CatalogAudioStore(cacheDirectory: cache, libraryDirectory: library);
  Future<void> noAbandonedAudio() async {
    final entries = await library.list().toList();
    expect(entries.whereType<Directory>(), isEmpty);
    expect(entries.where((e) => e.path.endsWith('.opus')), isEmpty);
  }

  test(
    'repeated manifest disk-full and cancellation roll back owned audio',
    () async {
      var fail = false;
      final store = CatalogAudioStore(
        cacheDirectory: cache,
        libraryDirectory: library,
        writeManifest: (file, text) async {
          if (fail) throw const FileSystemException('disk full');
          await file.writeAsString(text, flush: true);
        },
      );
      await store.initialize();
      final original = await store.putTemporary('track', source);
      final lease = (await store.acquire('track'))!;
      for (var attempt = 0; attempt < 3; attempt++) {
        fail = true;
        await expectLater(
          store.promoteLease('track', lease),
          throwsA(isA<FileSystemException>()),
        );
        await noAbandonedAudio();
        fail = false;
        var checks = 0;
        expect(
          await store.promoteLease(
            'track',
            lease,
            canPublish: () async => ++checks == 1,
          ),
          isNull,
        );
        await noAbandonedAudio();
        expect((await store.lookup('track'))!.path, original.path);
        expect(await File(lease.path).readAsString(), 'selected audio');
      }
      await lease.release();
    },
  );

  test('post-audio exception rolls back and a retry commits', () async {
    var fail = false;
    final store = CatalogAudioStore(
      cacheDirectory: cache,
      libraryDirectory: library,
      afterAudioPublication: () {
        if (fail) throw StateError('after audio');
      },
      pruneManifests: (_, _) async {
        if (fail) throw StateError('after manifest');
      },
    );
    await store.initialize();
    await store.putTemporary('track', source);
    final lease = (await store.acquire('track'))!;
    fail = true;
    await expectLater(store.promoteLease('track', lease), throwsStateError);
    await noAbandonedAudio();
    fail = false;
    final saved = (await store.promoteLease('track', lease))!;
    expect(await File(saved.path).readAsString(), 'selected audio');
    await lease.release();
  });

  test(
    'queued recovery cannot collect a pending writer or active lease',
    () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      var hold = false;
      final store = CatalogAudioStore(
        cacheDirectory: cache,
        libraryDirectory: library,
        copyFile: (file, destination) async {
          await File(
            destination,
          ).writeAsBytes(await file.readAsBytes(), flush: true);
          if (hold) {
            entered.complete();
            await resume.future;
          }
          return File(destination);
        },
      );
      await store.initialize();
      await store.putTemporary('track', source);
      final lease = (await store.acquire('track'))!;
      hold = true;
      final saving = store.promoteLease('track', lease);
      await entered.future;
      var recovered = false;
      final recovery = makeStore().initialize().then((_) {
        recovered = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(recovered, isFalse);
      expect(await File(lease.path).readAsString(), 'selected audio');
      resume.complete();
      final saved = (await saving)!;
      await recovery;
      expect(await File(saved.path).readAsString(), 'selected audio');
      expect(await File(lease.path).exists(), isTrue);
      await lease.release();
    },
  );

  test(
    'recovery preserves unknown entries, replaced identities and symlinks',
    () async {
      final alien = await File(
        p.join(root.path, 'alien'),
      ).writeAsString('unrelated');
      for (final mode in ['extra', 'replacement', 'symlink']) {
        final stage = await CatalogAudioStage.create(
          library,
          'audio.part',
          manifests: library,
        );
        await stage.file.writeAsString('owned');
        if (mode == 'extra') {
          await File(
            p.join(stage.directory.path, 'foreign'),
          ).writeAsString('keep');
        } else {
          await stage.file.delete();
          if (mode == 'symlink') {
            await Link(stage.file.path).create(alien.path);
          } else {
            await stage.file.writeAsString('replacement');
          }
        }
        await CatalogAudioStage.recoverRoot(library, library);
        expect(await stage.directory.exists(), isTrue);
      }
      expect(await alien.readAsString(), 'unrelated');
    },
  );

  test(
    'journal recovery removes uncommitted link and preserves referenced link',
    () async {
      final store = makeStore();
      await store.initialize();
      final key = store.publicationKey('track');
      final destination = p.join(
        library.path,
        '$key.00000000000000000001.opus',
      );
      final stage = await CatalogAudioStage.create(
        library,
        'audio.part',
        manifests: library,
        destination: destination,
      );
      await stage.file.writeAsString('uncommitted');
      publishCatalogFileNew(stage.file.path, destination);
      await makeStore().initialize();
      expect(await File(destination).exists(), isFalse);
      expect(await stage.directory.exists(), isFalse);

      await store.putTemporary('track', source);
      final saved = (await store.promote('track'))!;
      expect(await File(saved.path).readAsString(), 'selected audio');
      expect(await library.list().where((e) => e is Directory).length, 0);
    },
  );
}
