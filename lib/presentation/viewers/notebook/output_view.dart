import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:nbformat/nbformat.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../common/sandboxed_html_view.dart';
import '../markdown/markdown_body.dart';

/// Renders one notebook output (docs/05_viewers.md §3.1).
class OutputView extends StatelessWidget {
  const OutputView({
    super.key,
    required this.output,
    required this.basePath,
    required this.onOpenPath,
  });

  final Output output;
  final String basePath;
  final void Function(String) onOpenPath;

  static const maxStreamLines = 10000;
  static const headTailLines = 500;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final o = output;
    switch (o) {
      case StreamOutput(:final text, :final isStderr):
        return Container(
          width: double.infinity,
          color: isStderr ? colors.stderrBackground : null,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: _LongText(text: text),
        );
      case ErrorOutput(:final ename, :final evalue, :final traceback):
        return Container(
          color: colors.stderrBackground,
          child: ExpansionTile(
            dense: true,
            initiallyExpanded: true,
            title: Text(
              '$ename: $evalue',
              style: monoStyle(
                context,
                size: 12,
                color: colors.diffRemovedText,
              ),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(6),
                  child: SelectableText(
                    stripAnsi(traceback.join('\n')),
                    style: monoStyle(context, size: 12),
                  ),
                ),
              ),
            ],
          ),
        );
      case DisplayDataOutput(:final data):
        return _MimeView(
          bundle: data,
          basePath: basePath,
          onOpenPath: onOpenPath,
        );
    }
  }
}

class _LongText extends StatefulWidget {
  const _LongText({required this.text});

  final String text;

  @override
  State<_LongText> createState() => _LongTextState();
}

class _LongTextState extends State<_LongText> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.text.split('\n');
    final truncated = !_all && lines.length > OutputView.maxStreamLines;
    final shown = truncated
        ? '${lines.take(OutputView.headTailLines).join('\n')}\n…\n${lines.skip(lines.length - OutputView.headTailLines).join('\n')}'
        : widget.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(shown, style: monoStyle(context, size: 12)),
        ),
        if (truncated)
          TextButton(
            onPressed: () => setState(() => _all = true),
            child: Text(context.l10n.showAllLines(lines.length)),
          ),
      ],
    );
  }
}

class _MimeView extends StatelessWidget {
  const _MimeView({
    required this.bundle,
    required this.basePath,
    required this.onOpenPath,
  });

  final MimeBundle bundle;
  final String basePath;
  final void Function(String) onOpenPath;

  @override
  Widget build(BuildContext context) {
    final mime = bundle.preferred();
    if (mime == null) return const SizedBox.shrink();
    final value = bundle.entries[mime]!;
    switch (mime) {
      case 'image/png':
      case 'image/jpeg':
        final bytes = base64Decode(value.replaceAll('\n', ''));
        return Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) => Dialog(
                child: InteractiveViewer(
                  maxScale: 8,
                  child: Image.memory(bytes),
                ),
              ),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: Image.memory(
                bytes,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        );
      case 'image/svg+xml':
        return SandboxedHtmlView(html: value, label: context.l10n.showSvg);
      case 'text/html':
        return SandboxedHtmlView(html: value);
      case 'text/markdown':
        return MarkdownBody(
          data: value,
          basePath: basePath,
          onOpenPath: onOpenPath,
        );
      case 'text/latex':
        final tex = value.trim().replaceAll(RegExp(r'^\$+|\$+$'), '');
        return Math.tex(
          tex,
          onErrorFallback: (_) =>
              SelectableText(value, style: monoStyle(context, size: 12)),
        );
      case 'application/json':
        String pretty;
        try {
          pretty = const JsonEncoder.withIndent(
            '  ',
          ).convert(jsonDecode(value));
        } on FormatException {
          pretty = value;
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(pretty, style: monoStyle(context, size: 12)),
        );
      default:
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            bundle.entries['text/plain'] ?? value,
            style: monoStyle(context, size: 12),
          ),
        );
    }
  }
}
