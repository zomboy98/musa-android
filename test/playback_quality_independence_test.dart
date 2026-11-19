import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(playbackQuality: 'HIGH', audioQuality: 'LOW');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('playback and download quality can change independently', () {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(_Settings.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);

    notifier.setPlaybackQuality('LOSSLESS');
    expect(container.read(settingsProvider).playbackQuality, 'LOSSLESS');
    expect(container.read(settingsProvider).audioQuality, 'LOW');

    notifier.setAudioQuality('MEDIUM');
    expect(container.read(settingsProvider).playbackQuality, 'LOSSLESS');
    expect(container.read(settingsProvider).audioQuality, 'MEDIUM');
  });
}
