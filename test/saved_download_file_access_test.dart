import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_queue_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('requires an existing, nonempty readable file', () async {
    final dir = await Directory.systemTemp.createTemp('saved-download-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/track.flac');
    expect(await savedDownloadFileAccessible(file.path), isFalse);
    await file.writeAsBytes([]);
    expect(await savedDownloadFileAccessible(file.path), isFalse);
    await file.writeAsBytes([1, 2, 3]);
    expect(await savedDownloadFileAccessible(file.path), isTrue);
    expect(await savedDownloadFileAccessible(dir.path), isFalse);
    expect(
      await savedDownloadFileAccessible('network://remote/track'),
      isFalse,
    );
  });

  test('SAF needs readable access and a confirmed positive size', () async {
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var canRead = true;
    Object? size = 10;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'safCanOpenRead') return canRead;
      if (call.method == 'safStat') return {'exists': true, 'size': size};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await savedDownloadFileAccessible('content://file'), isTrue);
    size = 0;
    expect(await savedDownloadFileAccessible('content://file'), isFalse);
    size = null;
    expect(await savedDownloadFileAccessible('content://file'), isFalse);
    canRead = false;
    size = 10;
    expect(await savedDownloadFileAccessible('content://file'), isFalse);
  });
}
