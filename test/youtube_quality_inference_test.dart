import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';

Extension _youtube() => Extension(
  id: 'ytmusic-spotiflac',
  name: 'ytmusic-spotiflac',
  displayName: 'YouTube Music',
  version: '2.4.6',
  description: '',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: true,
  capabilities: const {'downloadFallbackTier': 'low_res'},
  qualityOptions: const [
    QualityOption(
      id: 'best',
      label: 'Best Audio',
      description: 'Opus/M4A audio direct from YouTube',
    ),
  ],
);

Extension _tidal() => Extension(
  id: 'tidal-web',
  name: 'tidal-web',
  displayName: 'Tidal',
  version: '1',
  description: '',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: true,
  capabilities: const {'downloadFallbackTier': 'lossless'},
  qualityOptions: const [
    QualityOption(id: 'HI_RES_LOSSLESS', label: 'HiRes FLAC', kind: 'lossless'),
    QualityOption(id: 'LOSSLESS', label: 'Lossless', kind: 'lossless'),
    QualityOption(id: 'HIGH', label: 'High', kind: 'lossy'),
    QualityOption(id: 'LOW', label: 'Low', kind: 'lossy'),
  ],
);

void main() {
  group('YouTube Music generic best', () {
    test('with the low_res tier it is lossy', () {
      expect(inferQualityKind('best', 'Best Audio', 'low_res'), 'lossy');
      expect(inferQualityKind('best', 'Best Audio', ' LOW_RES '), 'lossy');
      expect(inferQualityKind('default', '', 'low_res'), 'lossy');
    });

    test('lossless tiers keep it lossless and no tier keeps the old rule', () {
      expect(inferQualityKind('best', 'Best', 'lossless'), 'lossless');
      expect(inferQualityKind('best', 'Best', 'hi_res'), 'lossless');
      expect(inferQualityKind('best', 'Best Audio'), 'lossless');
    });

    test('a tier never overrides an explicit id', () {
      expect(inferQualityKind('FLAC', '', 'low_res'), 'lossless');
      expect(inferQualityKind('DOLBY_ATMOS', '', 'low_res'), 'spatial');
    });

    test('the extension gets a lossy kind and a lossy mark', () {
      final youtube = withDeclaredExtensionKinds(_youtube());
      expect(youtube.qualityOptions.single.kind, 'lossy');
      final choice = buildTrackQualityChoices(
        options: youtube.qualityOptions,
        currentId: 'best',
        service: youtube.id,
      ).single;
      expect(isLossyMark(choice.mark), isTrue);
      expect(choice.kind, 'lossy');
    });

    test('an extension that already declares kinds is returned as is', () {
      final tidal = _tidal();
      expect(identical(withDeclaredExtensionKinds(tidal), tidal), isTrue);
    });
  });

  group('selected YouTube Music is not replaced silently', () {
    test('auto_light stays on YouTube instead of jumping to Tidal', () {
      final request = resolveStreamingRequest(
        settingsQuality: autoLightStreamingQuality,
        selectedServiceId: 'ytmusic-spotiflac',
        extensions: [_tidal(), _youtube()],
        providerPriority: const ['tidal-web', 'ytmusic-spotiflac'],
      );
      expect(request.serviceId, 'ytmusic-spotiflac');
      expect(request.qualityId, 'best');
      expect(request.slower, isFalse);
    });

    test('best is not slow when requested explicitly', () {
      final request = resolveStreamingRequest(
        settingsQuality: 'best',
        selectedServiceId: 'ytmusic-spotiflac',
        extensions: [_tidal(), _youtube()],
      );
      expect(request.serviceId, 'ytmusic-spotiflac');
      expect(request.slower, isFalse);
    });

    test('relaying a YouTube best asks Tidal for a lossy tier, not FLAC', () {
      final candidates = streamingRelayCandidates(
        settingsQuality: 'best',
        first: const StreamingRequest('ytmusic-spotiflac', 'best'),
        extensions: [_tidal(), _youtube()],
      );
      expect(candidates.single.serviceId, 'tidal-web');
      expect(candidates.single.qualityId, 'HIGH');
    });

    test('a saved lossless choice is not turned into YouTube best', () {
      expect(
        reconcilePlaybackQuality(
          'LOSSLESS',
          _youtube().qualityOptions,
          fallbackTier: 'low_res',
        ),
        autoLightStreamingQuality,
      );
    });

    test('a saved YouTube best maps to the lossy tier of the next provider', () {
      expect(
        reconcilePlaybackQuality(
          'best',
          _tidal().qualityOptions,
          savedKind: 'lossy',
        ),
        'HIGH',
      );
    });
  });
}
