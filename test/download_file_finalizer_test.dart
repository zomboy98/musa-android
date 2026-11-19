import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_file_finalizer.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';
import 'package:mornye/services/ffmpeg_probe.dart';

void main() {
  late Directory directory;
  late List<String> warnings;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download-finalization-');
    warnings = [];
  });
  tearDown(() async => directory.delete(recursive: true));

  DownloadFileFinalizer finalizer({
    DecryptDownloadFile? decrypt,
    ReplaceSafDownloadFile? replaceSaf,
    Future<String?> Function(String)? probe,
    Future<PrimaryAudioProperties> Function(String)? properties,
    Future<void> Function(String, String)? repair,
    Future<Map<String, dynamic>> Function(String)? documentStat,
  }) => DownloadFileFinalizer(
    decryptFile:
        decrypt ??
        ({
          required inputPath,
          required descriptor,
          required deleteOriginal,
          prepareOutput,
        }) async => throw StateError('Unexpected decrypt'),
    replaceSafFile:
        replaceSaf ??
        ({
          required uri,
          required treeUri,
          required relativeDir,
          required op,
          avoidOverwrite = false,
          onPublishedFileName,
        }) async => throw StateError('Unexpected SAF access'),
    probeCodec: probe ?? (_) async => throw StateError('Unexpected probe'),
    probeProperties:
        properties ?? (_) async => throw StateError('Unexpected properties'),
    repairAc4: repair ?? (_, _) async => throw StateError('Unexpected repair'),
    warn: warnings.add,
    info: (_) {},
    readDocumentStat: documentStat ?? (_) async => {},
  );

  DownloadResult encrypted({bool existing = false}) => DownloadResult.fromMap({
    'already_exists': existing,
    'decryption_key': 'abcd',
    'extension_context': {'provider': 'example'},
  });

  Future<DownloadDecryptionOutcome> decrypt(
    DownloadFileFinalizer stage,
    DownloadResult result,
    String path, {
    bool saf = false,
    String? treeUri = 'content://tree',
    bool repair = false,
  }) => stage.decrypt(
    result: result,
    filePath: path,
    useSaf: saf,
    treeUri: treeUri,
    relativeDir: 'Artist/Album',
    baseName: 'Song',
    extensionFallback: '.flac',
    repairContainer: repair,
  );

  test(
    'existing or unencrypted files never enter the transform stages',
    () async {
      for (final result in [
        encrypted(existing: true),
        DownloadResult.fromMap({}),
      ]) {
        final outcome = await decrypt(
          finalizer(),
          result,
          'content://source',
          saf: true,
        );
        expect(outcome.path, 'content://source');
        expect(outcome.failure, isNull);
      }
    },
  );

  test(
    'local AC-4 repair completes before source promotion and stays MP4',
    () async {
      final source = await File(
        '${directory.path}/Song.mp4',
      ).writeAsString('encrypted');
      final output = File('${directory.path}/work.mp4');
      final stage = finalizer(
        decrypt:
            ({
              required inputPath,
              required descriptor,
              required deleteOriginal,
              prepareOutput,
            }) async {
              expect(deleteOriginal, isTrue);
              await output.writeAsString('decrypted');
              await prepareOutput!(output.path);
              await source.delete();
              return (await output.rename(source.path)).path;
            },
        repair: (path, encryptedPath) async {
          expect(await File(encryptedPath).readAsString(), 'encrypted');
          await File(path).writeAsString('repaired');
        },
        probe: (_) async => 'ac4',
      );
      final outcome = await decrypt(
        stage,
        encrypted(),
        source.path,
        repair: true,
      );
      expect(outcome.path, source.path);
      expect(await source.readAsString(), 'repaired');
      expect(await directory.list().length, 1);
    },
  );

  test('normalizes audio-only MP4 without overwriting a sibling', () async {
    final output = await File(
      '${directory.path}/Song.mp4',
    ).writeAsString('audio');
    final stage = finalizer(
      decrypt:
          ({
            required inputPath,
            required descriptor,
            required deleteOriginal,
            prepareOutput,
          }) async => output.path,
      probe: (_) async => 'aac',
    );
    final outcome = await decrypt(stage, encrypted(), output.path);
    expect(outcome.path, '${directory.path}/Song.m4a');
    expect(await File(outcome.path!).readAsString(), 'audio');
    await output.writeAsString('second');
    final collision = await decrypt(stage, encrypted(), output.path);
    expect(collision.path, output.path);
    expect(await File(outcome.path!).readAsString(), 'audio');
    expect(warnings.single, contains('target already exists'));
  });

  test(
    'SAF access, decrypt and publish failures retain distinct outcomes',
    () async {
      for (final failure in DownloadDecryptionFailure.values) {
        final temp = File('${directory.path}/encrypted.flac');
        final output = File('${directory.path}/decrypted.flac');
        final replacer = DownloadSafFileReplacer(
          copyToTemp: (_) async =>
              failure == DownloadDecryptionFailure.safAccess
              ? null
              : (await temp.writeAsString('encrypted')).path,
          publish:
              ({
                required treeUri,
                required relativeDir,
                required fileName,
                required srcPath,
                required avoidOverwrite,
                required preservedSuffix,
                collisionCleanFileName,
                collisionVariantFileName,
              }) async => null,
          deleteSource: (_) async => fail('Source was deleted after failure'),
        );
        final stage = finalizer(
          replaceSaf: replacer.replace,
          decrypt:
              ({
                required inputPath,
                required descriptor,
                required deleteOriginal,
                prepareOutput,
              }) async {
                expect(deleteOriginal, isFalse);
                return failure == DownloadDecryptionFailure.decrypt
                    ? null
                    : (await output.writeAsString('decrypted')).path;
              },
        );
        final outcome = await decrypt(
          stage,
          encrypted(),
          'content://source',
          saf: true,
        );
        expect(outcome.path, isNull);
        expect(outcome.failure, failure);
        expect(await directory.list().length, 0);
      }
      final missingTree = await decrypt(
        finalizer(),
        encrypted(),
        'content://source',
        saf: true,
        treeUri: '',
      );
      expect(missingTree.failure, DownloadDecryptionFailure.safAccess);
    },
  );

  test('SAF filenames come from metadata, with a path-based fallback', () async {
    const opaque =
        'content://com.android.providers.downloads.documents/document/msf%3A1234';
    expect(
      await downloadSourceFileName(
        opaque,
        readDocumentStat: (_) async => {
          'exists': true,
          'display_name': 'Song: Live 100%.flac',
        },
      ),
      'Song: Live 100%.flac',
    );
    expect(
      await downloadSourceFileName(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FSong%3A%20Live.flac',
        readDocumentStat: (_) async => {},
      ),
      'Song: Live.flac',
    );
    for (final invalid in [null, '../escape.flac', 'dir/song.flac']) {
      await expectLater(
        downloadSourceFileName(
          opaque,
          readDocumentStat: (_) async => {'display_name': invalid},
        ),
        throwsFormatException,
      );
    }
    expect(await downloadSourceFileName('/music/Song.flac'), 'Song.flac');
  });
}
