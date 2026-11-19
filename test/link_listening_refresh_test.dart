import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';
import 'package:mornye/services/link/sync/link_sync_runner.dart';

void main() {
  test('link refresh reloads every active mix history revision', () async {
    final changes = StreamController<int>.broadcast();
    addTearDown(changes.close);
    var loads = 0;
    var revision = 'before';
    final trigger = Provider<void Function()>((ref) {
      return () => refreshLinkListeningProviders(ref);
    });
    final container = ProviderContainer(
      overrides: [
        listeningStatisticsChangesProvider.overrideWith(
          (ref) => changes.stream,
        ),
        libraryMixListeningRevisionLoadProvider.overrideWithValue((
          _,
          __,
          ___,
        ) async {
          loads++;
          return revision;
        }),
      ],
    );
    addTearDown(container.dispose);
    final first = libraryMixListeningRevisionProvider((
      day: '2026-11-06',
      includeLocal: true,
      indexRevision: 'one',
    ));
    final second = libraryMixListeningRevisionProvider((
      day: '2026-11-06',
      includeLocal: false,
      indexRevision: 'two',
    ));
    final a = container.listen(first, (_, _) {});
    final b = container.listen(second, (_, _) {});
    addTearDown(a.close);
    addTearDown(b.close);
    expect(await container.read(first.future), 'before');
    expect(await container.read(second.future), 'before');
    expect(loads, 2);
    revision = 'after';
    container.read(trigger)();
    expect(await container.read(first.future), 'after');
    expect(await container.read(second.future), 'after');
    expect(loads, 4);
  });
}
