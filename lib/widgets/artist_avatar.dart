import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/services/cover_cache_manager.dart';

typedef ArtistImageResolver =
    Future<String?> Function(
      BuildContext context,
      String artistName,
      String? extensionId,
    );

typedef ArtistImageProviderFactory =
    ImageProvider Function(String url, int cachePixels);

Future<String?> defaultArtistImageResolver(
  BuildContext context,
  String artistName,
  String? extensionId,
) => lookupArtistImageUrl(context, artistName, extensionId: extensionId);

ImageProvider defaultArtistImageProvider(String url, int cachePixels) =>
    ResizeImage.resizeIfNeeded(
      cachePixels,
      cachePixels,
      CachedNetworkImageProvider(url, cacheManager: CoverCacheManager.instance),
    );

String artistInitials(String name) {
  final words = name
      .split(RegExp(r'\s+'))
      .where((word) => word.runes.any(_isLetterOrDigit))
      .toList();
  if (words.isEmpty) return '';
  String first(String word) => String.fromCharCode(
    word.runes.firstWhere(_isLetterOrDigit, orElse: () => word.runes.first),
  );
  if (words.length == 1) return first(words.first).toUpperCase();
  return (first(words.first) + first(words[1])).toUpperCase();
}

bool _isLetterOrDigit(int rune) {
  final char = String.fromCharCode(rune);
  return char.toLowerCase() != char.toUpperCase() ||
      RegExp(r'[0-9]').hasMatch(char);
}

/// Round artist photo. The initials stand in while the photo is looked up and
/// whenever there is none or it fails to load; nothing here can throw into
/// the tree and nothing spins.
class ArtistAvatar extends StatefulWidget {
  const ArtistAvatar({
    super.key,
    required this.name,
    this.size = 48,
    this.extensionId,
    this.imageUrl,
    this.resolver = defaultArtistImageResolver,
    this.imageProviderFactory = defaultArtistImageProvider,
  });

  final String name;
  final double size;
  final String? extensionId;
  final String? imageUrl;
  final ArtistImageResolver resolver;
  final ArtistImageProviderFactory imageProviderFactory;

  @override
  State<ArtistAvatar> createState() => _ArtistAvatarState();
}

class _ArtistAvatarState extends State<ArtistAvatar> {
  String? _url;
  String _requestedFor = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _url = widget.imageUrl;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant ArtistAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name ||
        oldWidget.extensionId != widget.extensionId) {
      _url = widget.imageUrl;
      _requestedFor = '';
      _resolve();
    }
  }

  void _resolve() {
    final known = widget.imageUrl?.trim() ?? '';
    final key = '${widget.extensionId ?? ''}|${widget.name}';
    if (known.isNotEmpty || _requestedFor == key || widget.name.trim().isEmpty) {
      return;
    }
    _requestedFor = key;
    final generation = ++_generation;
    Future<String?> lookup;
    try {
      lookup = widget.resolver(context, widget.name, widget.extensionId);
    } catch (_) {
      return;
    }
    lookup.then<void>(
      (url) {
        final clean = url?.trim() ?? '';
        if (mounted && generation == _generation && clean.isNotEmpty) {
          setState(() => _url = clean);
        }
      },
      onError: (Object _) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    final initials = artistInitials(widget.name);
    final fallback = Container(
      key: const ValueKey('artist-avatar-initials'),
      width: size,
      height: size,
      alignment: Alignment.center,
      color: scheme.secondaryContainer,
      child: initials.isEmpty
          ? Icon(
              Icons.person_outline,
              size: size * .5,
              color: scheme.onSecondaryContainer,
            )
          : Text(
              initials,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: size * .36,
                fontWeight: FontWeight.w600,
                color: scheme.onSecondaryContainer,
              ),
            ),
    );
    final url = _url?.trim() ?? '';
    Widget photo = fallback;
    if (url.isNotEmpty) {
      final pixels = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
      photo = Image(
        key: const ValueKey('artist-avatar-photo'),
        image: widget.imageProviderFactory(url, pixels),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, sync) =>
            sync || frame != null ? child : fallback,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: ClipOval(child: photo),
      ),
    );
  }
}
