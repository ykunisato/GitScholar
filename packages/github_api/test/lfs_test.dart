import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:github_api/github_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  downloadTests();
  group('LfsPointer.parse', () {
    test('parses a pointer file', () {
      final p = LfsPointer.parse(
        b(
          'version https://git-lfs.github.com/spec/v1\n'
          'oid sha256:4d7a214614ab2935c943f9e0ff69d22ea\n'
          'size 12345\n',
        ),
      );
      expect(p, isNotNull);
      // バッチAPIは `sha256:` を付けない digest を受け取る。
      expect(p!.oid, '4d7a214614ab2935c943f9e0ff69d22ea');
      expect(p.hashAlgo, 'sha256');
      expect(p.size, 12345);
    });

    test('rejects content that is not a pointer', () {
      expect(LfsPointer.parse(b('%PDF-1.7\nreal document')), isNull);
      expect(LfsPointer.parse(b('')), isNull);
      expect(LfsPointer.parse(b('version something else\n')), isNull);
    });

    test('rejects a pointer missing its fields', () {
      expect(
        LfsPointer.parse(b('version https://git-lfs.github.com/spec/v1\n')),
        isNull,
      );
      expect(
        LfsPointer.parse(
          b(
            'version https://git-lfs.github.com/spec/v1\n'
            'oid sha256:abc\n',
          ),
        ),
        isNull,
      );
    });

    test('does not scan large files', () {
      // 本物のPDFを1バイトずつ走査しないための上限。
      final big = Uint8List(LfsPointer.maxPointerBytes + 1);
      expect(LfsPointer.parse(big), isNull);
    });

    test('binary content is not a pointer', () {
      expect(LfsPointer.parse(Uint8List.fromList([0, 1, 2, 255])), isNull);
    });
  });
}

void downloadTests() {
  group('downloadLfsObject', () {
    final content = b('%PDF-1.7 real document');
    final oid = '${sha256.convert(content)}';

    GitHubClient clientWith(Future<http.Response> Function(http.Request) h) =>
        GitHubClient(token: 'tok', client: MockClient(h));

    test('resolves the pointer and returns the content', () async {
      final requests = <http.Request>[];
      final c = clientWith((req) async {
        requests.add(req);
        if (req.url.path.endsWith('/objects/batch')) {
          return http.Response(
            jsonEncode({
              'objects': [
                {
                  'oid': oid,
                  'size': content.length,
                  'actions': {
                    'download': {
                      'href': 'https://lfs.example/obj',
                      'header': {'X-Token': 'abc'},
                    },
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response.bytes(content, 200);
      });

      final bytes = await c.downloadLfsObject(
        'alice',
        'lit-notes',
        LfsPointer(oid: oid, size: content.length),
      );
      expect(bytes, content);
      expect(
        requests.first.url.path,
        '/alice/lit-notes.git/info/lfs/objects/batch',
      );
      expect(requests.first.headers['Accept'], 'application/vnd.git-lfs+json');
      expect(requests.first.headers['Authorization'], startsWith('Basic '));
      expect(requests.last.headers['X-Token'], 'abc');
      // `sha256:` を付けて送ると、サーバは object does not exist を返す。
      final sent = (jsonDecode(requests.first.body) as Map)['objects'] as List;
      expect((sent.first as Map)['oid'], oid);
      expect('${(sent.first as Map)['oid']}', isNot(contains(':')));
    });

    test('falls back to a bearer token when basic is refused', () async {
      final auths = <String>[];
      final c = clientWith((req) async {
        if (req.url.path.endsWith('/objects/batch')) {
          auths.add(req.headers['Authorization']!);
          if (auths.length == 1) return http.Response('no', 401);
          return http.Response(
            jsonEncode({
              'objects': [
                {
                  'oid': oid,
                  'size': content.length,
                  'actions': {
                    'download': {'href': 'https://lfs.example/obj'},
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(content, 200);
      });
      await c.downloadLfsObject(
        'alice',
        'lit-notes',
        LfsPointer(oid: oid, size: content.length),
      );
      expect(auths.first, startsWith('Basic '));
      expect(auths.last, startsWith('Bearer '));
    });

    test('rejects content that does not match the pointer', () async {
      final c = clientWith((req) async {
        if (req.url.path.endsWith('/objects/batch')) {
          return http.Response(
            jsonEncode({
              'objects': [
                {
                  'oid': oid,
                  'size': content.length,
                  'actions': {
                    'download': {'href': 'https://lfs.example/obj'},
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(b('%PDF-1.7 tampered!!!!!'), 200);
      });
      await expectLater(
        c.downloadLfsObject(
          'alice',
          'lit-notes',
          LfsPointer(oid: oid, size: content.length),
        ),
        throwsA(isA<GitHubApiException>()),
      );
    });

    test('surfaces an error object from the batch API', () async {
      final c = clientWith(
        (_) async => http.Response(
          jsonEncode({
            'objects': [
              {
                'oid': oid,
                'size': content.length,
                'error': {'code': 404, 'message': 'Object does not exist'},
              },
            ],
          }),
          200,
        ),
      );
      await expectLater(
        c.downloadLfsObject(
          'alice',
          'lit-notes',
          LfsPointer(oid: oid, size: content.length),
        ),
        throwsA(
          isA<GitHubApiException>().having(
            (e) => e.message,
            'message',
            contains('does not exist'),
          ),
        ),
      );
    });
  });
}
