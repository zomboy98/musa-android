part of 'home_tab.dart';

class _RecentAccessView {
  final List<RecentAccessItem> uniqueItems;

  const _RecentAccessView({required this.uniqueItems});
}

const _recentAccessVisibleLimit = 10;

_RecentAccessView _buildRecentAccessViewData(List<RecentAccessItem> items) {
  final sorted = [...items]
    ..sort((a, b) => b.accessedAt.compareTo(a.accessedAt));

  final seen = <String>{};
  final uniqueItems = <RecentAccessItem>[];
  for (final item in sorted) {
    if (seen.add('${item.type.name}:${item.id}')) {
      uniqueItems.add(item);
      if (uniqueItems.length >= _recentAccessVisibleLimit) break;
    }
  }

  return _RecentAccessView(uniqueItems: uniqueItems);
}

final recentAccessViewProvider = Provider<_RecentAccessView>((ref) {
  final recentAccessItems = ref.watch(
    recentAccessProvider.select((s) => s.items),
  );
  return _buildRecentAccessViewData(recentAccessItems);
});
