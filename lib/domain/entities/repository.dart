import 'package:collection/collection.dart';

/// Whether repository contents may be sent to the AI (FR-69).
enum AiAccess { allowed, denied, ask }

/// A GitHub repository.
class RepositoryRef {
  const RepositoryRef({
    required this.owner,
    required this.name,
    required this.isPrivate,
    required this.defaultBranch,
    required this.updatedAt,
    this.description,
    this.htmlUrl,
    this.aiAccess = AiAccess.ask,
    this.lastOpenedAt,
    this.pinnedAt,
    this.offlinePaths,
    this.offlineCommitSha,
    this.offlineUpdatedAt,
  });

  final String owner;
  final String name;
  final bool isPrivate;
  final String defaultBranch;
  final DateTime updatedAt;
  final String? description;
  final String? htmlUrl;
  final AiAccess aiAccess;
  final DateTime? lastOpenedAt;

  /// When the user pinned this repository (FR-16).
  final DateTime? pinnedAt;

  /// Path prefixes kept on the device. An empty list means the whole
  /// repository; null means offline use is off (FR-27).
  final List<String>? offlinePaths;

  /// Commit the offline copy was downloaded from.
  final String? offlineCommitSha;
  final DateTime? offlineUpdatedAt;

  String get fullName => '$owner/$name';

  bool get isPinned => pinnedAt != null;

  bool get isOffline => offlinePaths != null;

  /// Whether [path] is inside the offline selection.
  bool offlineCovers(String path) {
    final paths = offlinePaths;
    if (paths == null) return false;
    if (paths.isEmpty) return true;
    return paths.any((p) => path == p || path.startsWith('$p/'));
  }

  /// Effective AI access: public repositories default to allowed.
  AiAccess get effectiveAiAccess =>
      aiAccess == AiAccess.ask && !isPrivate ? AiAccess.allowed : aiAccess;

  RepositoryRef copyWith({
    AiAccess? aiAccess,
    DateTime? lastOpenedAt,
    String? defaultBranch,
    DateTime? pinnedAt,
    bool clearPinned = false,
    List<String>? offlinePaths,
    bool clearOffline = false,
    String? offlineCommitSha,
    DateTime? offlineUpdatedAt,
  }) => RepositoryRef(
    owner: owner,
    name: name,
    isPrivate: isPrivate,
    defaultBranch: defaultBranch ?? this.defaultBranch,
    updatedAt: updatedAt,
    description: description,
    htmlUrl: htmlUrl,
    aiAccess: aiAccess ?? this.aiAccess,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    pinnedAt: clearPinned ? null : (pinnedAt ?? this.pinnedAt),
    offlinePaths: clearOffline ? null : (offlinePaths ?? this.offlinePaths),
    offlineCommitSha: clearOffline
        ? null
        : (offlineCommitSha ?? this.offlineCommitSha),
    offlineUpdatedAt: clearOffline
        ? null
        : (offlineUpdatedAt ?? this.offlineUpdatedAt),
  );

  @override
  bool operator ==(Object other) =>
      other is RepositoryRef && other.fullName == fullName;

  @override
  int get hashCode => fullName.hashCode;
}

/// Entry type in a Git tree.
enum TreeEntryType { blob, tree, commit }

/// One entry of a recursive Git tree.
class TreeEntry {
  const TreeEntry({
    required this.path,
    required this.type,
    required this.sha,
    this.size,
    this.mode = '100644',
  });

  final String path;
  final TreeEntryType type;
  final String sha;
  final int? size;
  final String mode;

  bool get isBlob => type == TreeEntryType.blob;

  String get name => path.split('/').last;

  String get parent {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  TreeEntry copyWith({String? path, String? sha, int? size}) => TreeEntry(
    path: path ?? this.path,
    type: type,
    sha: sha ?? this.sha,
    size: size ?? this.size,
    mode: mode,
  );

  @override
  bool operator ==(Object other) =>
      other is TreeEntry &&
      other.path == path &&
      other.type == type &&
      other.sha == sha &&
      other.size == size &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(path, type, sha, size, mode);
}

/// Local state for one repository and branch (docs/03_data_model.md §1.2).
class Workspace {
  Workspace({
    required this.repo,
    required this.branch,
    required this.baseCommitSha,
    required this.treeSha,
    required List<TreeEntry> entries,
    required this.truncated,
    required this.fetchedAt,
  }) : entries = List.unmodifiable(entries),
       _index = {for (final e in entries) e.path: e};

  final RepositoryRef repo;
  final String branch;
  final String baseCommitSha;
  final String treeSha;
  final List<TreeEntry> entries;
  final bool truncated;
  final DateTime fetchedAt;
  final Map<String, TreeEntry> _index;

  /// Entry at [path], if any.
  TreeEntry? entry(String path) => _index[path];

  /// Blob entries only.
  Iterable<TreeEntry> get blobs => entries.where((e) => e.isBlob);

  Workspace copyWith({
    RepositoryRef? repo,
    String? branch,
    String? baseCommitSha,
    String? treeSha,
    List<TreeEntry>? entries,
    bool? truncated,
    DateTime? fetchedAt,
  }) => Workspace(
    repo: repo ?? this.repo,
    branch: branch ?? this.branch,
    baseCommitSha: baseCommitSha ?? this.baseCommitSha,
    treeSha: treeSha ?? this.treeSha,
    entries: entries ?? this.entries,
    truncated: truncated ?? this.truncated,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Workspace &&
      other.repo == repo &&
      other.branch == branch &&
      other.baseCommitSha == baseCommitSha &&
      other.treeSha == treeSha &&
      other.truncated == truncated &&
      const ListEquality<TreeEntry>().equals(other.entries, entries);

  @override
  int get hashCode => Object.hash(repo, branch, baseCommitSha, treeSha);
}
