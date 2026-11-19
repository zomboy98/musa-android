import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/track_video_source.dart';
import 'package:mornye/services/track_video_tags.dart';
import 'package:mornye/widgets/track_video_chip.dart';
import 'package:mornye/widgets/track_video_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Source implements TrackVideoSource {
  _Source(this.result);
  final TrackVideoOffer? result;
  int searches = 0;

  @override
  Future<TrackVideoOffer?> offerFor(Track track) async {
    searches++;
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

Widget _host(Widget child, {double width = 320, double scale = 2}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 640),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('no tag: one search, chip shown when a video exists', (
    tester,
  ) async {
    final source = _Source(
      const TrackVideoOffer(provider: 'youtube', videoId: 'abc'),
    );
    final lookup = TrackVideoLookup(
      tags: TrackVideoTags(),
      source: () => source,
    );
    await tester.pumpWidget(
      _host(TrackVideoGate(track: _track, lookup: lookup, onPressed: (_) {})),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(TrackVideoChip), findsOneWidget);
    expect(source.searches, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no tag and no result: chip hidden, nothing tagged', (
    tester,
  ) async {
    final tags = TrackVideoTags();
    final source = _Source(null);
    final lookup = TrackVideoLookup(tags: tags, source: () => source);
    await tester.pumpWidget(
      _host(TrackVideoGate(track: _track, lookup: lookup, onPressed: (_) {})),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(TrackVideoChip), findsNothing);
    expect(source.searches, 1);
    expect(await tester.runAsync(() => tags.read(_track)), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _host(TrackVideoGate(track: _track, lookup: lookup, onPressed: (_) {})),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    expect(source.searches, 2);
  });

  testWidgets('tag yes: chip shown without searching', (tester) async {
    final tags = TrackVideoTags();
    await tester.runAsync(
      () => tags.write(
        _track,
        offer: const TrackVideoOffer(provider: 'youtube', videoId: 'abc'),
      ),
    );
    final source = _Source(null);
    final lookup = TrackVideoLookup(tags: tags, source: () => source);
    TrackVideoTag? pressed;
    await tester.pumpWidget(
      _host(
        TrackVideoGate(
          track: _track,
          lookup: lookup,
          onPressed: (t) => pressed = t,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(TrackVideoChip), findsOneWidget);
    expect(source.searches, 0);
    await tester.tap(find.byType(TrackVideoChip));
    expect(pressed?.videoId, 'abc');
  });
}
