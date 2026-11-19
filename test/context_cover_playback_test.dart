import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/utils/context_cover_availability.dart';
import 'package:mornye/utils/playback_artwork.dart';

const _filePath = '/storage/emulated/0/Music/MUSA/Fuerza Regida/111XPANTIA/01.m4a';
const _normalCover = 'https://covers.test/normal.jpg';
const _deluxeCover = 'https://covers.test/deluxe.jpg';

Track _track(String album, String cover) => Track(
  id: 'godfather',
  name: 'GodFather',
  artistName: 'Fuerza Regida',
  albumName: album,
  coverUrl: cover,
  isrc: 'USA2P2512345',
  duration: 180,
  trackNumber: 1,
);

class _FailingCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => Stream<FileResponse>.error(Exception('sin conexion'));
}

void main() {
  test('a song opened from an album keeps that album cover and name', () {
    final deluxe = playableFromTrack(
      _track('111XPANTIA (Deluxe)', _deluxeCover),
      _filePath,
    );
    final normal = playableFromTrack(
      _track('111XPANTIA', _normalCover),
      _filePath,
    );

    expect(deluxe.artUri, _deluxeCover);
    expect(deluxe.album, '111XPANTIA (Deluxe)');
    expect(deluxe.toMediaItem().artUri, Uri.parse(_deluxeCover));
    expect(normal.artUri, _normalCover);
    expect(normal.album, '111XPANTIA');
  });

  test('the album cover survives queue serialization', () {
    final media = playableFromTrack(
      _track('111XPANTIA (Deluxe)', _deluxeCover),
      _filePath,
    );
    final restored = PlayableMedia.fromJson(media.toJson())!;
    expect(restored.contextCover, isTrue);
    expect(restored.artUri, _deluxeCover);
  });

  test('the file embedded cover no longer replaces the album cover', () async {
    final media = playableFromTrack(
      _track('111XPANTIA (Deluxe)', _deluxeCover),
      _filePath,
    );
    var extracted = false;
    final kept = await resolveEmbeddedArtworkUri(
      media.source,
      media.artUri,
      keepRemoteArtwork: media.contextCover,
      extract: (_) async {
        extracted = true;
        return '/cache/normal.jpg';
      },
    );
    expect(kept, isNull);
    expect(extracted, isFalse);
  });

  test('a file played from downloads still shows its own cover', () async {
    final media = playableFromHistory(
      DownloadHistoryItem(
        id: 'h1',
        trackName: 'GodFather',
        artistName: 'Fuerza Regida',
        albumName: '111XPANTIA',
        coverUrl: _normalCover,
        filePath: _filePath,
        downloadedAt: DateTime(2026),
        service: 'tidal',
      ),
    );
    expect(media.contextCover, isFalse);
    final recovered = await resolveEmbeddedArtworkUri(
      media.source,
      media.artUri,
      keepRemoteArtwork: media.contextCover,
      extract: (_) async => '/cache/normal.jpg',
    );
    expect(recovered, Uri.file('/cache/normal.jpg').toString());
  });

  group('context cover availability', () {
    PlayableMedia media() => playableFromTrack(
      _track('111XPANTIA (Deluxe)', _deluxeCover),
      _filePath,
    );

    Future<String?> run({required bool cached, required bool online}) {
      final m = media();
      return resolveEmbeddedArtworkUri(
        m.source,
        m.artUri,
        keepRemoteArtwork: m.contextCover,
        remoteAvailable: (url) => contextCoverAvailable(
          url,
          isCached: (_) async => cached,
          isOnline: () async => online,
        ),
        extract: (_) async => '/cache/embedded.jpg',
      );
    }

    test('offline and not cached falls back to the embedded cover', () async {
      expect(
        await run(cached: false, online: false),
        Uri.file('/cache/embedded.jpg').toString(),
      );
    });

    test('online keeps the context cover', () async {
      expect(await run(cached: false, online: true), isNull);
    });

    test('offline with the context cover cached keeps it', () async {
      expect(await run(cached: true, online: false), isNull);
    });
  });

  testWidgets('a failing network cover falls back to the embedded one', (
    tester,
  ) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('fallback-art-'),
    ))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/embedded.png');
    await tester.runAsync(() => file.writeAsBytes(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    )));
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerArtwork(
          artUri: 'https://covers.test/missing.jpg',
          cacheManager: _FailingCache(),
          fallbackUri: file.uri.toString(),
          colorScheme: const ColorScheme.light(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is FileImage,
      ),
      findsOneWidget,
    );
  });
}
