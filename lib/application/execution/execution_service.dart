import 'dart:async';
import 'dart:convert';

import 'package:nbformat/nbformat.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/repositories/execution_backend.dart';
import '../../infrastructure/local/app_database.dart';
import '../editing/editing_service.dart';
import '../workspace/workspace_service.dart';

/// Collected result of a code run.
class ExecResult {
  ExecResult({
    required this.outputs,
    required this.elapsed,
    this.timedOut = false,
  });

  final List<ExecOutput> outputs;
  final Duration elapsed;
  final bool timedOut;

  bool get hasError => timedOut || outputs.any((o) => o is ExecError);

  /// Plain-text summary for logs and the AI.
  String toText() {
    final b = StringBuffer();
    var images = 0;
    for (final o in outputs) {
      switch (o) {
        case ExecStream(:final name, :final text):
          b.write(name == 'stderr' ? '[stderr] $text' : text);
        case ExecDisplay(:final data):
          final keys = data.keys.where((k) => k.startsWith('image/'));
          if (keys.isNotEmpty) images++;
          if (data['text/plain'] != null) {
            b.writeln(joinMultiline(data['text/plain']));
          }
        case ExecError(:final ename, :final evalue, :final traceback):
          b.writeln(stripAnsi('$ename: $evalue\n${traceback.join('\n')}'));
        case ExecInput():
          break;
      }
    }
    if (images > 0) b.writeln('[image output: $images]');
    if (timedOut) b.writeln('[timed out after ${elapsed.inSeconds}s]');
    b.write('[elapsed ${elapsed.inMilliseconds} ms]');
    return b.toString();
  }
}

/// One entry of the execution log (FR-74).
class ExecLogEntry {
  const ExecLogEntry({
    required this.label,
    required this.result,
    required this.at,
  });
  final String label;
  final ExecResult result;
  final DateTime at;
}

/// Runs code and notebooks on the remote backend (docs/11 T-052..T-055).
class ExecutionService {
  ExecutionService({
    required this.backend,
    required this.db,
    required this.workspaces,
    required this.editing,
    this.kernelName = 'python3',
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ExecutionBackend backend;
  final AppDatabase db;
  final WorkspaceService workspaces;
  final EditingService editing;
  final String kernelName;
  final DateTime Function() _clock;

  final _kernels = <String, String>{}; // kernel name -> id
  final log = <ExecLogEntry>[];

  /// Maximum size of a file synced to the server.
  static const maxSyncBytes = 20 * 1024 * 1024;

  /// Remote directory for a repository.
  static String remoteRoot(RepositoryRef repo) =>
      'gitscholar/${repo.owner}__${repo.name}';

  Future<String> _kernel(String name) async =>
      _kernels[name] ??= await backend.startKernel(name);

  String _kernelFor(String language) {
    if (language.toLowerCase() == 'r') return 'ir';
    return kernelName;
  }

  /// Uploads files in the directory of [path] (and [path] itself) that
  /// changed since the last sync, including pending content (FR-72).
  Future<int> syncForPath(Workspace ws, String path) async {
    final dir = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    final changes = await db.pendingChangesFor(ws.repo.fullName, ws.branch);
    final candidates = <String>{
      for (final e in ws.blobs)
        if (_parent(e.path) == dir && (e.size ?? 0) <= maxSyncBytes) e.path,
      for (final c in changes)
        if (c.isPending &&
            c.kind != ChangeKind.delete &&
            _parent(c.path) == dir)
          c.path,
      path,
    };
    var uploaded = 0;
    for (final p in candidates) {
      final FileContent f;
      try {
        f = await workspaces.loadFile(ws, p);
      } on NotFoundFailure {
        continue;
      }
      final key = 'jupyter_sync:${backendKey()}:${ws.repo.fullName}:$p';
      if (await db.getValue(key) == f.blobSha) continue;
      await backend.uploadFile('${remoteRoot(ws.repo)}/$p', f.bytes);
      await db.setValue(key, f.blobSha);
      uploaded++;
    }
    return uploaded;
  }

  /// Identifies the backend for sync bookkeeping.
  String backendKey() => backend.runtimeType.toString();

  static String _parent(String p) =>
      p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '';

  String _chdirCode(String language, String relDir) {
    final escaped = relDir.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    if (language.toLowerCase() == 'r') {
      return "if (!exists('.gitscholar_root')) .gitscholar_root <- getwd(); "
          "setwd(file.path(.gitscholar_root, '$escaped'))";
    }
    return "import os as _gs_os\n"
        "globals().setdefault('_gitscholar_root', _gs_os.getcwd())\n"
        "_gs_os.chdir(_gs_os.path.join(_gitscholar_root, '$escaped'))";
  }

  /// Runs [code] and collects outputs, stopping at [timeout].
  Future<ExecResult> runCode(
    String code, {
    String language = 'python',
    Duration timeout = const Duration(seconds: 50),
    String? label,
  }) async {
    final kernel = await _kernel(_kernelFor(language));
    final outputs = <ExecOutput>[];
    final watch = Stopwatch()..start();
    var timedOut = false;
    try {
      await backend.execute(kernel, code).forEach(outputs.add).timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      await backend.interrupt(kernel);
    }
    final result = ExecResult(
      outputs: outputs,
      elapsed: watch.elapsed,
      timedOut: timedOut,
    );
    log.add(
      ExecLogEntry(
        label: label ?? code.split('\n').first,
        result: result,
        at: _clock(),
      ),
    );
    return result;
  }

  /// Executes [indices] of [nb] with the notebook directory as working
  /// directory, stores outputs and saves the notebook as a pending change.
  Future<Notebook> runNotebookCells(
    Workspace ws,
    String path,
    Notebook nb,
    List<int> indices, {
    void Function(int index, Notebook notebook)? onCellDone,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final language = nb.language ?? 'python';
    await syncForPath(ws, path);
    final dir = '${remoteRoot(ws.repo)}/${_parent(path)}';
    await runCode(
      _chdirCode(language, dir),
      language: language,
      label: 'chdir $dir',
    );
    final updated = nb.copy();
    for (final i in indices) {
      final cell = updated.cells[i];
      if (cell is! CodeCell) continue;
      final r = await runCode(
        cell.source,
        language: language,
        timeout: timeout,
        label: '$path [cell ${i + 1}]',
      );
      cell.outputs = toNotebookOutputs(r.outputs);
      final input = r.outputs.whereType<ExecInput>().firstOrNull;
      cell.executionCount = input?.executionCount ?? cell.executionCount;
      onCellDone?.call(i, updated);
      if (r.hasError) break;
    }
    await editing.saveText(ws, path, serializeNotebook(updated));
    return updated;
  }

  /// Converts backend outputs to nbformat outputs, merging adjacent streams.
  static List<Output> toNotebookOutputs(List<ExecOutput> outputs) {
    final out = <Output>[];
    for (final o in outputs) {
      switch (o) {
        case ExecStream(:final name, :final text):
          final last = out.isEmpty ? null : out.last;
          if (last is StreamOutput && last.name == name) {
            last.text += text;
          } else {
            out.add(StreamOutput(name: name, text: text));
          }
        case ExecDisplay(
          :final data,
          :final metadata,
          :final isResult,
          :final executionCount,
        ):
          final bundle = MimeBundle({
            for (final e in data.entries)
              e.key: e.value is String
                  ? e.value as String
                  : (MimeBundle.isJsonMime(e.key)
                        ? jsonEncode(e.value)
                        : joinMultiline(e.value)),
          });
          out.add(
            isResult
                ? ExecuteResultOutput(
                    data: bundle,
                    metadata: metadata,
                    executionCount: executionCount,
                  )
                : DisplayDataOutput(data: bundle, metadata: metadata),
          );
        case ExecError(:final ename, :final evalue, :final traceback):
          out.add(
            ErrorOutput(ename: ename, evalue: evalue, traceback: traceback),
          );
        case ExecInput():
          break;
      }
    }
    return out;
  }

  /// Renders a Quarto / R Markdown document via the Python kernel.
  Future<ExecResult> renderQuarto(
    Workspace ws,
    String path, {
    String format = 'html',
  }) async {
    await syncForPath(ws, path);
    final remote = '${remoteRoot(ws.repo)}/$path'.replaceAll("'", "\\'");
    final code = [
      'import subprocess, os',
      "_r = subprocess.run(['quarto', 'render', os.path.join(globals().get('_gitscholar_root', os.getcwd()), '$remote'), '--to', '$format'], capture_output=True, text=True)",
      'print(_r.stdout)',
      'print(_r.stderr)',
      "print('exit code', _r.returncode)",
    ].join('\n');
    return runCode(
      code,
      timeout: const Duration(minutes: 5),
      label: 'quarto render $path',
    );
  }

  /// Output file produced by [renderQuarto].
  static String renderedPath(String path, String format) {
    final dot = path.lastIndexOf('.');
    return '${dot < 0 ? path : path.substring(0, dot)}.$format';
  }

  Future<void> interruptAll() async {
    for (final id in _kernels.values) {
      await backend.interrupt(id);
    }
  }

  Future<void> restartAll() async {
    for (final id in _kernels.values) {
      await backend.restart(id);
    }
  }

  Future<void> shutdownAll() async {
    for (final id in _kernels.values) {
      try {
        await backend.shutdown(id);
      } on AppFailure {
        // Server may already be gone.
      }
    }
    _kernels.clear();
  }
}
