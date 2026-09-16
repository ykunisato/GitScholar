import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/presentation/agent/agent_controller.dart';
import 'package:gitscholar/presentation/core/providers.dart';

import '../fakes/test_env.dart';

/// Workspace controller whose value the test drives directly.
class _Switchable extends WorkspaceController {
  @override
  Future<Workspace?> build() async => null;

  void put(Workspace? ws) => state = AsyncData(ws);
}

Future<void> tick() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    env.github.seed({'README.md': '# Research\n'});
  });
  tearDown(() => env.dispose());

  ProviderContainer containerFor() {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(env.db),
        blobStoreProvider.overrideWithValue(env.blobs),
        currentWorkspaceProvider.overrideWith(_Switchable.new),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<Conversation> seedConversation(String id, String title) async {
    final c = Conversation(
      id: id,
      repoFullName: env.repo.fullName,
      title: title,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
    );
    await env.db.putConversation(c);
    return c;
  }

  test('closing the repository keeps the conversation', () async {
    final ws = await env.open();
    final container = containerFor();
    await container.read(currentWorkspaceProvider.future);
    final agent = container.read(agentControllerProvider.notifier);
    final workspace =
        container.read(currentWorkspaceProvider.notifier) as _Switchable;

    workspace.put(ws);
    await tick();
    await agent.load(await seedConversation('c1', 'Power analysis'));
    expect(container.read(agentControllerProvider).conversation?.id, 'c1');

    // Back arrow: the workspace closes but the session stays.
    workspace.put(null);
    await tick();
    expect(container.read(agentControllerProvider).conversation?.id, 'c1');

    // Reopening the same repository keeps it too.
    workspace.put(ws);
    await tick();
    expect(container.read(agentControllerProvider).conversation?.id, 'c1');
  });

  test('opening a repository restores its most recent conversation', () async {
    final ws = await env.open();
    await seedConversation('old', 'Older');
    await env.db.putConversation(
      Conversation(
        id: 'latest',
        repoFullName: env.repo.fullName,
        title: 'Newest',
        createdAt: DateTime.utc(2026, 9, 10),
        updatedAt: DateTime.utc(2026, 9, 10),
      ),
    );
    final container = containerFor();
    await container.read(currentWorkspaceProvider.future);
    container.read(agentControllerProvider);
    (container.read(currentWorkspaceProvider.notifier) as _Switchable).put(ws);
    await tick();
    expect(container.read(agentControllerProvider).conversation?.id, 'latest');
  });
}
