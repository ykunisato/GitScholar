import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:github_api/github_api.dart' show gitBlobSha;
import 'package:gitscholar/application/editing/change_diff.dart';
import 'package:gitscholar/application/editing/notebook_diff.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/failures.dart';
import 'package:gitscholar/domain/services/tree_view.dart';
import 'package:nbformat/nbformat.dart';

import '../fakes/test_env.dart';

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    env.github.seed({
      'README.md': '# Research\n',
      'notes/a.md': 'line1\nline2\n',
      'notes/b.md': 'bee\n',
      'analysis/model.R': 'x <- 1\n',
    });
  });
  tearDown(() => env.dispose());

  group('WorkspaceService', () {
    test('refresh fetches tree, second refresh only reads head', () async {
      final ws = await env.open();
      expect(ws.entry('notes/a.md'), isNotNull);
      expect(ws.entry('notes')!.type, TreeEntryType.tree);
      env.github.calls.clear();
      final again = await env.workspaces.refresh(env.repo, 'main', current: ws);
      expect(again.changed, isFalse);
      expect(env.github.calls, ['head']);
      expect(await env.workspaces.cached(env.repo, 'main'), isNotNull);
    });

    test('loadFile caches blobs', () async {
      final ws = await env.open();
      final f1 = await env.workspaces.loadFile(ws, 'notes/a.md');
      expect(f1.text, 'line1\nline2\n');
      expect(f1.source, ContentSource.remote);
      expect(f1.kind, FileKind.markdown);
      env.github.calls.clear();
      final f2 = await env.workspaces.loadFile(ws, './notes//a.md');
      expect(f2.source, ContentSource.cache);
      expect(env.github.calls, isEmpty);
    });

    test('loadFile rejects traversal and missing paths', () async {
      final ws = await env.open();
      expect(
        () => env.workspaces.loadFile(ws, '../etc/passwd'),
        throwsA(isA<ValidationFailure>()),
      );
      expect(
        () => env.workspaces.loadFile(ws, 'nope.md'),
        throwsA(isA<NotFoundFailure>()),
      );
      expect(
        () => env.workspaces.loadFile(ws, 'notes'),
        throwsA(isA<NotFoundFailure>()),
      );
    });

    test('refresh detects upstream changes to pending files', () async {
      final ws = await env.open();
      await env.editing.saveText(ws, 'notes/a.md', 'mine\n');
      env.github.seed({
        'README.md': '# Research\n',
        'notes/a.md': 'theirs\n',
        'notes/b.md': 'bee\n',
        'analysis/model.R': 'x <- 1\n',
      });
      final r = await env.workspaces.refresh(env.repo, 'main', current: ws);
      expect(r.changed, isTrue);
      expect(r.changedPaths, {'notes/a.md'});
      expect((await env.pending(r.workspace)).single.upstreamChanged, isTrue);
    });

    test('offline repository list falls back to cache', () async {
      await env.workspaces.listRepositories();
      env.github.failNext = const NetworkFailure('offline');
      final list = await env.workspaces.listRepositories();
      expect(list.single.fullName, 'alice/research');
    });
  });

  group('EditingService', () {
    test('save, load pending, revert removes change', () async {
      final ws = await env.open();
      final c = await env.editing.saveText(ws, 'notes/a.md', 'changed\n');
      expect(c!.kind, ChangeKind.modify);
      expect(c.contentSha, gitBlobSha(b('changed\n')));
      final loaded = await env.workspaces.loadFile(ws, 'notes/a.md');
      expect(loaded.source, ContentSource.pending);
      expect(loaded.text, 'changed\n');
      await env.editing.saveText(ws, 'notes/a.md', 'again\n');
      expect(await env.pending(ws), hasLength(1));
      expect(
        await env.editing.saveText(ws, 'notes/a.md', 'line1\nline2\n'),
        isNull,
      );
      expect(await env.pending(ws), isEmpty);
      expect(await env.editing.saveText(ws, 'notes/b.md', 'bee\n'), isNull);
    });

    test('create, delete, rename and tree markers', () async {
      final ws = await env.open();
      await env.editing.createFile(ws, 'notes/new.md', b('hi'));
      expect(
        () => env.editing.createFile(ws, 'notes/b.md'),
        throwsA(isA<ValidationFailure>()),
      );
      await env.editing.deleteFile(ws, 'README.md');
      await env.editing.renameFile(ws, 'analysis/model.R', 'analysis/hier.R');
      final changes = await env.pending(ws);
      expect(changes.map((c) => c.kind), [
        ChangeKind.create,
        ChangeKind.delete,
        ChangeKind.rename,
      ]);
      final root = buildTree(ws.entries, changes);
      final all = filterFiles(root, '');
      final markers = {for (final n in all) n.path: n.marker};
      expect(markers['notes/new.md'], ChangeMarker.created);
      expect(markers['README.md'], ChangeMarker.deleted);
      expect(markers['analysis/model.R'], ChangeMarker.deleted);
      expect(markers['analysis/hier.R'], ChangeMarker.created);
      expect(
        () => env.workspaces.loadFile(ws, 'analysis/model.R'),
        throwsA(isA<NotFoundFailure>()),
      );
      expect(
        (await env.workspaces.loadFile(ws, 'analysis/hier.R')).text,
        'x <- 1\n',
      );
      // Deleting a pending create just discards it.
      expect(await env.editing.deleteFile(ws, 'notes/new.md'), isNull);
      expect(await env.pending(ws), hasLength(2));
    });

    test(
      'modify then delete converts to delete; modify then rename keeps content',
      () async {
        final ws = await env.open();
        await env.editing.saveText(ws, 'notes/b.md', 'x\n');
        final d = await env.editing.deleteFile(ws, 'notes/b.md');
        expect(d!.kind, ChangeKind.delete);
        expect(d.contentSha, isNull);
        await env.editing.saveText(ws, 'notes/a.md', 'y\n');
        final r = await env.editing.renameFile(ws, 'notes/a.md', 'notes/c.md');
        expect(r.kind, ChangeKind.rename);
        expect((await env.workspaces.loadFile(ws, 'notes/c.md')).text, 'y\n');
      },
    );
  });

  group('CommitService', () {
    test('single modify uses Contents API', () async {
      final ws = await env.open();
      final c = await env.editing.saveText(ws, 'notes/a.md', 'new\n');
      env.github.calls.clear();
      final out = await env.commits.commit(ws, [c!.id], message: 'Update note');
      expect(env.github.calls, contains('putFile'));
      expect(env.github.calls, isNot(contains('createTree')));
      expect(env.github.headFiles()['notes/a.md'], 'new\n');
      expect(out.workspace.baseCommitSha, out.result.commitSha);
      expect(out.workspace.entry('notes/a.md')!.sha, gitBlobSha(b('new\n')));
      expect(await env.pending(out.workspace), isEmpty);
      final saved = await env.db.loadWorkspace(env.repo, 'main');
      expect(saved!.baseCommitSha, out.result.commitSha);
    });

    test('multi-file commit with delete and rename via Git Data API', () async {
      final ws = await env.open();
      final ids = [
        (await env.editing.saveText(ws, 'notes/a.md', 'A\n'))!.id,
        (await env.editing.saveText(ws, 'notes/b.md', 'B\n'))!.id,
        (await env.editing.deleteFile(ws, 'README.md'))!.id,
        (await env.editing.renameFile(
          ws,
          'analysis/model.R',
          'analysis/hier.R',
        )).id,
      ];
      final keep = await env.editing.createFile(ws, 'later.md', b('later'));
      env.github.calls.clear();
      final out = await env.commits.commit(ws, ids, message: 'Big change');
      // 内容が変わる2件だけblobを作る。リネームは既存のblobを指すだけ。
      expect(env.github.calls.where((c) => c == 'createBlob'), hasLength(2));
      expect(
        env.github.calls,
        containsAllInOrder(['createTree', 'createCommit', 'updateRef']),
      );
      expect(env.github.headFiles(), {
        'notes/a.md': 'A\n',
        'notes/b.md': 'B\n',
        'analysis/hier.R': 'x <- 1\n',
      });
      final ws2 = out.workspace;
      expect(ws2.entry('README.md'), isNull);
      expect(ws2.entry('analysis/model.R'), isNull);
      expect(ws2.entry('analysis/hier.R')!.sha, gitBlobSha(b('x <- 1\n')));
      final remaining = await env.pending(ws2);
      expect(remaining.single.id, keep.id);
      expect(remaining.single.baseCommitSha, out.result.commitSha);
    });

    test('remote moved on another file: commits on top of new head', () async {
      final ws = await env.open();
      final c = await env.editing.saveText(ws, 'notes/a.md', 'mine\n');
      final other = await env.editing.saveText(ws, 'notes/b.md', 'mine b\n');
      final remoteHead = env.github.seed({
        'README.md': '# Changed remotely\n',
        'notes/a.md': 'line1\nline2\n',
        'notes/b.md': 'bee\n',
        'analysis/model.R': 'x <- 1\n',
      });
      final out = await env.commits.commit(ws, [
        c!.id,
        other!.id,
      ], message: 'Mine');
      final files = env.github.headFiles();
      expect(files['README.md'], '# Changed remotely\n');
      expect(files['notes/a.md'], 'mine\n');
      expect(env.github.commits[out.result.commitSha]!.parents, [remoteHead]);
    });

    test('conflict on same file, then overwrite succeeds', () async {
      final ws = await env.open();
      final c = await env.editing.saveText(ws, 'notes/a.md', 'mine\n');
      env.github.seed({
        'README.md': '# Research\n',
        'notes/a.md': 'theirs\n',
        'notes/b.md': 'bee\n',
        'analysis/model.R': 'x <- 1\n',
      });
      await expectLater(
        env.commits.commit(ws, [c!.id], message: 'Mine'),
        throwsA(
          isA<ConflictFailure>().having((e) => e.conflictingPaths, 'paths', [
            'notes/a.md',
          ]),
        ),
      );
      expect(env.github.headFiles()['notes/a.md'], 'theirs\n');
      final refreshed = (await env.db.loadWorkspace(env.repo, 'main'))!;
      final out = await env.commits.commit(
        refreshed,
        [c.id],
        message: 'Mine',
        overwritePaths: {'notes/a.md'},
      );
      expect(env.github.headFiles()['notes/a.md'], 'mine\n');
      expect(out.result.committedPaths, ['notes/a.md']);
    });

    test('offline keeps pending changes', () async {
      final ws = await env.open();
      final c = await env.editing.saveText(ws, 'notes/a.md', 'mine\n');
      env.github.failNext = const NetworkFailure('offline');
      await expectLater(
        env.commits.commit(ws, [c!.id], message: 'm'),
        throwsA(isA<NetworkFailure>()),
      );
      expect(await env.pending(ws), hasLength(1));
    });

    test('validations and new branch', () async {
      final ws = await env.open();
      expect(
        () => env.commits.commit(ws, const ['x'], message: ' '),
        throwsA(isA<ValidationFailure>()),
      );
      expect(
        () => env.commits.commit(ws, const [], message: 'm'),
        throwsA(isA<ValidationFailure>()),
      );
      final c = await env.editing.saveText(ws, 'notes/a.md', 'branch\n');
      final out = await env.commits.commit(
        ws,
        [c!.id],
        message: 'm',
        newBranch: 'feature',
      );
      expect(out.result.branch, 'feature');
      expect(env.github.headFiles(branch: 'feature')['notes/a.md'], 'branch\n');
      expect(env.github.headFiles()['notes/a.md'], 'line1\nline2\n');
    });

    test('proposed changes cannot be committed', () async {
      final ws = await env.open();
      final c = await env.editing.saveText(ws, 'notes/a.md', 'p\n');
      await env.db.putPendingChange(c!.copyWith(status: ChangeStatus.proposed));
      expect(
        () => env.commits.commit(ws, [c.id], message: 'm'),
        throwsA(isA<ValidationFailure>()),
      );
    });
  });

  group('diffs', () {
    test('ChangeDiffLoader text diff', () async {
      final ws = await env.open();
      final c = await env.editing.saveText(
        ws,
        'notes/a.md',
        'line1\nchanged\n',
      );
      final contents = await ChangeDiffLoader(
        blobs: env.blobs,
        workspaces: env.workspaces,
      ).load(ws, c!);
      expect(contents.computeStats()!.added, 1);
      expect(contents.unified(), contains('+changed'));
      expect(contents.isBinary, isFalse);
    });

    test('notebook diff by id reports modified, added and removed', () {
      final a = Notebook(
        cells: [
          CodeCell(id: 'c1', source: 'x = 1'),
          MarkdownCell(id: 'm1', source: '# T'),
          CodeCell(id: 'c2', source: 'gone'),
        ],
      );
      final bNb = Notebook(
        cells: [
          CodeCell(
            id: 'c1',
            source: 'x = 2',
            outputs: [StreamOutput(name: 'stdout', text: '2')],
          ),
          MarkdownCell(id: 'm1', source: '# T'),
          CodeCell(id: 'c3', source: 'new'),
        ],
      );
      final d = diffNotebooks(a, bNb);
      expect(d.map((e) => e.type), [
        CellChangeType.modified,
        CellChangeType.unchanged,
        CellChangeType.removed,
        CellChangeType.added,
      ]);
      expect(d.first.outputsChanged, isTrue);
      expect(d.first.sourceDiff, isNotEmpty);
    });

    test('notebook diff without ids pairs replaced cells', () {
      final a = Notebook(
        nbformatMinor: 4,
        cells: [
          CodeCell(source: 'a'),
          CodeCell(source: 'b'),
        ],
      );
      final bNb = Notebook(
        nbformatMinor: 4,
        cells: [
          CodeCell(source: 'a'),
          CodeCell(source: 'B'),
        ],
      );
      final d = diffNotebooks(a, bNb);
      expect(d.map((e) => e.type), [
        CellChangeType.unchanged,
        CellChangeType.modified,
      ]);
    });
  });
}
