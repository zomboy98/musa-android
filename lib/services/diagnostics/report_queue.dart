import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef PendingReport = ({String name, Map<String, Object?> body});

class ReportQueue {
  ReportQueue({Future<Directory> Function()? root})
    : _root = root ?? _defaultRoot;

  static const maxEntries = 5;

  final Future<Directory> Function() _root;

  static Future<Directory> _defaultRoot() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'report_queue'),
  );

  Future<List<File>> _files() async {
    final root = await _root();
    if (!await root.exists()) return const [];
    final files = [
      await for (final entry in root.list(followLinks: false))
        if (entry is File && entry.path.endsWith('.json')) entry,
    ]..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<String> enqueue(Map<String, Object?> body) async {
    final root = await _root();
    await root.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random.secure().nextInt(0x10000).toRadixString(16);
    final name = '$stamp-$random';
    final target = File(p.join(root.path, '$name.json'));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode(body), flush: true);
    await temporary.rename(target.path);
    final files = await _files();
    for (var i = 0; i < files.length - maxEntries; i++) {
      await files[i].delete();
    }
    return name;
  }

  Future<int> count() async => (await _files()).length;

  Future<List<PendingReport>> pending() async {
    final result = <PendingReport>[];
    for (final file in await _files()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          result.add((
            name: p.basenameWithoutExtension(file.path),
            body: decoded,
          ));
        } else {
          await file.delete();
        }
      } catch (_) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    return result;
  }

  Future<void> remove(String name) async {
    final root = await _root();
    final file = File(p.join(root.path, '${p.basename(name)}.json'));
    if (await file.exists()) await file.delete();
  }
}
