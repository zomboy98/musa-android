import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/shuffle_mode_window.dart';

class _Host extends StatefulWidget {
  const _Host({
    required this.current,
    required this.smartAvailable,
    this.disableAnimations = false,
  });

  final ShuffleStrategy current;
  final bool smartAvailable;
  final bool disableAnimations;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  ShuffleStrategy? picked;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: widget.disableAnimations),
    child: Scaffold(
      body: Center(
        child: Column(
          children: [
            TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                final result = await showShuffleModeWindow(
                  context,
                  current: widget.current,
                  smartAvailable: widget.smartAvailable,
                );
                setState(() => picked = result);
              },
              child: const Text('open'),
            ),
            Text('picked: ${picked?.name}'),
          ],
        ),
      ),
    ),
  );
}

Future<void> _open(
  WidgetTester tester, {
  required bool smart,
  ShuffleStrategy current = ShuffleStrategy.off,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('es'),
      home: _Host(
        current: current,
        smartAvailable: smart,
        disableAnimations: reduceMotion,
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

MediaItem _item(int i, {String? artist, String? album}) => MediaItem(
  id: '$i',
  title: 'Song $i',
  artist: artist ?? 'Artist $i',
  album: album ?? 'Album $i',
);

void main() {
  testWidgets('library and playlists offer random and smart', (tester) async {
    await _open(tester, smart: true);
    expect(find.byKey(const ValueKey('shuffle-option-random')), findsOneWidget);
    expect(find.byKey(const ValueKey('shuffle-option-smart')), findsOneWidget);
    expect(find.text('Aleatorio'), findsWidgets);
    expect(find.text('Mezcla todo al azar'), findsOneWidget);
    expect(find.text('Inteligente'), findsOneWidget);
    expect(
      find.text('Prioriza lo que más escuchas y te redescubre lo olvidado'),
      findsOneWidget,
    );
  });

  testWidgets('albums and artists only offer random', (tester) async {
    await _open(tester, smart: false);
    expect(find.byKey(const ValueKey('shuffle-option-random')), findsOneWidget);
    expect(find.byKey(const ValueKey('shuffle-option-smart')), findsNothing);
  });

  testWidgets('choosing an option returns it and dismissing returns none', (
    tester,
  ) async {
    await _open(tester, smart: true);
    await tester.tap(find.byKey(const ValueKey('shuffle-option-smart')));
    await tester.pumpAndSettle();
    expect(find.text('picked: smart'), findsOneWidget);
    expect(find.byKey(const ValueKey('shuffle-mode-window')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('picked: null'), findsOneWidget);
  });

  testWidgets('touch targets are at least 44 dp and options are semantic', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _open(tester, smart: true, current: ShuffleStrategy.smart);
    for (final key in const ['random', 'smart']) {
      final size = tester.getSize(find.byKey(ValueKey('shuffle-option-$key')));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    expect(
      tester.getSemantics(find.byKey(const ValueKey('shuffle-option-smart'))),
      matchesSemantics(
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
        hasEnabledState: false,
        label:
            'Inteligente. Prioriza lo que más escuchas y te redescubre lo olvidado',
      ),
    );
    semantics.dispose();
  });

  testWidgets('reduced motion shows the window without a transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _Host(
          current: ShuffleStrategy.off,
          smartAvailable: true,
          disableAnimations: true,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    expect(find.byKey(const ValueKey('shuffle-mode-window')), findsOneWidget);
  });

  testWidgets('the icon marks the three states', (tester) async {
    Future<void> show(ShuffleStrategy strategy) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ShuffleStrategyIcon(strategy: strategy, size: 24)),
      ),
    );
    await show(ShuffleStrategy.off);
    expect(find.byType(AppIcon), findsOneWidget);
    await show(ShuffleStrategy.random);
    expect(find.byType(AppIcon), findsOneWidget);
    await show(ShuffleStrategy.smart);
    expect(find.byType(AppIcon), findsNWidgets(2));
  });

  testWidgets('smart is allowed only for mixed queues', (tester) async {
    expect(
      queueAllowsSmartShuffle([for (var i = 0; i < 6; i++) _item(i)]),
      isTrue,
    );
    expect(
      queueAllowsSmartShuffle([
        for (var i = 0; i < 6; i++) _item(i, artist: 'Band', album: 'Record'),
      ]),
      isFalse,
    );
  });

  testWidgets('the state labels announce which shuffle is active', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(
      shuffleStrategyLabel(context, ShuffleStrategy.smart),
      'Aleatorio activado: inteligente',
    );
    expect(
      shuffleStrategyLabel(context, ShuffleStrategy.random),
      'Aleatorio activado: común',
    );
    expect(
      shuffleStrategyLabel(context, ShuffleStrategy.off),
      'Aleatorio desactivado',
    );
  });
}
