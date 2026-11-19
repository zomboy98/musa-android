import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/download_file_inventory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const track = Track(
    id: '1',
    source: 'test',
    name: 'Song',
    artistName: 'Artist',
    albumName: '',
    duration: 1,
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('persists concurrent recordings and checks real file access', () async {
    final dir = await Directory.systemTemp.createTemp('download_inventory');
    addTearDown(() => dir.delete(recursive: true));
    final first = File('${dir.path}/one');
    final second = File('${dir.path}/two');
    await first.writeAsString('audio');
    await second.writeAsString('audio');
    await Future.wait([
      DownloadFileInventory.record(track, first.path),
      DownloadFileInventory.record(track, second.path),
    ]);
    // Reopen preferences as a new reader, as on the next app start.
    SharedPreferences.resetStatic();
    expect(
      await DownloadFileInventory.containsAccessible(
        track,
        savedDownloadFileAccessible,
      ),
      isTrue,
    );
    await first.delete();
    await second.delete();
    expect(
      await DownloadFileInventory.containsAccessible(
        track,
        savedDownloadFileAccessible,
      ),
      isFalse,
    );
  });

  test(
    'recognizes canonical and legacy ISRC hashes across formatting',
    () async {
      final legacy = sha256
          .convert(utf8.encode('isrc:US-ABC 26-00001'))
          .toString();
      SharedPreferences.setMockInitialValues({
        'download_file_inventory_v1': jsonEncode([
          {'path': '/legacy', 'identity': '', 'isrcHash': legacy},
        ]),
      });
      final wanted = track.copyWith(isrc: 'USABC2600001');
      final same = track.copyWith(id: 'another', isrc: 'us abc-26 00001');
      final conflict = track.copyWith(isrc: 'USABC2600002');
      await DownloadFileInventory.record(same, '/canonical');
      expect(
        await DownloadFileInventory.candidatePathsBatch([
          wanted,
          same,
          conflict,
        ]),
        <List<String>>[
          ['/canonical', '/legacy'],
          ['/canonical', '/legacy'],
          [],
        ],
      );
    },
  );

  test(
    'an absent Windows drive leaves download availability inconclusive',
    () async {
      final letters = 'ZYXWVUTSRQPONMLKJIHGFED'.split('');
      for (final letter in letters) {
        final root = '$letter:\\';
        if (!await Directory(root).exists()) {
          expect(
            await savedDownloadPathStatus('${root}Music\\Album\\track.flac'),
            SavedDownloadPathStatus.unavailable,
          );
          return;
        }
      }
      fail('Expected a drive letter without a mounted volume');
    },
    skip: !Platform.isWindows,
  );

  test('configured download root verifies absent album descendants', () async {
    final temporary = await Directory.systemTemp.createTemp('download-root');
    addTearDown(() => temporary.delete(recursive: true));
    final base = await temporary.resolveSymbolicLinks();
    final root = await Directory('$base/Music').create();
    final missing = '${root.path}/Artist/Deleted album/song.flac';
    expect(
      await verifiedDownloadDirectoryContainsPath(root.path, missing),
      isTrue,
    );
    expect(
      await verifiedDownloadDirectoryContainsPath(
        root.path,
        '$base/MusicOther/song.flac',
      ),
      isFalse,
    );
    await root.delete();
    expect(
      await verifiedDownloadDirectoryContainsPath(root.path, missing),
      isFalse,
    );
  });

  test(
    'configured download root rejects a linked, unavailable ancestor',
    () async {
      final temporary = await Directory.systemTemp.createTemp('download-link');
      addTearDown(() => temporary.delete(recursive: true));
      final base = await temporary.resolveSymbolicLinks();
      final root = await Directory('$base/Music').create();
      final external = await Directory('$base/External').create();
      await Link('${root.path}/Linked').create(external.path);
      await external.delete();
      expect(
        await verifiedDownloadDirectoryContainsPath(
          root.path,
          '${root.path}/Linked/Album/song.flac',
        ),
        isFalse,
      );
    },
    skip: Platform.isWindows,
  );

  test('a dangling download file link remains inconclusive', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'download-file-link',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final root = await temporary.resolveSymbolicLinks();
    final target = await File('$root/target.flac').writeAsBytes([1]);
    final link = Link('$root/download.flac');
    try {
      await link.create(target.path);
    } on FileSystemException catch (error) {
      if (!Platform.isWindows || error.osError?.errorCode != 1314) rethrow;
      markTestSkipped('Windows requires permission to create symbolic links.');
      return;
    }
    expect(
      await savedDownloadPathStatus(link.path, downloadDirectory: root),
      SavedDownloadPathStatus.accessible,
    );
    await target.delete();
    expect(
      await FileSystemEntity.type(link.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(
      await savedDownloadPathStatus(link.path, downloadDirectory: root),
      SavedDownloadPathStatus.unavailable,
    );
    await link.delete();
    expect(
      await savedDownloadPathStatus(link.path, downloadDirectory: root),
      SavedDownloadPathStatus.missing,
    );
  });

  test('content URI is accepted only when access probe succeeds', () async {
    await DownloadFileInventory.record(track, 'content://downloads/1');
    expect(
      await DownloadFileInventory.containsAccessible(track, (_) async => false),
      isFalse,
    );
    expect(
      await DownloadFileInventory.containsAccessible(track, (_) async => true),
      isTrue,
    );
  });

  test(
    'keeps temporarily inaccessible entries until deletion is confirmed',
    () async {
      const path = 'content://downloads/offline';
      await DownloadFileInventory.record(track, path);
      expect(
        await DownloadFileInventory.containsAccessible(
          track,
          (_) async => false,
        ),
        isFalse,
      );
      expect(
        await DownloadFileInventory.containsAccessible(
          track,
          (_) async => true,
        ),
        isTrue,
      );
      await DownloadFileInventory.removeDeletedPath(path);
      expect(
        await DownloadFileInventory.containsAccessible(
          track,
          (_) async => true,
        ),
        isFalse,
      );
    },
  );

  test(
    'stores hashed identifiers and clear removes recognition records',
    () async {
      await DownloadFileInventory.record(track, '/private/audio');
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString('download_file_inventory_v1')!;
      expect(data, isNot(contains('"source"')));
      expect(data, isNot(contains('"id"')));
      await DownloadFileInventory.clear();
      expect(
        await DownloadFileInventory.containsAccessible(
          track,
          (_) async => true,
        ),
        isFalse,
      );
    },
  );
}
