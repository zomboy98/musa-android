import 'package:mornye/services/jam/jam_track_reference.dart';

/// Portable test identity; never a device path or playback URL.
String jamTestTrack(String title) => JamTrackReference.create(
  isrc: 'USABC1234567',
  title: title,
  artist: 'Test artist',
)!.encode();
