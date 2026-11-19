/// Holds a tap on the "update available" notice until the shell can open
/// Settings > About, including a tap that launched the app.
class AppUpdateNotificationRouter {
  static const payload = 'musa_app_update';

  bool _pending = false;
  void Function()? _handler;

  void setHandler(void Function()? handler) {
    _handler = handler;
    _drain();
  }

  void receive(Object? value) {
    if (value != payload) return;
    _pending = true;
    _drain();
  }

  void _drain() {
    final handler = _handler;
    if (handler == null || !_pending) return;
    _pending = false;
    handler();
  }
}
