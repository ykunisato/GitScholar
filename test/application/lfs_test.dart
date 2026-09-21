import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';

import '../fakes/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  test('an LFS pointer is replaced by the real content', () async {
    // Git の blob にはポインタしか入っていない。
    final pointer = env.github.seedLfs('abc123', '%PDF-1.7 real paper');
    env.github.seed({
      'papers/paper.pdf': utf8.decode(pointer),
      'notes/plain.md': '# ふつうのファイル\n',
    });
    final ws = await env.open();

    final file = await env.workspaces.loadFile(ws, 'papers/paper.pdf');
    expect(file.text, '%PDF-1.7 real paper');
    expect(env.github.calls, contains('lfs'));
    expect(file.source, ContentSource.remote);
  });

  test('the resolved content is cached, not the pointer', () async {
    final pointer = env.github.seedLfs('abc123', '%PDF-1.7 real paper');
    env.github.seed({'papers/paper.pdf': utf8.decode(pointer)});
    final ws = await env.open();

    await env.workspaces.loadFile(ws, 'papers/paper.pdf');
    env.github.calls.clear();
    final again = await env.workspaces.loadFile(ws, 'papers/paper.pdf');
    expect(again.text, '%PDF-1.7 real paper');
    expect(again.source, ContentSource.cache);
    expect(env.github.calls, isEmpty, reason: '2回目は取得しない');
  });

  test('a pointer already in the cache is resolved', () async {
    // LFS 対応前に開いたファイルは、キャッシュにポインタが入ったままになる。
    final pointer = env.github.seedLfs('abc123', '%PDF-1.7 real paper');
    env.github.seed({'papers/paper.pdf': utf8.decode(pointer)});
    final ws = await env.open();
    final sha = ws.entry('papers/paper.pdf')!.sha;
    await env.blobs.write(sha, pointer, repoFullName: env.repo.fullName);

    final file = await env.workspaces.loadFile(ws, 'papers/paper.pdf');
    expect(file.text, '%PDF-1.7 real paper');

    // キャッシュ自体も実体に置き換わり、次からは取得し直さない。
    final cached = await env.blobs.read(sha);
    expect(utf8.decode(cached!), '%PDF-1.7 real paper');
  });

  test('ordinary files are untouched', () async {
    env.github.seed({'notes/plain.md': '# ふつうのファイル\n'});
    final ws = await env.open();
    final file = await env.workspaces.loadFile(ws, 'notes/plain.md');
    expect(file.text, '# ふつうのファイル\n');
    expect(env.github.calls, isNot(contains('lfs')));
  });
}
