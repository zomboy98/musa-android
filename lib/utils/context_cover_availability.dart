import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:mornye/services/cover_cache_manager.dart';

/// Whether an online cover can be shown right now: its image is already in
/// the persistent cover cache, or the device has a connection to fetch it.
Future<bool> contextCoverAvailable(
  String url, {
  Future<bool> Function(String)? isCached,
  Future<bool> Function()? isOnline,
}) async {
  try {
    final cached =
        isCached ??
        (String key) async =>
            await CoverCacheManager.instance.getFileFromCache(key) != null;
    if (await cached(url)) return true;
  } catch (_) {}
  try {
    final online =
        isOnline ??
        () async => !(await Connectivity().checkConnectivity()).every(
          (result) => result == ConnectivityResult.none,
        );
    return await online();
  } catch (_) {
    return true;
  }
}

/// Stores an online cover in the persistent cover cache so it still shows
/// without a connection later. Failures are ignored: the file's own cover
/// takes over when the cover cannot be shown.
Future<void> cacheContextCover(String url) async {
  try {
    await CoverCacheManager.instance.getSingleFile(url);
  } catch (_) {}
}
