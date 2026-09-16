/// Removes `<script>` elements and inline event handlers from HTML before it
/// is shown in a JavaScript-disabled WebView (docs/05_viewers.md §3.2).
/// JavaScript being disabled is the real protection; this is defence in depth.
String stripScripts(String html) {
  var out = html.replaceAll(
    RegExp(r'<script\b[^>]*>[\s\S]*?</script\s*>', caseSensitive: false),
    '',
  );
  out = out.replaceAll(RegExp(r'<script\b[^>]*/?>', caseSensitive: false), '');
  out = out.replaceAll(
    RegExp(
      r'''\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
      caseSensitive: false,
    ),
    '',
  );
  out = out.replaceAll(
    RegExp(
      r'''(href|src)\s*=\s*(["']?)\s*javascript:[^"'\s>]*\2''',
      caseSensitive: false,
    ),
    '',
  );
  return out;
}

/// Wraps an HTML fragment in a minimal document with a restrictive CSP.
String wrapHtmlDocument(String fragment, {bool dark = false}) {
  final fg = dark ? '#e6e6e6' : '#1a1a1a';
  final bg = dark ? '#1e2128' : '#ffffff';
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'\">"
      '<style>body{font-family:-apple-system,Roboto,sans-serif;font-size:13px;color:$fg;background:$bg;margin:8px}'
      'table{border-collapse:collapse}td,th{border:1px solid #9994;padding:2px 6px}</style>'
      '</head><body>$fragment</body></html>';
}
