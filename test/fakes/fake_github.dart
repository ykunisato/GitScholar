import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:github_api/github_api.dart' show gitBlobSha;
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/failures.dart';
import 'package:gitscholar/domain/repositories/github_repository.dart';

/// In-memory GitHub with Git Data API semantics (docs/10 §2).
class FakeGitHub implements GitHubRepository {
  FakeGitHub({
    this.user = const GitHubUser(login: 'alice', id: 1, avatarUrl: ''),
  });

  final GitHubUser user;
  final blobs = <String, Uint8List>{};
  final trees = <String, Map<String, String>>{}; // tree sha -> path -> blob sha
  final commits =
      <String, ({String tree, List<String> parents, String message})>{};
  final refs = <String, String>{}; // "owner/name@branch" -> commit
  final repos = <RepositoryRef>[];
  final calls = <String>[];
  var _counter = 0;
  Object? failNext;

  static final repo = RepositoryRef(
    owner: 'alice',
    name: 'research',
    isPrivate: true,
    defaultBranch: 'main',
    updatedAt: DateTime(2026),
  );

  String _key(RepositoryRef r, String b) => '${r.fullName}@$b';

  void _maybeFail() {
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  String putBlob(String text) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final sha = gitBlobSha(bytes);
    blobs[sha] = bytes;
    return sha;
  }

  String _treeSha(Map<String, String> files) {
    final keys = files.keys.toList()..sort();
    final sha = sha1
        .convert(utf8.encode(keys.map((k) => '$k=${files[k]}').join(';')))
        .toString();
    trees[sha] = Map.of(files);
    return sha;
  }

  String _commit(String tree, List<String> parents, String message) {
    final sha = sha1
        .convert(utf8.encode('$tree|$parents|$message|${_counter++}'))
        .toString();
    commits[sha] = (tree: tree, parents: parents, message: message);
    return sha;
  }

  /// Seeds [files] as a commit on [branch]; returns the commit sha.
  String seed(
    Map<String, String> files, {
    String branch = 'main',
    RepositoryRef? on,
    String message = 'seed',
  }) {
    final r = on ?? repo;
    if (!repos.contains(r)) repos.add(r);
    final tree = _treeSha({
      for (final e in files.entries) e.key: putBlob(e.value),
    });
    final parent = refs[_key(r, branch)];
    final c = _commit(tree, [?parent], message);
    refs[_key(r, branch)] = c;
    return c;
  }

  /// Files at the head of [branch].
  Map<String, String> headFiles({String branch = 'main', RepositoryRef? on}) {
    final c = commits[refs[_key(on ?? repo, branch)]]!;
    return {
      for (final e in trees[c.tree]!.entries)
        e.key: utf8.decode(blobs[e.value]!),
    };
  }

  @override
  int? rateLimitRemaining = 5000;

  @override
  Future<GitHubUser> currentUser() async {
    calls.add('user');
    _maybeFail();
    return user;
  }

  @override
  Future<List<RepositoryRef>> listRepositories({
    void Function(int fetched)? onProgress,
  }) async {
    calls.add('repos');
    _maybeFail();
    onProgress?.call(repos.length);
    return List.of(repos);
  }

  @override
  Future<List<String>> listBranches(RepositoryRef r) async {
    calls.add('branches');
    return [
      for (final k in refs.keys)
        if (k.startsWith('${r.fullName}@')) k.split('@').last,
    ];
  }

  @override
  Future<String> branchHead(RepositoryRef r, String branch) async {
    calls.add('head');
    _maybeFail();
    final sha = refs[_key(r, branch)];
    if (sha == null) throw NotFoundFailure('no branch $branch');
    return sha;
  }

  @override
  Future<String> commitTreeSha(RepositoryRef r, String commitSha) async {
    calls.add('commit');
    return commits[commitSha]!.tree;
  }

  @override
  Future<RemoteTree> tree(RepositoryRef r, String treeSha) async {
    calls.add('tree');
    final files = trees[treeSha]!;
    final dirs = <String>{};
    for (final p in files.keys) {
      final parts = p.split('/');
      for (var i = 1; i < parts.length; i++) {
        dirs.add(parts.sublist(0, i).join('/'));
      }
    }
    return RemoteTree(
      sha: treeSha,
      truncated: false,
      entries: [
        for (final d in dirs)
          TreeEntry(
            path: d,
            type: TreeEntryType.tree,
            sha: 'tree:$d',
            mode: '040000',
          ),
        for (final e in files.entries)
          TreeEntry(
            path: e.key,
            type: TreeEntryType.blob,
            sha: e.value,
            size: blobs[e.value]!.length,
          ),
      ],
    );
  }

  @override
  Future<Uint8List> blob(RepositoryRef r, String sha) async {
    calls.add('blob');
    _maybeFail();
    final b = blobs[sha];
    if (b == null) throw NotFoundFailure('no blob $sha');
    return b;
  }

  @override
  Future<String> createBlob(RepositoryRef r, Uint8List bytes) async {
    calls.add('createBlob');
    final sha = gitBlobSha(bytes);
    blobs[sha] = bytes;
    return sha;
  }

  @override
  Future<String> createTree(
    RepositoryRef r, {
    required String baseTree,
    required List<TreeChange> changes,
  }) async {
    calls.add('createTree');
    final files = Map.of(trees[baseTree]!);
    for (final c in changes) {
      if (c.sha == null) {
        files.remove(c.path);
      } else {
        files[c.path] = c.sha!;
      }
    }
    return _treeSha(files);
  }

  @override
  Future<String> createCommit(
    RepositoryRef r, {
    required String message,
    required String tree,
    required List<String> parents,
  }) async {
    calls.add('createCommit');
    return _commit(tree, parents, message);
  }

  @override
  Future<void> updateBranch(
    RepositoryRef r,
    String branch,
    String commitSha,
  ) async {
    calls.add('updateRef');
    final current = refs[_key(r, branch)];
    if (current != null && !commits[commitSha]!.parents.contains(current)) {
      throw const ConflictFailure('Update is not a fast forward');
    }
    refs[_key(r, branch)] = commitSha;
  }

  @override
  Future<void> createBranch(
    RepositoryRef r,
    String branch,
    String commitSha,
  ) async {
    calls.add('createRef');
    if (refs.containsKey(_key(r, branch))) {
      throw const ValidationFailure('Reference already exists');
    }
    refs[_key(r, branch)] = commitSha;
  }

  @override
  Future<PutFileResult> putFile(
    RepositoryRef r,
    String path, {
    required Uint8List bytes,
    required String message,
    required String branch,
    String? sha,
  }) async {
    calls.add('putFile');
    final head = refs[_key(r, branch)]!;
    final files = Map.of(trees[commits[head]!.tree]!);
    if (files[path] != sha) throw ConflictFailure('sha mismatch for $path');
    final blobSha = await createBlob(r, bytes);
    files[path] = blobSha;
    final tree = _treeSha(files);
    final commit = _commit(tree, [head], message);
    refs[_key(r, branch)] = commit;
    return PutFileResult(blobSha: blobSha, commitSha: commit, treeSha: tree);
  }
}
