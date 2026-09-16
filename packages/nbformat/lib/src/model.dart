import 'dart:math';

/// Thrown when a notebook cannot be parsed.
class NbformatException implements Exception {
  /// Creates the exception.
  const NbformatException(this.message);

  /// Human readable reason.
  final String message;

  @override
  String toString() => 'NbformatException: $message';
}

/// A Jupyter notebook.
class Notebook {
  /// Creates a notebook.
  Notebook({
    this.nbformat = 4,
    this.nbformatMinor = 5,
    Map<String, dynamic>? metadata,
    List<Cell>? cells,
    Map<String, dynamic>? extra,
  }) : metadata = metadata ?? <String, dynamic>{},
       cells = cells ?? <Cell>[],
       extra = extra ?? <String, dynamic>{};

  /// Major format version (always 4).
  int nbformat;

  /// Minor format version.
  int nbformatMinor;

  /// Notebook-level metadata.
  Map<String, dynamic> metadata;

  /// Cells in order.
  List<Cell> cells;

  /// Unknown top-level fields preserved for round-tripping.
  Map<String, dynamic> extra;

  /// Whether cells should carry an `id` (nbformat >= 4.5).
  bool get requiresCellIds => nbformat > 4 || nbformatMinor >= 5;

  /// Kernel language, from `metadata.kernelspec.language` or
  /// `metadata.language_info.name`.
  String? get language {
    final ks = metadata['kernelspec'];
    if (ks is Map && ks['language'] is String) return ks['language'] as String;
    final li = metadata['language_info'];
    if (li is Map && li['name'] is String) return li['name'] as String;
    return null;
  }

  /// Creates a new random cell id (8 alphanumeric characters).
  static String newCellId([Random? random]) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = random ?? Random();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Deep copy.
  Notebook copy() => Notebook(
    nbformat: nbformat,
    nbformatMinor: nbformatMinor,
    metadata: _deepCopyMap(metadata),
    cells: [for (final c in cells) c.copy()],
    extra: _deepCopyMap(extra),
  );
}

/// Cell type discriminator.
enum CellType {
  /// Markdown cell.
  markdown,

  /// Code cell.
  code,

  /// Raw cell.
  raw,
}

/// Base class for cells.
sealed class Cell {
  Cell({
    this.id,
    Map<String, dynamic>? metadata,
    this.source = '',
    Map<String, dynamic>? extra,
  }) : metadata = metadata ?? <String, dynamic>{},
       extra = extra ?? <String, dynamic>{};

  /// Cell id (nbformat 4.5+), or null.
  String? id;

  /// Cell metadata.
  Map<String, dynamic> metadata;

  /// Joined source text.
  String source;

  /// Unknown fields preserved for round-tripping (e.g. `attachments`).
  Map<String, dynamic> extra;

  /// The cell type.
  CellType get type;

  /// Tags from `metadata.tags`.
  List<String> get tags {
    final t = metadata['tags'];
    return t is List ? [for (final x in t) '$x'] : const [];
  }

  /// Whether the source should be hidden.
  bool get sourceHidden {
    final j = metadata['jupyter'];
    return j is Map && j['source_hidden'] == true;
  }

  /// Whether outputs should be hidden.
  bool get outputsHidden {
    final j = metadata['jupyter'];
    return metadata['collapsed'] == true ||
        (j is Map && j['outputs_hidden'] == true);
  }

  /// Deep copy.
  Cell copy();
}

/// A markdown cell.
class MarkdownCell extends Cell {
  /// Creates a markdown cell.
  MarkdownCell({super.id, super.metadata, super.source, super.extra});

  @override
  CellType get type => CellType.markdown;

  @override
  MarkdownCell copy() => MarkdownCell(
    id: id,
    metadata: _deepCopyMap(metadata),
    source: source,
    extra: _deepCopyMap(extra),
  );
}

/// A raw cell.
class RawCell extends Cell {
  /// Creates a raw cell.
  RawCell({super.id, super.metadata, super.source, super.extra});

  @override
  CellType get type => CellType.raw;

  @override
  RawCell copy() => RawCell(
    id: id,
    metadata: _deepCopyMap(metadata),
    source: source,
    extra: _deepCopyMap(extra),
  );
}

/// A code cell.
class CodeCell extends Cell {
  /// Creates a code cell.
  CodeCell({
    super.id,
    super.metadata,
    super.source,
    super.extra,
    this.executionCount,
    List<Output>? outputs,
  }) : outputs = outputs ?? <Output>[];

  /// Execution count, or null if not executed.
  int? executionCount;

  /// Outputs.
  List<Output> outputs;

  @override
  CellType get type => CellType.code;

  @override
  CodeCell copy() => CodeCell(
    id: id,
    metadata: _deepCopyMap(metadata),
    source: source,
    extra: _deepCopyMap(extra),
    executionCount: executionCount,
    outputs: [for (final o in outputs) o.copy()],
  );
}

/// Base class for code cell outputs.
sealed class Output {
  Output({Map<String, dynamic>? extra}) : extra = extra ?? <String, dynamic>{};

  /// Unknown fields preserved for round-tripping.
  Map<String, dynamic> extra;

  /// Deep copy.
  Output copy();
}

/// `stream` output.
class StreamOutput extends Output {
  /// Creates a stream output.
  StreamOutput({required this.name, required this.text, super.extra});

  /// `stdout` or `stderr`.
  String name;

  /// Joined text.
  String text;

  /// Whether this is stderr.
  bool get isStderr => name == 'stderr';

  @override
  StreamOutput copy() =>
      StreamOutput(name: name, text: text, extra: _deepCopyMap(extra));
}

/// `display_data` output.
class DisplayDataOutput extends Output {
  /// Creates a display data output.
  DisplayDataOutput({
    required this.data,
    Map<String, dynamic>? metadata,
    super.extra,
  }) : metadata = metadata ?? <String, dynamic>{};

  /// MIME bundle.
  MimeBundle data;

  /// Output metadata.
  Map<String, dynamic> metadata;

  @override
  DisplayDataOutput copy() => DisplayDataOutput(
    data: data.copy(),
    metadata: _deepCopyMap(metadata),
    extra: _deepCopyMap(extra),
  );
}

/// `execute_result` output.
class ExecuteResultOutput extends DisplayDataOutput {
  /// Creates an execute result output.
  ExecuteResultOutput({
    required super.data,
    super.metadata,
    this.executionCount,
    super.extra,
  });

  /// Execution count.
  int? executionCount;

  @override
  ExecuteResultOutput copy() => ExecuteResultOutput(
    data: data.copy(),
    metadata: _deepCopyMap(metadata),
    executionCount: executionCount,
    extra: _deepCopyMap(extra),
  );
}

/// `error` output.
class ErrorOutput extends Output {
  /// Creates an error output.
  ErrorOutput({
    required this.ename,
    required this.evalue,
    List<String>? traceback,
    super.extra,
  }) : traceback = traceback ?? <String>[];

  /// Exception name.
  String ename;

  /// Exception value.
  String evalue;

  /// Traceback lines (may contain ANSI escapes).
  List<String> traceback;

  @override
  ErrorOutput copy() => ErrorOutput(
    ename: ename,
    evalue: evalue,
    traceback: List.of(traceback),
    extra: _deepCopyMap(extra),
  );
}

/// A MIME type to content map. JSON MIME values are stored JSON-encoded.
class MimeBundle {
  /// Creates a bundle.
  MimeBundle([Map<String, String>? entries])
    : entries = entries ?? <String, String>{};

  /// MIME type to joined string (base64 for binary images).
  Map<String, String> entries;

  /// Default display priority (docs/05_viewers.md §3.1).
  static const defaultPriority = [
    'image/png',
    'image/jpeg',
    'image/svg+xml',
    'text/html',
    'text/markdown',
    'text/latex',
    'application/json',
    'text/plain',
  ];

  /// First MIME type in [priority] present in this bundle.
  String? preferred([List<String> priority = defaultPriority]) {
    for (final p in priority) {
      if (entries.containsKey(p)) return p;
    }
    return entries.isEmpty ? null : entries.keys.first;
  }

  /// Whether [mime] is a JSON MIME type.
  static bool isJsonMime(String mime) =>
      mime == 'application/json' ||
      (mime.startsWith('application/') && mime.endsWith('+json'));

  /// Deep copy.
  MimeBundle copy() => MimeBundle(Map.of(entries));
}

Map<String, dynamic> _deepCopyMap(Map<String, dynamic> m) => {
  for (final e in m.entries) e.key: _deepCopy(e.value),
};

Object? _deepCopy(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) '${e.key}': _deepCopy(e.value),
    };
  }
  if (v is List) return [for (final x in v) _deepCopy(x)];
  return v;
}
