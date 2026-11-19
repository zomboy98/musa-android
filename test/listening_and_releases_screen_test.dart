import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/screens/settings/profile_settings_page.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/screens/weekly_releases_screen.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/player_artwork.dart';

import 'support/fixed_settings.dart';

void main() {
  for (final mornye in [false, true]) {
    Widget app(Widget page) => MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: page,
    );
    testWidgets('annual tracks rank plays before minutes ($mornye)', (
      tester,
    ) async {
      final requested = <({int days, int year})>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            listeningSummaryProvider.overrideWith((ref, period) async {
              requested.add(period);
              return ListeningSummary.fromRows([
                for (final (key, minutes, plays) in [
                  ('Long A', 20, 1),
                  ('Repeat B', 5, 3),
                  ('Partial C', 1, 0),
                ])
                  {
                    'day': '${period.year}-01-01',
                    'track_key': key,
                    'title': key,
                    'artist': 'Artist',
                    'album': 'Album',
                    'milliseconds': minutes * 60000,
                    'plays': plays,
                  },
              ]);
            }),
          ],
          child: app(const ListeningStatisticsScreen(initialYearly: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous year'));
      await tester.pumpAndSettle();
      expect(requested.last, (days: 0, year: DateTime.now().year - 1));
      await tester.scrollUntilVisible(find.text('Repeat B'), 150);
      await tester.scrollUntilVisible(find.text('Long A'), 100);
      expect(
        tester.getTopLeft(find.text('Repeat B')).dy,
        lessThan(tester.getTopLeft(find.text('Long A')).dy),
      );
      expect(find.text('3 plays · 5 min'), findsOneWidget);
      expect(find.text('1 play · 20 min'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('Partial C'), findsNothing);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'annual partial listening keeps activity without ranking ($mornye)',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(FixedSettingsNotifier.new),
              listeningSummaryProvider.overrideWith((ref, period) async {
                return ListeningSummary.fromRows([
                  {
                    'day': '${period.year}-01-01',
                    'track_key': 'partial',
                    'title': 'Partial only',
                    'artist': 'Partial artist',
                    'album': 'Album',
                    'milliseconds': 60000,
                    'plays': 0,
                  },
                ]);
              }),
            ],
            child: app(const ListeningStatisticsScreen(initialYearly: true)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 min'), findsWidgets);
        await tester.scrollUntilVisible(find.text('Partial artist'), 150);
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1200),
        );
        await tester.pumpAndSettle();
        expect(find.text('Top tracks'), findsNothing);
        expect(find.text('Partial only'), findsNothing);
      },
    );
    testWidgets('annual activity groups local days into months ($mornye)', (
      tester,
    ) async {
      final year = DateTime.now().year - 1;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            listeningSummaryProvider.overrideWith(
              (ref, period) async => ListeningSummary.fromRows([
                for (final day in ['01-02', '01-03', '12-04'])
                  {
                    'day': '$year-$day',
                    'track_key': 'one',
                    'title': 'One',
                    'artist': 'Artist',
                    'album': 'Album',
                    'milliseconds': 60000,
                    'plays': 1,
                  },
              ]),
            ),
          ],
          child: app(const ListeningStatisticsScreen(initialYearly: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous year'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Jan'), 150);
      expect(find.text('Jan'), findsOneWidget);
      expect(find.text('2 min'), findsWidgets);
      await tester.scrollUntilVisible(find.text('Dec'), 150);
      expect(find.text('Dec'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('profile opens the current annual statistics ($mornye)', (
      tester,
    ) async {
      final requested = <({int days, int year})>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            listeningSummaryProvider.overrideWith((ref, period) async {
              requested.add(period);
              return ListeningSummary.fromRows([
                for (final key in ['one', 'two'])
                  {
                    'day': '${period.year}-01-01',
                    'track_key': key,
                    'title': key,
                    'artist': 'Artist',
                    'album': 'Album',
                    'milliseconds': 60000,
                    'plays': 1,
                  },
              ]);
            }),
          ],
          child: app(const ProfileSettingsPage(profile: UserProfile())),
        ),
      );
      await tester.pumpAndSettle();
      final entry = find.text('Your year ${DateTime.now().year}');
      await tester.ensureVisible(entry);
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('2 distinct songs'), findsOneWidget);
      expect(requested.last, (days: 0, year: DateTime.now().year));
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(ListeningStatisticsScreen), findsOneWidget);
      expect(requested.last, (days: 0, year: DateTime.now().year));
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'listening recap shows totals and supports annual view ($mornye)',
      (tester) async {
        final requested = <({int days, int year})>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(FixedSettingsNotifier.new),
              listeningSummaryProvider.overrideWith((ref, period) async {
                requested.add(period);
                return ListeningSummary.fromRows([
                  {
                    'day': '2026-10-01',
                    'track_key': 'one',
                    'title': 'One',
                    'artist': 'Artist',
                    'album': 'Album',
                    'milliseconds': 120000,
                    'plays': 1,
                    'artwork': '/covers/album.jpg',
                  },
                ]);
              }),
            ],
            child: app(const ListeningStatisticsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 play · 1 track · 1 active day'), findsOneWidget);
        await tester.tap(find.text('${DateTime.now().year}'));
        await tester.pumpAndSettle();
        expect(requested.last.days, 0);
        expect(requested.last.year, DateTime.now().year);
        final artistTile = find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.title is Text &&
              (widget.title! as Text).data == 'Artist',
        );
        await tester.scrollUntilVisible(artistTile, 150);
        await tester.pumpAndSettle();
        final artistArtwork = find.descendant(
          of: artistTile,
          matching: find.byType(PlayerArtwork),
        );
        expect(artistArtwork, findsOneWidget);
        expect(
          tester.widget<PlayerArtwork>(artistArtwork).artUri,
          '/covers/album.jpg',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'listening recap shows network covers and none for broken ones ($mornye)',
      (tester) async {
        const cover = 'network://nas/Album/cover.jpg';
        Map<String, Object?> row(String key, String artwork, int minutes) => {
          'day': '2026-10-01',
          'track_key': key,
          'title': key,
          'artist': key,
          'album': 'Album',
          'milliseconds': minutes * 60000,
          'plays': 1,
          'artwork': artwork,
        };
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(FixedSettingsNotifier.new),
              listeningSummaryProvider.overrideWith(
                (ref, period) async => ListeningSummary.fromRows([
                  row('Network', cover, 3),
                  row('Old', 'http://127.0.0.1:41234/7f3a', 2),
                ]),
              ),
            ],
            child: app(const ListeningStatisticsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        Finder tile(String title, {required bool artist}) =>
            find.byWidgetPredicate(
              (widget) =>
                  widget is ListTile &&
                  widget.title is Text &&
                  (widget.title! as Text).data == title &&
                  (widget.trailing == null) == artist,
            );
        Finder artwork(Finder tile) =>
            find.descendant(of: tile, matching: find.byType(PlayerArtwork));
        for (final (title, artist, expected) in [
          ('Network', true, cover),
          ('Old', true, null),
          ('Network', false, cover),
          ('Old', false, null),
        ]) {
          final row = tile(title, artist: artist);
          await tester.scrollUntilVisible(row, 150);
          await tester.pumpAndSettle();
          if (artist && expected == null) {
            expect(artwork(row), findsNothing);
          } else {
            expect(tester.widget<PlayerArtwork>(artwork(row)).artUri, expected);
          }
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'new releases supports week/month and explains incomplete providers ($mornye)',
      (tester) async {
        final now = DateTime.now();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              weeklyReleasesProvider.overrideWith(
                (ref, refresh) async => WeeklyReleaseFeed(
                  [
                    for (final days in [1, 10])
                      WeeklyRelease(
                        id: '$days',
                        name: 'Release $days',
                        artist: 'Artist',
                        providerId: 'provider-a',
                        date: now.subtract(Duration(days: days)),
                      ),
                  ],
                  unavailableArtists: ['Other Artist'],
                ),
              ),
            ],
            child: app(const WeeklyReleasesScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Release 1'), findsOneWidget);
        expect(find.text('Release 10'), findsNothing);
        // The expressive segmented group also lays out a measuring copy.
        await tester.tap(find.text('30 days').first);
        await tester.pumpAndSettle();
        expect(find.text('Release 10'), findsOneWidget);
        expect(find.textContaining('Other Artist'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
