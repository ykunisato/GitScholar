import 'dart:convert';
import 'dart:typed_data';

import 'package:github_api/github_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response json(
  Object body, {
  int status = 200,
  Map<String, String>? headers,
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...?headers},
);

void main() {
  group('gitBlobSha', () {
    test('empty', () {
      expect(
        gitBlobSha(Uint8List(0)),
        'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391',
      );
    });
    test('hello newline', () {
      expect(
        gitBlobSha(Uint8List.fromList(utf8.encode('hello\n'))),
        'ce013625030ba8dba906f756967f9e9ca394464a',
      );
    });
  });

  group('GitHubClient', () {
    late List<http.Request> requests;
    GitHubClient clientWith(
      Future<http.Response> Function(http.Request) h, {
      ETagCache? cache,
      void Function(int, DateTime?)? onRateLimit,
    }) {
      requests = [];
      return GitHubClient(
        token: 'tok',
        etagCache: cache,
        onRateLimit: onRateLimit,
        client: MockClient((req) {
          requests.add(req);
          return h(req);
        }),
      );
    }

    test('common headers and getUser', () async {
      int? remaining;
      final c2 = clientWith(
        (_) async => json(
          {'login': 'u', 'id': 1, 'avatar_url': 'a'},
          headers: {'x-ratelimit-remaining': '42', 'x-ratelimit-reset': '100'},
        ),
        onRateLimit: (r, _) => remaining = r,
      );
      final user = await c2.getUser();
      expect(user.login, 'u');
      expect(remaining, 42);
      final h = requests.single.headers;
      expect(h['Authorization'], 'Bearer tok');
      expect(h['Accept'], 'application/vnd.github+json');
      expect(h['X-GitHub-Api-Version'], '2022-11-28');
      expect(requests.single.url.path, '/user');
      c2.close();
    });

    test('listUserRepos follows Link pagination', () async {
      Map<String, dynamic> repo(int i) => {
        'owner': {'login': 'o'},
        'name': 'r$i',
        'full_name': 'o/r$i',
        'private': i.isEven,
        'default_branch': 'main',
        'updated_at': '2026-01-01T00:00:00Z',
      };
      final c = clientWith((req) async {
        if (req.url.queryParameters['page'] == '2') {
          return json([repo(3)]);
        }
        return json(
          [repo(1), repo(2)],
          headers: {
            'link':
                '<https://api.github.com/user/repos?page=2>; rel="next", '
                '<https://api.github.com/user/repos?page=2>; rel="last"',
          },
        );
      });
      final progress = <int>[];
      final repos = await c.listUserRepos(onProgress: progress.add);
      expect(repos.map((r) => r.fullName), ['o/r1', 'o/r2', 'o/r3']);
      expect(progress, [2, 3]);
      expect(
        requests.first.url.queryParameters['affiliation'],
        'owner,collaborator,organization_member',
      );
      expect(repos.first.isPrivate, isFalse);
    });

    test('parseNextLink', () {
      expect(GitHubClient.parseNextLink(null), isNull);
      expect(GitHubClient.parseNextLink('<x>; rel="last"'), isNull);
    });

    test('getBranchHeadSha uses ETag and 304', () async {
      final cache = MemoryETagCache();
      var calls = 0;
      final c = clientWith((req) async {
        calls++;
        if (req.headers['If-None-Match'] == '"e1"') {
          return http.Response('', 304);
        }
        return json(
          {
            'object': {'sha': 'abc'},
          },
          headers: {'etag': '"e1"'},
        );
      }, cache: cache);
      expect(await c.getBranchHeadSha('o', 'r', 'feature/x'), 'abc');
      expect(requests.single.url.path, '/repos/o/r/git/ref/heads/feature/x');
      expect(await c.getBranchHeadSha('o', 'r', 'feature/x'), 'abc');
      expect(calls, 2);
    });

    test('getCommit / getTree / getBlobRaw / getRepo / listBranches', () async {
      final c = clientWith((req) async {
        final p = req.url.path;
        if (p.endsWith('/git/commits/c1')) {
          return json({
            'sha': 'c1',
            'tree': {'sha': 't1'},
            'parents': [
              {'sha': 'p0'},
            ],
            'message': 'm',
          });
        }
        if (p.endsWith('/git/trees/t1')) {
          expect(req.url.queryParameters['recursive'], '1');
          return json({
            'sha': 't1',
            'truncated': true,
            'tree': [
              {
                'path': 'a.md',
                'type': 'blob',
                'sha': 'b1',
                'mode': '100644',
                'size': 3,
              },
              {'path': 'dir', 'type': 'tree', 'sha': 't2', 'mode': '040000'},
            ],
          });
        }
        if (p.endsWith('/git/blobs/b1')) {
          expect(req.headers['Accept'], 'application/vnd.github.raw+json');
          return http.Response.bytes([1, 2, 3], 200);
        }
        if (p.endsWith('/branches')) {
          return json([
            {
              'name': 'main',
              'commit': {'sha': 'c1'},
            },
          ]);
        }
        return json({
          'owner': {'login': 'o'},
          'name': 'r',
          'full_name': 'o/r',
          'private': true,
          'default_branch': 'dev',
          'updated_at': 'bad',
        });
      });
      final commit = await c.getCommit('o', 'r', 'c1');
      expect(commit.treeSha, 't1');
      expect(commit.parents, ['p0']);
      final tree = await c.getTree('o', 'r', 't1');
      expect(tree.truncated, isTrue);
      expect(tree.entries.first.size, 3);
      expect(tree.entries.first.toJson()['path'], 'a.md');
      expect(tree.entries.last.size, isNull);
      expect(await c.getBlobRaw('o', 'r', 'b1'), [1, 2, 3]);
      final repo = await c.getRepo('o', 'r');
      expect(repo.defaultBranch, 'dev');
      expect(repo.updatedAt, DateTime(1970));
      expect((await c.listBranches('o', 'r')).single.sha, 'c1');
    });

    test('create blob/tree/commit and update ref', () async {
      final c = clientWith((req) async {
        final body = req.body.isEmpty
            ? const <String, dynamic>{}
            : jsonDecode(req.body) as Map<String, dynamic>;
        switch (req.url.path) {
          case '/repos/o/r/git/blobs':
            expect(body['encoding'], 'base64');
            expect(base64Decode(body['content'] as String), [104, 105]);
            return json({'sha': 'b9'}, status: 201);
          case '/repos/o/r/git/trees':
            expect(body['base_tree'], 't1');
            expect(body['tree'], [
              {'path': 'a', 'mode': '100644', 'type': 'blob', 'sha': 'b9'},
              {'path': 'gone', 'mode': '100644', 'type': 'blob', 'sha': null},
            ]);
            return json({'sha': 't9'}, status: 201);
          case '/repos/o/r/git/commits':
            expect(body, {
              'message': 'msg',
              'tree': 't9',
              'parents': ['c1'],
            });
            return json({'sha': 'c9'}, status: 201);
          case '/repos/o/r/git/refs/heads/main':
            expect(req.method, 'PATCH');
            expect(body, {'sha': 'c9', 'force': false});
            return json({});
          case '/repos/o/r/git/refs':
            expect(body, {'ref': 'refs/heads/new', 'sha': 'c9'});
            return json({}, status: 201);
        }
        return http.Response('nope', 500);
      });
      expect(
        await c.createBlob('o', 'r', Uint8List.fromList([104, 105])),
        'b9',
      );
      expect(
        await c.createTree(
          'o',
          'r',
          baseTree: 't1',
          items: const [
            TreeItem(path: 'a', sha: 'b9'),
            TreeItem(path: 'gone', sha: null),
          ],
        ),
        't9',
      );
      expect(
        await c.createCommit(
          'o',
          'r',
          message: 'msg',
          tree: 't9',
          parents: ['c1'],
        ),
        'c9',
      );
      await c.updateRef('o', 'r', 'main', 'c9');
      await c.createRef('o', 'r', 'new', 'c9');
    });

    test('putContents', () async {
      final c = clientWith((req) async {
        expect(req.method, 'PUT');
        expect(req.url.path, '/repos/o/r/contents/notes/my%20note.md');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['sha'], 'old');
        expect(body['branch'], 'main');
        return json({
          'content': {'sha': 'new'},
          'commit': {
            'sha': 'c2',
            'tree': {'sha': 't2'},
          },
        });
      });
      final r = await c.putContents(
        'o',
        'r',
        'notes/my note.md',
        message: 'm',
        content: Uint8List(1),
        branch: 'main',
        sha: 'old',
      );
      expect(r.contentSha, 'new');
      expect(r.commitSha, 'c2');
      expect(r.treeSha, 't2');
    });

    test('rate limit', () async {
      final c = clientWith(
        (_) async => json({
          'resources': {
            'core': {'limit': 5000, 'remaining': 10, 'reset': 1000},
          },
        }),
      );
      final rl = await c.getRateLimit();
      expect(rl.remaining, 10);
      expect(rl.resetAt.millisecondsSinceEpoch, 1000000);
    });

    test('errors carry status, message and rate limit info', () async {
      final c = clientWith(
        (_) async => json(
          {'message': 'API rate limit exceeded'},
          status: 403,
          headers: {'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '2000'},
        ),
      );
      try {
        await c.getUser();
        fail('should throw');
      } on GitHubApiException catch (e) {
        expect(e.statusCode, 403);
        expect(e.message, 'API rate limit exceeded');
        expect(e.isRateLimited, isTrue);
        expect(e.rateLimitResetAt!.millisecondsSinceEpoch, 2000000);
        expect(e.toString(), contains('403'));
      }
    });

    test('retry-after and non-json error', () async {
      final c = clientWith(
        (_) async =>
            http.Response('<html>', 429, headers: {'retry-after': '30'}),
      );
      try {
        await c.getUser();
        fail('should throw');
      } on GitHubApiException catch (e) {
        expect(e.isRateLimited, isTrue);
        expect(e.rateLimitResetAt!.isAfter(DateTime.now()), isTrue);
      }
      expect(const GitHubApiException(404, 'x').rateLimitResetAt, isNull);
    });

    test('transport errors become status 0', () async {
      final c = clientWith((_) async => throw http.ClientException('down'));
      await expectLater(
        c.getUser(),
        throwsA(
          isA<GitHubApiException>()
              .having((e) => e.statusCode, 'status', 0)
              .having((e) => e.isNetworkError, 'network', isTrue),
        ),
      );
    });
  });

  group('GitHubDeviceFlow', () {
    final code = DeviceCodeResponse(
      deviceCode: 'dc',
      userCode: 'ABCD-1234',
      verificationUri: Uri.parse('https://github.com/login/device'),
      expiresIn: 900,
      interval: 5,
    );

    test('requestCode', () async {
      final flow = GitHubDeviceFlow(
        clientId: 'cid',
        client: MockClient((req) async {
          expect(req.url.path, '/login/device/code');
          expect(req.bodyFields, {
            'client_id': 'cid',
            'scope': 'repo read:user',
          });
          return json({
            'device_code': 'dc',
            'user_code': 'ABCD-1234',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          });
        }),
      );
      final r = await flow.requestCode();
      expect(r.userCode, 'ABCD-1234');
      expect(r.verificationUri.host, 'github.com');
    });

    test('requestCode error', () async {
      final flow = GitHubDeviceFlow(
        clientId: 'cid',
        client: MockClient(
          (_) async => json({'error': 'device_flow_disabled'}),
        ),
      );
      expect(
        flow.requestCode(),
        throwsA(
          isA<GitHubApiException>().having(
            (e) => e.errorCode,
            'code',
            'device_flow_disabled',
          ),
        ),
      );
    });

    test('pending then slow_down then success', () async {
      final delays = <int>[];
      final responses = [
        {'error': 'authorization_pending'},
        {'error': 'slow_down'},
        {'access_token': 'gho_x', 'token_type': 'bearer'},
      ];
      final flow = GitHubDeviceFlow(
        clientId: 'cid',
        delay: (d) async => delays.add(d.inSeconds),
        client: MockClient((req) async {
          expect(
            req.bodyFields['grant_type'],
            'urn:ietf:params:oauth:grant-type:device_code',
          );
          return json(responses.removeAt(0));
        }),
      );
      expect(await flow.pollForToken(code), 'gho_x');
      expect(delays, [5, 5, 10]);
    });

    for (final err in ['expired_token', 'access_denied']) {
      test(err, () async {
        final flow = GitHubDeviceFlow(
          clientId: 'cid',
          delay: (_) async {},
          client: MockClient((_) async => json({'error': err})),
        );
        await expectLater(
          flow.pollForToken(code),
          throwsA(
            isA<GitHubApiException>().having((e) => e.errorCode, 'code', err),
          ),
        );
      });
    }

    test('pollOnce reports pending, slow down, token and failure', () async {
      final responses = <Map<String, dynamic>>[
        {'error': 'authorization_pending'},
        {'error': 'slow_down'},
        {'access_token': 'gho_x'},
        {'error': 'access_denied'},
      ];
      final flow = GitHubDeviceFlow(
        clientId: 'cid',
        client: MockClient((req) async {
          expect(req.bodyFields['device_code'], 'dc');
          return json(responses.removeAt(0));
        }),
      );
      expect(
        await flow.pollOnce(code),
        isA<DevicePollPending>().having((r) => r.interval, 'interval', 5),
      );
      expect(
        await flow.pollOnce(code),
        isA<DevicePollPending>().having((r) => r.interval, 'interval', 10),
      );
      expect(
        await flow.pollOnce(code),
        isA<DevicePollToken>().having((r) => r.token, 'token', 'gho_x'),
      );
      expect(
        await flow.pollOnce(code),
        isA<DevicePollFailed>().having(
          (r) => r.error.errorCode,
          'code',
          'access_denied',
        ),
      );
    });

    test('immediate polling skips the first wait', () async {
      final delays = <int>[];
      final flow = GitHubDeviceFlow(
        clientId: 'cid',
        delay: (d) async => delays.add(d.inSeconds),
        client: MockClient((_) async => json({'access_token': 'gho_now'})),
      );
      expect(await flow.pollForToken(code, immediate: true), 'gho_now');
      expect(delays, isEmpty, reason: 'the app polls at once when it resumes');
    });

    test('cancel', () async {
      final flow = GitHubDeviceFlow(
        clientId: 'cid',
        delay: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
        client: MockClient(
          (_) async => json({'error': 'authorization_pending'}),
        ),
      );
      await expectLater(
        flow.pollForToken(code, cancel: Future<void>.value()),
        throwsA(
          isA<GitHubApiException>().having(
            (e) => e.errorCode,
            'code',
            'cancelled',
          ),
        ),
      );
    });

    test('local expiry', () async {
      var now = DateTime(2026);
      final flow = GitHubDeviceFlow(
        clientId: 'cid',
        now: () => now,
        delay: (_) async => now = now.add(const Duration(hours: 1)),
        client: MockClient(
          (_) async => json({'error': 'authorization_pending'}),
        ),
      );
      await expectLater(
        flow.pollForToken(code),
        throwsA(
          isA<GitHubApiException>().having(
            (e) => e.errorCode,
            'code',
            'expired_token',
          ),
        ),
      );
    });

    test('non-json response', () async {
      final flow = GitHubDeviceFlow(
        clientId: 'cid',
        client: MockClient((_) async => http.Response('<html>', 500)),
      );
      await expectLater(flow.requestCode(), throwsA(isA<GitHubApiException>()));
    });
  });
}
