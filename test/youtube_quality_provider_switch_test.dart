import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _youtube = Extension(
  id: 'youtube',
  name: 'YouTube Music',
  displayName: 'YouTube Music',
  version: '1',
  description: '',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: true,
  capabilities: {'downloadFallbackTier': 'low_res'},
  qualityOptions: [QualityOption(id: 'best', label: 'Best available')],
);

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() =>
      const ExtensionState(isInitialized: true, extensions: [_youtube]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the preparing badge of a low_res best is lossy', () {
    final choices = buildTrackQualityChoices(
      options: withDeclaredQualityKinds(
        _youtube.qualityOptions,
        fallbackTier: _youtube.capabilities['downloadFallbackTier']?.toString(),
      ),
      currentId: 'best',
      service: 'youtube',
    );
    final mark = choices.firstWhere((c) => c.current).mark;
    expect(isLossyMark(mark), isTrue);
  });

  test('switching to YouTube with LOSSLESS saved does not leave best', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [extensionProvider.overrideWith(_Extensions.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    notifier.setPlaybackQuality('LOSSLESS');
    notifier.setDefaultDownloadExtension(_youtube);
    expect(container.read(settingsProvider).playbackQuality, isNot('best'));
  });
}
