import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/apple_animated_artwork.dart';
import 'package:mornye/services/player_cover_mode.dart';

const _tall = PlayerCoverVideo('file:///tall.mp4');
const _canvas = PlayerCoverVideo('file:///canvas.mp4');
const _square = PlayerCoverVideo('file:///square.mp4');

PlayerCoverDecision _decide({
  bool motionEnabled = true,
  bool tallEnabled = true,
  bool networkAllowed = true,
  bool reduceAnimations = false,
  bool musicVideoActive = false,
  bool landscape = false,
  PlayerCoverVideo? appleTall,
  PlayerCoverVideo? canvas,
  PlayerCoverVideo? appleSquare,
}) => decidePlayerCoverMode(
  motionEnabled: motionEnabled,
  tallEnabled: tallEnabled,
  networkAllowed: networkAllowed,
  reduceAnimations: reduceAnimations,
  musicVideoActive: musicVideoActive,
  landscape: landscape,
  appleTall: appleTall,
  canvas: canvas,
  appleSquare: appleSquare,
);

void main() {
  group('decidePlayerCoverMode', () {
    test('without any loop the complete still cover stays', () {
      expect(_decide().mode, PlayerCoverMode.still);
    });

    test('priority is Apple tall, Canvas, Apple square, still', () {
      final all = _decide(
        appleTall: _tall,
        canvas: _canvas,
        appleSquare: _square,
      );
      expect(all.mode, PlayerCoverMode.fullBleedVideo);
      expect(all.kind, PlayerCoverVideoKind.appleTall);
      expect(all.source, _tall.source);

      final withoutTall = _decide(canvas: _canvas, appleSquare: _square);
      expect(withoutTall.mode, PlayerCoverMode.fullBleedVideo);
      expect(withoutTall.kind, PlayerCoverVideoKind.canvas);

      final squareOnly = _decide(appleSquare: _square);
      expect(squareOnly.mode, PlayerCoverMode.squareVideo);
      expect(squareOnly.kind, PlayerCoverVideoKind.appleSquare);
    });

    test('the motion artwork setting off keeps the still cover', () {
      expect(
        _decide(
          motionEnabled: false,
          appleTall: _tall,
          canvas: _canvas,
          appleSquare: _square,
        ).mode,
        PlayerCoverMode.still,
      );
    });

    test('remove animations keeps the still cover', () {
      expect(
        _decide(reduceAnimations: true, appleTall: _tall, canvas: _canvas).mode,
        PlayerCoverMode.still,
      );
    });

    test('a playing music video keeps the still cover', () {
      expect(
        _decide(
          musicVideoActive: true,
          appleTall: _tall,
          appleSquare: _square,
        ).mode,
        PlayerCoverMode.still,
      );
    });

    test('the adaptive setting off never goes full screen', () {
      final decision = _decide(
        tallEnabled: false,
        appleTall: _tall,
        appleSquare: _square,
      );
      expect(decision.mode, PlayerCoverMode.squareVideo);
      expect(
        _decide(tallEnabled: false, appleTall: _tall).mode,
        PlayerCoverMode.still,
      );
    });

    test('a Canvas stays a backdrop when not full screen', () {
      expect(
        _decide(tallEnabled: false, canvas: _canvas).mode,
        PlayerCoverMode.canvasBackdrop,
      );
      expect(
        _decide(landscape: true, appleTall: _tall, canvas: _canvas).mode,
        PlayerCoverMode.canvasBackdrop,
      );
    });

    test('landscape keeps the normal mode', () {
      expect(
        _decide(landscape: true, appleTall: _tall, appleSquare: _square).mode,
        PlayerCoverMode.squareVideo,
      );
      expect(
        _decide(landscape: true, appleTall: _tall).mode,
        PlayerCoverMode.still,
      );
    });

    test('mobile data not allowed skips loops that are not saved', () {
      const streamed = PlayerCoverVideo(
        'https://c.example.test/a.mp4',
        local: false,
      );
      expect(
        _decide(networkAllowed: false, canvas: streamed).mode,
        PlayerCoverMode.still,
      );
      expect(
        _decide(networkAllowed: false, canvas: streamed, appleTall: _tall).kind,
        PlayerCoverVideoKind.appleTall,
      );
      expect(
        _decide(
          networkAllowed: false,
          appleTall: streamed,
          canvas: _canvas,
        ).kind,
        PlayerCoverVideoKind.canvas,
      );
      expect(_decide(canvas: streamed).mode, PlayerCoverMode.fullBleedVideo);
    });

    test('an empty source is not a loop', () {
      expect(
        _decide(appleTall: const PlayerCoverVideo('')).mode,
        PlayerCoverMode.still,
      );
    });
  });

  group('selectAnimatedArtworkVariants', () {
    final editorial = {
      'motionDetailSquare': {
        'video': 'https://v.example.test/square.m3u8',
        'previewFrame': {'url': 'https://v.example.test/square.jpg'},
      },
      'motionTallVideo3x4': {'video': 'https://v.example.test/tall.m3u8'},
    };

    test('returns the square and the tall loop apart', () {
      final variants = selectAnimatedArtworkVariants(editorial);
      expect(variants.square?.url, 'https://v.example.test/square.m3u8');
      expect(variants.square?.variant, AnimatedArtworkVariant.square);
      expect(variants.square?.previewUrl, 'https://v.example.test/square.jpg');
      expect(variants.tall?.url, 'https://v.example.test/tall.m3u8');
      expect(variants.tall?.variant, AnimatedArtworkVariant.tall);
    });

    test('keeps the square loop as the single choice', () {
      expect(
        selectAnimatedArtworkVariant(editorial)?.variant,
        AnimatedArtworkVariant.square,
      );
    });

    test('a tall-only album yields only the tall loop', () {
      final variants = selectAnimatedArtworkVariants({
        'motionDetailTall': {'video': 'https://v.example.test/t.m3u8'},
      });
      expect(variants.square, isNull);
      expect(variants.tall?.url, 'https://v.example.test/t.m3u8');
      expect(
        selectAnimatedArtworkVariant({
          'motionDetailTall': {'video': 'https://v.example.test/t.m3u8'},
        })?.variant,
        AnimatedArtworkVariant.tall,
      );
    });

    test('ignores entries without a usable URL', () {
      expect(
        selectAnimatedArtworkVariants({
          'motionDetailSquare': {'video': 'ftp://nope'},
          'motionDetailTall': {'video': ''},
        }).isEmpty,
        isTrue,
      );
      expect(selectAnimatedArtworkVariants('x').isEmpty, isTrue);
      expect(selectAnimatedArtworkVariants(null).isEmpty, isTrue);
    });

    test('a response carries both variants', () {
      final result = classifyAnimatedArtworkResponse({
        'success': true,
        'type': 'animated_artwork',
        'id': '42',
        'editorial_video': editorial,
      });
      expect(result.outcome, AnimatedArtworkOutcome.found);
      expect(result.source?.variant, AnimatedArtworkVariant.square);
      expect(result.variants.tall, isNotNull);
      expect(result.variants.square, isNotNull);
    });
  });

  group('videoFitForAspect', () {
    test('a 3:4 video on a tall phone is shown at the full width', () {
      final result = videoFitForAspect(0.75, 0.46);
      expect(result.fit, PlayerVideoFit.fitWidth);
      expect(result.cropFraction, closeTo(0.387, 0.001));
    });

    test('a 9:16 video loses 18 percent, over the threshold', () {
      final result = videoFitForAspect(0.5625, 0.46);
      expect(result.fit, PlayerVideoFit.fitWidth);
      expect(result.cropFraction, closeTo(0.182, 0.001));
    });

    test('a video close to the screen shape covers it', () {
      final result = videoFitForAspect(0.5625, 0.52);
      expect(result.fit, PlayerVideoFit.cover);
      expect(result.cropFraction, closeTo(0.076, 0.001));
      expect(result.cropFraction, lessThan(playerVideoMaxCropFraction));
    });

    test('a square video is shown at the full width', () {
      expect(videoFitForAspect(1, 0.46).fit, PlayerVideoFit.fitWidth);
    });

    test('a video narrower than the area never loses its sides', () {
      final result = videoFitForAspect(0.4, 0.46);
      expect(result.fit, PlayerVideoFit.cover);
      expect(result.cropFraction, 0);
    });

    test('invalid aspects fall back to cover', () {
      expect(videoFitForAspect(0, 0.46).fit, PlayerVideoFit.cover);
      expect(videoFitForAspect(0.75, 0).fit, PlayerVideoFit.cover);
      expect(videoFitForAspect(double.nan, 0.46).fit, PlayerVideoFit.cover);
    });
  });
}
