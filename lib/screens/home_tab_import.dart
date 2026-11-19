part of 'home_tab.dart';

extension _HomeTabCsvImport on _HomeTabState {
  Future<void> _importCsv(BuildContext context, WidgetRef ref) async {
    if (_isCsvImporting) return;
    _setCsvImporting(true);
    try {
      await importPlaylistFile(context, ref);
    } finally {
      _setCsvImporting(false);
    }
  }
}
