import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/plugin_code_provider.dart';
import 'package:mornye/services/plugin_code_service.dart';
import 'package:mornye/widgets/plugin_code_card.dart';

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

class _Fixture {
  _Fixture(this.temp, {int count = 8}) {
    for (var i = 1; i <= count; i++) {
      bodies['p$i'] = utf8.encode('package-$i');
    }
  }

  final Directory temp;
  final Map<String, List<int>> bodies = {};
  final List<String> order = [];
  final Map<String, Future<bool> Function(String path)> behaviors = {};

  Future<http.Response> handler(http.Request request) async {
    if (request.url.host == 'musa-api.heyshin.app') {
      return http.Response(
        jsonEncode({
          'name': 'Pack',
          'items': [
            for (final entry in bodies.entries)
              {
                'id': entry.key,
                'name': 'Item ${entry.key.substring(1)}',
                'version': '1.0.0',
                'url': 'https://files.example.com/${entry.key}.mornye-ext',
                'sha256': _hash(entry.value),
              },
          ],
        }),
        200,
      );
    }
    final id = request.url.path.substring(1).split('.').first;
    return http.Response.bytes(bodies[id]!, 200);
  }

  PluginCodeInstaller installer(Map<String, String>? versions) =>
      PluginCodeInstaller(
        prepare: () async {},
        installedVersions: () => versions ?? const {},
        install: (path) {
          final id = path.split(RegExp(r'[\\/]')).last.split('.').first;
          order.add(id);
          return (behaviors[id] ?? (_) async => true)(path);
        },
        upgrade: (path) async => true,
        finish: () {},
      );

  ProviderContainer container({Map<String, String>? versions}) {
    final c = ProviderContainer(
      overrides: [
        pluginCodeServiceProvider.overrideWithValue(
          PluginCodeService(client: MockClient(handler), tempRoot: temp),
        ),
        pluginCodeInstallerProvider.overrideWithValue(installer(versions)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plugin_redeem_test_');
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } catch (_) {}
  });

  test('one redeem processes all 8 items in order and reports each', () async {
    final fixture = _Fixture(temp);
    final container = fixture.container();
    final seen = <int>[];
    container.listen(pluginCodeRedeemProvider, (previous, next) {
      if (next.running && next.current != 0 && !seen.contains(next.current)) {
        seen.add(next.current);
      }
    });
    final notifier = container.read(pluginCodeRedeemProvider.notifier);
    notifier.setInput('9r2-wuh');
    await notifier.redeem();
    final state = container.read(pluginCodeRedeemProvider);
    expect(state.phase, PluginCodePhase.done);
    expect(fixture.order, [for (var i = 1; i <= 8; i++) 'p$i']);
    expect(state.results.length, 8);
    expect(
      state.results.every((r) => r.outcome == PluginCodeOutcome.added),
      isTrue,
    );
    expect(seen, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(state.total, 8);
    expect(state.input, isEmpty);
  });

  test('an installer error in one item does not stop the others', () async {
    final fixture = _Fixture(temp);
    fixture.behaviors['p3'] = (_) async => throw StateError('boom');
    fixture.behaviors['p5'] = (_) async => false;
    final container = fixture.container();
    final notifier = container.read(pluginCodeRedeemProvider.notifier);
    notifier.setInput('9R2-WUH');
    await notifier.redeem();
    final state = container.read(pluginCodeRedeemProvider);
    expect(fixture.order.length, 8);
    expect(state.results[2].outcome, PluginCodeOutcome.failed);
    expect(state.results[2].failure, PluginCodeFailure.installFailed);
    expect(state.results[4].outcome, PluginCodeOutcome.failed);
    expect(
      state.results.where((r) => r.outcome == PluginCodeOutcome.added),
      hasLength(6),
    );
  });

  test('an item slower than the maximum is marked and skipped', () async {
    final fixture = _Fixture(temp);
    final never = Completer<bool>();
    fixture.behaviors['p2'] = (_) => never.future;
    final container = fixture.container();
    final notifier = container.read(pluginCodeRedeemProvider.notifier);
    notifier.setInput('9R2-WUH');
    await notifier.redeem(itemTimeout: const Duration(milliseconds: 50));
    final state = container.read(pluginCodeRedeemProvider);
    expect(state.phase, PluginCodePhase.done);
    expect(fixture.order.length, 8);
    expect(state.results[1].outcome, PluginCodeOutcome.failed);
    expect(state.results[1].failure, PluginCodeFailure.timeout);
    expect(
      state.results.where((r) => r.outcome == PluginCodeOutcome.added),
      hasLength(7),
    );
  });

  test('same-version items are reported as already added', () async {
    final fixture = _Fixture(temp, count: 3);
    final container = fixture.container(versions: {'p1': '1.0.0'});
    final notifier = container.read(pluginCodeRedeemProvider.notifier);
    notifier.setInput('ABCD');
    await notifier.redeem();
    final state = container.read(pluginCodeRedeemProvider);
    expect(state.results.first.outcome, PluginCodeOutcome.alreadyAdded);
    expect(fixture.order, ['p2', 'p3']);
  });

  test('a second call while running joins the same run', () async {
    final fixture = _Fixture(temp, count: 2);
    final gate = Completer<bool>();
    fixture.behaviors['p1'] = (_) => gate.future;
    final container = fixture.container();
    final notifier = container.read(pluginCodeRedeemProvider.notifier);
    notifier.setInput('ABCD');
    final first = notifier.redeem();
    final second = notifier.redeem();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(pluginCodeRedeemProvider).running, isTrue);
    gate.complete(true);
    await Future.wait([first, second]);
    expect(fixture.order, ['p1', 'p2']);
  });

  test('an invalid code fails without touching the network', () async {
    final fixture = _Fixture(temp);
    final container = fixture.container();
    final notifier = container.read(pluginCodeRedeemProvider.notifier);
    notifier.setInput('x');
    await notifier.redeem();
    final state = container.read(pluginCodeRedeemProvider);
    expect(state.phase, PluginCodePhase.failed);
    expect(state.failure, PluginCodeFailure.invalidFormat);
    expect(state.input, 'x');
    expect(fixture.order, isEmpty);
  });

  testWidgets('rebuilding or removing the card does not stop the run', (
    tester,
  ) async {
    final fixture = _Fixture(temp);
    final gates = <String, Completer<bool>>{
      for (var i = 1; i <= 8; i++) 'p$i': Completer<bool>(),
    };
    for (final entry in gates.entries) {
      fixture.behaviors[entry.key] = (_) => entry.value.future;
    }
    final container = fixture.container();
    addTearDown(() {
      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete(true);
      }
    });

    Future<void> pumpCard(Widget child) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );

    Future<void> settle(int ms) async {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)),
      );
      await tester.pump();
    }

    await pumpCard(const PluginCodeCard());
    await tester.enterText(
      find.byKey(const ValueKey('plugin-code-field')),
      '9R2-WUH',
    );
    await tester.runAsync(() async {
      unawaited(container.read(pluginCodeRedeemProvider.notifier).redeem());
    });
    await settle(300);
    await tester.pump();
    expect(find.text('Añadiendo 1 de 8…'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('plugin-code-add')))
          .onPressed,
      isNull,
    );

    await pumpCard(const SizedBox());
    await tester.runAsync(() async => gates['p1']!.complete(true));
    await settle(300);
    expect(container.read(pluginCodeRedeemProvider).current, 2);

    await pumpCard(const PluginCodeCard());
    await tester.pump();
    expect(find.text('Añadiendo 2 de 8…'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('plugin-code-field')))
          .controller!
          .text,
      '9R2-WUH',
    );

    await tester.runAsync(() async {
      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete(true);
      }
    });
    for (var i = 0; i < 40; i++) {
      if (container.read(pluginCodeRedeemProvider).phase ==
          PluginCodePhase.done) {
        break;
      }
      await settle(100);
    }
    await tester.pump();
    expect(fixture.order.length, 8);
    expect(find.byKey(const ValueKey('plugin-code-results')), findsOneWidget);
    expect(find.text('Añadido: Item 1'), findsOneWidget);
    expect(find.text('Añadido: Item 8'), findsOneWidget);
  });
}
