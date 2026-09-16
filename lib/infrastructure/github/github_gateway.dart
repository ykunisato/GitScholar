import 'dart:typed_data';

import 'package:github_api/github_api.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/repositories/github_repository.dart';
import '../local/app_database.dart';

/// Maps [GitHubApiException] to [AppFailure] (docs/04 §2.3).
AppFailure mapGitHubException(
  GitHubApiException e, {
  bool isRefUpdate = false,
}) {
  if (e.statusCode == 0) {
    if (e.errorCode != null) {
      return AuthFailure(e.message, cause: e, code: e.errorCode);
    }
    return NetworkFailure(e.message, cause: e);
  }
  if (e.isRateLimited) {
    return RateLimitFailure(e.message, cause: e, resetAt: e.rateLimitResetAt);
  }
  if (e.statusCode == 401) return AuthFailure(e.message, cause: e);
  if (e.statusCode == 404) return NotFoundFailure(e.message, cause: e);
  if (e.statusCode == 409 || (e.statusCode == 422 && isRefUpdate)) {
    return ConflictFailure(e.message, cause: e);
  }
  if (e.statusCode == 422 || e.statusCode == 400 || e.statusCode == 403) {
    return ValidationFailure(e.message, cause: e);
  }
  if (e.statusCode >= 500) return NetworkFailure(e.message, cause: e);
  return UnknownFailure(e.message, cause: e);
}

/// ETag cache persisted in the key/value table (docs/04 §2.2).
class DriftETagCache implements ETagCache {
  DriftETagCache(this.db);

  final AppDatabase db;

  @override
  Future<ETagEntry?> get(String url) async {
    final v = await db.getValue('etag:$url');
    if (v is! Map) return null;
    return ETagEntry(v['etag'] as String, v['body'] as String);
  }

  @override
  Future<void> put(String url, ETagEntry entry) =>
      db.setValue('etag:$url', {'etag': entry.etag, 'body': entry.body});
}

/// [GitHubRepository] backed by [GitHubClient].
class GitHubGateway implements GitHubRepository {
  GitHubGateway(
    this.client, {
    this.maxGetRetries = 3,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  final GitHubClient client;
  final int maxGetRetries;
  final Future<void> Function(Duration) _delay;

  @override
  int? rateLimitRemaining;

  /// Runs [op], retrying GETs on network/5xx errors with 1s, 2s, 4s backoff
  /// (docs/02_architecture.md §7).
  Future<T> _get<T>(Future<T> Function() op) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await op();
      } on GitHubApiException catch (e) {
        final retryable =
            (e.statusCode == 0 && e.errorCode == null) || e.statusCode >= 500;
        if (!retryable || attempt >= maxGetRetries) throw mapGitHubException(e);
        await _delay(Duration(seconds: 1 << attempt));
      }
    }
  }

  Future<T> _write<T>(
    Future<T> Function() op, {
    bool isRefUpdate = false,
  }) async {
    try {
      return await op();
    } on GitHubApiException catch (e) {
      throw mapGitHubException(e, isRefUpdate: isRefUpdate);
    }
  }

  @override
  Future<GitHubUser> currentUser() => _get(() async {
    final u = await client.getUser();
    return GitHubUser(
      login: u.login,
      id: u.id,
      avatarUrl: u.avatarUrl,
      name: u.name,
    );
  });

  @override
  Future<List<RepositoryRef>> listRepositories({
    void Function(int fetched)? onProgress,
  }) => _get(() async {
    final repos = await client.listUserRepos(onProgress: onProgress);
    return [
      for (final r in repos)
        RepositoryRef(
          owner: r.owner,
          name: r.name,
          isPrivate: r.isPrivate,
          defaultBranch: r.defaultBranch,
          updatedAt: r.updatedAt,
          description: r.description,
          htmlUrl: r.htmlUrl,
        ),
    ];
  });

  @override
  Future<List<String>> listBranches(RepositoryRef repo) => _get(
    () async => [
      for (final b in await client.listBranches(repo.owner, repo.name)) b.name,
    ],
  );

  @override
  Future<String> branchHead(RepositoryRef repo, String branch) =>
      _get(() => client.getBranchHeadSha(repo.owner, repo.name, branch));

  @override
  Future<String> commitTreeSha(RepositoryRef repo, String commitSha) => _get(
    () async =>
        (await client.getCommit(repo.owner, repo.name, commitSha)).treeSha,
  );

  @override
  Future<RemoteTree> tree(RepositoryRef repo, String treeSha) => _get(() async {
    final t = await client.getTree(repo.owner, repo.name, treeSha);
    return RemoteTree(
      sha: t.sha,
      truncated: t.truncated,
      entries: [
        for (final e in t.entries)
          TreeEntry(
            path: e.path,
            type: switch (e.type) {
              'tree' => TreeEntryType.tree,
              'commit' => TreeEntryType.commit,
              _ => TreeEntryType.blob,
            },
            sha: e.sha,
            size: e.size,
            mode: e.mode,
          ),
      ],
    );
  });

  @override
  Future<Uint8List> blob(RepositoryRef repo, String sha) =>
      _get(() => client.getBlobRaw(repo.owner, repo.name, sha));

  @override
  Future<String> createBlob(RepositoryRef repo, Uint8List bytes) =>
      _write(() => client.createBlob(repo.owner, repo.name, bytes));

  @override
  Future<String> createTree(
    RepositoryRef repo, {
    required String baseTree,
    required List<TreeChange> changes,
  }) => _write(
    () => client.createTree(
      repo.owner,
      repo.name,
      baseTree: baseTree,
      items: [for (final c in changes) TreeItem(path: c.path, sha: c.sha)],
    ),
  );

  @override
  Future<String> createCommit(
    RepositoryRef repo, {
    required String message,
    required String tree,
    required List<String> parents,
  }) => _write(
    () => client.createCommit(
      repo.owner,
      repo.name,
      message: message,
      tree: tree,
      parents: parents,
    ),
  );

  @override
  Future<void> updateBranch(
    RepositoryRef repo,
    String branch,
    String commitSha,
  ) => _write(
    () => client.updateRef(repo.owner, repo.name, branch, commitSha),
    isRefUpdate: true,
  );

  @override
  Future<void> createBranch(
    RepositoryRef repo,
    String branch,
    String commitSha,
  ) => _write(() => client.createRef(repo.owner, repo.name, branch, commitSha));

  @override
  Future<PutFileResult> putFile(
    RepositoryRef repo,
    String path, {
    required Uint8List bytes,
    required String message,
    required String branch,
    String? sha,
  }) => _write(() async {
    final r = await client.putContents(
      repo.owner,
      repo.name,
      path,
      message: message,
      content: bytes,
      branch: branch,
      sha: sha,
    );
    return PutFileResult(
      blobSha: r.contentSha,
      commitSha: r.commitSha,
      treeSha: r.treeSha,
    );
  }, isRefUpdate: true);

  // ------------------------------------------------- issues / discussions

  RepoThread _discussion(DiscussionDto d) => RepoThread(
    kind: ThreadKind.discussion,
    number: d.number,
    title: d.title,
    author: d.author,
    updatedAt: d.updatedAt,
    commentCount: d.commentCount,
    url: d.url,
    category: d.category,
  );

  RepoThread _issue(IssueDto i) => RepoThread(
    kind: ThreadKind.issue,
    number: i.number,
    title: i.title,
    author: i.author,
    updatedAt: i.updatedAt,
    commentCount: i.commentCount,
    url: i.htmlUrl,
    isOpen: i.isOpen,
  );

  ThreadComment _threadComment(ThreadCommentDto c) => ThreadComment(
    id: c.id,
    nodeId: c.nodeId,
    reactions: _reactions(c.reactions),
    author: c.author,
    body: c.body,
    createdAt: c.createdAt,
  );

  /// Drops empty groups and anything GitHub adds that the app does not know.
  List<Reaction> _reactions(List<ReactionGroupDto> groups) {
    final out = <Reaction>[];
    for (final g in groups) {
      final kind = ReactionKind.fromGraphQl(g.content);
      if (kind == null || g.count == 0) continue;
      out.add(Reaction(kind: kind, count: g.count, mine: g.viewerHasReacted));
    }
    return out;
  }

  @override
  Future<List<RepoThread>?> listDiscussions(RepositoryRef repo) =>
      _get(() async {
        final list = await client.listDiscussions(repo.owner, repo.name);
        return list == null ? null : [for (final d in list) _discussion(d)];
      });

  @override
  Future<List<RepoThread>> listIssues(RepositoryRef repo) => _get(() async {
    final list = await client.listIssues(repo.owner, repo.name);
    return [for (final i in list) _issue(i)];
  });

  @override
  Future<ThreadDetail> thread(RepositoryRef repo, RepoThread thread) => _get(
    () async {
      if (thread.kind == ThreadKind.discussion) {
        final d = await client.getDiscussion(
          repo.owner,
          repo.name,
          thread.number,
        );
        return ThreadDetail(
          thread: _discussion(d),
          body: d.body,
          nodeId: d.nodeId,
          reactions: _reactions(d.reactions),
          comments: [for (final c in d.comments) _threadComment(c)],
        );
      }
      final issue = await client.getIssue(repo.owner, repo.name, thread.number);
      final comments = await client.listIssueComments(
        repo.owner,
        repo.name,
        thread.number,
      );
      // The issues API does not say whether the signed-in user reacted, so the
      // reactions are read separately by node id.
      final groups = await client.reactionsFor([
        issue.nodeId,
        for (final c in comments) c.nodeId,
      ]);
      return ThreadDetail(
        thread: _issue(issue),
        body: issue.body,
        nodeId: issue.nodeId,
        reactions: _reactions(groups[issue.nodeId] ?? const []),
        comments: [
          for (final c in comments)
            _threadComment(
              c,
            ).withReactions(_reactions(groups[c.nodeId] ?? const [])),
        ],
      );
    },
  );

  @override
  Future<ThreadComment> comment(
    RepositoryRef repo,
    RepoThread thread,
    String body, {
    String? nodeId,
  }) => _write(() async {
    if (thread.kind == ThreadKind.discussion) {
      if (nodeId == null) {
        throw const GitHubApiException(422, 'Missing discussion id');
      }
      return _threadComment(await client.createDiscussionComment(nodeId, body));
    }
    return _threadComment(
      await client.createIssueComment(
        repo.owner,
        repo.name,
        thread.number,
        body,
      ),
    );
  });

  @override
  Future<List<Reaction>> react(
    RepositoryRef repo, {
    required String subjectId,
    required ReactionKind kind,
    required bool add,
  }) => _write(
    () async =>
        _reactions(await client.react(subjectId, kind.graphQlName, add: add)),
  );
}
