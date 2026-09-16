import 'dart:convert';
import 'dart:typed_data';

import '../entities/file.dart';

/// Detects [FileKind] from a path (docs/03_data_model.md §1.2).
abstract final class FileKindDetector {
  static const _code = {
    'py',
    'r',
    'jl',
    'stan',
    'sh',
    'js',
    'ts',
    'dart',
    'c',
    'cpp',
    'h',
    'java',
    'sql',
    'yaml',
    'yml',
    'json',
    'toml',
    'bib',
    'tex',
    'csv',
    'tsv',
  };
  static const _markdown = {'md', 'markdown', 'qmd', 'rmd'};
  static const _image = {'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'bmp'};
  static const _text = {'txt', 'log', 'cfg', 'ini'};

  /// Lower-cased extension without the dot, or '' when none.
  static String extension(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// Kind from the path alone.
  static FileKind fromPath(String path) {
    final name = path.split('/').last.toLowerCase();
    if (name.endsWith('.env.example')) return FileKind.text;
    final ext = extension(path);
    if (ext == 'pdf') return FileKind.pdf;
    if (ext == 'ipynb') return FileKind.notebook;
    if (_markdown.contains(ext)) return FileKind.markdown;
    if (_code.contains(ext)) return FileKind.code;
    if (_image.contains(ext)) return FileKind.image;
    if (_text.contains(ext) || ext.isEmpty) return FileKind.text;
    return FileKind.unknown;
  }

  /// Kind from path and content: unknown/text files that are not UTF-8
  /// become [FileKind.binary]; unknown UTF-8 files become text.
  static FileKind fromContent(String path, Uint8List bytes) {
    final kind = fromPath(path);
    if (kind != FileKind.text && kind != FileKind.unknown) return kind;
    return looksBinary(bytes) ? FileKind.binary : FileKind.text;
  }

  /// Heuristic: NUL byte in the first 8KB or invalid UTF-8.
  static bool looksBinary(Uint8List bytes) {
    final n = bytes.length < 8000 ? bytes.length : 8000;
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    try {
      const Utf8Decoder().convert(bytes.sublist(0, n));
      return false;
    } on FormatException catch (e) {
      // A multi-byte sequence cut at the 8KB boundary is still text.
      return !(n < bytes.length && (e.offset ?? 0) >= n - 4);
    }
  }

  /// Whether the kind is editable as text.
  static bool isTextEditable(FileKind kind) =>
      kind == FileKind.code ||
      kind == FileKind.markdown ||
      kind == FileKind.text;

  /// Maximum size shown in a viewer (docs/05_viewers.md).
  static int maxViewerBytes(FileKind kind) => switch (kind) {
    FileKind.pdf => 100 * 1024 * 1024,
    FileKind.notebook => 50 * 1024 * 1024,
    FileKind.image => 20 * 1024 * 1024,
    _ => 5 * 1024 * 1024,
  };
}
