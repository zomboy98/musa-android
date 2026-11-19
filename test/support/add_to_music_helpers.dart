import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Taps the row "+" and, in the add-to-music sheet, flips the Library row and
/// confirms: adds the song when it was out of the library, removes it when in.
Future<void> tapSaveToLibrary(WidgetTester tester, {Finder? plus}) async {
  await tester.tap(plus ?? find.byKey(const ValueKey('save-library-track')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.byKey(const ValueKey('add-to-music-library')));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('add-to-music-confirm')));
  await tester.pump();
}

/// Flips the Library row of an already open add-to-music sheet and confirms.
Future<void> confirmLibraryInSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.byKey(const ValueKey('add-to-music-library')));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('add-to-music-confirm')));
  await tester.pump();
}

/// Opens the sheet from the row "+" and closes it with Cancel (no change).
Future<void> tapSaveThenCancel(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('save-library-track')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.byKey(const ValueKey('add-to-music-cancel')));
  await tester.pumpAndSettle();
}
