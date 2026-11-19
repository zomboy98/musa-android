import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/services/feedback/feedback_sanitizer.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FeedbackImage {
  const FeedbackImage({required this.name, this.bytes, this.path});

  final String name;
  final Uint8List? bytes;
  final String? path;
}

class FeedbackStore extends ChangeNotifier {
  FeedbackStore({Future<Directory> Function()? root})
    : _root = root ?? _defaultRoot;

  static final instance = FeedbackStore();
  static const threadFileName = 'hilo.json';
  static const attachmentsFolder = 'adjuntos';
  static const _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.heic',
  };

  final Future<Directory> Function() _root;

  static Future<Directory> _defaultRoot() async => Directory(
    p.join((await getApplicationDocumentsDirectory()).path, 'feedback'),
  );

  Future<Directory> threadDirectory(String id) async =>
      Directory(p.join((await _root()).path, p.basename(id)));

  Future<List<FeedbackThread>> list() async {
    final root = await _root();
    if (!await root.exists()) return const [];
    final threads = <FeedbackThread>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final file = File(p.join(entry.path, threadFileName));
      try {
        final thread = FeedbackThread.fromJson(
          jsonDecode(await file.readAsString()),
        );
        if (thread != null) threads.add(thread);
      } catch (_) {
        continue;
      }
    }
    threads.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return threads;
  }

  Future<FeedbackThread> create({
    required FeedbackKind kind,
    required String text,
    String screen = '',
    String? diagnostics,
    List<FeedbackImage> images = const [],
    DateTime? now,
  }) async {
    final cleaned = FeedbackSanitizer.cleanUserText(text);
    if (cleaned.isEmpty) throw ArgumentError('Empty report');
    final created = (now ?? DateTime.now());
    final id = _newId(created);
    final directory = await threadDirectory(id);
    await Directory(
      p.join(directory.path, attachmentsFolder),
    ).create(recursive: true);
    final names = <String>[];
    for (final image in images) {
      final name = await _storeImage(directory, image, names.length + 1);
      if (name != null) names.add(name);
    }
    final thread = FeedbackThread(
      id: id,
      createdAt: created,
      kind: kind,
      text: cleaned,
      screen: FeedbackSanitizer.cleanLine(screen),
      attachments: names,
      diagnostics: diagnostics,
    );
    await _write(thread);
    return thread;
  }

  Future<FeedbackThread> setStatus(
    FeedbackThread thread,
    FeedbackStatus status, {
    String? fixedInVersion,
  }) => _save(
    thread.copyWith(
      status: status,
      fixedInVersion: status == FeedbackStatus.fixed
          ? FeedbackSanitizer.cleanLine(
              fixedInVersion ?? thread.fixedInVersion,
              maxLength: 40,
            )
          : '',
    ),
  );

  Future<FeedbackThread> addComment(
    FeedbackThread thread,
    String text, {
    DateTime? now,
  }) {
    final cleaned = FeedbackSanitizer.cleanUserText(text, maxLength: 1500);
    if (cleaned.isEmpty) return Future.error(ArgumentError('Empty comment'));
    final created = now ?? DateTime.now();
    return _save(
      thread.copyWith(
        comments: [
          ...thread.comments,
          FeedbackComment(
            id: _newId(created),
            createdAt: created,
            text: cleaned,
          ),
        ],
      ),
    );
  }

  Future<FeedbackThread> addAttachment(
    FeedbackThread thread,
    FeedbackImage image,
  ) async {
    final name = await _storeImage(
      await threadDirectory(thread.id),
      image,
      thread.attachments.length + 1,
    );
    if (name == null) return thread;
    return _save(thread.copyWith(attachments: [...thread.attachments, name]));
  }

  Future<File> attachmentFile(FeedbackThread thread, String name) async => File(
    p.join(
      (await threadDirectory(thread.id)).path,
      attachmentsFolder,
      p.basename(name),
    ),
  );

  Future<FeedbackThread> save(FeedbackThread thread) => _save(thread);

  Future<FeedbackThread> _save(FeedbackThread thread) async {
    await _write(thread);
    return thread;
  }

  Future<void> _write(FeedbackThread thread) async {
    final directory = await threadDirectory(thread.id);
    await directory.create(recursive: true);
    final target = File(p.join(directory.path, threadFileName));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(thread.toJson()),
      flush: true,
    );
    await temporary.rename(target.path);
    notifyListeners();
  }

  Future<String?> _storeImage(
    Directory directory,
    FeedbackImage image,
    int number,
  ) async {
    final extension = p.extension(image.name).toLowerCase();
    final name =
        'captura-$number'
        '${_imageExtensions.contains(extension) ? extension : '.png'}';
    final target = File(p.join(directory.path, attachmentsFolder, name));
    await target.parent.create(recursive: true);
    final bytes = image.bytes;
    final path = image.path;
    if (bytes != null) {
      await target.writeAsBytes(bytes, flush: true);
    } else if (path != null && await File(path).exists()) {
      await File(path).copy(target.path);
    } else {
      return null;
    }
    return name;
  }

  static String _newId(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    final random = Random.secure().nextInt(0x10000).toRadixString(16);
    return '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}-'
        '${random.padLeft(4, '0')}';
  }
}
