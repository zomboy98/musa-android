import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/jam/jam_track_reference.dart';
import 'package:mornye/services/jam/jam_track_resolver.dart';

void main() {
  JamTrackReference ref({String? id = '123', String? isrc = 'USABC1234567', String title = 'Song', String artist = 'Artist'}) => JamTrackReference.create(provider: id == null ? null : 'tidal', externalId: id, isrc: isrc, title: title, artist: artist)!;

  test('round trips distinct title and artist and rejects paths', () {
    final original = ref();
    final decoded = JamTrackReference.tryDecode(original.encode())!;
    expect(decoded.title, 'Song');
    expect(decoded.artist, 'Artist');
    expect(decoded.externalId, '123');
    expect(JamTrackReference.tryDecode('C:\\secret.mp3'), isNull);
    expect(JamTrackReference.create(provider: 'local', externalId: '123', title: 'Song', artist: 'Artist'), isNull);
    expect(JamTrackReference.create(provider: 'tidal', externalId: '../123', title: 'Song', artist: 'Artist'), isNull);
  });

  test('allows musical slashes while rejecting recognizable paths and oversized text', () {
    final musical = ref(title: 'Love/Hate', artist: 'AC/DC');
    final decoded = JamTrackReference.tryDecode(musical.encode())!;
    expect(decoded.title, 'Love/Hate');
    expect(decoded.artist, 'AC/DC');
    for (final path in ['/home/user/song', '../secret', r'C:\secret', 'file:///song', 'folder/song.mp3', 'a/b/c']) {
      expect(JamTrackReference.create(isrc: 'USABC1234567', title: path, artist: 'Artist'), isNull, reason: path);
    }
    expect(JamTrackReference.create(isrc: 'USABC1234567', title: 'x' * 101, artist: 'Artist'), isNull);
    expect(JamTrackReference.create(isrc: 'USABC1234567', title: 'x' * 100, artist: 'y' * 100), isNull);
  });
  test('local tracks without portable identity are unavailable', () {
    const track = Track(id: 'private', name: 'Song', artistName: 'Artist', albumName: '', duration: 1, source: 'local');
    expect(JamTrackReference.fromTrack(track), isNull);
    expect(JamTrackReference.fromTrack(track.copyWith(isrc: 'USABC1234567'))?.isrc, 'USABC1234567');
  });

  test('resolves exact unique identity and rejects ambiguity and conflicts', () async {
    final reference = ref();
    final candidates = <JamLocalCandidate<String>>[JamLocalCandidate(reference: reference, value: 'local')];
    final resolver = JamLibraryTrackResolver<String>(() async => candidates);
    expect(await resolver.resolveLocal(reference.encode()), 'local');
    expect(await resolver.resolveLocal(ref(id: '456', isrc: null).encode()), isNull);
    candidates.add(JamLocalCandidate(reference: reference, value: 'second'));
    expect(await resolver.resolveLocal(reference.encode()), isNull);
    candidates.clear();
    candidates.add(JamLocalCandidate(reference: ref(isrc: 'GBABC1234567'), value: 'conflict'));
    expect(await resolver.resolveLocal(reference.encode()), isNull);
  });
}

