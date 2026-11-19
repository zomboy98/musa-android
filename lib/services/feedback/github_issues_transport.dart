import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/services/feedback/feedback_package.dart';
import 'package:mornye/services/feedback/feedback_sanitizer.dart';
import 'package:mornye/services/feedback/feedback_store.dart';
import 'package:mornye/services/feedback/feedback_token_store.dart';
import 'package:mornye/services/feedback/feedback_transport.dart';

enum FeedbackRemoteError {
  noToken,
  noNetwork,
  timeout,
  unauthorized,
  forbidden,
  notFound,
  rateLimited,
  invalid,
  server,
}

class FeedbackRemoteException implements Exception {
  const FeedbackRemoteException(this.error);

  final FeedbackRemoteError error;

  @override
  String toString() => 'FeedbackRemoteException(${error.name})';
}

class FeedbackSync {
  const FeedbackSync({
    required this.status,
    required this.fixedInVersion,
    required this.comments,
  });

  final FeedbackStatus status;
  final String fixedInVersion;
  final List<FeedbackComment> comments;
}

abstract class FeedbackRemote implements FeedbackTransport {
  Future<FeedbackSync> sync(FeedbackThread thread);
  Future<void> testConnection();
}

class GitHubIssuesTransport implements FeedbackRemote {
  GitHubIssuesTransport({
    required FeedbackTokenStore tokenStore,
    FeedbackStore? store,
    http.Client? client,
    String repo = AppInfo.feedbackRepo,
    int maxAttempts = 3,
    Future<void> Function(Duration)? delay,
  }) : _tokens = tokenStore,
       _store = store ?? FeedbackStore.instance,
       _client = client ?? http.Client(),
       _repo = repo,
       _maxAttempts = maxAttempts,
       _delay = delay ?? Future<void>.delayed;

  static const assetsBranch = 'feedback-assets';
  static const _api = 'https://api.github.com';
  static const _maxWait = Duration(seconds: 8);

  final FeedbackTokenStore _tokens;
  final FeedbackStore _store;
  final http.Client _client;
  final String _repo;
  final int _maxAttempts;
  final Future<void> Function(Duration) _delay;

  static String kindLabel(FeedbackKind kind) => switch (kind) {
    FeedbackKind.bug => 'bug',
    FeedbackKind.suggestion => 'idea',
    FeedbackKind.design => 'diseno',
    FeedbackKind.other => 'otro',
  };

  static String kindTitle(FeedbackKind kind) => FeedbackPackage.kindLabel(kind);

  static String title(FeedbackThread thread) {
    final line = FeedbackSanitizer.cleanLine(
      thread.text.split('\n').first,
      maxLength: 70,
    );
    return '[${kindTitle(thread.kind)}] ${line.isEmpty ? thread.id : line}';
  }

  static String assetPath(FeedbackThread thread, int number, String name) {
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '.png' : name.substring(dot).toLowerCase();
    return 'capturas/${thread.id}-$number$extension';
  }

  String assetUrl(String path) =>
      'https://github.com/$_repo/blob/$assetsBranch/$path';

  String body(FeedbackThread thread, List<String> assetPaths) {
    final buffer = StringBuffer()
      ..writeln(thread.text)
      ..writeln()
      ..writeln('- Tipo: ${kindTitle(thread.kind)}')
      ..writeln('- Fecha: ${FeedbackPackage.stamp(thread.createdAt)}')
      ..writeln('- Reporte local: ${thread.id}');
    if (thread.screen.isNotEmpty) {
      buffer.writeln('- Pantalla: ${thread.screen}');
    }
    buffer.writeln('- App: ${AppInfo.version} (${AppInfo.buildNumber})');
    if (AppInfo.shortGitCommit.isNotEmpty) {
      buffer.writeln('- Commit: ${AppInfo.shortGitCommit}');
    }
    if (assetPaths.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('### Capturas')
        ..writeln();
      for (var i = 0; i < assetPaths.length; i++) {
        buffer.writeln('- [Captura ${i + 1}](${assetUrl(assetPaths[i])})');
      }
    }
    final diagnostics = thread.diagnostics;
    if (diagnostics != null && diagnostics.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('<details>')
        ..writeln(
          '<summary>Datos del dispositivo y registro reciente</summary>',
        )
        ..writeln()
        ..writeln('```')
        ..writeln(diagnostics.replaceAll('```', "'''"))
        ..writeln('```')
        ..writeln()
        ..writeln('</details>');
    }
    return buffer.toString();
  }

  @override
  Future<FeedbackDelivery> send(FeedbackThread thread) async {
    final token = await _requireToken();
    final assetPaths = <String>[];
    for (var i = 0; i < thread.attachments.length; i++) {
      final file = await _store.attachmentFile(thread, thread.attachments[i]);
      if (!await file.exists()) continue;
      final path = assetPath(thread, i + 1, thread.attachments[i]);
      await _uploadAsset(token, path, await file.readAsBytes(), thread.id);
      assetPaths.add(path);
    }
    final response = await _request(
      token,
      'POST',
      '/repos/$_repo/issues',
      body: {
        'title': title(thread),
        'body': body(thread, assetPaths),
        'labels': ['feedback', kindLabel(thread.kind), 'estado:enviado'],
      },
    );
    final json = _object(response.body);
    final number = json['number'];
    final url = json['html_url'];
    if (number is! int) {
      throw const FeedbackRemoteException(FeedbackRemoteError.invalid);
    }
    return FeedbackDelivery(
      issueNumber: number,
      issueUrl: url is String
          ? url
          : 'https://github.com/$_repo/issues/$number',
    );
  }

  @override
  Future<void> testConnection() async {
    final token = await _requireToken();
    await _request(token, 'GET', '/repos/$_repo');
  }

  @override
  Future<FeedbackSync> sync(FeedbackThread thread) async {
    final number = thread.issueNumber;
    if (number == null) {
      throw const FeedbackRemoteException(FeedbackRemoteError.invalid);
    }
    final token = await _requireToken();
    final issue = _object(
      (await _request(token, 'GET', '/repos/$_repo/issues/$number')).body,
    );
    final rawComments = jsonDecode(
      (await _request(
        token,
        'GET',
        '/repos/$_repo/issues/$number/comments?per_page=100',
      )).body,
    );
    final remote = <FeedbackComment>[];
    if (rawComments is List) {
      for (final item in rawComments) {
        if (item is! Map || item['id'] is! int) continue;
        final text = FeedbackSanitizer.clean(
          '${item['body'] ?? ''}',
          maxLength: 1500,
        );
        final created = DateTime.tryParse('${item['created_at']}');
        if (text.isEmpty || created == null) continue;
        remote.add(
          FeedbackComment(
            id: 'github-${item['id']}',
            createdAt: created.toLocal(),
            text: text,
            remoteId: item['id'] as int,
          ),
        );
      }
    }
    final known = {
      for (final comment in thread.comments)
        if (comment.remoteId != null) comment.remoteId,
    };
    final merged = [
      ...thread.comments,
      for (final comment in remote)
        if (!known.contains(comment.remoteId)) comment,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final labels = <String>{
      if (issue['labels'] is List)
        for (final label in issue['labels'] as List)
          if (label is Map && label['name'] is String)
            (label['name'] as String).toLowerCase(),
    };
    final closed = issue['state'] == 'closed';
    var version = '';
    for (final label in labels) {
      if (label.startsWith('version:')) {
        version = label.substring('version:'.length).trim();
      }
    }
    if (version.isEmpty) {
      final pattern = RegExp(r'Corregido en\s+v?([A-Za-z0-9][\w.+-]*)');
      for (final comment in remote.reversed) {
        final match = pattern.firstMatch(comment.text);
        if (match != null) {
          version = match.group(1)!;
          break;
        }
      }
    }
    final FeedbackStatus status;
    if (labels.contains('descartado') || labels.contains('estado:descartado')) {
      status = FeedbackStatus.dismissed;
    } else if (version.isNotEmpty || labels.contains('estado:corregido')) {
      status = FeedbackStatus.fixed;
    } else if (closed) {
      status = FeedbackStatus.fixed;
    } else if (labels.contains('estado:revision') ||
        labels.contains('estado:en-revision')) {
      status = FeedbackStatus.reviewing;
    } else {
      status = FeedbackStatus.sent;
    }
    return FeedbackSync(
      status: status,
      fixedInVersion: status == FeedbackStatus.fixed ? version : '',
      comments: merged,
    );
  }

  Future<String> _requireToken() async {
    final token = await _tokens.read();
    if (token == null || token.isEmpty) {
      throw const FeedbackRemoteException(FeedbackRemoteError.noToken);
    }
    return token;
  }

  Future<void> _uploadAsset(
    String token,
    String path,
    List<int> bytes,
    String id,
  ) async {
    final content = base64Encode(bytes);
    final branch = await _request(
      token,
      'GET',
      '/repos/$_repo/git/ref/heads/$assetsBranch',
      allow: const {404},
    );
    if (branch.statusCode == 404) {
      await _createOrphanBranch(token, path, content, id);
      return;
    }
    await _request(
      token,
      'PUT',
      '/repos/$_repo/contents/$path',
      body: {
        'message': 'Captura del reporte $id',
        'content': content,
        'branch': assetsBranch,
      },
      allow: const {422},
    );
  }

  Future<void> _createOrphanBranch(
    String token,
    String path,
    String content,
    String id,
  ) async {
    final blob = _object(
      (await _request(
        token,
        'POST',
        '/repos/$_repo/git/blobs',
        body: {'content': content, 'encoding': 'base64'},
      )).body,
    );
    final tree = _object(
      (await _request(
        token,
        'POST',
        '/repos/$_repo/git/trees',
        body: {
          'tree': [
            {
              'path': path,
              'mode': '100644',
              'type': 'blob',
              'sha': blob['sha'],
            },
          ],
        },
      )).body,
    );
    final commit = _object(
      (await _request(
        token,
        'POST',
        '/repos/$_repo/git/commits',
        body: {
          'message': 'Capturas de reportes: primer commit ($id)',
          'tree': tree['sha'],
          'parents': <String>[],
        },
      )).body,
    );
    await _request(
      token,
      'POST',
      '/repos/$_repo/git/refs',
      body: {'ref': 'refs/heads/$assetsBranch', 'sha': commit['sha']},
    );
  }

  Map<String, dynamic> _object(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      throw const FeedbackRemoteException(FeedbackRemoteError.invalid);
    }
    throw const FeedbackRemoteException(FeedbackRemoteError.invalid);
  }

  Future<http.Response> _request(
    String token,
    String method,
    String path, {
    Map<String, Object?>? body,
    Set<int> allow = const {},
  }) async {
    FeedbackRemoteException? last;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final request = http.Request(method, Uri.parse('$_api$path'))
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'MUSA-feedback',
            if (body != null) 'Content-Type': 'application/json',
          });
        if (body != null) request.body = jsonEncode(body);
        final response = await http.Response.fromStream(
          await _client.send(request).timeout(const Duration(seconds: 30)),
        );
        final status = response.statusCode;
        if (status >= 200 && status < 300 || allow.contains(status)) {
          return response;
        }
        final error = _classify(response);
        if (error.error == FeedbackRemoteError.rateLimited) {
          final wait = _waitFor(response);
          if (wait == null || attempt == _maxAttempts) throw error;
          await _delay(wait);
          last = error;
          continue;
        }
        if (error.error == FeedbackRemoteError.server) {
          last = error;
          if (attempt < _maxAttempts) {
            await _delay(Duration(seconds: attempt));
          }
          continue;
        }
        throw error;
      } on FeedbackRemoteException {
        rethrow;
      } on SocketException {
        last = const FeedbackRemoteException(FeedbackRemoteError.noNetwork);
      } on TimeoutException {
        last = const FeedbackRemoteException(FeedbackRemoteError.timeout);
      } on http.ClientException {
        last = const FeedbackRemoteException(FeedbackRemoteError.noNetwork);
      }
      if (attempt < _maxAttempts) await _delay(Duration(seconds: attempt));
    }
    throw last ?? const FeedbackRemoteException(FeedbackRemoteError.server);
  }

  Duration? _waitFor(http.Response response) {
    final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
    if (retryAfter != null) {
      final wait = Duration(seconds: retryAfter);
      return wait <= _maxWait ? wait : null;
    }
    final reset = int.tryParse(response.headers['x-ratelimit-reset'] ?? '');
    if (reset != null) {
      final wait = DateTime.fromMillisecondsSinceEpoch(
        reset * 1000,
      ).difference(DateTime.now());
      return wait <= _maxWait ? (wait.isNegative ? Duration.zero : wait) : null;
    }
    return null;
  }

  FeedbackRemoteException _classify(http.Response response) {
    final status = response.statusCode;
    if (status == 401) {
      return const FeedbackRemoteException(FeedbackRemoteError.unauthorized);
    }
    if (status == 429 ||
        status == 403 &&
            (response.headers['x-ratelimit-remaining'] == '0' ||
                response.headers.containsKey('retry-after') ||
                response.body.toLowerCase().contains('rate limit'))) {
      return const FeedbackRemoteException(FeedbackRemoteError.rateLimited);
    }
    if (status == 403) {
      return const FeedbackRemoteException(FeedbackRemoteError.forbidden);
    }
    if (status == 404) {
      return const FeedbackRemoteException(FeedbackRemoteError.notFound);
    }
    if (status >= 500) {
      return const FeedbackRemoteException(FeedbackRemoteError.server);
    }
    return const FeedbackRemoteException(FeedbackRemoteError.invalid);
  }
}
