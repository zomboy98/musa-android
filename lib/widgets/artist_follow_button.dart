import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';

class ArtistFollowButton extends ConsumerWidget {
  const ArtistFollowButton({
    super.key,
    required this.artistId,
    required this.providerId,
    required this.name,
    this.imageUrl,
    this.onChanged,
  });

  final String artistId;
  final String? providerId;
  final String name;
  final String? imageUrl;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final following = ref.watch(
      libraryCollectionsProvider.select(
        (state) =>
            state.isFavoriteArtist(artistId: artistId, providerId: providerId),
      ),
    );
    final label = following
        ? context.l10n.artistFollowing
        : context.l10n.artistFollow;
    final foreground = following ? colorScheme.primary : colorScheme.onPrimary;
    return Semantics(
      button: true,
      toggled: following,
      label: label,
      excludeSemantics: true,
      onTap: () => _toggle(ref),
      child: Material(
        color: following
            ? Colors.white.withValues(alpha: 0.10)
            : colorScheme.primary,
        shape: StadiumBorder(
          side: following
              ? BorderSide(color: colorScheme.primary, width: 1.5)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _toggle(ref),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 50, minWidth: 120),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 8,
                children: [
                  Icon(
                    following ? CupertinoIcons.checkmark : CupertinoIcons.plus,
                    size: 20,
                    color: foreground,
                  ),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(WidgetRef ref) async {
    final added = await ref
        .read(libraryCollectionsProvider.notifier)
        .toggleFavoriteArtist(
          artistId: artistId,
          providerId: providerId,
          name: name,
          imageUrl: imageUrl,
        );
    onChanged?.call(added);
  }
}
