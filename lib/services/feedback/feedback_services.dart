import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/services/feedback/feedback_capture.dart';
import 'package:mornye/services/feedback/feedback_diagnostics.dart';
import 'package:mornye/services/feedback/feedback_image_processor.dart';
import 'package:mornye/services/feedback/feedback_store.dart';
import 'package:mornye/services/feedback/feedback_token_store.dart';
import 'package:mornye/services/feedback/feedback_transport.dart';
import 'package:mornye/services/feedback/github_issues_transport.dart';

typedef FeedbackImagePicker = Future<List<FeedbackImage>> Function();
typedef FeedbackImagePreparer = Future<FeedbackImage?> Function(FeedbackImage);
typedef FeedbackScreenCapture = Future<Uint8List?> Function();
typedef FeedbackDiagnosticsLoader =
    Future<FeedbackDiagnostics> Function(BuildContext context);

class FeedbackServices {
  FeedbackServices({
    FeedbackStore? store,
    FeedbackImagePicker? pickImages,
    FeedbackImagePreparer? prepareImage,
    FeedbackScreenCapture? captureScreen,
    FeedbackDiagnosticsLoader? loadDiagnostics,
    FeedbackTransport? shareTransport,
    FeedbackTransport? folderTransport,
    FeedbackTokenStore? tokenStore,
    FeedbackRemote? remote,
  }) : tokenStore = tokenStore ?? SecureFeedbackTokenStore(),
       store = store ?? FeedbackStore.instance,
       pickImages = pickImages ?? pickGalleryImages,
       prepareImage = prepareImage ?? FeedbackImageProcessor.prepare,
       captureScreen = captureScreen ?? FeedbackCapture.captureScreen,
       loadDiagnostics = loadDiagnostics ?? defaultDiagnostics,
       shareTransport =
           shareTransport ??
           ShareFeedbackTransport(store: store ?? FeedbackStore.instance),
       folderTransport =
           folderTransport ??
           FolderFeedbackTransport(store: store ?? FeedbackStore.instance) {
    this.remote =
        remote ??
        GitHubIssuesTransport(tokenStore: this.tokenStore, store: this.store);
  }

  final FeedbackStore store;
  final FeedbackImagePicker pickImages;
  final FeedbackImagePreparer prepareImage;
  final FeedbackScreenCapture captureScreen;
  final FeedbackDiagnosticsLoader loadDiagnostics;
  final FeedbackTransport shareTransport;
  final FeedbackTransport folderTransport;
  final FeedbackTokenStore tokenStore;
  late final FeedbackRemote remote;

  Future<FeedbackThread> sendRemote(FeedbackThread thread) async {
    try {
      final delivery = await remote.send(thread);
      return await store.save(
        thread.copyWith(
          issueNumber: delivery.issueNumber,
          issueUrl: delivery.issueUrl,
          pendingSend: false,
        ),
      );
    } catch (_) {
      await store.save(thread.copyWith(pendingSend: true));
      rethrow;
    }
  }

  Future<FeedbackThread> syncRemote(FeedbackThread thread) async {
    final result = await remote.sync(thread);
    return store.save(
      thread.copyWith(
        status: result.status,
        fixedInVersion: result.fixedInVersion,
        comments: result.comments,
      ),
    );
  }

  static Future<List<FeedbackImage>> pickGalleryImages() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    return [
      for (final file in result)
        if (file.path != null) FeedbackImage(name: file.name, path: file.path),
    ];
  }

  static Future<FeedbackDiagnostics> defaultDiagnostics(
    BuildContext context,
  ) async {
    var quality = '';
    var provider = '';
    final locale = Localizations.localeOf(context).toLanguageTag();
    try {
      final settings = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(settingsProvider);
      quality = settings.audioQuality;
      provider = settings.defaultService;
    } catch (_) {
      quality = '';
      provider = '';
    }
    return FeedbackDiagnostics.collect(
      locale: locale,
      quality: quality,
      provider: provider,
    );
  }
}
