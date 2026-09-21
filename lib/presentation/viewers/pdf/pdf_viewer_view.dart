import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../application/editing/pdf_sidecar_service.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/failures.dart';
import '../../../domain/services/char_rect_grouping.dart';
import '../../agent/agent_controller.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
import 'pdf_selection_menu.dart';

/// PDF viewer with page navigation, search, selection, outline, marker
/// highlights (FR-90) and the note bar (FR-96).
class PdfViewerView extends ConsumerStatefulWidget {
  const PdfViewerView({super.key, required this.file});

  final FileContent file;

  @override
  ConsumerState<PdfViewerView> createState() => _PdfViewerViewState();
}

class _PdfViewerViewState extends ConsumerState<PdfViewerView> {
  final _controller = PdfViewerController();
  final _searchText = TextEditingController();
  final _note = TextEditingController();

  /// Created only after the document is loaded. PdfTextSearcher dereferences
  /// the controller's viewer state in its constructor, so building it earlier
  /// throws a null check error.
  PdfTextSearcher? _searcher;

  int? _initialPage;
  int _page = 1;
  int _pageCount = 0;
  List<PdfOutlineNode> _outline = const [];
  bool _searching = false;

  /// Current text selection, used to create highlights.
  List<PdfPageTextRange> _ranges = const [];

  /// Latest annotations, read by the page paint callback.
  PdfAnnotations _annotations = PdfAnnotations.empty;

  bool _busy = false;

  String get _positionKey => 'pdfpage:${widget.file.blobSha}';

  @override
  void initState() {
    super.initState();
    ref.read(databaseProvider).getValue(_positionKey).then((v) {
      if (mounted) setState(() => _initialPage = v is int ? v : 1);
    });
  }

  void _onSearch() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searcher?.removeListener(_onSearch);
    _searcher?.dispose();
    _searchText.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _jump() async {
    final l = context.l10n;
    final v = await textInputDialog(
      context,
      title: l.goToPage,
      label: l.pageNumber(_pageCount),
      initial: '$_page',
    );
    final n = int.tryParse(v ?? '');
    if (n != null && n >= 1 && n <= _pageCount) {
      await _controller.goToPage(pageNumber: n);
    }
  }

  // ------------------------------------------------------------ highlights

  /// Paints stored highlights under the page content.
  void _paintHighlights(Canvas canvas, Rect pageRect, PdfPage page) {
    for (final h in _annotations.forPage(page.pageNumber)) {
      final paint = Paint()
        ..color =
            (pdfMarkerColors[h.color] ??
                    pdfMarkerColors[HighlightColor.yellow]!)
                .withValues(alpha: 0.38);
      for (final r in h.rects) {
        final rect = PdfRect(
          math.min(r.left, r.right),
          math.max(r.top, r.bottom),
          math.max(r.left, r.right),
          math.min(r.top, r.bottom),
        );
        if (rect.isEmpty) continue;
        canvas.drawRect(
          rect
              .toRect(page: page, scaledPageSize: pageRect.size)
              .translate(pageRect.left, pageRect.top),
          paint,
        );
      }
    }
  }

  /// Splits a selected range into one rectangle per run of text. Grouping
  /// handles vertical writing as well (docs/05 §1).
  List<HighlightRect> _lineRects(PdfPageTextRange range) {
    final chars = range.pageText.charRects;
    final end = math.min(range.end, chars.length);
    return groupCharRects([
      for (var i = range.start; i < end; i++) _toHighlightRect(chars[i]),
    ]);
  }

  HighlightRect _toHighlightRect(PdfRect r) =>
      HighlightRect(left: r.left, top: r.top, right: r.right, bottom: r.bottom);

  Future<void> _highlight(
    HighlightColor color, {
    PdfTextSelectionDelegate? delegate,
  }) async {
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null || _busy) return;
    var ranges = _ranges;
    if (ranges.isEmpty && delegate != null) {
      ranges = await delegate.getSelectedTextRanges();
    }
    if (ranges.isEmpty || !mounted) return;
    final l = context.l10n;
    setState(() => _busy = true);
    try {
      final rectsByPage = <int, List<HighlightRect>>{};
      final text = StringBuffer();
      for (final r in ranges) {
        (rectsByPage[r.pageNumber] ??= []).addAll(_lineRects(r));
        text.write(r.text);
      }
      await ref
          .read(pdfSidecarServiceProvider)
          .addHighlights(
            ws,
            widget.file.path,
            rectsByPage: rectsByPage,
            color: color,
            text: text.toString().trim(),
          );
      if (!mounted) return;
      setState(() => _ranges = const []);
      ref.read(selectionProvider.notifier).set(null);
      showSnack(context, l.pdfHighlightAdded);
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, failureMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Sends the current selection to the AI pane.
  void _askAi() {
    ref.read(agentControllerProvider.notifier).setAttachOpenFile(true);
    ref.read(shellProvider.notifier).showPane(PhonePane.agent);
  }

  Future<void> _removeHighlight(String id) async {
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    try {
      await ref
          .read(pdfSidecarServiceProvider)
          .removeHighlight(ws, widget.file.path, id);
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, failureMessage(context, e));
    }
  }

  void _showHighlights() {
    final path = widget.file.path;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.6,
        child: Consumer(
          builder: (ctx, ref, _) {
            final annotations =
                ref.watch(pdfAnnotationsProvider(path)).value ??
                PdfAnnotations.empty;
            if (annotations.highlights.isEmpty) {
              return EmptyState(
                icon: Icons.format_color_text,
                message: ctx.l10n.pdfNoHighlights,
              );
            }
            final items = [...annotations.highlights]
              ..sort((a, b) => a.page.compareTo(b.page));
            return ListView(
              children: [
                for (final h in items)
                  ListTile(
                    leading: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: pdfMarkerColors[h.color],
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    title: Text(
                      h.text.isEmpty ? 'p.${h.page}' : h.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('p.${h.page}'),
                    trailing: IconButton(
                      tooltip: ctx.l10n.delete,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _removeHighlight(h.id),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _controller.goToPage(pageNumber: h.page);
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- notes

  Future<void> _saveNote() async {
    final ws = ref.read(currentWorkspaceProvider).value;
    final text = _note.text.trim();
    if (ws == null || text.isEmpty || _busy) return;
    final l = context.l10n;
    final selection = ref.read(selectionProvider);
    final quote = selection != null && selection.path == widget.file.path
        ? selection.text
        : null;
    setState(() => _busy = true);
    try {
      final path = await ref
          .read(pdfSidecarServiceProvider)
          .appendNote(
            ws,
            widget.file.path,
            text: text,
            page: _page,
            quote: quote,
          );
      if (!mounted) return;
      _note.clear();
      if (quote != null) ref.read(selectionProvider.notifier).set(null);
      showSnack(
        context,
        l.pdfNoteSaved(path),
        action: SnackBarAction(
          label: l.open,
          onPressed: () => openPath(context, ref, path),
        ),
      );
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, failureMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openNotes() async {
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    final l = context.l10n;
    final path = PdfSidecarService.notesPathFor(widget.file.path);
    final exists = await ref.read(editingServiceProvider).exists(ws, path);
    if (!mounted) return;
    if (exists) {
      openPath(context, ref, path);
    } else {
      showSnack(context, l.pdfNotesEmpty);
    }
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_initialPage == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final searcher = _searcher;
    final matches = searcher?.matches.length ?? 0;
    final ws = ref.watch(currentWorkspaceProvider).value;
    _annotations =
        ref.watch(pdfAnnotationsProvider(widget.file.path)).value ??
        PdfAnnotations.empty;
    String colorLabel(HighlightColor c) => switch (c) {
      HighlightColor.yellow => l.colorYellow,
      HighlightColor.green => l.colorGreen,
      HighlightColor.blue => l.colorBlue,
      HighlightColor.pink => l.colorPink,
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              if (_outline.isNotEmpty)
                IconButton(
                  tooltip: l.tableOfContents,
                  icon: const Icon(Icons.toc),
                  onPressed: () => _showOutline(context),
                ),
              TextButton(
                onPressed: _pageCount == 0 ? null : _jump,
                child: Text('$_page / $_pageCount'),
              ),
              const Spacer(),
              if (!_searching && ws != null) ...[
                PopupMenuButton<HighlightColor>(
                  key: const Key('pdfHighlight'),
                  enabled: _ranges.isNotEmpty && !_busy,
                  tooltip: l.pdfHighlight,
                  icon: Icon(
                    Icons.format_color_text,
                    color: _ranges.isEmpty
                        ? Theme.of(context).disabledColor
                        : null,
                  ),
                  onSelected: _highlight,
                  itemBuilder: (ctx) => [
                    for (final c in HighlightColor.values)
                      PopupMenuItem(
                        value: c,
                        child: Row(
                          children: [
                            Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: pdfMarkerColors[c],
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(colorLabel(c)),
                          ],
                        ),
                      ),
                  ],
                ),
                if (_annotations.highlights.isNotEmpty)
                  IconButton(
                    tooltip: l.pdfHighlights,
                    icon: const Icon(Icons.bookmarks_outlined),
                    onPressed: _showHighlights,
                  ),
              ],
              if (_searching && searcher != null) ...[
                SizedBox(
                  width: 200,
                  child: TextField(
                    key: const Key('pdfSearch'),
                    controller: _searchText,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: l.find,
                      isDense: true,
                    ),
                    onChanged: (v) => v.isEmpty
                        ? searcher.resetTextSearch()
                        : searcher.startTextSearch(v, caseInsensitive: true),
                  ),
                ),
                Text(
                  matches == 0
                      ? '0'
                      : '${(searcher.currentIndex ?? 0) + 1}/$matches',
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: matches == 0 ? null : searcher.goToPrevMatch,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: matches == 0 ? null : searcher.goToNextMatch,
                ),
              ],
              IconButton(
                tooltip: l.find,
                icon: Icon(_searching ? Icons.search_off : Icons.search),
                onPressed: searcher == null
                    ? null
                    : () => setState(() {
                        _searching = !_searching;
                        if (!_searching) {
                          _searchText.clear();
                          searcher.resetTextSearch();
                        }
                      }),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          // The Stack carries the annotation overlay (docs/05 §1).
          child: Stack(
            children: [
              PdfViewer.data(
                widget.file.bytes,
                sourceName: 'blob:${widget.file.blobSha ?? widget.file.path}',
                controller: _controller,
                initialPageNumber: _initialPage!,
                params: PdfViewerParams(
                  pagePaintCallbacks: [
                    if (searcher != null) searcher.pageTextMatchPaintCallback,
                    _paintHighlights,
                  ],
                  onViewerReady: (document, controller) async {
                    final outline = await document.loadOutline();
                    if (!mounted) return;
                    setState(() {
                      _pageCount = document.pages.length;
                      _outline = outline;
                      _searcher ??= PdfTextSearcher(controller)
                        ..addListener(_onSearch);
                    });
                  },
                  onPageChanged: (n) {
                    if (n == null) return;
                    setState(() => _page = n);
                    ref.read(pdfPageProvider.notifier).set(widget.file.path, n);
                    ref.read(databaseProvider).setValue(_positionKey, n);
                  },
                  textSelectionParams: PdfTextSelectionParams(
                    onTextSelectionChange: (selection) async {
                      final text = await selection.getSelectedText();
                      final ranges = await selection.getSelectedTextRanges();
                      if (!mounted) return;
                      setState(() => _ranges = ranges);
                      ref
                          .read(selectionProvider.notifier)
                          .set(
                            text.isEmpty
                                ? null
                                : ViewerSelection(
                                    path: widget.file.path,
                                    text: text,
                                    page: _page,
                                  ),
                          );
                    },
                  ),
                  buildContextMenu: (menuContext, menuParams) {
                    final delegate = menuParams.textSelectionDelegate;
                    if (!delegate.hasSelectedText) return null;
                    return Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: PdfSelectionMenu(
                            copyLabel: l.copy,
                            markerLabel: l.pdfHighlight,
                            askAiLabel: l.askAi,
                            onCopy: () {
                              delegate.copyTextSelection();
                              menuParams.dismissContextMenu();
                              showSnack(context, l.copied);
                            },
                            onAskAi: () {
                              menuParams.dismissContextMenu();
                              _askAi();
                            },
                            onHighlight: (c) {
                              menuParams.dismissContextMenu();
                              _highlight(c, delegate: delegate);
                            },
                          ),
                        ),
                      ),
                    );
                  },
                  errorBannerBuilder: (context, error, stack, documentRef) =>
                      FailureView(error: error),
                ),
              ),
            ],
          ),
        ),
        if (ws != null) _noteBar(context),
      ],
    );
  }

  /// Bar for writing a note into the PDF's Markdown notes file (FR-96).
  Widget _noteBar(BuildContext context) {
    final l = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: l.pdfNotes,
                icon: const Icon(Icons.sticky_note_2_outlined),
                onPressed: _openNotes,
              ),
              Expanded(
                child: TextField(
                  key: const Key('pdfNote'),
                  controller: _note,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _saveNote(),
                  decoration: InputDecoration(
                    hintText: l.pdfNoteHint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                key: const Key('pdfNoteSend'),
                tooltip: l.pdfNoteAdd,
                icon: const Icon(Icons.add_comment_outlined),
                onPressed: _busy ? null : _saveNote,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showOutline(BuildContext context) {
    List<Widget> build(List<PdfOutlineNode> nodes, int depth) => [
      for (final n in nodes) ...[
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 16.0 + depth * 16, right: 16),
          title: Text(n.title),
          trailing: n.dest == null ? null : Text('${n.dest!.pageNumber}'),
          onTap: n.dest == null
              ? null
              : () {
                  Navigator.pop(context);
                  _controller.goToPage(pageNumber: n.dest!.pageNumber);
                },
        ),
        ...build(n.children, depth + 1),
      ],
    ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.7,
        child: ListView(children: build(_outline, 0)),
      ),
    );
  }
}
