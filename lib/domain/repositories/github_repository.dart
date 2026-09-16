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

  /// Remaining core rate limit, if known.
  int? get rateLimitRemaining;
}
