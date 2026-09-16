import '../failures.dart';

/// Normalises a repository-relative path, rejecting traversal
/// (docs/09_security_privacy.md §4).
///
/// Accepts `a/./b`, `a//b`, trailing slashes. Rejects absolute paths, `..`
/// segments, backslashes and empty paths with [ValidationFailure].
String normalizePath(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) throw const ValidationFailure('Path is empty');
  if (trimmed.startsWith('/') ||
      trimmed.contains(r'\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(trimmed)) {
    throw ValidationFailure('Absolute paths are not allowed: $input');
  }
  final parts = <String>[];
  for (final seg in trimmed.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      throw ValidationFailure('Path traversal is not allowed: $input');
    }
    parts.add(seg);
  }
  if (parts.isEmpty) throw const ValidationFailure('Path is empty');
  return parts.join('/');
}

/// Like [normalizePath] but returns null instead of throwing.
String? tryNormalizePath(String input) {
  try {
    return normalizePath(input);
  } on ValidationFailure {
    return null;
  }
}

/// Resolves a relative link from the file at [fromPath] (Markdown links).
/// Returns null for external or invalid links.
String? resolveRelativeLink(String fromPath, String link) {
  if (link.isEmpty || link.startsWith('#')) return null;
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(link)) return null;
  var target = link.split('#').first.split('?').first;
  if (target.isEmpty) return null;
  target = Uri.decodeFull(target);
  final base = <String>[];
  if (!target.startsWith('/')) {
    final dir = fromPath.contains('/')
        ? fromPath.substring(0, fromPath.lastIndexOf('/'))
        : '';
    if (dir.isNotEmpty) base.addAll(dir.split('/'));
  }
  for (final seg in target.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (base.isEmpty) return null;
      base.removeLast();
    } else {
      base.add(seg);
    }
  }
  return base.isEmpty ? null : base.join('/');
}
