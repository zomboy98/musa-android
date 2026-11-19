import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/screens/extension_collection_screens.dart';
import 'support/search_results_fixture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'selected Guest resolves exact catalog result and opens its profile',
    (tester) async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final queries = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'customSearchWithExtension') {
              final query = (call.arguments as Map)['query'] as String;
              queries.add(query);
              await Future<void>.delayed(Duration.zero);
              return [
                {'id': 'wrong-id', 'name': 'Guesthouse'},
                {'id': 'resolved-guest', 'name': 'Guest'},
              ];
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionProvider.overrideWith(
              () => SearchFixtureExtensions(searchFixtureAllFilters),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: Center(
                child: ClickableArtistName(
                  artistName: 'Tyler, The Creator feat. Guest',
                  artistId: 'wrong-first-id,wrong-second-id',
                  extensionId: 'example',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Tyler, The Creator feat. Guest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guest'));
      await tester.pumpAndSettle();
      expect(queries, ['Guest']);
      final profile = tester.widget<ExtensionArtistScreen>(
        find.byType(ExtensionArtistScreen),
      );
      expect(profile.artistId, 'resolved-guest');
      expect(profile.artistName, 'Guest');
    },
  );

  testWidgets('mixed separators offer every artist and resolve the selection', (
    tester,
  ) async {
    const channel = MethodChannel('com.zarz.mornye/backend');
    final queries = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'customSearchWithExtension') {
            final query = (call.arguments as Map)['query'] as String;
            queries.add(query);
            return [
              {'id': 'resolved-$query', 'name': query},
            ];
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionProvider.overrideWith(
            () => SearchFixtureExtensions(searchFixtureAllFilters),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(
              child: ClickableArtistName(
                artistName: 'A & B feat. C',
                artistId: 'untrusted1,untrusted2',
                extensionId: 'example',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('A & B feat. C'));
    await tester.pumpAndSettle();
    expect(find.text('A & B'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    await tester.tap(find.text('C'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(queries, ['C']);
    expect(
      tester
          .widget<ExtensionArtistScreen>(find.byType(ExtensionArtistScreen))
          .artistId,
      'resolved-C',
    );
  });

  for (final topCard in [true, false]) {
    testWidgets(
      'wide search artist activates song without opening artist credits ($topCard)',
      (tester) async {
        const channel = MethodChannel('com.zarz.mornye/backend');
        final queries = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'customSearchWithExtension') {
            final query = (call.arguments as Map)['query'] as String;
            queries.add(query);
            return [
              {'id': 'resolved-$query', 'name': query},
            ];
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final history = _CountingHistory();
        final playback = _ArtistTapPlayback();
        await pumpSearchFixture(
          tester,
          size: const Size(1300, 900),
          mornye: topCard,
          filters: searchFixtureAllFilters,
          isInHistory: true,
          history: history,
          playback: playback,
          settings: AppSettings(
            searchProvider: 'example',
            defaultSearchTab: topCard ? 'all' : 'track',
            searchViewMode: 'grid',
          ),
          results: SearchFixtureResults(
            songArtist: 'First Artist feat. Second Artist',
          ),
        );
        final card = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                topCard ? 'top-track-track-0' : 'track-track-0#',
              ),
        );
        expect(card, findsOneWidget);
        final artist = find.descendant(
          of: card,
          matching: find.text('First Artist feat. Second Artist'),
        );
        await tester.tapAt(tester.getCenter(artist));
        await tester.pumpAndSettle();
        expect(find.text('First Artist'), findsNothing);
        expect(find.text('Second Artist'), findsNothing);
        expect(find.byType(ExtensionArtistScreen), findsNothing);
        expect(queries, isEmpty);
        expect(playback.tracks, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('artist credits can be opened with keyboard', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(
              child: ClickableArtistName(
                artistName: 'First Artist feat. Second Artist',
                artistId: 'first,second',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('First Artist'), findsOneWidget);
    expect(find.text('Second Artist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('commas in credits are not guessed as artist boundaries', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(
              child: ClickableArtistName(
                artistName: 'Tyler, The Creator, Guest',
                artistId: 'first,second',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Tyler, The Creator, Guest'));
    await tester.pumpAndSettle();
    expect(find.text('Tyler'), findsNothing);
    expect(find.text('The Creator'), findsNothing);
    expect(find.text('Guest'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two IDs offer separated comma credits without assigning IDs', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(
              child: ClickableArtistName(
                artistName: 'A, B',
                artistId: 'idA,idB',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('A, B'));
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('A, B'), findsWidgets);
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    // With no catalog configured the lookup must fail safely, rather than
    // opening the guessed idB directly.
    expect(find.byType(Navigator), findsWidgets);
    expect(find.text('B'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('feature separator preserves commas inside a name', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(
              child: ClickableArtistName(
                artistName: 'Tyler, The Creator feat. Guest',
                artistId: 'one,two',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Tyler, The Creator feat. Guest'));
    await tester.pumpAndSettle();
    expect(find.text('Tyler, The Creator'), findsOneWidget);
    expect(find.text('Guest'), findsOneWidget);
    expect(find.text('Tyler'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one ID keeps the complete comma-containing artist name', (
    tester,
  ) async {
    final observer = _RouteObserver();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorObservers: [observer],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(
              child: ClickableArtistName(
                artistName: 'A, B',
                artistId: 'idA',
                extensionId: 'provider',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('A, B'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(observer.pushes, 2); // The one supplied identity opens directly.
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets('artist picker offers each featured credit ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => navigateToArtistCredits(
                    context,
                    artistNames: 'First Artist featured Second Artist',
                  ),
                  child: const Text('Artists'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      expect(find.text('First Artist'), findsOneWidget);
      expect(find.text('Second Artist'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

class _ArtistTapPlayback extends PlaybackController {
  List<Track> tracks = [];

  @override
  Future<void> playTrackList(
    List<Track> tracks, {
    int startIndex = 0,
    String? playlistId,
    bool exactStart = false,
    bool requireLocalStart = false,
    String? listContext,
    List<String>? listOccurrences,
  }) async {
    this.tracks = tracks;
  }
}

class _RouteObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

class _CountingHistory extends DownloadHistoryNotifier {
  int lookups = 0;
  @override
  DownloadHistoryState build() => DownloadHistoryState();
  @override
  Future<DownloadHistoryItem?> getBySpotifyIdAsync(String id) async {
    lookups++;
    return null;
  }

  @override
  Future<DownloadHistoryItem?> getByIsrcAsync(String isrc) async {
    lookups++;
    return null;
  }

  @override
  Future<DownloadHistoryItem?> findByTrackAndArtistAsync(
    String name,
    String artist,
  ) async {
    lookups++;
    return null;
  }
}
