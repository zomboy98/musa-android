import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_playlist_drag_batch.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/widgets/library_playlist_drag_source.dart';

UnifiedLibraryItem song(String id) => UnifiedLibraryItem(
  id: id,
  trackName: 'Same title',
  artistName: 'Same artist',
  albumName: '',
  filePath: '/$id.flac',
  addedAt: DateTime(2026),
  source: LibraryItemSource.local,
);

void main() {
  for (final newGesture in [false, true]) {
    test(
      'late drop preserves newer selection or gesture ($newGesture)',
      () async {
        var token = Object();
        final selected = <String>{'local_a'};
        final loading = Completer<List<UnifiedLibraryItem>>();
        final writing = Completer<void>();
        final batch = LibraryPlaylistDragBatch();
        batch.freeze(selected, (_) => loading.future, selectionToken: token);
        final completed = () async {
          await batch.result;
          await writing.future;
          if (batch.ownsSelection(token, selected)) {
            selected.clear();
          }
        }();
        loading.complete([song('local_a')]);
        await Future<void>.delayed(Duration.zero);
        token = Object();
        if (!newGesture) {
          selected
            ..clear()
            ..add('local_b');
        }
        writing.complete();
        await completed;
        expect(selected, {newGesture ? 'local_a' : 'local_b'});
      },
    );
  }

  test('unchanged selection is owned until completed drop clears it', () async {
    final token = Object();
    final selected = <String>{'local_a'};
    final batch = LibraryPlaylistDragBatch();
    batch.freeze(
      selected,
      (_) async => [song('local_a')],
      selectionToken: token,
    );
    await batch.result;
    expect(batch.ownsSelection(token, selected), isTrue);
    expect(batch.ownsSelection(token, {'local_b'}), isFalse);
    selected.clear();
    expect(batch.ownsSelection(token, selected), isFalse);
  });

  testWidgets('cancelled drag completes lookup without adding songs', (
    tester,
  ) async {
    final loading = Completer<List<UnifiedLibraryItem>>();
    final batch = LibraryPlaylistDragBatch();
    var ended = false;
    var accepted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              DragTarget<LibraryPlaylistDragBatch>(
                onAcceptWithDetails: (_) => accepted = true,
                builder: (_, _, _) => const SizedBox(width: 200, height: 100),
              ),
              LibraryPlaylistDragSource<LibraryPlaylistDragBatch>(
                data: batch,
                onSelect: () =>
                    batch.freeze(['local_a'], (_) => loading.future),
                onDragStarted: () {},
                onDragEnd: () => ended = true,
                feedbackBuilder: (_) => const Material(child: Text('Loading')),
                child: const SizedBox(
                  width: 200,
                  height: 100,
                  child: Text('Song A'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song A')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();
    loading.completeError(StateError('cancelled gesture lookup failed'));
    await tester.pumpAndSettle();
    expect(ended, isTrue);
    expect(accepted, isFalse);
    expect((await batch.result).failed, isTrue);
    expect(tester.takeException(), isNull);
  });

  test(
    'snapshot preserves order and distinct records with identical metadata',
    () async {
      final selected = ['local_a', 'local_b'];
      final batch = LibraryPlaylistDragBatch();
      final loading = Completer<List<UnifiedLibraryItem>>();
      batch.freeze(selected, (_) => loading.future);
      selected.clear();
      batch.freeze(['local_c'], (_) async => [song('local_c')]);
      loading.complete([song('local_b'), song('local_a')]);
      final result = await batch.result;
      expect(result.failed, isFalse);
      expect(result.items.map((e) => e.id), ['local_a', 'local_b']);
      expect(() => result.items.clear(), throwsUnsupportedError);
    },
  );

  for (final throwsError in [false, true]) {
    test(
      'missing song or failed lookup rejects whole batch ($throwsError)',
      () async {
        final batch = LibraryPlaylistDragBatch();
        batch.freeze(['local_a', 'local_b'], (_) async {
          if (throwsError) throw StateError('database unavailable');
          return [song('local_a')];
        });
        final result = await batch.result;
        expect(result.failed, isTrue);
        expect(result.items, isEmpty);
      },
    );
  }

  testWidgets(
    'filtered drag freezes hidden selected song for feedback and drop',
    (tester) async {
      final selected = <String>{'local_a', 'local_b'};
      final loading = Completer<List<UnifiedLibraryItem>>();
      final dropped = <String>[];
      List<String>? requested;
      final batch = LibraryPlaylistDragBatch();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                DragTarget<LibraryPlaylistDragBatch>(
                  onAcceptWithDetails: (details) async {
                    final resolved = await details.data.result;
                    if (!resolved.failed) {
                      dropped.addAll(resolved.items.map((e) => e.id));
                    }
                  },
                  builder: (_, _, _) => const SizedBox(
                    key: ValueKey('target'),
                    width: 200,
                    height: 100,
                    child: Text('Playlist'),
                  ),
                ),
                // The filter shows A only; B remains selected outside the visible list.
                LibraryPlaylistDragSource<LibraryPlaylistDragBatch>(
                  data: batch,
                  onSelect: () => batch.freeze(selected, (ids) {
                    requested = ids;
                    return loading.future;
                  }),
                  onDragStarted: () {},
                  onDragEnd: () {},
                  feedbackBuilder: (_) =>
                      FutureBuilder<LibraryPlaylistDragResult>(
                        future: batch.result,
                        builder: (_, snapshot) => Material(
                          child: Text(
                            snapshot.hasData
                                ? 'Dragging ${snapshot.data!.items.length}'
                                : 'Loading',
                          ),
                        ),
                      ),
                  child: const SizedBox(
                    width: 200,
                    height: 100,
                    child: Text('Song A'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Song A')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(requested, ['local_a', 'local_b']);
      expect(find.text('Loading'), findsOneWidget);
      selected.clear(); // Later selection changes cannot change the gesture.
      loading.complete([song('local_a'), song('local_b')]);
      await tester.pumpAndSettle();
      expect(find.text('Dragging 2'), findsOneWidget);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('target'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(dropped, ['local_a', 'local_b']);
      expect(tester.takeException(), isNull);
    },
  );
}
