import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/saf_attempt_cleanup.dart';
import 'package:path/path.dart' as p;

void main() {
  const id = 'f1f2920b-a39b-42b7-8bf2-df0a1196063b';
  test(
    'canonical native attempt works under an aliased support path',
    () async {
      final base = await Directory.systemTemp.createTemp('saf-anchor-alias-');
      addTearDown(() => base.delete(recursive: true));
      final support = await Directory(p.join(base.path, 'support')).create();
      final alias = Link(p.join(base.path, 'alias'));
      try {
        await alias.create(support.path);
      } on FileSystemException catch (error) {
        if (Platform.isWindows && error.osError?.errorCode == 1314) {
          markTestSkipped('Windows host lacks symlink privilege');
          return;
        }
        rethrow;
      }
      final attempt = await Directory(
        p.join(await support.resolveSymbolicLinks(), 'native-saf-attempts', id),
      ).create(recursive: true);
      final output = await File(
        p.join(attempt.path, 'output.flac'),
      ).writeAsString('fixture');
      final calls = <String>[];
      expect(
        await withTransferredSafHookGrant<String>(
          marker: attempt.path,
          applicationSupportDirectory: alias.path,
          sourcePath: output.path,
          acquire: (path) async {
            expect(path, attempt.path);
            calls.add('acquire');
            return 'fixture-token';
          },
          release: (token) async {
            expect(token, 'fixture-token');
            calls.add('release');
          },
          run: () async => 'processed',
        ),
        'processed',
      );
      expect(calls, ['acquire', 'release']);
      expect(
        await deleteTransferredSafAttemptOutput(
          marker: attempt.path,
          applicationSupportDirectory: alias.path,
          sourcePath: output.path,
        ),
        isTrue,
      );
      expect(
        await cleanupTransferredSafAttemptDirectory(
          marker: attempt.path,
          applicationSupportDirectory: alias.path,
        ),
        isTrue,
      );
      expect(await support.exists(), isTrue);
    },
  );
  test(
    'hook grant is confined, available during invocation, and always revoked',
    () async {
      final support = await Directory.systemTemp.createTemp('saf-hook-grant-');
      addTearDown(() => support.delete(recursive: true));
      final attempt = await Directory(
        p.join(support.path, 'native-saf-attempts', id),
      ).create(recursive: true);
      final owned = File(p.join(attempt.path, 'output.flac'));
      final external = File(p.join(support.path, 'external.flac'));
      await owned.writeAsString('owned');
      await external.writeAsString('external');
      final events = <String>[];
      var granted = false;
      Future<String> invoke(String source, {bool fail = false}) =>
          withTransferredSafHookGrant<String>(
            marker: attempt.path,
            applicationSupportDirectory: support.path,
            sourcePath: source,
            acquire: (directory) async {
              expect(directory, attempt.path);
              granted = true;
              events.add('acquire');
              return 'scoped-token';
            },
            release: (token) async {
              expect(token, 'scoped-token');
              granted = false;
              events.add('release');
            },
            run: () async {
              expect(granted, isTrue);
              events.add('run');
              if (fail) throw StateError('hook failed or cancelled');
              return 'completed';
            },
          );
      await expectLater(invoke(external.path), throwsStateError);
      expect(events, isEmpty);
      expect(await invoke(owned.path), 'completed');
      expect(events, ['acquire', 'run', 'release']);
      expect(granted, isFalse);
      events.clear();
      await expectLater(invoke(owned.path, fail: true), throwsStateError);
      expect(events, ['acquire', 'run', 'release']);
      expect(granted, isFalse);
      expect(await external.readAsString(), 'external');
      expect(await owned.readAsString(), 'owned');
    },
  );
  test('external hook and cancellation never retire either source', () async {
    final support = await Directory.systemTemp.createTemp('saf-hook-cancel-');
    addTearDown(() => support.delete(recursive: true));
    final attempt = await Directory(
      p.join(support.path, 'native-saf-attempts', id),
    ).create(recursive: true);
    final original = File(p.join(attempt.path, 'output.flac'));
    final replacement = File(p.join(attempt.path, 'replacement.flac'));
    final external = File(p.join(support.path, 'library.flac'));
    await original.writeAsString('original attempt');
    await replacement.writeAsString('hook replacement');
    await external.writeAsString('existing library');
    Future<bool> accept(String path, bool Function() cancelled) =>
        acceptTransferredSafHookOutput(
          marker: attempt.path,
          applicationSupportDirectory: support.path,
          sourcePath: path,
          shouldAbort: cancelled,
        );
    expect(await accept(external.path, () => false), isFalse);
    expect(await accept(external.path, () => true), isFalse);
    expect(await accept(replacement.path, () => true), isFalse);
    var checks = 0;
    expect(await accept(replacement.path, () => ++checks >= 2), isFalse);
    expect(checks, 2);
    expect(await original.readAsString(), 'original attempt');
    expect(await replacement.readAsString(), 'hook replacement');
    expect(await external.readAsString(), 'existing library');
    expect(await accept(replacement.path, () => false), isTrue);
  });
  test(
    'source deletion needs host ownership and confines every file',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'saf-owned-source-',
      );
      addTearDown(() => support.delete(recursive: true));
      final attempt = await Directory(
        p.join(support.path, 'native-saf-attempts', id),
      ).create(recursive: true);
      final external = File(p.join(support.path, 'library.flac'));
      await external.writeAsString('external library audio');
      final owned = File(p.join(attempt.path, 'output.flac'));
      await owned.writeAsString('attempt output');
      Future<bool> remove(String marker, String source) =>
          deleteTransferredSafAttemptOutput(
            marker: marker,
            applicationSupportDirectory: support.path,
            sourcePath: source,
          );
      expect(await remove(attempt.path, external.path), isFalse);
      expect(await remove('', owned.path), isFalse);
      expect(await remove(support.path, external.path), isFalse);
      expect(await external.readAsString(), 'external library audio');
      expect(await owned.readAsString(), 'attempt output');
      expect(await remove(attempt.path, owned.path), isTrue);
      expect(await owned.exists(), isFalse);
      expect(await external.readAsString(), 'external library audio');
    },
  );

  test('source symlink cannot authorize deletion of external audio', () async {
    final support = await Directory.systemTemp.createTemp(
      'saf-owned-source-link-',
    );
    addTearDown(() => support.delete(recursive: true));
    final attempt = await Directory(
      p.join(support.path, 'native-saf-attempts', id),
    ).create(recursive: true);
    final external = File(p.join(support.path, 'library.flac'));
    await external.writeAsString('external audio');
    final link = Link(p.join(attempt.path, 'output.flac'));
    try {
      await link.create(external.path);
    } on FileSystemException catch (error) {
      if (Platform.isWindows && error.osError?.errorCode == 1314) {
        markTestSkipped('Windows host lacks symlink privilege');
        return;
      }
      rethrow;
    }
    expect(
      await deleteTransferredSafAttemptOutput(
        marker: attempt.path,
        applicationSupportDirectory: support.path,
        sourcePath: link.path,
      ),
      isFalse,
    );
    expect(await external.readAsString(), 'external audio');
    expect(await link.exists(), isTrue);
    await link.delete();
  });
  test('symlink attempt never authorizes removal of its target', () async {
    final support = await Directory.systemTemp.createTemp('saf-cleanup-link-');
    addTearDown(() => support.delete(recursive: true));
    final root = await Directory(
      p.join(support.path, 'native-saf-attempts'),
    ).create();
    final outside = await Directory(p.join(support.path, 'unrelated')).create();
    final link = Link(p.join(root.path, id));
    try {
      await link.create(outside.path);
    } on FileSystemException catch (error) {
      if (Platform.isWindows && error.osError?.errorCode == 1314) {
        markTestSkipped('Windows host lacks symlink privilege');
        return;
      }
      rethrow;
    }
    expect(
      await cleanupTransferredSafAttemptDirectory(
        marker: link.path,
        applicationSupportDirectory: support.path,
      ),
      isFalse,
    );
    expect(await link.exists(), isTrue);
    expect(await outside.exists(), isTrue);
    await link.delete();
  });

  test('symlink workspace root never authorizes an external attempt', () async {
    final support = await Directory.systemTemp.createTemp(
      'saf-cleanup-root-link-',
    );
    addTearDown(() => support.delete(recursive: true));
    final outside = await Directory(
      p.join(support.path, 'unrelated', id),
    ).create(recursive: true);
    final root = Link(p.join(support.path, 'native-saf-attempts'));
    try {
      await root.create(outside.parent.path);
    } on FileSystemException catch (error) {
      if (Platform.isWindows && error.osError?.errorCode == 1314) {
        markTestSkipped('Windows host lacks symlink privilege');
        return;
      }
      rethrow;
    }
    expect(
      await cleanupTransferredSafAttemptDirectory(
        marker: p.join(root.path, id),
        applicationSupportDirectory: support.path,
      ),
      isFalse,
    );
    expect(
      await cleanupTransferredSafAttemptDirectory(
        marker: await outside.resolveSymbolicLinks(),
        applicationSupportDirectory: support.path,
      ),
      isFalse,
    );
    expect(await outside.exists(), isTrue);
    expect(await root.exists(), isTrue);
    await root.delete();
  });
  test('only an empty direct owned attempt can be retired', () async {
    final support = await Directory.systemTemp.createTemp('saf-cleanup-');
    addTearDown(() => support.delete(recursive: true));
    final attempt = await Directory(
      p.join(support.path, 'native-saf-attempts', id),
    ).create(recursive: true);
    final output = File(p.join(attempt.path, 'output.flac'));
    await output.writeAsString('active or unrelated content');
    Future<bool> clean(String marker) => cleanupTransferredSafAttemptDirectory(
      marker: marker,
      applicationSupportDirectory: support.path,
    );
    expect(await clean(attempt.path), isFalse);
    expect(await output.readAsString(), 'active or unrelated content');
    await output.delete();
    expect(await clean(attempt.path), isTrue);
    expect(await attempt.exists(), isFalse);
    expect(await Directory(p.dirname(attempt.path)).exists(), isTrue);
  });

  test(
    'outside roots, unowned names, nested and traversal markers are preserved',
    () async {
      final support = await Directory.systemTemp.createTemp('saf-cleanup-');
      addTearDown(() => support.delete(recursive: true));
      final root = await Directory(
        p.join(support.path, 'native-saf-attempts'),
      ).create();
      for (final path in [
        p.join(support.path, id),
        p.join(root.path, 'unowned'),
        p.join(root.path, id, id),
      ]) {
        final directory = await Directory(path).create(recursive: true);
        expect(
          await cleanupTransferredSafAttemptDirectory(
            marker: path,
            applicationSupportDirectory: support.path,
          ),
          isFalse,
        );
        expect(await directory.exists(), isTrue);
      }
      final traversal = '${root.path}${p.separator}..${p.separator}$id';
      expect(
        await cleanupTransferredSafAttemptDirectory(
          marker: traversal,
          applicationSupportDirectory: support.path,
        ),
        isFalse,
      );
    },
  );
}
