import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/utils/provider_resource_ids.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

class ArtistsSheetArtist {
  const ArtistsSheetArtist({
    required this.name,
    this.id,
    this.extensionId,
    this.imageUrl,
  });

  final String name;
  final String? id;
  final String? extensionId;
  final String? imageUrl;
}

List<ArtistsSheetArtist> artistsSheetArtistsFrom(
  String artistNames,
  String? artistIds, {
  String? extensionId,
  String? imageUrl,
}) {
  final targets = buildArtistTapTargets(artistNames, artistIds);
  return [
    for (final target in targets)
      ArtistsSheetArtist(
        name: target.name,
        id: target.artistId,
        extensionId: target.artistId == null && targets.length > 1
            ? null
            : extensionId,
        imageUrl: targets.length == 1 ? imageUrl : null,
      ),
  ];
}

class ArtistsSheetAlbum {
  const ArtistsSheetAlbum({
    required this.name,
    this.id,
    this.artistName,
    this.coverUrl,
    this.extensionId,
    this.type,
    this.onAdd,
  });

  factory ArtistsSheetAlbum.fromTrack(Track track, {VoidCallback? onAdd}) =>
      ArtistsSheetAlbum(
        name: track.albumName,
        id: track.albumId,
        artistName: track.albumArtist ?? track.artistName,
        coverUrl: track.coverUrl,
        extensionId: track.source,
        type: track.albumType,
        onAdd: onAdd,
      );

  final String name;
  final String? id;
  final String? artistName;
  final String? coverUrl;
  final String? extensionId;
  final String? type;
  final VoidCallback? onAdd;
}

class _SheetChoice {
  const _SheetChoice.artist(this.artist, this.imageUrl) : album = false;
  const _SheetChoice.album() : artist = null, imageUrl = null, album = true;

  final ArtistsSheetArtist? artist;
  final String? imageUrl;
  final bool album;
}

bool _isCurrentArtist(
  ArtistsSheetArtist artist,
  String? currentName,
  String? currentId,
) {
  final id = artist.id?.trim();
  final other = currentId?.trim();
  if (id != null && id.isNotEmpty && other != null && other.isNotEmpty) {
    return stripPrefixedResourceId(id) == stripPrefixedResourceId(other);
  }
  final name = currentName?.trim().toLowerCase();
  return name != null &&
      name.isNotEmpty &&
      artist.name.trim().toLowerCase() == name;
}

/// Opens a compact bottom sheet with every artist in [artistas] and, below,
/// the [album] they belong to. Choosing an artist or the album navigates to
/// its page. Nothing opens when the only artist is the one whose page the
/// caller is already on ([currentArtistName] or [currentArtistId]).
Future<void> showArtistsSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<ArtistsSheetArtist> artistas,
  ArtistsSheetAlbum? album,
  String? currentArtistName,
  String? currentArtistId,
}) async {
  if (artistas.isEmpty) return;
  if (artistas.length == 1 &&
      _isCurrentArtist(artistas.first, currentArtistName, currentArtistId)) {
    return;
  }
  final collections = ref.read(libraryCollectionsProvider.notifier);
  final choice = await showAppBottomSheet<_SheetChoice>(
    context: context,
    useRootNavigator: true,
    maxHeightFactor: 0.7,
    builder: (sheetContext) => ArtistsSheetContent(
      artistas: artistas,
      album: album,
      collections: collections,
      onChoose: (value) => Navigator.pop(sheetContext, value),
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice.album) {
    if (album == null) return;
    await navigateToAlbum(
      context,
      albumName: album.name,
      albumId: album.id,
      artistName: album.artistName,
      coverUrl: album.coverUrl,
      extensionId: album.extensionId,
    );
    return;
  }
  final artist = choice.artist;
  if (artist == null) return;
  await navigateToArtist(
    context,
    artistName: artist.name,
    artistId: artist.id,
    coverUrl: choice.imageUrl ?? artist.imageUrl,
    extensionId: artist.extensionId,
  );
}

class ArtistsSheetContent extends StatelessWidget {
  const ArtistsSheetContent({
    super.key,
    required this.artistas,
    required this.collections,
    required this.onChoose,
    this.album,
  });

  final List<ArtistsSheetArtist> artistas;
  final ArtistsSheetAlbum? album;
  final LibraryCollectionsNotifier collections;
  final ValueChanged<Object> onChoose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final artist in artistas)
            _ArtistRow(
              key: ValueKey('artists-sheet-artist-${artist.name}'),
              artist: artist,
              collections: collections,
              onOpen: (imageUrl) =>
                  onChoose(_SheetChoice.artist(artist, imageUrl)),
            ),
          if (album != null && album!.name.trim().isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            _AlbumRow(
              album: album!,
              onOpen: () => onChoose(const _SheetChoice.album()),
            ),
          ],
        ],
      ),
    );
  }
}

class _ArtistRow extends StatefulWidget {
  const _ArtistRow({
    super.key,
    required this.artist,
    required this.collections,
    required this.onOpen,
  });

  final ArtistsSheetArtist artist;
  final LibraryCollectionsNotifier collections;
  final ValueChanged<String?> onOpen;

  @override
  State<_ArtistRow> createState() => _ArtistRowState();
}

typedef _ArtistIdentity = ({String id, String? providerId});

class _ArtistRowState extends State<_ArtistRow> {
  Future<ArtistProfile?>? _profile;
  _ArtistIdentity? _identity;
  var _started = false;
  var _lookingUp = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final artist = widget.artist;
    final known = _knownIdentity(artist);
    if (known != null) _identity = known;
    if (known == null || artist.imageUrl == null) {
      _lookingUp = known == null;
      _profile = lookupArtistProfile(
        context,
        artist.name,
        extensionId: artist.extensionId,
      );
      _profile!.then((profile) {
        if (!mounted) return;
        setState(() {
          _lookingUp = false;
          if (profile == null || _identity != null) return;
          _identity = (
            id: stripPrefixedResourceId(profile.id),
            providerId: profile.providerId,
          );
        });
      });
    }
  }

  static _ArtistIdentity? _knownIdentity(ArtistsSheetArtist artist) {
    final id = artist.id?.trim();
    if (id == null || id.isEmpty) return null;
    final provider = artist.extensionId?.trim().isNotEmpty == true
        ? artist.extensionId
        : legacyProviderIdFromResourceId(id);
    if (provider == null || provider.isEmpty) return null;
    return (id: stripPrefixedResourceId(id), providerId: provider);
  }

  Future<void> _toggle(String? imageUrl) async {
    var identity = _identity;
    if (identity == null) {
      if (mounted) setState(() => _lookingUp = true);
      final profile = await _profile;
      if (!mounted) return;
      setState(() => _lookingUp = false);
      if (profile == null) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.artistFollowNotFound),
        );
        return;
      }
      identity = (
        id: stripPrefixedResourceId(profile.id),
        providerId: profile.providerId,
      );
      if (mounted) setState(() => _identity = identity);
    }
    await widget.collections.toggleFavoriteArtist(
      artistId: identity.id,
      providerId: identity.providerId,
      name: widget.artist.name,
      imageUrl: imageUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final artist = widget.artist;
    return FutureBuilder<ArtistProfile?>(
      future: _profile,
      builder: (context, snapshot) {
        final imageUrl = artist.imageUrl ?? snapshot.data?.imageUrl;
        return InkWell(
          onTap: () => widget.onOpen(imageUrl),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                _ArtistAvatar(imageUrl: imageUrl),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        artist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        l10n.recentTypeArtist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _FollowChip(
                  identity: _identity,
                  busy: _lookingUp,
                  onPressed: () => _toggle(imageUrl),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FollowChip extends ConsumerWidget {
  const _FollowChip({
    required this.identity,
    required this.onPressed,
    this.busy = false,
  });

  final _ArtistIdentity? identity;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final id = identity;
    final following = id == null
        ? false
        : ref.watch(
            libraryCollectionsProvider.select(
              (state) => state.isFavoriteArtist(
                artistId: id.id,
                providerId: id.providerId,
              ),
            ),
          );
    final label = following
        ? context.l10n.artistFollowing
        : context.l10n.artistFollow;
    return Semantics(
      button: true,
      toggled: following,
      excludeSemantics: true,
      label: label,
      onTap: onPressed,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const StadiumBorder(),
          foregroundColor: scheme.onSurface,
          side: BorderSide(
            color: following
                ? scheme.primary
                : scheme.outline.withValues(alpha: 0.7),
          ),
        ),
        child: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                label,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

class _ArtistAvatar extends StatelessWidget {
  const _ArtistAvatar({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.person, color: scheme.onSurfaceVariant),
    );
    final url = imageUrl?.trim();
    return ClipOval(
      child: SizedBox.square(
        dimension: 52,
        child: url == null || url.isEmpty
            ? placeholder
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 156,
                fadeInDuration: const Duration(milliseconds: 150),
                placeholder: (_, _) => placeholder,
                errorWidget: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

class _AlbumRow extends StatelessWidget {
  const _AlbumRow({required this.album, required this.onOpen});

  final ArtistsSheetAlbum album;
  final VoidCallback onOpen;

  String _typeLabel(BuildContext context) {
    final l10n = context.l10n;
    return switch (album.type?.trim().toLowerCase()) {
      'single' => l10n.releaseTypeSingle,
      'ep' => l10n.releaseTypeEp,
      _ => l10n.recentTypeAlbum,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.album, color: scheme.onSurfaceVariant),
    );
    final cover = album.coverUrl?.trim();
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox.square(
                dimension: 52,
                child: cover == null || cover.isEmpty
                    ? placeholder
                    : CachedNetworkImage(
                        imageUrl: cover,
                        fit: BoxFit.cover,
                        memCacheWidth: 156,
                        placeholder: (_, _) => placeholder,
                        errorWidget: (_, _, _) => placeholder,
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    album.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _typeLabel(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (album.onAdd != null)
              IconButton(
                onPressed: album.onAdd,
                tooltip: context.l10n.tooltipAddToPlaylist,
                icon: const Icon(Icons.add_rounded),
              ),
          ],
        ),
      ),
    );
  }
}
