import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/track_video_source.dart';
import 'package:mornye/services/track_video_tags.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Source implements TrackVideoSource {
  _Source(this.result);
  TrackVideoOffer? result;
  int searches = 0;
  Completer<void>? gate;

  @override
  Future<TrackVideoOffer?> offerFor(Track track) async {
    searches++;
    await gate?.future;
    return result;
  }

  @override
  Future<String?> prepare(Track track, TrackVideoOffer offer) async => null;
}

const _track = Track(
  id: 'a',
  name: 'n',
  artistName: 'x',
  albumName: 'y',
  duration: 10,
  isrc: 'USABC1234567',
);
const _other = Track(
  id: 'b',
  name: 'm',
  artistName: 'x',
  albumName: 'y',
  duration: 10,
  isrc: 'USABC7654321',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('no tag: one search, tag saved with the video id', () async {
    final source = _Source(
      const TrackVideoOffer(provider: 'youtube', videoId: 'abc'),
    );
    final lookup = TrackVideoLookup(
      tags: TrackVideoTags(),
      source: () => source,
    );
    final first = await lookup.tagFor(_track);
    expect(first?.hasVideo, isTrue);
    expect(first?.videoId, 'abc');
    final second = await lookup.tagFor(_track);
    expect(second?.hasVideo, isTrue);
    expect(source.searches, 1);
  });

  test('no result tags nothing and the next play searches again', () async {
    final source = _Source(null);
    final tags = TrackVideoTags();
    final lookup = TrackVideoLookup(tags: tags, source: () => source);
    expect(await lookup.tagFor(_track), isNull);
    expect(await tags.read(_track), isNull);
    source.result = const TrackVideoOffer(provider: 'youtube', videoId: 'z');
    expect((await lookup.tagFor(_track))?.videoId, 'z');
    expect(source.searches, 2);
    expect((await lookup.tagFor(_track))?.videoId, 'z');
    expect(source.searches, 2);
  });

  test('tag yes with no source available needs no search', () async {
    final tags = TrackVideoTags();
    await tags.write(
      _track,
      offer: const TrackVideoOffer(provider: 'youtube', videoId: 'abc'),
    );
    final source = _Source(null);
    final lookup = TrackVideoLookup(tags: tags, source: () => source);
    expect((await lookup.tagFor(_track))?.hasVideo, isTrue);
    expect(source.searches, 0);
  });

  test('simultaneous requests share one search', () async {
    final source = _Source(
      const TrackVideoOffer(provider: 'youtube', videoId: 'abc'),
    )..gate = Completer<void>();
    final lookup = TrackVideoLookup(
      tags: TrackVideoTags(),
      source: () => source,
    );
    final a = lookup.tagFor(_track);
    final b = lookup.tagFor(_track);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    source.gate!.complete();
    expect((await a)?.hasVideo, isTrue);
    expect((await b)?.hasVideo, isTrue);
    expect(source.searches, 1);
  });

  test('cancelled search saves nothing', () async {
    final source = _Source(
      const TrackVideoOffer(provider: 'youtube', videoId: 'abc'),
    )..gate = Completer<void>();
    final tags = TrackVideoTags();
    final lookup = TrackVideoLookup(tags: tags, source: () => source);
    final pending = lookup.tagFor(_track);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    lookup.cancel(_track);
    source.gate!.complete();
    expect(await pending, isNull);
    expect(await tags.read(_track), isNull);
  });

  test('without a provider nothing is searched or tagged', () async {
    final lookup = TrackVideoLookup(tags: TrackVideoTags(), source: () => null);
    expect(await lookup.tagFor(_track), isNull);
  });

  test('tags leave with their song', () async {
    final tags = TrackVideoTags();
    await tags.write(
      _track,
      offer: const TrackVideoOffer(provider: 'youtube', videoId: 'p'),
    );
    await tags.write(
      _other,
      offer: const TrackVideoOffer(provider: 'youtube', videoId: 'q'),
    );
    final removed = await tags.prune((key) async => key == 'isrc:USABC7654321');
    expect(removed, 1);
    expect(await tags.read(_track), isNull);
    expect((await tags.read(_other))?.hasVideo, isTrue);
    await tags.forget(_other);
    expect(await tags.read(_other), isNull);
  });
}
