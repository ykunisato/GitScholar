import 'package:nbformat/nbformat.dart';

import '../../domain/entities/entities.dart';
import '../../domain/services/ignore_rules.dart';

/// Text extracted from a PDF, page by page.
typedef PdfTextExtractor = Future<List<String>> Function(List<int> bytes);

/// The file currently open in the viewer.
class OpenFileContext {
  const OpenFileContext({
    required this.content,
    this.selection,
    this.pdfPages,
    this.currentPage,
  });

  final FileContent content;
  final ViewerSelection? selection;

  /// Extracted page texts for PDFs.
  final List<String>? pdfPages;

  /// 1-based current page for PDFs.
  final int? currentPage;
}

/// Builds the `<context>` block (docs/07_ai_agent.md §3).
abstract final class ContextBuilder {
  static const maxContentChars = 200000;
  static const maxTreeLines = 200;
  static const pdfFullTextPageLimit = 50;

  /// Renders a file as plain text for the model.
  static String renderFile(FileContent f, {List<String>? pdfPages}) {
    switch (f.kind) {
      case FileKind.notebook:
        final text = f.text;
        if (text == null) return '[binary notebook]';
        try {
          return notebookToPlainText(parseNotebook(text));
        } on NbformatException catch (e) {
          return '[invalid notebook: ${e.message}]\n$text';
        }
      case FileKind.pdf:
        if (pdfPages == null) return '[PDF text not available]';
        return [
          for (final (i, t) in pdfPages.indexed) '[page ${i + 1}]\n$t',
        ].join('\n');
      case FileKind.image:
        return '[image file, ${f.size} bytes]';
      case FileKind.binary:
        return '[binary file, ${f.size} bytes]';
      case FileKind.markdown:
      case FileKind.code:
      case FileKind.text:
      case FileKind.unknown:
        return f.text ?? '[binary file, ${f.size} bytes]';
    }
  }

  /// Builds the full context block. Ignored files contribute only their path.
  static String build({
    required Workspace workspace,
    required IgnoreRules rules,
    OpenFileContext? open,
    bool pdfFullText = false,
    bool includeTree = true,
  }) {
    final b = StringBuffer()
      ..writeln('<context>')
      ..writeln(
        '<repository name="${workspace.repo.fullName}" branch="${workspace.branch}" />',
      );
    if (open != null) {
      final f = open.content;
      final sel = open.selection;
      final attrs = StringBuffer('path="${f.path}" kind="${f.kind.name}"');
      if (sel != null && sel.startLine != null) {
        attrs.write(
          ' selection_lines="${sel.startLine}-${sel.endLine ?? sel.startLine}"',
        );
      }
      if (open.currentPage != null) {
        attrs.write(' current_page="${open.currentPage}"');
      }
      b.writeln('<open_file $attrs>');
      if (rules.isIgnored(f.path)) {
        b.writeln('[access restricted by .gitscholarignore]');
      } else {
        b
          ..writeln('<content>')
          ..writeln(_content(open, pdfFullText: pdfFullText))
          ..writeln('</content>');
        if (sel != null && sel.text.isNotEmpty) {
          b
            ..writeln('<selection>')
            ..writeln(sel.text)
            ..writeln('</selection>');
        }
      }
      b.writeln('</open_file>');
    }
    if (includeTree) {
      b
        ..writeln('<tree_summary>')
        ..writeln(treeSummary(workspace))
        ..writeln('</tree_summary>');
    }
    b.write('</context>');
    return b.toString();
  }

  static String _content(OpenFileContext open, {required bool pdfFullText}) {
    final f = open.content;
    if (f.kind == FileKind.pdf && open.pdfPages != null) {
      final pages = open.pdfPages!;
      if (pdfFullText || pages.length <= pdfFullTextPageLimit) {
        return _truncate(renderFile(f, pdfPages: pages));
      }
      final center = (open.currentPage ?? 1) - 1;
      final start = (center - 5).clamp(0, pages.length - 1);
      final end = (center + 5).clamp(0, pages.length - 1);
      return _truncate(
        [
          '[pages ${start + 1}-${end + 1} of ${pages.length}]',
          for (var i = start; i <= end; i++) '[page ${i + 1}]\n${pages[i]}',
        ].join('\n'),
      );
    }
    final text = renderFile(f, pdfPages: open.pdfPages);
    if (text.length <= maxContentChars) return text;
    final sel = open.selection;
    final lines = text.split('\n');
    if (sel?.startLine != null) {
      final s = (sel!.startLine! - 2000).clamp(0, lines.length);
      final e = ((sel.endLine ?? sel.startLine!) + 2000).clamp(0, lines.length);
      return '[lines ${s + 1}-$e of ${lines.length}]\n${lines.sublist(s, e).join('\n')}';
    }
    return _truncate(text);
  }

  static String _truncate(String s) => s.length <= maxContentChars
      ? s
      : '${s.substring(0, maxContentChars)}\n[truncated: ${s.length} chars total; use read_file with line ranges]';

  /// Directory listing to depth 2, at most [maxTreeLines] lines.
  static String treeSummary(Workspace ws) {
    final lines = <String>[];
    final sorted = ws.entries.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final e in sorted) {
      final depth = '/'.allMatches(e.path).length;
      if (depth > 1) continue;
      lines.add(e.type == TreeEntryType.tree ? '${e.path}/' : e.path);
      if (lines.length >= maxTreeLines) {
        lines.add('... (${ws.entries.length} entries total)');
        break;
      }
    }
    return lines.join('\n');
  }
}
