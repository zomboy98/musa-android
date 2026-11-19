import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/settings/musa_license_page.dart';
import 'package:flutter/services.dart';

void main() {
  testWidgets('licenses screen shows attribution, source link and LGPL text', (
    tester,
  ) async {
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const [
        AppInfo.appName,
      ], await musaLicenseText(rootBundle.loadString));
    });
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMusaLicensePage(context),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Copyright 2026 zarzet'), findsOneWidget);
    expect(find.textContaining('copyright original conservado'), findsOneWidget);
    expect(find.textContaining(AppInfo.sourceCodeUrl), findsOneWidget);
    expect(
      find.textContaining('Tienes derecho a recibir el código fuente'),
      findsOneWidget,
    );
    expect(find.text('Código fuente'), findsOneWidget);

    await tester.tap(find.text(AppInfo.appName).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('GNU LESSER GENERAL PUBLIC LICENSE'), findsWidgets);
  });
}
