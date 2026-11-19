import 'dart:async';

/// Waits for the bundled add-ons to be installed or upgraded, so that a lookup
/// never reaches an add-on that is about to be replaced. It always completes:
/// a failure or a [timeout] lets the lookup go ahead with what is installed.
Future<bool> awaitBundledExtensions(
  Future<void> Function()? ready, {
  Duration timeout = const Duration(seconds: 15),
  void Function(String message)? log,
}) async {
  if (ready == null) return true;
  try {
    var timedOut = false;
    await ready().timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
      },
    );
    if (timedOut) log?.call('add-ons not ready after ${timeout.inSeconds}s');
    return !timedOut;
  } catch (error) {
    log?.call('add-on startup wait failed ${error.runtimeType}');
    return false;
  }
}
