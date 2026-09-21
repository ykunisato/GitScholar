import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/presentation/core/providers.dart';
import 'package:gitscholar/presentation/workspace/workspace_shell.dart';

import '../fakes/app_harness.dart';
import '../fakes/test_env.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

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
    env.github.seed({'inbox/a.md': 'Draft\n', 'papers/2026/keep.md': 'Kept\n'});
  });
  tearDown(() async => env.dispose());

  testWidgets('moves a file from the tree into another folder', (tester) async {
    // ボトムシートは実際の描画面ではなく MediaQuery の高さで自分の高さを決める。
    // 両者がずれているとシートがはみ出す。
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        env,
        child: const WorkspaceShell(
          owner: 'alice',
          name: 'research',
          initialPath: 'inbox/a.md',
        ),
      ),
    );
    await settle(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkspaceShell)),
    );

    // タブにも同じ名前が出るので、ツリーの行に限定する。
    final tree = find.byKey(const Key('fileTree'));
    await tester.tap(find.descendant(of: tree, matching: find.text('inbox')));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.descendant(of: tree, matching: find.text('a.md')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to another folder'));
    await tester.pumpAndSettle();

    // フォルダは階層のまま並ぶ。末端の名前で選ぶ。
    expect(find.byKey(const Key('moveTo-')), findsOneWidget);
    await tester.tap(find.byKey(const Key('moveTo-papers/2026')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moveConfirm')));
    await settle(tester);

    final pending = await env.db.pendingChangesFor('alice/research', 'main');
    expect(pending.single.kind, ChangeKind.rename);
    expect(pending.single.oldPath, 'inbox/a.md');
    expect(pending.single.path, 'papers/2026/a.md');
    // 開いていたタブも移動先を指す。
    expect(container.read(openFilesProvider).active, 'papers/2026/a.md');
    await disposeTree(tester);
  });
}
