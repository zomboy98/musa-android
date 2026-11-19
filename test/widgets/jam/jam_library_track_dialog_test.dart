import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/jam/jam_track_reference.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/widgets/jam/jam_library_app_view.dart';

void main() {
  testWidgets('catalog timeout permits retry and ignores late response', (
    tester,
  ) async {
    final requests = <Completer<List<Track>>>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(false)),
          jamLibraryPageLoaderProvider.overrideWithValue(
            (_) async => const QueueLibraryDbPage(rows: [], nextCursor: null),
          ),
          jamCatalogSearchProvider.overrideWithValue((_) {
            final request = Completer<List<Track>>();
            requests.add(request);
            return request.future;
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(body: JamLibraryTrackDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Catálogo'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'song');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('No se pudo buscar en el catálogo.'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(requests, hasLength(2));
    requests.first.complete(const [
      Track(
        id: '1',
        name: 'Late',
        artistName: 'Artist',
        albumName: '',
        duration: 1,
      ),
    ]);
    requests.last.complete(const [
      Track(
        id: '2',
        name: 'Current',
        artistName: 'Artist',
        albumName: '',
        duration: 1,
      ),
    ]);
    await tester.pump();
    expect(find.text('Late'), findsNothing);
    expect(find.text('Current'), findsOneWidget);
  });
  testWidgets(
    'catalog debounces and ignores stale results; only ISRC can be selected',
    (tester) async {
      final pending = <String, Completer<List<Track>>>{};
      String? selected;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => _Settings(false)),
            jamLibraryPageLoaderProvider.overrideWithValue(
              (_) async => const QueueLibraryDbPage(rows: [], nextCursor: null),
            ),
            jamCatalogSearchProvider.overrideWithValue((query) {
              final result = Completer<List<Track>>();
              pending[query] = result;
              return result.future;
            }),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('es'),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => selected = await showDialog<String>(
                    context: context,
                    builder: (_) => const JamLibraryTrackDialog(),
                  ),
                  child: const Text('Abrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Catálogo'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'old');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump(const Duration(milliseconds: 350));
      expect(pending.keys, ['first']);
      await tester.enterText(find.byType(TextField), 'second');
      await tester.pump(const Duration(milliseconds: 350));
      pending['second']!.complete(const [
        Track(
          id: '1',
          name: 'Eligible',
          artistName: 'Artist',
          albumName: '',
          duration: 1,
          isrc: 'USABC1234567',
        ),
        Track(
          id: '2',
          name: 'Missing',
          artistName: 'Artist',
          albumName: '',
          duration: 1,
        ),
      ]);
      await tester.pump();
      pending['first']!.complete(const [
        Track(
          id: '3',
          name: 'Stale',
          artistName: 'Artist',
          albumName: '',
          duration: 1,
        ),
      ]);
      await tester.pump();
      expect(find.text('Stale'), findsNothing);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Missing'))
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('Eligible'));
      await tester.pumpAndSettle();
      expect(JamTrackReference.tryDecode(selected!)?.isrc, 'USABC1234567');
    },
  );
  testWidgets('host selects a local song without ISRC', (tester) async {
    final item = LocalLibraryItem(
      id: '1',
      trackName: 'Local',
      artistName: 'Artist',
      albumName: '',
      filePath: r'C:\private\song.mp3',
      scannedAt: DateTime(2026),
    );
    PlayableMedia? selected;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(true)),
          jamLibraryPageLoaderProvider.overrideWithValue(
            (_) async => QueueLibraryDbPage(
              rows: [
                {'source': 'local', 'item': item.toJson()},
              ],
              nextCursor: null,
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    selected = await showDialog<PlayableMedia>(
                      context: context,
                      builder: (_) => const JamLibraryTrackDialog(isHost: true),
                    ),
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No compartible'), findsNothing);
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(selected?.source, item.filePath);
    expect(find.textContaining('private'), findsNothing);
  });
  for (final (host, readable) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets('SAF availability host=$host readable=$readable', (
      tester,
    ) async {
      final item = LocalLibraryItem(
        id: 'saf',
        trackName: 'SAF Song',
        artistName: 'Artist',
        albumName: '',
        filePath: 'content://media/audio/1',
        scannedAt: DateTime(2026),
        isrc: 'USABC1234567',
      );
      var probes = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => _Settings(true)),
            jamSafReadProbeProvider.overrideWithValue((_) async {
              probes++;
              return readable;
            }),
            jamLibraryPageLoaderProvider.overrideWithValue(
              (_) async => QueueLibraryDbPage(
                rows: [
                  {'source': 'local', 'item': item.toJson()},
                ],
                nextCursor: null,
              ),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('es'),
            home: Scaffold(body: JamLibraryTrackDialog(isHost: host)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No disponible para el anfitrión'),
        host && !readable ? findsOneWidget : findsNothing,
      );
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'SAF Song'))
            .enabled,
        !host || readable,
      );
      expect(probes, host ? 1 : 0);
    });
  }
  testWidgets('disposing dialog during SAF probe is safe', (tester) async {
    final pending = Completer<bool>();
    final item = LocalLibraryItem(
      id: 'saf',
      trackName: 'SAF Song',
      artistName: 'Artist',
      albumName: '',
      filePath: 'content://media/audio/1',
      scannedAt: DateTime(2026),
      isrc: 'USABC1234567',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(true)),
          jamSafReadProbeProvider.overrideWithValue((_) => pending.future),
          jamLibraryPageLoaderProvider.overrideWithValue(
            (_) async => QueueLibraryDbPage(
              rows: [
                {'source': 'local', 'item': item.toJson()},
              ],
              nextCursor: null,
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(body: JamLibraryTrackDialog(isHost: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Comprobando disponibilidad'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('permission denied'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  for (final enabled in [false, true]) {
    testWidgets('query respects local library setting $enabled', (
      tester,
    ) async {
      bool? includeLocal;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => _Settings(enabled)),
            jamLibraryPageLoaderProvider.overrideWithValue((query) async {
              includeLocal = query.includeLocal;
              return const QueueLibraryDbPage(rows: [], nextCursor: null);
            }),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('es'),
            home: Scaffold(body: JamLibraryTrackDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(includeLocal, enabled);
    });
  }
  testWidgets('searches library rows and returns a safe reference', (
    tester,
  ) async {
    final items = [
      LocalLibraryItem(
        id: '1',
        trackName: 'Luna',
        artistName: 'Sol',
        albumName: 'Cielo',
        filePath: r'C:\private\luna.flac',
        scannedAt: DateTime(2026),
        isrc: 'USABC1234567',
      ),
      LocalLibraryItem(
        id: '2',
        trackName: 'Local',
        artistName: 'Artist',
        albumName: '',
        filePath: r'C:\private\song.mp3',
        scannedAt: DateTime(2026),
      ),
    ];
    String? selected;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(true)),
          jamLibraryPageLoaderProvider.overrideWithValue(
            (query) async => QueueLibraryDbPage(
              nextCursor: null,
              rows: items
                  .where(
                    (item) => item.trackName.toLowerCase().contains(
                      (query.searchQuery ?? '').toLowerCase(),
                    ),
                  )
                  .map((item) => {'source': 'local', 'item': item.toJson()})
                  .toList(),
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showDialog<String>(
                    context: context,
                    builder: (_) => const JamLibraryTrackDialog(),
                  );
                },
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No compartible'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'luna');
    await tester.pumpAndSettle();
    expect(find.text('Local'), findsNothing);
    await tester.tap(find.text('Luna'));
    await tester.pumpAndSettle();
    final reference = JamTrackReference.tryDecode(selected!);
    expect(reference?.title, 'Luna');
    expect(reference?.isrc, 'USABC1234567');
    final payload = utf8.decode(
      base64Url.decode(
        base64Url.normalize(selected!.substring('jamref1:'.length)),
      ),
    );
    expect(payload, isNot(contains('private')));
  });

  testWidgets('reports an empty library', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(false)),
          jamLibraryPageLoaderProvider.overrideWithValue(
            (_) async => const QueueLibraryDbPage(rows: [], nextCursor: null),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(body: JamLibraryTrackDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('La biblioteca está vacía.'), findsOneWidget);
  });
}

class _Settings extends SettingsNotifier {
  _Settings(this.enabled);
  final bool enabled;
  @override
  AppSettings build() => AppSettings(localLibraryEnabled: enabled);
}
