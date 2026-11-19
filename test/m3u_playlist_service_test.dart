import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/m3u_playlist_service.dart';

void main() {
  group('parseM3u', () {
    test('derives cross-platform and file URI names without changing paths', () {
      final entries = M3uPlaylistService.parseM3uEntries(r'''
C:\Music\Artist\Mi canción.mp3
file:///Music/Mi%20canci%C3%B3n.mp3
file:///Music/AC%2FDC.flac
Music/100%20real.mp3
#EXTINF:5,Explicit - Title
C:\Other\ignored.mp3
C:\Music\Artist\Mi canción.mp3
''', idSeed: 1);
      expect(entries.map((e) => e.track.name), [
        'Mi canción', 'Mi canción', 'AC/DC', '100%20real', 'Title', 'Mi canción',
      ]);
      expect(entries[4].track.artistName, 'Explicit');
      expect(entries[0].path, r'C:\Music\Artist\Mi canción.mp3');
      expect(entries[2].path, 'file:///Music/AC%2FDC.flac');
      expect(entries.map((e) => e.track.id).toSet(), hasLength(6));
    });
    test('reads EXTINF duration, artist, and title', () {
      final tracks = M3uPlaylistService.parseM3u('''
#EXTM3U
#EXTINF:245,Daft Punk - Harder Better Faster Stronger
Daft Punk/Discovery/04 Harder Better Faster Stronger.flac
#EXTINF:-1,Solo Title Only
music/solo.flac
''');

      expect(tracks, hasLength(2));
      expect(tracks[0].name, 'Harder Better Faster Stronger');
      expect(tracks[0].artistName, 'Daft Punk');
      expect(tracks[0].duration, 245);
      expect(tracks[1].name, 'Solo Title Only');
      expect(tracks[1].artistName, 'Unknown Artist');
      expect(tracks[1].duration, 0);
    });

    test('falls back to the file name stem without EXTINF', () {
      final tracks = M3uPlaylistService.parseM3u('''
# a comment
Some Artist - Some Song.mp3
''');

      expect(tracks, hasLength(1));
      expect(tracks[0].artistName, 'Some Artist');
      expect(tracks[0].name, 'Some Song');
    });
  });

  group('buildM3u8Content', () {
    test('writes EXTM3U header and EXTINF entries', () {
      final content = M3uPlaylistService.buildM3u8Content([
        M3uExportEntry(
          track: Track(
            id: 't1',
            name: 'Song',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 200,
            coverUrl: null,
          ),
          path: 'Artist/Album/Song.flac',
        ),
      ]);

      expect(
        content,
        '#EXTM3U\n#EXTINF:200,Artist - Song\nArtist/Album/Song.flac\n',
      );
    });
  });

  group('exportPathFor', () {
    test('passes plain paths through', () {
      expect(
        M3uPlaylistService.exportPathFor('/storage/emulated/0/Music/a.flac'),
        '/storage/emulated/0/Music/a.flac',
      );
    });

    test('makes SAF document URIs relative to their tree root', () {
      expect(
        M3uPlaylistService.exportPathFor(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic/document/'
          'primary%3AMusic%2FArtist%2FAlbum%2Fsong.flac',
        ),
        'Artist/Album/song.flac',
      );
    });

    test('strips the storage prefix without tree context', () {
      expect(
        M3uPlaylistService.exportPathFor(
          'content://com.android.externalstorage.documents/document/'
          'primary%3AMusic%2Fsong.flac',
        ),
        'Music/song.flac',
      );
    });

    test('returns null for content URIs without a document path', () {
      expect(
        M3uPlaylistService.exportPathFor('content://media/external/audio/1'),
        isNull,
      );
    });
  });
}
