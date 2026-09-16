import 'model.dart';

final _ansi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

/// Removes ANSI escape sequences from [text].
String stripAnsi(String text) => text.replaceAll(_ansi, '');

/// Renders a notebook as plain text for AI context
/// (docs/07_ai_agent.md §3). Image outputs are replaced with placeholders.
String notebookToPlainText(Notebook nb, {int maxOutputChars = 2000}) {
  final buf = StringBuffer();
  for (final (i, cell) in nb.cells.indexed) {
    buf.writeln('[cell $i, ${cell.type.name}]');
    buf.writeln(cell.source);
    if (cell is CodeCell && cell.outputs.isNotEmpty) {
      buf.writeln('[outputs]');
      for (final o in cell.outputs) {
        buf.writeln(_truncate(outputToPlainText(o), maxOutputChars));
      }
    }
    buf.writeln();
  }
  return buf.toString();
}

/// Renders one output as plain text.
String outputToPlainText(Output o) {
  switch (o) {
    case StreamOutput():
      return o.text;
    case ErrorOutput():
      return stripAnsi('${o.ename}: ${o.evalue}\n${o.traceback.join('\n')}');
    case DisplayDataOutput():
      final mime = o.data.preferred();
      if (mime == null) return '';
      if (mime.startsWith('image/')) {
        return o.data.entries.containsKey('text/plain')
            ? '[$mime output] ${o.data.entries['text/plain']}'
            : '[$mime output]';
      }
      if (mime == 'text/html' && o.data.entries.containsKey('text/plain')) {
        return o.data.entries['text/plain']!;
      }
      return o.data.entries[mime]!;
  }
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}… [truncated]';
