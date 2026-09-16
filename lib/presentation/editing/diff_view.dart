import 'package:flutter/material.dart';
import 'package:text_diff/text_diff.dart';

import '../../application/editing/change_diff.dart';
import '../../application/editing/notebook_diff.dart';
import '../../domain/entities/entities.dart';
import '../core/theme.dart';
import '../core/widgets.dart';

/// Renders a change as a unified or side-by-side diff (docs/06 §2).
class ChangeDiffView extends StatefulWidget {
  const ChangeDiffView({
    super.key,
    required this.contents,
    this.shrinkWrap = false,
  });

  final ChangeContents contents;
  final bool shrinkWrap;

  @override
  State<ChangeDiffView> createState() => _ChangeDiffViewState();
}

class _ChangeDiffViewState extends State<ChangeDiffView> {
  bool _sideBySide = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = widget.contents;
    if (c.change.kind == ChangeKind.delete) {
      return EmptyState(
        icon: Icons.delete_outline,
        message: l.fileWillBeDeleted,
      );
    }
    if (c.isBinary) {
      return EmptyState(
        icon: Icons.insert_drive_file_outlined,
        message: l.binaryChanged(
          formatBytes(c.oldBytes?.length ?? 0),
          formatBytes(c.newBytes?.length ?? 0),
        ),
      );
    }
    if (c.kind == FileKind.notebook) {
      final cells = c.notebookDiff();
      if (cells != null) {
        return NotebookDiffView(cells: cells, shrinkWrap: widget.shrinkWrap);
      }
    }
    List<DiffLine> lines;
    try {
      lines = c.lineDiff();
    } on DiffTooLarge {
      return Column(
        children: [
          MaterialBanner(
            content: Text(l.diffTooLarge),
            actions: const [SizedBox.shrink()],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(c.newText ?? '', style: monoStyle(context)),
            ),
          ),
        ],
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.wide;
    final header = Row(
      children: [
        if (c.change.kind == ChangeKind.rename)
          Expanded(
            child: Text(
              '${c.change.oldPath} → ${c.change.path}',
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          const Spacer(),
        if (wide && !widget.shrinkWrap)
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(l.unified)),
              ButtonSegment(value: true, label: Text(l.sideBySide)),
            ],
            selected: {_sideBySide},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _sideBySide = s.first),
          ),
      ],
    );
    final body = _sideBySide && wide
        ? _SideBySide(lines: lines, shrinkWrap: widget.shrinkWrap)
        : UnifiedDiffList(
            lines: toHunks(lines, context: 3),
            shrinkWrap: widget.shrinkWrap,
          );
    if (widget.shrinkWrap) return body;
    return Column(
      children: [
        Padding(padding: const EdgeInsets.all(8), child: header),
        Expanded(child: body),
      ],
    );
  }
}

/// Unified diff of hunks.
class UnifiedDiffList extends StatelessWidget {
  const UnifiedDiffList({
    super.key,
    required this.lines,
    this.shrinkWrap = false,
  });

  final List<Hunk> lines;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final rows = <Object>[
      for (final h in lines) ...[h.header, ...h.lines],
    ];
    if (rows.isEmpty) {
      return EmptyState(icon: Icons.check, message: context.l10n.noDifferences);
    }
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final style = monoStyle(context, size: 12);
    Widget row(Object r) {
      if (r is String) {
        return Container(
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Text(r, style: style.copyWith(color: scheme.onSurfaceVariant)),
        );
      }
      final d = r as DiffLine;
      final (bg, fg, sign) = switch (d.op) {
        DiffOp.insert => (colors.diffAdded, colors.diffAddedText, '+'),
        DiffOp.delete => (colors.diffRemoved, colors.diffRemovedText, '-'),
        DiffOp.equal => (Colors.transparent, scheme.onSurface, ' '),
      };
      return Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 36,
              child: Text(
                '${d.oldLineNo ?? ''}',
                textAlign: TextAlign.right,
                style: style.copyWith(color: scheme.outline),
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                '${d.newLineNo ?? ''}',
                textAlign: TextAlign.right,
                style: style.copyWith(color: scheme.outline),
              ),
            ),
            const SizedBox(width: 6),
            Text(sign, style: style.copyWith(color: fg)),
            const SizedBox(width: 4),
            Expanded(
              child: Text(d.text, style: style.copyWith(color: fg)),
            ),
          ],
        ),
      );
    }

    if (shrinkWrap) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final r in rows) row(r)],
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) => row(rows[i]),
    );
  }
}

class _SideBySide extends StatelessWidget {
  const _SideBySide({required this.lines, required this.shrinkWrap});

  final List<DiffLine> lines;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    // Pair deletes with following inserts on the same row.
    final rows = <(DiffLine?, DiffLine?)>[];
    var i = 0;
    while (i < lines.length) {
      final l = lines[i];
      if (l.op == DiffOp.equal) {
        rows.add((l, l));
        i++;
        continue;
      }
      final dels = <DiffLine>[];
      final ins = <DiffLine>[];
      while (i < lines.length && lines[i].op == DiffOp.delete) {
        dels.add(lines[i++]);
      }
      while (i < lines.length && lines[i].op == DiffOp.insert) {
        ins.add(lines[i++]);
      }
      final n = dels.length > ins.length ? dels.length : ins.length;
      for (var k = 0; k < n; k++) {
        rows.add((
          k < dels.length ? dels[k] : null,
          k < ins.length ? ins[k] : null,
        ));
      }
    }
    final colors = context.colors;
    final style = monoStyle(context, size: 12);
    final scheme = Theme.of(context).colorScheme;
    Widget cell(DiffLine? d, bool left) {
      final changed = d != null && d.op != DiffOp.equal;
      final bg = !changed
          ? Colors.transparent
          : (left ? colors.diffRemoved : colors.diffAdded);
      return Expanded(
        child: Container(
          color: d == null
              ? scheme.surfaceContainerHighest.withValues(alpha: 0.4)
              : bg,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Text(
                  '${left ? d?.oldLineNo ?? '' : d?.newLineNo ?? ''}',
                  textAlign: TextAlign.right,
                  style: style.copyWith(color: scheme.outline),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(d?.text ?? '', style: style)),
            ],
          ),
        ),
      );
    }

    Widget row((DiffLine?, DiffLine?) r) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          cell(r.$1, true),
          const VerticalDivider(width: 1),
          cell(r.$2, false),
        ],
      ),
    );
    if (shrinkWrap) return Column(children: [for (final r in rows) row(r)]);
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) => row(rows[i]),
    );
  }
}

/// Cell-level notebook diff.
class NotebookDiffView extends StatelessWidget {
  const NotebookDiffView({
    super.key,
    required this.cells,
    this.shrinkWrap = false,
  });

  final List<CellDiff> cells;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final changed = [
      for (final c in cells)
        if (c.type != CellChangeType.unchanged) c,
    ];
    if (changed.isEmpty) {
      return EmptyState(icon: Icons.check, message: l.noDifferences);
    }
    final colors = context.colors;
    Widget item(CellDiff d) {
      final index = (d.newIndex ?? d.oldIndex)! + 1;
      final (label, color) = switch (d.type) {
        CellChangeType.added => (l.cellAdded(index), colors.diffAddedText),
        CellChangeType.removed => (
          l.cellRemoved(index),
          colors.diffRemovedText,
        ),
        _ => (l.cellModified(index), Theme.of(context).colorScheme.primary),
      };
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Badge2(d.cell.type.name, color: color),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(color: color)),
                ],
              ),
              const SizedBox(height: 6),
              if (d.type == CellChangeType.modified && d.sourceDiff.isNotEmpty)
                UnifiedDiffList(
                  lines: toHunks(d.sourceDiff, context: 2),
                  shrinkWrap: true,
                )
              else if (d.type != CellChangeType.modified)
                Container(
                  color: d.type == CellChangeType.added
                      ? colors.diffAdded
                      : colors.diffRemoved,
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    d.cell.source,
                    style: monoStyle(context, size: 12),
                  ),
                ),
              if (d.outputsChanged)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l.outputsUpdated,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (shrinkWrap) return Column(children: [for (final c in changed) item(c)]);
    return ListView(children: [for (final c in changed) item(c)]);
  }
}
