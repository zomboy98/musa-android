import 'package:mornye/utils/extension_error_message.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/services/playlist_sources.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/cover_collage_backdrop.dart';
import 'package:mornye/widgets/import_tracks_collage.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/provider_icon.dart';

final _log = AppLogger('CreatePlaylist');
bool _importInProgress = false;

enum _PlaylistSource {
  empty,
  folder,
  file,
  link,
  spotify,
  appleMusic,
  youtubeMusic,
}

/// Creates a playlist that starts empty, holds one Library folder, or
/// imports an M3U or CSV file matched to local files.
Future<void> showCreatePlaylistSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = context.l10n;
  final source = await showAppScrollableBottomSheet<_PlaylistSource>(
    context: context,
    title: l10n.collectionCreatePlaylist,
    builder: (sheetContext, controller) => SingleChildScrollView(
      controller: controller,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (source, icon, title, subtitle) in [
            (
              _PlaylistSource.empty,
              Icons.playlist_add,
              l10n.playlistCreateEmpty,
              l10n.playlistCreateEmptySubtitle,
            ),
            (
              _PlaylistSource.folder,
              Icons.folder_outlined,
              l10n.playlistCreateFromFolder,
              l10n.playlistCreateFromFolderSubtitle,
            ),
            (
              _PlaylistSource.link,
              Icons.link,
              context.l10n.createPlaylistImportPublicLink,
              context.l10n.createPlaylistUsesACompatibleExtension,
            ),
            (
              _PlaylistSource.file,
              Icons.file_open_outlined,
              l10n.playlistImportFile,
              l10n.playlistImportFileSubtitle,
            ),
          ])
            AppSheetOption(
              leading: AppIcon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              onTap: () => Navigator.pop(sheetContext, source),
            ),
          for (final (source, platform) in [
            (_PlaylistSource.spotify, 'Spotify'),
            (_PlaylistSource.appleMusic, 'Apple Music'),
            (_PlaylistSource.youtubeMusic, 'YouTube Music'),
          ])
            AppSheetOption(
              leading: ProviderIcon(provider: platform),
              title: Text(platform),
              subtitle: Text(context.l10n.createPlaylistUseAPublicLink),
              onTap: () => Navigator.pop(sheetContext, source),
            ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  switch (source) {
    case _PlaylistSource.empty:
      await _createEmpty(context, ref);
    case _PlaylistSource.folder:
      await _createFromFolder(context, ref);
    case _PlaylistSource.file:
      await importPlaylistFile(context, ref);
    case _PlaylistSource.link:
      await importPlaylistLink(context, ref);
    case _PlaylistSource.spotify:
      await importPlaylistLink(context, ref, platform: 'Spotify');
    case _PlaylistSource.appleMusic:
      await importPlaylistLink(context, ref, platform: 'Apple Music');
    case _PlaylistSource.youtubeMusic:
      await importPlaylistLink(context, ref, platform: 'YouTube Music');
  }
}

Future<String?> _promptName(BuildContext context, [String? initialName]) =>
    promptPlaylistName(
      context,
      title: context.l10n.collectionCreatePlaylist,
      confirmLabel: context.l10n.actionCreate,
      initialName: initialName,
    );

Future<void> _createEmpty(BuildContext context, WidgetRef ref) async {
  final name = await _promptName(context);
  if (name == null || name.isEmpty) return;
  await ref.read(libraryCollectionsProvider.notifier).createPlaylist(name);
}

Future<void> _createFromFolder(BuildContext context, WidgetRef ref) async {
  final library = LibraryDatabase.instance;
  // The sheet may close before the scan answers; it reports any error.
  final folders = loadLibraryFolders(library)..ignore();
  final folder = await showAppScrollableBottomSheet<LibraryFolder>(
    context: context,
    title: context.l10n.playlistFolderPickerTitle,
    builder: (sheetContext, controller) =>
        _FolderList(folders: folders, controller: controller),
  );
  if (folder == null || !context.mounted) return;
  final name = await _promptName(context, folder.name);
  if (name == null || name.isEmpty || !context.mounted) return;

  final tracks = await libraryFolderTracks(folder, library);
  final notifier = ref.read(libraryCollectionsProvider.notifier);
  final id = await notifier.createPlaylist(name);
  final result = await notifier.addTracksToPlaylist(id, tracks);
  if (!context.mounted) return;
  showAppSnackBar(
    context,
    content: Text(
      context.l10n.playlistCreatedWithTracks(name, result.addedCount),
    ),
  );
}

/// Resolves a public link using an installed extension and saves its tracks.
Future<void> importPlaylistLink(
  BuildContext context,
  WidgetRef ref, {
  String? platform,
}) async {
  if (_importInProgress) return;
  _importInProgress = true;
  try {
    await _importPlaylistLink(context, ref, platform: platform);
  } finally {
    _importInProgress = false;
  }
}

Future<void> _importPlaylistLink(
  BuildContext context,
  WidgetRef ref, {
  String? platform,
}) async {
  var input = '';
  final url = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        platform == null
            ? context.l10n.createPlaylistImportPublicLink
            : context.l10n.createPlaylistImportFromPlatform(platform),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(context.l10n.createPlaylistOpenAPublicPlaylistInYour),
          TextField(
            onChanged: (value) => input = value,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: context.l10n.createPlaylistPlaylistLink,
              helperText: context
                  .l10n
                  .createPlaylistRequiresAnEnabledCompatibleExtension,
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(context.l10n.dialogCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, input.trim()),
          child: Text(context.l10n.createPlaylistContinue),
        ),
      ],
    ),
  );
  if (url == null || url.isEmpty || !context.mounted) return;
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty) {
    showAppSnackBar(
      context,
      content: Text(context.l10n.createPlaylistEnterAValidHttpLink),
    );
    return;
  }
  final allowedHosts = switch (platform) {
    'Spotify' => ['spotify.com', 'spotify.link'],
    'Apple Music' => ['music.apple.com'],
    'YouTube Music' => ['music.youtube.com', 'youtube.com', 'youtu.be'],
    _ => <String>[],
  };
  final host = uri.host.toLowerCase();
  if (allowedHosts.isNotEmpty &&
      !allowedHosts.any(
        (domain) => host == domain || host.endsWith('.$domain'),
      )) {
    showAppSnackBar(
      context,
      content: Text(context.l10n.createPlaylistEnterAPlatformLink(platform!)),
    );
    return;
  }
  try {
    final request = ref
        .read(linkDesktopDownloadsProvider)
        .resolveUrl(url)
        .then<LinkResolvedLink?>(
          (value) => value,
          onError: (Object error, StackTrace stack) {
            _log.e('Failed to resolve playlist link', error, stack);
            return null;
          },
        );
    final resolved = await showDialog<LinkResolvedLink>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: FutureBuilder<LinkResolvedLink?>(
          future: request,
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, snapshot.data);
                }
              });
            }
            return AlertDialog(
              title: Text(context.l10n.createPlaylistCheckingPlaylist),
              content:
                  snapshot.connectionState == ConnectionState.done &&
                      !snapshot.hasData
                  ? Text(context.l10n.createPlaylistCouldNotCheckTheLinkCheck)
                  : Semantics(
                      liveRegion: true,
                      label: context.l10n.createPlaylistCheckingLink,
                      child: const LinearProgressIndicator(),
                    ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(context.l10n.dialogCancel),
                ),
              ],
            );
          },
        ),
      ),
    );
    if (resolved == null || !context.mounted) return;
    if (resolved.playlistName == null || resolved.tracks.isEmpty) {
      showAppSnackBar(
        context,
        content: Text(context.l10n.createPlaylistTheLinkDoesNotContainAn),
      );
      return;
    }
    final selected = await _selectImportTracks(
      context,
      resolved.tracks,
      resolved.playlistName!,
    );
    if (selected == null || selected.isEmpty || !context.mounted) return;
    final name = await _promptName(context, resolved.playlistName);
    if (name == null || name.isEmpty || !context.mounted) return;
    final notifier = ref.read(libraryCollectionsProvider.notifier);
    final container = ProviderScope.containerOf(context, listen: false);
    final result = await saveImportedPlaylist(notifier, name, selected);
    final queueError = await _queueImportedTracks(container, selected);
    if (context.mounted) {
      if (queueError != null) {
        _showImportQueueError(context, queueError);
      } else {
        showAppSnackBar(
          context,
          content: Text(
            context.l10n.createPlaylistImportedAddedcountTracksIntoName(
              result.addedCount,
              name,
            ),
          ),
        );
      }
    }
  } catch (e, stack) {
    _log.e('Failed to import playlist link', e, stack);
    if (context.mounted) {
      showAppSnackBar(
        context,
        content: Text(context.l10n.createPlaylistCouldNotImportTheLinkCheck),
      );
    }
  }
}

Future<List<Track>?> _selectImportTracks(
  BuildContext context,
  List<Track> tracks,
  String playlistName,
) {
  final selected = List<bool>.filled(tracks.length, true);
  final collageBackdrop = CoverCollageBackdrop(
    sources: importCoverUrls(tracks),
  );
  return Navigator.of(context).push<List<Track>>(
    MaterialPageRoute(
      builder: (pageContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final colors = Theme.of(context).colorScheme;
          final shownName = importDisplayName(
            playlistName,
            context.l10n.createPlaylistImportedFallbackName,
          );
          final count = selected.where((value) => value).length;
          final media = MediaQuery.of(context);
          return Scaffold(
            body: SafeArea(
              top: false,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Stack(
                      children: [
                        Positioned.fill(child: collageBackdrop),
                        Column(
                          children: [
                            SizedBox(
                              height: collageHeaderHeight(media.size) * 0.9,
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                              child: Column(
                                children: [
                                  Text(
                                    shownName,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    context.l10n
                                        .createPlaylistPlaylistCountOfCount2Selected(
                                          count,
                                          tracks.length,
                                        ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Positioned(
                          top: media.padding.top + 8,
                          left: 8,
                          child: IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.45,
                              ),
                              foregroundColor: Colors.white,
                            ),
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).backButtonTooltip,
                            onPressed: () => Navigator.pop(pageContext),
                            icon: const Icon(Icons.arrow_back),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        Text(
                          context.l10n.createPlaylistChooseTracks,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(pageContext),
                              child: Text(context.l10n.dialogCancel),
                            ),
                            TextButton(
                              onPressed: () => setDialogState(
                                () => selected.fillRange(
                                  0,
                                  selected.length,
                                  true,
                                ),
                              ),
                              child: Text(context.l10n.createPlaylistSelectAll),
                            ),
                            TextButton(
                              onPressed: () => setDialogState(
                                () => selected.fillRange(
                                  0,
                                  selected.length,
                                  false,
                                ),
                              ),
                              child: Text(context.l10n.createPlaylistClearAll),
                            ),
                          ],
                        ),
                        FilledButton.icon(
                          onPressed: selected.contains(true)
                              ? () => Navigator.pop(pageContext, [
                                  for (var i = 0; i < tracks.length; i++)
                                    if (selected[i]) tracks[i],
                                ])
                              : null,
                          icon: const Icon(Icons.file_download_outlined),
                          label: Text(context.l10n.createPlaylistImport),
                        ),
                      ],
                    ),
                  ),
                  SliverList.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) => CheckboxListTile(
                      key: ValueKey('import_track_$index'),
                      secondary: SizedBox(
                        width: 44,
                        height: 44,
                        child:
                            tracks[index].coverUrl == null ||
                                importCoverUrls([tracks[index]]).isEmpty
                            ? DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.music_note,
                                  size: 20,
                                  color: colors.onSurfaceVariant,
                                ),
                              )
                            : ImportCoverImage(
                                url: tracks[index].coverUrl!.trim(),
                                cacheWidth: 132,
                              ),
                      ),
                      value: selected[index],
                      title: Text(tracks[index].name),
                      subtitle: Text(tracks[index].artistName),
                      onChanged: (value) => setDialogState(
                        () => selected[index] = value ?? false,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Creates an imported playlist atomically with its contents.
@visibleForTesting
Future<PlaylistAddBatchResult> saveImportedPlaylist(
  LibraryCollectionsNotifier notifier,
  String name,
  List<Track> tracks,
) => notifier.createImportedPlaylist(name, tracks);

/// Queues each imported song once; the queue checks existing accessible files.
@visibleForTesting
Future<void> queueImportedTracksOnce(
  List<Track> tracks,
  Future<void> Function(Track track) enqueue,
) async {
  final seen = <Track>[];
  String normalized(String value) => value.trim().toLowerCase();
  for (final track in tracks) {
    if (track.source == 'local') continue;
    final isrc = normalized(track.isrc ?? '');
    final duplicate = seen.any((other) {
      final otherIsrc = normalized(other.isrc ?? '');
      if (isrc.isNotEmpty && otherIsrc.isNotEmpty) return isrc == otherIsrc;
      bool hasProviderIdentity(Track value) =>
          value.id.trim().isNotEmpty &&
          !value.id.startsWith('csv_') &&
          !value.id.startsWith('m3u_');
      final hasId = hasProviderIdentity(track);
      final otherHasId = hasProviderIdentity(other);
      if (hasId || otherHasId) {
        return hasId &&
            otherHasId &&
            track.id == other.id &&
            normalized(track.source ?? '') == normalized(other.source ?? '');
      }
      if (normalized(track.albumName) != normalized(other.albumName) ||
          track.duration != other.duration) {
        return false;
      }
      return normalized(track.name).isNotEmpty &&
          normalized(track.artistName).isNotEmpty &&
          normalized(track.name) == normalized(other.name) &&
          normalized(track.artistName) == normalized(other.artistName);
    });
    if (duplicate) continue;
    seen.add(track);
    await enqueue(track);
  }
}

Future<bool?> _queueImportedTracks(
  ProviderContainer container,
  List<Track> tracks,
) async {
  try {
    final settings = container.read(settingsProvider);
    if (!settings.autoDownloadSavedTracks) return null;
    if (tracks.every((track) => track.source == 'local')) return null;
    final service = resolveConfiguredDownloadService(
      settings.defaultService,
      container.read(extensionProvider),
      autoFallback: settings.autoFallback,
    );
    if (service.isEmpty) {
      return true;
    }
    var failed = false;
    await queueImportedTracksOnce(tracks, (track) async {
      try {
        await container
            .read(downloadQueueProvider.notifier)
            .addSavedTrackToQueue(track, service);
      } catch (error, stack) {
        failed = true;
        _log.e('Could not queue imported track', error, stack);
      }
    });
    return failed ? false : null;
  } catch (error, stack) {
    _log.e('Playlist saved but automatic download failed', error, stack);
    return false;
  }
}

void _showImportQueueError(BuildContext context, bool noProvider) {
  showAppSnackBar(
    context,
    content: Text(
      noProvider
          ? noDownloadProviderMessage(
              context.l10n,
              noDownloadProviderCause(
                ProviderScope.containerOf(
                  context,
                  listen: false,
                ).read(extensionProvider),
              ),
            )
          : context.l10n.savedTrackAutoDownloadError,
    ),
  );
}

/// Opens the existing CSV/M3U playlist import flow.
Future<void> importPlaylistFile(
  BuildContext context,
  WidgetRef ref, {
  LibraryDatabase? library,
}) async {
  if (_importInProgress) return;
  _importInProgress = true;
  try {
    await _importPlaylistFile(context, ref, library: library);
  } finally {
    _importInProgress = false;
  }
}

Future<void> _importPlaylistFile(
  BuildContext context,
  WidgetRef ref, {
  LibraryDatabase? library,
}) async {
  final l10n = context.l10n;
  final List<PlaylistImportEntry> entries;
  final String fileName;
  try {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8', 'csv'],
    );
    if (picked == null) return;
    fileName = picked.name;
    entries = await parsePlaylistImportFile(
      await picked.readAsBytes(),
      fileName,
    );
  } catch (e) {
    _log.e('Failed to read playlist file: $e');
    if (context.mounted) {
      showAppSnackBar(context, content: Text(l10n.playlistImportFailed));
    }
    return;
  }
  if (!context.mounted) return;
  if (entries.isEmpty) {
    showAppSnackBar(context, content: Text(l10n.playlistImportNoTracks));
    return;
  }
  try {
    final match = await matchPlaylistImport(
      entries,
      library ?? LibraryDatabase.instance,
    );
    if (!context.mounted) return;
    final selected = await _selectImportTracks(
      context,
      match.tracks,
      p.basenameWithoutExtension(fileName),
    );
    if (selected == null || selected.isEmpty || !context.mounted) return;
    final name = await _promptName(
      context,
      p.basenameWithoutExtension(fileName),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    final notifier = ref.read(libraryCollectionsProvider.notifier);
    final container = ProviderScope.containerOf(context, listen: false);
    final result = await saveImportedPlaylist(notifier, name, selected);
    final queueError = await _queueImportedTracks(container, selected);
    if (context.mounted) {
      if (queueError != null) {
        _showImportQueueError(context, queueError);
      } else {
        showAppSnackBar(
          context,
          content: Text(
            l10n.playlistImportResult(
              result.addedCount,
              name,
              selected.where((track) => track.source == 'local').length,
            ),
          ),
        );
      }
    }
  } catch (e, stack) {
    _log.e('Failed to import playlist', e, stack);
    if (context.mounted) {
      showAppSnackBar(context, content: Text(l10n.playlistImportFailed));
    }
  }
}

class _FolderList extends StatelessWidget {
  const _FolderList({required this.folders, required this.controller});

  final Future<List<LibraryFolder>> folders;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<LibraryFolder>>(
      future: folders,
      builder: (context, snapshot) {
        final folders = snapshot.hasError
            ? const <LibraryFolder>[]
            : snapshot.data;
        if (folders == null) {
          // Skeleton rows in the geometry of the folder rows below.
          return SingleChildScrollView(
            controller: controller,
            child: ShimmerLoading(
              child: Column(
                children: [
                  for (var i = 0; i < 4; i++)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      child: Row(
                        spacing: 16,
                        children: [
                          SkeletonBox(width: 24, height: 24, borderRadius: 6),
                          Expanded(
                            child: Column(
                              spacing: 6,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SkeletonBox(width: 160, height: 14),
                                SkeletonBox(width: 220, height: 12),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        if (folders.isEmpty) {
          return SingleChildScrollView(
            controller: controller,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: EmptyState(
                icon: Icons.folder_outlined,
                title: context.l10n.playlistFolderPickerEmptyTitle,
                message: context.l10n.playlistFolderPickerEmpty,
              ),
            ),
          );
        }
        return ListView.builder(
          controller: controller,
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final folder = folders[index];
            final count = context.l10n.tracksCount(folder.ids.length);
            return AppSheetOption(
              leading: const AppIcon(Icons.folder_outlined),
              title: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                folder.path.isEmpty ? count : '$count · ${folder.path}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, folder),
            );
          },
        );
      },
    );
  }
}
