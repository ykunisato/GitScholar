import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/entities.dart';
import '../../domain/services/file_kind_detector.dart';
import '../core/providers.dart';
import '../core/widgets.dart';
import 'code/code_viewer.dart';
import 'common/unsupported_file_view.dart';
import 'image/image_viewer.dart';
import 'markdown/markdown_viewer.dart';
import 'notebook/notebook_viewer.dart';
import 'pdf/pdf_viewer_view.dart';

/// Chooses a viewer by [FileKind] (docs/05_viewers.md).
class ViewerDispatcher extends ConsumerWidget {
  const ViewerDispatcher({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(fileContentProvider(path));
    final editing = ref.watch(
      shellProvider.select((s) => s.editing.contains(path)),
    );
    final entrySize = ref.watch(
      currentWorkspaceProvider.select((s) => s.value?.entry(path)?.size),
    );
    final kind = FileKindDetector.fromPath(path);
    if (entrySize != null &&
        entrySize > FileKindDetector.maxViewerBytes(kind)) {
      return UnsupportedFileView(path: path, size: entrySize, tooLarge: true);
    }
    // Keep showing the previous content while reloading so editors keep state.
    if (!async.hasValue) {
      if (async.hasError) {
        return FailureView(
          error: async.error!,
          onRetry: () => ref.invalidate(fileContentProvider(path)),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final file = async.value!;
    if (file.size > FileKindDetector.maxViewerBytes(file.kind)) {
      return UnsupportedFileView(path: path, size: file.size, tooLarge: true);
    }
    return switch (file.kind) {
      FileKind.pdf => PdfViewerView(key: ValueKey('pdf:$path'), file: file),
      FileKind.markdown => MarkdownViewer(
        key: ValueKey('md:$path'),
        file: file,
        editing: editing,
      ),
      FileKind.notebook => NotebookViewer(
        key: ValueKey('nb:$path'),
        file: file,
        editing: editing,
      ),
      FileKind.code || FileKind.text => CodeViewer(
        key: ValueKey('code:$path'),
        file: file,
        editing: editing,
      ),
      FileKind.image => ImageViewer(file: file),
      FileKind.binary ||
      FileKind.unknown => UnsupportedFileView(path: path, size: file.size),
    };
  }
}
