/// Files the app keeps beside a PDF: its highlights
/// `<name>.annotations.json` (FR-90, ADR-0008) and its notes `<name>.md`
/// (FR-96, ADR-0011).
///
/// They are named after the PDF, so moving or renaming the PDF without them
/// leaves the highlights and notes behind, pointing at a file that is no
/// longer there (FR-49).
library;

import 'path_utils.dart';

/// `papers/foo.pdf` becomes `papers/foo.annotations.json`.
String pdfAnnotationsPath(String pdfPath) =>
    '${_stem(pdfPath)}.annotations.json';

/// `papers/foo.pdf` becomes `papers/foo.md`.
String pdfNotesPath(String pdfPath) => '${_stem(pdfPath)}.md';

/// Paths that belong to [path] and should travel with it. Empty for
/// anything that is not a PDF.
List<String> companionPathsFor(String path) {
  final normalized = tryNormalizePath(path);
  if (normalized == null) return const [];
  if (!normalized.toLowerCase().endsWith('.pdf')) return const [];
  return [pdfAnnotationsPath(normalized), pdfNotesPath(normalized)];
}

String _stem(String pdfPath) {
  final p = normalizePath(pdfPath);
  final dot = p.lastIndexOf('.');
  return dot > p.lastIndexOf('/') ? p.substring(0, dot) : p;
}
