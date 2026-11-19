import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_app_controller.dart';
import 'package:mornye/services/jam/jam_invitation_codec.dart';
import 'package:mornye/services/jam/jam_network_address.dart';
import 'package:mornye/services/jam/jam_playback_runtime.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_track_reference.dart';
import 'package:mornye/services/jam/jam_track_resolver.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playable_media.dart';

import 'support/music_player_automix_harness.dart';

Future<InternetAddress> _localAddress() async {
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final address in interface.addresses) {
      if (!address.isLoopback && isJamAddress(address)) return address;
    }
  }
  return InternetAddress.loopbackIPv4;
}

void main() {
  setUpMusicPlayerHarness();

  test('two controllers synchronize local playback over pinned TLS', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final address = await _localAddress();
    // The selected address is visible in the test report, including fallback.
    // ignore: avoid_print
    print('Jam TLS test interface: ${address.address}');
    final network = LocalNetworkAccess(isAndroid: false);
    final host = JamAppController(networkAccess: network);
    final guest = JamAppController(
      networkAccess: network,
      pollInterval: const Duration(milliseconds: 50),
    );
    addTearDown(host.dispose);
    addTearDown(guest.dispose);
    addTearDown(() async {
      await guest.close();
      await host.close();
    });

    JamTrackReference ref(String isrc, String title) =>
        JamTrackReference.create(isrc: isrc, title: title, artist: 'Artist')!;
    final one = ref('USABC1200001', 'One');
    final two = ref('USABC1200002', 'Two');
    var inventoryReads = 0;
    final resolver = JamLibraryTrackResolver<PlayableMedia>(() async {
      inventoryReads++;
      return [
        JamLocalCandidate(reference: one, value: testTracks[0]),
        JamLocalCandidate(reference: two, value: testTracks[1]),
      ];
    });
    await handler.setQueueAndPlay([testTracks.first]);
    await handler.seek(const Duration(seconds: 12));
    await handler.pause();
    final source = native.sources['music-player'];
    final position = handler.playbackState.value.position;

    await host.startHosting(address: address);
    expect(host.phase, JamAppPhase.hosting, reason: '${host.error}');
    expect(
      await host.add(trackId: one.encode(), occurrenceId: 'one'),
      JamOutcome.applied,
    );
    host.attachHostPlayback(
      resolver: resolver,
      port: RuntimeJamPlaybackPort(musicPlayerRuntime),
    );
    await waitUntil(() => host.playbackState == JamPlaybackState.synchronized);
    final invite = JamInvitationCodec.decode(
      JamInvitationCodec.encode(host.invitation!),
    );
    expect(invite.endpoint.scheme, 'https');
    expect(invite.endpoint.host, address.address);
    await guest.join(invite);
    expect(guest.phase, JamAppPhase.connected, reason: '${guest.error}');
    expect(
      await guest.add(trackId: two.encode(), occurrenceId: 'two'),
      JamOutcome.applied,
    );
    await waitUntil(
      () =>
          handler.queue.value.length == 2 &&
          host.playbackState == JamPlaybackState.synchronized,
    );
    expect(
      await guest.move(occurrenceId: 'two', beforeOccurrenceId: 'one'),
      JamOutcome.applied,
    );
    await waitUntil(
      () =>
          handler.queue.value.first.id == 'two' &&
          host.playbackState == JamPlaybackState.synchronized,
    );
    expect(await guest.remove(occurrenceId: 'two'), JamOutcome.applied);
    await waitUntil(
      () =>
          handler.queue.value.length == 1 &&
          host.playbackState == JamPlaybackState.synchronized,
    );
    expect(guest.snapshot!.entries.map((e) => e.occurrenceId), ['one']);
    expect(host.snapshot!.entries.map((e) => e.occurrenceId), ['one']);
    expect(native.sources['music-player'], source);
    expect(handler.playbackState.value.position, position);
    expect(handler.playbackState.value.playing, isFalse);
    expect(inventoryReads, greaterThan(0));
    expect(native.sources.values, everyElement(startsWith('/')));

    await guest.close();
    await guest.join(invite); // A consumed invitation cannot pair again.
    expect(guest.phase, JamAppPhase.error);
    host.renewInvitation();
    await guest.join(
      JamInvitationCodec.decode(JamInvitationCodec.encode(host.invitation!)),
    );
    expect(guest.phase, JamAppPhase.connected, reason: '${guest.error}');
    await host.close();
    await waitUntil(() => guest.phase == JamAppPhase.error);
    expect(host.snapshot, isNull);
    expect(guest.snapshot, isNull);
    expect(native.sources['music-player'], source);
    expect(handler.playbackState.value.position, position);
  });
}
