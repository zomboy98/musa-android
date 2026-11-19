import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/collection_reorder_sliver.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

final _entries = [
  for (final id in ['a', 'b', 'c'])
    CollectionTrackEntry(
      key: id,
      addedAt: DateTime(2026),
      track: Track(
        // Two occurrences of one catalog track must stay independently selectable.
        id: id == 'c' ? 'a' : id,
        name: 'Song $id',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      ),
    ),
];

class _Collections extends LibraryCollectionsNotifier {
  _Collections(this.entries);

  final List<CollectionTrackEntry> entries;
  int _writes = 0;
  bool _failSave = false;
  bool _changedMembership = false;

  void removeLovedForTest(String key) {
    state = state.copyWith(
      loved: state.loved.where((e) => e.key != key).toList(),
    );
  }

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    loved: entries,
    playlists: [
      UserPlaylistCollection(
        id: 'mix',
        name: 'My mix',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: entries,
      ),
    ],
  );

  @override
  Future<void> ensurePlaylistLoaded(String id) async {}

  @override
  Future<bool> reorderPlaylistTracks(
    String id,
    List<String> keys, {
    List<String>? expectedOrder,
  }) async {
    if (_failSave) throw StateError('Storage unavailable');
    _writes++;
    final playlist = state.playlistById(id)!;
    final byKey = {for (final entry in playlist.tracks) entry.key: entry};
    state = state.copyWith(
      playlists: [
        playlist.copyWith(tracks: [for (final key in keys) byKey[key]!]),
      ],
    );
    return true;
  }

  @override
  Future<bool> reorderSavedTracks(
    LibraryTracksFolderMode mode,
    List<String> keys, {
    List<String>? expectedOrder,
  }) async {
    if (_failSave) throw StateError('Storage unavailable');
    if (_changedMembership) return false;
    _writes++;
    final byKey = {for (final entry in this.entries) entry.key: entry};
    final entries = [for (final key in keys) byKey[key]!];
    state = mode == LibraryTracksFolderMode.loved
        ? state.copyWith(loved: entries)
        : state.copyWith();
    return true;
  }
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Host extends LinkDesktopHost {
  @override
  LinkDesktopHostState build() => const LinkDesktopHostState();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<_Collections> open(
    WidgetTester tester, {
    bool desktop = false,
    bool mornye = false,
    bool enterEditor = true,
    List<CollectionTrackEntry>? entries,
    double mobileHeight = 1000,
    LibraryTracksFolderMode mode = LibraryTracksFolderMode.loved,
  }) async {
    debugDesktopPlatformOverride = desktop;
    tester.view.physicalSize = desktop
        ? const Size(1200, 900)
        : Size(430, mobileHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final collections = _Collections(entries ?? _entries);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          libraryCollectionsProvider.overrideWith(() => collections),
          linkDesktopHostProvider.overrideWith(_Host.new),
          localLibraryProvider.overrideWith(_Library.new),
          downloadHistoryProvider.overrideWith(_History.new),
          downloadHistoryVisibleBatchExistsProvider.overrideWith(
            (ref, request) => const {},
          ),
          localLibraryCoverProvider.overrideWith((ref, request) async => null),
          localLibraryFirstCoverProvider.overrideWith(
            (ref, request) async => null,
          ),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryTracksFolderScreen(
            mode: mode,
            playlistId: mode == LibraryTracksFolderMode.playlist ? 'mix' : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!enterEditor) return collections;
    await tester.tap(find.byKey(const ValueKey('collection-edit-order')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryTracksFolderScreen), findsOneWidget);
    expect(find.byType(CollectionReorderSliver), findsOneWidget);
    return collections;
  }

  Future<void> moveFirstToLast(
    WidgetTester tester, {
    bool holdRow = false,
    bool desktop = false,
  }) async {
    final handle = find.byKey(const ValueKey('collection-order-handle-a'));
    await tester.ensureVisible(handle);
    await tester.pumpAndSettle();
    final origin = holdRow
        ? tester.getCenter(find.text('Song a'))
        : tester.getCenter(handle);
    final lastBottom = tester.getBottomRight(
      find.byKey(const ValueKey('collection-order-handle-c')),
    );
    final target = Offset(origin.dx, lastBottom.dy + 80);
    final gesture = await tester.startGesture(
      origin,
      kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
    );
    if (holdRow) await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveBy(const Offset(0, 4));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(target);
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CollectionReorderSliver>(find.byType(CollectionReorderSliver))
          .entries
          .map((entry) => entry.key),
      ['b', 'c', 'a'],
    );
  }

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      for (final mode in LibraryTracksFolderMode.values) {
        testWidgets(
          'reorder ${mode.name} in place (desktop=$desktop, mornye=$mornye)',
          (tester) async {
            final semantics = desktop && !mornye
                ? tester.ensureSemantics()
                : null;
            try {
              final collections = await open(
                tester,
                desktop: desktop,
                mornye: mornye,
                mode: mode,
              );
              await moveFirstToLast(
                tester,
                desktop: desktop,
                holdRow: !desktop,
              );
              expect(collections._writes, 0);
              await tester.tap(
                find.byKey(const ValueKey('collection-order-save')),
              );
              await tester.pumpAndSettle();
              expect(collections._writes, 1);
              expect(find.byType(CollectionReorderSliver), findsNothing);
              expect(find.text('Song order saved'), findsOneWidget);
              expect(tester.takeException(), isNull);
            } finally {
              semantics?.dispose();
            }
          },
        );
      }
    }
  }

  testWidgets('discard keeps the original order', (tester) async {
    final collections = await open(tester);
    await moveFirstToLast(tester);
    await tester.tap(find.byTooltip('Close').first);
    await tester.pumpAndSettle();
    expect(find.text('Discard Changes?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(CollectionReorderSliver), findsNothing);
    expect(collections._writes, 0);
  });

  testWidgets('selected occurrences move together and save', (tester) async {
    final collections = await open(tester);
    await tester.tap(find.byKey(const ValueKey('collection-order-select-a')));
    await tester.tap(find.byKey(const ValueKey('collection-order-select-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('collection-order-group-down')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CollectionReorderSliver>(find.byType(CollectionReorderSliver))
          .entries
          .map((entry) => entry.key),
      ['c', 'a', 'b'],
    );
    expect(collections._writes, 0);
    await tester.tap(find.byKey(const ValueKey('collection-order-save')));
    await tester.pumpAndSettle();
    expect(collections._writes, 1);
  });

  for (final mode in LibraryTracksFolderMode.values) {
    testWidgets('selection enters order editor for ${mode.name}', (
      tester,
    ) async {
      final collections = await open(
        tester,
        mode: mode,
        enterEditor: false,
        mobileHeight: 1400,
      );
      await tester.longPress(find.text('Song a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Song c'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('collection-selection-edit-order')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CollectionReorderSliver), findsOneWidget);
      for (final key in ['a', 'c']) {
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(ValueKey('collection-order-select-$key')),
              )
              .value,
          isTrue,
        );
      }
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('collection-order-select-b')),
            )
            .value,
        isFalse,
      );
      await tester.tap(
        find.byKey(const ValueKey('collection-order-group-down')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CollectionReorderSliver>(
              find.byType(CollectionReorderSliver),
            )
            .entries
            .map((e) => e.key),
        ['b', 'a', 'c'],
      );
      await tester.tap(find.byKey(const ValueKey('collection-order-save')));
      await tester.pumpAndSettle();
      final state = collections.state;
      final saved = mode == LibraryTracksFolderMode.playlist
          ? state.playlistById('mix')!.tracks
          : state.loved;
      expect(saved.map((e) => e.key), ['b', 'a', 'c']);
    });
  }

  testWidgets('discard selected group order preserves collection', (
    tester,
  ) async {
    final collections = await open(
      tester,
      enterEditor: false,
      mobileHeight: 1400,
    );
    await tester.longPress(find.text('Song a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song c'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('collection-selection-edit-order')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('collection-order-group-down')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(collections._writes, 0);
    expect(collections.state.loved.map((e) => e.key), ['a', 'b', 'c']);
    expect(find.text('2 selected'), findsWidgets);
  });

  testWidgets('cancel restores only selected entries still in collection', (
    tester,
  ) async {
    final collections = await open(
      tester,
      enterEditor: false,
      mobileHeight: 1400,
    );
    await tester.longPress(find.text('Song a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song c'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('collection-selection-edit-order')),
    );
    await tester.pumpAndSettle();
    collections.removeLovedForTest('c');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close').first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsWidgets);
    expect(find.text('Song c'), findsNothing);
    expect(collections.state.loved.map((e) => e.key), ['a', 'b']);
    expect(collections._writes, 0);
  });

  testWidgets('membership conflict restores surviving original selection', (
    tester,
  ) async {
    final collections = await open(
      tester,
      enterEditor: false,
      mobileHeight: 1400,
    );
    await tester.longPress(find.text('Song a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song c'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('collection-selection-edit-order')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('collection-order-group-down')));
    await tester.pumpAndSettle();
    collections.removeLovedForTest('c');
    collections._changedMembership = true;
    await tester.tap(find.byKey(const ValueKey('collection-order-save')));
    await tester.pumpAndSettle();
    expect(find.byType(CollectionReorderSliver), findsNothing);
    expect(find.text('1 selected'), findsWidgets);
    expect(collections.state.loved.map((e) => e.key), ['a', 'b']);
    expect(collections._writes, 0);
    expect(
      find.text(
        'This collection changed while editing. Please reorder it again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('order conflict restores selection made in editor', (
    tester,
  ) async {
    final collections = await open(tester);
    await tester.tap(find.byKey(const ValueKey('collection-order-select-a')));
    await tester.tap(find.byKey(const ValueKey('collection-order-select-c')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('collection-order-group-down')));
    await tester.pumpAndSettle();
    collections._changedMembership = true;
    await tester.tap(find.byKey(const ValueKey('collection-order-save')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsWidgets);
    expect(
      find.text(
        'This collection changed while editing. Please reorder it again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('selection checkbox identifies its track to accessibility', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await open(tester);
      final checkbox = find.byKey(const ValueKey('collection-order-select-a'));
      expect(tester.getSemantics(checkbox).label, contains('Song a'));
      expect(tester.getSemantics(checkbox).label, contains('Artist'));
    } finally {
      semantics.dispose();
    }
  });

  for (final scenario in [
    (selected: ['a', 'b'], row: 'a', down: true, expected: ['c', 'a', 'b']),
    (selected: ['b', 'c'], row: 'c', down: false, expected: ['b', 'c', 'a']),
    // a and c are distinct occurrences of the same catalog track.
    (selected: ['a', 'c'], row: 'a', down: true, expected: ['b', 'a', 'c']),
    (selected: ['a', 'c'], row: 'c', down: false, expected: ['a', 'c', 'b']),
    (selected: ['b', 'c'], row: 'a', down: true, expected: ['b', 'a', 'c']),
  ]) {
    testWidgets('accessible move respects occurrences $scenario', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final collections = await open(tester, desktop: true);
        for (final key in scenario.selected) {
          await tester.tap(
            find.byKey(ValueKey('collection-order-select-$key')),
          );
        }
        await tester.pumpAndSettle();
        final row = find
            .ancestor(
              of: find.byKey(
                ValueKey('collection-order-handle-${scenario.row}'),
              ),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics &&
                    widget.properties.customSemanticsActions?.isNotEmpty ==
                        true,
              ),
            )
            .first;
        final node = tester.getSemantics(row);
        final actionId = node
            .getSemanticsData()
            .customSemanticsActionIds!
            .singleWhere(
              (id) =>
                  CustomSemanticsAction.getAction(id)!.label ==
                  (scenario.down ? 'Move down' : 'Move up'),
            );
        tester.binding.pipelineOwner.semanticsOwner!.performAction(
          node.id,
          SemanticsAction.customAction,
          actionId,
        );
        await tester.pumpAndSettle();
        final expected = scenario.expected;
        expect(
          tester
              .widget<CollectionReorderSliver>(
                find.byType(CollectionReorderSliver),
              )
              .entries
              .map((entry) => entry.key),
          expected,
        );
        await tester.tap(find.byKey(const ValueKey('collection-order-save')));
        await tester.pumpAndSettle();
        expect(collections.state.loved.map((entry) => entry.key), expected);
        expect(collections._writes, 1);
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final scenario in [
    (selected: ['a', 'b'], absent: ['Move up']),
    (selected: ['b', 'c'], absent: ['Move down']),
    (selected: ['a', 'b', 'c'], absent: ['Move up', 'Move down']),
  ]) {
    testWidgets('group controls respect collection boundary $scenario', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final collections = await open(tester, desktop: true);
        for (final key in scenario.selected) {
          await tester.tap(
            find.byKey(ValueKey('collection-order-select-$key')),
          );
        }
        await tester.pumpAndSettle();
        final row = find
            .ancestor(
              of: find.byKey(const ValueKey('collection-order-handle-b')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics &&
                    widget.properties.customSemanticsActions != null,
              ),
            )
            .first;
        final ids =
            tester
                .getSemantics(row)
                .getSemanticsData()
                .customSemanticsActionIds ??
            const <int>[];
        final labels = ids.map(
          (id) => CustomSemanticsAction.getAction(id)!.label,
        );
        for (final (direction, label) in [
          ('up', 'Move up'),
          ('down', 'Move down'),
        ]) {
          final button = tester.widget<IconButton>(
            find.byKey(ValueKey('collection-order-group-$direction')),
          );
          expect(button.tooltip, label);
          expect(
            button.onPressed,
            scenario.absent.contains(label) ? isNull : isNotNull,
          );
        }
        for (final label in scenario.absent) {
          expect(labels, isNot(contains(label)));
        }
        expect(collections._writes, 0);
        expect(
          tester
              .widget<ExpressiveButton>(
                find.byKey(const ValueKey('collection-order-save')),
              )
              .onPressed,
          isNull,
        );
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final desktop in [false, true]) {
    testWidgets(
      'group controls stay reachable while scrolling (desktop=$desktop)',
      (tester) async {
        final entries = [
          for (var i = 0; i < 50; i++)
            CollectionTrackEntry(
              key: 'long-$i',
              addedAt: DateTime(2026),
              track: _entries.first.track,
            ),
        ];
        final collections = await open(
          tester,
          desktop: desktop,
          mobileHeight: 640,
          entries: entries,
        );
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        final controls = find.byKey(
          const ValueKey('collection-order-group-down'),
        );
        final save = find.byKey(const ValueKey('collection-order-save'));
        scroll.position.jumpTo(1200);
        await tester.pumpAndSettle();
        expect(controls.hitTestable(), findsOneWidget);
        expect(save.hitTestable(), findsOneWidget);
        expect(
          tester.getCenter(controls).dy,
          greaterThan(tester.getCenter(save).dy),
        );

        final middle = find.byKey(
          const ValueKey('collection-order-select-long-20'),
        );
        await tester.scrollUntilVisible(middle, 150);
        await tester.pumpAndSettle();
        await tester.tap(middle);
        await tester.pumpAndSettle();
        await tester.tap(controls);
        await tester.pumpAndSettle();
        List<String> draft() => tester
            .widget<CollectionReorderSliver>(
              find.byType(CollectionReorderSliver),
            )
            .entries
            .map((entry) => entry.key)
            .toList();
        expect(draft().indexOf('long-20'), 21);

        final group = ['long-21', 'long-20'];
        final second = find.byKey(
          const ValueKey('collection-order-select-long-21'),
        );
        await tester.scrollUntilVisible(second, 100);
        await tester.tap(second);
        await tester.pumpAndSettle();

        final handle = find.byKey(
          const ValueKey('collection-order-handle-long-20'),
        );
        final viewport = tester.getRect(find.byType(Scrollable).first);
        for (final down in [true, false]) {
          if (!down) {
            scroll.position.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(handle);
          await tester.pumpAndSettle();
          expect(handle.hitTestable(), findsOneWidget);
          final before = scroll.position.pixels;
          final origin = tester.getCenter(handle);
          final gesture = await tester.startGesture(
            origin,
            kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
          );
          await gesture.moveBy(Offset(0, down ? 26 : -26));
          await tester.pump(const Duration(milliseconds: 100));
          await gesture.moveTo(
            Offset(origin.dx, down ? viewport.bottom - 2 : viewport.top + 2),
          );
          await tester.pump();
          expect(tester.widget<IconButton>(controls).onPressed, isNull);
          for (var i = 0; i < 280; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            if (down
                ? scroll.position.pixels >= scroll.position.maxScrollExtent
                : scroll.position.pixels <= scroll.position.minScrollExtent) {
              break;
            }
          }
          expect(
            scroll.position.pixels,
            down ? greaterThan(before) : lessThan(before),
          );
          if (down) {
            expect(
              scroll.position.pixels,
              closeTo(scroll.position.maxScrollExtent, 0.5),
            );
          }
          await gesture.up();
          await tester.pumpAndSettle();
          final keys = draft();
          expect(down ? keys.skip(keys.length - 2) : keys.take(2), group);
          expect(
            keys.where((key) => !group.contains(key)),
            entries
                .map((entry) => entry.key)
                .where((key) => !group.contains(key)),
          );
        }

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();
        expect(find.byType(LibraryTracksFolderScreen), findsOneWidget);
        expect(find.byType(CollectionReorderSliver), findsNothing);
        expect(collections._writes, 0);
      },
    );
  }

  testWidgets('dragging one selected handle moves the whole group', (
    tester,
  ) async {
    await open(tester, desktop: true);
    await tester.tap(find.byKey(const ValueKey('collection-order-select-a')));
    await tester.tap(find.byKey(const ValueKey('collection-order-select-b')));
    await tester.pumpAndSettle();
    final handle = find.byKey(const ValueKey('collection-order-handle-a'));
    final origin = tester.getCenter(handle);
    final end = tester.getBottomRight(
      find.byKey(const ValueKey('collection-order-handle-c')),
    );
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 4));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(Offset(origin.dx, end.dy + 80));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CollectionReorderSliver>(find.byType(CollectionReorderSliver))
          .entries
          .map((entry) => entry.key),
      ['c', 'a', 'b'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'nonadjacent occurrences move independently of catalog identity',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('collection-order-select-a')));
      await tester.tap(find.byKey(const ValueKey('collection-order-select-c')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('collection-order-group-down')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CollectionReorderSliver>(
              find.byType(CollectionReorderSliver),
            )
            .entries
            .map((entry) => entry.key),
        ['b', 'a', 'c'],
      );
      await tester.tap(find.byKey(const ValueKey('collection-order-group-up')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CollectionReorderSliver>(
              find.byType(CollectionReorderSliver),
            )
            .entries
            .map((entry) => entry.key),
        ['a', 'c', 'b'],
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('collection-order-select-b')),
            )
            .value,
        isFalse,
      );
    },
  );

  testWidgets('dragging a selected last row upward keeps group order', (
    tester,
  ) async {
    await open(tester, desktop: true);
    await tester.tap(find.byKey(const ValueKey('collection-order-select-b')));
    await tester.tap(find.byKey(const ValueKey('collection-order-select-c')));
    await tester.pumpAndSettle();
    final origin = tester.getCenter(
      find.byKey(const ValueKey('collection-order-handle-c')),
    );
    final firstTop = tester.getTopLeft(
      find.byKey(const ValueKey('collection-order-handle-a')),
    );
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -4));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(Offset(origin.dx, firstTop.dy - 80));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CollectionReorderSliver>(find.byType(CollectionReorderSliver))
          .entries
          .map((entry) => entry.key),
      ['b', 'c', 'a'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dragging an unselected handle preserves the selected occurrences',
    (tester) async {
      await open(tester, desktop: true);
      await tester.tap(find.byKey(const ValueKey('collection-order-select-b')));
      await tester.tap(find.byKey(const ValueKey('collection-order-select-c')));
      await tester.pumpAndSettle();
      await moveFirstToLast(tester, desktop: true);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('collection-order-select-b')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('collection-order-select-c')),
            )
            .value,
        isTrue,
      );
    },
  );

  testWidgets('selection and group buttons stay fixed during a drag', (
    tester,
  ) async {
    await open(tester, desktop: true);
    await tester.tap(find.byKey(const ValueKey('collection-order-select-a')));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('collection-order-handle-a'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('collection-order-select-b')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('collection-order-group-down')),
          )
          .onPressed,
      isNull,
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('collection-order-select-b')),
          )
          .onChanged,
      isNotNull,
    );
  });

  testWidgets('failed save keeps the draft available for retry', (
    tester,
  ) async {
    final collections = await open(tester);
    collections._failSave = true;
    await moveFirstToLast(tester);
    await tester.tap(find.byKey(const ValueKey('collection-order-save')));
    await tester.pumpAndSettle();
    expect(find.byType(CollectionReorderSliver), findsOneWidget);
    expect(
      find.text('Could not save the song order. Try again.'),
      findsOneWidget,
    );
    expect(collections._writes, 0);
  });

  testWidgets('cancelling a drag leaves previous edits ready to save', (
    tester,
  ) async {
    final collections = await open(tester);
    await moveFirstToLast(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('collection-order-handle-b'))),
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<ExpressiveButton>(
            find.byKey(const ValueKey('collection-order-save')),
          )
          .onPressed,
      isNull,
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ExpressiveButton>(
            find.byKey(const ValueKey('collection-order-save')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('collection-order-save')));
    await tester.pumpAndSettle();
    expect(collections._writes, 1);
  });
}
