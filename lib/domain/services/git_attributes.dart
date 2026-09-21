/// Reads `.gitattributes` to find out whether a path is stored with Git LFS
/// (FR-102).
///
/// Only the subset of pattern syntax that matters here is implemented:
/// `*.pdf`, `dir/*.pdf`, `**/x`, exact paths, and a leading `/` to anchor at
/// the repository root. Negations (`!`) and attribute macros are ignored.
bool isLfsTracked(String? gitattributes, String path) {
  if (gitattributes == null || gitattributes.isEmpty) return false;
  for (final raw in gitattributes.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    if (!parts.skip(1).any((a) => a == 'filter=lfs')) continue;
    if (_matches(parts.first, path)) return true;
  }
  return false;
}

bool _matches(String pattern, String path) {
  var glob = pattern;
  var anchored = false;
  if (glob.startsWith('/')) {
    glob = glob.substring(1);
    anchored = true;
  }
  if (glob.contains('/')) anchored = true;
  // A pattern without a slash applies to the file name at any depth.
  final target = anchored ? path : path.split('/').last;
  return RegExp('^${_toRegExp(glob)}\$').hasMatch(target);
}

String _toRegExp(String glob) {
  final out = StringBuffer();
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        out.write('.*');
        i++;
        // `**/` の直後は階層が無くてもよい
        if (i + 1 < glob.length && glob[i + 1] == '/') i++;
      } else {
        out.write('[^/]*');
      }
    } else if (c == '?') {
      out.write('[^/]');
    } else {
      out.write(RegExp.escape(c));
    }
  }
  return out.toString();
}
