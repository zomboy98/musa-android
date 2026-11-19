import 'package:mornye/models/track.dart';

class TrackVideoOffer {
  const TrackVideoOffer({required this.provider, required this.videoId});

  final String provider;
  final String videoId;
}

class TrackVideoNeedsNetwork implements Exception {
  const TrackVideoNeedsNetwork();
}

/// Where a song's video comes from. Availability must come from real data:
/// [offerFor] returns null when the provider has no video for the song or
/// cannot be asked.
abstract interface class TrackVideoSource {
  Future<TrackVideoOffer?> offerFor(Track track);

  /// Fetches the video with its audio and returns a playable path, or null
  /// when it could not be prepared. It never touches saved files.
  Future<String?> prepare(Track track, TrackVideoOffer offer);
}

/// Set once a provider that can answer both calls is available. While null,
/// no song shows the video chip.
TrackVideoSource? trackVideoSource;
