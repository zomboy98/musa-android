import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/provider_cooldown_provider.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/widgets/provider_cooldown_panel.dart';

class _MemoryStore implements ProviderCooldownStore {
  @override
  Future<Map<String, int>> readAll() async => {};

  @override
  void write(String key, int value) {}

  @override
  void remove(String key) {}
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'example.amazon',
        name: 'example.amazon',
        displayName: 'Amazon',
        version: '1.0.0',
        description: '',
        enabled: true,
        status: 'loaded',
      ),
    ],
  );
}

Future<void> _pump(WidgetTester tester, ProviderCooldown cooldown) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        providerCooldownServiceProvider.overrideWithValue(cooldown),
        extensionProvider.overrideWith(_Extensions.new),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(child: ProviderCooldownPanel()),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Enfriamiento de proveedores'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('sin enfriamientos muestra el aviso y la explicacion', (
    tester,
  ) async {
    await _pump(tester, ProviderCooldown(store: _MemoryStore()));
    expect(find.text('Ningún proveedor en enfriamiento'), findsOneWidget);
    expect(find.textContaining('quedan en espera, no fallan'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('con enfriamiento muestra nombre y tiempo que baja', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 16, 12);
    final cooldown = ProviderCooldown(clock: () => now, store: _MemoryStore());
    cooldown.note('amazon', 3 * 3600 + 12 * 60);
    await _pump(tester, cooldown);
    final until = now.add(const Duration(hours: 3, minutes: 12)).toLocal();
    final hhmm =
        '${until.hour.toString().padLeft(2, "0")}:${until.minute.toString().padLeft(2, "0")}';
    expect(
      find.text('Amazon · En pausa hasta $hhmm (3 h 12 min)'),
      findsOneWidget,
    );
    expect(find.text('Ningún proveedor en enfriamiento'), findsNothing);
    now = now.add(const Duration(minutes: 12));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('(3 h 0 min)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sin pausa muestra el ultimo fallo con hora y codigo', (
    tester,
  ) async {
    final now = DateTime.now();
    final cooldown = ProviderCooldown(clock: () => now, store: _MemoryStore());
    cooldown.noteAttempts([
      {'provider': 'amazon', 'error_type': 'api_error', 'http_status': 429},
    ]);
    await _pump(tester, cooldown);
    final at = now.toLocal();
    final hhmm =
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    expect(
      find.text('Amazon · Último fallo: api_error a las $hhmm · HTTP 429'),
      findsOneWidget,
    );
    expect(find.textContaining('En pausa'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('con pausa activa manda la pausa sobre el fallo', (tester) async {
    final now = DateTime.now();
    final cooldown = ProviderCooldown(clock: () => now, store: _MemoryStore());
    cooldown.noteAttempts([
      {'provider': 'amazon', 'error_type': 'rate_limit', 'retry_after_s': 600},
    ]);
    await _pump(tester, cooldown);
    expect(find.textContaining('Amazon · En pausa hasta'), findsOneWidget);
    expect(find.textContaining('Último fallo'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('un proveedor sin fallo ni pausa no aparece', (tester) async {
    final cooldown = ProviderCooldown(store: _MemoryStore());
    cooldown.noteAttempts([
      {'provider': 'amazon', 'error_type': ''},
    ]);
    await _pump(tester, cooldown);
    expect(find.textContaining('Amazon'), findsNothing);
    expect(find.text('Ningún proveedor en enfriamiento'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
