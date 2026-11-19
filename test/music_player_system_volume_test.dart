import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/system_volume_service.dart';

import 'support/music_player_automix_harness.dart';

void main() {
  setUpMusicPlayerHarness();

  test('system mute keeps playback running, including after manual play', () async {
    const events = MethodChannel(
      'com.kurenai7968.volume_controller.volume_listener_event',
    );
    native.messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() => native.messenger.setMockMethodCallHandler(events, null));
    final listener = SystemVolumeService.instance.changes.listen((_) {});
    addTearDown(listener.cancel);

    setPlaybackAutomationOptions(
      enabled: true,
      pauseOnMute: true,
      playOnHeadphonesConnected: false,
    );
    await handler.setQueueAndPlay(testTracks);
    Future<void> volume(double value) => native.messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
    await volume(0.5);
    await volume(0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handler.playbackState.value.playing, isTrue);
    expect(native.playing, {'music-player'});

    await handler.pause();
    await handler.play();
    await volume(0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handler.playbackState.value.playing, isTrue);
    expect(native.playing, {'music-player'});
  });
}
