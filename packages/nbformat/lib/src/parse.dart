import 'dart:convert';

import 'model.dart';

/// Parses notebook JSON text.
///
/// Throws [NbformatException] for invalid JSON or nbformat < 4.
Notebook parseNotebook(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (e) {
    throw NbformatException('Invalid JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const NbformatException('Notebook root must be an object');
  }
  return notebookFromJson(decoded);
}

/// Builds a [Notebook] from decoded JSON.
Notebook notebookFromJson(Map<String, dynamic> json) {
  final major = json['nbformat'];
  if (major is! int) {
    throw const NbformatException('Missing nbformat');
  }
  if (major < 4) {
    throw NbformatException('Unsupported nbformat $major (requires 4)');
  }
  final minor = json['nbformat_minor'] is int
      ? json['nbformat_minor'] as int
      : 0;
  final cellsJson = json['cells'];
  if (cellsJson is! List) {
    throw const NbformatException('Missing cells');
  }
  final extra = <String, dynamic>{
    for (final e in json.entries)
      if (!const {
        'nbformat',
        'nbformat_minor',
        'metadata',
        'cells',
      }.contains(e.key))
        e.key: e.value,
  };
  return Notebook(
    nbformat: major,
    nbformatMinor: minor,
    metadata: _map(json['metadata']),
    cells: [for (final (i, c) in cellsJson.indexed) _cellFromJson(c, i)],
    extra: extra,
  );
}

Cell _cellFromJson(Object? json, int index) {
  if (json is! Map<String, dynamic>) {
    throw NbformatException('Cell $index must be an object');
  }
  final type = json['cell_type'];
  final id = json['id'] is String ? json['id'] as String : null;
  final metadata = _map(json['metadata']);
  final source = joinMultiline(json['source']);
  const common = {'cell_type', 'id', 'metadata', 'source'};
  switch (type) {
    case 'markdown':
      return MarkdownCell(
        id: id,
        metadata: metadata,
        source: source,
        extra: _extra(json, common),
      );
    case 'raw':
      return RawCell(
        id: id,
        metadata: metadata,
        source: source,
        extra: _extra(json, common),
      );
    case 'code':
      final outputs = json['outputs'];
      return CodeCell(
        id: id,
        metadata: metadata,
        source: source,
        executionCount: json['execution_count'] is int
            ? json['execution_count'] as int
            : null,
        outputs: outputs is List
            ? [for (final o in outputs) _outputFromJson(o)]
            : <Output>[],
        extra: _extra(json, {...common, 'outputs', 'execution_count'}),
      );
    default:
      throw NbformatException('Unknown cell_type "$type" at cell $index');
  }
}

Output _outputFromJson(Object? json) {
  if (json is! Map<String, dynamic>) {
    throw const NbformatException('Output must be an object');
  }
  switch (json['output_type']) {
    case 'stream':
      return StreamOutput(
        name: '${json['name'] ?? 'stdout'}',
        text: joinMultiline(json['text']),
        extra: _extra(json, {'output_type', 'name', 'text'}),
      );
    case 'display_data':
      return DisplayDataOutput(
        data: _bundle(json['data']),
        metadata: _map(json['metadata']),
        extra: _extra(json, {'output_type', 'data', 'metadata'}),
      );
    case 'execute_result':
      return ExecuteResultOutput(
        data: _bundle(json['data']),
        metadata: _map(json['metadata']),
        executionCount: json['execution_count'] is int
            ? json['execution_count'] as int
            : null,
        extra: _extra(json, {
          'output_type',
          'data',
          'metadata',
          'execution_count',
        }),
      );
    case 'error':
      final tb = json['traceback'];
      return ErrorOutput(
        ename: '${json['ename'] ?? ''}',
        evalue: '${json['evalue'] ?? ''}',
        traceback: tb is List ? [for (final l in tb) '$l'] : <String>[],
        extra: _extra(json, {'output_type', 'ename', 'evalue', 'traceback'}),
      );
    default:
      throw NbformatException('Unknown output_type "${json['output_type']}"');
  }
}

MimeBundle _bundle(Object? data) {
  if (data is! Map) return MimeBundle();
  return MimeBundle({
    for (final e in data.entries)
      '${e.key}': MimeBundle.isJsonMime('${e.key}')
          ? (e.value is String ? e.value as String : jsonEncode(e.value))
          : joinMultiline(e.value),
  });
}

/// Joins a `string | list of strings` multiline value.
String joinMultiline(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is List) return value.map((e) => '$e').join();
  return '$value';
}

/// Splits text into Jupyter's multiline list form: every element except the
/// last keeps its trailing `\n`.
List<String> splitMultiline(String text) {
  if (text.isEmpty) return const [];
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      out.add(text.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) out.add(text.substring(start));
  return out;
}

Map<String, dynamic> _map(Object? v) => v is Map
    ? <String, dynamic>{for (final e in v.entries) '${e.key}': e.value}
    : <String, dynamic>{};

Map<String, dynamic> _extra(Map<String, dynamic> json, Set<String> known) => {
  for (final e in json.entries)
    if (!known.contains(e.key)) e.key: e.value,
};

/// Converts [nb] to JSON-compatible maps.
Map<String, dynamic> notebookToJson(Notebook nb) {
  return {
    'cells': [for (final c in nb.cells) _cellToJson(c, nb)],
    'metadata': nb.metadata,
    'nbformat': nb.nbformat,
    'nbformat_minor': nb.nbformatMinor,
    ...nb.extra,
  };
}

Map<String, dynamic> _cellToJson(Cell c, Notebook nb) {
  if (nb.requiresCellIds && c.id == null) c.id = Notebook.newCellId();
  final base = <String, dynamic>{
    'cell_type': c.type.name,
    if (c.id != null) 'id': c.id,
    'metadata': c.metadata,
  };
  switch (c) {
    case CodeCell():
      base['execution_count'] = c.executionCount;
      base['outputs'] = [for (final o in c.outputs) _outputToJson(o)];
    case MarkdownCell():
    case RawCell():
      break;
  }
  base['source'] = splitMultiline(c.source);
  base.addAll(c.extra);
  return base;
}

Map<String, dynamic> _outputToJson(Output o) {
  switch (o) {
    case StreamOutput():
      return {
        'name': o.name,
        'output_type': 'stream',
        'text': splitMultiline(o.text),
        ...o.extra,
      };
    case ExecuteResultOutput():
      return {
        'data': _bundleToJson(o.data),
        'execution_count': o.executionCount,
        'metadata': o.metadata,
        'output_type': 'execute_result',
        ...o.extra,
      };
    case DisplayDataOutput():
      return {
        'data': _bundleToJson(o.data),
        'metadata': o.metadata,
        'output_type': 'display_data',
        ...o.extra,
      };
    case ErrorOutput():
      return {
        'ename': o.ename,
        'evalue': o.evalue,
        'output_type': 'error',
        'traceback': o.traceback,
        ...o.extra,
      };
  }
}

Map<String, dynamic> _bundleToJson(MimeBundle b) => {
  for (final e in b.entries.entries)
    e.key: MimeBundle.isJsonMime(e.key)
        ? _tryDecode(e.value)
        : (e.key.startsWith('image/') && e.key != 'image/svg+xml'
              ? e.value
              : splitMultiline(e.value)),
};

Object? _tryDecode(String s) {
  try {
    return jsonDecode(s);
  } on FormatException {
    return s;
  }
}

/// Serializes [nb] using Jupyter's formatting (1-space indent, trailing
/// newline).
String serializeNotebook(Notebook nb, {String indent = ' '}) =>
    '${JsonEncoder.withIndent(indent).convert(notebookToJson(nb))}\n';
