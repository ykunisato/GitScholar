// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/application/agent/agent_service.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/services/ignore_rules.dart';
import 'package:gitscholar/infrastructure/ai/context_builder.dart';
import 'package:gitscholar/infrastructure/ai/research_tools.dart';
import 'package:scholar_agent/scholar_agent.dart';

import '../fakes/fake_anthropic.dart';
import '../fakes/test_env.dart';

const notebook = '''
{"cells":[{"cell_type":"code","execution_count":1,"id":"c1","metadata":{},"outputs":[{"ename":"ValueError","evalue":"bad","output_type":"error","traceback":["ValueError: bad"]}],"source":["fit(model)"]}],
 "metadata":{"kernelspec":{"language":"python","name":"python3"}},"nbformat":4,"nbformat_minor":5}
''';

void main() {
  late TestEnv env;
  late Workspace ws;
  late ResearchTools tools;
  late Map<String, ToolHandler> h;
  final proposals = <Proposal>[];
  final requests = <CommitRequest>[];

  setUp(() async {
    env = await TestEnv.create();
    env.github.seed({
      'README.md': '# Research\n',
      'notes/precision.md':
          'Precision weighting and personality.\nSecond line.\n',
      'notes/other.md': 'Nothing here.\nprecision appears twice: precision\n',
      'notebooks/analysis.ipynb': notebook,
      '.env': 'SECRET=1\n',
      'papers/a.pdf': '%PDF-fake',
    });
    ws = await env.open();
    proposals.clear();
    requests.clear();
    tools = ResearchTools(
      ToolEnvironment(
        workspace: () => ws,
        workspaces: env.workspaces,
        editing: env.editing,
        db: env.db,
        blobs: env.blobs,
        rules: IgnoreRules.fromFile(null),
        conversationId: 'conv',
        onProposal: proposals.add,
        onCommitRequest: requests.add,
        pdfText: (bytes) async => ['page one text', 'page two'],
      ),
    );
    h = tools.handlers();
  });
  tearDown(() => env.dispose());

  test(
    'definitions are strict closed schemas; execution tools hidden without backend',
    () {
      final defs = tools.definitions();
      expect(defs.map((d) => d.name), [
        'list_files',
        'read_file',
        'search_repo',
        'propose_change',
        'get_diff',
        'request_commit',
      ]);
      for (final d in defs) {
        expect(d.strict, isTrue);
        expect(d.inputSchema['additionalProperties'], isFalse);
        expect(d.inputSchema['required'], isA<List<String>>());
      }
    },
  );

  test('list_files hides ignored files and respects path', () async {
    final root = await h['list_files']!({});
    expect(root.content, contains('dir  notes/'));
    expect(root.content, contains('file notes/precision.md'));
    expect(root.content, isNot(contains('.env')));
    final sub = await h['list_files']!({'path': 'notes', 'depth': 1});
    expect(sub.content, isNot(contains('README')));
    expect((await h['list_files']!({'path': 'README.md'})).isError, isTrue);
  });

  test(
    'read_file: numbered lines, ranges, notebook, pdf, ignored, traversal',
    () async {
      final r = await h['read_file']!({
        'path': 'notes/precision.md',
        'start_line': 2,
        'end_line': 2,
      });
      expect(r.content, contains('2\tSecond line.'));
      expect(r.content, isNot(contains('Precision weighting')));
      final nb = await h['read_file']!({'path': 'notebooks/analysis.ipynb'});
      expect(nb.content, contains('[cell 0, code]'));
      expect(nb.content, contains('ValueError: bad'));
      final pdf = await h['read_file']!({'path': 'papers/a.pdf'});
      expect(pdf.content, contains('page one text'));
      final secret = await h['read_file']!({'path': '.env'});
      expect(secret.isError, isTrue);
      expect(secret.content, contains('restricted'));
      expect((await h['read_file']!({'path': '../x'})).isError, isTrue);
      expect((await h['read_file']!({'path': 'missing.md'})).isError, isTrue);
    },
  );

  test('read_file sees pending content', () async {
    await env.editing.saveText(ws, 'notes/precision.md', 'edited\n');
    expect(
      (await h['read_file']!({'path': 'notes/precision.md'})).content,
      contains('edited'),
    );
  });

  test(
    'search_repo finds matches across files and skips ignored/pdf',
    () async {
      final r = await h['search_repo']!({'query': 'PRECISION'});
      expect(r.content, contains('notes/precision.md:1:'));
      expect(r.content, contains('notes/other.md:2:'));
      expect(r.content, isNot(contains('.env')));
      final limited = await h['search_repo']!({
        'query': 'precision',
        'max_results': 1,
      });
      expect(limited.content, contains('[result limit 1 reached]'));
      final scoped = await h['search_repo']!({
        'query': 'precision',
        'paths': ['notes/other.md'],
      });
      expect(scoped.content, isNot(contains('precision.md')));
      expect(
        (await h['search_repo']!({'query': 'fit\\(', 'regex': true})).content,
        contains('analysis.ipynb'),
      );
      expect(
        (await h['search_repo']!({'query': '(', 'regex': true})).isError,
        isTrue,
      );
      expect(
        (await h['search_repo']!({'query': 'zzz'})).content,
        contains('No matches'),
      );
    },
  );

  group('propose_change', () {
    test('old_text must occur exactly once', () async {
      final zero = await h['propose_change']!({
        'path': 'notes/other.md',
        'kind': 'modify',
        'edits': [
          {'old_text': 'absent', 'new_text': 'x'},
        ],
        'explanation': 'e',
      });
      expect(zero.isError, isTrue);
      expect(zero.content, contains('occurs 0 times'));
      final two = await h['propose_change']!({
        'path': 'notes/other.md',
        'kind': 'modify',
        'edits': [
          {'old_text': 'precision', 'new_text': 'x'},
        ],
        'explanation': 'e',
      });
      expect(two.content, contains('occurs 2 times'));
      expect(proposals, isEmpty);
    });

    test(
      'proposal is not visible until approved; approve applies it',
      () async {
        final r = await h['propose_change']!({
          'path': 'notes/precision.md',
          'kind': 'modify',
          'edits': [
            {'old_text': 'Second line.', 'new_text': 'Second line, revised.'},
          ],
          'explanation': 'clarify',
        });
        expect(r.isError, isFalse, reason: r.content);
        expect(jsonDecode(r.content)['diff_summary'], '+1 -1');
        expect(proposals.single.status, ProposalStatus.pending);
        expect(
          (await env.workspaces.loadFile(ws, 'notes/precision.md')).text,
          contains('Second line.\n'),
        );
        expect((await env.pending(ws)).single.status, ChangeStatus.proposed);

        // A second proposal for the same file builds on the first.
        final r2 = await h['propose_change']!({
          'path': 'notes/precision.md',
          'kind': 'modify',
          'edits': [
            {'old_text': 'revised', 'new_text': 'rewritten'},
          ],
          'explanation': 'more',
        });
        expect(jsonDecode(r2.content)['note'], contains('Replaced'));
        expect(await env.db.proposalsFor('conv'), hasLength(1));

        final agent = AgentService(
          db: env.db,
          blobs: env.blobs,
          editing: env.editing,
          clientFor: (_) => throw UnimplementedError(),
        );
        await agent.approveProposal(ws, proposals.last.id);
        final changes = await env.pending(ws);
        expect(changes.single.status, ChangeStatus.pending);
        expect(changes.single.origin, ChangeOrigin.ai);
        expect(
          (await env.workspaces.loadFile(ws, 'notes/precision.md')).text,
          contains('Second line, rewritten.'),
        );
        expect(
          (await env.db.proposal(proposals.last.id))!.status,
          ProposalStatus.approved,
        );
      },
    );

    test('reject removes proposed change and returns note', () async {
      await h['propose_change']!({
        'path': 'notes/new.md',
        'kind': 'create',
        'content': 'hello',
        'explanation': 'e',
      });
      final agent = AgentService(
        db: env.db,
        blobs: env.blobs,
        editing: env.editing,
        clientFor: (_) => throw UnimplementedError(),
      );
      final note = await agent.rejectProposal(proposals.single.id);
      expect(note, contains('rejected'));
      expect(await env.pending(ws), isEmpty);
    });

    test(
      'create existing and delete missing are errors; delete approved',
      () async {
        expect(
          (await h['propose_change']!({
            'path': 'README.md',
            'kind': 'create',
            'content': 'x',
            'explanation': 'e',
          })).isError,
          isTrue,
        );
        expect(
          (await h['propose_change']!({
            'path': 'nope.md',
            'kind': 'delete',
            'explanation': 'e',
          })).isError,
          isTrue,
        );
        expect(
          (await h['propose_change']!({
            'path': '.env',
            'kind': 'delete',
            'explanation': 'e',
          })).isError,
          isTrue,
        );
        await h['propose_change']!({
          'path': 'README.md',
          'kind': 'delete',
          'explanation': 'e',
        });
        final agent = AgentService(
          db: env.db,
          blobs: env.blobs,
          editing: env.editing,
          clientFor: (_) => throw UnimplementedError(),
        );
        await agent.approveProposal(ws, proposals.single.id);
        expect((await env.pending(ws)).single.kind, ChangeKind.delete);
      },
    );
  });

  test('get_diff shows pending and proposed changes', () async {
    await env.editing.saveText(ws, 'notes/other.md', 'changed\n');
    await h['propose_change']!({
      'path': 'notes/new.md',
      'kind': 'create',
      'content': 'hi\n',
      'explanation': 'e',
    });
    final d = await h['get_diff']!({});
    expect(d.content, contains('[uncommitted modify] notes/other.md'));
    expect(d.content, contains('+changed'));
    expect(d.content, contains('[proposed create] notes/new.md'));
  });

  test('request_commit never commits', () async {
    await env.editing.saveText(ws, 'notes/other.md', 'changed\n');
    final head = env.github.refs.values.single;
    final r = await h['request_commit']!({
      'message': 'Update',
      'paths': ['notes/other.md'],
    });
    expect(jsonDecode(r.content)['status'], 'awaiting_user');
    expect(requests.single.paths, ['notes/other.md']);
    expect(env.github.refs.values.single, head);
    expect(env.github.calls, isNot(contains('putFile')));
  });

  test(
    'ContextBuilder includes file, selection, tree; restricts ignored files',
    () async {
      final f = await env.workspaces.loadFile(ws, 'notes/precision.md');
      final ctx = ContextBuilder.build(
        workspace: ws,
        rules: IgnoreRules.fromFile(null),
        open: OpenFileContext(
          content: f,
          selection: const ViewerSelection(
            path: 'notes/precision.md',
            text: 'Second line.',
            startLine: 2,
            endLine: 2,
          ),
        ),
      );
      expect(
        ctx,
        contains('<repository name="alice/research" branch="main" />'),
      );
      expect(ctx, contains('selection_lines="2-2"'));
      expect(ctx, contains('Precision weighting'));
      expect(ctx, contains('<selection>\nSecond line.'));
      expect(ctx, contains('notes/'));
      final secret = await env.workspaces.loadFile(ws, '.env');
      final restricted = ContextBuilder.build(
        workspace: ws,
        rules: IgnoreRules.fromFile(null),
        open: OpenFileContext(content: secret),
      );
      expect(restricted, isNot(contains('SECRET')));
      final pdf = await env.workspaces.loadFile(ws, 'papers/a.pdf');
      final pages = List.generate(80, (i) => 'text of page ${i + 1}');
      final pdfCtx = ContextBuilder.build(
        workspace: ws,
        rules: IgnoreRules([]),
        open: OpenFileContext(content: pdf, pdfPages: pages, currentPage: 40),
      );
      expect(pdfCtx, contains('[pages 35-45 of 80]'));
      expect(pdfCtx, isNot(contains('text of page 1\n')));
    },
  );

  test('AgentService runs a tool turn and persists history', () async {
    final fake = FakeAnthropic([
      FakeAnthropic.toolUse('t1', 'read_file', {'path': 'README.md'}),
      FakeAnthropic.text('The README is a title.'),
    ]);
    final agent = AgentService(
      db: env.db,
      blobs: env.blobs,
      editing: env.editing,
      clientFor: (key) => AnthropicClient.withApiKey(key, client: fake.client),
    );
    final conv = await agent.createConversation(
      ws.repo,
      'What is in the README?',
    );
    final events = await agent
        .runTurn(
          conversation: conv,
          apiKey: 'sk-test',
          settings: const Settings(),
          userMessage: AgentService.userMessage(
            'What is in the README?',
            context: '<context/>',
          ),
          tools: tools.definitions(),
          handlers: h,
        )
        .toList();
    expect(events.last, isA<TurnFinished>());
    final first = fake.requests.first;
    expect(first['model'], 'claude-opus-5');
    expect(first['fallbacks'], 'default');
    expect(first['cache_control'], {'type': 'ephemeral'});
    expect((first['system'] as List).single['cache_control'], {
      'type': 'ephemeral',
    });
    expect(
      fake.headers.first['anthropic-beta'],
      contains('server-side-fallback-2026-07-01'),
    );
    expect(
      fake.headers.first['anthropic-beta'],
      contains('context-management-2025-06-27'),
    );
    final second = fake.requests[1]['messages'] as List;
    expect(
      ((second[2] as Map)['content'] as List).single['content'],
      contains('# Research'),
    );
    final history = await agent.history(conv.id);
    expect(history.map((m) => m.role), [
      'user',
      'assistant',
      'user',
      'assistant',
    ]);
    expect(conv.title, 'What is in the README?');
  });
}
