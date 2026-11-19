import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/listening_statistics.dart' show listeningDay;
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('HomeTopPicks');

const _cacheKey = 'home_top_picks_v2';

/// The most extension playlists Top Picks show after the mixes.
const homeTopPickPlaylists = 9;

/// Exclude chart playlists and sections from the daily selection.
final _chartName = RegExp(r'\b(top \d+|charts?)\b', caseSensitive: false);

/// Up to [count] playlists of [sections] with a cover, each once, in an order
/// that holds for the [day] and changes with the next. Charts are left out.
@visibleForTesting
List<ExploreItem> pickTopPickPlaylists(
  List<ExploreSection> sections,
  String day, {
  int count = homeTopPickPlaylists,
}) {
  final playlists = <(String?, String), ExploreItem>{};
  for (final section in sections) {
    if (_chartName.hasMatch(section.title)) continue;
    for (final item in section.items) {
      if (item.type != 'playlist' || item.id.isEmpty) continue;
      if (_chartName.hasMatch(item.name)) continue;
      if (item.coverUrl?.trim().isNotEmpty != true) continue;
      playlists.putIfAbsent((item.providerId, item.id), () => item);
    }
  }
  final ordered = playlists.values.toList()
    ..sort((a, b) {
      final provider = (a.providerId ?? '').compareTo(b.providerId ?? '');
      return provider != 0 ? provider : a.id.compareTo(b.id);
    })
    ..shuffle(Random(int.tryParse(day.replaceAll('-', '')) ?? 0));
  return ordered.take(count).toList(growable: false);
}

/// Respect the Home feed selection. Auto uses the first available extension;
/// Off or an unavailable selection does not query another extension.
@visibleForTesting
String? pickTopPicksExtension(
  List<String> available,
  String? homeFeed, {
  String? catalog,
}) {
  if (homeFeed == AppSettings.homeFeedProviderOff) return null;
  if (homeFeed != null && homeFeed.isNotEmpty) {
    return available.contains(homeFeed) ? homeFeed : null;
  }
  if (catalog != null && available.contains(catalog)) return catalog;
  return available.firstOrNull;
}

final homeTopPicksExtensionProvider = Provider<String?>((ref) {
  final homeFeed = ref.watch(
    settingsProvider.select((settings) => settings.homeFeedProvider),
  );
  final catalog = ref.watch(
    settingsProvider.select((settings) => settings.searchProvider),
  );
  final available = ref
      .watch(extensionProvider.select((state) => state.extensions))
      .where((extension) => extension.enabled && extension.hasHomeFeed);
  return pickTopPicksExtension([
    for (final extension in available) extension.id,
  ], homeFeed, catalog: catalog);
});

@visibleForTesting
final homeTopPicksFeedReaderProvider =
    Provider<Future<List<ExploreSection>?> Function(String)>(
      (ref) => readExtensionHomeFeed,
    );

final homeTopPicksRegionProvider = FutureProvider<String?>((ref) async {
  final id = ref.watch(homeTopPicksExtensionProvider);
  if (id == null) return null;
  // Only the region setting matters: other changes to the extension list
  // (health checks, session renewals on resume) must not reload Top Picks.
  ref.watch(
    extensionProvider.select(
      (state) => state.extensions
          .where((item) => item.id == id)
          .firstOrNull
          ?.homeFeedRegionSetting
          ?.key,
    ),
  );
  final extension = ref
      .read(extensionProvider)
      .extensions
      .where((item) => item.id == id)
      .firstOrNull;
  if (extension?.homeFeedRegionSetting == null) return null;
  final settings = await ref.watch(extensionSettingsProvider(id).future);
  return resolveHomeFeedRegion(extension!, settings);
});

/// The picks to paint: the last ones while a reload or a retry runs, so the
/// shelf never empties and refills (stale-while-revalidate).
List<ExploreItem> topPickPlaylistsOf(AsyncValue<List<ExploreItem>> picks) =>
    picks.value ?? const [];

/// Increment only for an explicit user refresh, preserving the daily cache.
final homeTopPicksRefreshProvider = StateProvider<int>((ref) => 0);

/// A successful Explore refresh can supply the same normalized feed directly.
final homeTopPicksRefreshFeedProvider =
    StateProvider<
      ({String extensionId, String? region, List<ExploreSection> sections})?
    >((ref) => null);

class _RefreshTracker {
  int attempted = 0;
  Future<void> pendingWrite = Future.value();
}

final _refreshTrackerProvider = Provider<_RefreshTracker>(
  (ref) => _RefreshTracker(),
);

/// Injectable clock keeps the calendar boundary testable.
@visibleForTesting
final homeTopPicksClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final homeTopPicksDayProvider = NotifierProvider<_HomeTopPicksDay, String>(
  _HomeTopPicksDay.new,
);

class _HomeTopPicksDay extends Notifier<String> with WidgetsBindingObserver {
  Timer? _timer;

  @override
  String build() {
    final now = ref.watch(homeTopPicksClockProvider);
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _timer?.cancel();
      WidgetsBinding.instance.removeObserver(this);
    });
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != AppLifecycleState.hidden &&
        lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.detached) {
      _schedule(now);
    }
    return listeningDay(now());
  }

  void _schedule(DateTime Function() now) {
    _timer?.cancel();
    final current = now();
    final midnight = DateTime(current.year, current.month, current.day + 1);
    final untilMidnight = midnight.difference(current);
    _timer = Timer(untilMidnight, () {
      _update(now);
    });
  }

  void _update(DateTime Function() now) {
    final day = listeningDay(now());
    if (day != state) state = day;
    _schedule(now);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _update(ref.read(homeTopPicksClockProvider));
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

/// A day's random extension playlists, kept for that day. A failed read falls
/// back on the last day's picks and is tried again on the next launch.
final homeTopPicksProvider = FutureProvider<List<ExploreItem>>((ref) async {
  final extensionId = ref.watch(homeTopPicksExtensionProvider);
  final day = ref.watch(homeTopPicksDayProvider);
  final revision = ref.watch(homeTopPicksRefreshProvider);
  final tracker = ref.read(_refreshTrackerProvider);
  final refreshedFeed = ref.read(homeTopPicksRefreshFeedProvider);
  final readFeed = ref.watch(homeTopPicksFeedReaderProvider);
  final regionFuture = ref.watch(homeTopPicksRegionProvider.future);
  if (extensionId == null) return const [];
  final region = await regionFuture;
  if (!ref.mounted) return const [];
  final prefs = await SharedPreferences.getInstance();
  if (!ref.mounted) return const [];
  await tracker.pendingWrite;
  if (!ref.mounted) return const [];
  final forceRefresh = revision != tracker.attempted;
  final cached = _decode(prefs.getString(_cacheKey));
  final usable = cached?.extensionId == extensionId && cached?.region == region
      ? cached
      : null;
  if (!forceRefresh && usable != null && usable.day == day) return usable.items;
  List<ExploreSection>? sections;
  try {
    if (forceRefresh &&
        refreshedFeed?.extensionId == extensionId &&
        refreshedFeed?.region == region) {
      sections = refreshedFeed!.sections;
    } else {
      // A region change also refreshes Explore. Wait for that request before
      // consulting the bridge, then reuse only its matching regional result.
      if (cached != null &&
          cached.extensionId == extensionId &&
          cached.region != region) {
        await ref.read(exploreProvider.notifier).waitForConfigurationReload();
        if (!ref.mounted) return const [];
        final feed = ref.read(exploreProvider);
        if (feed.providerId == extensionId &&
            feed.region == region &&
            feed.error == null &&
            feed.lastFetched != null) {
          sections = feed.sections;
        }
      }
      sections ??= await readFeed(extensionId);
    }
  } on Object catch (error, stack) {
    _log.w('Could not read Top Picks playlists: $error\n$stack');
  }
  if (sections == null) {
    if (!ref.mounted) return const [];
    if (forceRefresh) tracker.attempted = revision;
    if (usable != null) return usable.items;
    // Startup clears the bridge's caches and cancels reads under way: failing
    // with an Exception, not an Error, has Riverpod try again in a moment.
    throw Exception('Top Picks have no playlists yet');
  }
  final items = pickTopPickPlaylists(sections, day);
  // A slower request from a previous day must not overwrite today's cache.
  if (!ref.mounted) return items;
  final write = tracker.pendingWrite.then((_) async {
    if (!ref.mounted) return;
    await prefs.setString(
      _cacheKey,
      jsonEncode({
        'day': day,
        'extensionId': extensionId,
        'region': region,
        'items': [for (final item in items) item.toJson()],
      }),
    );
  });
  tracker.pendingWrite = write.catchError((Object _) {});
  await write;
  if (ref.mounted && forceRefresh) tracker.attempted = revision;
  return items;
});

({String day, String extensionId, String? region, List<ExploreItem> items})?
_decode(String? value) {
  if (value == null) return null;
  try {
    final json = jsonDecode(value);
    if (json is! Map) return null;
    final day = json['day'], extensionId = json['extensionId'];
    final items = json['items'];
    if (day is! String || extensionId is! String || items is! List) return null;
    return (
      day: day,
      extensionId: extensionId,
      region: json['region'] is String ? json['region'] as String : null,
      items: [
        for (final item in items)
          if (item is Map<String, dynamic>) ExploreItem.fromJson(item),
      ],
    );
  } on FormatException {
    return null;
  }
}
