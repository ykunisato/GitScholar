/// A repository location parsed out of a github.com web URL (FR-100).
class GitHubUrlTarget {
  /// Creates a target.
  const GitHubUrlTarget({
    required this.owner,
    required this.name,
    this.branch,
    this.path,
  });

  final String owner;
  final String name;

  /// Branch taken from a `/tree/` or `/blob/` URL.
  final String? branch;

  /// File or directory path taken from a `/tree/` or `/blob/` URL.
  final String? path;

  /// `owner/name`.
  String get fullName => '$owner/$name';

  /// Location to hand to the router (docs/08 §1).
  String get location {
    final query = [
      if (branch != null && branch!.isNotEmpty)
        'branch=${Uri.encodeQueryComponent(branch!)}',
      if (path != null && path!.isNotEmpty)
        'path=${Uri.encodeQueryComponent(path!)}',
    ];
    final suffix = query.isEmpty ? '' : '?${query.join('&')}';
    return '/ws/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(name)}$suffix';
  }

  @override
  bool operator ==(Object other) =>
      other is GitHubUrlTarget &&
      other.owner == owner &&
      other.name == name &&
      other.branch == branch &&
      other.path == path;

  @override
  int get hashCode => Object.hash(owner, name, branch, path);

  @override
  String toString() => 'GitHubUrlTarget($location)';
}

/// Paths under github.com that are not repositories.
const _reservedOwners = {
  'about',
  'apps',
  'codespaces',
  'collections',
  'contact',
  'events',
  'explore',
  'features',
  'issues',
  'login',
  'marketplace',
  'new',
  'notifications',
  'organizations',
  'orgs',
  'pricing',
  'pulls',
  'search',
  'security',
  'sessions',
  'settings',
  'signup',
  'sponsors',
  'topics',
  'trending',
};

/// Finds the first github.com repository URL in [text] and parses it.
///
/// Shared text often carries a title or extra words around the link, so the
/// URL is searched for rather than assumed to be the whole string.
GitHubUrlTarget? parseGitHubUrl(String text) {
  for (final match in RegExp(r'https?://[^\s<>"]+').allMatches(text)) {
    final target = _parse(match.group(0)!);
    if (target != null) return target;
  }
  return null;
}

GitHubUrlTarget? _parse(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final host = uri.host.toLowerCase();
  if (host != 'github.com' && host != 'www.github.com') return null;

  final segments = [
    for (final s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  if (segments.length < 2) return null;

  final owner = segments[0];
  if (_reservedOwners.contains(owner.toLowerCase())) return null;
  var name = segments[1];
  if (name.toLowerCase().endsWith('.git')) {
    name = name.substring(0, name.length - 4);
  }
  if (name.isEmpty) return null;

  // /tree/<branch>/<path> and /blob/<branch>/<path> carry a location inside
  // the repository. Branch names may contain slashes, which GitHub URLs do
  // not disambiguate; the first segment is taken as the branch.
  if (segments.length >= 4) {
    final kind = segments[2].toLowerCase();
    if (kind == 'tree' || kind == 'blob') {
      final branch = segments[3];
      final path = segments.length > 4 ? segments.sublist(4).join('/') : null;
      return GitHubUrlTarget(
        owner: owner,
        name: name,
        branch: branch,
        path: path,
      );
    }
  }
  // Anything else (issues, pulls, discussions, ...) opens the repository.
  return GitHubUrlTarget(owner: owner, name: name);
}
