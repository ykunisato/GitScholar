import 'dart:convert';

import 'package:github_api/github_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  late List<http.Request> requests;
  late List<String> bodies;

  GitHubClient clientWith(Future<http.Response> Function(http.Request) h) {
    requests = [];
    bodies = [];
    return GitHubClient(
      token: 'tok',
      client: MockClient((req) {
        requests.add(req);
        bodies.add(req.body);
        return h(req);
      }),
    );
  }

  group('issues', () {
    test('listIssues drops pull requests', () async {
      final c = clientWith(
        (_) async => json([
          {
            'number': 3,
            'title': 'Bug',
            'user': {'login': 'bob'},
            'updated_at': '2026-09-01T00:00:00Z',
            'comments': 2,
            'state': 'open',
            'html_url': 'https://github.com/a/b/issues/3',
          },
          {
            'number': 4,
            'title': 'A PR',
            'user': {'login': 'bob'},
            'updated_at': '2026-09-02T00:00:00Z',
            'comments': 0,
            'state': 'open',
            'html_url': 'https://github.com/a/b/pull/4',
            'pull_request': {'url': 'x'},
          },
        ]),
      );
      final issues = await c.listIssues('a', 'b');
      expect(issues.map((i) => i.number), [3]);
      expect(issues.single.commentCount, 2);
      expect(issues.single.isOpen, isTrue);
      expect(requests.single.url.query, contains('state=open'));
    });

    test('createIssueComment posts the body', () async {
      final c = clientWith(
        (_) async => json({
          'id': 9,
          'user': {'login': 'alice'},
          'body': 'thanks',
          'created_at': '2026-09-03T00:00:00Z',
        }),
      );
      final comment = await c.createIssueComment('a', 'b', 3, 'thanks');
      expect(comment.author, 'alice');
      expect(comment.body, 'thanks');
      expect(jsonDecode(bodies.single), {'body': 'thanks'});
      expect(requests.single.method, 'POST');
    });
  });

  group('discussions', () {
    test('listDiscussions maps nodes', () async {
      final c = clientWith(
        (_) async => json({
          'data': {
            'repository': {
              'hasDiscussionsEnabled': true,
              'discussions': {
                'nodes': [
                  {
                    'id': 'D_1',
                    'number': 7,
                    'title': 'Weekly',
                    'url': 'https://github.com/a/b/discussions/7',
                    'updatedAt': '2026-09-05T00:00:00Z',
                    'author': {'login': 'carol'},
                    'category': {'name': 'General'},
                    'comments': {'totalCount': 4},
                  },
                ],
              },
            },
          },
        }),
      );
      final list = await c.listDiscussions('a', 'b');
      expect(list, isNotNull);
      expect(list!.single.number, 7);
      expect(list.single.nodeId, 'D_1');
      expect(list.single.category, 'General');
      expect(list.single.commentCount, 4);
      expect(requests.single.url.path, '/graphql');
    });

    test('listDiscussions returns null when discussions are off', () async {
      final c = clientWith(
        (_) async => json({
          'data': {
            'repository': {'hasDiscussionsEnabled': false},
          },
        }),
      );
      expect(await c.listDiscussions('a', 'b'), isNull);
    });

    test('graphql errors become exceptions', () async {
      final c = clientWith(
        (_) async => json({
          'data': null,
          'errors': [
            {'message': 'Resource not accessible', 'type': 'FORBIDDEN'},
          ],
        }),
      );
      await expectLater(
        c.listDiscussions('a', 'b'),
        throwsA(
          isA<GitHubApiException>()
              .having((e) => e.message, 'message', 'Resource not accessible')
              .having((e) => e.errorCode, 'errorCode', 'FORBIDDEN'),
        ),
      );
    });

    test('getDiscussion selects comments once and parses them', () async {
      final c = clientWith(
        (_) async => json({
          'data': {
            'repository': {
              'discussion': {
                'id': 'D_1',
                'number': 7,
                'title': 'Weekly',
                'url': 'https://github.com/a/b/discussions/7',
                'updatedAt': '2026-09-05T00:00:00Z',
                'author': {'login': 'carol'},
                'category': {'name': 'General'},
                'body': 'agenda',
                'comments': {
                  'totalCount': 1,
                  'nodes': [
                    {
                      'id': 'DC_1',
                      'body': 'hi',
                      'createdAt': '2026-09-06T00:00:00Z',
                      'author': {'login': 'alice'},
                    },
                  ],
                },
              },
            },
          },
        }),
      );
      final d = await c.getDiscussion('a', 'b', 7);
      expect(d.body, 'agenda');
      expect(d.commentCount, 1);
      expect(d.comments.single.body, 'hi');
      expect(d.comments.single.author, 'alice');

      // GraphQL refuses a field selected twice with different arguments, so
      // the query must mention `comments` exactly once.
      final query =
          (jsonDecode(bodies.single) as Map<String, dynamic>)['query']
              as String;
      expect('comments'.allMatches(query), hasLength(1));
    });

    test('the detail query asks for reactions', () async {
      final c = clientWith(
        (_) async => json({
          'data': {
            'repository': {
              'discussion': {
                'id': 'D_1',
                'number': 7,
                'title': 'Weekly',
                'url': 'u',
                'updatedAt': '2026-09-05T00:00:00Z',
                'author': {'login': 'carol'},
                'category': {'name': 'General'},
                'body': 'agenda',
                'reactionGroups': [
                  {
                    'content': 'THUMBS_UP',
                    'viewerHasReacted': true,
                    'reactors': {'totalCount': 3},
                  },
                  {
                    'content': 'EYES',
                    'viewerHasReacted': false,
                    'reactors': {'totalCount': 0},
                  },
                ],
                'comments': {'totalCount': 0, 'nodes': <Object?>[]},
              },
            },
          },
        }),
      );
      final d = await c.getDiscussion('a', 'b', 7);
      expect(d.reactions, hasLength(2));
      expect(d.reactions.first.content, 'THUMBS_UP');
      expect(d.reactions.first.count, 3);
      expect(d.reactions.first.viewerHasReacted, isTrue);
      final query =
          (jsonDecode(bodies.single) as Map<String, dynamic>)['query']
              as String;
      // reactors is a connection, so it always gets a page size.
      expect(query, contains('reactors(first:1){totalCount}'));
    });

    test('reactionsFor keys groups by node id', () async {
      final c = clientWith(
        (_) async => json({
          'data': {
            'nodes': [
              {
                'id': 'I_1',
                'reactionGroups': [
                  {
                    'content': 'HEART',
                    'viewerHasReacted': false,
                    'reactors': {'totalCount': 2},
                  },
                ],
              },
              {'id': 'IC_1', 'reactionGroups': <Object?>[]},
            ],
          },
        }),
      );
      final map = await c.reactionsFor(['I_1', '', 'IC_1']);
      expect(map.keys, ['I_1', 'IC_1']);
      expect(map['I_1']!.single.count, 2);
      expect(map['IC_1'], isEmpty);
      final sent = jsonDecode(bodies.single) as Map<String, dynamic>;
      // Empty ids would make the query fail.
      expect(sent['variables'], {
        'ids': ['I_1', 'IC_1'],
      });
    });

    test('reactionsFor skips the request when there is no id', () async {
      final c = clientWith((_) async => json({'data': <String, Object?>{}}));
      expect(await c.reactionsFor(['', '']), isEmpty);
      expect(requests, isEmpty);
    });

    test('react picks the mutation and returns the new groups', () async {
      final c = clientWith(
        (_) async => json({
          'data': {
            'removeReaction': {
              'reactionGroups': [
                {
                  'content': 'ROCKET',
                  'viewerHasReacted': false,
                  'reactors': {'totalCount': 1},
                },
              ],
            },
          },
        }),
      );
      final groups = await c.react('D_1', 'ROCKET', add: false);
      expect(groups.single.viewerHasReacted, isFalse);
      expect(groups.single.count, 1);
      final sent = jsonDecode(bodies.single) as Map<String, dynamic>;
      expect('${sent['query']}', contains('removeReaction(input:'));
      expect('${sent['query']}', isNot(contains('addReaction')));
      expect(sent['variables'], {'id': 'D_1', 'content': 'ROCKET'});
    });

    test('createDiscussionComment sends the node id', () async {
      final c = clientWith(
        (_) async => json({
          'data': {
            'addDiscussionComment': {
              'comment': {
                'id': 'DC_1',
                'body': 'hi',
                'createdAt': '2026-09-06T00:00:00Z',
                'author': {'login': 'alice'},
              },
            },
          },
        }),
      );
      final comment = await c.createDiscussionComment('D_1', 'hi');
      expect(comment.id, 'DC_1');
      expect(comment.author, 'alice');
      final sent = jsonDecode(bodies.single) as Map<String, dynamic>;
      expect(sent['variables'], {'id': 'D_1', 'body': 'hi'});
      expect('${sent['query']}', contains('addDiscussionComment'));
    });
  });
}
