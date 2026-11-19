import 'package:connectivity_plus/connectivity_plus.dart';

typedef ConnectivityCheck = Future<List<ConnectivityResult>> Function();

Future<List<ConnectivityResult>> _systemCheck() =>
    Connectivity().checkConnectivity();

Future<bool> videoNetworkAllowed({
  required bool allowMobileData,
  ConnectivityCheck? check,
}) async {
  final List<ConnectivityResult> results;
  try {
    results = await (check ?? _systemCheck)();
  } catch (_) {
    return false;
  }
  if (results.isEmpty) return false;
  final unmetered = results.any(
    (r) => r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet,
  );
  if (unmetered) return true;
  if (results.every((r) => r == ConnectivityResult.none)) return false;
  return allowMobileData;
}
