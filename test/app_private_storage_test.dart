import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/app_private_storage.dart';

void main() {
  const roots = ['/data/user/0/org.demo.app'];

  test('private storage is recognised under either data spelling', () {
    expect(
      isAppPrivateStoragePath(
        '/data/user/0/org.demo.app/app_flutter/MUSA',
        roots,
      ),
      isTrue,
    );
    expect(
      isAppPrivateStoragePath(
        '/data/data/org.demo.app/app_flutter/MUSA',
        roots,
      ),
      isTrue,
    );
    expect(
      isAppPrivateStoragePath('/storage/emulated/0/Music/MUSA', roots),
      isFalse,
    );
    expect(
      isAppPrivateStoragePath('/data/user/0/org.demo.apple/x', roots),
      isFalse,
    );
  });

  test('only the exact private download folder counts as the old default', () {
    const folders = ['/data/user/0/org.demo.app/app_flutter/MUSA'];
    expect(
      isAppPrivateDownloadFolder(
        '/data/user/0/org.demo.app/app_flutter/MUSA/',
        folders,
      ),
      isTrue,
    );
    expect(
      isAppPrivateDownloadFolder(
        '/data/data/org.demo.app/app_flutter/MUSA',
        folders,
      ),
      isTrue,
    );
    expect(
      isAppPrivateDownloadFolder(
        '/data/user/0/org.demo.app/app_flutter/MUSA/Mine',
        folders,
      ),
      isFalse,
    );
    expect(isAppPrivateDownloadFolder('', folders), isFalse);
  });

  test('private storage folders derive from the app directories', () async {
    final storage = AppPrivateStorage(
      documentsDirectory: () async => '/data/user/0/org.demo.app/app_flutter',
      externalDirectory: () async =>
          '/storage/emulated/0/Android/data/org.demo.app/files',
    );
    expect(await storage.downloadFolders(), [
      '/data/user/0/org.demo.app/app_flutter/MUSA',
      '/storage/emulated/0/Android/data/org.demo.app/files/MUSA',
    ]);
    expect(await storage.roots(), [
      '/data/user/0/org.demo.app',
      '/storage/emulated/0/Android/data/org.demo.app',
    ]);
  });

  group('default download directory', () {
    final shared = Directory('/storage/emulated/0/Music/MUSA');
    final private = Directory('/data/user/0/org.demo.app/app_flutter/MUSA');

    test('denied access falls back to private storage', () async {
      final resolved = await resolveDefaultDownloadDirectory(
        sharedDefault: () async => shared,
        privateDefault: () async => private,
        isWritable: (_) async => false,
      );
      expect(resolved.directory.path, private.path);
      expect(resolved.privateFallback, isTrue);
    });

    test('a shared folder that throws also falls back', () async {
      final resolved = await resolveDefaultDownloadDirectory(
        sharedDefault: () async => throw const FileSystemException('denied'),
        privateDefault: () async => private,
        isWritable: (_) async => true,
      );
      expect(resolved.privateFallback, isTrue);
    });

    test('granted access uses Music/MUSA again', () async {
      var granted = false;
      Future<DefaultDownloadDirectory> resolve() =>
          resolveDefaultDownloadDirectory(
            sharedDefault: () async => shared,
            privateDefault: () async => private,
            isWritable: (_) async => granted,
          );
      expect((await resolve()).directory.path, private.path);
      granted = true;
      final resolved = await resolve();
      expect(resolved.directory.path, shared.path);
      expect(resolved.privateFallback, isFalse);
    });
  });

  group('queue hold for the access prompt', () {
    bool hold({
      bool isAndroid = true,
      bool safMode = false,
      bool networkOnly = false,
      bool customFolder = false,
      bool granted = false,
      bool answered = false,
    }) => shouldHoldQueueForStorageAccess(
      isAndroid: isAndroid,
      safMode: safMode,
      networkOnly: networkOnly,
      customFolder: customFolder,
      granted: granted,
      answered: answered,
    );

    test('waits only until the user has been asked', () {
      expect(hold(), isTrue);
      expect(hold(answered: true), isFalse);
      expect(hold(granted: true), isFalse);
    });

    test('never blocks other destinations or platforms', () {
      expect(hold(isAndroid: false), isFalse);
      expect(hold(safMode: true), isFalse);
      expect(hold(networkOnly: true), isFalse);
      expect(hold(customFolder: true), isFalse);
    });
  });
}
