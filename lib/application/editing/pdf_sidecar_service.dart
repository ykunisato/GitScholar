import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../domain/entities/entities.dart';
import '../../domain/services/path_utils.dart';
import '../workspace/workspace_service.dart';
import 'editing_service.dart';

/// Companion files kept next to a PDF: the annotation sidecar
/// `<name>.annotations.json` (FR-90, ADR-0008) and the notes file
/// `<name>.md` (FR-96, ADR-0011).
///
/// Both are ordinary repository files, so they go through the normal pending
/// change and commit flow.
class PdfSidecarService {
  /// Creates a service.
  PdfSidecarService({
    required this.editing,
    required this.workspaces,
    DateTime Function()? clock,
    String Function()? newId,
  }) : _clock = clock ?? DateTime.now,
       _newId = newId ?? const Uuid().v4;

  final EditingService editing;
  final WorkspaceService workspaces;
  final DateTime Function() _clock;
  final String Function() _newId;

  /// `papers/foo.pdf` becomes `papers/foo.annotations.json`.
  static String annotationsPathFor(String pdfPath) =>
      '${_stem(pdfPath)}.annotations.json';

  /// `papers/foo.pdf` becomes `papers/foo.md`.
  static String notesPathFor(String pdfPath) => '${_stem(pdfPath)}.md';

  static String _stem(String pdfPath) {
    final p = normalizePath(pdfPath);
    final dot = p.lastIndexOf('.');
    return dot > p.lastIndexOf('/') ? p.substring(0, dot) : p;
  }

  /// Reads the sidecar file; missing or malformed files read as empty.
  Future<PdfAnnotations> load(Workspace ws, String pdfPath) async =>
      PdfAnnotations.parse(
        await workspaces.tryReadText(ws, annotationsPathFor(pdfPath)),
      );

  /// Adds one highlight per page in [rectsByPage] and saves the sidecar.
  Future<PdfAnnotations> addHighlights(
    Workspace ws,
    String pdfPath, {
    required Map<int, List<HighlightRect>> rectsByPage,
    required HighlightColor color,
    required String text,
  }) async {
    var annotations = await load(ws, pdfPath);
    final now = _clock().toUtc();
    for (final entry in rectsByPage.entries) {
      if (entry.value.isEmpty) continue;
      annotations = annotations.add(
        PdfHighlight(
          id: _newId(),
          page: entry.key,
          rects: entry.value,
          color: color,
          text: text,
          createdAt: now,
        ),
      );
    }
    await _save(ws, pdfPath, annotations);
    return annotations;
  }

  /// Removes the highlight with [id] and saves the sidecar.
  Future<PdfAnnotations> removeHighlight(
    Workspace ws,
    String pdfPath,
    String id,
  ) async {
    final annotations = (await load(ws, pdfPath)).removeId(id);
    await _save(ws, pdfPath, annotations);
    return annotations;
  }

  /// Writes the sidecar, deleting it when the last highlight is gone.
  Future<void> _save(
    Workspace ws,
    String pdfPath,
    PdfAnnotations annotations,
  ) async {
    final path = annotationsPathFor(pdfPath);
    if (annotations.highlights.isEmpty) {
      if (await editing.exists(ws, path)) await editing.deleteFile(ws, path);
      return;
    }
    await editing.saveText(ws, path, annotations.encode());
  }

  /// Appends a note to the PDF's Markdown notes file, creating the file when
  /// it does not exist yet. Returns the notes path.
  Future<String> appendNote(
    Workspace ws,
    String pdfPath, {
    required String text,
    int? page,
    String? quote,
  }) async {
    final path = notesPathFor(pdfPath);
    final block = noteBlock(text: text, page: page, quote: quote);
    if (await editing.exists(ws, path)) {
      final current = (await workspaces.loadFile(ws, path)).text ?? '';
      await editing.saveText(ws, path, '$current${_gap(current)}$block');
    } else {
      await editing.createFile(
        ws,
        path,
        Uint8List.fromList(utf8.encode('${_header(pdfPath)}$block')),
      );
    }
    return path;
  }

  /// Blank line between the existing content and the new note.
  static String _gap(String current) {
    if (current.isEmpty || current.endsWith('\n\n')) return '';
    return current.endsWith('\n') ? '\n' : '\n\n';
  }

  static String _header(String pdfPath) {
    final name = normalizePath(pdfPath).split('/').last;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    return '# $title\n\n[$name](<$name>)\n\n';
  }

  /// One note as a Markdown list item: the page, the note text and, when the
  /// note was taken with a selection, the quoted passage.
  static String noteBlock({required String text, int? page, String? quote}) {
    final lines = _lines(text);
    final b = StringBuffer()
      ..writeln('- ${page == null ? '' : '**p.$page** '}${lines.first}');
    for (final line in lines.skip(1)) {
      b.writeln(line.isEmpty ? '' : '  $line');
    }
    if (quote != null && quote.trim().isNotEmpty) {
      for (final line in _lines(quote)) {
        b.writeln('  > $line');
      }
    }
    b.writeln();
    return b.toString();
  }

  static List<String> _lines(String s) => [
    for (final line in s.trim().split('\n')) line.trimRight(),
  ];
}
