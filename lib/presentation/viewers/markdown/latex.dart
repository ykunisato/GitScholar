import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:markdown_widget/markdown_widget.dart';

const _latexTag = 'latex';

/// Parses `$...$` and `$$...$$` (FR-31).
class LatexSyntax extends m.InlineSyntax {
  LatexSyntax() : super(r'(\$\$[\s\S]+?\$\$)|(\$[^\$\n]+?\$)');

  @override
  bool onMatch(m.InlineParser parser, Match match) {
    final value = match[0]!;
    final block = value.startsWith(r'$$');
    final content = block
        ? value.substring(2, value.length - 2)
        : value.substring(1, value.length - 1);
    final el = m.Element.text(_latexTag, value)
      ..attributes['content'] = content
      ..attributes['isInline'] = '${!block}';
    parser.addNode(el);
    return true;
  }
}

SpanNodeGeneratorWithTag latexGenerator(bool dark) => SpanNodeGeneratorWithTag(
  tag: _latexTag,
  generator: (e, config, visitor) =>
      _LatexNode(e.attributes, e.textContent, config, dark),
);

class _LatexNode extends SpanNode {
  _LatexNode(this.attributes, this.textContent, this.config, this.dark);

  final Map<String, String> attributes;
  final String textContent;
  final MarkdownConfig config;
  final bool dark;

  @override
  InlineSpan build() {
    final content = attributes['content'] ?? '';
    final inline = attributes['isInline'] == 'true';
    final style = parentStyle ?? config.p.textStyle;
    if (content.trim().isEmpty) {
      return TextSpan(style: style, text: textContent);
    }
    final math = Math.tex(
      content,
      mathStyle: inline ? MathStyle.text : MathStyle.display,
      textStyle: style.copyWith(
        color: style.color ?? (dark ? Colors.white : Colors.black),
      ),
      onErrorFallback: (error) => Text(
        textContent,
        style: style.copyWith(fontFamily: 'monospace', color: Colors.red),
      ),
    );
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: inline
          ? math
          : Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Center(child: math),
              ),
            ),
    );
  }
}
