import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

final _log = AppLogger('AddToMusicSheet');

/// Destino fijo de la biblioteca general dentro de la hoja.
const addToMusicLibraryTarget = 'library';

/// Navegador donde ya hay una hoja abierta: evita apilar dos por un doble
/// toque en el "+". Atada al navegador, no a un booleano global.
NavigatorState? _openIn;

/// El "+" de cualquier cancion: una hoja baja (maximo 60 % de la pantalla)
/// con la biblioteca y las playlists del usuario. Cada fila tocada se
/// ilumina para ver a donde ira la cancion; las que ya la contienen salen
/// marcadas y deseleccionarlas la quita.
Future<void> showAddToMusicSheet(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  if (!context.mounted) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  if (_openIn == navigator && navigator.mounted) return;
  _openIn = navigator;
  try {
    // Para marcar de inicio lo que ya esta en la biblioteca.
    if (ref.read(savedLibraryTracksProvider).isLoading) {
      try {
        await ref.read(savedLibraryTracksProvider.future);
      } catch (_) {
        // Se abre igual: la fila de la biblioteca saldra sin marcar.
      }
      if (!context.mounted) return;
    }
    await showAppBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      maxHeightFactor: 0.6,
      title: context.l10n.addToMusicTitle,
      subtitle: '${track.name} • ${track.artistName}',
      builder: (_) => _AddToMusicBody(track: track),
    );
  } finally {
    if (_openIn == navigator) _openIn = null;
  }
}

class _AddToMusicBody extends ConsumerStatefulWidget {
  const _AddToMusicBody({required this.track});

  final Track track;

  @override
  ConsumerState<_AddToMusicBody> createState() => _AddToMusicBodyState();
}

class _AddToMusicBodyState extends ConsumerState<_AddToMusicBody> {
  late final String _key = trackCollectionKey(widget.track);
  late final Set<String> _initial;
  late final Set<String> _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _initial = {
      if (ref.read(librarySongKeysProvider).contains(_key))
        addToMusicLibraryTarget,
      for (final playlist in ref.read(libraryCollectionsProvider).playlists)
        if (playlist.containsTrackKey(_key)) playlist.id,
    };
    _selected = {..._initial};
  }

  Set<String> get _toAdd => _selected.difference(_initial);
  Set<String> get _toRemove => _initial.difference(_selected);
  int get _changes => _toAdd.length + _toRemove.length;

  void _toggle(String id) {
    if (_busy) return;
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  Future<void> _createPlaylist() async {
    if (_busy) return;
    final before = {
      for (final p in ref.read(libraryCollectionsProvider).playlists) p.id,
    };
    await showCreatePlaylistSheet(context, ref);
    if (!mounted) return;
    // Lo recien creado queda seleccionado para esta cancion.
    final created = [
      for (final p in ref.read(libraryCollectionsProvider).playlists)
        if (!before.contains(p.id)) p.id,
    ];
    if (created.isNotEmpty) setState(() => _selected.addAll(created));
  }

  Future<void> _apply() async {
    if (_busy || _changes == 0) return;
    setState(() => _busy = true);
    final track = widget.track;
    final container = ProviderScope.containerOf(context, listen: false);
    final collections = ref.read(libraryCollectionsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final root = Navigator.of(context, rootNavigator: true).context;
    final libraryAdd = _toAdd.contains(addToMusicLibraryTarget);
    final libraryRemove = _toRemove.contains(addToMusicLibraryTarget);
    final added = _toAdd.length;
    var failed = false;
    try {
      for (final id in _toAdd.where((id) => id != addToMusicLibraryTarget)) {
        await collections.addTrackToPlaylist(id, track);
        failed |=
            !(container
                    .read(libraryCollectionsProvider)
                    .playlistById(id)
                    ?.containsTrackKey(_key) ??
                false);
      }
      for (final id in _toRemove.where((id) => id != addToMusicLibraryTarget)) {
        await collections.removeTracksFromPlaylist(id, [_key]);
      }
    } catch (error, stack) {
      _log.e('No se pudo actualizar el destino de ${track.id}', error, stack);
      failed = true;
    }
    // La biblioteca puede tardar (prepara el audio): la hoja ya no espera.
    if (mounted) Navigator.of(context).pop();
    try {
      if (libraryAdd || libraryRemove) {
        // ignore: use_build_context_synchronously
        await toggleSavedLibraryTrackIn(root, container, track, libraryRemove);
        final inLibrary = container
            .read(libraryMembershipProvider)
            .isInLibrary(track);
        failed |= libraryAdd ? !inLibrary : inLibrary;
      }
    } catch (error, stack) {
      _log.e('No se pudo actualizar la biblioteca', error, stack);
      failed = true;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed
              ? l10n.addToMusicError
              : added > 0
              ? l10n.addToMusicSaved(added)
              : l10n.addToMusicTitle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final playlists = ref.watch(
      libraryCollectionsProvider.select((state) => state.playlists),
    );
    final hasRemovals = _toRemove.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              _TargetRow(
                key: const ValueKey('add-to-music-library'),
                icon: Icons.library_music_outlined,
                title: l10n.addToMusicLibrary,
                subtitle: _subtitleFor(
                  addToMusicLibraryTarget,
                  l10n.addToMusicLibrarySubtitle,
                ),
                selected: _selected.contains(addToMusicLibraryTarget),
                enabled: !_busy,
                onTap: () => _toggle(addToMusicLibraryTarget),
              ),
              for (final playlist in playlists)
                _TargetRow(
                  key: ValueKey('add-to-music-playlist-${playlist.id}'),
                  icon: Icons.queue_music,
                  title: playlist.name,
                  subtitle: _subtitleFor(
                    playlist.id,
                    l10n.collectionPlaylistTracks(playlist.trackCount),
                  ),
                  selected: _selected.contains(playlist.id),
                  enabled: !_busy,
                  onTap: () => _toggle(playlist.id),
                ),
              ListTile(
                key: const ValueKey('add-to-music-new-playlist'),
                leading: Icon(
                  Icons.add_circle_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(l10n.collectionCreatePlaylist),
                enabled: !_busy,
                onTap: _createPlaylist,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('add-to-music-cancel'),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.dialogCancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('add-to-music-confirm'),
                  onPressed: _busy || _changes == 0 ? null : _apply,
                  child: Text(
                    hasRemovals
                        ? l10n.addToMusicConfirmApply(_changes)
                        : l10n.addToMusicConfirmAdd(_changes),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Dice que pasara con la fila: se agregara, se quitara o ya esta dentro.
  String _subtitleFor(String id, String fallback) {
    final l10n = context.l10n;
    if (_toAdd.contains(id)) return l10n.addToMusicWillAdd;
    if (_toRemove.contains(id)) return l10n.addToMusicWillRemove;
    if (_initial.contains(id)) return l10n.addToMusicAlreadyIn;
    return fallback;
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: ListTile(
        selected: selected,
        selectedTileColor: colors.primary.withValues(alpha: 0.16),
        selectedColor: colors.primary,
        enabled: enabled,
        leading: Icon(icon),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Icon(
          selected ? Icons.check_circle : Icons.radio_button_unchecked,
          color: selected ? colors.primary : colors.onSurfaceVariant,
        ),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
