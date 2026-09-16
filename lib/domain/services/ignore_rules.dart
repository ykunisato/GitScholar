/// gitignore-style rules for `.gitscholarignore` (docs/07_ai_agent.md §5.2).
///
/// Supports `*`, `**`, `?`, character classes, negation `!`, directory
/// patterns ending in `/`, and anchoring with a leading or inner `/`.
class IgnoreRules {
  IgnoreRules(List<String> patterns)
    : _rules = [for (final p in patterns) ?_Rule.parse(p)];

  /// Parses file content, prepending [defaultPatterns].
  factory IgnoreRules.fromFile(String? content) =>
      IgnoreRules([...defaultPatterns, ...?content?.split('\n')]);

  /// Always excluded from AI.
  static const defaultPatterns = ['.env', '*.pem', '*.key', '**/secrets/**'];

  /// The ignore file name at the repository root.
  static const fileName = '.gitscholarignore';

  final List<_Rule> _rules;

  /// Whether [path] (a file path, repository relative) is ignored.
  bool isIgnored(String path) {
    final segments = path.split('/');
    // A file is ignored if it or any parent directory is ignored.
    var ignored = false;
    for (var i = 1; i <= segments.length; i++) {
      final sub = segments.sublist(0, i).join('/');
      final isDir = i < segments.length;
      for (final rule in _rules) {
        if (rule.dirOnly && !isDir) continue;
        if (rule.matches(sub)) ignored = !rule.negated;
      }
      if (ignored && isDir) return true;
    }
    return ignored;
  }
}

class _Rule {
  _Rule(this.regex, {required this.negated, required this.dirOnly});

  static _Rule? parse(String raw) {
    var p = raw.trimRight();
    if (p.isEmpty || p.startsWith('#')) return null;
    var negated = false;
    if (p.startsWith('!')) {
      negated = true;
      p = p.substring(1);
    } else if (p.startsWith(r'\!') || p.startsWith(r'\#')) {
      p = p.substring(1);
    }
    var dirOnly = false;
    if (p.endsWith('/')) {
      dirOnly = true;
      p = p.substring(0, p.length - 1);
    }
    if (p.isEmpty) return null;
    final anchored = p.startsWith('/') || p.contains('/');
    if (p.startsWith('/')) p = p.substring(1);
    final body = _globToRegex(p);
    final source = anchored ? '^$body\$' : '^(?:.*/)?$body\$';
    return _Rule(RegExp(source), negated: negated, dirOnly: dirOnly);
  }

  final RegExp regex;
  final bool negated;
  final bool dirOnly;

  bool matches(String path) => regex.hasMatch(path);

  static String _globToRegex(String glob) {
    final b = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        final double = i + 1 < glob.length && glob[i + 1] == '*';
        if (double) {
          final slashAfter = i + 2 < glob.length && glob[i + 2] == '/';
          if (slashAfter) {
            b.write('(?:.*/)?');
            i += 2;
          } else {
            b.write('.*');
            i += 1;
          }
        } else {
          b.write('[^/]*');
        }
      } else if (c == '?') {
        b.write('[^/]');
      } else if (c == '[') {
        final end = glob.indexOf(']', i + 1);
        if (end < 0) {
          b.write(r'\[');
        } else {
          var cls = glob.substring(i + 1, end);
          if (cls.startsWith('!')) cls = '^${cls.substring(1)}';
          b.write('[$cls]');
          i = end;
        }
      } else if (r'.+()|^$\{}'.contains(c)) {
        b.write('\\$c');
      } else {
        b.write(c);
      }
    }
    return b.toString();
  }
}
