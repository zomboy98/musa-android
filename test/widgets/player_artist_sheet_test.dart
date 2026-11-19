import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/player_artist_sheet.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/controllers/clickable_metadata.dart';

void main() {
  test(
    'artist credits preserve ambiguous names and separate supported credits',
    () {
      for (final name in ['Earth, Wind & Fire', 'Florence & the Machine']) {
        final identified = buildArtistTapTargets(name, 'artist-id');
        expect(identified.map((a) => a.name), [name]);
        expect(identified.single.artistId, 'artist-id');
        expect(buildArtistTapTargets(name, null).map((a) => a.name), [name]);
      }
      final multiple = buildArtistTapTargets('Alice & Bob', 'id-a,id-b');
      expect(multiple.map((a) => a.name), ['Alice', 'Bob']);
      expect(multiple.map((a) => a.artistId), ['id-a', 'id-b']);
      expect(
        buildArtistTapTargets('Alice feat. Bob', null).map((a) => a.name),
        ['Alice', 'Bob'],
      );
      final featured = buildArtistTapTargets(
        'Tito Double P feat. Peso Pluma',
        'principal-id',
      );
      expect(featured.map((a) => a.name), ['Tito Double P', 'Peso Pluma']);
      expect(featured.map((a) => a.artistId), [null, null]);
      expect(buildArtistTapTargets('Alice ft. Bob', 'id').map((a) => a.name), [
        'Alice',
        'Bob',
      ]);
      expect(
        buildArtistTapTargets('Alice & Bob', 'unknown').map((a) => a.name),
        ['Alice & Bob'],
      );
      expect(buildArtistTapTargets('', null), isEmpty);
    },
  );
  test('artist credits split on commas and semicolons without IDs', () {
    expect(
      buildArtistTapTargets('Chuyin, Fuerza Regida', null).map((a) => a.name),
      ['Chuyin', 'Fuerza Regida'],
    );
    expect(
      buildArtistTapTargets(
        'Calle 24, Chino Pacas, Fuerza Regida',
        null,
      ).map((a) => a.name),
      ['Calle 24', 'Chino Pacas', 'Fuerza Regida'],
    );
    expect(buildArtistTapTargets('A; B', null).map((a) => a.name), ['A', 'B']);
    expect(
      buildArtistTapTargets('Tyler, The Creator', null).map((a) => a.name),
      ['Tyler, The Creator'],
    );
    expect(
      buildArtistTapTargets(
        'Tyler, The Creator, Frank Ocean',
        null,
      ).map((a) => a.name),
      ['Tyler, The Creator', 'Frank Ocean'],
    );
    expect(buildArtistTapTargets('Alice & Bob', null).map((a) => a.name), [
      'Alice & Bob',
    ]);
  });
  test('artist credits do not invent IDs when counts differ', () {
    final single = buildArtistTapTargets('Chuyin, Fuerza Regida', 'id-a');
    expect(single.map((a) => a.name), ['Chuyin', 'Fuerza Regida']);
    expect(single.map((a) => a.artistId), [null, null]);
    final paired = buildArtistTapTargets('Chuyin, Fuerza Regida', 'id-a,id-b');
    expect(paired.map((a) => a.name), ['Chuyin', 'Fuerza Regida']);
    expect(paired.map((a) => a.artistId), ['id-a', 'id-b']);
  });
  test('catalog codec preserves full track and reads legacy queue payload', () {
    const track = Track(
      id: 'track',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      artistId: 'artist-id',
      albumId: 'album-id',
      albumType: 'single',
      deezerId: 'deezer-id',
      duration: 123,
      source: 'provider',
      coverUrl: 'https://example.com/cover.jpg',
      explicit: true,
    );
    final playable = playableFromCatalogTrack(track);
    final decoded = PlayableMedia.fromJson(playable.toJson())!.catalogTrack!;
    expect(decoded.toJson(), track.toJson());
    expect(
      playable
          .toMediaItem(resolvedArtwork: track.coverUrl)
          .extras?['albumType'],
      'single',
    );
    final legacy = {
      'id': 'old',
      'name': 'Old song',
      'artistName': 'Old artist',
      'albumName': 'Old album',
      'duration': 10,
      'source': 'old-provider',
      'deezerId': 'old-deezer',
    };
    final oldSource =
        'catalog:${base64Url.encode(utf8.encode(jsonEncode(legacy)))}';
    final restored = PlayableMedia(
      id: 'old',
      source: oldSource,
      title: 'Old song',
      artist: 'Old artist',
    ).catalogTrack!;
    expect(restored.artistName, 'Old artist');
    expect(restored.albumName, 'Old album');
    expect(restored.deezerId, 'old-deezer');
    expect(restored.albumType, isNull);
  });

  testWidgets('release artwork uses local, network and missing artwork paths', (
    tester,
  ) async {
    Widget sheet(Uri? art) => MaterialApp(
      home: Scaffold(
        body: PlayerArtistSheet(
          mediaItem: MediaItem(
            id: '1',
            title: 'Song',
            artist: 'Artist',
            album: 'Album',
            artUri: art,
          ),
          onArtist: (_) {},
          onAlbum: () {},
        ),
      ),
    );
    final directory = Directory.systemTemp.createTempSync('musa-sheet-cover-');
    final file = File('${directory.path}/cover.png');
    file.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=',
      ),
    );
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
      directory.deleteSync();
    });
    await tester.pumpWidget(sheet(file.uri));
    final local = tester.widget<Image>(
      find.descendant(
        of: find.byType(PlayerArtwork),
        matching: find.byType(Image),
      ),
    );
    expect(local.image, isA<FileImage>());
    expect((local.image as FileImage).file.uri, file.uri);
    await tester.pumpWidget(sheet(Uri.parse('https://example.com/cover.jpg')));
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    await tester.pumpWidget(sheet(null));
    expect(
      find.byWidgetPredicate((w) => w is AppIcon && w.icon == Icons.music_note),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });
  test('track metadata survives playback and restoration', () {
    for (final type in ['single', 'album', null]) {
      final track = Track(
        id: 'id',
        name: 'Song',
        artistName: 'Alice',
        albumName: 'Record',
        albumId: 'record-id',
        albumType: type,
        duration: 1,
        source: 'catalog',
      );
      final playable = playableFromTrack(track, 'path');
      final restored = PlayableMedia.fromJson(playable.toJson())!;
      final media = restored.toMediaItem(
        resolvedArtwork: 'https://example.com/art.jpg',
      );
      expect(media.extras?['albumId'], 'record-id');
      expect(media.extras?['albumType'], type);
      expect(
        playerReleaseName(media, media.extras?['albumType'] as String?),
        type == 'single' ? 'Song' : 'Record',
      );
    }
  });
  const item = MediaItem(
    id: '1',
    title: 'Song',
    artist: 'Alice feat. Bob',
    album: 'Record',
  );
  test('release identity only follows explicit type', () {
    expect(playerReleaseName(item, 'single'), 'Song');
    expect(playerReleaseName(item, 'album'), 'Record');
    expect(playerReleaseName(item, 'ep'), 'Record');
    expect(playerReleaseName(item, null), 'Record');
    expect(playerReleaseName(item.copyWith(album: ''), null), 'Song');
  });
  testWidgets(
    'separate artists and album remain actionable on narrow screens',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerArtistSheet(
              mediaItem: item,
              onArtist: (artist) => selected = artist.name,
              onAlbum: () => selected = 'album',
            ),
          ),
        ),
      );
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Record'), findsOneWidget);
      await tester.tap(find.text('Bob'));
      expect(selected, 'Bob');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('artist and release actions retain the selected identities', (
    tester,
  ) async {
    String? selectedName;
    String? selectedId;
    var albumSelected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerArtistSheet(
            mediaItem: item,
            artistIds: 'alice-id,bob-id',
            onArtist: (artist) {
              selectedName = artist.name;
              selectedId = artist.artistId;
            },
            onAlbum: () => albumSelected = true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Bob'));
    expect(selectedName, 'Bob');
    expect(selectedId, 'bob-id');
    await tester.tap(find.text('Record'));
    expect(albumSelected, isTrue);
  });
}
