import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github_api/github_api.dart' show gitBlobSha;
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/infrastructure/local/app_database.dart';
import 'package:gitscholar/infrastructure/local/blob_store.dart';
import 'package:gitscholar/infrastructure/local/settings_store.dart';
import 'package:gitscholar/infrastructure/logging/app_logger.dart';

void main() {
  late AppDatabase db;
  late Directory dir;
  late FileBlobStore store;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('blobs');
    store = FileBlobStore(root: dir, db: db);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Uint8List bytes(int n, [int v = 1]) => Uint8List.fromList(List.filled(n, v));

  test('blob write/read/exists/delete', () async {
    final data = bytes(10);
    final sha = gitBlobSha(data);
    await store.write(sha, data, repoFullName: 'o/r');
    expect(await store.exists(sha), isTrue);
    expect(await store.read(sha), data);
    expect(await store.totalSize(), 10);
    expect(await store.sizeForRepo('o/r'), 10);
    await store.delete(sha);
    expect(await store.read(sha), isNull);
    expect(await store.totalSize(), 0);
    expect(() => store.read('../../x'), throwsArgumentError);
  });

  test('evict removes LRU but keeps pinned blobs', () async {
    final shas = <String>[];
    for (var i = 0; i < 3; i++) {
      final d = bytes(100, i + 1);
      final sha = gitBlobSha(d);
      shas.add(sha);
      await store.write(sha, d);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final now = DateTime.now();
    await db.putPendingChange(
      PendingChange(
        id: 'p',
        repoFullName: 'o/r',
        branch: 'main',
        path: 'a',
        kind: ChangeKind.modify,
        origin: ChangeOrigin.user,
        status: ChangeStatus.pending,
        baseCommitSha: 'c',
        contentSha: shas[0],
        createdAt: now,
        updatedAt: now,
      ),
    );
    await store.evict(targetBytes: 200);
    expect(await store.exists(shas[0]), isTrue, reason: 'pinned');
    expect(await store.exists(shas[1]), isFalse, reason: 'oldest unpinned');
    expect(await store.exists(shas[2]), isTrue);
    await store.clear();
    expect(await store.exists(shas[0]), isTrue);
    expect(await store.exists(shas[2]), isFalse);
  });

  test('workspace save replaces tree entries', () async {
    final repo = RepositoryRef(
      owner: 'o',
      name: 'r',
      isPrivate: false,
      defaultBranch: 'main',
      updatedAt: DateTime(2026),
    );
    await db.upsertRepositories([repo]);
    Workspace ws(List<String> paths) => Workspace(
      repo: repo,
      branch: 'main',
      baseCommitSha: 'c',
      treeSha: 't',
      entries: [
        for (final p in paths)
          TreeEntry(path: p, type: TreeEntryType.blob, sha: 's$p'),
      ],
      truncated: false,
      fetchedAt: DateTime(2026),
    );
    await db.saveWorkspace(ws(['a', 'b']));
    await db.saveWorkspace(ws(['c']));
    final loaded = await db.loadWorkspace(repo, 'main');
    expect(loaded!.entries.map((e) => e.path), ['c']);
    await db.setRepositoryAiAccess('o/r', AiAccess.denied);
    expect((await db.repository('o/r'))!.aiAccess, AiAccess.denied);
    await db.deleteRepositoryData('o/r');
    expect(await db.loadWorkspace(repo, 'main'), isNull);
  });

  test('conversations, messages, proposals, key values', () async {
    final now = DateTime(2026);
    await db.putConversation(
      Conversation(
        id: 'c',
        repoFullName: 'o/r',
        title: 't',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.addMessage(
      StoredMessage(
        id: 'm',
        conversationId: 'c',
        role: 'assistant',
        blocks: const [
          {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
        ],
        usage: const {'output_tokens': 3},
        createdAt: now,
      ),
    );
    final msgs = await db.messagesFor('c');
    expect(msgs.single.blocks.single['signature'], 'sig');
    await db.putProposal(
      Proposal(
        id: 'p',
        conversationId: 'c',
        path: 'a',
        kind: 'modify',
        explanation: 'e',
        status: ProposalStatus.pending,
        pendingChangeId: 'x',
        createdAt: now,
      ),
    );
    expect((await db.proposal('p'))!.status, ProposalStatus.pending);
    await db.putCommitRequest(
      CommitRequest(
        id: 'r',
        conversationId: 'c',
        message: 'm',
        paths: const ['a'],
        status: CommitRequestStatus.awaitingUser,
        createdAt: now,
      ),
    );
    expect((await db.commitRequestsFor('c')).single.paths, ['a']);
    await db.deleteConversation('c');
    expect(await db.conversationsFor('o/r'), isEmpty);
    expect(await db.messagesFor('c'), isEmpty);

    final settings = SettingsStore(db);
    expect((await settings.load()).aiModel, 'claude-opus-5');
    await settings.save(const Settings(aiEffort: 'max'));
    expect((await settings.load()).aiEffort, 'max');
  });

  test('AppLogger masks secrets', () {
    expect(
      AppLogger.mask('Authorization: Bearer abc123'),
      'Authorization: Bearer ***',
    );
    expect(
      AppLogger.mask('{"api_key":"sk-ant-api03-SECRET"}'),
      '{"api_key":"***"}',
    );
    expect(AppLogger.mask('token=gho_abcdefghijkl'), 'token=***');
    expect(AppLogger.mask('key sk-ant-api03-verysecret'), 'key sk-ant-***');
    expect(AppLogger.mask('x gho_abcdefghijkl'), 'x gho_***');
  });
}
