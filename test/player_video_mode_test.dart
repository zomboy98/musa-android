import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_video_mode_provider.dart';
import 'package:mornye/widgets/player_cover_actions.dart';

const _first = MediaItem(id: 'a', title: 'A', artist: 'Artist');
const _second = MediaItem(id: 'b', title: 'B', artist: 'Artist');

class _Current extends CurrentMediaItemNotifier {
  @override
  Stream<MediaItem?> build() => _items.stream;
}

final _items = StreamController<MediaItem?>.broadcast();

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [currentMediaItemProvider.overrideWith(_Current.new)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('the video path belongs to the song that started it', () async {
    final container = _container();
    container.listen(currentMediaItemProvider, (_, _) {});
    _items.add(_first);
    await container.read(currentMediaItemProvider.future);
    container.listen(playerVideoModeProvider, (_, _) {});
    expect(container.read(playerVideoPathProvider(_first)), isNull);
    container
        .read(playerVideoModeProvider.notifier)
        .show(const PlayerVideoMode(mediaId: 'a', path: '/v/a.mp4'));
    expect(container.read(playerVideoPathProvider(_first)), '/v/a.mp4');
    expect(container.read(playerVideoPathProvider(_second)), isNull);
  });

  test('changing song leaves video mode', () async {
    final container = _container();
    container.listen(currentMediaItemProvider, (_, _) {});
    _items.add(_first);
    await container.read(currentMediaItemProvider.future);
    container.listen(playerVideoModeProvider, (_, _) {});
    container
        .read(playerVideoModeProvider.notifier)
        .show(const PlayerVideoMode(mediaId: 'a', path: '/v/a.mp4'));
    _items.add(_second);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(playerVideoModeProvider), isNull);
  });

  test('clear returns to audio only', () {
    final container = _container();
    container.listen(playerVideoModeProvider, (_, _) {});
    container
        .read(playerVideoModeProvider.notifier)
        .show(const PlayerVideoMode(mediaId: 'a', path: '/v/a.mp4'));
    container.read(playerVideoModeProvider.notifier).clear();
    expect(container.read(playerVideoModeProvider), isNull);
  });

  testWidgets('without a catalog identity the artist tap uses the fallback', (
    tester,
  ) async {
    var fallbacks = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showPlayerArtistsSheet(
                context,
                ref,
                _first,
                fallback: () async => fallbacks++,
              ),
              child: const Text('artist'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('artist'));
    await tester.pump();
    expect(fallbacks, 1);
  });
}
