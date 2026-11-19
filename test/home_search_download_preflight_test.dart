
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/search_results_fixture.dart';

class _Extensions extends ExtensionNotifier {
  _Extensions({this.extra = const [], this.priority = const []});
  final List<Extension> extra;
  final List<String> priority;
  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    providerPriority: priority,
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasMetadataProvider: true,
        searchBehavior: SearchBehavior(enabled: true),
      ),
      Extension(
        id: 'download',
        name: 'download',
        displayName: 'Download',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
      ...extra,
    ],
  );
}

Extension _download(String id, {bool enabled = true}) => Extension(
  id: id,
  name: id,
  displayName: id,
  version: '1',
  description: '',
  enabled: enabled,
  status: 'loaded',
  hasDownloadProvider: true,
);

// Reemplaza al antiguo "preflight" de búsqueda: la búsqueda ya NO dispara ni
// espera verificaciones de proveedores; solo consulta. La sesión la prepara el
// planificador de fondo (ver provider_session_preparer_test.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'search never queries or opens provider verification and shows no UI',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugDesktopPlatformOverride = false;
      const backend = MethodChannel('com.zarz.mornye/backend');
      const panel = MethodChannel('com.zarz.mornye/verification_panel');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final authLookups = <String>[];
      var panelOpens = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'getExtensionPendingAuth') {
          authLookups.add((call.arguments as Map)['extension_id'] as String);
        }
        return null;
      });
      messenger.setMockMethodCallHandler(panel, (call) async {
        panelOpens++;
        return 'granted';
      });
      try {
      final results = SearchFixtureResults();
      await pumpSearchFixture(
        tester,
        size: const Size(1000, 800),
        mornye: false,
        extensions: _Extensions(
          extra: [_download('second'), _download('third')],
          priority: ['third', 'second', 'download'],
        ),
        results: results,
        settings: const AppSettings(
          searchProvider: 'example',
          defaultService: 'download',
        ),
      );
      for (final text in ['Another', 'Third']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
      }
      expect(results.requestedFilters, hasLength(3));
      expect(find.textContaining('Found'), findsWidgets);
      expect(authLookups, isEmpty, reason: 'search never preflights sessions');
      expect(panelOpens, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox());
      } finally {
        messenger.setMockMethodCallHandler(backend, null);
        messenger.setMockMethodCallHandler(panel, null);
        debugDefaultTargetPlatformOverride = null;
        debugDesktopPlatformOverride = null;
      }
    },
  );
}
