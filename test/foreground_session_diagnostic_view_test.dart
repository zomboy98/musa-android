import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/services/foreground_session_renewal.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  testWidgets(
    'distinguishes refreshed from valid and formats only validated expiry',
    (tester) async {
      final now = DateTime.utc(2026);
      final diagnostic = const ForegroundSessionDiagnostic()
          .record(
            const SessionRenewalResult(
              status: SessionRenewalStatus.refreshed,
              expiresAt: '2099-01-01T00:00:00Z',
            ),
            now,
          )
          .record(
            const SessionRenewalResult(
              status: SessionRenewalStatus.validUntil,
              expiresAt: '2098-01-01T00:00:00Z',
            ),
            now,
          )
          .record(
            const SessionRenewalResult(
              status: SessionRenewalStatus.refreshed,
              expiresAt: 'secret-not-a-date',
            ),
            now,
          );
      await tester.pumpWidget(
        MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ForegroundSessionDiagnosticView(diagnostic: diagnostic),
          ),
        ),
      );
      expect(find.textContaining('Refreshed: 1'), findsOneWidget);
      expect(find.textContaining('Valid: 1'), findsOneWidget);
      expect(find.textContaining('Unknown: 1'), findsOneWidget);
      expect(find.textContaining('Earliest expiry:'), findsOneWidget);
      expect(find.textContaining('secret-not-a-date'), findsNothing);
    },
  );
}
