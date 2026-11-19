import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/services/backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'backup-collections-json-',
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'direct collections JSON keeps exact metadata bytes for v2 and v3',
    () async {
      final collections = <String, dynamic>{
        'loved': [
          {
            'key': 'example:track',
            'track': {
              'name': '日本語 "quoted" \\ slash\nline',
              'comment': null,
              'unknown': {
                'array': [null, true, -0.0, 1.25],
              },
            },
          },
        ],
        'playlists': [
          {
            'id': 'playlist',
            'name': 'Emoji 🎵',
            'coverImagePath': null,
            'tracks': <dynamic>[],
          },
        ],
        'favoriteArtists': <dynamic>[],
        'unknown"key': {'collections': '__raw_collections__', 'nested': null},
      };
      for (final version in [2, 3]) {
        final metadata = <String, dynamic>{
          'magic': BackupService.magic,
          'format_version': version,
          'app': 'Mornye',
          'app_version': '5.1.0',
          'created_at': '2026-10-07T00:00:00.000Z',
          'history_count': 0,
          'unknown_root': {'preserved': true},
          'data': <String, dynamic>{
            'settings': {
              'quote': '"',
              'slash': '\\',
              'line': '\n',
              'nil': null,
            },
            'profile': {'name': '日本語 🎵'},
            'collections': collections,
            'playlist_covers': <String, dynamic>{},
            'extensions': {'items': <dynamic>[], 'nil': null},
            'unknown_data': {'preserved': true},
          },
        };
        final path = '${directory.path}/metadata-$version.json';
        final original = jsonEncode(metadata);
        await BackupService.writeBackupMetadata(path, metadata);
        expect(await File(path).readAsBytes(), utf8.encode(original));
        final placeholder = Map<String, dynamic>.of(metadata)
          ..['data'] = (Map<String, dynamic>.of(
            metadata['data'] as Map<String, dynamic>,
          )..['collections'] = <String, dynamic>{});
        await BackupService.writeBackupMetadata(
          path,
          placeholder,
          collectionsJson: jsonEncode(collections),
        );
        expect(await File(path).readAsBytes(), utf8.encode(original));
        final parsed = BackupService.parse(await File(path).readAsString());
        expect(parsed, isNotNull);
        expect(parsed!.formatVersion, version);
        expect(parsed.collections, collections);
      }
    },
  );

  test(
    'direct JSON archive round trips and retains category presence',
    () async {
      for (final collections in <Map<String, dynamic>>[
        {
          'loved': <dynamic>[],
          'playlists': <dynamic>[],
          'favoriteArtists': <dynamic>[],
        },
        {
          'loved': [
            {'opaque': '日本語 🎵 \\ "\n', 'nil': null},
          ],
          'future': {'value': true},
        },
      ]) {
        final archiveFile = await BackupService.writeBackupArchive(
          settings: const {'theme': 'mornye'},
          collections: const {},
          collectionsJson: jsonEncode(collections),
          playlistCoverFiles: const {},
          extensions: const {},
          loadHistoryPage: (_, _) async => [],
          includeHistory: false,
          outputDirectory: directory,
          temporaryDirectory: directory,
        );
        final archive = ZipDecoder().decodeBytes(
          await archiveFile.readAsBytes(),
        );
        final metadata =
            jsonDecode(utf8.decode(archive.find('metadata.json')!.content))
                as Map<String, dynamic>;
        final data = metadata['data'] as Map<String, dynamic>;
        expect(data.keys, ['settings', 'collections']);
        expect(data['collections'], collections);
        final bundle = await BackupService.parseFile(
          archiveFile.path,
          temporaryDirectory: directory,
        );
        expect(bundle, isNotNull);
        expect(bundle!.hasCollections, isTrue);
        expect(bundle.collections, collections);
        await bundle.cleanup();
      }
    },
  );

  test('map and encoded collections are mutually exclusive', () async {
    await expectLater(
      BackupService.writeBackupArchive(
        settings: null,
        collections: {'loved': <dynamic>[]},
        collectionsJson: '{}',
        playlistCoverFiles: const {},
        extensions: const {},
        loadHistoryPage: (_, _) async => [],
        includeHistory: false,
        outputDirectory: directory,
        temporaryDirectory: directory,
      ),
      throwsArgumentError,
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'saved tracks survive archive round trip and restore; old backups preserve them',
    () async {
      SharedPreferences.setMockInitialValues({});
      const track = Track(
        id: 'saved',
        name: 'Canción 🎵',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 120,
        source: 'catalog',
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(savedLibraryTracksProvider.notifier);
      await notifier.add(track);
      final encoded = BackupService.withSavedLibraryTracks(
        '{"loved":[],"playlists":[]}',
        await container.read(savedLibraryTracksProvider.future),
      );
      final file = await BackupService.writeBackupArchive(
        settings: null,
        collections: const {},
        collectionsJson: encoded,
        playlistCoverFiles: const {},
        extensions: const {},
        loadHistoryPage: (_, _) async => [],
        includeHistory: false,
        outputDirectory: directory,
        temporaryDirectory: directory,
      );
      final bundle = (await BackupService.parseFile(
        file.path,
        temporaryDirectory: directory,
      ))!;
      await notifier.remove(track);
      await notifier.restoreFromBackup(
        BackupService.savedLibraryTracksFromBackup(bundle.collections)!,
      );
      expect(
        (await container.read(
          savedLibraryTracksProvider.future,
        )).single.toJson(),
        track.toJson(),
      );
      expect(BackupService.savedLibraryTracksFromBackup({'loved': <dynamic>[]}), isNull);
      expect(
        (await container.read(savedLibraryTracksProvider.future)).single.id,
        track.id,
      );
      await notifier.restoreFromBackup(
        BackupService.savedLibraryTracksFromBackup({'savedLibraryTracks': <dynamic>[]})!,
      );
      expect(await container.read(savedLibraryTracksProvider.future), isEmpty);
      await bundle.cleanup();
    },
  );
}
