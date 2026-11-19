part of 'download_settings_page.dart';

/// Searchable region list.
class _RegionPickerSheet extends StatefulWidget {
  const _RegionPickerSheet({
    required this.regions,
    required this.selected,
    required this.countryNameOf,
    required this.onSelected,
    required this.scrollController,
  });

  final List<String> regions;
  final String selected;
  final String Function(BuildContext context, String code) countryNameOf;
  final ValueChanged<String> onSelected;
  final ScrollController scrollController;

  @override
  State<_RegionPickerSheet> createState() => _RegionPickerSheetState();
}

class _RegionPickerSheetState extends State<_RegionPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? widget.regions
        : widget.regions.where((code) {
            if (code.toLowerCase().contains(query)) return true;
            return widget
                .countryNameOf(context, code)
                .toLowerCase()
                .contains(query);
          }).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: AppSearchField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            hintText: MaterialLocalizations.of(context).searchFieldLabel,
            clearTooltip: context.l10n.dialogClear,
            onClear: () => setState(() => _query = ''),
          ),
        ),
        Flexible(
          child: matches.isEmpty
              ? ListView(
                  controller: widget.scrollController,
                  shrinkWrap: true,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        context.l10n.searchEmptyResultSubtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  controller: widget.scrollController,
                  shrinkWrap: true,
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final code = matches[index];
                    final isSelected = code == widget.selected;
                    final countryName = widget.countryNameOf(context, code);
                    return AppSheetOption.choice(
                      title: Text(countryName != code ? countryName : code),
                      subtitle: countryName != code ? Text(code) : null,
                      selected: isSelected,
                      onTap: () => widget.onSelected(code),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
