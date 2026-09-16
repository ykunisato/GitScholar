/// GitHub user.
class UserDto {
  /// Creates a user.
  const UserDto({
    required this.login,
    required this.id,
    required this.avatarUrl,
    this.name,
  });

  /// Parses JSON.
  factory UserDto.fromJson(Map<String, dynamic> j) => UserDto(
    login: j['login'] as String,
    id: j['id'] as int,
    avatarUrl: (j['avatar_url'] ?? '') as String,
    name: j['name'] as String?,
  );

  /// Login.
  final String login;

  /// Numeric id.
  final int id;

  /// Avatar URL.
  final String avatarUrl;

  /// Display name.
  final String? name;
}

/// GitHub repository.
class RepoDto {
  /// Creates a repository.
  const RepoDto({
    required this.owner,
    required this.name,
    required this.fullName,
    required this.isPrivate,
    required this.defaultBranch,
    required this.updatedAt,
    this.description,
    this.htmlUrl,
  });

  /// Parses JSON.
  factory RepoDto.fromJson(Map<String, dynamic> j) => RepoDto(
    owner: (j['owner'] as Map<String, dynamic>)['login'] as String,
    name: j['name'] as String,
    fullName: j['full_name'] as String,
    isPrivate: (j['private'] ?? false) as bool,
    defaultBranch: (j['default_branch'] ?? 'main') as String,
    description: j['description'] as String?,
    htmlUrl: j['html_url'] as String?,
    updatedAt: DateTime.tryParse('${j['updated_at']}') ?? DateTime(1970),
  );

  /// Owner login.
  final String owner;

  /// Repository name.
  final String name;

  /// `owner/name`.
  final String fullName;

  /// Whether private.
  final bool isPrivate;

  /// Default branch.
  final String defaultBranch;

  /// Description.
  final String? description;

  /// Web URL.
  final String? htmlUrl;

  /// Last update time.
  final DateTime updatedAt;
}

/// Branch.
class BranchDto {
  /// Creates a branch.
  const BranchDto({required this.name, required this.sha});

  /// Parses JSON.
  factory BranchDto.fromJson(Map<String, dynamic> j) => BranchDto(
    name: j['name'] as String,
    sha: (j['commit'] as Map<String, dynamic>)['sha'] as String,
  );

  /// Branch name.
  final String name;

  /// Head commit SHA.
  final String sha;
}

/// Commit (Git Data API).
class CommitDto {
  /// Creates a commit.
  const CommitDto({
    required this.sha,
    required this.treeSha,
    required this.parents,
    this.message = '',
  });

  /// Parses JSON.
  factory CommitDto.fromJson(Map<String, dynamic> j) => CommitDto(
    sha: j['sha'] as String,
    treeSha: (j['tree'] as Map<String, dynamic>)['sha'] as String,
    message: (j['message'] ?? '') as String,
    parents: [
      for (final p in (j['parents'] ?? const <Object?>[]) as List)
        (p as Map<String, dynamic>)['sha'] as String,
    ],
  );

  /// Commit SHA.
  final String sha;

  /// Tree SHA.
  final String treeSha;

  /// Parent SHAs.
  final List<String> parents;

  /// Message.
  final String message;
}

/// Tree entry from the Git trees API.
class TreeEntryDto {
  /// Creates an entry.
  const TreeEntryDto({
    required this.path,
    required this.type,
    required this.sha,
    required this.mode,
    this.size,
  });

  /// Parses JSON.
  factory TreeEntryDto.fromJson(Map<String, dynamic> j) => TreeEntryDto(
    path: j['path'] as String,
    type: j['type'] as String,
    sha: j['sha'] as String,
    mode: j['mode'] as String,
    size: j['size'] as int?,
  );

  /// Path relative to the repository root.
  final String path;

  /// `blob`, `tree` or `commit` (submodule).
  final String type;

  /// Object SHA.
  final String sha;

  /// File mode.
  final String mode;

  /// Size in bytes for blobs.
  final int? size;

  /// JSON form (used by fakes).
  Map<String, dynamic> toJson() => {
    'path': path,
    'type': type,
    'sha': sha,
    'mode': mode,
    if (size != null) 'size': size,
  };
}

/// Tree response.
class TreeDto {
  /// Creates a tree.
  const TreeDto({
    required this.sha,
    required this.entries,
    required this.truncated,
  });

  /// Parses JSON.
  factory TreeDto.fromJson(Map<String, dynamic> j) => TreeDto(
    sha: j['sha'] as String,
    truncated: (j['truncated'] ?? false) as bool,
    entries: [
      for (final e in j['tree'] as List)
        TreeEntryDto.fromJson(e as Map<String, dynamic>),
    ],
  );

  /// Tree SHA.
  final String sha;

  /// Entries.
  final List<TreeEntryDto> entries;

  /// Whether GitHub truncated the result.
  final bool truncated;
}

/// Item for creating a tree. A null [sha] deletes [path].
class TreeItem {
  /// Creates a tree item.
  const TreeItem({
    required this.path,
    required this.sha,
    this.mode = '100644',
    this.type = 'blob',
  });

  /// Path.
  final String path;

  /// Blob SHA, or null to delete.
  final String? sha;

  /// Mode.
  final String mode;

  /// Type.
  final String type;

  /// JSON body.
  Map<String, dynamic> toJson() => {
    'path': path,
    'mode': mode,
    'type': type,
    'sha': sha,
  };
}

/// Result of `PUT /contents`.
class ContentsPutResult {
  /// Creates a result.
  const ContentsPutResult({
    required this.contentSha,
    required this.commitSha,
    required this.treeSha,
  });

  /// New blob SHA.
  final String contentSha;

  /// New commit SHA.
  final String commitSha;

  /// New tree SHA.
  final String treeSha;
}

/// Rate limit status.
class RateLimitDto {
  /// Creates a status.
  const RateLimitDto({
    required this.limit,
    required this.remaining,
    required this.resetAt,
  });

  /// Maximum requests per window.
  final int limit;

  /// Remaining requests.
  final int remaining;

  /// Reset time.
  final DateTime resetAt;
}

/// Device code response.
class DeviceCodeResponse {
  /// Creates a response.
  const DeviceCodeResponse({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  /// Parses JSON.
  factory DeviceCodeResponse.fromJson(Map<String, dynamic> j) =>
      DeviceCodeResponse(
        deviceCode: j['device_code'] as String,
        userCode: j['user_code'] as String,
        verificationUri: Uri.parse(j['verification_uri'] as String),
        expiresIn: (j['expires_in'] ?? 900) as int,
        interval: (j['interval'] ?? 5) as int,
      );

  /// Device code (secret, used for polling).
  final String deviceCode;

  /// Code the user types.
  final String userCode;

  /// Where the user types the code.
  final Uri verificationUri;

  /// Seconds until expiry.
  final int expiresIn;

  /// Minimum polling interval in seconds.
  final int interval;
}
