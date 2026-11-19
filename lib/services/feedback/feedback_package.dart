import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/services/feedback/feedback_store.dart';
import 'package:path/path.dart' as p;

class FeedbackPackage {
  const FeedbackPackage._();

  static const jsonName = 'reporte.json';
  static const markdownName = 'reporte.md';
  static const imagesFolder = 'capturas';
  static const formatVersion = 1;

  static String folderName(FeedbackThread thread) =>
      'musa-reporte-${thread.id}';

  static String kindLabel(FeedbackKind kind) => switch (kind) {
    FeedbackKind.bug => 'Error',
    FeedbackKind.suggestion => 'Sugerencia',
    FeedbackKind.design => 'Detalle de diseño',
    FeedbackKind.other => 'Otro',
  };

  static String statusLabel(FeedbackStatus status) => switch (status) {
    FeedbackStatus.sent => 'Enviado',
    FeedbackStatus.reviewing => 'En revisión',
    FeedbackStatus.fixed => 'Corregido en una versión',
    FeedbackStatus.dismissed => 'Descartado',
  };

  static String stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    final local = time.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String markdown(FeedbackThread thread) {
    final buffer = StringBuffer()
      ..writeln('# Reporte ${thread.id}')
      ..writeln()
      ..writeln('- Tipo: ${kindLabel(thread.kind)}')
      ..writeln('- Fecha: ${stamp(thread.createdAt)}')
      ..writeln('- Estado: ${statusLabel(thread.status)}');
    if (thread.status == FeedbackStatus.fixed &&
        thread.fixedInVersion.isNotEmpty) {
      buffer.writeln('- Corregido en: ${thread.fixedInVersion}');
    }
    if (thread.screen.isNotEmpty) {
      buffer.writeln('- Pantalla: ${thread.screen}');
    }
    buffer
      ..writeln('- App: ${AppInfo.version} (${AppInfo.buildNumber})')
      ..writeln()
      ..writeln('## Descripción')
      ..writeln()
      ..writeln(thread.text)
      ..writeln();
    if (thread.attachments.isNotEmpty) {
      buffer
        ..writeln('## Capturas')
        ..writeln();
      for (final name in thread.attachments) {
        buffer.writeln('- $imagesFolder/$name');
      }
      buffer.writeln();
    }
    if (thread.diagnostics != null && thread.diagnostics!.isNotEmpty) {
      buffer
        ..writeln('## Datos del dispositivo y registro reciente')
        ..writeln()
        ..writeln('```')
        ..writeln(thread.diagnostics)
        ..writeln('```')
        ..writeln();
    }
    if (thread.comments.isNotEmpty) {
      buffer
        ..writeln('## Seguimiento')
        ..writeln();
      for (final comment in thread.comments) {
        buffer.writeln('- ${stamp(comment.createdAt)}: ${comment.text}');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  static String json(FeedbackThread thread) =>
      const JsonEncoder.withIndent('  ').convert({
        'formato': formatVersion,
        'app': {
          'version': AppInfo.version,
          'build': AppInfo.buildNumber,
          'commit': AppInfo.shortGitCommit,
        },
        ...thread.toJson(),
        'attachments': [
          for (final name in thread.attachments) '$imagesFolder/$name',
        ],
      });

  static Future<Directory> writeFolder(
    FeedbackStore store,
    FeedbackThread thread,
    Directory parent,
  ) async {
    final target = Directory(p.join(parent.path, folderName(thread)));
    await target.create(recursive: true);
    await File(
      p.join(target.path, jsonName),
    ).writeAsString(json(thread), flush: true);
    await File(
      p.join(target.path, markdownName),
    ).writeAsString(markdown(thread), flush: true);
    for (final name in thread.attachments) {
      final source = await store.attachmentFile(thread, name);
      if (!await source.exists()) continue;
      final destination = File(p.join(target.path, imagesFolder, name));
      await destination.parent.create(recursive: true);
      await source.copy(destination.path);
    }
    return target;
  }

  static Future<File> writeZip(
    FeedbackStore store,
    FeedbackThread thread,
    Directory parent,
  ) async {
    final archive = Archive();
    void add(String name, List<int> bytes) =>
        archive.addFile(ArchiveFile.bytes(name, bytes));
    add(jsonName, utf8.encode(json(thread)));
    add(markdownName, utf8.encode(markdown(thread)));
    for (final name in thread.attachments) {
      final source = await store.attachmentFile(thread, name);
      if (await source.exists()) {
        add('$imagesFolder/$name', await source.readAsBytes());
      }
    }
    final bytes = ZipEncoder().encode(archive);
    await parent.create(recursive: true);
    final file = File(p.join(parent.path, '${folderName(thread)}.zip'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}
