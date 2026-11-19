import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_service.dart';

import 'support/music_player_automix_harness.dart';

class _DelayedRuntime extends MusicPlayerRuntime {
  final ready = Completer<MusicPlayerHandler>();
  @override
  Future<MusicPlayerHandler> initialize() => ready.future;
}
class _CountHandler extends MusicPlayerHandler {
  int calls = 0;
  @override
  Future<void> setQueueAndPlay(List<PlayableMedia> items, {int initialIndex = 0, Duration initialPosition = Duration.zero, bool? shuffle}) async { calls++; }
}

void main() {
  setUpMusicPlayerHarness();
  test('obsolete queue request cannot start after delayed initialization', () async {
    await handler.dispose();
    final runtime = _DelayedRuntime();
    final controller = MusicPlayerController(runtime: runtime);
    final target = _CountHandler();
    addTearDown(target.dispose);
    var current = true;
    const media = PlayableMedia(id: 'x', source: 'catalog:x', title: 'X', artist: 'A');
    final pending = controller.playAll([media], isCurrentRequest: () => current);
    current = false;
    runtime.ready.complete(target);
    await pending;
    expect(target.calls, 0);
  });
}
