// ignore_for_file: avoid_dynamic_calls

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/services/html_sanitizer.dart';
import 'package:gitscholar/infrastructure/local/secure_store.dart';
import 'package:gitscholar/presentation/agent/agent_controller.dart';
import 'package:gitscholar/presentation/agent/agent_pane.dart';
import 'package:gitscholar/presentation/auth/sign_in_screen.dart';
import 'package:gitscholar/presentation/core/providers.dart';
import 'package:gitscholar/presentation/editing/changes_screen.dart';
import 'package:gitscholar/presentation/repositories/repository_list_screen.dart';
import 'package:gitscholar/presentation/viewers/code/code_viewer.dart';
import 'package:gitscholar/presentation/viewers/common/sandboxed_html_view.dart';
import 'package:gitscholar/presentation/viewers/markdown/markdown_body.dart';
import 'package:gitscholar/presentation/workspace/files_pane.dart';
import 'package:gitscholar/presentation/workspace/workspace_shell.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../fakes/app_harness.dart';
import '../fakes/fake_anthropic.dart';
import '../fakes/fake_github.dart';
import '../fakes/test_env.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Unmounts the app and lets drift/stream cleanup timers run before the
/// test ends (otherwise pending timers fail the test and block DB close).
Future<void> disposeTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(seconds: 2));
  }
}

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    env.github.seed({
      'README.md': '# Research\n\nSee `notes/a.md`.\n',
      'notes/a.md': 'Precision note\n',
      'notebooks/analysis.ipynb':
          '{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}',
      for (var i = 0; i < 300; i++) 'data/file_$i.csv': 'x\n',
    });
  });
  tearDown(() async => env.dispose());

  group('pure helpers', () {
    test('stripScripts removes scripts and handlers', () {
      final html = stripScripts(
        '<div onclick="evil()">x</div><script>alert(1)</script><a href="javascript:x">y</a><SCRIPT src=a></SCRIPT>',
      );
      expect(html, isNot(contains('script')));
      expect(html, isNot(contains('onclick')));
      expect(html, isNot(contains('javascript:')));
      expect(html, contains('<div>x</div>'));
      expect(wrapHtmlDocument('<b>x</b>'), contains("default-src 'none'"));
    });

    test('sandbox blocks navigation', () {
      expect(
        SandboxedHtmlView.decide(
          NavigationRequest(url: 'https://evil.example', isMainFrame: true),
        ),
        NavigationDecision.prevent,
      );
      expect(
        SandboxedHtmlView.decide(
          NavigationRequest(url: 'about:blank', isMainFrame: true),
        ),
        NavigationDecision.navigate,
      );
    });

    test('line endings restored for CRLF files', () {
      expect(restoreLineEndings('a\nb\n', crlf: true), 'a\r\nb\r\n');
      expect(restoreLineEndings('a\nb\n', crlf: false), 'a\nb\n');
    });

    test('front matter and path linkify', () {
      final (fm, body) = splitFrontMatter('---\ntitle: X\n---\n# Body');
      expect(fm, 'title: X');
      expect(body, '# Body');
      expect(splitFrontMatter('# none').$1, isNull);
      final linked = linkifyRepositoryPaths(
        'Read `notes/a.md` and `missing.md`',
        {'notes/a.md'},
      );
      expect(linked, contains('[`notes/a.md`](gitscholar-path:notes%2Fa.md)'));
      expect(linked, contains('`missing.md`'));
    });
  });

  testWidgets('sign-in screen shows button when signed out', (tester) async {
    await tester.pumpWidget(
      harness(env, child: const SignInScreen(), auth: _SignedOutAuth.new),
    );
    await settle(tester);
    expect(find.byKey(const Key('signInButton')), findsOneWidget);
    expect(find.text('Sign in with GitHub'), findsOneWidget);
    await disposeTree(tester);
  });

  testWidgets('sign-in shows device code and copies it on tap', (tester) async {
    // SelectableText swallows taps, so the copy action has to be wired to it
    // and not only to the surrounding InkWell.
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add(((call.arguments as Map)['text'] ?? '') as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      harness(env, child: const SignInScreen(), auth: _PendingAuth.new),
    );
    await settle(tester);
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(find.text('Open in browser'), findsOneWidget);

    await tester.tap(find.byKey(const Key('userCode')));
    await settle(tester);
    expect(copied, ['ABCD-1234']);
    await disposeTree(tester);
  });

  Future<ProviderContainer> openShell(
    WidgetTester tester,
    Size size, {
    FakeAnthropic? anthropic,
    InMemorySecureStore? secure,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => env.db.upsertRepositories([env.repo]));
    await tester.pumpWidget(
      harness(
        env,
        size: size,
        anthropic: anthropic,
        secure: secure,
        child: const WorkspaceShell(owner: 'alice', name: 'research'),
      ),
    );
    await settle(tester);
    return ProviderScope.containerOf(
      tester.element(find.byType(WorkspaceShell)),
    );
  }

  testWidgets('tablet shows three panes; tree renders only visible rows', (
    tester,
  ) async {
    await openShell(tester, const Size(1200, 800));
    expect(find.byType(FilesPane), findsOneWidget);
    expect(find.byType(AgentPane), findsOneWidget);
    expect(find.byKey(const Key('phoneNav')), findsNothing);
    await tester.tap(find.text('data'));
    await settle(tester);
    final rows = find.byType(TreeRow).evaluate().length;
    expect(rows, greaterThan(10));
    expect(
      rows,
      lessThan(60),
      reason: 'ListView.builder must not build all 300 rows',
    );
    await disposeTree(tester);
  });

  testWidgets('phone uses bottom navigation and opens viewer on tap', (
    tester,
  ) async {
    final container = await openShell(tester, const Size(420, 800));
    expect(find.byKey(const Key('phoneNav')), findsOneWidget);
    await tester.tap(find.text('README.md'));
    await settle(tester);
    expect(container.read(shellProvider).phonePane, PhonePane.viewer);
    expect(container.read(openFilesProvider).active, 'README.md');
    await disposeTree(tester);
  });

  testWidgets('the viewer is never shown without a file', (tester) async {
    final container = await openShell(tester, const Size(420, 800));
    expect(container.read(openFilesProvider).active, isNull);
    // The viewer has no tab of its own; asking for it lands on the files.
    container.read(shellProvider.notifier).showPane(PhonePane.viewer);
    await settle(tester);
    expect(container.read(shellProvider).phonePane, PhonePane.files);

    await tester.tap(find.text('README.md'));
    await settle(tester);
    expect(container.read(shellProvider).phonePane, PhonePane.viewer);

    container.read(openFilesProvider.notifier).close('README.md');
    await settle(tester);
    expect(container.read(shellProvider).phonePane, PhonePane.files);
    await disposeTree(tester);
  });

  testWidgets('a shared file link opens the file, not just the repo', (
    tester,
  ) async {
    // 共有されたリンクは /ws/:owner/:repo?path=... として渡ってくる。
    await tester.pumpWidget(
      harness(
        env,
        size: const Size(420, 800),
        child: const WorkspaceShell(
          owner: 'alice',
          name: 'research',
          initialPath: 'notes/a.md',
        ),
      ),
    );
    await settle(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkspaceShell)),
    );
    expect(container.read(openFilesProvider).active, 'notes/a.md');
    // フォンではビューアに切り替わらないと、開いたことが画面に出ない。
    expect(container.read(shellProvider).phonePane, PhonePane.viewer);
    await disposeTree(tester);
  });

  testWidgets('threads pane lists discussions and posts a comment', (
    tester,
  ) async {
    final thread = env.github.seedThread(
      kind: ThreadKind.discussion,
      number: 7,
      title: 'Weekly meeting',
      body: 'agenda',
    );
    await openShell(tester, const Size(420, 800));
    await tester.tap(find.text('Threads'));
    await settle(tester);
    expect(find.text('Weekly meeting'), findsOneWidget);

    await tester.tap(find.text('Weekly meeting'));
    await settle(tester);
    expect(find.byKey(const Key('threadComment')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('threadComment')),
      'looks good',
    );
    await tester.tap(find.byKey(const Key('threadSend')));
    await settle(tester);
    expect(
      env.github.threadComments[FakeGitHub.threadKey(thread)]!.single.body,
      'looks good',
    );
    await disposeTree(tester);
  });

  testWidgets('a reaction can be added and taken back', (tester) async {
    env.github.seedThread(
      kind: ThreadKind.discussion,
      number: 7,
      title: 'Weekly meeting',
      body: 'agenda',
    );
    await openShell(tester, const Size(420, 800));
    await tester.tap(find.text('Threads'));
    await settle(tester);
    await tester.tap(find.text('Weekly meeting'));
    await settle(tester);

    await tester.tap(find.byKey(const Key('post-addReaction')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('pick-rocket')));
    await settle(tester);
    expect(
      env.github.reactions['node:discussion#7'],
      contains(ReactionKind.rocket),
    );
    expect(find.byKey(const Key('post-reaction-rocket')), findsOneWidget);

    // Tapping the chip again takes the reaction back.
    await tester.tap(find.byKey(const Key('post-reaction-rocket')));
    await settle(tester);
    expect(env.github.reactions['node:discussion#7'], isEmpty);
    expect(find.byKey(const Key('post-reaction-rocket')), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('threads pane switches to issues', (tester) async {
    env.github.seedThread(
      kind: ThreadKind.issue,
      number: 3,
      title: 'Fix the parser',
    );
    await openShell(tester, const Size(420, 800));
    await tester.tap(find.text('Threads'));
    await settle(tester);
    expect(find.text('Fix the parser'), findsNothing);

    await tester.tap(find.text('Issues'));
    await settle(tester);
    expect(find.text('Fix the parser'), findsOneWidget);
    expect(env.github.calls, contains('issues'));
    await disposeTree(tester);
  });

  testWidgets('editing creates a pending change shown in changes list', (
    tester,
  ) async {
    final container = await openShell(tester, const Size(1200, 800));
    final ws = container.read(currentWorkspaceProvider).value!;
    await tester.runAsync(
      () => env.editing.saveText(ws, 'notes/a.md', 'Edited note\n'),
    );
    await settle(tester);
    await disposeTree(tester);
    await tester.pumpWidget(
      harness(
        env,
        child: const ChangesScreen(),
        extraOverrides: [
          currentWorkspaceProvider.overrideWith(() => _FixedWorkspace(ws)),
        ],
      ),
    );
    await settle(tester);
    expect(find.text('notes/a.md'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.byKey(const Key('commitFab')), findsOneWidget);
    await disposeTree(tester);
  });

  testWidgets('AI panel: question, proposal, approval', (tester) async {
    final anthropic = FakeAnthropic([
      FakeAnthropic.toolUse('t1', 'propose_change', {
        'path': 'notes/a.md',
        'kind': 'modify',
        'edits': [
          {
            'old_text': 'Precision note',
            'new_text': 'Precision weighting note',
          },
        ],
        'explanation': 'Clarify wording',
      }),
      FakeAnthropic.text('I proposed a clearer wording.'),
    ]);
    final secure = InMemorySecureStore()
      ..values[SecureStore.githubToken] = 'tok'
      ..values[SecureStore.anthropicKey] = 'sk-test';
    await tester.runAsync(
      () => env.db.setRepositoryAiAccess('alice/research', AiAccess.allowed),
    );
    final container = await openShell(
      tester,
      const Size(1400, 900),
      anthropic: anthropic,
      secure: secure,
    );
    await tester.runAsync(
      () => env.db.setRepositoryAiAccess('alice/research', AiAccess.allowed),
    );
    await container
        .read(currentWorkspaceProvider.notifier)
        .setAiAccess(AiAccess.allowed);
    container.read(openFilesProvider.notifier).open('notes/a.md');
    await settle(tester);
    expect(find.textContaining('notes/a.md'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('agentInput')),
      'Improve this note',
    );
    await tester.tap(find.byKey(const Key('agentSend')));
    await settle(tester);
    await settle(tester);

    final sent = anthropic.requests.first;
    final firstUser =
        ((sent['messages'] as List).first as Map)['content'] as List;
    expect(firstUser.first['text'], contains('<open_file path="notes/a.md"'));
    expect(firstUser.first['text'], contains('Precision note'));
    expect(find.text('I proposed a clearer wording.'), findsOneWidget);
    expect(find.byKey(const Key('approveProposal')), findsOneWidget);

    // Not applied before approval.
    final ws = container.read(currentWorkspaceProvider).value!;
    final before = await tester.runAsync(
      () => env.workspaces.loadFile(ws, 'notes/a.md'),
    );
    expect(before!.text, 'Precision note\n');

    await tester.tap(find.byKey(const Key('approveProposal')));
    await settle(tester);
    final after = await tester.runAsync(
      () => env.workspaces.loadFile(ws, 'notes/a.md'),
    );
    expect(after!.text, 'Precision weighting note\n');
    expect(
      container
          .read(agentControllerProvider)
          .items
          .whereType<ProposalChatItem>()
          .single
          .proposal
          .status,
      ProposalStatus.approved,
    );
    await disposeTree(tester);
  });

  testWidgets('pinned repositories are listed first', (tester) async {
    final repos = [
      for (var i = 1; i <= 3; i++)
        RepositoryRef(
          owner: 'o',
          name: 'r$i',
          isPrivate: false,
          defaultBranch: 'main',
          updatedAt: DateTime(2026, 1, i),
        ),
    ];
    await tester.runAsync(() async {
      await env.db.upsertRepositories(repos);
      await env.db.setPinnedAt('o/r2', DateTime(2026, 5));
    });
    await tester.pumpWidget(
      harness(env, child: const RepositoryListScreen(restoreLast: false)),
    );
    await settle(tester);
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('o/r2'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('o/r2')).dy,
      lessThan(tester.getTopLeft(find.text('o/r1')).dy),
      reason: 'the pinned repository is above the others',
    );
    // The pin button toggles it back off.
    await tester.tap(find.byKey(const Key('pin-o/r2')));
    await settle(tester);
    expect(find.text('Pinned'), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('AI panel reports missing API key', (tester) async {
    final container = await openShell(tester, const Size(1400, 900));
    await container
        .read(currentWorkspaceProvider.notifier)
        .setAiAccess(AiAccess.allowed);
    await tester.enterText(find.byKey(const Key('agentInput')), 'Hello');
    await tester.tap(find.byKey(const Key('agentSend')));
    await settle(tester);
    expect(find.text('Anthropic API key is not set'), findsOneWidget);
    await disposeTree(tester);
  });
}

class _SignedOutAuth extends AuthController {
  @override
  Future<AuthState> build() async => const SignedOut();
}

class _PendingAuth extends AuthController {
  @override
  Future<AuthState> build() async => PendingDeviceCode(
    userCode: 'ABCD-1234',
    verificationUri: Uri.parse('https://github.com/login/device'),
    expiresAt: DateTime.now().add(const Duration(minutes: 15)),
  );
}

class _FixedWorkspace extends WorkspaceController {
  _FixedWorkspace(this.ws);

  final Workspace ws;

  @override
  Future<Workspace?> build() async => ws;
}
