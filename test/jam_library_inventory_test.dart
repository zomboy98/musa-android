import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/jam/jam_library_inventory.dart';
import 'package:mornye/services/jam/jam_track_reference.dart';
import 'package:mornye/services/library_database.dart';
import 'package:path/path.dart' as p;

class _History extends Fake implements HistoryDatabase {
  final rows = <Map<String, dynamic>>[];
  int reads = 0;
  @override
  Future<List<Map<String, dynamic>>> getAll({int? limit, int? offset}) async {
    reads++;
    return rows;
  }
}

class _Library extends Fake implements LibraryDatabase {
  final rows = <Map<String, dynamic>>[];
  @override
  Future<List<LibraryFilePathRow>> getFilePathRows() async => [
    for (final row in rows)
      (
        id: row['id'] as String,
        sourceId: 'local',
        filePath: row['filePath'] as String,
      ),
  ];
  @override
  Future<List<Map<String, dynamic>>> getByIds(List<String> ids) async => rows;
}

void main() {
  test(
    'resolves only a unique readable local ISRC without trusting legacy IDs',
    () async {
      final history = _History();
      final library = _Library();
      final path = Platform.isWindows
          ? r'C:\music\song.flac'
          : '/music/song.flac';
      final item = DownloadHistoryItem(
        id: '1',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: '',
        filePath: path,
        service: 'Tidal',
        downloadedAt: DateTime(2026),
        isrc: 'USABC1234567',
        spotifyId: '123',
      );
      history.rows.add(item.toJson());
      var readable = true;
      final inventory = JamLibraryInventory(
        includeLocalLibrary: () => true,
        history: history,
        library: library,
        fileExists: (_) async => readable,
      );
      final reference = JamTrackReference.create(
        isrc: item.isrc,
        title: 'Song',
        artist: 'Artist',
      )!.encode();
      expect((await inventory.resolveLocal(reference))?.source, path);
      readable = false;
      expect(await inventory.resolveLocal(reference), isNull);
      readable = true;
      history.rows.add({...item.toJson(), 'id': '2'});
      expect((await inventory.resolveLocal(reference))?.source, path);
      final other = Platform.isWindows
          ? r'C:\music\other.flac'
          : '/music/other.flac';
      history.rows.add({...item.toJson(), 'id': '3', 'filePath': other});
      expect(await inventory.resolveLocal(reference), isNull);
      expect(await inventory.resolveLocal('legacy-path'), isNull);
      final providerOnly = JamTrackReference.create(
        provider: 'tidal',
        externalId: '123',
        title: 'Song',
        artist: 'Artist',
      )!.encode();
      expect(await inventory.resolveLocal(providerOnly), isNull);
    },
  );

  test('ignores inaccessible candidates before deciding ambiguity', () async {
    final history = _History();
    final item = DownloadHistoryItem(
      id: '1',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: '',
      filePath: 'content://downloads/stale',
      service: 'Tidal',
      downloadedAt: DateTime(2026),
      isrc: 'USABC1234567',
    );
    history.rows.addAll([
      item.toJson(),
      {...item.toJson(), 'id': '2', 'filePath': 'content://downloads/good'},
    ]);
    final inventory = JamLibraryInventory(
      includeLocalLibrary: () => false,
      history: history,
      library: _Library(),
      safCanOpenRead: (uri) async => uri.endsWith('/good'),
    );
    final ref = JamTrackReference.create(
      isrc: item.isrc,
      title: 'Song',
      artist: 'Artist',
    )!.encode();
    expect(
      (await inventory.resolveLocal(ref))?.source,
      'content://downloads/good',
    );
  });

  test(
    'identical SAF sources deduplicate but distinct URIs stay ambiguous',
    () async {
      final history = _History();
      final item = DownloadHistoryItem(
        id: '1',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: '',
        filePath: 'content://downloads/one',
        service: 'Tidal',
        downloadedAt: DateTime(2026),
        isrc: 'USABC1234567',
      );
      history.rows.addAll([
        item.toJson(),
        {...item.toJson(), 'id': '2'},
      ]);
      final inventory = JamLibraryInventory(
        includeLocalLibrary: () => false,
        history: history,
        library: _Library(),
        safCanOpenRead: (_) async => true,
      );
      final ref = JamTrackReference.create(
        isrc: item.isrc,
        title: 'Song',
        artist: 'Artist',
      )!.encode();
      expect((await inventory.resolveLocal(ref))?.source, item.filePath);
      history.rows.add({
        ...item.toJson(),
        'id': '3',
        'filePath': 'content://downloads/ONE',
      });
      expect(await inventory.resolveLocal(ref), isNull);
    },
  );

  test(
    'does not collapse paths through a symlink and parent segment',
    () async {
      final root = await Directory.systemTemp.createTemp('jam_identity_');
      addTearDown(() => root.delete(recursive: true));
      final other = await Directory(p.join(root.path, 'other')).create();
      final nested = await Directory(p.join(other.path, 'nested')).create();
      final direct = File(p.join(root.path, 'song.flac'));
      final otherSong = File(p.join(other.path, 'song.flac'));
      await direct.writeAsString('first');
      await otherSong.writeAsString('second');
      final link = Link(p.join(root.path, 'link'));
      try {
        await link.create(nested.path);
      } on FileSystemException {
        // Creating directory symlinks can require privileges on Windows.
        return;
      }
      final throughLink = '${link.path}${p.separator}..${p.separator}song.flac';
      // Some platforms resolve parent segments before following links.
      if (await File(throughLink).readAsString() != 'second') return;
      final item = DownloadHistoryItem(
        id: '1',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: '',
        filePath: direct.path,
        service: 'Tidal',
        downloadedAt: DateTime(2026),
        isrc: 'USABC1234567',
      );
      final history = _History()
        ..rows.addAll([
          item.toJson(),
          {...item.toJson(), 'id': '2', 'filePath': throughLink},
        ]);
      final inventory = JamLibraryInventory(
        includeLocalLibrary: () => false,
        history: history,
        library: _Library(),
      );
      final ref = JamTrackReference.create(
        isrc: item.isrc,
        title: 'Song',
        artist: 'Artist',
      )!.encode();
      expect(await inventory.resolveLocal(ref), isNull);
    },
  );

  test('distinct path spellings remain ambiguous', () async {
    final direct = Platform.isWindows
        ? r'C:\music\song.flac'
        : '/music/song.flac';
    final viaParent = Platform.isWindows
        ? r'C:\music\link\..\song.flac'
        : '/music/link/../song.flac';
    final item = DownloadHistoryItem(
      id: '1',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: '',
      filePath: direct,
      service: 'Tidal',
      downloadedAt: DateTime(2026),
      isrc: 'USABC1234567',
    );
    final history = _History()
      ..rows.addAll([
        item.toJson(),
        {...item.toJson(), 'id': '2', 'filePath': viaParent},
      ]);
    final inventory = JamLibraryInventory(
      includeLocalLibrary: () => false,
      history: history,
      library: _Library(),
      fileExists: (_) async => true,
    );
    final ref = JamTrackReference.create(
      isrc: item.isrc,
      title: 'Song',
      artist: 'Artist',
    )!.encode();
    expect(await inventory.resolveLocal(ref), isNull);
  });

  test(
    'batch refreshes inventory once per call and checks SAF access',
    () async {
      final history = _History();
      final item = DownloadHistoryItem(
        id: '1',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: '',
        filePath: 'content://downloads/1',
        service: 'Tidal',
        downloadedAt: DateTime(2026),
        isrc: 'USABC1234567',
      );
      history.rows.add(item.toJson());
      var accessible = true;
      final inventory = JamLibraryInventory(
        includeLocalLibrary: () => false,
        history: history,
        library: _Library(),
        safCanOpenRead: (_) async => accessible,
      );
      final reference = JamTrackReference.create(
        isrc: item.isrc,
        title: 'Song',
        artist: 'Artist',
      )!.encode();
      expect(
        (await inventory.resolveLocalBatch([
          reference,
          reference,
        ])).map((media) => media?.source),
        [item.filePath, item.filePath],
      );
      expect(history.reads, 1);
      accessible = false;
      expect(await inventory.resolveLocalBatch([reference]), [null]);
      expect(history.reads, 2);
      history.rows.clear();
      expect(await inventory.resolveLocalBatch([reference]), [null]);
    },
  );

  test('SAF bridge exceptions resolve as unavailable', () async {
    final history = _History();
    final item = DownloadHistoryItem(
      id: '1',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: '',
      filePath: 'content://downloads/1',
      service: 'Tidal',
      downloadedAt: DateTime(2026),
      isrc: 'USABC1234567',
    );
    history.rows.add(item.toJson());
    final inventory = JamLibraryInventory(
      includeLocalLibrary: () => false,
      history: history,
      library: _Library(),
      safCanOpenRead: (_) async => throw StateError('permission revoked'),
    );
    final reference = JamTrackReference.create(
      isrc: item.isrc,
      title: 'Song',
      artist: 'Artist',
    )!.encode();
    expect(await inventory.resolveLocal(reference), isNull);
  });
}
