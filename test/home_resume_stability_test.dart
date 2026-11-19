import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Extension source({String status = 'loaded'}) => Extension(
  id: 'A',
  name: 'A',
  displayName: 'A',
  version: '1',
  description: '',
  enabled: true,
  status: status,
  hasMetadataProvider: true,
  searchBehavior: const SearchBehavior(
    enabled: true,
    filters: [SearchFilter(id: 'albums')],
  ),
);

class MutableExtensions extends ExtensionNotifier {
  MutableExtensions(this.initial);
  final List<Extension> initial;
  @override
  ExtensionState build() => ExtensionState(extensions: initial);

  /// What a health check or a session renewal does when the app resumes: the
  /// list changes, the providers that qualify do not.
  void replace(List<Extension> items) =>
      state = state.copyWith(extensions: items);
}

const channel = MethodChannel('com.zarz.mornye/backend');

Future<void> resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump(const Duration(minutes: 20));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets(
    'Top Picks stay loaded through pause, resume and an extension list change',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final reader = <String>[];
      final slow = Completer<List<ExploreSection>?>();
      final container = ProviderContainer(
        overrides: [
          homeTopPicksClockProvider.overrideWithValue(
            () => DateTime(2026, 11, 8),
          ),
          homeTopPicksExtensionProvider.overrideWithValue('A'),
          extensionProvider.overrideWith(() => MutableExtensions([source()])),
          homeTopPicksFeedReaderProvider.overrideWithValue((id) async {
            reader.add(id);
            if (reader.length > 1) return slow.future;
            return [
              ExploreSection(
                uri: 'feed',
                title: 'Playlists',
                items: [
                  ExploreItem(
                    id: 'p1',
                    uri: 'p1',
                    type: 'playlist',
                    name: 'Playlist',
                    artists: '',
                    coverUrl: 'https://example.com/a.png',
                  ),
                ],
              ),
            ];
          }),
        ],
      );
      addTearDown(container.dispose);
      final seen = <AsyncValue<List<ExploreItem>>>[];
      final subscription = container.listen(
        homeTopPicksProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await tester.pump();
      await tester.pump();
      expect(container.read(homeTopPicksProvider).value, isNotEmpty);
      seen.clear();

      await resume(tester);
      (container.read(extensionProvider.notifier) as MutableExtensions).replace(
        [source(status: 'loaded ')],
      );
      await tester.pump();
      await tester.pump();

      expect(seen.where((value) => value.isLoading), isEmpty);
      expect(container.read(homeTopPicksProvider).value, isNotEmpty);
      // A real reload (explicit refresh, reader pending): still no gap.
      container.read(homeTopPicksRefreshProvider.notifier).state++;
      await tester.pump();
      await tester.pump();
      final reloading = container.read(homeTopPicksProvider);
      expect(reloading.isLoading, isTrue, reason: 'the reload is running');
      expect(topPickPlaylistsOf(reloading), isNotEmpty);
      slow.complete(null);
      subscription.close();
      container.dispose();
    },
  );
}
