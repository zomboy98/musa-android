import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/library_reorganizer.dart';
import 'package:mornye/services/private_downloads_migration.dart';

Map<String, dynamic> _historyRow(String id, String path) => {
  'id': id,
  'trackName': 'Song $id',
  'artistName': 'Artist',
  'albumName': 'Album',
  'filePath': path,
  'service': 'demo',
  'downloadedAt': '2026-01-01T00:00:00.000Z',
};

Map<String, dynamic> _libraryRow(String id, String path) => {
  'id': id,
  'trackName': 'Scan $id',
  'artistName': 'Artist',
  'albumName': 'Album',
  'filePath': path,
  'scannedAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  late Directory base;
  late String privateRoot;
  late String sharedRoot;
  late Map<String, String> history;
  late Set<String> failingIds;
  late List<String> relinked;

  Future<File> write(String relative, String content) async {
    final file = File(p.join(privateRoot, relative));
    await file.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  LibraryReorganizer reorganizer() => LibraryReorganizer(
    onSourceRelocated: (_, _) async {},
    updateHistoryPath:
        (
          id,
          newFilePath, {
          newSafFileName,
          newSafRelativeDir,
          required expectedFilePath,
        }) async {
          if (failingIds.contains(id)) return false;
          history[id] = newFilePath;
          return true;
        },
    relinkLibraryPath: (oldPath, newPath) async {
      relinked.add(newPath);
      return true;
    },
  );

  Future<PrivateDownloadsPlan> plan() => buildPrivateDownloadsPlan(
    privateFolders: [privateRoot],
    targetRoot: sharedRoot,
    historyRows: (limit, offset) async => offset > 0
        ? []
        : [for (final e in history.entries) _historyRow(e.key, e.value)],
    libraryRows: (limit, offset) async => offset > 0
        ? []
        : [_libraryRow('scan-1', p.join(privateRoot, 'Scanned', 'loose.flac'))],
  );

  setUp(() async {
    base = await Directory.systemTemp.createTemp('private-downloads-');
    privateRoot = p.join(base.path, 'app_flutter', 'MUSA');
    sharedRoot = p.join(base.path, 'Music', 'MUSA');
    failingIds = {};
    relinked = [];
    await Directory(sharedRoot).create(recursive: true);
    history = {
      'h1': p.join(privateRoot, 'Artist', 'Album', 'one.flac'),
      'h2': p.join(privateRoot, 'Artist', 'Album', 'two.flac'),
      'h3': p.join(privateRoot, 'gone.flac'),
      'outside': p.join(base.path, 'elsewhere', 'keep.flac'),
    };
    await write(p.join('Artist', 'Album', 'one.flac'), 'one-bytes');
    await write(p.join('Artist', 'Album', 'two.flac'), 'two-bytes');
    await write(p.join('Scanned', 'loose.flac'), 'loose-bytes');
    final outside = File(history['outside']!);
    await outside.create(recursive: true);
    await outside.writeAsString('outside-bytes');
  });

  tearDown(() => base.delete(recursive: true));

  test('plans only existing files inside the private folder', () async {
    final result = await plan();
    final sources = result.plan.moves.map((m) => m.sourcePath).toSet();
    expect(result.count, 3);
    expect(result.missing, 1);
    expect(
      sources,
      containsAll([
        history['h1'],
        history['h2'],
        p.join(privateRoot, 'Scanned', 'loose.flac'),
      ]),
    );
    expect(sources, isNot(contains(history['outside'])));
    expect(result.plan.root, p.normalize(sharedRoot));
    final first = result.plan.moves.firstWhere(
      (m) => m.sourcePath == history['h1'],
    );
    expect(first.targetRelativeDir, 'Artist/Album');
    expect(first.targetFileName, 'one.flac');
  });

  test(
    'copies, verifies, relinks and only then deletes the original',
    () async {
      final original = history['h1']!;
      final result = await reorganizer().run((await plan()).plan);

      expect(result.moved, 3);
      expect(result.failed, 0);
      final moved = File(p.join(sharedRoot, 'Artist', 'Album', 'one.flac'));
      expect(await moved.readAsString(), 'one-bytes');
      expect(await File(original).exists(), isFalse);
      expect(history['h1'], moved.path);
      expect(
        await File(p.join(sharedRoot, 'Scanned', 'loose.flac')).readAsString(),
        'loose-bytes',
      );
      expect(await File(history['outside']!).exists(), isTrue);
    },
  );

  test('a track whose record cannot be updated stays where it was', () async {
    failingIds = {'h2'};
    final original = history['h2']!;

    final result = await reorganizer().run((await plan()).plan);

    expect(result.moved, 2);
    expect(result.failed, 1);
    expect(await File(original).readAsString(), 'two-bytes');
    expect(history['h2'], original);
    expect(
      await File(p.join(sharedRoot, 'Artist', 'Album', 'two.flac')).exists(),
      isFalse,
    );
  });

  test('an interrupted move resumes without losing or duplicating', () async {
    failingIds = {'h2'};
    await reorganizer().run((await plan()).plan);

    failingIds = {};
    final resumed = await plan();
    expect(resumed.count, 1);
    expect(resumed.plan.moves.single.sourcePath, history['h2']);

    final result = await reorganizer().run(resumed.plan);
    expect(result.moved, 1);
    expect(
      await File(
        p.join(sharedRoot, 'Artist', 'Album', 'two.flac'),
      ).readAsString(),
      'two-bytes',
    );
    expect((await plan()).count, 0);
  });

  test('cancelling leaves the remaining tracks in place', () async {
    var done = 0;
    final result = await reorganizer().run(
      (await plan()).plan,
      isCancelled: () => done >= 1,
      onProgress: (count, _) => done = count,
    );
    expect(result.cancelled, isTrue);
    expect(result.moved, 1);
    expect((await plan()).count, 2);
  });

  test('an existing file in the shared folder is not overwritten', () async {
    final clash = File(p.join(sharedRoot, 'Artist', 'Album', 'one.flac'));
    await clash.create(recursive: true);
    await clash.writeAsString('someone-else');

    await reorganizer().run((await plan()).plan);

    expect(await clash.readAsString(), 'someone-else');
    expect(
      await File(
        p.join(sharedRoot, 'Artist', 'Album', 'one (2).flac'),
      ).readAsString(),
      'one-bytes',
    );
  });
}
