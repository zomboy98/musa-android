import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/track_video_source.dart';
import 'package:mornye/services/video_network_policy.dart';
import 'package:mornye/services/youtube_track_video_source.dart';

void installYoutubeTrackVideoSource(ProviderContainer container) {
  if (trackVideoSource != null) return;
  trackVideoSource = createYoutubeTrackVideoSource(
    isAvailable: () => container
        .read(extensionProvider)
        .extensions
        .any(
          (e) =>
              e.id.trim().toLowerCase() == youtubeVideoProviderId &&
              e.enabled &&
              e.status != 'error' &&
              e.hasDownloadProvider,
        ),
    networkAllowed: () => videoNetworkAllowed(
      allowMobileData: container.read(
        settingsProvider.select((s) => s.videoMobileDataEnabled),
      ),
    ),
  );
}
