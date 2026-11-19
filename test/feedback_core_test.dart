import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/feedback/feedback_diagnostics.dart';
import 'package:mornye/services/feedback/feedback_package.dart';
import 'package:mornye/services/feedback/feedback_sanitizer.dart';
import 'package:mornye/services/feedback/feedback_store.dart';
import 'package:mornye/services/feedback/feedback_transport.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory temp;
  late FeedbackStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('musa_feedback_test');
    store = FeedbackStore(root: () async => Directory(p.join(temp.path, 'fb')));
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a thread survives a JSON round trip', () {
    final thread = FeedbackThread(
      id: 'a',
      createdAt: DateTime.utc(2026, 1, 2, 3),
      kind: FeedbackKind.design,
      text: 'hola',
      screen: '/x',
      attachments: const ['captura-1.png'],
      diagnostics: 'diag',
      status: FeedbackStatus.fixed,
      fixedInVersion: '5.4',
      comments: [
        FeedbackComment(
          id: 'c',
          createdAt: DateTime.utc(2026, 1, 2),
          text: 'nota',
          remoteId: 9,
        ),
      ],
      issueNumber: 12,
      issueUrl: 'https://github.com/zomboy98/MUSA/issues/12',
      pendingSend: true,
    );
    final back = FeedbackThread.fromJson(
      jsonDecode(jsonEncode(thread.toJson())),
    )!;
    expect(back.kind, FeedbackKind.design);
    expect(back.status, FeedbackStatus.fixed);
    expect(back.fixedInVersion, '5.4');
    expect(back.comments.single.remoteId, 9);
    expect(back.issueNumber, 12);
    expect(back.pendingSend, isTrue);
    expect(FeedbackThread.fromJson({'id': 'x'}), isNull);
  });

  test(
    'the store persists threads, status, comments and attachments',
    () async {
      final thread = await store.create(
        kind: FeedbackKind.bug,
        text: 'Se corta la cancion',
        screen: 'Reproductor',
        images: [
          FeedbackImage(
            name: 'IMG_privada.JPG',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ],
      );
      expect(thread.attachments, ['captura-1.jpg']);
      final fixed = await store.setStatus(
        thread,
        FeedbackStatus.fixed,
        fixedInVersion: '5.4',
      );
      await store.addComment(fixed, 'Sigue pasando');
      final listed = await store.list();
      expect(listed, hasLength(1));
      expect(listed.single.status, FeedbackStatus.fixed);
      expect(listed.single.fixedInVersion, '5.4');
      expect(listed.single.comments.single.text, 'Sigue pasando');
      final file = await store.attachmentFile(listed.single, 'captura-1.jpg');
      expect(await file.exists(), isTrue);
      final reopened = await store.setStatus(
        listed.single,
        FeedbackStatus.reviewing,
      );
      expect(reopened.fixedInVersion, isEmpty);
      expect(
        () => store.create(kind: FeedbackKind.other, text: '  '),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('the user text keeps plain links and long words but not secrets', () {
    const raw =
        'Pasa en https://example.com/album/123?x=1 y en '
        'https://cdn.x.com/a.flac?sig=abc123 con '
        'LongWordWithoutDigitsAbcdefghijklmnopqrstuvwxyz y '
        'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd token: hunter2';
    final clean = FeedbackSanitizer.cleanUserText(raw);
    expect(clean, contains('https://example.com/album/123?x=1'));
    expect(clean, contains('https://cdn.x.com/a.flac'));
    expect(clean, isNot(contains('sig=')));
    expect(clean, contains('LongWordWithoutDigitsAbcdefghijklmnopqrstuvwxyz'));
    expect(clean, isNot(contains('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')));
    expect(clean, isNot(contains('hunter2')));
  });

  test('the sanitizer removes tokens, signed URLs, paths and emails', () {
    const raw =
        'Fallo en https://cdn.x.com/a.flac?sig=abc123&token=zzz con '
        'Bearer abc.def y token: hunter2 en C:\\Users\\Alex\\Music\\a.flac y '
        '/storage/emulated/0/Download/MUSA/a.flac de alex@correo.com '
        'clave ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd';
    final clean = FeedbackSanitizer.clean(raw);
    for (final secret in [
      'cdn.x.com',
      'abc.def',
      'hunter2',
      'Alex',
      '/storage/emulated',
      'alex@correo.com',
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    ]) {
      expect(clean, isNot(contains(secret)));
    }
    expect(clean, contains('[URL]'));
    expect(clean, contains('[ruta]'));
  });

  test(
    'diagnostics keep recent log entries sanitized and no credentials',
    () async {
      SharedPreferences.setMockInitialValues({});
      final log = BugLog(preferences: SharedPreferences.getInstance);
      await log.addNote('mira https://x.com/a?token=1 token=secreto');
      final diagnostics = await FeedbackDiagnostics.collect(
        locale: 'es',
        quality: 'LOSSLESS; token=abc',
        provider: 'https://evil.example/x',
        bugLog: log,
        deviceInfo: () async =>
            (device: 'Pixel C:\\Users\\Alex', system: 'Android 15'),
      );
      final text = diagnostics.toText();
      expect(text, contains('Android 15'));
      expect(text, contains('Proveedor activo: unknown'));
      expect(text, isNot(contains('secreto')));
      expect(text, isNot(contains('x.com')));
      expect(text, isNot(contains('Alex')));
      expect(text, isNot(contains('token=abc')));
    },
  );

  test(
    'the package has reporte.json, reporte.md and the screenshots',
    () async {
      final thread = await store.create(
        kind: FeedbackKind.suggestion,
        text: 'Mas contraste',
        diagnostics: 'Dispositivo: Pixel',
        images: [
          FeedbackImage(name: 'a.png', bytes: Uint8List.fromList([1, 2, 3])),
        ],
      );
      final md = FeedbackPackage.markdown(thread);
      expect(md, contains('Sugerencia'));
      expect(md, contains('Mas contraste'));
      expect(md, contains('capturas/captura-1.png'));
      expect(md, contains('Dispositivo: Pixel'));
      final parsed = jsonDecode(FeedbackPackage.json(thread)) as Map;
      expect(parsed['formato'], 1);
      expect(parsed['kind'], 'suggestion');
      expect(parsed['attachments'], ['capturas/captura-1.png']);

      final out = Directory(p.join(temp.path, 'out'));
      final zip = await FeedbackPackage.writeZip(store, thread, out);
      final names = ZipDecoder()
          .decodeBytes(await zip.readAsBytes())
          .files
          .map((file) => file.name)
          .toSet();
      expect(names, {'reporte.json', 'reporte.md', 'capturas/captura-1.png'});
    },
  );

  test(
    'the folder transport exports folder and zip; share gets the zip',
    () async {
      final thread = await store.create(kind: FeedbackKind.bug, text: 'Error');
      final target = Directory(
        p.join(temp.path, 'Documentos', 'MUSA', 'feedback'),
      );
      final delivery = await FolderFeedbackTransport(
        store: store,
        targetDirectory: () async => target,
      ).send(thread);
      expect(File(p.join(delivery.path!, 'reporte.md')).existsSync(), isTrue);
      expect(
        File(
          p.join(target.path, '${FeedbackPackage.folderName(thread)}.zip'),
        ).existsSync(),
        isTrue,
      );
      File? shared;
      await ShareFeedbackTransport(
        store: store,
        workDirectory: () async => temp,
        share: (zip, text) async => shared = zip,
      ).send(thread);
      expect(shared!.path.endsWith('.zip'), isTrue);
    },
  );
}
