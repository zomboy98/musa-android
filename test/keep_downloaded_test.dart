import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/keep_downloaded_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/widgets/keep_downloaded_switch.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_home_fixture.dart';

final _t1 = libraryTrack('1');
final _t2 = libraryTrack('2');
final _t3 = libraryTrack('3');

class _FakeBackend implements KeepDownloadedBackend {
  _FakeBackend(this.files);

  /// Downloaded files by track id.
  final Map<String, List<String>> files;
  final deleted = <String>[];
  final enqueued = <String>[];
  final failing = <String>{};
  int? deleteLimit;
  bool deleteThrows = false;
  Completer<void>? gate;

  @override
  Future<List<String>> downloadedPaths(Track track) async =>
      List.of(files[track.id] ?? const []);

  @override
  Future<List<String>> deletePaths(List<String> paths) async {
    if (deleteThrows) throw StateError('delete failed');
    final done = deleteLimit == null ? paths : paths.take(deleteLimit!).toList();
    deleted.addAll(done);
    return done;
  }

  @override
  Future<void> enqueue(Track track, {DownloadOrigin? origin}) async {
    await gate?.future;
    if (failing.contains(track.id)) throw StateError('queue failed');
    enqueued.add(track.id);
  }
}

UserPlaylistCollection _playlist(String id, List<Track> tracks) =>
    UserPlaylistCollection(
      id: id,
      name: 'List $id',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      tracks: [for (final t in tracks) favoriteEntry(t)],
    );

/// Mounts [child] with a library of [saved] songs, [playlists] and the given
/// scopes already switched on.
Future<(ProviderContainer, _FakeBackend)> _mount(
  WidgetTester tester, {
  required Widget child,
  List<Track> saved = const [],
  List<UserPlaylistCollection> playlists = const [],
  Set<String> active = const {},
  Map<String, List<String>> files = const {},
  Set<String> failing = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    SavedLibraryTracksNotifier.storageKey: jsonEncode([
      for (final t in saved) t.toJson(),
    ]),
    KeepDownloadedNotifier.storageKey: active.toList(),
  });
  final backend = _FakeBackend({...files})..failing.addAll(failing);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...libraryHomeOverrides(playlists: playlists),
        keepDownloadedBackendProvider.overrideWithValue(backend),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    ProviderScope.containerOf(tester.element(find.byType(Scaffold))),
    backend,
  );
}

final _switch = find.byKey(const ValueKey('keep-downloaded-switch'));
bool _isOn(WidgetTester tester) => tester.widget<SwitchListTile>(_switch).value;

void main() {
  group('reference counting', () {
    test('a song needed by another active scope is not deleted', () {
      final plan = planKeepDownloadedRemoval(
        scope: keepPlaylistScope('p1'),
        activeScopes: {keepPlaylistScope('p1'), keepPlaylistScope('p2')},
        keysByScope: {
          keepPlaylistScope('p1'): {'a', 'b', 'c'},
          keepPlaylistScope('p2'): {'b'},
          keepLibraryScope: {'c'},
        },
      );
      // "c" belongs to the library, but the library switch is off.
      expect(plan.toDelete, {'a', 'c'});
      expect(plan.shared, {'b'});
    });

    test('an active library keeps its songs when a playlist is turned off', () {
      final plan = planKeepDownloadedRemoval(
        scope: keepPlaylistScope('p1'),
        activeScopes: {keepPlaylistScope('p1'), keepLibraryScope},
        keysByScope: {
          keepPlaylistScope('p1'): {'a', 'c'},
          keepLibraryScope: {'c'},
        },
      );
      expect(plan.toDelete, {'a'});
      expect(plan.shared, {'c'});
    });

    test('nothing shared deletes everything of the scope', () {
      final plan = planKeepDownloadedRemoval(
        scope: keepLibraryScope,
        activeScopes: {keepLibraryScope},
        keysByScope: {
          keepLibraryScope: {'a', 'b'},
        },
      );
      expect(plan.toDelete, {'a', 'b'});
      expect(plan.shared, isEmpty);
    });
  });

  testWidgets('turning on tells how many songs could not be queued', (
    tester,
  ) async {
    final (container, backend) = await _mount(
      tester,
      child: KeepDownloadedSwitch(scope: keepPlaylistScope('p1')),
      playlists: [
        _playlist('p1', [_t1, _t2, _t3]),
      ],
      files: {
        '2': ['/m/2.flac'],
      },
      failing: {'1', '3'},
    );
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(backend.enqueued, isEmpty);
    expect(
      container.read(keepDownloadedControllerProvider).lastEnqueueFailures,
      2,
    );
    expect(
      find.text('Could not queue 2 songs to keep downloaded.'),
      findsOneWidget,
    );
  });

  Future<_FakeBackend> turnOffWithFiles(
    WidgetTester tester, {
    int? deleteLimit,
    bool deleteThrows = false,
  }) async {
    final (_, backend) = await _mount(
      tester,
      child: KeepDownloadedSwitch(scope: keepPlaylistScope('p1')),
      playlists: [
        _playlist('p1', [_t1, _t2]),
      ],
      active: {keepPlaylistScope('p1')},
      files: {
        '1': ['/m/1.flac'],
        '2': ['/m/2.flac'],
      },
    );
    backend
      ..deleteLimit = deleteLimit
      ..deleteThrows = deleteThrows;
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off and delete'));
    await tester.pumpAndSettle();
    return backend;
  }

  testWidgets('turning off tells how many downloads could not be deleted', (
    tester,
  ) async {
    await turnOffWithFiles(tester, deleteLimit: 1);
    expect(find.text('1 download could not be deleted.'), findsOneWidget);
  });

  testWidgets('turning off says deleting failed when the delete throws', (
    tester,
  ) async {
    await turnOffWithFiles(tester, deleteThrows: true);
    expect(find.text('Could not delete the downloads.'), findsOneWidget);
    expect(find.text('Could not change this setting'), findsNothing);
  });

  testWidgets('the switch shows a progress indicator while it works', (
    tester,
  ) async {
    final (_, backend) = await _mount(
      tester,
      child: KeepDownloadedSwitch(scope: keepPlaylistScope('p1')),
      playlists: [
        _playlist('p1', [_t1]),
      ],
    );
    backend.gate = Completer<void>();
    expect(find.byKey(const ValueKey('keep-downloaded-busy')), findsNothing);
    await tester.tap(_switch);
    await tester.pump();
    expect(find.byKey(const ValueKey('keep-downloaded-busy')), findsOneWidget);
    backend.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('keep-downloaded-busy')), findsNothing);
  });

  testWidgets('turning on queues only what is not downloaded yet', (
    tester,
  ) async {
    final (container, backend) = await _mount(
      tester,
      child: KeepDownloadedSwitch(scope: keepPlaylistScope('p1')),
      playlists: [
        _playlist('p1', [_t1, _t2, _t3]),
      ],
      files: {
        '2': ['/m/2.flac'],
      },
    );
    expect(_isOn(tester), isFalse);
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(_isOn(tester), isTrue);
    expect(backend.enqueued, ['1', '3']);
    expect(backend.deleted, isEmpty);
    expect(
      container.read(keepDownloadedProvider),
      contains(keepPlaylistScope('p1')),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(KeepDownloadedNotifier.storageKey), [
      keepPlaylistScope('p1'),
    ]);
  });

  testWidgets('turning off asks first and cancel puts the switch back on', (
    tester,
  ) async {
    final (container, backend) = await _mount(
      tester,
      child: KeepDownloadedSwitch(scope: keepPlaylistScope('p1')),
      playlists: [
        _playlist('p1', [_t1, _t2]),
      ],
      active: {keepPlaylistScope('p1')},
      files: {
        '1': ['/m/1.flac'],
        '2': ['/m/2.flac'],
      },
    );
    expect(_isOn(tester), isTrue);
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(find.text('Turn off and delete 2 downloads?'), findsOneWidget);
    expect(find.text('Turn off and delete'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Turn off and delete 2 downloads?'), findsNothing);
    expect(_isOn(tester), isTrue);
    expect(backend.deleted, isEmpty);
    expect(
      container.read(keepDownloadedProvider),
      contains(keepPlaylistScope('p1')),
    );
  });

  testWidgets('confirming deletes only this list and keeps shared songs', (
    tester,
  ) async {
    final (container, backend) = await _mount(
      tester,
      child: KeepDownloadedSwitch(scope: keepPlaylistScope('p1')),
      playlists: [
        _playlist('p1', [_t1, _t2, _t3]),
        _playlist('p2', [_t2]),
      ],
      // The library (with t3) and p2 (with t2) keep their downloads on.
      saved: [_t3],
      active: {
        keepPlaylistScope('p1'),
        keepPlaylistScope('p2'),
        keepLibraryScope,
      },
      files: {
        '1': ['/m/1.flac'],
        '2': ['/m/2.flac'],
        '3': ['/m/3.flac'],
      },
    );
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    // Only t1 is exclusive to this list.
    expect(find.text('Turn off and delete 1 download?'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('keep-downloaded-shared-note')),
      findsOneWidget,
    );
    expect(find.textContaining('2 songs stay downloaded'), findsOneWidget);

    await tester.tap(find.text('Turn off and delete'));
    await tester.pumpAndSettle();
    expect(backend.deleted, ['/m/1.flac']);
    expect(_isOn(tester), isFalse);
    final active = container.read(keepDownloadedProvider);
    expect(active, isNot(contains(keepPlaylistScope('p1'))));
    expect(active, contains(keepPlaylistScope('p2')));
    expect(active, contains(keepLibraryScope));
  });

  testWidgets('the general library switch works with the same rule', (
    tester,
  ) async {
    final (container, backend) = await _mount(
      tester,
      child: const KeepDownloadedSwitch(scope: keepLibraryScope),
      saved: [_t1, _t2],
      active: {keepLibraryScope},
      files: {
        '1': ['/m/1.flac'],
        '2': ['/m/2.flac'],
      },
    );
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(find.text('Turn off and delete 2 downloads?'), findsOneWidget);
    await tester.tap(find.text('Turn off and delete'));
    await tester.pumpAndSettle();
    expect(backend.deleted, ['/m/1.flac', '/m/2.flac']);
    expect(container.read(keepDownloadedProvider), isEmpty);
    // The songs stay in the library.
    expect(container.read(savedLibraryTracksProvider).value, hasLength(2));
  });

  testWidgets('with no downloaded files the dialog says nothing is deleted', (
    tester,
  ) async {
    final (_, backend) = await _mount(
      tester,
      child: const KeepDownloadedSwitch(scope: keepLibraryScope),
      saved: [_t1],
      active: {keepLibraryScope},
    );
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(find.text('Turn off keeping downloads?'), findsOneWidget);
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(backend.deleted, isEmpty);
    expect(_isOn(tester), isFalse);
  });

  testWidgets('songs added to an active scope are queued, inactive ones not', (
    tester,
  ) async {
    final (container, backend) = await _mount(
      tester,
      child: const SizedBox(),
      active: {keepPlaylistScope('p1')},
    );
    final controller = container.read(keepDownloadedControllerProvider);
    await controller.onTracksAdded(keepPlaylistScope('p1'), [_t1]);
    await controller.onTracksAdded(keepPlaylistScope('p2'), [_t2]);
    await controller.onTracksAdded(keepLibraryScope, [_t3]);
    expect(backend.enqueued, ['1']);
  });
}
