import 'dart:convert';

import 'package:nbformat/nbformat.dart';
import 'package:text_diff/text_diff.dart';

enum CellChangeType { added, removed, modified, unchanged }

/// One cell-level difference (docs/06_editing_diff_commit.md §2).
class CellDiff {
  const CellDiff({
    required this.type,
    this.oldIndex,
    this.newIndex,
    this.oldCell,
    this.newCell,
    this.sourceDiff = const [],
    this.outputsChanged = false,
  });

  final CellChangeType type;
  final int? oldIndex;
  final int? newIndex;
  final Cell? oldCell;
  final Cell? newCell;
  final List<DiffLine> sourceDiff;
  final bool outputsChanged;

  Cell get cell => (newCell ?? oldCell)!;
}

/// Aligns cells by id (when every cell has one) or by source, then reports
/// added, removed and modified cells.
List<CellDiff> diffNotebooks(Notebook a, Notebook b) {
  final useIds =
      a.cells.every((c) => c.id != null) && b.cells.every((c) => c.id != null);
  // Keys must be single "lines" for the line differ, so encode sources.
  String key(Cell c) =>
      useIds ? c.id! : '${c.type.name}:${base64.encode(utf8.encode(c.source))}';
  final ops = diffLineLists(
    [for (final c in a.cells) key(c)],
    [for (final c in b.cells) key(c)],
  );

  final out = <CellDiff>[];
  final deletes = <int>[];
  final inserts = <int>[];

  void flush() {
    final pairs = useIds
        ? 0
        : (deletes.length < inserts.length ? deletes.length : inserts.length);
    for (var i = 0; i < pairs; i++) {
      out.add(_compare(a, b, deletes[i], inserts[i], forceModified: true));
    }
    for (final i in deletes.skip(pairs)) {
      out.add(
        CellDiff(
          type: CellChangeType.removed,
          oldIndex: i,
          oldCell: a.cells[i],
        ),
      );
    }
    for (final j in inserts.skip(pairs)) {
      out.add(
        CellDiff(type: CellChangeType.added, newIndex: j, newCell: b.cells[j]),
      );
    }
    deletes.clear();
    inserts.clear();
  }

  for (final op in ops) {
    switch (op.op) {
      case DiffOp.delete:
        deletes.add(op.oldLineNo! - 1);
      case DiffOp.insert:
        inserts.add(op.newLineNo! - 1);
      case DiffOp.equal:
        flush();
        out.add(_compare(a, b, op.oldLineNo! - 1, op.newLineNo! - 1));
    }
  }
  flush();
  return out;
}

CellDiff _compare(
  Notebook a,
  Notebook b,
  int i,
  int j, {
  bool forceModified = false,
}) {
  final oc = a.cells[i];
  final nc = b.cells[j];
  final sourceChanged = oc.source != nc.source || oc.type != nc.type;
  final outputsChanged = _outputs(oc) != _outputs(nc);
  final modified = forceModified || sourceChanged || outputsChanged;
  return CellDiff(
    type: modified ? CellChangeType.modified : CellChangeType.unchanged,
    oldIndex: i,
    newIndex: j,
    oldCell: oc,
    newCell: nc,
    sourceDiff: sourceChanged ? diffLines(oc.source, nc.source) : const [],
    outputsChanged: outputsChanged,
  );
}

String _outputs(Cell c) {
  if (c is! CodeCell) return '';
  final json = notebookToJson(
    Notebook(
      cells: [CodeCell(id: 'x', outputs: c.outputs)],
    ),
  );
  return jsonEncode(((json['cells'] as List).first as Map)['outputs']);
}
