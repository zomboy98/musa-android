import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/extension_collection_screens.dart';

Future<String> _message(
  WidgetTester tester,
  Locale locale,
  Object error,
) async {
  late String result;
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          result = collectionLoadErrorMessage(context, error);
          return const SizedBox();
        },
      ),
    ),
  );
  return result;
}

void main() {
  testWidgets('untyped failure shows the localized generic message', (
    tester,
  ) async {
    final es = await _message(
      tester,
      const Locale('es'),
      Exception('getPlaylist returned null'),
    );
    expect(es, 'No se pudo cargar la lista. Inténtalo de nuevo.');
    expect(es, isNot(contains('getPlaylist')));

    final en = await _message(
      tester,
      const Locale('en'),
      Exception('getPlaylist returned null'),
    );
    expect(en, "Couldn't load the playlist. Try again.");
  });

  testWidgets('verification required keeps its own message', (tester) async {
    final message = await _message(
      tester,
      const Locale('en'),
      Exception('verification_required'),
    );
    expect(message, isNot("Couldn't load the playlist. Try again."));
  });
}
