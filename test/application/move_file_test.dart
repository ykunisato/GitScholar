import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/failures.dart';
import 'package:gitscholar/domain/services/companion_files.dart';

import '../fakes/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    env.github.seed({
      'inbox/paper.pdf': '%PDF-1.7 fake\n',
      'inbox/paper.md': '# メモ\n',
      'inbox/paper.annotations.json': '{"version":1,"highlights":[]}',
      'inbox/plain.md': '# ふつうのファイル\n',
      'inbox/lonely.pdf': '%PDF-1.7 fake\n',
      'papers/2026/keep.md': '# すでにあるファイル\n',
    });
  });
  tearDown(() => env.dispose());

  PendingChange? changeFor(List<PendingChange> all, String path) {
    for (final c in all) {
      if (c.path == path) return c;
    }
    return null;
  }

  test('moves a file into another folder as a pending rename', () async {
    final ws = await env.open();
    await env.editing.moveFile(ws, 'inbox/plain.md', 'papers/2026');

    final change = (await env.pending(ws)).single;
    expect(change.kind, ChangeKind.rename);
    expect(change.oldPath, 'inbox/plain.md');
    expect(change.path, 'papers/2026/plain.md');
  });

  test('moves a file to the repository root', () async {
    final ws = await env.open();
    await env.editing.moveFile(ws, 'inbox/plain.md', '');
    expect((await env.pending(ws)).single.path, 'plain.md');
  });

  test('a PDF takes its highlights and notes along', () async {
    final ws = await env.open();
    await env.editing.moveFile(ws, 'inbox/paper.pdf', 'papers/2026');

    final pending = await env.pending(ws);
    expect(pending.length, 3);
    for (final path in [
      'papers/2026/paper.pdf',
      'papers/2026/paper.md',
      'papers/2026/paper.annotations.json',
    ]) {
      expect(changeFor(pending, path)?.kind, ChangeKind.rename, reason: path);
    }
  });

  test('companions that do not exist are not invented', () async {
    // マーカーもメモも無いPDF。作られてはいけない。
    final ws = await env.open();
    await env.editing.moveFile(ws, 'inbox/lonely.pdf', 'papers/2026');
    expect((await env.pending(ws)).single.path, 'papers/2026/lonely.pdf');
  });

  test('refuses to move onto an existing file', () async {
    final ws = await env.open();
    await expectLater(
      env.editing.moveFile(ws, 'inbox/plain.md', 'papers/2026'),
      completes,
    );
    await expectLater(
      env.editing.moveFile(ws, 'inbox/plain.md', 'papers/2026'),
      throwsA(isA<AppFailure>()),
    );
  });

  test('a blocked note leaves the PDF where it is', () async {
    env.github.seed({
      'inbox/paper.pdf': '%PDF-1.7 fake\n',
      'inbox/paper.md': '# メモ\n',
      'papers/2026/paper.md': '# 別のメモ\n',
    });
    final ws = await env.open();

    await expectLater(
      env.editing.moveFile(ws, 'inbox/paper.pdf', 'papers/2026'),
      throwsA(isA<ValidationFailure>()),
    );
    expect(await env.pending(ws), isEmpty, reason: 'PDFも動かない');
  });

  test('keeps an edit made before the move', () async {
    final ws = await env.open();
    await env.editing.saveText(ws, 'inbox/plain.md', '# 編集した\n');
    await env.editing.moveFile(ws, 'inbox/plain.md', 'papers/2026');

    final change = (await env.pending(ws)).single;
    expect(change.kind, ChangeKind.rename);
    expect(change.path, 'papers/2026/plain.md');
    final moved = await env.workspaces.loadFile(ws, 'papers/2026/plain.md');
    expect(moved.text, '# 編集した\n');
  });

  test('an LFS file keeps its pointer when moved and committed', () async {
    // 開いた時点でキャッシュにはPDFの実体が入る。移動でそれをblobとして
    // 送ってしまうと、LFSを迂回して実体がリポジトリに入る。
    final pointer = env.github.seedLfs('abc123', '%PDF-1.7 real paper');
    env.github.seed({'inbox/lfs.pdf': utf8.decode(pointer)});
    final ws = await env.open();
    expect(
      (await env.workspaces.loadFile(ws, 'inbox/lfs.pdf')).text,
      '%PDF-1.7 real paper',
    );

    final change = await env.editing.moveFile(ws, 'inbox/lfs.pdf', 'papers');
    env.github.calls.clear();
    await env.commits.commit(ws, [change.id], message: 'move');

    final head = env.github.headFiles();
    expect(head['papers/lfs.pdf'], utf8.decode(pointer));
    expect(head.containsKey('inbox/lfs.pdf'), isFalse);
    expect(env.github.calls, isNot(contains('createBlob')));
  });

  test('a moved file can still be opened before it is committed', () async {
    final ws = await env.open();
    await env.editing.moveFile(ws, 'inbox/plain.md', 'papers/2026');
    final file = await env.workspaces.loadFile(ws, 'papers/2026/plain.md');
    expect(file.text, '# ふつうのファイル\n');
    expect(file.source, ContentSource.pending);
  });

  group('companionPathsFor', () {
    test('lists the files that belong to a PDF', () {
      expect(companionPathsFor('papers/foo.pdf'), [
        'papers/foo.annotations.json',
        'papers/foo.md',
      ]);
      expect(companionPathsFor('papers/FOO.PDF'), [
        'papers/FOO.annotations.json',
        'papers/FOO.md',
      ]);
    });

    test('is empty for anything else', () {
      expect(companionPathsFor('notes/plain.md'), isEmpty);
      expect(companionPathsFor(''), isEmpty);
    });
  });
}
