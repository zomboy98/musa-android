import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/sources_page.dart';
import 'package:mornye/services/regional_song_signal.dart';
import 'package:mornye/services/search_region.dart';
import 'package:mornye/widgets/settings_group.dart';

String _regionLabel(BuildContext context, String setting) {
  final language = Localizations.localeOf(context).languageCode;
  final l10n = context.l10n;
  return switch (sanitizeSearchRegion(setting)) {
    searchRegionAuto => l10n.searchRegionAutoValue(
      searchRegionName(
        resolveSearchRegion(
          searchRegionAuto,
          deviceCountry: deviceCountryCode(),
        )!,
        language,
      ),
    ),
    searchRegionNone => l10n.searchRegionGlobalOption,
    final code => searchRegionName(code, language),
  };
}

/// The setting that picks the country of the regional order of results.
class SearchRegionSelector extends ConsumerWidget {
  const SearchRegionSelector({super.key});

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final language = Localizations.localeOf(context).languageCode;
    final current = sanitizeSearchRegion(
      ref.read(settingsProvider).searchRegion,
    );
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(dialogContext.l10n.searchRegionChoose),
        children: [
          for (final (value, label) in [
            (searchRegionAuto, dialogContext.l10n.searchRegionAutoOption),
            (searchRegionNone, dialogContext.l10n.searchRegionGlobalOption),
            for (final country in searchRegionCountries)
              (country.code, searchRegionName(country.code, language)),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(value),
              child: Row(
                children: [
                  Expanded(child: Text(label)),
                  if (value == current) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen != null) {
      ref.read(settingsProvider.notifier).setSearchRegion(chosen);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setting = ref.watch(settingsProvider.select((s) => s.searchRegion));
    return SettingsSearchTarget(
      label: context.l10n.searchRegionTitle,
      child: SettingsItem(
        key: const ValueKey('search-region-setting'),
        icon: Icons.public,
        title: context.l10n.searchRegionTitle,
        subtitle:
            '${_regionLabel(context, setting)}\n${context.l10n.searchRegionSubtitle}',
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pick(context, ref),
        showDivider: false,
      ),
    );
  }
}

/// The switch that lets results use what the user follows and plays.
class PersonalizeSearchSwitch extends ConsumerWidget {
  const PersonalizeSearchSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(
      settingsProvider.select((s) => s.personalizeSearchResults),
    );
    return SettingsSearchTarget(
      label: context.l10n.personalizeSearchTitle,
      child: SettingsSwitchItem(
        key: const ValueKey('personalize-search-setting'),
        icon: Icons.tune,
        title: context.l10n.personalizeSearchTitle,
        subtitle: context.l10n.personalizeSearchSubtitle,
        value: value,
        onChanged: ref
            .read(settingsProvider.notifier)
            .setPersonalizeSearchResults,
        showDivider: false,
      ),
    );
  }
}

/// A discreet line over the results naming the region that was used. Tapping
/// it opens the setting. Hidden when the regional order is off or cannot run.
class SearchRegionNote extends ConsumerWidget {
  const SearchRegionNote({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setting = ref.watch(settingsProvider.select((s) => s.searchRegion));
    final available = ref.watch(
      extensionProvider.select(
        (state) => state.extensions.any(
          (ext) =>
              ext.id == regionalSignalExtensionId &&
              ext.enabled &&
              ext.hasCustomSearch,
        ),
      ),
    );
    final region = resolveSearchRegion(
      setting,
      deviceCountry: deviceCountryCode(),
    );
    if (region == null || !available) return const SizedBox.shrink();
    final name = searchRegionName(
      region,
      Localizations.localeOf(context).languageCode,
    );
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: const ValueKey('search-region-note'),
      onTap: () => pushPage<void>(context, (_) => const SourcesPage()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.public, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                context.l10n.searchRegionResultsFor(name),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
