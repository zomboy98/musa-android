import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/utils/download_quality_options.dart';
import 'package:mornye/utils/playback_quality_options.dart';

/// Slice of the extension state that quality screens depend on, so they only
/// rebuild when providers, their priority or their loading state change.
typedef ExtensionQualityView = (
  List<Extension> extensions,
  List<String> priority,
  bool initialized,
  bool loading,
);

ExtensionQualityView extensionQualityView(ExtensionState s) =>
    (s.extensions, s.providerPriority, s.isInitialized, s.isLoading);

/// Provider whose qualities are offered: the configured default service, or
/// the first usable one by priority when it is missing.
String resolveQualityService(
  ExtensionQualityView view,
  String defaultService,
  bool autoFallback,
) {
  // Match catalog playback: exclude broken extensions and apply provider
  // priority only when resolving an alternative to the configured service.
  final usable = view.$1.where((e) => e.status != 'error').toList();
  final ordered = <Extension>[];
  for (final id in view.$2) {
    final normalized = id.trim().toLowerCase();
    for (final extension in usable) {
      if (extension.id.trim().toLowerCase() == normalized &&
          !ordered.contains(extension)) {
        ordered.add(extension);
      }
    }
  }
  ordered.addAll(usable.where((e) => !ordered.contains(e)));
  return resolveConfiguredDownloadService(
    defaultService,
    ExtensionState(extensions: ordered, providerPriority: view.$2),
    autoFallback: autoFallback,
  );
}

/// Download quality shown as selected for a provider: its stored choice, or
/// its source default when none is stored (nothing is written for that).
QualityOption downloadQualitySelection(
  String defaultService,
  String audioQuality,
  Map<String, String> byProvider,
  PlaybackQualityGroup group,
) {
  final key = group.extension.id.trim().toLowerCase();
  final configured = key == defaultService.trim().toLowerCase()
      ? audioQuality
      : byProvider[key] ?? '';
  return findDownloadQualityOption(group.options, configured) ??
      defaultDownloadQualityOption(key, group.options) ??
      group.options
          .where((o) => o.kind.trim().toLowerCase() == 'lossless')
          .firstOrNull ??
      group.options.first;
}

/// Providers that offer audio (catalog, lyrics and metadata sources are chosen
/// elsewhere), by priority and then by name.
List<Extension> audioProviders(
  Iterable<Extension> extensions,
  List<String> priority,
) {
  final rank = {
    for (final entry in priority.indexed) entry.$2.trim().toLowerCase(): entry.$1,
  };
  final usable = extensions
      .where((e) => e.enabled && e.status != 'error' && e.hasDownloadProvider)
      .toList();
  usable.sort((a, b) {
    final byRank = (rank[a.id.trim().toLowerCase()] ?? priority.length)
        .compareTo(rank[b.id.trim().toLowerCase()] ?? priority.length);
    return byRank != 0
        ? byRank
        : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  });
  return usable;
}

/// Keeps both quality choices valid for [provider]: a provider with a single
/// quality has it selected, a streaming choice it does not declare returns to
/// the light automatic mode, and an empty or undeclared download choice
/// becomes its default (MP3-equivalent) quality. Never leaves a choice empty.
void reconcileListenQualities(
  SettingsNotifier notifier,
  AppSettings settings,
  Extension provider,
) {
  final options = distinctDownloadQualityOptions(
    provider.qualityOptions,
  ).toList();
  if (options.isEmpty) return;
  final streaming = settings.playbackQuality.trim();
  if (options.length == 1) {
    if (!sameManifestQualityId(streaming, options.single.id)) {
      notifier.setPlaybackQuality(options.single.id);
    }
  } else if (streaming.isNotEmpty &&
      streaming != autoLightStreamingQuality &&
      findDownloadQualityOption(options, streaming) == null) {
    notifier.setPlaybackQuality(autoLightStreamingQuality);
  } else if (streaming.isEmpty) {
    notifier.setPlaybackQuality(autoLightStreamingQuality);
  }
  final key = provider.id.trim().toLowerCase();
  final configured = key == settings.defaultService.trim().toLowerCase()
      ? settings.audioQuality
      : settings.downloadQualityByProvider[key] ?? '';
  if (findDownloadQualityOption(options, configured) == null) {
    final fallback = defaultDownloadQualityFor(provider);
    if (fallback != null) {
      notifier.setAudioQualityForProvider(
        provider.id,
        manifestQualityId(fallback.id),
        option: fallback,
      );
    }
  }
}
