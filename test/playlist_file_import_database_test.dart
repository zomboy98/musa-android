import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playlist_file_import_ui_test.dart' show EmptyLibrary, Picker;
import 'playlist_link_import_test.dart' show FakeResolver;
import 'support/link_sync_support.dart';

// The native picker is replaced; reading the chosen file, parsing, selection,
// notifier, SQL schema/transaction and reopening the database are real.
final class DiskPlaylistFile extends PlatformFile {
  DiskPlaylistFile(this.file, this.filename);
  final File file;
  final String filename;
  @override
  String get name => filename;
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final extension in ['csv', 'm3u', 'm3u8']) {
    testWidgets(
      '$extension disk import selects occurrences and survives SQLite reopen',
      (tester) async {
        final directory = (await tester.runAsync(linkSyncTempDirectory))!;
        final file = File('${directory.path}/Disk mix.$extension');
        await tester.runAsync(
          () => file.writeAsString(
            extension == 'csv'
                ? 'Track Name,Artist Name,Album Name\nFirst,Artist,Album\nSecond,Artist,Album\nFirst,Artist,Album\nFirst,Artist,Album\n'
                : '#EXTM3U\n#EXTINF:123,Artist - First\nfirst.mp3\nfile:///Music/Mi%20canci%C3%B3n.mp3\nC:\\Music\\AC%2FDC.mp3\nC:\\Music\\AC%2FDC.mp3\n',
          ),
        );
        final originalPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = Picker(
          DiskPlaylistFile(file, 'Disk mix.$extension'),
        );
        addTearDown(() => FilePickerPlatform.instance = originalPicker);
        final db = (await tester.runAsync(
          () => openLinkCollectionsDatabase(directory, 'file-import'),
        ))!;
        final resolver = FakeResolver();
        final container = ProviderContainer(
          overrides: [
            linkDesktopDownloadsProvider.overrideWithValue(resolver),
            libraryCollectionsProvider.overrideWith(
              () => LibraryCollectionsNotifier(
                database: LibraryCollectionsDatabase.withDatabase(db),
              ),
            ),
          ],
        );
        var disposed = false;
        addTearDown(() {
          if (!disposed) container.dispose();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => importPlaylistFile(
                      context,
                      ref,
                      library: EmptyLibrary(),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        for (
          var i = 0;
          i < 500 && find.text('Choose tracks').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.text('Choose tracks'), findsOneWidget);
        // Remove only the first occurrence, leaving two equal tracks in order.
        await tester.tap(find.byKey(const ValueKey('import_track_0')));
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create'));
        for (var i = 0; i < 500; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (container.read(libraryCollectionsProvider).playlists.isNotEmpty)
            break;
        }
        final playlist = container
            .read(libraryCollectionsProvider)
            .playlists
            .single;
        expect(playlist.name, 'Disk mix');
        final rows = (await tester.runAsync(
          () => db.rawQuery(
            'SELECT track_key FROM playlist_tracks WHERE playlist_id = ? ORDER BY added_at,rowid',
            [playlist.id],
          ),
        ))!;
        expect(rows, hasLength(3));
        expect(rows.map((row) => row['track_key']).toSet(), hasLength(3));
        expect(resolver.calls, 0);
        expect(resolver.downloads, 0);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
        container.dispose();
        disposed = true;
        await tester.runAsync(db.close);
        final reopened = (await tester.runAsync(
          () => openLinkCollectionsDatabase(directory, 'file-import'),
        ))!;
        final reloaded = ProviderContainer(
          overrides: [
            libraryCollectionsProvider.overrideWith(
              () => LibraryCollectionsNotifier(
                database: LibraryCollectionsDatabase.withDatabase(reopened),
              ),
            ),
          ],
        );
        addTearDown(reloaded.dispose);
        await tester.runAsync(
          () => reloaded
              .read(libraryCollectionsProvider.notifier)
              .ensurePlaylistLoaded(playlist.id),
        );
        final saved = reloaded
            .read(libraryCollectionsProvider)
            .playlistById(playlist.id)!;
        expect(saved.name, 'Disk mix');
        expect(saved.tracks.map((entry) => entry.track.name), extension == 'csv'
            ? ['Second', 'First', 'First']
            : ['Mi canción', 'AC%2FDC', 'AC%2FDC']);
        expect(
          saved.tracks.map((entry) => entry.track.artistName),
          everyElement(extension == 'csv' ? 'Artist' : 'Unknown Artist'),
        );
      },
    );
  }
}
