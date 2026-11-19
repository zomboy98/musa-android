import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String guidedTourCompletedKey = 'guided_tour_completed';

class GuidedTourState {
  const GuidedTourState({this.completed = false, this.running = false});

  final bool completed;
  final bool running;

  GuidedTourState copyWith({bool? completed, bool? running}) => GuidedTourState(
    completed: completed ?? this.completed,
    running: running ?? this.running,
  );
}

class GuidedTourController extends Notifier<GuidedTourState> {
  @override
  GuidedTourState build() => const GuidedTourState();

  Future<bool> _readCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(guidedTourCompletedKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  Future<void> _writeCompleted(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(guidedTourCompletedKey, value);
    } catch (_) {}
  }

  Future<bool> startIfFirstTime() async {
    if (state.running) return false;
    if (await _readCompleted()) {
      state = state.copyWith(completed: true);
      return false;
    }
    state = state.copyWith(completed: false, running: true);
    return true;
  }

  Future<void> replay() async {
    state = const GuidedTourState(running: true);
    await _writeCompleted(false);
  }

  Future<void> finish() async {
    state = const GuidedTourState(completed: true);
    await _writeCompleted(true);
  }

  void dismissWithoutCompleting() {
    state = state.copyWith(running: false);
  }
}

final guidedTourProvider =
    NotifierProvider<GuidedTourController, GuidedTourState>(
      GuidedTourController.new,
    );
