import 'dart:convert';
import 'dart:typed_data';

/// File categories used to choose a viewer (docs/03_data_model.md §1.2).
enum FileKind { pdf, markdown, notebook, code, image, text, binary, unknown }

/// Where file content came from.
enum ContentSource { remote, cache, pending }

/// File content loaded through LoadFile.
class FileContent {
  FileContent({
    required this.path,
    required this.bytes,
    required this.kind,
    required this.source,
    this.blobSha,
  });

  final String path;
  final Uint8List bytes;
  final FileKind kind;
  final ContentSource source;

  /// Blob SHA of these bytes (null only when unknown).
  final String? blobSha;

  String? _text;
  bool _decoded = false;

  /// UTF-8 text, or null when the bytes are not valid UTF-8.
  String? get text {
    if (!_decoded) {
      _decoded = true;
      try {
        _text = utf8.decode(bytes);
      } on FormatException {
        _text = null;
      }
    }
    return _text;
  }

  int get size => bytes.length;
}

/// Current selection inside a viewer, used as AI context (FR-62).
class ViewerSelection {
  const ViewerSelection({
    required this.path,
    required this.text,
    this.startLine,
    this.endLine,
    this.page,
    this.cellIndex,
  });

  final String path;
  final String text;
  final int? startLine;
  final int? endLine;
  final int? page;
  final int? cellIndex;

  String get label {
    if (startLine != null) {
      return endLine != null && endLine != startLine
          ? 'L$startLine-$endLine'
          : 'L$startLine';
    }
    if (page != null) return 'p.$page';
    if (cellIndex != null) return 'cell ${cellIndex! + 1}';
    return '${text.length} chars';
  }
}
