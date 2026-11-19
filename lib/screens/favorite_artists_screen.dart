import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_home.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/screens/weekly_releases_screen.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

class FavoriteArtistsScreen extends ConsumerStatefulWidget {
  const FavoriteArtistsScreen({super.key});

  @override
  ConsumerState<FavoriteArtistsScreen> createState() =>
      _FavoriteArtistsScreenState();
}

class _FavoriteArtistsScreenState extends ConsumerState<FavoriteArtistsScreen> {
  static const _rowExtent = 64.0;
  static const _searchFrom = 8;

  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(
      libraryCollectionsProvider.select((state) => state.favoriteArtists),
    );
    final sorted = sortArtistsByName(all);
    final folded = foldLibraryText(_query);
    final artists = folded.isEmpty
        ? sorted
        : [
            for (final artist in sorted)
              if (foldLibraryText(artist.name).contains(folded)) artist,
          ];
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = context.navBarBottomInset;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.libraryHomeYourArtists),
          SliverToBoxAdapter(
            child: ListTile(
              leading: const Icon(Icons.new_releases_outlined),
              title: Text(context.l10n.weeklyReleases),
              subtitle: Text(context.l10n.weeklyReleasesDescription),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(slidePageRoute<void>(page: const WeeklyReleasesScreen())),
            ),
          ),
          if (all.length >= _searchFrom)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: AppSearchField(
                  controller: _search,
                  hintText: context.l10n.libraryHomeArtistSearchHint,
                  clearTooltip: context.l10n.dialogClear,
                  samplesBackdrop: false,
                  onChanged: (value) => setState(() => _query = value.trim()),
                  onClear: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
              ),
            ),
          if (all.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.favorite,
                        size: 60,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        context.l10n.collectionFavoriteArtistsEmptyTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.collectionFavoriteArtistsEmptySubtitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
              sliver: SliverFixedExtentList.builder(
                itemExtent: _rowExtent,
                itemCount: artists.length,
                itemBuilder: (context, index) {
                  final artist = artists[index];
                  return ListTile(
                    key: ValueKey('your-artist-${artist.key}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    leading: _ArtistThumbnail(artist: artist),
                    title: Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle:
                        artist.providerId == null || artist.providerId!.isEmpty
                        ? null
                        : Text(
                            artist.providerId!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: AppIconButton(
                      tooltip: context.l10n.artistOptionRemoveFromFavorites,
                      icon: Icon(Icons.favorite, color: colorScheme.error),
                      onPressed: () async {
                        await ref
                            .read(libraryCollectionsProvider.notifier)
                            .removeFavoriteArtist(artist.key);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              context.l10n.collectionRemovedFromFavoriteArtists(
                                artist.name,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        slidePageRoute<void>(
                          page: ArtistScreen(
                            artistId: artist.artistId,
                            artistName: artist.name,
                            coverUrl: artist.imageUrl,
                            extensionId:
                                artist.providerId != null &&
                                    artist.providerId!.isNotEmpty
                                ? artist.providerId
                                : null,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
        ],
      ),
    );
  }
}

class _ArtistThumbnail extends StatelessWidget {
  final CollectionArtistEntry artist;

  const _ArtistThumbnail({required this.artist});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final imageUrl = artist.imageUrl;
    return AppShapeClip(
      kind: AppShapes.artist,
      child: imageUrl != null && imageUrl.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: imageUrl,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              memCacheWidth: 112,
              memCacheHeight: 112,
              cacheManager: CoverCacheManager.instance,
              errorWidget: (_, _, _) => _placeholder(colorScheme),
            )
          : _placeholder(colorScheme),
    );
  }

  Widget _placeholder(ColorScheme colorScheme) {
    return Container(
      width: 56,
      height: 56,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.person, color: colorScheme.onSurfaceVariant),
    );
  }
}
