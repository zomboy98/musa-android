import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/storage_access_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Gateway implements AllFilesAccessGateway {
  _Gateway({this.supported = true});

  @override
  final bool supported;
  bool granted = false;
  AllFilesAccessResult nextResult = AllFilesAccessResult.denied;
  int reads = 0;
  int requests = 0;

  @override
  Future<bool> isGranted() async {
    reads++;
    return granted;
  }

  @override
  Future<AllFilesAccessResult> request() async {
    requests++;
    if (nextResult == AllFilesAccessResult.granted) granted = true;
    return nextResult;
  }
}

class _Settings extends SettingsNotifier {
  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger = binding.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(secure, (call) async => null);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => messenger.setMockMethodCallHandler(secure, null));

  ProviderContainer make(_Gateway gateway) {
    final container = ProviderContainer(
      overrides: [
        allFilesAccessGatewayProvider.overrideWithValue(gateway),
        settingsProvider.overrideWith(_Settings.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('nothing is asked where the permission does not exist', () async {
    final container = make(_Gateway(supported: false));
    final state = container.read(storageAccessProvider);
    expect(state.supported, isFalse);
    expect(state.granted, isTrue);
    expect(state.answered, isTrue);
    container.read(storageAccessProvider.notifier).requestPrompt();
    expect(container.read(storageAccessProvider).promptRequested, isFalse);
  });

  test('a denied install is asked once and remembers the answer', () async {
    final gateway = _Gateway();
    final container = make(gateway);
    final access = container.read(storageAccessProvider.notifier);
    await access.ensureLoaded();
    expect(container.read(storageAccessProvider).granted, isFalse);
    expect(container.read(storageAccessProvider).answered, isFalse);

    await access.promptIfNeeded();
    expect(container.read(storageAccessProvider).promptRequested, isTrue);

    await access.decline();
    var state = container.read(storageAccessProvider);
    expect(state.answered, isTrue);
    expect(state.promptRequested, isFalse);
    expect(state.granted, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        StorageAccessNotifier.askedKey,
      ),
      isTrue,
    );

    await access.promptIfNeeded();
    expect(container.read(storageAccessProvider).promptRequested, isFalse);

    final again = make(_Gateway());
    await again.read(storageAccessProvider.notifier).ensureLoaded();
    state = again.read(storageAccessProvider);
    expect(state.answered, isTrue);
  });

  test('allowing records the access and the settings flag', () async {
    final gateway = _Gateway()..nextResult = AllFilesAccessResult.granted;
    final container = make(gateway);
    container.read(settingsProvider);
    await container.read(settingsProvider.notifier).ensureLoaded();
    final access = container.read(storageAccessProvider.notifier);

    final result = await access.request();

    expect(result, AllFilesAccessResult.granted);
    expect(container.read(storageAccessProvider).granted, isTrue);
    expect(container.read(storageAccessProvider).answered, isTrue);
    expect(container.read(settingsProvider).useAllFilesAccess, isTrue);
  });

  test('returning to the app reads the permission again', () async {
    final gateway = _Gateway();
    final container = make(gateway);
    container.listen(storageAccessProvider, (_, _) {});
    await container.read(storageAccessProvider.notifier).ensureLoaded();
    expect(container.read(storageAccessProvider).granted, isFalse);
    final readsBefore = gateway.reads;

    gateway.granted = true;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(gateway.reads, greaterThan(readsBefore));
    expect(container.read(storageAccessProvider).granted, isTrue);
  });

  test('the private stand-in flag is tracked for the warning', () async {
    final container = make(_Gateway());
    final access = container.read(storageAccessProvider.notifier);
    await access.ensureLoaded();
    access.setUsingPrivateFallback(true);
    expect(container.read(storageAccessProvider).usingPrivateFallback, isTrue);
    access.setUsingPrivateFallback(false);
    expect(container.read(storageAccessProvider).usingPrivateFallback, isFalse);
  });
}
