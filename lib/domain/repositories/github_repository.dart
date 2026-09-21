import 'dart:typed_data';

import '../entities/entities.dart';

/// A change to apply when creating a tree. A null [sha] deletes [path].
class TreeChange {
  const TreeChange(this.path, this.sha);

  final String path;
  final String? sha;
}

/// Result of a single-file Contents API commit.
class PutFileResult {
  const PutFileResult({
    required this.blobSha,
    required this.commitSha,
    required this.treeSha,
  });

  final String blobSha;
  final String commitSha;
  final String treeSha;
}

/// Remote tree listing.
class RemoteTree {
  const RemoteTree({
    required this.sha,
    required this.entries,
    required this.truncated,
  });

  final String sha;
  final List<TreeEntry> entries;
  final bool truncated;
}

/// GitHub operations used by the app (docs/04_github_integration.md).
/// Implementations throw AppFailure subclasses only.
abstract class GitHubRepository {
  Future<GitHubUser> currentUser();
  Future<List<RepositoryRef>> listRepositories({
    void Function(int fetched)? onProgress,
  });
  Future<List<String>> listBranches(RepositoryRef repo);
  Future<String> branchHead(RepositoryRef repo, String branch);
  Future<String> commitTreeSha(RepositoryRef repo, String commitSha);
  Future<RemoteTree> tree(RepositoryRef repo, String treeSha);
  Future<Uint8List> blob(RepositoryRef repo, String sha);
  Future<String> createBlob(RepositoryRef repo, Uint8List bytes);
  Future<String> createTree(
    RepositoryRef repo, {
    required String baseTree,
    required List<TreeChange> changes,
  });
  Future<String> createCommit(
    RepositoryRef repo, {
    required String message,
    required String tree,
    required List<String> parents,
  });

  /// Fast-forward only. Throws ConflictFailure when not a fast-forward.
  Future<void> updateBranch(
    RepositoryRef repo,
    String branch,
    String commitSha,
  );
  Future<void> createBranch(
    RepositoryRef repo,
    String branch,
    String commitSha,
  );

  /// Throws ConflictFailure when [sha] does not match the current blob.
  Future<PutFileResult> putFile(
    RepositoryRef repo,
    String path, {
    required Uint8List bytes,
    required String message,
    required String branch,
    String? sha,
  });

  /// Lists discussions (FR-97). Returns null when the repository has
  /// discussions turned off.
  Future<List<RepoThread>?> listDiscussions(RepositoryRef repo);

  /// Lists open issues, newest activity first (FR-97).
  Future<List<RepoThread>> listIssues(RepositoryRef repo);

  /// Reads one thread with its comments.
  Future<ThreadDetail> thread(RepositoryRef repo, RepoThread thread);

  /// Posts a comment and returns it (FR-98).
  ///
  /// [nodeId] is the discussion's GraphQL id; it is ignored for issues.
  Future<ThreadComment> comment(
    RepositoryRef repo,
    RepoThread thread,
    String body, {
    String? nodeId,
  });

  /// Adds or removes the signed-in user's [kind] reaction on [subjectId] and
  /// returns the subject's reactions afterwards (FR-99). [subjectId] is the
  /// GraphQL node id of an issue, a discussion or one of their comments.
  Future<List<Reaction>> react(
    RepositoryRef repo, {
    required String subjectId,
    required ReactionKind kind,
    required bool add,
  });

  /// Fetches content stored with Git LFS (FR-102).
  ///
  /// For an LFS-tracked file the Git blob holds only a pointer; the bytes
  /// live on a separate LFS server.
  Future<Uint8List> lfsObject(
    RepositoryRef repo, {
    required String oid,
    required int size,
    String hashAlgo = 'sha256',
  });

  /// Remaining core rate limit, if known.
  int? get rateLimitRemaining;
}
