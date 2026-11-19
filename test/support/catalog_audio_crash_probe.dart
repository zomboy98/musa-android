// Run with `dart run test/support/catalog_audio_crash_probe.dart`.
// Child exit() deliberately skips finally blocks, exercising real process death.
import 'dart:convert';
import 'dart:io';

import 'package:mornye/services/catalog_audio_store.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    final root = Directory(arguments[0]);
    final mode = arguments[1];
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: Directory(p.join(root.path, 'library')),
      clock: () => DateTime.utc(2026, 1, mode == 'playback' ? 9 : 1),
      writeManifest: (file, text) async {
        if (mode == 'playback') {
          throw const FileSystemException('manifest failed after timestamp');
        }
        await file.writeAsString(text, flush: true);
      },
      afterAudioPublication: () {
        if (mode == 'audio') exit(77);
      },
      pruneManifests: (_, _) async {
        if (mode == 'manifest') exit(78);
      },
      copyFile: (source, destination) async {
        final file = File(destination);
        final output = file.openWrite();
        await output.addStream(source.openRead());
        await output.flush();
        await output.close();
        if (mode == 'stage') exit(79);
        return file;
      },
    );
    await store.initialize();
    if (mode == 'playback') {
      try {
        await store.recordPlayback('track');
      } on FileSystemException {
        // The timestamp is persisted, while failed-playback protection exists
        // only in this child process. exit discards that memory for real.
        exit(80);
      }
      throw StateError('Expected playback manifest failure');
    }
    final lease = (await store.acquire('track'))!;
    await store.promoteLease('track', lease);
    throw StateError('Child did not terminate at checkpoint');
  }
  final results = <String, String>{};
  for (final mode in ['stage', 'audio', 'manifest', 'playback']) {
    final root = await Directory.systemTemp.createTemp(
      'catalog-process-crash-',
    );
    try {
      var now = DateTime.utc(2026, 1, 1);
      CatalogAudioStore makeStore() => CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
        clock: () => now,
      );
      final store = makeStore();
      await store.initialize();
      final input = await File(
        p.join(root.path, 'input'),
      ).writeAsString('exact selected audio');
      final original = await store.putTemporary('track', input);
      final child = await Process.run(Platform.resolvedExecutable, [
        'run',
        Platform.script.toFilePath(),
        root.path,
        mode,
      ], workingDirectory: Directory.current.path);
      final expected = {
        'audio': 77,
        'manifest': 78,
        'stage': 79,
        'playback': 80,
      }[mode];
      if (child.exitCode != expected) {
        throw StateError('Child failed: ${child.exitCode} ${child.stderr}');
      }
      final reopened = makeStore();
      await reopened.initialize();
      final entry = (await reopened.lookup('track'))!;
      if (await File(entry.path).readAsString() != 'exact selected audio') {
        throw StateError('Wrong bytes');
      }
      if (entry.persistent != (mode == 'manifest')) {
        throw StateError('Wrong commit state');
      }
      if (mode != 'manifest' && entry.path != original.path) {
        throw StateError('Original publication lost');
      }
      for (final dir in [reopened.cacheDirectory, reopened.libraryDirectory]) {
        if (await dir.list().where((entry) => entry is Directory).length != 0) {
          throw StateError('Stage leaked');
        }
      }
      final audioCount = await reopened.libraryDirectory
          .list()
          .where((entry) => entry.path.endsWith('.opus'))
          .length;
      if (audioCount != (mode == 'manifest' ? 1 : 0)) {
        throw StateError('Persistent orphan leaked');
      }
      if (mode == 'playback') {
        now = DateTime.utc(2026, 1, 15); // Six days after actual playback.
        if (await reopened.cleanupExpired() != 0 ||
            await File(original.path).readAsString() !=
                'exact selected audio') {
          throw StateError('Playback retention expired before seven days');
        }
        now = DateTime.utc(2026, 1, 16);
        if (await reopened.cleanupExpired() != 1) {
          throw StateError('Playback retention did not expire at seven days');
        }
      }
      results[mode] = 'PASS';
    } finally {
      await root.delete(recursive: true);
    }
  }
  stdout.writeln(jsonEncode(results));
}
