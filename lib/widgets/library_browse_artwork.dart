import 'package:flutter/material.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';

/// Cover of a browsed album or artist: the scanned or embedded artwork, or a
/// plain placeholder while none is known.
class LibraryBrowseArtwork extends StatefulWidget {
  const LibraryBrowseArtwork({
    super.key,
    required this.entry,
    this.placeholderIcon = Icons.album_outlined,
    this.placeholderSize = 40,
  });

  final LibraryBrowseEntry entry;
  final IconData placeholderIcon;
  final double placeholderSize;

  @override
  State<LibraryBrowseArtwork> createState() => _LibraryBrowseArtworkState();
}

class _LibraryBrowseArtworkState extends State<LibraryBrowseArtwork> {
  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    Widget fallback(BuildContext context) => ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          widget.placeholderIcon,
          size: widget.placeholderSize,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (entry.source == 'local') {
      return LocalLibraryArtworkBuilder(
        coverPath: entry.cover,
        filePath: entry.samplePath,
        builder: (context, cover) => cover == null
            ? fallback(context)
            : LocalOrNetworkCoverImage(
                url: cover,
                complete: true,
                placeholder: fallback,
              ),
      );
    }
    final embedded = entry.cover?.isNotEmpty == true
        ? null
        : DownloadedEmbeddedCoverResolver.resolve(
            entry.samplePath,
            onChanged: () {
              if (mounted) setState(() {});
            },
          );
    final cover = entry.cover?.isNotEmpty == true ? entry.cover! : embedded;
    return cover == null
        ? fallback(context)
        : LocalOrNetworkCoverImage(
            url: cover,
            complete: true,
            placeholder: fallback,
          );
  }
}
