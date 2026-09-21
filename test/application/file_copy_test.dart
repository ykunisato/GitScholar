import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/application/editing/file_copy_service.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/failures.dart';

import '../fakes/fake_github.dart';
import '../fakes/test_env.dart';

void main() {
  late TestEnv env;
  late FileCopyService copier;
  late RepositoryRef mine;

  setUp(() async {
    env = await TestEnv.create();
    // 読み取り専用の配布元と、自分のリポジトリ。
    env.github.seed({'papers/shared.md': 'from upstream\n'});
    mine = RepositoryRef(
      owner: 'alice',
      name: 'notes',
      isPrivate: true,
      defaultBranch: 'main',
      updatedAt: DateTime(2026),
    );
    env.github.seed({'README.md': '# Notes\n'}, on: mine);
    await env.db.upsertRepositories([FakeGitHub.repo, mine]);
    copier = FileCopyService(editing: env.editing, workspaces: env.workspaces);
  });
  tearDown(() => env.dispose());

  Future<FileContent> sourceFile() async {
    final ws = await env.open();
    return env.workspaces.loadFile(ws, 'papers/shared.md');
  }

  test('copies into another repository as a pending change', () async {
    final result = await copier.copy(
      source: await sourceFile(),
      target: mine,
      targetPath: 'papers/shared.md',
    );
    expect(result.hasChange, isTrue);
    expect(result.replaced, isFalse);
    expect(result.change!.kind, ChangeKind.create);
    expect(result.change!.repoFullName, 'alice/notes');

    // 元のリポジトリには何も起きない。
    final sourcePending = await env.db.pendingChangesFor(
      FakeGitHub.repo.fullName,
      'main',
    );
    expect(sourcePending, isEmpty);
  });

  test('copying onto an existing file replaces it', () async {
    final result = await copier.copy(
      source: await sourceFile(),
      target: mine,
      targetPath: 'README.md',
    );
    expect(result.replaced, isTrue);
    expect(result.change!.kind, ChangeKind.modify);
  });

  test('copying identical bytes leaves nothing to commit', () async {
    final ws = await env.open();
    final same = await env.workspaces.loadFile(ws, 'papers/shared.md');
    await copier.copy(source: same, target: mine, targetPath: 'copy.md');
    // 2回目は同じ内容なので、変更としては残らない。
    final again = await copier.copy(
      source: same,
      target: mine,
      targetPath: 'copy.md',
    );
    expect(again.hasChange, isTrue, reason: '新規作成は保留中の変更として残る');
    expect(again.change!.kind, ChangeKind.create);
  });

  test('rejects a path that escapes the repository', () async {
    expect(
      () async => copier.copy(
        source: await sourceFile(),
        target: mine,
        targetPath: '../secrets.md',
      ),
      throwsA(isA<ValidationFailure>()),
    );
  });

  test('refuses to copy into a destination that uses Git LFS', () async {
    // 通常の blob として書くと LFS を迂回し、実体がリポジトリに残り続ける。
    env.github.seed({
      '.gitattributes': '*.pdf filter=lfs diff=lfs merge=lfs -text\n',
    }, on: mine);
    await expectLater(
      copier.copy(
        source: await sourceFile(),
        target: mine,
        targetPath: 'papers/paper.pdf',
      ),
      throwsA(isA<LfsUnsupportedFailure>()),
    );
    expect(await env.db.pendingChangesFor(mine.fullName, 'main'), isEmpty);
  });

  test('a destination without LFS is unaffected', () async {
    env.github.seed({'.gitattributes': '*.psd filter=lfs\n'}, on: mine);
    final result = await copier.copy(
      source: await sourceFile(),
      target: mine,
      targetPath: 'papers/paper.pdf',
    );
    expect(result.hasChange, isTrue);
  });

  test('suggests the source path as the destination', () {
    expect(FileCopyService.suggestPath('papers/a.md'), 'papers/a.md');
  });
}
