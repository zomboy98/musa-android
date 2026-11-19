import 'dart:io';

import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/services/feedback/feedback_package.dart';
import 'package:mornye/services/feedback/feedback_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class FeedbackDelivery {
  const FeedbackDelivery({this.path, this.issueNumber, this.issueUrl = ''});

  final String? path;
  final int? issueNumber;
  final String issueUrl;
}

abstract class FeedbackTransport {
  Future<FeedbackDelivery> send(FeedbackThread thread);
}

typedef FeedbackShareAction = Future<void> Function(File zip, String text);

class ShareFeedbackTransport implements FeedbackTransport {
  ShareFeedbackTransport({
    FeedbackStore? store,
    Future<Directory> Function()? workDirectory,
    FeedbackShareAction? share,
  }) : _store = store ?? FeedbackStore.instance,
       _workDirectory = workDirectory ?? getTemporaryDirectory,
       _share = share ?? _systemShare;

  final FeedbackStore _store;
  final Future<Directory> Function() _workDirectory;
  final FeedbackShareAction _share;

  static Future<void> _systemShare(File zip, String text) => SharePlus.instance
      .share(ShareParams(files: [XFile(zip.path)], text: text));

  @override
  Future<FeedbackDelivery> send(FeedbackThread thread) async {
    final directory = Directory(
      p.join((await _workDirectory()).path, 'musa-feedback'),
    );
    final zip = await FeedbackPackage.writeZip(_store, thread, directory);
    await _share(zip, 'MUSA ${thread.id}');
    return FeedbackDelivery(path: zip.path);
  }
}

class FolderFeedbackTransport implements FeedbackTransport {
  FolderFeedbackTransport({
    FeedbackStore? store,
    Future<Directory> Function()? targetDirectory,
  }) : _store = store ?? FeedbackStore.instance,
       _targetDirectory = targetDirectory ?? defaultTargetDirectory;

  static const androidPublicPath =
      '/storage/emulated/0/Documents/MUSA/feedback';

  final FeedbackStore _store;
  final Future<Directory> Function() _targetDirectory;

  static Future<Directory> defaultTargetDirectory() async {
    if (Platform.isAndroid) {
      try {
        final directory = Directory(androidPublicPath);
        await directory.create(recursive: true);
        final probe = File(p.join(directory.path, '.escritura'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return directory;
      } catch (_) {
        final external = await getExternalStorageDirectory();
        if (external != null) {
          return Directory(p.join(external.path, 'feedback'));
        }
      }
    }
    return Directory(
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        'MUSA',
        'feedback',
      ),
    );
  }

  @override
  Future<FeedbackDelivery> send(FeedbackThread thread) async {
    final directory = await _targetDirectory();
    await directory.create(recursive: true);
    final folder = await FeedbackPackage.writeFolder(_store, thread, directory);
    await FeedbackPackage.writeZip(_store, thread, directory);
    return FeedbackDelivery(path: folder.path);
  }
}
