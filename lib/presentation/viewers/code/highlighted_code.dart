import 'package:flutter/material.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/github.dart';

import '../../core/theme.dart';
import 'language_map.dart';

/// Read-only highlighted code for notebook cells and small snippets.
class HighlightedCode extends StatelessWidget {
  const HighlightedCode({
    super.key,
    required this.code,
    required this.language,
    this.fontSize = 13,
  });

  final String code;
  final String language;
  final double fontSize;

  static final _highlight = Highlight();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = monoStyle(context, size: fontSize);
    final (id, mode) = languageForName(language);
    TextSpan span;
    try {
      _highlight.registerLanguage(id, mode);
      final result = _highlight.highlight(code: code, language: id);
      final renderer = TextSpanRenderer(
        base,
        dark ? atomOneDarkTheme : githubTheme,
      );
      result.render(renderer);
      span = renderer.span ?? TextSpan(text: code, style: base);
    } on Object {
      span = TextSpan(text: code, style: base);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectableText.rich(span),
    );
  }
}
