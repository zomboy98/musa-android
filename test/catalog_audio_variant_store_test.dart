import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/catalog_audio_store.dart';

void main() {
  test(
    'promotion copies the selected variant and preserves active leases',
    () async {
      final root = await Directory.systemTemp.createTemp('musa-variant-store-');
      addTearDown(() => root.delete(recursive: true));
      CatalogAudioStore makeStore() => CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      final store = makeStore();
      await store.initialize();
      final first = await File('${root.path}/first').writeAsString('aac-128');
      final second = await File('${root.path}/second').writeAsString('aac-256');
      final low = await store.putTemporary(
        'track/aac/128',
        first,
        extension: '.m4a',
      );
      final lease = (await store.acquire('track/aac/128'))!;
      final high = await store.putTemporary(
        'track/aac/256',
        second,
        extension: '.m4a',
      );

      final promoted = await store.promoteVariant('track', 'track/aac/128');
      expect(promoted?.persistent, isTrue);
      expect(await File(promoted!.path).readAsString(), 'aac-128');
      expect(await File(lease.path).readAsString(), 'aac-128');
      expect(await File(high.path).readAsString(), 'aac-256');
      expect(low.path, lease.path);

      // The saved copy is authoritative and must never be replaced by a later
      // completion for a different playback profile.
      final again = await store.promoteVariant('track', 'track/aac/256');
      expect(again?.path, promoted.path);
      await lease.release();
      final restarted = makeStore();
      await restarted.initialize();
      expect(
        await File((await restarted.lookup('track'))!.path).readAsString(),
        'aac-128',
      );
      expect(
        await File(
          (await restarted.lookup('track/aac/256'))!.path,
        ).readAsString(),
        'aac-256',
      );
    },
  );
}
