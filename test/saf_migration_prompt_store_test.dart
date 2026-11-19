import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/constants/storage_defaults.dart';
import 'package:mornye/services/saf_migration_prompt_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const store = SafMigrationPromptStore();
  late Directory sandbox;
  late Directory documents;
  late String destination;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('saf-migration-');
    documents = await Directory(p.join(sandbox.path, 'documents')).create();
    destination = p.join(documents.path, defaultDownloadFolderName);
  });

  tearDown(() => sandbox.delete(recursive: true));

  Future<bool> shouldPrompt(String directory, {String mode = 'app'}) async {
    if (!SafMigrationPromptStore.isCandidate(mode, directory)) return false;
    return store.markShownIfNeeded(
      directory,
      storageMode: mode,
      documentsDirectory: () async => documents,
    );
  }

  test('missing private default leaves the prompt available', () async {
    expect(await shouldPrompt(destination), isFalse);
    expect(await Directory(destination).exists(), isFalse);
    expect(await store.wasShown(), isFalse);
    expect(await shouldPrompt(p.join(sandbox.path, 'external')), isTrue);
    expect(await store.wasShown(), isTrue);
  });

  test(
    'existing private default accepts harmless path normalization',
    () async {
      await Directory(destination).create();
      final alias =
          '${documents.path}${p.separator}.${p.separator}'
          '$defaultDownloadFolderName${p.separator}';
      expect(await shouldPrompt(alias), isFalse);
    },
  );

  test('a sibling sharing the private root prefix keeps the prompt', () async {
    expect(
      await shouldPrompt(
        p.join('${documents.path}-external', defaultDownloadFolderName),
      ),
      isTrue,
    );
  });

  test('parent traversal keeps the prompt', () async {
    final traversal =
        '$destination${p.separator}..${p.separator}$defaultDownloadFolderName';
    expect(await shouldPrompt(traversal), isTrue);
  });

  test('a file at the expected destination keeps the prompt', () async {
    await File(destination).create();
    expect(await shouldPrompt(destination), isTrue);
  });

  test('a linked default keeps the prompt', () async {
    final external = await Directory(p.join(sandbox.path, 'external')).create();
    await Link(destination).create(external.path);
    expect(await shouldPrompt(destination), isTrue);
  });

  test('a linked documents directory keeps the prompt', () async {
    await documents.delete();
    final external = await Directory(p.join(sandbox.path, 'external')).create();
    await Link(documents.path).create(external.path);
    expect(await shouldPrompt(destination), isTrue);
  });

  test('a stable alias above the provider directory is allowed', () async {
    final alias = await Link(
      p.join(sandbox.path, 'alias'),
    ).create(sandbox.path);
    documents = Directory(p.join(alias.path, 'documents'));
    expect(
      await shouldPrompt(p.join(documents.path, defaultDownloadFolderName)),
      isFalse,
    );
    await alias.delete();
  });

  test('an unverifiable documents directory keeps the prompt', () async {
    await documents.delete();
    expect(await shouldPrompt(destination), isTrue);
  });

  test('a documents provider error keeps the prompt', () async {
    expect(
      await store.markShownIfNeeded(
        destination,
        storageMode: 'app',
        documentsDirectory: () async => throw FileSystemException('denied'),
      ),
      isTrue,
    );
    expect(await store.wasShown(), isTrue);
  });

  test('a shown prompt is not shown again', () async {
    await store.markShown();
    expect(await shouldPrompt(destination), isFalse);
  });

  test('SAF mode and empty paths leave the flag unset', () async {
    expect(await shouldPrompt(destination, mode: 'saf'), isFalse);
    expect(await shouldPrompt(''), isFalse);
    expect(await store.wasShown(), isFalse);
  });
}
