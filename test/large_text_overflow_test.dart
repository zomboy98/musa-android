import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/screens/settings/music_preferences_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/playback_provider_setup.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'support/app_icon_finder.dart';

const _longTitle = 'No Te Detengas (Remasterizado) Edicion Especial';
const _scales = [1.5, 2.0];
const _widths = [320.0, 360.0];

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    playerMode: 'external',
    audioQuality: '',
    defaultService: 'example',
  );

  @override
  void setDefaultService(String value) =>
      state = state.copyWith(defaultService: value);

  @override
  bool setDefaultDownloadExtension(Extension value, {bool confirmed = false}) {
    state = state.copyWith(defaultService: value.id);
    return true;
  }

  @override
  void setPlaybackQuality(String value) =>
      state = state.copyWith(playbackQuality: value);

  @override
  void setAudioQualityForProvider(
    String provider,
    String quality, {
    QualityOption? option,
  }) {
    state = state.copyWith(audioQuality: quality);
  }
}

class _PlainSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Extensions extends ExtensionNotifier {
  _Extensions({this.status = 'loaded'});

  final String status;

  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    providerPriority: const ['example'],
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Proveedor de musica con un nombre muy largo',
        version: '1',
        description: '',
        enabled: true,
        status: status,
        hasDownloadProvider: true,
        qualityOptions: const [
          QualityOption(
            id: 'low',
            label: 'Calidad estandar de transmision con nombre largo',
          ),
          QualityOption(id: 'high', label: 'Calidad alta sin perdida'),
        ],
      ),
    ],
  );
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  @override
  Future<String> createPlaylist(String name) async => name;
}

void noOverflow(WidgetTester tester) {
  final error = tester.takeException();
  if (error != null) {
    fail(error is FlutterError ? error.toStringDeep() : '$error');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  setUpAll(() async {
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });

  void size(WidgetTester tester, double width, [double height = 700]) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(
    Widget home, {
    required double scale,
    required bool mornye,
    bool plainSettings = false,
    List<Override> overrides = const [],
  }) => ProviderScope(
    overrides: [
      settingsProvider.overrideWith(
        plainSettings ? _PlainSettings.new : _Settings.new,
      ),
      libraryCollectionsProvider.overrideWith(_Collections.new),
      ...overrides,
    ],
    child: MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    ),
  );

  for (final mornye in [false, true]) {
    for (final scale in _scales) {
      for (final width in _widths) {
        final label = 'Mornye: $mornye, scale: $scale, width: $width';

        testWidgets('settings header does not overflow ($label)', (
          tester,
        ) async {
          size(tester, width);
          await tester.pumpWidget(
            app(
              const Scaffold(
                body: CustomScrollView(
                  slivers: [
                    AppSliverHeader.page(
                      title: 'Estadisticas de escucha y reproduccion',
                    ),
                    SliverToBoxAdapter(child: SizedBox(height: 2000)),
                  ],
                ),
              ),
              scale: scale,
              mornye: mornye,
            ),
          );
          await tester.pumpAndSettle();
          noOverflow(tester);
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -300),
          );
          await tester.pumpAndSettle();
          noOverflow(tester);
        });

        testWidgets('settings group with long titles does not overflow '
            '($label)', (tester) async {
          size(tester, width);
          await tester.pumpWidget(
            app(
              Scaffold(
                body: ListView(
                  children: [
                    SettingsGroup(
                      children: [
                        SettingsItem(
                          icon: Icons.tune,
                          title: _longTitle * 2,
                          subtitle: 'Descripcion larga de la opcion ' * 3,
                          trailing: const Text('Valor largo'),
                          onTap: () {},
                        ),
                        SettingsSwitchItem(
                          icon: Icons.lock,
                          title: _longTitle * 2,
                          subtitle: 'Descripcion larga de la opcion ' * 3,
                          value: true,
                          onChanged: (_) {},
                        ),
                        SettingsItem(
                          title: _longTitle,
                          titleTrailing: const Icon(Icons.info_outline),
                          selected: true,
                          trailing: const Icon(Icons.check),
                          onTap: () {},
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              scale: scale,
              mornye: mornye,
            ),
          );
          await tester.pumpAndSettle();
          noOverflow(tester);
        });

        testWidgets('mini player does not overflow ($label)', (tester) async {
          size(tester, width);
          await tester.pumpWidget(
            app(
              const Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: MiniPlayer(),
                ),
              ),
              scale: scale,
              mornye: mornye,
              overrides: [
                currentMediaItemProvider.overrideWithBuild(
                  (ref, notifier) => Stream.value(
                    const MediaItem(
                      id: 'long-track',
                      title: _longTitle,
                      artist: 'Primer artista, segundo artista y otro artista',
                      extras: {'explicit': true},
                    ),
                  ),
                ),
                playbackStateProvider.overrideWith(
                  (ref) => const Stream.empty(),
                ),
                lowEndDeviceProvider.overrideWithValue(true),
                backdropBlurEnabledProvider.overrideWithValue(false),
              ],
            ),
          );
          for (var i = 0; i < 4; i++) {
            await tester.pump();
          }
          noOverflow(tester);
          await tester.pumpWidget(const SizedBox.shrink());
        });

        testWidgets('create playlist sheet does not overflow ($label)', (
          tester,
        ) async {
          size(tester, width);
          await tester.pumpWidget(
            app(
              Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: TextButton(
                    onPressed: () => showCreatePlaylistSheet(context, ref),
                    child: const Text('create'),
                  ),
                ),
              ),
              scale: scale,
              mornye: mornye,
            ),
          );
          await tester.tap(find.text('create'));
          await tester.pumpAndSettle();
          noOverflow(tester);
          await tester.tap(find.text('Empty playlist'));
          await tester.pumpAndSettle();
          noOverflow(tester);
        });

        for (final status in ['loaded', 'error']) {
          testWidgets('provider setup sheet ($status) does not overflow '
              '($label)', (tester) async {
            size(tester, width);
            await tester.pumpWidget(
              app(
                Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => showPlaybackProviderSetup(context),
                      child: const Text('Open'),
                    ),
                  ),
                ),
                scale: scale,
                mornye: mornye,
                overrides: [
                  extensionProvider.overrideWith(
                    () => _Extensions(status: status),
                  ),
                ],
              ),
            );
            await tester.tap(find.text('Open'));
            await tester.pumpAndSettle();
            noOverflow(tester);
          });
        }

        testWidgets('listening preferences page does not overflow ($label)', (
          tester,
        ) async {
          size(tester, width, 900);
          await tester.pumpWidget(
            app(
              const MusicPreferencesPage(expandSectionsForTest: true),
              scale: scale,
              mornye: mornye,
              overrides: [extensionProvider.overrideWith(_Extensions.new)],
            ),
          );
          await tester.pumpAndSettle();
          noOverflow(tester);
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -2000),
          );
          await tester.pumpAndSettle();
          noOverflow(tester);
        });
      }
    }
  }

  group('compact lyrics header', () {
    late StreamController<MediaItem?> mediaItems;

    setUp(() {
      DecorativePhase.debugHoldClock = true;
      mediaItems = StreamController<MediaItem?>.broadcast();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        secureStorageChannel,
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(backendChannel, (call) async {
        if (call.method == 'setScreenAwake') return null;
        if (call.method == 'readFileMetadata') {
          return jsonEncode({'title': _longTitle});
        }
        fail('Unexpected platform call: ${call.method}');
      });
    });

    tearDown(() async {
      DecorativePhase.debugHoldClock = false;
      await mediaItems.close();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(backendChannel, null);
      messenger.setMockMethodCallHandler(secureStorageChannel, null);
    });

    for (final scale in _scales) {
      for (final width in _widths) {
        testWidgets('does not overflow (scale: $scale, width: $width)', (
          tester,
        ) async {
          size(tester, width, 740);
          await tester.pumpWidget(
            app(
              NowPlayingScreen(
                metadataControllerFactory: () =>
                    PlayerMetadataController(automaticOnlineSearch: false),
              ),
              scale: scale,
              mornye: true,
              plainSettings: true,
              overrides: [
                currentMediaItemProvider.overrideWithBuild(
                  (ref, notifier) => mediaItems.stream,
                ),
                playerMotionArtworkProvider.overrideWith(
                  (ref, album) async => null,
                ),
                playerArtworkVideoProvider.overrideWith(
                  (ref, source) => Completer<VideoPlayerController>().future,
                ),
                playerCollectionTrackProvider.overrideWith(
                  (ref, item) async => Track(
                    id: item.id,
                    name: item.title,
                    artistName: item.artist ?? '',
                    albumName: item.album ?? '',
                    duration: item.duration?.inSeconds ?? 0,
                    source: 'local',
                  ),
                ),
                playbackStateProvider.overrideWith(
                  (ref) => const Stream.empty(),
                ),
                playQueueProvider.overrideWith((ref) => Stream.value(const [])),
                systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
              ],
            ),
          );
          mediaItems.add(
            const MediaItem(
              id: 'long',
              title: _longTitle,
              artist: 'Primer artista, segundo artista y otro artista',
              album: 'Album',
              duration: Duration(minutes: 3),
              extras: {'source': 'content://library/long.flac'},
            ),
          );
          for (var i = 0; i < 30; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          noOverflow(tester);
          await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
          for (var i = 0; i < 30; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          noOverflow(tester);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  });
}
