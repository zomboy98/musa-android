import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/bluetooth_start_guard.dart';
import 'package:mornye/utils/lyrics_sync.dart';

final lyricsOutputPlatformProvider = Provider<BluetoothStartPlatform?>(
  (ref) => Platform.isAndroid ? const ChannelBluetoothStartPlatform() : null,
);

/// Whether the audio currently leaves the device over Bluetooth. Checked when
/// the provider starts and whenever playback starts or stops, which is when
/// the route can have changed.
class LyricsBluetoothRoute extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<bool>(playbackPlayingProvider, (_, _) => _refresh());
    _refresh();
    return false;
  }

  Future<void> _refresh() async {
    final platform = ref.read(lyricsOutputPlatformProvider);
    if (platform == null) return;
    final routed = await platform.routedToBluetooth();
    if (ref.mounted && routed != state) state = routed;
  }
}

final lyricsBluetoothRouteProvider =
    NotifierProvider<LyricsBluetoothRoute, bool>(LyricsBluetoothRoute.new);

/// The shift for one track, in ms, kept current with the listener's setting
/// and the audio route.
final lyricsTimingOffsetProvider =
    Provider.family<int, ({int? trackMs, int autoMs})>(
      (ref, track) => effectiveLyricsOffsetMs(
        globalMs: ref.watch(themeProvider.select((t) => t.lyricsOffsetMs)),
        trackMs: track.trackMs,
        autoMs: track.autoMs,
        bluetooth: ref.watch(lyricsBluetoothRouteProvider),
      ),
    );
