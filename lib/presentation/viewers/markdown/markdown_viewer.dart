import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../../domain/entities/entities.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../code/code_viewer.dart';
import 'markdown_body.dart';

enum MarkdownMode { edit, preview, split }

/// Markdown / Quarto viewer with edit, preview and split modes (FR-31, FR-36).
class MarkdownViewer extends ConsumerStatefulWidget {
  const MarkdownViewer({super.key, required this.file, required this.editing});

  final FileContent file;
  final bool editing;

  @override
  ConsumerState<MarkdownViewer> createState() => _MarkdownViewerState();
}

class _MarkdownViewerState extends ConsumerState<MarkdownViewer> {
  MarkdownMode? _mode;
  final _toc = TocController();

  @override
  void dispose() {
    _toc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.wide;
    final mode = !widget.editing
        ? MarkdownMode.preview
        : (_mode ?? (wide ? MarkdownMode.split : MarkdownMode.edit));
    final editor = CodeViewer(
      key: const ValueKey('md-editor'),
      file: widget.file,
      editing: true,
    );
    final preview = _Preview(file: widget.file, toc: _toc);
    return Column(
      children: [
        if (widget.editing)
          Padding(
            padding: const EdgeInsets.all(6),
            child: SegmentedButton<MarkdownMode>(
              segments: [
                ButtonSegment(
                  value: MarkdownMode.edit,
                  label: Text(l.modeEdit),
                  icon: const Icon(Icons.edit_note),
                ),
                ButtonSegment(
                  value: MarkdownMode.preview,
                  label: Text(l.modePreview),
                  icon: const Icon(Icons.visibility),
                ),
                if (wide)
                  ButtonSegment(
                    value: MarkdownMode.split,
                    label: Text(l.modeSplit),
                    icon: const Icon(Icons.vertical_split),
                  ),
              ],
              selected: {mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
        Expanded(
          child: switch (mode) {
            MarkdownMode.edit => editor,
            MarkdownMode.preview => preview,
            MarkdownMode.split => Row(
              children: [
                Expanded(child: editor),
                const VerticalDivider(width: 1),
                Expanded(child: preview),
              ],
            ),
          },
        ),
      ],
    );
  }
}

class _Preview extends ConsumerWidget {
  const _Preview({required this.file, required this.toc});

  final FileContent file;
  final TocController toc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final (frontMatter, body) = splitFrontMatter(file.text ?? '');
    void open(String p) => openPath(context, ref, p);
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (frontMatter != null)
              ExpansionTile(
                dense: true,
                title: Text(l.frontMatter),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      frontMatter,
                      style: monoStyle(context, size: 12),
                    ),
                  ),
                ],
              ),
            Expanded(
              child: MarkdownWidget(
                data: body,
                tocController: toc,
                padding: const EdgeInsets.all(16),
                config: buildMarkdownConfig(
                  context,
                  basePath: file.path,
                  onOpenPath: open,
                  imageBuilder: (url) =>
                      RepositoryImage(url: url, basePath: file.path),
                ),
                markdownGenerator: buildMarkdownGenerator(context),
              ),
            ),
          ],
        ),
        Positioned(
          right: 8,
          top: 8,
          child: IconButton.filledTonal(
            tooltip: l.tableOfContents,
            icon: const Icon(Icons.toc),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (ctx) => SizedBox(
                height: MediaQuery.sizeOf(ctx).height * 0.6,
                child: TocWidget(controller: toc),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
