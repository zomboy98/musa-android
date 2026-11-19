import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';

const first = Track(
  id: '1',
  name: 'One',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 123,
);
const second = Track(
  id: '2',
  name: 'Two',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 234,
);

class FakeResolver implements LinkDownloadsPort {
  bool fail = false;
  int calls = 0;
  int downloads = 0;
  Completer<LinkResolvedLink>? pending;
  @override
  Future<LinkResolvedLink> resolveUrl(String url) async {
    calls++;
    if (pending != null) return pending!.future;
    if (fail) throw StateError('unavailable');
    return (tracks: [first, second, first], playlistName: 'Public mix');
  }

  @override
  int enqueue(
    List<Track> tracks, {
    String? service,
    String? quality,
    String? playlistName,
  }) {
    downloads++;
    return tracks.length;
  }
}

class FakeCollections extends LibraryCollectionsNotifier {
  String? name;
  List<Track> tracks = [];
  bool preserve = false;
  bool failAdd = false;
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
  @override
  Future<PlaylistAddBatchResult> createImportedPlaylist(
    String value,
    List<Track> selected,
  ) async {
    if (failAdd) throw StateError('write failed');
    name = value;
    tracks = List.of(selected);
    preserve = true;
    return PlaylistAddBatchResult(
      addedCount: tracks.length,
      alreadyInPlaylistCount: 0,
    );
  }
}

void main() {
  Future<void> open(
    WidgetTester tester,
    FakeResolver resolver,
    FakeCollections collections, {
    String? platform,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linkDesktopDownloadsProvider.overrideWithValue(resolver),
          libraryCollectionsProvider.overrideWith(() => collections),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    importPlaylistLink(context, ref, platform: platform),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/playlist',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'imports ordered occurrences with metadata and never enqueues downloads',
    (tester) async {
      final resolver = FakeResolver();
      final collections = FakeCollections();
      await open(tester, resolver, collections);
      await submit(tester);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(collections.name, 'Public mix');
      expect(collections.tracks, [first, second, first]);
      expect(collections.tracks.first.albumName, 'Album');
      expect(collections.preserve, isTrue);
      expect(resolver.downloads, 0);
    },
  );
  testWidgets('cancel and resolver errors do not create a playlist', (
    tester,
  ) async {
    final resolver = FakeResolver();
    final collections = FakeCollections();
    await open(tester, resolver, collections);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(resolver.calls, 0);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    resolver.fail = true;
    await submit(tester);
    expect(collections.name, isNull);
    expect(resolver.downloads, 0);
    expect(find.textContaining('Could not check the link'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('cancel during resolution ignores the eventual result', (
    tester,
  ) async {
    final resolver = FakeResolver()..pending = Completer<LinkResolvedLink>();
    final collections = FakeCollections();
    await open(tester, resolver, collections);
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/playlist',
    );
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Checking playlist'), findsOneWidget);
    expect(resolver.calls, 1);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    resolver.pending!.complete((tracks: [first], playlistName: 'Public mix'));
    await tester.pumpAndSettle();
    expect(collections.name, isNull);
    expect(resolver.downloads, 0);
    expect(find.text('Choose tracks'), findsNothing);
  });

  testWidgets('platform rejects a link from a different host', (tester) async {
    final resolver = FakeResolver();
    await open(tester, resolver, FakeCollections(), platform: 'Spotify');
    await tester.enterText(
      find.byType(TextField),
      'https://spotify.com.evil.test/playlist',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a Spotify link.'), findsOneWidget);
    expect(resolver.calls, 0);
    expect(resolver.downloads, 0);
  });

  testWidgets('a failed atomic write reports an error', (tester) async {
    final resolver = FakeResolver();
    final collections = FakeCollections()..failAdd = true;
    await open(tester, resolver, collections);
    await submit(tester);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(collections.name, isNull);
    expect(resolver.downloads, 0);
    expect(find.textContaining('Could not import the link'), findsOneWidget);
  });

  testWidgets('a second import is ignored while the first is resolving', (
    tester,
  ) async {
    final resolver = FakeResolver()..pending = Completer<LinkResolvedLink>();
    late BuildContext owner;
    late WidgetRef ownerRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linkDesktopDownloadsProvider.overrideWithValue(resolver)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) {
              owner = context;
              ownerRef = ref;
              return const Scaffold();
            },
          ),
        ),
      ),
    );
    unawaited(importPlaylistLink(owner, ownerRef));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/playlist',
    );
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await importPlaylistLink(owner, ownerRef);
    expect(resolver.calls, 1);
    expect(find.text('Checking playlist'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    resolver.pending!.complete((tracks: [first], playlistName: 'Public mix'));
    await tester.pumpAndSettle();
  });

  testWidgets('selection preserves occurrence order', (tester) async {
    final resolver = FakeResolver();
    final collections = FakeCollections();
    await open(tester, resolver, collections);
    await submit(tester);
    await tester.tap(find.byKey(const ValueKey('import_track_0')));
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(collections.tracks, [second, first]);
    expect(collections.preserve, isTrue);
  });
}
