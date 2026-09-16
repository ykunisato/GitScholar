import '../../domain/entities/entities.dart';
import '../../domain/repositories/github_repository.dart';

/// Reads and comments on GitHub Discussions and Issues (FR-97, FR-98).
class ThreadService {
  /// Creates a service.
  ThreadService(this.github);

  final GitHubRepository github;

  /// Lists threads of [kind]. Null means discussions are turned off for the
  /// repository.
  Future<List<RepoThread>?> list(RepositoryRef repo, ThreadKind kind) =>
      kind == ThreadKind.discussion
      ? github.listDiscussions(repo)
      : github.listIssues(repo);

  /// Reads one thread with its comments.
  Future<ThreadDetail> detail(RepositoryRef repo, RepoThread thread) =>
      github.thread(repo, thread);

  /// Adds or removes an emoji reaction (FR-99).
  Future<List<Reaction>> react(
    RepositoryRef repo, {
    required String subjectId,
    required ReactionKind kind,
    required bool add,
  }) => github.react(repo, subjectId: subjectId, kind: kind, add: add);

  /// Posts a comment on [thread].
  Future<ThreadComment> comment(
    RepositoryRef repo,
    RepoThread thread,
    String body, {
    String? nodeId,
  }) => github.comment(repo, thread, body, nodeId: nodeId);
}
