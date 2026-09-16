import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../domain/entities/entities.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

/// PDF viewer with page navigation, search, selection and outline (FR-30).
class PdfViewerView extends ConsumerStatefulWidget {
  const PdfViewerView({super.key, required this.file});

  final FileContent file;

  @override
  ConsumerState<PdfViewerView> createState() => _PdfViewerViewState();
}

class _PdfViewerViewState extends ConsumerState<PdfViewerView> {
  final _controller = PdfViewerController();
  final _searchText = TextEditingController();

  /// Created only after the document is loaded. PdfTextSearcher dereferences
  /// the controller's viewer state in its constructor, so building it earlier
  /// throws a null check error.
  PdfTextSearcher? _searcher;

  int? _initialPage;
  int _page = 1;
  int _pageCount = 0;
  List<PdfOutlineNode> _outline = const [];
  bool _searching = false;

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

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_initialPage == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final searcher = _searcher;
    final matches = searcher?.matches.length ?? 0;
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
          // Stack leaves room for the Phase 4 annotation overlay (docs/05 §1).
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
                      if (!mounted) return;
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
                  errorBannerBuilder: (context, error, stack, documentRef) =>
                      FailureView(error: error),
                ),
              ),
            ],
          ),
        ),
      ],
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
