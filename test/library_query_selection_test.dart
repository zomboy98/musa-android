import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/library_query_selection.dart';

void main() {
  test('selects the entire query without loading song models', () async {
    final selection = LibraryQuerySelection();
    final ids = await selection.resolve(
      scope: 'filtered',
      load: () async => List.generate(1000, (i) => 'local_$i'),
      isCurrent: () => true,
    );
    expect(ids, hasLength(1000));
    expect(selection.covers('filtered', ids!), isTrue);
    expect(selection.covers('other', ids), isFalse);
    expect(selection.covers('filtered', ids.take(300).toSet()), isFalse);
  });

  test('late lookup cannot overwrite a newer query or selection', () async {
    final selection = LibraryQuerySelection();
    final pending = Completer<List<String>>();
    var current = true;
    final result = selection.resolve(
      scope: 'old',
      load: () => pending.future,
      isCurrent: () => current,
    );
    current = false;
    final newer = await selection.resolve(
      scope: 'new',
      load: () async => ['local_new'],
      isCurrent: () => true,
    );
    pending.complete(['local_old']);
    expect(await result, isNull);
    expect(selection.covers('new', newer!), isTrue);
  });

  test('failed query preserves the previous complete selection', () async {
    final selection = LibraryQuerySelection();
    await selection.resolve(
      scope: 'old',
      load: () async => ['local_a'],
      isCurrent: () => true,
    );
    await expectLater(
      selection.resolve(
        scope: 'new',
        load: () async => throw StateError('disk'),
        isCurrent: () => true,
      ),
      throwsStateError,
    );
    expect(selection.covers('old', {'local_a'}), isTrue);
  });

  for (final action in ['delete', 'playback', 'conversion']) {
    test('$action resolves all selected models, preserving ID order', () async {
      final ids = List.generate(1000, (i) => 'local_$i');
      final result = await resolveLibrarySelectionItems(
        selectedIds: ids,
        load: () async => ids.reversed.toList(),
        idOf: (item) => item,
        isCurrent: () => true,
      );
      expect(result, ids);
    });
    test('$action never receives a partial or stale selection', () async {
      await expectLater(
        resolveLibrarySelectionItems(
          selectedIds: ['local_a', 'local_b'],
          load: () async => ['local_a'],
          idOf: (item) => item,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(
        await resolveLibrarySelectionItems(
          selectedIds: ['local_a'],
          load: () async => ['local_a'],
          idOf: (item) => item,
          isCurrent: () => false,
        ),
        isNull,
      );
    });
  }
}
