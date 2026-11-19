import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/cover_backdrop.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_song_journey.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

Widget _mini({required bool mornye, bool highContrast = false}) =>
    ProviderScope(
      overrides: [
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(
            const MediaItem(id: 'a', title: 'Track', artist: 'Ana'),
          ),
        ),
        playbackStateProvider.overrideWith((ref) => const Stream.empty()),
        mornyeLiquidGlassProvider.overrideWithValue(false),
        backdropBlurEnabledProvider.overrideWithValue(false),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(const AppSettings()),
        ),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(highContrast: highContrast),
          child: child!,
        ),
        home: Scaffold(
          bottomNavigationBar: const SizedBox(width: 360, child: MiniPlayer()),
        ),
      ),
    );

LinearGradient _gradient(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.byKey(const ValueKey('mini-cover-gradient')),
  );
  return (box.decoration as BoxDecoration).gradient! as LinearGradient;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mornye in [true, false]) {
    final name = mornye ? 'Mornye' : 'Material';

    testWidgets('$name mini player: cover on the left, controls on the right '
        'inside a horizontal gradient', (tester) async {
      await tester.pumpWidget(_mini(mornye: mornye));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final cover = tester.getCenter(find.byType(PlayerArtwork)).dx;
      final title = tester.getCenter(find.text('Track')).dx;
      final buttons = find.byType(AppIconButton);
      expect(buttons, findsAtLeastNWidgets(2));
      final play = tester.getCenter(buttons.at(0)).dx;
      final next = tester.getCenter(buttons.at(1)).dx;
      expect(cover, lessThan(title));
      expect(title, lessThan(play));
      expect(play, lessThan(next));

      final gradient = _gradient(tester);
      expect(gradient.begin, AlignmentDirectional.centerStart);
      expect(gradient.end, AlignmentDirectional.centerEnd);
      final strong = gradient.colors.first;
      final light = gradient.colors.last;
      expect(strong, isNot(light));
      expect(light.computeLuminance(), greaterThan(strong.computeLuminance()));
    });

    testWidgets('$name mini player text and icons read over the gradient', (
      tester,
    ) async {
      await tester.pumpWidget(_mini(mornye: mornye));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final gradient = _gradient(tester);
      final on = tester
          .widget<AppIconButton>(find.byType(AppIconButton).at(1))
          .color!;
      for (final fill in gradient.colors) {
        expect(journeyContrast(on, fill), greaterThanOrEqualTo(4.5));
      }
    });
  }

  testWidgets('high contrast gives a solid gradient', (tester) async {
    await tester.pumpWidget(_mini(mornye: true, highContrast: true));
    await tester.pump();
    final gradient = _gradient(tester);
    expect(gradient.colors.first, gradient.colors.last);
  });

  test('the on-colour reads at least 4.5:1 over any cover colour', () {
    for (final hue in [0.0, 30.0, 60.0, 120.0, 200.0, 240.0, 300.0]) {
      for (final tone in [10.0, 40.0, 70.0, 95.0]) {
        final backdrop = CoverBackdrop([
          CoverBackdropSample(hue: hue, chroma: 60, tone: tone, share: 1),
        ], meanChroma: 60);
        final strong = Color.alphaBlend(
          journeyFill(journeyCoverTint(backdrop), highContrast: false),
          Colors.black,
        );
        final light = Color.lerp(strong, Colors.white, 0.16)!;
        final on = journeyOnColorFor([strong, light]);
        expect(journeyContrast(on, strong), greaterThanOrEqualTo(4.5));
        expect(journeyContrast(on, light), greaterThanOrEqualTo(4.5));
      }
    }
  });

  test('a cover without colour gives a dark neutral gradient', () {
    final tint = journeyCoverTint(CoverBackdrop.neutral);
    final strong = Color.alphaBlend(
      journeyFill(tint, highContrast: false),
      Colors.black,
    );
    expect(strong.computeLuminance(), lessThan(0.2));
    expect(journeyOnColorFor([strong]), Colors.white);
  });
}
