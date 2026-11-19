import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/download_history.dart';
import '../../models/track.dart';
import '../../models/unified_library_item.dart';
import '../../providers/settings_provider.dart';
import '../../services/library_database.dart';
import '../../services/platform_bridge.dart';
import '../../services/playable_media.dart';
import '../../services/jam/jam_app_controller.dart';
import '../../services/jam/jam_track_reference.dart';
import 'jam_app_view.dart';

/// Opt-in connection between Jam and the listener's library.
class JamLibraryAppView extends StatelessWidget {
  const JamLibraryAppView({super.key, required this.controller});

  final JamAppController controller;

  @override
  Widget build(BuildContext context) => JamAppView(
    controller: controller,
    trackTitle: (id) {
      if (id.startsWith('jamhost1:')) return context.l10n.jamHostQueueSong;
      final ref = JamTrackReference.tryDecode(id);
      return ref == null
          ? context.l10n.jamSongUnavailable
          : '${ref.title} — ${ref.artist}';
    },
    selectHostMedia: (context) => showDialog<PlayableMedia>(
      context: context,
      builder: (_) => const JamLibraryTrackDialog(isHost: true),
    ),
    selectTrack: (context) => showDialog<String>(
      context: context,
      builder: (_) => JamLibraryTrackDialog(isHost: false),
    ),
  );
}

final jamLibraryPageLoaderProvider =
    Provider<Future<QueueLibraryDbPage> Function(QueueLibraryDbQuery)>(
      (ref) =>
          (query) => LibraryDatabase.instance.getQueueTrackPageResult(query),
    );

final jamCatalogSearchProvider = Provider<Future<List<Track>> Function(String)>(
  (ref) {
    return (query) async {
      final rows = await PlatformBridge.searchTracksWithMetadataProviders(
        query,
        limit: 20,
        includeExtensions: ref.read(settingsProvider).useExtensionProviders,
      );
      return rows.map((row) => Track.fromBackendMap(row)).toList();
    };
  },
);

final jamSafReadProbeProvider = Provider<Future<bool> Function(String)>(
  (ref) => PlatformBridge.safCanOpenRead,
);
final _jamSafReadProvider = FutureProvider.autoDispose.family<bool, String>((
  ref,
  path,
) async {
  try {
    return await ref.watch(jamSafReadProbeProvider)(path);
  } catch (_) {
    return false;
  }
});

final _jamLibraryPageProvider = FutureProvider.autoDispose
    .family<QueueLibraryDbPage, (String, int)>(
      (ref, request) => ref.watch(jamLibraryPageLoaderProvider)(
        QueueLibraryDbQuery(
          includeSingleTrackAlbums: true,
          searchQuery: request.$1,
          limit: 100,
          offset: request.$2,
          includeLocal: ref.watch(
            settingsProvider.select((s) => s.localLibraryEnabled),
          ),
        ),
      ),
    );

/// Selects a library reference without starting playback or downloads.
class JamLibraryTrackDialog extends ConsumerStatefulWidget {
  const JamLibraryTrackDialog({super.key, this.isHost = false});

  final bool isHost;

  @override
  ConsumerState<JamLibraryTrackDialog> createState() =>
      _JamLibraryTrackDialogState();
}

class _JamLibraryTrackDialogState extends ConsumerState<JamLibraryTrackDialog> {
  String _query = '';
  int _offset = 0;
  bool _catalog = false;
  Timer? _debounce;
  int _request = 0;
  bool _loading = false;
  bool _error = false;
  List<Track> _results = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _request++;
    super.dispose();
  }

  void _search(String value) {
    final query = value.trim();
    _debounce?.cancel();
    final request = ++_request;
    setState(() {
      _query = query;
      _offset = 0;
      _results = [];
      _error = false;
      _loading = _catalog && query.isNotEmpty;
    });
    if (!_catalog || query.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final results = await ref
            .read(jamCatalogSearchProvider)(query)
            .timeout(const Duration(seconds: 10));
        if (!mounted || request != _request) return;
        setState(() {
          _results = results;
          _loading = false;
        });
      } catch (_) {
        if (!mounted || request != _request) return;
        setState(() {
          _error = true;
          _loading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _catalog
        ? null
        : ref.watch(_jamLibraryPageProvider((_query, _offset)));
    return AlertDialog(
      title: Text(context.l10n.jamAddSong),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.isHost) ...[
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(context.l10n.jamLibrary),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(context.l10n.jamCatalog),
                  ),
                ],
                selected: {_catalog},
                onSelectionChanged: (value) {
                  setState(() => _catalog = value.first);
                  _search(_query);
                },
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: _catalog
                    ? context.l10n.jamSearchCatalog
                    : context.l10n.jamSearchLibrary,
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _catalog
                  ? _buildCatalog()
                  : tracks!.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (_, _) => Center(
                        child: Text(context.l10n.jamLibraryLoadFailed),
                      ),
                      data: (page) => _buildTracks(page),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.dialogCancel),
        ),
      ],
    );
  }

  Widget _buildCatalog() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.jamCatalogSearchFailed),
            TextButton(
              onPressed: () => _search(_query),
              child: Text(context.l10n.dialogRetry),
            ),
          ],
        ),
      );
    }
    if (_results.isEmpty)
      return Center(
        child: Text(
          _query.isEmpty
              ? context.l10n.jamSearchForSong
              : context.l10n.jamNoResults,
        ),
      );
    return Column(
      children: [
        Text(context.l10n.jamIsrcOnly),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final track = _results[index];
              final candidate = JamTrackReference.fromTrack(track);
              final reference = candidate?.isrc == null ? null : candidate;
              return ListTile(
                title: Text(track.name),
                subtitle: Text(
                  reference == null
                      ? context.l10n.jamArtistNoIsrc(track.artistName)
                      : track.artistName,
                ),
                enabled: reference != null,
                onTap: reference == null
                    ? null
                    : () => Navigator.pop(context, reference.encode()),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTracks(QueueLibraryDbPage page) {
    final items = <UnifiedLibraryItem>[];
    for (final row in page.rows) {
      final data = Map<String, dynamic>.from(row['item'] as Map);
      if (row['source'] == 'local') {
        items.add(
          UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(data)),
        );
      } else if (row['source'] == 'downloaded') {
        items.add(
          UnifiedLibraryItem.fromDownloadHistory(
            DownloadHistoryItem.fromJson(data),
          ),
        );
      }
    }
    if (items.isEmpty && _offset == 0) {
      return Center(
        child: Text(
          _query.isEmpty
              ? context.l10n.jamLibraryEmpty
              : context.l10n.jamNoResults,
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final track = item.toTrack();
              final candidate = JamTrackReference.fromTrack(track);
              // The current host resolver only resolves verified library ISRCs.
              final reference = candidate?.isrc == null ? null : candidate;
              final checkSaf =
                  widget.isHost &&
                  Uri.tryParse(item.filePath)?.scheme.toLowerCase() ==
                      'content';
              final availability = checkSaf
                  ? ref.watch(_jamSafReadProvider(item.filePath))
                  : null;
              final selectable = widget.isHost
                  ? item.filePath.trim().isNotEmpty
                  : reference != null;
              final checking = availability?.isLoading ?? false;
              final unavailable = checkSaf && (availability?.value != true);
              return ListTile(
                title: Text(
                  track.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  !selectable
                      ? context.l10n.jamArtistNotShareable(track.artistName)
                      : checking
                      ? context.l10n.jamArtistChecking(track.artistName)
                      : unavailable
                      ? context.l10n.jamArtistUnavailableToHost(
                          track.artistName,
                        )
                      : track.artistName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                enabled: selectable && !unavailable,
                onTap: !selectable || unavailable
                    ? null
                    : () => Navigator.pop(
                        context,
                        widget.isHost
                            ? item.historyItem != null
                                  ? playableFromHistory(item.historyItem!)
                                  : playableFromLocal(item.localItem!)
                            : reference!.encode(),
                      ),
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _offset == 0
                  ? null
                  : () => setState(() => _offset -= 100),
              child: Text(context.l10n.jamPrevious),
            ),
            TextButton(
              onPressed: page.rows.length < 100
                  ? null
                  : () => setState(() => _offset += 100),
              child: Text(context.l10n.jamNext),
            ),
          ],
        ),
      ],
    );
  }
}
