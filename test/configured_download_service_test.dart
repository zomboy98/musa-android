import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/local_track_redownload_service.dart';

void main() {
  const a = Extension(
    id: 'a',
    name: 'A',
    displayName: 'A',
    version: '1',
    description: '',
    enabled: true,
    status: 'loaded',
    hasDownloadProvider: true,
  );
  const b = Extension(
    id: 'b',
    name: 'B',
    displayName: 'B',
    version: '1',
    description: '',
    enabled: true,
    status: 'loaded',
    hasDownloadProvider: true,
  );
  const state = ExtensionState(extensions: [a, b]);
  const prioritized = ExtensionState(
    extensions: [a, b],
    providerPriority: ['missing', ' B ', 'a'],
  );

  test('uses download priority when no provider is selected', () {
    expect(resolveConfiguredDownloadService('', prioritized), 'b');
    expect(
      resolveConfiguredDownloadService('', prioritized, autoFallback: false),
      'b',
    );
  });
  test('uses download priority for an unavailable selection', () {
    expect(resolveConfiguredDownloadService('missing', prioritized), 'b');
    expect(
      resolveConfiguredDownloadService(
        'missing',
        prioritized,
        autoFallback: false,
      ),
      '',
    );
  });
  test('keeps an available explicit selection ahead of priority', () {
    expect(resolveConfiguredDownloadService('a', prioritized), 'a');
  });
  test('skips failed providers and keeps enabled non-error providers', () {
    const healthy = Extension(
      id: 'healthy',
      name: 'Healthy',
      displayName: 'Healthy',
      version: '1',
      description: '',
      enabled: true,
      status: 'enabled',
      hasDownloadProvider: true,
    );
    const failed = Extension(
      id: 'failed',
      name: 'Failed',
      displayName: 'Failed',
      version: '1',
      description: '',
      enabled: true,
      status: 'error',
      hasDownloadProvider: true,
    );
    const state = ExtensionState(
      extensions: [failed, healthy],
      providerPriority: ['failed'],
    );
    expect(resolveConfiguredDownloadService('', state), 'healthy');
    expect(resolveConfiguredDownloadService('failed', state), 'healthy');
    expect(
      resolveConfiguredDownloadService('failed', state, autoFallback: false),
      '',
    );
  });

  test('uses the selected provider', () {
    expect(
      resolveConfiguredDownloadService('b', state, autoFallback: false),
      'b',
    );
  });
  test('resolves an empty first-install default like settings', () {
    expect(
      resolveConfiguredDownloadService('', state, autoFallback: false),
      resolveEffectiveDownloadService('', state),
    );
  });
  test('falls back only when enabled for an unavailable selection', () {
    expect(
      resolveConfiguredDownloadService('missing', state, autoFallback: true),
      'a',
    );
    expect(
      resolveConfiguredDownloadService('missing', state, autoFallback: false),
      '',
    );
    expect(resolveConfiguredDownloadService('', const ExtensionState()), '');
  });
  test('FLAC upgrade respects disabled fallback', () {
    expect(
      LocalTrackRedownloadService.preferredFlacService(
        const AppSettings(defaultService: 'missing', autoFallback: false),
        state,
      ),
      '',
    );
    expect(
      LocalTrackRedownloadService.preferredFlacQualityForService('a', state),
      'LOSSLESS',
    );
  });
}
