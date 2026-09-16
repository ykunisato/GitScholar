/// Kind of a pending change.
enum ChangeKind { modify, create, delete, rename }

/// Who made the change.
enum ChangeOrigin { user, ai }

/// Lifecycle of a pending change (docs/03_data_model.md §1.4).
enum ChangeStatus { pending, proposed }

/// An uncommitted file-level change.
class PendingChange {
  const PendingChange({
    required this.id,
    required this.repoFullName,
    required this.branch,
    required this.path,
    required this.kind,
    required this.origin,
    required this.status,
    required this.baseCommitSha,
    required this.createdAt,
    required this.updatedAt,
    this.oldPath,
    this.baseBlobSha,
    this.contentSha,
    this.proposalId,
    this.upstreamChanged = false,
  });

  final String id;
  final String repoFullName;
  final String branch;
  final String path;
  final String? oldPath;
  final ChangeKind kind;
  final ChangeOrigin origin;
  final ChangeStatus status;

  /// Blob the change was based on (null for create).
  final String? baseBlobSha;
  final String baseCommitSha;

  /// Blob SHA of the new content in the BlobStore (null for delete).
  final String? contentSha;
  final String? proposalId;

  /// Remote changed this path since [baseBlobSha] (docs/04 §3.2 step 6).
  final bool upstreamChanged;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isPending => status == ChangeStatus.pending;

  /// Path whose original content this change is based on.
  String get sourcePath => oldPath ?? path;

  PendingChange copyWith({
    String? path,
    String? oldPath,
    ChangeKind? kind,
    ChangeOrigin? origin,
    ChangeStatus? status,
    String? baseBlobSha,
    String? baseCommitSha,
    String? contentSha,
    String? proposalId,
    bool? upstreamChanged,
    DateTime? updatedAt,
    bool clearContent = false,
  }) => PendingChange(
    id: id,
    repoFullName: repoFullName,
    branch: branch,
    path: path ?? this.path,
    oldPath: oldPath ?? this.oldPath,
    kind: kind ?? this.kind,
    origin: origin ?? this.origin,
    status: status ?? this.status,
    baseBlobSha: baseBlobSha ?? this.baseBlobSha,
    baseCommitSha: baseCommitSha ?? this.baseCommitSha,
    contentSha: clearContent ? null : (contentSha ?? this.contentSha),
    proposalId: proposalId ?? this.proposalId,
    upstreamChanged: upstreamChanged ?? this.upstreamChanged,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// Result of a successful commit.
class CommitResult {
  const CommitResult({
    required this.commitSha,
    required this.branch,
    required this.committedPaths,
  });

  final String commitSha;
  final String branch;
  final List<String> committedPaths;

  String get shortSha =>
      commitSha.length > 7 ? commitSha.substring(0, 7) : commitSha;
}
