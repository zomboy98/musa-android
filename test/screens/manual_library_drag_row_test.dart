import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/models/library_playlist_drag_batch.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/widgets/library_playlist_drag_source.dart';

Widget source(Widget child) =>
    LibraryPlaylistDragSource<LibraryPlaylistDragBatch>(
      data: LibraryPlaylistDragBatch(),
      onSelect: () {},
      onDragStarted: () {},
      onDragEnd: () {},
      feedbackBuilder: (_) => const Material(child: Text('drag')),
      child: child,
    );

void main() {
  test('batch membership reflects IDs frozen after an earlier query', () {
    final batch = LibraryPlaylistDragBatch();
    expect(batch.containsId('local_a'), isFalse);
    batch.freeze(['local_a'], (_) async => []);
    expect(batch.containsId('local_a'), isTrue);
    expect(batch.containsId('local_b'), isFalse);
  });

  testWidgets('drag update keeps its original callback across rebuild', (
    tester,
  ) async {
    var originalUpdates = 0;
    var replacementUpdates = 0;
    Widget build(bool replacement) => MaterialApp(
      home: Scaffold(
        body: LibraryPlaylistDragSource<Object>(
          data: Object(),
          onSelect: () {},
          onDragStarted: () {},
          onDragEnd: () {},
          onDragUpdate: (_) {
            if (replacement) {
              replacementUpdates++;
            } else {
              originalUpdates++;
            }
          },
          feedbackBuilder: (_) => const Material(child: Text('feedback')),
          child: const SizedBox(width: 300, height: 100, child: Text('source')),
        ),
      ),
    );
    await tester.pumpWidget(build(false));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('source')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(build(true));
    await gesture.moveBy(const Offset(30, 30));
    await tester.pump();
    expect(originalUpdates, greaterThan(0));
    expect(replacementUpdates, 0);
    await gesture.up();
    await tester.pump();
  });
  test(
    'frozen drag survives selection changes during load and write',
    () async {
      var token = Object();
      final selected = <String>{'local_a', 'local_b'};
      final loading = Completer<List<UnifiedLibraryItem>>();
      final writing = Completer<void>();
      final batch = LibraryPlaylistDragBatch();
      batch.freeze(selected, (_) => loading.future, selectionToken: token);
      final idsFuture = resolveManualLibraryDragIds(batch);
      selected
        ..clear()
        ..add('local_c');
      token = Object();
      UnifiedLibraryItem song(String id) => UnifiedLibraryItem(
        id: id,
        trackName: id,
        artistName: '',
        albumName: '',
        filePath: '/$id',
        addedAt: DateTime(2026),
        source: LibraryItemSource.local,
      );
      loading.complete([song('local_b'), song('local_a')]);
      final ids = (await idsFuture)!;
      expect(ids, ['local_a', 'local_b']);
      List<String>? written;
      final finished = writeManualLibraryMove(
        selected: ids,
        write: (snapshot) {
          written = snapshot;
          return writing.future;
        },
        ownsSelection: () => batch.ownsSelection(token, selected),
      );
      selected
        ..clear()
        ..add('local_d');
      token = Object();
      writing.complete();
      expect(await finished, isFalse);
      expect(written, ['local_a', 'local_b']);
      expect(selected, {'local_d'});
    },
  );

  test('failed drag batch cannot supply IDs for a move', () async {
    final batch = LibraryPlaylistDragBatch();
    batch.freeze(['local_missing'], (_) async => []);
    expect(await resolveManualLibraryDragIds(batch), isNull);
  });
  testWidgets('grid drag lands on the chosen card', (tester) async {
    var anchor = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GridView.count(
            crossAxisCount: 2,
            children: [
              for (final id in ['dl_a', 'local_b'])
                source(
                  ManualLibraryDragRow(
                    id: id,
                    selected: id == 'dl_a',
                    canAccept: id == 'local_b',
                    dragLabel: '1',
                    onDropBefore: (_) => anchor = id,
                    child: Center(child: Text(id)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('dl_a')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.text('local_b')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(anchor, 'local_b');
  });

  testWidgets('long press drags selected group to an unselected anchor', (
    tester,
  ) async {
    var drops = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              source(
                ManualLibraryDragRow(
                  id: 'dl_a',
                  selected: true,
                  canAccept: false,
                  dragLabel: '2',
                  onDropBefore: (_) => fail('selected target'),
                  child: const SizedBox(
                    height: 80,
                    width: 300,
                    child: Text('source'),
                  ),
                ),
              ),
              ManualLibraryDragRow(
                id: 'local_b',
                selected: false,
                canAccept: true,
                dragLabel: '2',
                onDropBefore: (_) => drops++,
                child: const SizedBox(
                  height: 80,
                  width: 300,
                  child: Text('anchor'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('source')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.text('anchor')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(drops, 1);
  });

  testWidgets('table row wrapper accepts a group drag before the target', (
    tester,
  ) async {
    var anchor = '';
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverTrackTable(
                  rows: const [
                    TrackTableRow(id: 'dl_a', title: 'source'),
                    TrackTableRow(id: 'local_b', title: 'anchor'),
                  ],
                  columns: const [TrackTableColumn.title],
                  selectedIds: const {'dl_a'},
                  onSelect: (_, _, _) {},
                  onActivate: (_) {},
                  rowWrapper: (context, id, child) => source(
                    ManualLibraryDragRow(
                      id: id,
                      selected: id == 'dl_a',
                      canAccept: id == 'local_b',
                      dragLabel: '1',
                      onDropBefore: (_) => anchor = id,
                      child: child,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('source')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.text('anchor')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(anchor, 'local_b');
  });

  testWidgets('same payload can be dropped on a playlist', (tester) async {
    LibraryPlaylistDragBatch? received;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              source(
                const SizedBox(width: 200, height: 80, child: Text('song')),
              ),
              DragTarget<LibraryPlaylistDragBatch>(
                onAcceptWithDetails: (details) => received = details.data,
                builder: (_, _, _) => const SizedBox(
                  width: 200,
                  height: 80,
                  child: Text('playlist'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('song')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.text('playlist')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(received, isNotNull);
  });
}
