import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nbformat/nbformat.dart';

import '../../../domain/entities/entities.dart';
import '../../../domain/failures.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../code/highlighted_code.dart';
import '../markdown/markdown_body.dart';
import 'output_view.dart';

/// Parses off the UI isolate for large notebooks (docs/02 §9).
Future<Notebook> parseNotebookAsync(String text) => text.length >= 200 * 1024
    ? compute(parseNotebook, text)
    : Future.value(parseNotebook(text));

/// Notebook viewer and cell editor (docs/05 §3, docs/06 §1.2).
class NotebookViewer extends ConsumerStatefulWidget {
  const NotebookViewer({super.key, required this.file, required this.editing});

  final FileContent file;
  final bool editing;

  @override
  ConsumerState<NotebookViewer> createState() => _NotebookViewerState();
}

class _NotebookViewerState extends ConsumerState<NotebookViewer> {
  Notebook? _nb;
  Object? _error;
  String? _loadedSha;
  Timer? _saveTimer;
  int? _editingCell;
  final _running = <int>{};
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NotebookViewer old) {
    super.didUpdateWidget(old);
    if (widget.file.blobSha != _loadedSha && !_dirty && _running.isEmpty) {
      _load();
    }
    if (old.editing && !widget.editing) {
      _flush();
      _editingCell = null;
    }
  }

  Future<void> _load() async {
    final text = widget.file.text;
    if (text == null) {
      setState(() => _error = const ValidationFailure('Notebook is not UTF-8'));
      return;
    }
    try {
      final nb = await parseNotebookAsync(text);
      if (mounted) {
        setState(() {
          _nb = nb;
          _error = null;
          _loadedSha = widget.file.blobSha;
        });
      }
    } on NbformatException catch (e) {
      if (mounted) setState(() => _error = ValidationFailure(e.message));
    }
  }

  void _changed() {
    _dirty = true;
    setState(() {});
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _flush);
  }

  Future<void> _flush() async {
    _saveTimer?.cancel();
    if (!_dirty || _nb == null) return;
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    _dirty = false;
    try {
      final saved = await ref
          .read(editingServiceProvider)
          .saveText(ws, widget.file.path, serializeNotebook(_nb!));
      _loadedSha = saved?.contentSha ?? widget.file.blobSha;
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, failureMessage(context, e));
    }
  }

  @override
  void dispose() {
    if (_dirty) unawaited(_flush());
    _saveTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------- editing

  void _insert(int index, CellType type) {
    final nb = _nb!;
    final id = nb.requiresCellIds ? Notebook.newCellId() : null;
    nb.cells.insert(
      index,
      type == CellType.code ? CodeCell(id: id) : MarkdownCell(id: id),
    );
    _editingCell = index;
    _changed();
  }

  void _delete(int i) {
    _nb!.cells.removeAt(i);
    _editingCell = null;
    _changed();
  }

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _nb!.cells.length) return;
    final c = _nb!.cells.removeAt(i);
    _nb!.cells.insert(j, c);
    _editingCell = j;
    _changed();
  }

  void _toggleType(int i) {
    final c = _nb!.cells[i];
    _nb!.cells[i] = c is CodeCell
        ? MarkdownCell(id: c.id, metadata: c.metadata, source: c.source)
        : CodeCell(id: c.id, metadata: c.metadata, source: c.source);
    _changed();
  }

  void _clearOutputs(int i) {
    final c = _nb!.cells[i];
    if (c is CodeCell) {
      c.outputs = [];
      c.executionCount = null;
      _changed();
    }
  }

  Future<void> _run(List<int> indices) async {
    final exec = ref.read(executionServiceProvider);
    final ws = ref.read(currentWorkspaceProvider).value;
    if (exec == null || ws == null || _nb == null) {
      showSnack(context, context.l10n.executionNotConfigured);
      return;
    }
    await _flush();
    setState(() => _running.addAll(indices));
    try {
      final updated = await exec.runNotebookCells(
        ws,
        widget.file.path,
        _nb!,
        indices,
        onCellDone: (i, nb) {
          if (mounted) {
            setState(() {
              _nb = nb;
              _running.remove(i);
            });
          }
        },
      );
      if (mounted) setState(() => _nb = updated);
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, failureMessage(context, e));
    } finally {
      if (mounted) setState(_running.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_error != null) return FailureView(error: _error!);
    final nb = _nb;
    if (nb == null) return const Center(child: CircularProgressIndicator());
    final exec = ref.watch(executionServiceProvider);
    final language = nb.language ?? 'python';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              Badge2(language),
              const SizedBox(width: 8),
              Text(
                l.cellCount(nb.cells.length),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              if (exec != null) ...[
                IconButton(
                  tooltip: l.runAll,
                  icon: const Icon(Icons.fast_forward),
                  onPressed: _running.isNotEmpty
                      ? null
                      : () => _run([
                          for (var i = 0; i < nb.cells.length; i++)
                            if (nb.cells[i] is CodeCell) i,
                        ]),
                ),
                IconButton(
                  tooltip: l.interrupt,
                  icon: const Icon(Icons.stop),
                  onPressed: _running.isEmpty ? null : exec.interruptAll,
                ),
                IconButton(
                  tooltip: l.restartKernel,
                  icon: const Icon(Icons.restart_alt),
                  onPressed: exec.restartAll,
                ),
              ],
              if (widget.editing) ...[
                IconButton(
                  tooltip: l.addCodeCell,
                  icon: const Icon(Icons.add_box_outlined),
                  onPressed: () => _insert(nb.cells.length, CellType.code),
                ),
                IconButton(
                  tooltip: l.addMarkdownCell,
                  icon: const Icon(Icons.post_add),
                  onPressed: () => _insert(nb.cells.length, CellType.markdown),
                ),
              ],
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: nb.cells.isEmpty
              ? EmptyState(
                  icon: Icons.menu_book_outlined,
                  message: l.emptyNotebook,
                )
              : ListView.builder(
                  key: const Key('notebookCells'),
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: nb.cells.length,
                  itemBuilder: (context, i) => CellView(
                    key: ValueKey(
                      nb.cells[i].id ??
                          'cell-$i-${identityHashCode(nb.cells[i])}',
                    ),
                    cell: nb.cells[i],
                    index: i,
                    language: language,
                    path: widget.file.path,
                    editing: widget.editing && _editingCell == i,
                    editable: widget.editing,
                    running: _running.contains(i),
                    canRun: exec != null,
                    onTap: () {
                      ref
                          .read(selectionProvider.notifier)
                          .set(
                            ViewerSelection(
                              path: widget.file.path,
                              text: nb.cells[i].source,
                              cellIndex: i,
                            ),
                          );
                      if (widget.editing) setState(() => _editingCell = i);
                    },
                    onSourceChanged: (s) {
                      nb.cells[i].source = s;
                      _changed();
                    },
                    onAction: (a) => switch (a) {
                      CellAction.insertCodeAbove => _insert(i, CellType.code),
                      CellAction.insertCodeBelow => _insert(
                        i + 1,
                        CellType.code,
                      ),
                      CellAction.insertMarkdownBelow => _insert(
                        i + 1,
                        CellType.markdown,
                      ),
                      CellAction.delete => _delete(i),
                      CellAction.moveUp => _move(i, -1),
                      CellAction.moveDown => _move(i, 1),
                      CellAction.toggleType => _toggleType(i),
                      CellAction.clearOutputs => _clearOutputs(i),
                      CellAction.run => _run([i]),
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

enum CellAction {
  insertCodeAbove,
  insertCodeBelow,
  insertMarkdownBelow,
  delete,
  moveUp,
  moveDown,
  toggleType,
  clearOutputs,
  run,
}

class CellView extends ConsumerStatefulWidget {
  const CellView({
    super.key,
    required this.cell,
    required this.index,
    required this.language,
    required this.path,
    required this.editing,
    required this.editable,
    required this.running,
    required this.canRun,
    required this.onTap,
    required this.onSourceChanged,
    required this.onAction,
  });

  final Cell cell;
  final int index;
  final String language;
  final String path;
  final bool editing;
  final bool editable;
  final bool running;
  final bool canRun;
  final VoidCallback onTap;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<CellAction> onAction;

  @override
  ConsumerState<CellView> createState() => _CellViewState();
}

class _CellViewState extends ConsumerState<CellView> {
  late final TextEditingController _text = TextEditingController(
    text: widget.cell.source,
  );
  late bool _sourceOpen = !widget.cell.sourceHidden;
  late bool _outputsOpen = !widget.cell.outputsHidden;

  @override
  void didUpdateWidget(CellView old) {
    super.didUpdateWidget(old);
    if (!widget.editing && _text.text != widget.cell.source) {
      _text.text = widget.cell.source;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cell = widget.cell;
    final scheme = Theme.of(context).colorScheme;
    final colors = context.colors;
    final isCode = cell is CodeCell;
    void open(String p) => openPath(context, ref, p);

    final Widget source;
    if (widget.editing) {
      source = TextField(
        controller: _text,
        autofocus: true,
        maxLines: null,
        style: monoStyle(context),
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
        ),
        onChanged: widget.onSourceChanged,
      );
    } else if (!_sourceOpen) {
      source = TextButton(
        onPressed: () => setState(() => _sourceOpen = true),
        child: Text(l.showSource),
      );
    } else if (cell is MarkdownCell) {
      source = cell.source.trim().isEmpty
          ? Text(l.emptyCell, style: TextStyle(color: scheme.outline))
          : MarkdownBody(
              data: cell.source,
              basePath: widget.path,
              onOpenPath: open,
            );
    } else if (isCode) {
      source = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: colors.cellBackground,
          borderRadius: BorderRadius.circular(4),
        ),
        child: HighlightedCode(code: cell.source, language: widget.language),
      );
    } else {
      source = SelectableText(cell.source, style: monoStyle(context));
    }

    final outputs = cell is CodeCell ? cell.outputs : const <Output>[];
    return InkWell(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 3,
              color: widget.editing ? scheme.primary : Colors.transparent,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              child: widget.running
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      cell is CodeCell ? '[${cell.executionCount ?? ' '}]' : '',
                      textAlign: TextAlign.right,
                      style: monoStyle(
                        context,
                        size: 12,
                        color: scheme.outline,
                      ),
                    ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (cell.tags.isNotEmpty || widget.editable)
                    Row(
                      children: [
                        for (final t in cell.tags)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Badge2(t),
                          ),
                        const Spacer(),
                        if (widget.canRun && isCode)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: l.runCell,
                            icon: const Icon(Icons.play_arrow, size: 18),
                            onPressed: widget.running
                                ? null
                                : () => widget.onAction(CellAction.run),
                          ),
                        if (widget.editable)
                          PopupMenuButton<CellAction>(
                            iconSize: 18,
                            tooltip: l.cellActions,
                            onSelected: widget.onAction,
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: CellAction.insertCodeAbove,
                                child: Text(l.insertCodeAbove),
                              ),
                              PopupMenuItem(
                                value: CellAction.insertCodeBelow,
                                child: Text(l.insertCodeBelow),
                              ),
                              PopupMenuItem(
                                value: CellAction.insertMarkdownBelow,
                                child: Text(l.insertMarkdownBelow),
                              ),
                              PopupMenuItem(
                                value: CellAction.moveUp,
                                child: Text(l.moveUp),
                              ),
                              PopupMenuItem(
                                value: CellAction.moveDown,
                                child: Text(l.moveDown),
                              ),
                              PopupMenuItem(
                                value: CellAction.toggleType,
                                child: Text(isCode ? l.toMarkdown : l.toCode),
                              ),
                              if (isCode)
                                PopupMenuItem(
                                  value: CellAction.clearOutputs,
                                  child: Text(l.clearOutputs),
                                ),
                              PopupMenuItem(
                                value: CellAction.delete,
                                child: Text(l.delete),
                              ),
                            ],
                          ),
                      ],
                    ),
                  source,
                  if (outputs.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    if (_outputsOpen)
                      for (final o in outputs)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: OutputView(
                            output: o,
                            basePath: widget.path,
                            onOpenPath: open,
                          ),
                        )
                    else
                      TextButton(
                        onPressed: () => setState(() => _outputsOpen = true),
                        child: Text(l.showOutputs(outputs.length)),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
