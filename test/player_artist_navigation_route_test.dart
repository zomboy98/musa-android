import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_track_navigation.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/screens/extension_collection_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/search_results_fixture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final catalog in [true, false]) {
    testWidgets(
      'playing artist navigation uses ${catalog ? 'catalog identity' : 'local lookup'}',
      (tester) async {
        final track = Track(
          id: 'song',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 180,
          artistId: 'native-artist',
          source: 'example',
        );
        final source = catalog
            ? 'catalog:${base64Url.encode(utf8.encode(jsonEncode(track.toJson())))}'
            : '/music/song.flac';
        final item = MediaItem(
          id: source,
          title: 'Song',
          artist: 'Artist',
          extras: {'source': source, 'originSource': 'example'},
        );
        final queries = <String>[];
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'customSearchWithExtension') {
            queries.add((call.arguments as Map)['query'] as String);
            return [
              {'id': 'lookup-artist', 'name': 'Artist'},
            ];
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              extensionProvider.overrideWith(
                () => SearchFixtureExtensions(searchFixtureAllFilters),
              ),
              playerCollectionTrackProvider(
                item,
              ).overrideWith((ref) async => track),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Consumer(
                builder: (context, ref, _) {
                  final loaded = ref
                      .watch(playerCollectionTrackProvider(item))
                      .hasValue;
                  return Scaffold(
                    body: TextButton(
                      onPressed: loaded
                          ? () => openPlayingArtist(context, ref, item)
                          : null,
                      child: const Text('Open artist'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('Open artist'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final profile = tester.widget<ExtensionArtistScreen>(
          find.byType(ExtensionArtistScreen),
        );
        expect(profile.extensionId, 'example');
        expect(profile.artistId, catalog ? 'native-artist' : 'lookup-artist');
        expect(queries, catalog ? isEmpty : ['Artist']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
