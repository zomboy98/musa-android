import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mornye/services/analytics/install_id.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/diagnostics/log_redactor.dart';
import 'package:mornye/services/diagnostics/report_client.dart';
import 'package:mornye/services/diagnostics/report_device_info.dart';
import 'package:mornye/services/diagnostics/report_models.dart';
import 'package:mornye/services/diagnostics/report_queue.dart';
import 'package:mornye/services/diagnostics/report_rate_limiter.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

typedef ReportLogSource = Future<String> Function();
typedef ReportShareAction = Future<void> Function(File zip, String text);

sealed class ReportOutcome {
  const ReportOutcome();
}

class ReportSent extends ReportOutcome {
  const ReportSent(this.ref);

  final String ref;
}

class ReportQueued extends ReportOutcome {
  const ReportQueued();
}

class ReportRateLimited extends ReportOutcome {
  const ReportRateLimited();
}

class ReportRejected extends ReportOutcome {
  const ReportRejected(this.status);

  final int? status;
}

Future<String> defaultReportLog() async {
  final lines = <String>[];
  try {
    for (final entry in await BugLog.instance.entries()) {
      final note = entry['note'];
      lines.add(
        [
              entry['time'],
              entry['category'],
              entry['type'],
              entry['tag'],
              entry['frames'],
              if (entry['count'] != null) 'omitidos ${entry['count']}',
              if (note != null) BugLog.sanitizeNote(note),
            ]
            .whereType<String>()
            .where((part) => part.isNotEmpty)
            .join(' | ')
            .replaceAll('\n', ' / '),
      );
    }
  } catch (_) {}
  try {
    for (final entry in LogBuffer().entries) {
      final level = entry.level.toLowerCase();
      if (level.contains('error') ||
          level.contains('warn') ||
          level.contains('fatal')) {
        lines.add(entry.toString().replaceAll('\n', ' / '));
      }
    }
  } catch (_) {}
  return lines.join('\n');
}

class ReportService {
  ReportService({
    ReportClient? client,
    ReportQueue? queue,
    ReportRateLimiter? limiter,
    InstallId? installId,
    ReportLogSource? logSource,
    Future<ReportDeviceInfo> Function(String locale)? deviceInfo,
    Future<void> Function(Duration)? delay,
    ReportShareAction? share,
    Future<Directory> Function()? workDirectory,
    DateTime Function()? now,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 3)],
  }) : _client = client ?? ReportClient(),
       _queue = queue ?? ReportQueue(),
       _limiter = limiter ?? ReportRateLimiter(),
       _installId = installId ?? InstallId.instance,
       _logSource = logSource ?? defaultReportLog,
       _deviceInfo =
           deviceInfo ?? ((locale) => ReportDeviceInfo.collect(locale: locale)),
       _delay = delay ?? Future<void>.delayed,
       _share = share ?? _systemShare,
       _workDirectory = workDirectory ?? getTemporaryDirectory,
       _now = now ?? DateTime.now;

  static const maxLogBytes = 20 * 1024;

  final ReportClient _client;
  final ReportQueue _queue;
  final ReportRateLimiter _limiter;
  final InstallId _installId;
  final ReportLogSource _logSource;
  final Future<ReportDeviceInfo> Function(String locale) _deviceInfo;
  final Future<void> Function(Duration) _delay;
  final ReportShareAction _share;
  final Future<Directory> Function() _workDirectory;
  final DateTime Function() _now;
  final List<Duration> retryDelays;

  static Future<void> _systemShare(File zip, String text) => SharePlus.instance
      .share(ShareParams(files: [XFile(zip.path)], text: text));

  static String cleanText(String value) => value
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
      .replaceAll('\r\n', '\n')
      .trim();

  static String cleanContact(String value) => value
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<String> readLog() async {
    try {
      return await _logSource();
    } catch (_) {
      return '';
    }
  }

  Future<ReportPackage> build(
    ReportDraft draft, {
    required String locale,
    String? rawLog,
  }) async {
    final info = await _deviceInfo(locale);
    final deviceText = draft.includeDevice ? info.toText() : '';
    var logText = '';
    if (draft.includeLog) {
      final raw = rawLog ?? await readLog();
      final budget = maxLogBytes - utf8.encode(deviceText).length - 4;
      logText = LogRedactor.redact(raw, bytes: budget < 0 ? 0 : budget);
    }
    final text = cleanText(draft.text);
    final contact = cleanContact(draft.contact);
    return ReportPackage(
      kind: draft.kind,
      text: text.length > ReportPackage.maxText
          ? text.substring(0, ReportPackage.maxText)
          : text,
      contact: contact.length > ReportPackage.maxContact
          ? contact.substring(0, ReportPackage.maxContact)
          : contact,
      version: info.appVersion,
      os: info.osMajor,
      logField: [deviceText, logText].where((s) => s.isNotEmpty).join('\n\n'),
      deviceText: deviceText,
      logText: logText,
      images: draft.images.take(ReportPackage.maxImages).toList(),
    );
  }

  Future<ReportOutcome> submit(ReportPackage package) async {
    if (!await _limiter.canSend()) return const ReportRateLimited();
    final body = package.toBody(await _installId.read());
    ReportException? last;
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      if (attempt > 0) await _delay(retryDelays[attempt - 1]);
      try {
        final receipt = await _client.send(body);
        await _limiter.record();
        return ReportSent(receipt.ref);
      } on ReportException catch (error) {
        last = error;
        if (!error.retryable) break;
      }
    }
    if (last != null && last.failure == ReportFailure.rateLimited) {
      return const ReportRateLimited();
    }
    if (last != null && !last.retryable) return ReportRejected(last.status);
    await _queue.enqueue(body);
    await _limiter.record();
    return const ReportQueued();
  }

  Future<int> pendingCount() => _queue.count();

  Future<int> flushPending() async {
    var sent = 0;
    for (final item in await _queue.pending()) {
      try {
        await _client.send(item.body);
        await _queue.remove(item.name);
        sent++;
      } on ReportException catch (error) {
        if (error.failure == ReportFailure.rejected) {
          await _queue.remove(item.name);
          continue;
        }
        break;
      }
    }
    return sent;
  }

  static String _kindLabel(ReportKind kind) => switch (kind) {
    ReportKind.error => 'Error',
    ReportKind.idea => 'Idea',
    ReportKind.other => 'Otro',
  };

  List<int> buildZip(ReportPackage package) {
    final archive = Archive();
    void add(String name, String text) =>
        archive.addFile(ArchiveFile.bytes(name, utf8.encode(text)));
    final stamp = _now().toUtc().toIso8601String();
    final summary = StringBuffer()
      ..writeln('# Informe de MUSA')
      ..writeln()
      ..writeln('- Tipo: ${_kindLabel(package.kind)}')
      ..writeln('- Fecha: $stamp')
      ..writeln('- Versión: ${package.version}')
      ..writeln('- Android: ${package.os}');
    if (package.contact.isNotEmpty) {
      summary.writeln('- Contacto: ${package.contact}');
    }
    summary
      ..writeln()
      ..writeln('## Descripción')
      ..writeln()
      ..writeln(package.text);
    add('informe.md', summary.toString());
    if (package.deviceText.isNotEmpty)
      add('dispositivo.txt', package.deviceText);
    if (package.logText.isNotEmpty) add('registro.txt', package.logText);
    for (var i = 0; i < package.images.length; i++) {
      archive.addFile(
        ArchiveFile.bytes(
          'capturas/captura-${i + 1}.jpg',
          package.images[i].bytes,
        ),
      );
    }
    return ZipEncoder().encode(archive);
  }

  Future<File> writeZip(ReportPackage package) async {
    final directory = Directory(
      p.join((await _workDirectory()).path, 'musa-informe'),
    );
    await directory.create(recursive: true);
    final stamp = _now().millisecondsSinceEpoch;
    final file = File(p.join(directory.path, 'musa-informe-$stamp.zip'));
    await file.writeAsBytes(buildZip(package), flush: true);
    return file;
  }

  Future<File> shareAsFile(ReportPackage package) async {
    final zip = await writeZip(package);
    await _share(zip, 'MUSA ${package.version}');
    return zip;
  }
}
