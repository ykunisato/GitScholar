import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:github_api/github_api.dart' show gitBlobSha;
import 'package:nbformat/nbformat.dart';
import 'package:scholar_agent/scholar_agent.dart';
import 'package:text_diff/text_diff.dart';
import 'package:uuid/uuid.dart';

import '../../application/editing/change_diff.dart';
import '../../application/editing/editing_service.dart';
import '../../application/execution/execution_service.dart';
import '../../application/workspace/workspace_service.dart';
import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/services/file_kind_detector.dart';
import '../../domain/services/ignore_rules.dart';
import '../../domain/services/path_utils.dart';
import '../../domain/services/tree_view.dart';
import '../local/app_database.dart';
import '../local/blob_store.dart';
import 'context_builder.dart';

/// Dependencies shared by tool handlers.
class ToolEnvironment {
  ToolEnvironment({
    required this.workspace,
    required this.workspaces,
    required this.editing,
    required this.db,
    required this.blobs,
    required this.rules,
    required this.conversationId,
    this.pdfText,
    this.execution,
    this.onProposal,
    this.onCommitRequest,
    DateTime Function()? clock,
    String Function()? newId,
  }) : clock = clock ?? DateTime.now,
       newId = newId ?? const Uuid().v4;

  /// Current workspace (may change after commits).
  final Workspace Function() workspace;
  final WorkspaceService workspaces;
  final EditingService editing;
  final AppDatabase db;
  final BlobStore blobs;
  final IgnoreRules rules;
  final String conversationId;
  final PdfTextExtractor? pdfText;
  final ExecutionService? execution;
  final void Function(Proposal proposal)? onProposal;
  final void Function(CommitRequest request)? onCommitRequest;
  final DateTime Function() clock;
  final String Function() newId;
}

/// Research tools exposed to the agent (docs/07_ai_agent.md §4).
class ResearchTools {
  ResearchTools(this.env);

  final ToolEnvironment env;

  static const maxReadChars = 200000;
  static const maxSearchFetches = 200;
  static const maxSearchFileBytes = 1024 * 1024;
  static const executionTools = {
    'run_code',
    'run_notebook_cell',
    'render_quarto',
  };

  static const _restricted =
      'Access restricted: this file is excluded by .gitscholarignore.';

  static JsonMap _schema(Map<String, JsonMap> props, List<String> required) => {
    'type': 'object',
    'properties': props,
    'required': required,
    'additionalProperties': false,
  };

  /// Tool definitions; execution tools only when a backend is configured.
  List<ToolDefinition> definitions() => [
    ToolDefinition(
      name: 'list_files',
      description:
          'List files and directories in the repository (including uncommitted changes). '
          'Use path to list a subdirectory and depth to limit recursion.',
      inputSchema: _schema({
        'path': {
          'type': 'string',
          'description':
              'Directory path relative to the repository root. Omit for root.',
        },
        'depth': {
          'type': 'integer',
          'description': 'Maximum depth (default 2).',
        },
      }, []),
    ),
    ToolDefinition(
      name: 'read_file',
      description:
          'Read a file with line numbers. PDFs return extracted text, notebooks return cells with outputs. '
          'Use start_line/end_line for large files.',
      inputSchema: _schema(
        {
          'path': {'type': 'string'},
          'start_line': {'type': 'integer'},
          'end_line': {'type': 'integer'},
        },
        ['path'],
      ),
    ),
    ToolDefinition(
      name: 'search_repo',
      description:
          'Search text files (Markdown, code, notebooks, BibTeX, YAML) for a query. '
          'Returns path:line: text. PDFs are not searched.',
      inputSchema: _schema(
        {
          'query': {'type': 'string'},
          'regex': {
            'type': 'boolean',
            'description': 'Treat query as a regular expression.',
          },
          'paths': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Restrict to these path prefixes.',
          },
          'max_results': {'type': 'integer'},
        },
        ['query'],
      ),
    ),
    ToolDefinition(
      name: 'propose_change',
      description:
          'Propose a change to one file. The user must approve it before it is applied. '
          'For modify, give edits where each old_text occurs exactly once in the current file. '
          'For create, give content. For delete, give only path and explanation.',
      inputSchema: _schema(
        {
          'path': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['modify', 'create', 'delete'],
          },
          'edits': {
            'type': 'array',
            'items': _schema(
              {
                'old_text': {'type': 'string'},
                'new_text': {'type': 'string'},
              },
              ['old_text', 'new_text'],
            ),
          },
          'content': {'type': 'string'},
          'explanation': {'type': 'string'},
        },
        ['path', 'kind', 'explanation'],
      ),
    ),
    ToolDefinition(
      name: 'get_diff',
      description:
          'Show unified diffs of uncommitted changes and pending proposals, optionally for one path.',
      inputSchema: _schema({
        'path': {'type': 'string'},
      }, []),
    ),
    ToolDefinition(
      name: 'request_commit',
      description:
          'Ask the user to commit and push the given paths with a message. This does not commit; '
          'the user reviews and confirms.',
      inputSchema: _schema(
        {
          'message': {'type': 'string'},
          'paths': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        ['message', 'paths'],
      ),
    ),
    if (env.execution != null) ...[
      ToolDefinition(
        name: 'run_code',
        description:
            'Run Python or R code on the remote Jupyter kernel and return stdout, stderr and errors.',
        inputSchema: _schema(
          {
            'language': {
              'type': 'string',
              'enum': ['python', 'r'],
            },
            'code': {'type': 'string'},
            'timeout_sec': {'type': 'integer'},
          },
          ['language', 'code'],
        ),
      ),
      ToolDefinition(
        name: 'run_notebook_cell',
        description:
            'Execute one notebook cell (0-based index) remotely and store its outputs as an uncommitted change.',
        inputSchema: _schema(
          {
            'path': {'type': 'string'},
            'cell_index': {'type': 'integer'},
          },
          ['path', 'cell_index'],
        ),
      ),
      ToolDefinition(
        name: 'render_quarto',
        description:
            'Render a .qmd or .Rmd document remotely with quarto and return the log.',
        inputSchema: _schema(
          {
            'path': {'type': 'string'},
            'format': {
              'type': 'string',
              'enum': ['html', 'pdf'],
            },
          },
          ['path'],
        ),
      ),
    ],
  ];

  /// Handlers keyed by tool name.
  Map<String, ToolHandler> handlers() => {
    'list_files': _guard(listFiles),
    'read_file': _guard(readFile),
    'search_repo': _guard(searchRepo),
    'propose_change': _guard(proposeChange),
    'get_diff': _guard(getDiff),
    'request_commit': _guard(requestCommit),
    if (env.execution != null) ...{
      'run_code': _guard(runCode),
      'run_notebook_cell': _guard(runNotebookCell),
      'render_quarto': _guard(renderQuarto),
    },
  };

  ToolHandler _guard(Future<ToolResult> Function(JsonMap) f) => (input) async {
    try {
      return await f(input);
    } on AppFailure catch (e) {
      return ToolResult.error(e.message);
    }
  };

  String _path(JsonMap input, [String key = 'path']) {
    final v = input[key];
    if (v is! String) throw ValidationFailure('$key is required');
    return normalizePath(v);
  }

  Future<List<PendingChange>> _changes() {
    final ws = env.workspace();
    return env.db.pendingChangesFor(ws.repo.fullName, ws.branch);
  }

  // ------------------------------------------------------------ list_files

  Future<ToolResult> listFiles(JsonMap input) async {
    final ws = env.workspace();
    final raw = input['path'];
    final base = raw is String && raw.trim().isNotEmpty && raw.trim() != '/'
        ? normalizePath(raw)
        : '';
    final depth = (input['depth'] as num?)?.toInt() ?? 2;
    final root = buildTree(ws.entries, await _changes());
    TreeNode? start = root;
    if (base.isNotEmpty) {
      start = null;
      void find(TreeNode n) {
        for (final c in n.children) {
          if (c.path == base) start = c;
          if (start == null && c.isDirectory) find(c);
        }
      }

      find(root);
      if (start == null || !start!.isDirectory) {
        return ToolResult.error('Not a directory: $base');
      }
    }
    final out = <String>[];
    void walk(TreeNode n, int d) {
      for (final c in n.children) {
        if (env.rules.isIgnored(c.path)) continue;
        if (c.marker == ChangeMarker.deleted) continue;
        if (c.isDirectory) {
          out.add('dir  ${c.path}/');
          if (d + 1 < depth) walk(c, d + 1);
        } else {
          final size = c.entry?.size;
          out.add(
            'file ${c.path}${size == null ? '' : ' ($size bytes)'}${c.marker == ChangeMarker.none ? '' : ' [${c.marker.name}]'}',
          );
        }
        if (out.length >= 1000) return;
      }
    }

    walk(start!, 0);
    if (out.isEmpty) return const ToolResult('(empty)');
    return ToolResult(out.join('\n'));
  }

  // ------------------------------------------------------------- read_file

  Future<String> _renderForRead(FileContent f) async {
    if (f.kind == FileKind.pdf) {
      final extractor = env.pdfText;
      if (extractor == null) return '[PDF text extraction unavailable]';
      return ContextBuilder.renderFile(f, pdfPages: await extractor(f.bytes));
    }
    return ContextBuilder.renderFile(f);
  }

  Future<ToolResult> readFile(JsonMap input) async {
    final path = _path(input);
    if (env.rules.isIgnored(path)) return const ToolResult.error(_restricted);
    final f = await env.workspaces.loadFile(env.workspace(), path);
    final text = await _renderForRead(f);
    final lines = text.split('\n');
    final start = (input['start_line'] as num?)?.toInt();
    final end = (input['end_line'] as num?)?.toInt();
    if (start == null && end == null && text.length > maxReadChars) {
      return ToolResult.error(
        'File is large (${text.length} chars, ${lines.length} lines). Call read_file with start_line and end_line.',
      );
    }
    final s = ((start ?? 1) - 1).clamp(0, lines.length);
    final e = (end ?? lines.length).clamp(s, lines.length);
    final width = '$e'.length;
    final body = StringBuffer();
    for (var i = s; i < e; i++) {
      body.writeln('${'${i + 1}'.padLeft(width)}\t${lines[i]}');
      if (body.length > maxReadChars) {
        body.writeln('[truncated at line ${i + 1}]');
        break;
      }
    }
    return ToolResult('$path (lines ${s + 1}-$e of ${lines.length})\n$body');
  }

  // ----------------------------------------------------------- search_repo

  Future<ToolResult> searchRepo(JsonMap input) async {
    final query = input['query'];
    if (query is! String || query.isEmpty) {
      return const ToolResult.error('query is required');
    }
    final max = ((input['max_results'] as num?)?.toInt() ?? 50).clamp(1, 500);
    final RegExp pattern;
    try {
      pattern = input['regex'] == true
          ? RegExp(query, caseSensitive: false, multiLine: true)
          : RegExp(RegExp.escape(query), caseSensitive: false);
    } on FormatException catch (e) {
      return ToolResult.error('Invalid regex: ${e.message}');
    }
    final prefixes = [
      for (final p in (input['paths'] as List?) ?? const [])
        ?tryNormalizePath('$p'),
    ];
    final ws = env.workspace();
    final changes = await _changes();
    final pendingPaths = {
      for (final c in changes)
        if (c.isPending && c.kind != ChangeKind.delete) c.path,
    };
    final deleted = {
      for (final c in changes)
        if (c.isPending && c.kind == ChangeKind.delete) c.path,
      for (final c in changes)
        if (c.isPending && c.kind == ChangeKind.rename) c.oldPath!,
    };
    final candidates = <String>{
      for (final e in ws.blobs) e.path,
      ...pendingPaths,
    }..removeAll(deleted);
    final results = <String>[];
    var fetched = 0;
    var skipped = 0;
    final sorted = candidates.toList()..sort();
    for (final path in sorted) {
      if (results.length >= max) break;
      if (env.rules.isIgnored(path)) continue;
      if (prefixes.isNotEmpty &&
          !prefixes.any((p) => path == p || path.startsWith('$p/'))) {
        continue;
      }
      final kind = FileKindDetector.fromPath(path);
      if (kind == FileKind.pdf || kind == FileKind.image) continue;
      final entry = ws.entry(path);
      final cached =
          pendingPaths.contains(path) ||
          (entry != null && await env.blobs.exists(entry.sha));
      if (!cached) {
        if ((entry?.size ?? 0) > maxSearchFileBytes ||
            fetched >= maxSearchFetches) {
          skipped++;
          continue;
        }
        fetched++;
      }
      final FileContent f;
      try {
        f = await env.workspaces.loadFile(ws, path);
      } on AppFailure {
        continue;
      }
      if (f.kind == FileKind.binary) continue;
      final text = f.kind == FileKind.notebook
          ? ContextBuilder.renderFile(f)
          : f.text;
      if (text == null) continue;
      for (final (i, line) in text.split('\n').indexed) {
        if (pattern.hasMatch(line)) {
          final t = line.trim();
          results.add(
            '$path:${i + 1}: ${t.length > 200 ? '${t.substring(0, 200)}…' : t}',
          );
          if (results.length >= max) break;
        }
      }
    }
    final notes = [
      if (results.length >= max) '[result limit $max reached]',
      if (skipped > 0) '[$skipped uncached or large files not searched]',
    ];
    if (results.isEmpty) {
      return ToolResult(['No matches for "$query".', ...notes].join('\n'));
    }
    return ToolResult([...results, ...notes].join('\n'));
  }

  // -------------------------------------------------------- propose_change

  /// Existing proposal for [path] in this conversation, if still pending.
  Future<(Proposal, PendingChange)?> _openProposal(String path) async {
    for (final p in await env.db.proposalsFor(env.conversationId)) {
      if (p.path != path || p.status != ProposalStatus.pending) continue;
      final c = await env.db.pendingChange(p.pendingChangeId);
      if (c != null) return (p, c);
    }
    return null;
  }

  Future<ToolResult> proposeChange(JsonMap input) async {
    final path = _path(input);
    if (env.rules.isIgnored(path)) return const ToolResult.error(_restricted);
    final kindName = input['kind'];
    final explanation = (input['explanation'] as String?)?.trim() ?? '';
    final ws = env.workspace();
    final open = await _openProposal(path);

    Future<String?> currentText() async {
      if (open != null && open.$2.contentSha != null) {
        final bytes = await env.blobs.read(open.$2.contentSha!);
        return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
      }
      try {
        final f = await env.workspaces.loadFile(ws, path);
        if (f.kind == FileKind.binary ||
            f.kind == FileKind.pdf ||
            f.kind == FileKind.image) {
          throw ValidationFailure('Cannot edit binary file: $path');
        }
        return f.text;
      } on NotFoundFailure {
        return null;
      }
    }

    ChangeKind kind;
    Uint8List? newBytes;
    String? oldText = await currentText();
    switch (kindName) {
      case 'modify':
        if (oldText == null) {
          return ToolResult.error(
            'File does not exist: $path. Use kind "create".',
          );
        }
        final edits = input['edits'];
        if (edits is! List || edits.isEmpty) {
          return const ToolResult.error('edits are required for modify');
        }
        var text = oldText;
        for (final (i, raw) in edits.indexed) {
          final edit = raw as Map;
          final oldPart = edit['old_text'] as String? ?? '';
          final newPart = edit['new_text'] as String? ?? '';
          if (oldPart.isEmpty) {
            return ToolResult.error('edits[$i].old_text is empty');
          }
          final count = oldPart.allMatches(text).length;
          if (count != 1) {
            return ToolResult.error(
              'edits[$i].old_text must occur exactly once in $path but occurs $count times. '
              '${count == 0 ? 'Re-read the file; the text may differ.' : 'Include more surrounding context.'}',
            );
          }
          text = text.replaceFirst(oldPart, newPart);
        }
        if (text == oldText) {
          return const ToolResult.error('The edits do not change the file.');
        }
        kind = ChangeKind.modify;
        newBytes = Uint8List.fromList(utf8.encode(text));
      case 'create':
        final content = input['content'];
        if (content is! String) {
          return const ToolResult.error('content is required for create');
        }
        if (open == null && await env.editing.exists(ws, path)) {
          return ToolResult.error(
            'File already exists: $path. Use kind "modify".',
          );
        }
        kind = ChangeKind.create;
        newBytes = Uint8List.fromList(utf8.encode(content));
        oldText = open == null ? null : oldText;
      case 'delete':
        if (oldText == null && !await env.editing.exists(ws, path)) {
          return ToolResult.error('File does not exist: $path');
        }
        kind = ChangeKind.delete;
      default:
        return ToolResult.error('Unknown kind: $kindName');
    }

    final now = env.clock();
    final contentSha = newBytes == null ? null : gitBlobSha(newBytes);
    if (newBytes != null) {
      await env.blobs.write(
        contentSha!,
        newBytes,
        repoFullName: ws.repo.fullName,
      );
    }
    final change = PendingChange(
      id: open?.$2.id ?? env.newId(),
      repoFullName: ws.repo.fullName,
      branch: ws.branch,
      path: path,
      kind:
          open != null &&
              open.$2.kind == ChangeKind.create &&
              kind == ChangeKind.modify
          ? ChangeKind.create
          : kind,
      origin: ChangeOrigin.ai,
      status: ChangeStatus.proposed,
      baseBlobSha: ws.entry(path)?.sha,
      baseCommitSha: ws.baseCommitSha,
      contentSha: contentSha,
      createdAt: open?.$2.createdAt ?? now,
      updatedAt: now,
    );
    final proposal = Proposal(
      id: open?.$1.id ?? env.newId(),
      conversationId: env.conversationId,
      path: path,
      kind: change.kind.name,
      explanation: explanation,
      status: ProposalStatus.pending,
      pendingChangeId: change.id,
      createdAt: open?.$1.createdAt ?? now,
    );
    await env.db.putPendingChange(change.copyWith(proposalId: proposal.id));
    await env.db.putProposal(proposal);
    env.onProposal?.call(proposal);

    var summary = kind.name;
    if (newBytes != null) {
      try {
        final s = stats(diffLines(oldText ?? '', utf8.decode(newBytes)));
        summary = '+${s.added} -${s.deleted}';
      } on DiffTooLarge {
        summary = 'large change';
      }
    }
    return ToolResult(
      jsonEncode({
        'proposal_id': proposal.id,
        'status': 'awaiting_user_approval',
        'diff_summary': summary,
        if (open != null)
          'note': 'Replaced your earlier proposal for this file.',
      }),
    );
  }

  // -------------------------------------------------------------- get_diff

  Future<ToolResult> getDiff(JsonMap input) async {
    final raw = input['path'];
    final only = raw is String && raw.isNotEmpty ? normalizePath(raw) : null;
    final ws = env.workspace();
    final loader = ChangeDiffLoader(
      blobs: env.blobs,
      workspaces: env.workspaces,
    );
    final out = StringBuffer();
    for (final c in await _changes()) {
      if (only != null && c.path != only && c.oldPath != only) continue;
      if (env.rules.isIgnored(c.path)) continue;
      out.writeln(
        '[${c.isPending ? 'uncommitted' : 'proposed'} ${c.kind.name}] ${c.path}',
      );
      if (c.kind == ChangeKind.delete) continue;
      try {
        final contents = await loader.load(ws, c);
        out.writeln(contents.isBinary ? '(binary)' : contents.unified());
      } on DiffTooLarge {
        out.writeln('(diff too large)');
      } on AppFailure catch (e) {
        out.writeln('(unavailable: ${e.message})');
      }
      if (out.length > 50000) {
        out.writeln('[truncated]');
        break;
      }
    }
    return ToolResult(out.isEmpty ? 'No uncommitted changes.' : out.toString());
  }

  // -------------------------------------------------------- request_commit

  Future<ToolResult> requestCommit(JsonMap input) async {
    final message = (input['message'] as String?)?.trim() ?? '';
    if (message.isEmpty) return const ToolResult.error('message is required');
    final paths = [
      for (final p in (input['paths'] as List?) ?? const [])
        normalizePath('$p'),
    ];
    final request = CommitRequest(
      id: env.newId(),
      conversationId: env.conversationId,
      message: message,
      paths: paths,
      status: CommitRequestStatus.awaitingUser,
      createdAt: env.clock(),
    );
    await env.db.putCommitRequest(request);
    env.onCommitRequest?.call(request);
    return ToolResult(
      jsonEncode({
        'request_id': request.id,
        'status': 'awaiting_user',
        'note':
            'The user will review and commit. Do not assume it has been committed.',
      }),
    );
  }

  // ------------------------------------------------------------- execution

  Future<ToolResult> runCode(JsonMap input) async {
    final exec = env.execution!;
    final code = input['code'] as String? ?? '';
    final timeout = Duration(
      seconds: ((input['timeout_sec'] as num?)?.toInt() ?? 50).clamp(1, 55),
    );
    final r = await exec.runCode(
      code,
      language: input['language'] as String? ?? 'python',
      timeout: timeout,
    );
    return ToolResult(r.toText(), isError: r.hasError);
  }

  Future<ToolResult> runNotebookCell(JsonMap input) async {
    final path = _path(input);
    if (env.rules.isIgnored(path)) return const ToolResult.error(_restricted);
    final index = (input['cell_index'] as num?)?.toInt() ?? -1;
    final ws = env.workspace();
    final f = await env.workspaces.loadFile(ws, path);
    final nb = parseNotebook(f.text ?? '');
    if (index < 0 || index >= nb.cells.length) {
      return ToolResult.error(
        'cell_index out of range (0-${nb.cells.length - 1})',
      );
    }
    if (nb.cells[index] is! CodeCell) {
      return const ToolResult.error('Not a code cell');
    }
    final updated = await env.execution!.runNotebookCells(ws, path, nb, [
      index,
    ]);
    final cell = updated.cells[index] as CodeCell;
    final text = cell.outputs.map(outputToPlainText).join('\n');
    final hasError = cell.outputs.any((o) => o is ErrorOutput);
    return ToolResult(text.isEmpty ? '(no output)' : text, isError: hasError);
  }

  Future<ToolResult> renderQuarto(JsonMap input) async {
    final path = _path(input);
    final format = input['format'] as String? ?? 'html';
    final r = await env.execution!.renderQuarto(
      env.workspace(),
      path,
      format: format,
    );
    return ToolResult(r.toText(), isError: r.hasError);
  }
}
