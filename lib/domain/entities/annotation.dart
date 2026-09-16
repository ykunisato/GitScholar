import 'dart:convert';

/// Marker colour of a PDF highlight (FR-90).
enum HighlightColor {
  yellow,
  green,
  blue,
  pink;

  /// Parses a stored colour name, falling back to [yellow].
  static HighlightColor parse(String? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => yellow);
}

/// A rectangle in PDF page coordinates: the origin is the bottom-left corner
/// and the y axis points up, so [top] is greater than [bottom].
class HighlightRect {
  const HighlightRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// Parses `[left, top, right, bottom]`.
  factory HighlightRect.fromJson(List<dynamic> j) => HighlightRect(
    left: (j[0] as num).toDouble(),
    top: (j[1] as num).toDouble(),
    right: (j[2] as num).toDouble(),
    bottom: (j[3] as num).toDouble(),
  );

  final double left;
  final double top;
  final double right;
  final double bottom;

  /// `[left, top, right, bottom]`, rounded to keep the JSON diff small.
  List<double> toJson() => [
    _round(left),
    _round(top),
    _round(right),
    _round(bottom),
  ];

  static double _round(double v) => (v * 100).roundToDouble() / 100;

  @override
  bool operator ==(Object other) =>
      other is HighlightRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// One highlighted run of text on a single page.
class PdfHighlight {
  const PdfHighlight({
    required this.id,
    required this.page,
    required this.rects,
    required this.color,
    required this.text,
    required this.createdAt,
  });

  /// Parses one entry of the sidecar file.
  factory PdfHighlight.fromJson(Map<String, dynamic> j) => PdfHighlight(
    id: '${j['id']}',
    page: (j['page'] as num?)?.toInt() ?? 1,
    rects: [
      for (final r in (j['rects'] ?? const <Object?>[]) as List)
        HighlightRect.fromJson(r as List),
    ],
    color: HighlightColor.parse(j['color'] as String?),
    text: (j['text'] ?? '') as String,
    createdAt:
        DateTime.tryParse('${j['createdAt']}')?.toUtc() ?? DateTime.utc(1970),
  );

  final String id;

  /// 1-based page number.
  final int page;

  /// One rectangle per line of the highlighted text.
  final List<HighlightRect> rects;

  final HighlightColor color;

  /// The highlighted text, kept so the list stays readable without the PDF.
  final String text;

  final DateTime createdAt;

  /// JSON form used in the sidecar file.
  Map<String, dynamic> toJson() => {
    'id': id,
    'page': page,
    'color': color.name,
    'text': text,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'rects': [for (final r in rects) r.toJson()],
  };
}

/// Contents of a `<pdf>.annotations.json` sidecar file (ADR-0008).
class PdfAnnotations {
  const PdfAnnotations(this.highlights);

  /// Parses a sidecar file, tolerating a missing or malformed file.
  factory PdfAnnotations.parse(String? source) {
    if (source == null || source.trim().isEmpty) return empty;
    try {
      final j = jsonDecode(source);
      if (j is! Map<String, dynamic>) return empty;
      return PdfAnnotations([
        for (final h in (j['highlights'] ?? const <Object?>[]) as List)
          PdfHighlight.fromJson(h as Map<String, dynamic>),
      ]);
    } on FormatException {
      return empty;
    } on TypeError {
      return empty;
    }
  }

  /// No annotations.
  static const empty = PdfAnnotations(<PdfHighlight>[]);

  /// Schema version written to the file.
  static const version = 1;

  final List<PdfHighlight> highlights;

  /// Highlights on [page] (1-based).
  List<PdfHighlight> forPage(int page) => [
    for (final h in highlights)
      if (h.page == page) h,
  ];

  /// Returns a copy with [h] added.
  PdfAnnotations add(PdfHighlight h) => PdfAnnotations([...highlights, h]);

  /// Returns a copy without the highlight with [id].
  PdfAnnotations removeId(String id) => PdfAnnotations([
    for (final h in highlights)
      if (h.id != id) h,
  ]);

  /// Pretty JSON ordered by page, with a trailing newline so Git diffs stay
  /// line-based.
  String encode() {
    final sorted = [...highlights]
      ..sort(
        (a, b) => a.page == b.page
            ? a.createdAt.compareTo(b.createdAt)
            : a.page.compareTo(b.page),
      );
    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert({
      'version': version,
      'highlights': [for (final h in sorted) h.toJson()],
    })}\n';
  }
}
