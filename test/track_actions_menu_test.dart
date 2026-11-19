import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/track_actions.dart';
import 'package:mornye/widgets/track_actions_sheet.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

const _track = Track(
  id: 'deezer:42',
  name: 'Example track',
  artistName: 'Example artist',
  albumName: 'Example album',
  duration: 180,
);

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

class _PopCounter extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => pops++;
}

Widget _app(
  Widget home, {
  required bool mornye,
  NavigatorObserver? observer,
  Brightness brightness = Brightness.light,
}) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(_Settings.new),
    libraryCollectionsProvider.overrideWith(_Collections.new),
    librarySongKeysProvider.overrideWithValue(<String>{}),
    downloadQueueLookupProvider.overrideWithValue(
      const DownloadQueueLookup.empty(),
    ),
    playerUiEnabledProvider.overrideWithValue(true),
    linkPhoneClientProvider.overrideWithValue(null),
  ],
  child: MaterialApp(
    navigatorObservers: [?observer],
    theme: mornye ? MornyeTheme.build(brightness) : ThemeData(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: home),
  ),
);

TrackActionMenu _menu(
  BuildContext context, {
  TrackActionInputs inputs = const TrackActionInputs(
    canQueue: true,
    canPlayLocal: true,
  ),
}) => buildTrackActionMenu(context.l10n, inputs);

List<String> _labelsInReadingOrder(
  WidgetTester tester,
  Iterable<String> labels,
) {
  final found = <({String label, Offset at})>[];
  for (final label in labels) {
    final finder = find.text(label);
    if (finder.evaluate().isEmpty) continue;
    found.add((label: label, at: tester.getTopLeft(finder.first)));
  }
  found.sort((a, b) {
    final dy = (a.at.dy - b.at.dy).round();
    return dy.abs() > 6 ? dy : a.at.dx.compareTo(b.at.dx).sign;
  });
  return [for (final item in found) item.label];
}

void main() {
  setUp(() => debugDesktopPlatformOverride = false);
  tearDown(() => debugDesktopPlatformOverride = null);

  testWidgets('the three presentations list the same actions in one order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late TrackActionMenu menu;
    final expected = <String>[];

    Future<List<String>> shown(
      Widget Function(TrackActionMenu) build, {
      required bool mornye,
    }) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              menu = _menu(context);
              expected
                ..clear()
                ..addAll([for (final action in menu.all) action.label]);
              return build(menu);
            },
          ),
          mornye: mornye,
        ),
      );
      await tester.pump();
      return _labelsInReadingOrder(tester, expected);
    }

    final material = await shown(
      (menu) => TrackActionsSheet(menu: menu, title: 'Title', artist: 'Artist'),
      mornye: false,
    );
    final mornye = await shown(
      (menu) =>
          MornyeTrackActionsMenu(menu: menu, title: 'Title', artist: 'Artist'),
      mornye: true,
    );
    final desktop = [
      for (final group in menu.toContextGroups((_) {}))
        for (final action in group) action.label,
    ];

    expect(material, expected);
    expect(mornye, expected);
    expect(desktop, expected);
    expect(menu.ids, [
      TrackActionId.favorite,
      TrackActionId.addToMusic,
      TrackActionId.download,
      TrackActionId.playLocal,
      TrackActionId.playNext,
      TrackActionId.addToQueue,
      TrackActionId.goToAlbum,
      TrackActionId.goToArtist,
      TrackActionId.share,
      TrackActionId.copyTitle,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only applicable actions are offered', (tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
        mornye: false,
      ),
    );
    final menu = buildTrackActionMenu(
      captured.l10n,
      const TrackActionInputs(hasAlbum: false, hasArtist: false),
    );
    expect(menu.ids, isNot(contains(TrackActionId.goToAlbum)));
    expect(menu.ids, isNot(contains(TrackActionId.goToArtist)));
    expect(menu.ids, isNot(contains(TrackActionId.playNext)));
    expect(menu.ids, isNot(contains(TrackActionId.addToQueue)));
    expect(menu.ids, isNot(contains(TrackActionId.playLocal)));
    expect(menu.ids, contains(TrackActionId.share));
    final active = buildTrackActionMenu(
      captured.l10n,
      const TrackActionInputs(download: TrackDownloadPhase.active),
    );
    final download = active.quick.firstWhere(
      (a) => a.id == TrackActionId.download,
    );
    expect(download.enabled, isFalse);
    expect(download.label, captured.l10n.trackActionDownloading);
    expect(active.toContextGroups((_) {}).first.last.onSelected, isNull);
  });

  testWidgets('the player menu offers the download only when it can run', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
        mornye: false,
      ),
    );
    final offered = buildTrackActionMenu(
      captured.l10n,
      const TrackActionInputs(playerTools: true),
    );
    final download = offered.quick.firstWhere(
      (a) => a.id == TrackActionId.download,
    );
    expect(download.enabled, isTrue);
    expect(download.label, captured.l10n.dialogDownload);
    final hidden = buildTrackActionMenu(
      captured.l10n,
      const TrackActionInputs(playerTools: true, canDownload: false),
    );
    expect(
      hidden.quick.map((a) => a.id),
      isNot(contains(TrackActionId.download)),
    );
  });

  for (final mornye in [false, true]) {
    testWidgets('opening does not change the size after the first frame '
        '(Mornye: $mornye)', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () =>
                  TrackCollectionQuickActions.showTrackOptionsSheet(
                    context,
                    ref,
                    _track,
                  ),
              child: const Text('Open'),
            ),
          ),
          mornye: mornye,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(Duration.zero);
      final type = mornye ? MornyeContextMenu : TrackActionsSheet;
      final first = tester.getSize(find.byType(type));
      expect(find.byType(FutureBuilder<Object?>), findsNothing);
      expect(find.byType(StreamBuilder<Object?>), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(type)), first);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('each action closes once with its id, even on a double tap '
        '(Mornye: $mornye)', (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final observer = _PopCounter();
      late TrackActionMenu menu;
      TrackActionId? chosen;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              menu = _menu(context);
              return TextButton(
                onPressed: () async {
                  chosen = mornye
                      ? await showMornyeContextMenu<TrackActionId>(
                          context: context,
                          builder: (_) => MornyeTrackActionsMenu(
                            menu: menu,
                            title: 'Title',
                            artist: 'Artist',
                          ),
                        )
                      : await showAppModalBottomSheet<TrackActionId>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => TrackActionsSheet(
                            menu: menu,
                            title: 'Title',
                            artist: 'Artist',
                          ),
                        );
                },
                child: const Text('Open'),
              );
            },
          ),
          mornye: mornye,
          observer: observer,
        ),
      );
      for (final id in [
        TrackActionId.favorite,
        TrackActionId.download,
        TrackActionId.playNext,
        TrackActionId.share,
        TrackActionId.copyTitle,
      ]) {
        chosen = null;
        observer.pops = 0;
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final label = menu.all.firstWhere((a) => a.id == id).label;
        final target = find.text(label).first;
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target, warnIfMissed: false);
        await tester.tap(target, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(chosen, id);
        expect(observer.pops, 1, reason: '$id closed more than once');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop actions run their callback once each', (tester) async {
    late TrackActionMenu menu;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            menu = _menu(context);
            return const SizedBox();
          },
        ),
        mornye: false,
      ),
    );
    final calls = <TrackActionId>[];
    final groups = menu.toContextGroups((action) => calls.add(action.id));
    for (final group in groups) {
      for (final action in group) {
        action.onSelected!();
      }
    }
    expect(calls, menu.ids);
    expect(calls.toSet().length, calls.length);
  });

  testWidgets('copying the title puts it on the clipboard once', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _app(
        Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () =>
                runTrackAction(context, ref, _track, TrackActionId.copyTitle),
            child: const Text('Copy'),
          ),
        ),
        mornye: false,
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, ['Example track - Example artist']);
    expect(find.byIcon(CupertinoIcons.ellipsis), findsNothing);
  });
}
