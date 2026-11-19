import 'package:flutter/material.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/widgets/artist_avatar.dart';

const List<String> _commaNames = [
  'Tyler, The Creator',
  'Earth, Wind & Fire',
  'Crosby, Stills, Nash & Young',
  'Crosby, Stills & Nash',
  'Emerson, Lake & Palmer',
  'Peter, Paul and Mary',
  'Blood, Sweat & Tears',
  'Brooks & Dunn',
  'Hall & Oates',
  'Simon & Garfunkel',
];

final RegExp _conSeparator = RegExp(r'\s+con\s+', caseSensitive: false);
final RegExp _placeholder = RegExp('\u0001(\\d+)\u0001');

/// One name per credited artist. Explicit feature credits keep the rules of
/// [buildArtistTapTargets]; a plain credit such as "A, B" or "A & B" is split,
/// except for well known names that carry a comma or an ampersand themselves.
List<String> splitJourneyArtists(String rawArtists, {String? artistIds}) {
  final raw = rawArtists.trim();
  if (raw.isEmpty) return const [];
  final targets = buildArtistTapTargets(raw, artistIds);
  if (targets.length > 1) return [for (final t in targets) t.name];
  var text = raw;
  final protected = <String>[];
  for (final known in _commaNames) {
    final at = text.toLowerCase().indexOf(known.toLowerCase());
    if (at < 0) continue;
    protected.add(text.substring(at, at + known.length));
    text = text.replaceRange(
      at,
      at + known.length,
      '\u0001${protected.length - 1}\u0001',
    );
  }
  final seen = <String>{};
  final names = <String>[];
  for (final piece in splitArtistNames(
    text,
  ).expand((part) => part.split(_conSeparator))) {
    final name = piece
        .trim()
        .replaceAllMapped(_placeholder, (m) => protected[int.parse(m[1]!)]);
    if (name.isNotEmpty && seen.add(name.toLowerCase())) names.add(name);
  }
  return names.isEmpty ? [raw] : names;
}

/// Artists of the playing track, one row with a round photo per artist.
/// Several credited artists open their own page; with many, the rows fold
/// under a stacked-avatar header.
class JourneyArtistsList extends StatefulWidget {
  const JourneyArtistsList({
    super.key,
    required this.artistNames,
    this.artistIds,
    this.extensionId,
    this.onSingleArtist,
    this.onArtist,
    this.resolver = defaultArtistImageResolver,
    this.imageProviderFactory = defaultArtistImageProvider,
    this.foldAbove = 3,
  });

  final String artistNames;
  final String? artistIds;
  final String? extensionId;
  final VoidCallback? onSingleArtist;
  final ValueChanged<String>? onArtist;
  final ArtistImageResolver resolver;
  final ArtistImageProviderFactory imageProviderFactory;
  final int foldAbove;

  @override
  State<JourneyArtistsList> createState() => _JourneyArtistsListState();
}

class _JourneyArtistsListState extends State<JourneyArtistsList> {
  bool _open = false;

  void _openArtist(String name, int count) {
    if (count == 1 && widget.onSingleArtist != null) {
      widget.onSingleArtist!();
      return;
    }
    final named = widget.onArtist;
    if (named != null) {
      named(name);
      return;
    }
    navigateToArtist(
      context,
      artistName: name,
      extensionId: widget.extensionId,
    );
  }

  Widget _row(String name, int count) => Semantics(
    button: true,
    label: name,
    excludeSemantics: true,
    onTap: () => _openArtist(name, count),
    child: InkWell(
      key: ValueKey('journey-artist-row-$name'),
      onTap: () => _openArtist(name, count),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              ArtistAvatar(
                key: ValueKey('journey-artist-avatar-$name'),
                name: name,
                extensionId: widget.extensionId,
                resolver: widget.resolver,
                imageProviderFactory: widget.imageProviderFactory,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _foldedHeader(List<String> names) {
    const size = 40.0;
    const overlap = 26.0;
    final shown = names.take(4).toList();
    final reduce = MediaQuery.disableAnimationsOf(context);
    final count = context.l10n.journeyArtistsCount(names.length);
    return Semantics(
      button: true,
      expanded: _open,
      label: count,
      excludeSemantics: true,
      onTap: () => setState(() => _open = !_open),
      child: InkWell(
        key: const ValueKey('journey-artists-toggle'),
        onTap: () => setState(() => _open = !_open),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: size + overlap * (shown.length - 1),
                  height: size,
                  child: Stack(
                    children: [
                      for (var i = shown.length - 1; i >= 0; i--)
                        PositionedDirectional(
                          start: i * overlap,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF1E1E23),
                                width: 2,
                              ),
                            ),
                            child: ArtistAvatar(
                              name: shown[i],
                              size: size - 4,
                              extensionId: widget.extensionId,
                              resolver: widget.resolver,
                              imageProviderFactory:
                                  widget.imageProviderFactory,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        count,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        names.join(', '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? .5 : 0,
                  duration: reduce
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  child: const Icon(Icons.expand_more),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final names = splitJourneyArtists(
      widget.artistNames,
      artistIds: widget.artistIds,
    );
    if (names.isEmpty) return const SizedBox.shrink();
    final folded = names.length > widget.foldAbove;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final rows = Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final name in names) _row(name, names.length)],
    );
    if (!folded) return rows;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _foldedHeader(names),
        AnimatedSize(
          duration: reduce ? Duration.zero : const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: _open ? rows : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
