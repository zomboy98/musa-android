import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/track_collection_action_policy.dart';

void main() {
  group('quality variant track menu', () {
    test('keeps local playback available without quality variants', () {
      expect(
        resolveQualityVariantMenuAction(
          allowQualityVariants: false,
          hasLocalPlaybackCandidate: true,
        ),
        QualityVariantMenuAction.playLocal,
      );
    });

    test(
      'does not offer local playback or variants for an unavailable track',
      () {
        expect(
          resolveQualityVariantMenuAction(
            allowQualityVariants: false,
            hasLocalPlaybackCandidate: false,
          ),
          isNull,
        );
      },
    );

    test('offers another download when the track is not local', () {
      expect(
        resolveQualityVariantMenuAction(
          allowQualityVariants: true,
          hasLocalPlaybackCandidate: false,
        ),
        QualityVariantMenuAction.downloadAnotherQuality,
      );
    });

    test('swaps to local playback when row tap handles the download', () {
      expect(
        resolveQualityVariantMenuAction(
          allowQualityVariants: true,
          hasLocalPlaybackCandidate: true,
        ),
        QualityVariantMenuAction.playLocal,
      );
    });
  });
}
