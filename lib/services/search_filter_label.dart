import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/extension.dart';

/// The label of a search filter chip.
///
/// Extensions declare English labels ("Songs", "Albums"). For a recognized
/// kind (all, songs, albums, artists, playlists) the app's own string is used
/// when the app language is Spanish, so the chips never mix languages. Other
/// languages keep the extension's label (no regression for them). The filter id sent to the extension is untouched; an unknown
/// kind keeps the extension's label.
String searchFilterLabel(
  AppLocalizations l10n,
  SearchFilter filter, {
  String? languageCode,
}) {
  final declared = filter.label ?? filter.id;
  if ((languageCode ?? l10n.localeName.split('_').first) != 'es') {
    return declared;
  }
  for (final candidate in [filter.id, filter.label, filter.icon]) {
    if (candidate == null || candidate.trim().isEmpty) continue;
    switch (canonicalExtensionSearchFilterId(candidate)) {
      case 'all':
        return l10n.historyFilterAll;
      case 'track':
        return l10n.searchSongs;
      case 'album':
        return l10n.searchAlbums;
      case 'artist':
        return l10n.searchArtists;
      case 'playlist':
        return l10n.searchPlaylists;
    }
  }
  return declared;
}
