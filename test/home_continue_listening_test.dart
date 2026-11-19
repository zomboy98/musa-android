import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/player_artwork.dart';

import 'support/fixed_settings.dart';

const _cover = 'network://nas/Album/cover.jpg';

/// The Material Home without a feed, resuming a saved song unless
/// [saved] is false.
Widget _home({
  bool saved = true,
  bool feed = false,
  double scale = 1,
  _Playback? playback,
}) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(
      () => FixedSettingsNotifier(
        AppSettings(
          searchProvider: 'example',
          homeFeedProvider: feed ? null : AppSettings.homeFeedProviderOff,
        ),
      ),
    ),
    extensionProvider.overrideWith(_Extensions.new),
    exploreProvider.overrideWith(() => _Explore(feed)),
    if (playback != null) playbackProvider.overrideWith(() => playback),
    downloadHistoryProvider.overrideWith(_History.new),
    recentAccessProvider.overrideWith(_Recent.new),
    libraryMixesProvider.overrideWith((ref) async => const []),
    playerUiEnabledProvider.overrideWithValue(true),
    currentMediaItemProvider.overrideWithBuild(
      (ref, notifier) => Stream<MediaItem?>.value(null),
    ),
    playbackResumeProvider.overrideWith(
      (ref) async => saved
          ? (
              media: const PlayableMedia(
                id: 'network://nas/Album/song.flac',
                source: 'network://nas/Album/song.flac',
                title: 'Saved song',
                artist: 'Artist',
                networkArtworkSource: _cover,
              ),
              position: const Duration(seconds: 23),
            )
          : null,
    ),
  ],
  child: MaterialApp(
    theme: AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: const HomeTab(mode: HomeTabMode.combined),
      ),
    ),
  ),
);

/// Opens [_home] in a [width] wide window, as the desktop app when
/// [desktop] is true.
Future<void> _open(
  WidgetTester tester, {
  required bool desktop,
  double width = 1280,
  bool saved = true,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  debugDesktopPlatformOverride = desktop;
  addTearDown(() => debugDesktopPlatformOverride = null);
  await tester.pumpWidget(_home(saved: saved));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('tapping a quick pick plays the selected fixture track', (
    tester,
  ) async {
    final playback = _Playback();
    await tester.pumpWidget(_home(feed: true, playback: playback));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('A long fixture song title 0'));
    await tester.pump();
    expect(playback.selected?.id, '0');
    expect(playback.selected?.source, 'fixture-provider');
  });
  testWidgets('quick pick menu does not start playback', (tester) async {
    final playback = _Playback();
    await tester.pumpWidget(_home(feed: true, playback: playback));
    await tester.pump();
    await tester.pump();
    final row = find.byKey(const ValueKey('quick-pick-track-0-fixture:0'));
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('Show menu')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(playback.selected, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('quick picks fit at 320 pixels and 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDesktopPlatformOverride = false;
    addTearDown(() => debugDesktopPlatformOverride = null);
    await tester.pumpWidget(_home(feed: true, scale: 2));
    await tester.pump();
    await tester.pump();
    expect(find.text('Fixture picks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('last quick pick remains reachable at 300 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDesktopPlatformOverride = false;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final playback = _Playback();
    await tester.pumpWidget(_home(feed: true, scale: 3, playback: playback));
    await tester.pump();
    await tester.pump();
    final last = find.text('A long fixture song title 4');
    await tester.ensureVisible(last);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(last);
    await tester.pump();
    expect(playback.selected?.id, '4');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Continue listening shows a network cover not stored yet', (
    tester,
  ) async {
    const cover = _cover;
    await tester.pumpWidget(_home());
    await tester.pump();
    await tester.pump();

    final card = find.ancestor(
      of: find.text('Saved song'),
      matching: find.byType(InkWell),
    );
    final artwork = find.descendant(
      of: card.first,
      matching: find.byType(PlayerArtwork),
    );
    expect(tester.widget<PlayerArtwork>(artwork).artUri, cover);
  });

  testWidgets('desktop Home sets the shortcuts beside Continue listening', (
    tester,
  ) async {
    await _open(tester, desktop: true);
    expect(tester.takeException(), isNull);

    final continueHeader = tester.getRect(find.text('Continue listening'));
    final shortcutsHeader = tester.getRect(find.text('Shortcuts'));
    expect(shortcutsHeader.top, continueHeader.top);
    expect(shortcutsHeader.left, greaterThan(continueHeader.left + 400));

    // The shortcuts stack in one list as tall as the card beside it.
    final card = tester.getRect(
      find
          .ancestor(of: find.text('Saved song'), matching: find.byType(InkWell))
          .first,
    );
    final first = tester.getRect(
      find
          .ancestor(
            of: find.text('Shuffle library'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    final last = tester.getRect(
      find
          .ancestor(
            of: find.text('Network storage'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(first.left, last.left);
    expect(first.top, card.top);
    expect(last.bottom, card.bottom);
    expect(first.height, greaterThanOrEqualTo(48));
  });

  testWidgets('desktop Home stacks both sections in a narrow pane', (
    tester,
  ) async {
    await _open(tester, desktop: true, width: 700);
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.text('Shortcuts')).top,
      greaterThan(tester.getRect(find.text('Saved song')).bottom),
    );
    // One row of shortcuts.
    expect(
      tester.getRect(find.text('Network storage')).top,
      tester.getRect(find.text('Shuffle library')).top,
    );
  });

  testWidgets('desktop Home without a session shows the shortcuts in a row', (
    tester,
  ) async {
    await _open(tester, desktop: true, saved: false);
    expect(tester.takeException(), isNull);
    expect(find.text('Continue listening'), findsNothing);
    // Labels may wrap; the tiles share one row and one height.
    final tiles = {
      for (final label in [
        'Shuffle library',
        'Equalizer',
        'Listening statistics',
        'Network storage',
      ])
        tester.getRect(
          find
              .ancestor(of: find.text(label), matching: find.byType(InkWell))
              .first,
        ),
    };
    expect({for (final tile in tiles) (tile.top, tile.height)}, hasLength(1));
  });

  testWidgets('phones keep two columns of shortcuts under the card', (
    tester,
  ) async {
    await _open(tester, desktop: false, width: 400);
    expect(tester.takeException(), isNull);
    final shuffle = tester.getRect(find.text('Shuffle library'));
    expect(tester.getRect(find.text('Equalizer')).top, shuffle.top);
    expect(
      tester.getRect(find.text('Listening statistics')).top,
      greaterThan(shuffle.bottom),
    );
    expect(
      tester.getRect(find.text('Shortcuts')).top,
      greaterThan(tester.getRect(find.text('Saved song')).bottom),
    );
  });
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Explore extends ExploreNotifier {
  _Explore(this.feed);
  final bool feed;
  @override
  ExploreState build() => feed
      ? ExploreState(
          sections: [
            ExploreSection(
              uri: 'fixture',
              title: 'Fixture picks',
              isQuickPicks: true,
              items: [
                for (var i = 0; i < 5; i++)
                  ExploreItem(
                    id: i.toString(),
                    uri: 'fixture:$i',
                    type: 'track',
                    name: 'A long fixture song title $i',
                    artists: 'Fixture artist',
                    providerId: 'fixture-provider',
                  ),
              ],
            ),
          ],
        )
      : const ExploreState();

  @override
  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {}
}

class _Playback extends PlaybackController {
  Track? selected;
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
    selected = tracks[startIndex];
  }
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}
