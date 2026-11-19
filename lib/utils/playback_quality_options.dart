import 'package:mornye/models/extension.dart';
import 'package:mornye/utils/download_quality_options.dart';

/// Quality options of one download provider, without repeated rows.
class PlaybackQualityGroup {
  const PlaybackQualityGroup(this.extension, this.options);

  final Extension extension;
  final List<QualityOption> options;

  String get title => extension.displayName.trim().isEmpty
      ? extension.id
      : extension.displayName.trim();
}

/// Every quality option of every enabled, error-free download provider.
/// The configured service comes first, then the provider priority order and
/// finally the remaining providers alphabetically.
List<PlaybackQualityGroup> playbackQualityGroups(
  Iterable<Extension> extensions, {
  required String configuredService,
  List<String> providerPriority = const [],
}) {
  final usable = extensions
      .where(
        (extension) =>
            extension.enabled &&
            extension.status != 'error' &&
            extension.hasDownloadProvider,
      )
      .toList();
  final priority = <String, int>{
    for (final entry in providerPriority.indexed)
      entry.$2.trim().toLowerCase(): entry.$1,
  };
  final configured = configuredService.trim().toLowerCase();
  int rank(Extension extension) {
    final id = extension.id.trim().toLowerCase();
    if (id == configured) return -1;
    return priority[id] ?? providerPriority.length;
  }

  usable.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  });
  return [
    for (final extension in usable)
      if (distinctDownloadQualityOptions(extension.qualityOptions).toList()
          case final options when options.isNotEmpty)
        PlaybackQualityGroup(extension, options),
  ];
}

/// The group and option a saved quality id points at (first provider, in
/// display order, that declares it), or null when nothing matches.
({PlaybackQualityGroup group, QualityOption option})? matchPlaybackQuality(
  List<PlaybackQualityGroup> groups,
  String saved,
) {
  for (final group in groups) {
    final option = findDownloadQualityOption(group.options, saved);
    if (option != null) return (group: group, option: option);
  }
  return null;
}
