import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';

import 'playlist_link_import_test.dart' show FakeResolver, first, second;
import 'support/link_sync_support.dart';

// Only resolution is simulated. The UI, notifier, production schema, writes,
// transactions, and subsequent reload all run through the actual app code.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final fail in [false, true]) {
    testWidgets(
      fail
          ? 'SQL failure rolls back imported rows and removes only the new list'
          : 'public link import persists ordered duplicate occurrences across reopen',
      (tester) async {
        final resolver = FakeResolver();
        final directory = await tester.runAsync(linkSyncTempDirectory);
        final db = (await tester.runAsync(
          () => openLinkCollectionsDatabase(directory!, 'public-import'),
        ))!;
        final database = LibraryCollectionsDatabase.withDatabase(db);
        final container = ProviderContainer(
          overrides: [
            linkDesktopDownloadsProvider.overrideWithValue(resolver),
            libraryCollectionsProvider.overrideWith(
              () => LibraryCollectionsNotifier(database: database),
            ),
          ],
        );
        var disposed = false;
        addTearDown(() {
          if (!disposed) container.dispose();
        });
        final keep = (await tester.runAsync(() async {
          final notifier = container.read(libraryCollectionsProvider.notifier);
          final id = await notifier.createPlaylist('Keep me');
          await notifier.addTracksToPlaylist(id, [second]);
          if (fail) {
            await db.execute('CREATE TABLE import_audit(track_key TEXT)');
            await db.execute('''CREATE TRIGGER audit_import
              AFTER INSERT ON playlist_tracks
              WHEN new.playlist_id != '$id'
              BEGIN INSERT INTO import_audit VALUES(new.track_key); END''');
            // The first imported row executes before the second fails. SQLite
            // must roll it back, and UI compensation must delete the new list.
            await db.execute('''CREATE TRIGGER reject_import
              BEFORE INSERT ON playlist_tracks
              WHEN new.playlist_id != '$id'
                AND instr(new.track_json, '"id":"2"') > 0
              BEGIN SELECT RAISE(ABORT, 'injected import failure'); END''');
          }
          return id;
        }))!;
        final before = await tester.runAsync(
          () => db.rawQuery('SELECT * FROM playlist_tracks ORDER BY rowid'),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => importPlaylistLink(context, ref),
                    child: const Text('Open import'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open import'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'https://example.com/playlist',
        );
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create'));
        final outcome = find.textContaining(
          fail ? 'Could not import the link' : 'Imported 3 tracks',
        );
        for (var i = 0; i < 500 && outcome.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(outcome, findsOneWidget);
        expect(resolver.calls, 1);
        expect(resolver.downloads, 0);

        final rows = (await tester.runAsync(
          () => db.rawQuery('SELECT * FROM playlists ORDER BY rowid'),
        ))!;
        expect(
          rows.map((row) => row['name']),
          fail ? ['Keep me'] : ['Keep me', 'Public mix'],
        );
        expect(
          container
              .read(libraryCollectionsProvider)
              .playlists
              .map((p) => p.name),
          contains('Keep me'),
        );
        if (fail) {
          // Deleting the failed playlist would not clear this audit table:
          // its emptiness proves the preceding insert rolled back in SQL.
          expect(
            await tester.runAsync(() => db.query('import_audit')),
            isEmpty,
          );
          expect(
            container.read(libraryCollectionsProvider).playlists,
            hasLength(1),
          );
          expect(
            await tester.runAsync(
              () => db.rawQuery('SELECT * FROM playlist_tracks ORDER BY rowid'),
            ),
            before,
          );
        } else {
          final id = rows.last['id']! as String;
          final saved = (await tester.runAsync(
            () => db.rawQuery(
              'SELECT track_key,track_json FROM playlist_tracks '
              'WHERE playlist_id = ? ORDER BY added_at,rowid',
              [id],
            ),
          ))!;
          expect(saved.map((row) => row['track_key']).toSet(), hasLength(3));
          expect(saved.map((row) => jsonDecode(row['track_json']! as String)), [
            first.toJson(),
            second.toJson(),
            first.toJson(),
          ]);

          // Close the live connection and create a fresh notifier on a newly
          // opened file, proving persistence beyond the original state/cache.
          await tester.pumpWidget(const SizedBox());
          container.dispose();
          disposed = true;
          await tester.runAsync(db.close);
          final reopened = (await tester.runAsync(
            () => openLinkCollectionsDatabase(directory!, 'public-import'),
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
                .ensurePlaylistLoaded(id),
          );
          final playlist = reloaded
              .read(libraryCollectionsProvider)
              .playlistById(id)!;
          expect(playlist.name, 'Public mix');
          expect(playlist.tracks.map((entry) => entry.track.toJson()), [
            first.toJson(),
            second.toJson(),
            first.toJson(),
          ]);
          expect(
            reloaded.read(libraryCollectionsProvider).playlistById(keep),
            isNotNull,
          );
        }
      },
    );
  }
}
