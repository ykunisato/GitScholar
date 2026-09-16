/// The kind of a diff line.
enum DiffOp {
  /// Present in both inputs.
  equal,

  /// Present only in the new input.
  insert,

  /// Present only in the old input.
  delete,
}

/// One line of a diff.
class DiffLine {
  /// Creates a diff line.
  const DiffLine(this.op, this.text, {this.oldLineNo, this.newLineNo});

  /// Operation for this line.
  final DiffOp op;

  /// Line text without the trailing newline.
  final String text;

  /// 1-based line number in the old input, or null for inserts.
  final int? oldLineNo;

  /// 1-based line number in the new input, or null for deletes.
  final int? newLineNo;

  @override
  bool operator ==(Object other) =>
      other is DiffLine &&
      other.op == op &&
      other.text == text &&
      other.oldLineNo == oldLineNo &&
      other.newLineNo == newLineNo;

  @override
  int get hashCode => Object.hash(op, text, oldLineNo, newLineNo);

  @override
  String toString() {
    final prefix = switch (op) {
      DiffOp.equal => ' ',
      DiffOp.insert => '+',
      DiffOp.delete => '-',
    };
    return '$prefix$text';
  }
}

/// A contiguous group of changes with surrounding context.
class Hunk {
  /// Creates a hunk.
  const Hunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  /// 1-based start line in the old input (0 when [oldCount] is 0).
  final int oldStart;

  /// Number of old lines covered.
  final int oldCount;

  /// 1-based start line in the new input (0 when [newCount] is 0).
  final int newStart;

  /// Number of new lines covered.
  final int newCount;

  /// Lines in this hunk.
  final List<DiffLine> lines;

  /// Unified diff header, e.g. `@@ -1,3 +1,4 @@`.
  String get header =>
      '@@ -${_range(oldStart, oldCount)} +${_range(newStart, newCount)} @@';

  static String _range(int start, int count) =>
      count == 1 ? '$start' : '$start,$count';
}

/// Counts of added and deleted lines.
class DiffStats {
  /// Creates stats.
  const DiffStats({required this.added, required this.deleted});

  /// Number of inserted lines.
  final int added;

  /// Number of deleted lines.
  final int deleted;
}

/// Thrown when an input exceeds [maxDiffLines].
class DiffTooLarge implements Exception {
  /// Creates the exception.
  const DiffTooLarge(this.lineCount);

  /// The number of lines in the larger input.
  final int lineCount;

  @override
  String toString() => 'DiffTooLarge($lineCount lines)';
}

/// Maximum number of lines per input before [DiffTooLarge] is thrown.
const int maxDiffLines = 20000;

/// Splits [text] into lines, normalising `\r\n` to `\n`.
///
/// A trailing newline does not produce an extra empty line; an empty string
/// produces no lines.
List<String> splitLines(String text) {
  if (text.isEmpty) return const [];
  final normalised = text.replaceAll('\r\n', '\n');
  final lines = normalised.split('\n');
  if (normalised.endsWith('\n')) lines.removeLast();
  return lines;
}

/// Computes a line diff from [a] to [b] using Myers' O(ND) algorithm.
///
/// Throws [DiffTooLarge] when either input has more than [maxDiffLines] lines.
List<DiffLine> diffLines(String a, String b) {
  final oldLines = splitLines(a);
  final newLines = splitLines(b);
  final larger = oldLines.length > newLines.length
      ? oldLines.length
      : newLines.length;
  if (larger > maxDiffLines) throw DiffTooLarge(larger);
  return diffLineLists(oldLines, newLines);
}

/// Computes a diff between two already-split line lists.
List<DiffLine> diffLineLists(List<String> oldLines, List<String> newLines) {
  // Trim common prefix and suffix to keep the core small.
  var prefix = 0;
  while (prefix < oldLines.length &&
      prefix < newLines.length &&
      oldLines[prefix] == newLines[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < oldLines.length - prefix &&
      suffix < newLines.length - prefix &&
      oldLines[oldLines.length - 1 - suffix] ==
          newLines[newLines.length - 1 - suffix]) {
    suffix++;
  }
  final a = oldLines.sublist(prefix, oldLines.length - suffix);
  final b = newLines.sublist(prefix, newLines.length - suffix);

  final ops = <DiffOp>[
    for (var i = 0; i < prefix; i++) DiffOp.equal,
    ..._myers(a, b),
    for (var i = 0; i < suffix; i++) DiffOp.equal,
  ];

  final result = <DiffLine>[];
  var oi = 0;
  var ni = 0;
  for (final op in ops) {
    switch (op) {
      case DiffOp.equal:
        result.add(
          DiffLine(op, oldLines[oi], oldLineNo: oi + 1, newLineNo: ni + 1),
        );
        oi++;
        ni++;
      case DiffOp.delete:
        result.add(DiffLine(op, oldLines[oi], oldLineNo: oi + 1));
        oi++;
      case DiffOp.insert:
        result.add(DiffLine(op, newLines[ni], newLineNo: ni + 1));
        ni++;
    }
  }
  return result;
}

/// Myers shortest edit script, returned as a sequence of operations.
List<DiffOp> _myers(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0) return List.filled(m, DiffOp.insert);
  if (m == 0) return List.filled(n, DiffOp.delete);

  final max = n + m;
  final offset = max;
  final v = List<int>.filled(2 * max + 2, 0);
  final trace = <List<int>>[];

  outer:
  for (var d = 0; d <= max; d++) {
    trace.add(List<int>.of(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        x = v[offset + k + 1];
      } else {
        x = v[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) break outer;
    }
  }

  // Backtrack.
  final ops = <DiffOp>[];
  var x = n;
  var y = m;
  for (var d = trace.length - 1; d >= 0; d--) {
    final vd = trace[d];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = vd[offset + prevK];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add(DiffOp.equal);
      x--;
      y--;
    }
    if (d > 0) {
      if (x == prevX) {
        ops.add(DiffOp.insert);
        y--;
      } else {
        ops.add(DiffOp.delete);
        x--;
      }
    }
  }
  return ops.reversed.toList();
}

/// Groups [lines] into hunks with [context] lines of surrounding context.
List<Hunk> toHunks(List<DiffLine> lines, {int context = 3}) {
  final changeIdx = <int>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].op != DiffOp.equal) i,
  ];
  if (changeIdx.isEmpty) return const [];

  final ranges = <List<int>>[];
  for (final i in changeIdx) {
    final start = (i - context).clamp(0, lines.length - 1);
    final end = (i + context).clamp(0, lines.length - 1);
    if (ranges.isNotEmpty && start <= ranges.last[1] + 1) {
      ranges.last[1] = end;
    } else {
      ranges.add([start, end]);
    }
  }

  return [
    for (final r in ranges)
      _buildHunk(lines, lines.sublist(r[0], r[1] + 1), r[0]),
  ];
}

Hunk _buildHunk(List<DiffLine> all, List<DiffLine> slice, int startIndex) {
  var oldCount = 0;
  var newCount = 0;
  int? oldStart;
  int? newStart;
  for (final l in slice) {
    if (l.op != DiffOp.insert) {
      oldCount++;
      oldStart ??= l.oldLineNo;
    }
    if (l.op != DiffOp.delete) {
      newCount++;
      newStart ??= l.newLineNo;
    }
  }
  // For empty sides, unified diff uses the line before the hunk (0 at start).
  oldStart ??= _precedingLineNo(all, startIndex, old: true);
  newStart ??= _precedingLineNo(all, startIndex, old: false);
  return Hunk(
    oldStart: oldStart,
    oldCount: oldCount,
    newStart: newStart,
    newCount: newCount,
    lines: slice,
  );
}

int _precedingLineNo(List<DiffLine> all, int index, {required bool old}) {
  for (var i = index - 1; i >= 0; i--) {
    final no = old ? all[i].oldLineNo : all[i].newLineNo;
    if (no != null) return no;
  }
  return 0;
}

/// Renders [hunks] as a unified diff.
String toUnified(
  List<Hunk> hunks, {
  required String oldPath,
  required String newPath,
}) {
  final buf = StringBuffer()
    ..writeln('--- a/$oldPath')
    ..writeln('+++ b/$newPath');
  for (final h in hunks) {
    buf.writeln(h.header);
    for (final l in h.lines) {
      buf.writeln(l.toString());
    }
  }
  return buf.toString();
}

/// Counts added and deleted lines.
DiffStats stats(List<DiffLine> lines) {
  var added = 0;
  var deleted = 0;
  for (final l in lines) {
    if (l.op == DiffOp.insert) added++;
    if (l.op == DiffOp.delete) deleted++;
  }
  return DiffStats(added: added, deleted: deleted);
}

/// Reconstructs the new line list by applying [lines] (for testing).
List<String> applyDiff(List<DiffLine> lines) => [
  for (final l in lines)
    if (l.op != DiffOp.delete) l.text,
];

/// Reconstructs the old line list from [lines] (for testing).
List<String> revertDiff(List<DiffLine> lines) => [
  for (final l in lines)
    if (l.op != DiffOp.insert) l.text,
];
