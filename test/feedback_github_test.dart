import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/services/feedback/feedback_package.dart';
import 'package:mornye/services/feedback/feedback_store.dart';
import 'package:mornye/services/feedback/feedback_token_store.dart';
import 'package:mornye/services/feedback/github_issues_transport.dart';
import 'package:path/path.dart' as p;

const _token = 'github_pat_SECRETO_1234567890';

void main() {
  late Directory temp;
  late FeedbackStore store;
  late FeedbackThread thread;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('musa_feedback_gh');
    store = FeedbackStore(root: () async => Directory(p.join(temp.path, 'fb')));
    thread = await store.create(
      kind: FeedbackKind.bug,
      text: 'Se corta la cancion\nsegunda linea',
      screen: 'Reproductor',
      diagnostics: 'Dispositivo: Pixel',
      images: [
        FeedbackImage(name: 'a.png', bytes: Uint8List.fromList([1, 2, 3])),
      ],
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  GitHubIssuesTransport transport(
    http.Client client, {
    String? token = _token,
    int attempts = 3,
  }) => GitHubIssuesTransport(
    tokenStore: MemoryFeedbackTokenStore(token),
    store: store,
    client: client,
    maxAttempts: attempts,
    delay: (_) async {},
  );

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  test('creates the issue with labels and uploads screenshots', () async {
    final calls = <String>[];
    Map<String, dynamic>? issueBody;
    final client = MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      expect(request.headers['Authorization'], 'Bearer $_token');
      final path = request.url.path;
      if (path.endsWith('/git/ref/heads/feedback-assets')) {
        return json({'message': 'Not Found'}, 404);
      }
      if (path.endsWith('/git/blobs')) return json({'sha': 'b1'}, 201);
      if (path.endsWith('/git/trees')) return json({'sha': 't1'}, 201);
      if (path.endsWith('/git/commits')) {
        expect((jsonDecode(request.body) as Map)['parents'], isEmpty);
        return json({'sha': 'c1'}, 201);
      }
      if (path.endsWith('/git/refs')) return json({}, 201);
      if (path.endsWith('/issues')) {
        issueBody = jsonDecode(request.body) as Map<String, dynamic>;
        return json({
          'number': 7,
          'html_url': 'https://github.com/zomboy98/MUSA/issues/7',
        }, 201);
      }
      return json({}, 500);
    });
    final delivery = await transport(client).send(thread);
    expect(delivery.issueNumber, 7);
    expect(delivery.issueUrl, endsWith('/issues/7'));
    expect(calls.first, contains('/repos/zomboy98/MUSA/git/ref/heads'));
    expect(issueBody!['title'], '[Error] Se corta la cancion');
    expect(issueBody!['labels'], ['feedback', 'bug', 'estado:enviado']);
    final body = issueBody!['body'] as String;
    expect(body, contains('<details>'));
    expect(body, contains('Dispositivo: Pixel'));
    expect(
      body,
      contains(
        'https://github.com/zomboy98/MUSA/blob/feedback-assets/capturas/'
        '${thread.id}-1.png',
      ),
    );
    expect(body, isNot(contains(_token)));
  });

  test('uses the contents API when the assets branch already exists', () async {
    String? put;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/git/ref/heads/feedback-assets')) {
        return json({'ref': 'x'});
      }
      if (request.method == 'PUT') {
        put = path;
        expect((jsonDecode(request.body) as Map)['branch'], 'feedback-assets');
        return json({}, 201);
      }
      return json({'number': 1, 'html_url': 'u'}, 201);
    });
    await transport(client).send(thread);
    expect(put, endsWith('/contents/capturas/${thread.id}-1.png'));
  });

  Future<FeedbackRemoteError> failWith(http.Response response) async {
    final client = MockClient((_) async => response);
    try {
      await transport(client, attempts: 2).testConnection();
    } on FeedbackRemoteException catch (error) {
      expect(error.toString(), isNot(contains(_token)));
      return error.error;
    }
    fail('Expected a failure');
  }

  test('maps HTTP failures to clear errors', () async {
    expect(
      await failWith(http.Response('', 401)),
      FeedbackRemoteError.unauthorized,
    );
    expect(
      await failWith(http.Response('', 403)),
      FeedbackRemoteError.forbidden,
    );
    expect(
      await failWith(http.Response('', 404)),
      FeedbackRemoteError.notFound,
    );
    expect(
      await failWith(
        http.Response('', 403, headers: {'x-ratelimit-remaining': '0'}),
      ),
      FeedbackRemoteError.rateLimited,
    );
    expect(await failWith(http.Response('', 503)), FeedbackRemoteError.server);
  });

  test(
    'a request that times out is reported as a timeout, not as no network',
    () async {
      final slow = MockClient((_) async {
        throw TimeoutException('lento');
      });
      await expectLater(
        transport(slow).send(thread),
        throwsA(
          isA<FeedbackRemoteException>().having(
            (e) => e.error,
            'error',
            FeedbackRemoteError.timeout,
          ),
        ),
      );
    },
  );

  test(
    'no network and missing token are reported and retried with a cap',
    () async {
      var calls = 0;
      final offline = MockClient((_) async {
        calls++;
        throw const SocketException('sin red');
      });
      await expectLater(
        transport(offline).send(thread),
        throwsA(
          isA<FeedbackRemoteException>().having(
            (e) => e.error,
            'error',
            FeedbackRemoteError.noNetwork,
          ),
        ),
      );
      expect(calls, 3);
      await expectLater(
        transport(MockClient((_) async => json({})), token: null).send(thread),
        throwsA(
          isA<FeedbackRemoteException>().having(
            (e) => e.error,
            'error',
            FeedbackRemoteError.noToken,
          ),
        ),
      );
    },
  );

  test('a transient server error is retried and then succeeds', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return calls == 1 ? http.Response('', 502) : json({'id': 1});
    });
    await transport(client).testConnection();
    expect(calls, 2);
  });

  test('sync reflects state, version and new comments', () async {
    final linked = await store.save(
      thread.copyWith(
        issueNumber: 7,
        comments: [
          FeedbackComment(
            id: 'github-1',
            createdAt: DateTime.utc(2026, 1, 1),
            text: 'ya conocido',
            remoteId: 1,
          ),
        ],
      ),
    );
    Response issue(List<String> labels, String state) => (labels, state);
    Future<FeedbackSync> run(
      Response issue,
      List<Map<String, Object>> comments,
    ) {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/comments')) return json(comments);
        return json({
          'state': issue.$2,
          'labels': [
            for (final name in issue.$1) {'name': name},
          ],
        });
      });
      return transport(client).sync(linked);
    }

    final reviewing = await run(issue(['estado:revision'], 'open'), [
      {'id': 1, 'body': 'ya conocido', 'created_at': '2026-01-01T00:00:00Z'},
      {
        'id': 2,
        'body': 'Lo miro en https://x.com/a?token=1',
        'created_at': '2026-01-02T00:00:00Z',
      },
    ]);
    expect(reviewing.status, FeedbackStatus.reviewing);
    expect(reviewing.comments, hasLength(2));
    expect(reviewing.comments.last.text, contains('[URL]'));

    final byLabel = await run(issue(['version:5.4.0'], 'closed'), const []);
    expect(byLabel.status, FeedbackStatus.fixed);
    expect(byLabel.fixedInVersion, '5.4.0');

    final byComment = await run(issue(['feedback'], 'closed'), [
      {
        'id': 3,
        'body': 'Corregido en 5.5.1',
        'created_at': '2026-01-03T00:00:00Z',
      },
    ]);
    expect(byComment.fixedInVersion, '5.5.1');

    final dismissed = await run(issue(['descartado'], 'closed'), const []);
    expect(dismissed.status, FeedbackStatus.dismissed);
  });

  test('the token never reaches the report package', () async {
    final memory = MemoryFeedbackTokenStore(_token);
    await memory.write(_token);
    final linked = thread.copyWith(issueNumber: 7);
    final text =
        FeedbackPackage.markdown(linked) + FeedbackPackage.json(linked);
    expect(text, isNot(contains(_token)));
    final file = File(
      p.join((await store.threadDirectory(thread.id)).path, 'hilo.json'),
    );
    expect(await file.readAsString(), isNot(contains(_token)));
  });
}

typedef Response = (List<String>, String);
