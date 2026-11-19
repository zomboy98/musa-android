import 'package:flutter/material.dart';
import 'package:mornye/models/library_home.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/library_home_strings.dart';

const libraryHomeChipsHeight = 56.0;

/// Horizontal filter chips. Choosing one shows only that kind and adds a
/// leading "x" chip that returns to everything.
class LibraryFilterChipsBar extends StatelessWidget {
  const LibraryFilterChipsBar({
    super.key,
    required this.selected,
    required this.onSelected,
    this.horizontalPadding = 16,
    this.includeDownloaded = true,
  });

  final LibraryHomeFilter selected;
  final ValueChanged<LibraryHomeFilter> onSelected;
  final double horizontalPadding;
  final bool includeDownloaded;

  static const _order = [
    LibraryHomeFilter.songs,
    LibraryHomeFilter.albums,
    LibraryHomeFilter.artists,
    LibraryHomeFilter.playlists,
    LibraryHomeFilter.downloaded,
    LibraryHomeFilter.favorites,
  ];

  @override
  Widget build(BuildContext context) {
    final strings = LibraryHomeStrings.of(context);
    final colors = Theme.of(context).colorScheme;
    final filtering = selected != LibraryHomeFilter.all;
    final filters = [
      if (filtering) selected else LibraryHomeFilter.all,
      for (final filter in _order)
        if (filter != selected &&
            (includeDownloaded || filter != LibraryHomeFilter.downloaded))
          filter,
    ];
    return SizedBox(
      height: libraryHomeChipsHeight,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: 8,
        ),
        children: [
          if (filtering)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: IconButton(
                key: const ValueKey('library-filter-clear'),
                tooltip: strings.clearFilter,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  backgroundColor: colors.surfaceContainerHighest,
                  foregroundColor: colors.onSurface,
                ),
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => onSelected(LibraryHomeFilter.all),
              ),
            ),
          for (final filter in filters)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: _FilterChip(
                key: ValueKey('library-filter-${filter.name}'),
                label: strings.filter(filter),
                selected: filter == selected,
                onTap: () => onSelected(filter),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: selected ? colors.onPrimary : colors.onSurface,
          backgroundColor: selected
              ? colors.primary
              : colors.surfaceContainerHighest,
          shape: const StadiumBorder(),
          minimumSize: const Size(48, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: Theme.of(context).textTheme.labelLarge,
        ),
        child: Text(label),
      ),
    );
  }
}

/// Pins the chips under the header so the filter stays reachable while the
/// list scrolls; nothing else is fixed.
class LibraryChipsHeaderDelegate extends SliverPersistentHeaderDelegate {
  const LibraryChipsHeaderDelegate({
    required this.selected,
    required this.onSelected,
    required this.background,
    required this.horizontalPadding,
    this.includeDownloaded = true,
  });

  final LibraryHomeFilter selected;
  final ValueChanged<LibraryHomeFilter> onSelected;
  final Color background;
  final double horizontalPadding;
  final bool includeDownloaded;

  @override
  double get minExtent => libraryHomeChipsHeight;
  @override
  double get maxExtent => libraryHomeChipsHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      ColoredBox(
        color: background,
        child: LibraryFilterChipsBar(
          selected: selected,
          onSelected: onSelected,
          horizontalPadding: horizontalPadding,
          includeDownloaded: includeDownloaded,
        ),
      );

  @override
  bool shouldRebuild(LibraryChipsHeaderDelegate old) =>
      old.includeDownloaded != includeDownloaded ||
      old.selected != selected ||
      old.background != background ||
      old.horizontalPadding != horizontalPadding;
}

IconData libraryViewIcon(LibraryHomeView view) => switch (view) {
  LibraryHomeView.compact => Icons.view_headline,
  LibraryHomeView.list => Icons.view_list_outlined,
  LibraryHomeView.grid => Icons.grid_view_outlined,
};

/// The order selector and the layout button. Both choices are remembered.
class LibrarySortBar extends StatelessWidget {
  const LibrarySortBar({
    super.key,
    required this.sort,
    required this.view,
    required this.onSort,
    required this.onView,
    this.trailing,
  });

  final LibraryHomeSort sort;
  final LibraryHomeView view;
  final ValueChanged<LibraryHomeSort> onSort;
  final ValueChanged<LibraryHomeView> onView;
  final Widget? trailing;

  Future<void> _chooseSort(BuildContext context) async {
    final strings = LibraryHomeStrings.of(context);
    final chosen = await showAppBottomSheet<LibraryHomeSort>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in LibraryHomeSort.values)
            ListTile(
              key: ValueKey('library-sort-${option.name}'),
              title: Text(strings.sort(option)),
              selected: option == sort,
              selectedColor: Theme.of(context).colorScheme.onSurface,
              trailing: option == sort ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, option),
            ),
        ],
      ),
    );
    if (chosen != null) onSort(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final strings = LibraryHomeStrings.of(context);
    final colors = Theme.of(context).colorScheme;
    final next = LibraryHomeView
        .values[(view.index + 1) % LibraryHomeView.values.length];
    return Row(
      children: [
        Flexible(
          child: TextButton.icon(
            key: const ValueKey('library-sort'),
            onPressed: () => _chooseSort(context),
            style: TextButton.styleFrom(
              foregroundColor: colors.onSurface,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: const Icon(Icons.swap_vert, size: 18),
            label: Text(
              strings.sort(sort),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const Spacer(),
        ?trailing,
        IconButton(
          key: const ValueKey('library-view'),
          tooltip: '${strings.changeView}: ${strings.view(next)}',
          icon: Icon(libraryViewIcon(view)),
          onPressed: () => onView(next),
        ),
      ],
    );
  }
}

/// A row of the library: artwork, title, one line of context and actions.
class LibraryEntryTile extends StatelessWidget {
  const LibraryEntryTile({
    super.key,
    required this.artwork,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.compact = false,
    this.circular = false,
    this.pinned = false,
    this.trailing,
    this.horizontalPadding = 16,
  });

  final Widget artwork;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool compact;
  final bool circular;
  final bool pinned;
  final Widget? trailing;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final size = compact ? 40.0 : 56.0;
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: horizontalPadding,
          end: horizontalPadding - 8 < 0 ? 0 : horizontalPadding - 8,
          top: compact ? 4 : 6,
          bottom: compact ? 4 : 6,
        ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: size,
              child: circular
                  ? ClipOval(child: artwork)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(compact ? 6 : 8),
                      child: artwork,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    children: [
                      if (pinned)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 4),
                          child: Icon(
                            Icons.push_pin,
                            size: 12,
                            color: colors.primary,
                          ),
                        ),
                      Expanded(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: subtitleStyle,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            trailing ?? const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// The grid form of a library entry.
class LibraryEntryCell extends StatelessWidget {
  const LibraryEntryCell({
    super.key,
    required this.artwork,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.circular = false,
    this.onLongPress,
  });

  final Widget artwork;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: circular
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: circular
                ? ClipOval(child: artwork)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: artwork,
                  ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Artwork of a fixed shortcut: a tinted tile with its own icon.
class LibraryShortcutArtwork extends StatelessWidget {
  const LibraryShortcutArtwork({
    super.key,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [background, Color.lerp(background, foreground, 0.28)!],
      ),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => Center(
        child: Icon(
          icon,
          color: foreground,
          size: constraints.biggest.shortestSide * 0.46,
        ),
      ),
    ),
  );
}

/// Still placeholders while the first rows load; no spinner, no motion.
class LibraryHomeSkeleton extends StatelessWidget {
  const LibraryHomeSkeleton({
    super.key,
    this.rows = 6,
    this.horizontalPadding = 16,
  });

  final int rows;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double width) => Container(
      width: width,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return SliverList.builder(
      itemCount: rows,
      itemBuilder: (context, index) => Padding(
        key: ValueKey('library-skeleton-$index'),
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: 6,
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(140 + (index % 3) * 24),
                const SizedBox(height: 8),
                bar(90),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What to do next when a view has nothing to show.
class LibraryHomeEmptyState extends StatelessWidget {
  const LibraryHomeEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      key: const ValueKey('library-empty'),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: colors.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton(
              key: const ValueKey('library-empty-action'),
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
