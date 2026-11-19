import 'package:flutter/widgets.dart';

/// Keeps native log collection scoped to the visible app shell.
class NativeLogLifecycle with WidgetsBindingObserver {
  NativeLogLifecycle(this._setAppActive);

  final ValueChanged<bool> _setAppActive;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final state = binding.lifecycleState;
    _setAppActive(state == null || state == AppLifecycleState.resumed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _setAppActive(state == AppLifecycleState.resumed);
  }

  void dispose() {
    if (!_started) return;
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
    _setAppActive(false);
  }
}
