import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/widgets/player_quality_preparing.dart';
import 'package:mornye/widgets/player_video_pill.dart';
import 'package:mornye/widgets/quality_mark_art.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('the filling quality mark keeps both layers on the same line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          height: 40,
          child: PreparingQualityMark(
            mark: QualityMark.flac,
            started: DateTime.now().subtract(const Duration(seconds: 2)),
            label: 'FLAC',
            compact: true,
            badgeSize: 18,
            height: 28,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final lockups = find.byType(QualityMarkLockup);
    expect(lockups, findsNWidgets(2));
    expect(
      tester.getTopLeft(lockups.at(0)).dy,
      tester.getTopLeft(lockups.at(1)).dy,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the video mark shows one badge once it is complete', (
    tester,
  ) async {
    final started = DateTime.now();
    await tester.pumpWidget(
      _host(PreparingVideoMark(started: started, height: 28, badgeSize: 18)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));
    await tester.pumpWidget(
      _host(
        PreparingVideoMark(
          started: started,
          done: true,
          height: 28,
          badgeSize: 18,
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byIcon(Icons.play_arrow_rounded),
        findsNWidgets(i < 1 ? 2 : 1),
        reason: 'step $i',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
