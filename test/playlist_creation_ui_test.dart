import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/playlist_reorder_page.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Collections extends LibraryCollectionsNotifier {
  final orders = <List<String>>[];
  List<String>? expected;
  bool conflict = false;
  Completer<bool>? pending;
  final createdNames = <String>[];

  @override
  LibraryCollectionsState build() {
    final added = DateTime(2026, 10, 1);
    return LibraryCollectionsState(
      isLoaded: true,
      playlists: [
        UserPlaylistCollection(
          id: 'mix',
          name: 'Mix',
          createdAt: added,
          updatedAt: added,
          tracks: [
            for (final name in ['First', 'Second', 'Third'])
              CollectionTrackEntry(
                key: name,
                track: Track(
                  id: name,
                  name: name,
                  artistName: 'Artist',
                  albumName: 'Album',
                  duration: 180,
                ),
                addedAt: added,
              ),
          ],
        ),
      ],
    );
  }

  @override
  Future<bool> reorderPlaylistTracks(
    String playlistId,
    List<String> orderedKeys, {
    List<String>? expectedOrder,
  }) async {
    expected = expectedOrder;
    orders.add(orderedKeys);
    if (pending != null) return pending!.future;
    if (conflict) return false;
    return true;
  }

  @override
  Future<String> createPlaylist(String name) async {
    createdNames.add(name);
    return name;
  }
}

Widget _app(Widget home, _Collections collections, {required bool mornye}) =>
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        libraryCollectionsProvider.overrideWith(() => collections),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'legacy original order clears changes and pending save blocks edits (Mornye: $mornye)',
      (tester) async {
        final collections = _Collections()..pending = Completer<bool>();
        await tester.pumpWidget(
          _app(
            const PlaylistReorderPage(playlistId: 'mix'),
            collections,
            mornye: mornye,
          ),
        );
        void reorder(int oldIndex, int newIndex) => tester
            .widget<SliverReorderableList>(find.byType(SliverReorderableList))
            .onReorderItem!(oldIndex, newIndex);
        reorder(0, 1);
        await tester.pump();
        expect(find.text('Save'), findsOneWidget);
        reorder(1, 0);
        await tester.pump();
        expect(find.text('Save'), findsNothing);
        reorder(0, 1);
        await tester.pump();
        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(
          tester
              .widget<AbsorbPointer>(
                find
                    .ancestor(
                      of: find.text('Save'),
                      matching: find.byType(AbsorbPointer),
                    )
                    .first,
              )
              .absorbing,
          isTrue,
        );
        reorder(1, 2);
        await tester.pump();
        expect(collections.orders.single, ['Second', 'First', 'Third']);
        collections.pending!.complete(false);
        await tester.pumpAndSettle();
        final list = tester.widget<SliverReorderableList>(
          find.byType(SliverReorderableList),
        );
        expect(
          list
              .itemBuilder(
                tester.element(find.byType(SliverReorderableList)),
                0,
              )
              .key,
          const ValueKey('Second'),
        );
      },
    );
    testWidgets('dragging a handle reorders and saves (Mornye: $mornye)', (
      tester,
    ) async {
      final collections = _Collections();
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const PlaylistReorderPage(playlistId: 'mix'),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
          collections,
          mornye: mornye,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsNothing);

      final handles = find.byWidgetPredicate(
        (widget) => widget is AppIcon && widget.icon == Icons.drag_handle,
      );
      expect(handles, findsNWidgets(3));
      final rowHeight =
          tester.getTopLeft(handles.at(1)).dy -
          tester.getTopLeft(handles.at(0)).dy;
      final gesture = await tester.startGesture(
        tester.getCenter(handles.at(2)),
      );
      await tester.pump();
      for (var step = 0; step < 10; step++) {
        await gesture.moveBy(Offset(0, -rowHeight * 0.25));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(collections.orders, [
        ['Third', 'First', 'Second'],
      ]);
      expect(collections.expected, ['First', 'Second', 'Third']);
      expect(find.text('Playlist order saved'), findsOneWidget);
      expect(find.byType(PlaylistReorderPage), findsNothing);
    });

    testWidgets('legacy conflict keeps edits open (Mornye: $mornye)', (
      tester,
    ) async {
      final collections = _Collections()..conflict = true;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const PlaylistReorderPage(playlistId: 'mix'),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
          collections,
          mornye: mornye,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final handles = find.byWidgetPredicate(
        (widget) => widget is AppIcon && widget.icon == Icons.drag_handle,
      );
      final rowHeight =
          tester.getTopLeft(handles.at(1)).dy -
          tester.getTopLeft(handles.at(0)).dy;
      final gesture = await tester.startGesture(
        tester.getCenter(handles.at(2)),
      );
      await tester.pump();
      for (var step = 0; step < 10; step++) {
        await gesture.moveBy(Offset(0, -rowHeight * 0.25));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(collections.expected, ['First', 'Second', 'Third']);
      expect(collections.orders.single, ['Third', 'First', 'Second']);
      expect(find.byType(PlaylistReorderPage), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(
        find.text(
          'This collection changed while editing. Please reorder it again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('create playlist offers three sources (Mornye: $mornye)', (
      tester,
    ) async {
      final collections = _Collections();
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => showCreatePlaylistSheet(context, ref),
                child: const Text('create'),
              ),
            ),
          ),
          collections,
          mornye: mornye,
        ),
      );
      await tester.tap(find.text('create'));
      await tester.pumpAndSettle();
      for (final title in [
        'Empty playlist',
        'From a folder',
        'Import playlist file',
      ]) {
        expect(find.text(title), findsOneWidget);
      }

      await tester.tap(find.text('Empty playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'Evening');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(collections.createdNames, ['Evening']);
    });
  }
}
