import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/track_list_tile.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final customAccent in [
    Colors.white,
    Colors.black,
    Colors.yellow,
    Colors.blue,
    Colors.red,
    Colors.green,
  ]) {
    testWidgets(
      'MUSA active fill follows accent with readable text $customAccent',
      (tester) async {
        final theme = MornyeTheme.build(
          Brightness.dark,
          customAccent: customAccent,
        );
        Future<Color?> render({
          required bool current,
          bool playing = false,
          bool selected = false,
        }) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: Scaffold(
                body: TrackCard(
                  leading: const Icon(Icons.music_note),
                  title: 'Canción de prueba',
                  subtitle: const Text('Artista de prueba'),
                  isCurrent: current,
                  isPlaying: playing,
                  isSelected: selected,
                  onTap: () {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          return tester
              .widget<AppContentCard>(find.byType(AppContentCard))
              .color;
        }

        expect(await render(current: false), Colors.transparent);
        final paused = await render(current: true);
        expect(
          paused,
          Color.alphaBlend(
            theme.colorScheme.primary.withValues(alpha: .12),
            theme.colorScheme.surface,
          ),
        );
        expect(await render(current: true, playing: true), paused);
        final selectedCurrent = await render(current: true, selected: true);
        expect(await render(current: false, selected: true), selectedCurrent);
        final foreground = theme.colorScheme.onSurface;
        final bright = foreground.computeLuminance();
        final dark = paused!.computeLuminance();
        final ratio = (bright > dark
            ? (bright + .05) / (dark + .05)
            : (dark + .05) / (bright + .05));
        expect(ratio, greaterThanOrEqualTo(4.5));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('render passive current states at 320dp text $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: MornyeTheme.build(Brightness.dark, accent: MornyeAccent.green),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: captureKey,
            child: Scaffold(
              body: SafeArea(
                child: ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('MUSA · Prueba visual de estados'),
                    ),
                    for (final state in [
                      (false, false, 'Sin selección'),
                      (true, true, 'Reproduciendo'),
                      (true, false, 'En pausa'),
                    ])
                      TrackCard(
                        leading: const SizedBox.square(
                          dimension: 40,
                          child: Icon(Icons.music_note),
                        ),
                        title: '${state.$3} · Título largo de prueba',
                        subtitle: const Text('Artista de prueba'),
                        isCurrent: state.$1,
                        isPlaying: state.$2,
                        onTap: () {},
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.download_outlined),
                            ),
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.more_horiz),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('design/diagnostico-musa-pista-activa');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/320dp-texto-${(scale * 100).toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }

  for (final local in [false, true]) {
    for (final playing in [false, true]) {
      testWidgets('MUSA current row local=$local playing=$playing', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final track = Track(
          id: local ? 'local' : 'catalog',
          name: 'Una canción de prueba con título extenso',
          artistName: 'Artista de prueba',
          albumName: 'Álbum de prueba',
          duration: 120,
        );
        var plays = 0;
        var downloads = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              catalogTrackPlaybackUiProvider(
                catalogTrackKey(track),
              ).overrideWith(
                (ref) =>
                    (isCurrent: true, isPlaying: playing, isLoading: false),
              ),
              playlistDownloadedFileProvider(
                track,
              ).overrideWith((ref) async => local),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.dark),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: TrackListTile(
                  track: track,
                  isInHistory: local,
                  clickableArtist: false,
                  playlistActions: true,
                  leading: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.music_note),
                  ),
                  onActivate: () => plays++,
                  onDownload: ({forceQualityPicker = false}) => downloads++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byType(NowPlayingIndicator),
          playing ? findsOneWidget : findsNothing,
        );
        expect(
          find.byIcon(Icons.pause_rounded),
          playing ? findsNothing : findsOneWidget,
        );
        expect(find.byIcon(Icons.play_arrow), findsNothing);
        expect(
          tester.widget<Text>(find.text(track.name)).style?.fontWeight,
          FontWeight.w700,
        );
        final selected = find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.selected == true,
        );
        expect(selected, findsOneWidget);
        final indicator = playing
            ? find.byType(NowPlayingIndicator)
            : find.byIcon(Icons.pause_rounded);
        await tester.tap(indicator);
        expect(plays, 1);
        await tester.tap(find.byKey(const ValueKey('download-library-track')));
        expect(downloads, 1);
        expect(plays, 1);
        expect(
          find.byKey(const ValueKey('save-library-track')),
          findsOneWidget,
        );
        final saveBounds = tester.getRect(
          find.byKey(const ValueKey('save-library-track')),
        );
        final downloadBounds = tester.getRect(
          find.byKey(const ValueKey('download-library-track')),
        );
        expect(saveBounds.height, greaterThanOrEqualTo(48));
        expect(downloadBounds.width, greaterThanOrEqualTo(48));
        expect(
          saveBounds.top,
          greaterThan(tester.getRect(find.text(track.name)).bottom),
        );
      });
    }
  }

  testWidgets('selection semantics supersedes current-track selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MornyeTheme.build(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TrackCard(
            leading: const Icon(Icons.music_note),
            title: 'Canción de prueba',
            isCurrent: true,
            isPlaying: false,
            isSelectionMode: true,
            isSelected: false,
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
