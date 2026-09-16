import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scholar_agent/scholar_agent.dart';

import '../../application/agent/agent_service.dart';
import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../infrastructure/ai/context_builder.dart';
import '../../infrastructure/ai/pdf_text.dart';
import '../../infrastructure/ai/research_tools.dart';
import '../../infrastructure/local/secure_store.dart';
import '../core/providers.dart';

// ------------------------------------------------------------------ items

sealed class ChatItem {
  const ChatItem();
}

class UserChatItem extends ChatItem {
  const UserChatItem(this.text, {this.contextLabel});

  final String text;
  final String? contextLabel;
}

class ToolCallView {
  ToolCallView(this.call, [this.result]);

  final ToolUse call;
  ToolResult? result;
}

class AssistantChatItem extends ChatItem {
  AssistantChatItem();

  String text = '';
  String thinking = '';
  final tools = <ToolCallView>[];
  Usage? usage;
  String? model;
  bool done = false;
}

class ProposalChatItem extends ChatItem {
  ProposalChatItem(this.proposal);

  Proposal proposal;
}

class CommitRequestChatItem extends ChatItem {
  CommitRequestChatItem(this.request);

  CommitRequest request;
}

enum NoticeKind {
  refusal,
  maxTokens,
  toolLimit,
  error,
  missingKey,
  contextLarge,
}

class NoticeChatItem extends ChatItem {
  const NoticeChatItem(this.kind, [this.detail]);

  final NoticeKind kind;
  final String? detail;
}

/// A code-execution tool call awaiting user confirmation (docs/07 §5.1).
class PermissionRequest {
  PermissionRequest(this.call) : completer = Completer<bool>();

  final ToolUse call;
  final Completer<bool> completer;
}

class AgentState {
  const AgentState({
    this.conversation,
    this.items = const [],
    this.running = false,
    this.permission,
    this.attachOpenFile = true,
    this.attachSelection = true,
    this.extraPaths = const [],
    this.lastInputTokens = 0,
    this.autoRun = false,
    this.revision = 0,
  });

  final Conversation? conversation;
  final List<ChatItem> items;
  final bool running;
  final PermissionRequest? permission;
  final bool attachOpenFile;
  final bool attachSelection;
  final List<String> extraPaths;
  final int lastInputTokens;
  final bool autoRun;

  /// Bumped on in-place item mutations to trigger rebuilds.
  final int revision;

  AgentState copyWith({
    Conversation? conversation,
    bool clearConversation = false,
    List<ChatItem>? items,
    bool? running,
    PermissionRequest? permission,
    bool clearPermission = false,
    bool? attachOpenFile,
    bool? attachSelection,
    List<String>? extraPaths,
    int? lastInputTokens,
    bool? autoRun,
  }) => AgentState(
    conversation: clearConversation
        ? null
        : (conversation ?? this.conversation),
    items: items ?? this.items,
    running: running ?? this.running,
    permission: clearPermission ? null : (permission ?? this.permission),
    attachOpenFile: attachOpenFile ?? this.attachOpenFile,
    attachSelection: attachSelection ?? this.attachSelection,
    extraPaths: extraPaths ?? this.extraPaths,
    lastInputTokens: lastInputTokens ?? this.lastInputTokens,
    autoRun: autoRun ?? this.autoRun,
    revision: revision + 1,
  );
}

/// Describes what will be sent as context (NFR-31).
class ContextPreview {
  const ContextPreview({
    this.path,
    this.selectionLabel,
    required this.includeTree,
    this.extraPaths = const [],
    this.restricted = false,
  });

  final String? path;
  final String? selectionLabel;
  final bool includeTree;
  final List<String> extraPaths;
  final bool restricted;
}

class _Gate implements PermissionGate {
  _Gate(this.controller);

  final AgentController controller;

  @override
  Future<bool> allow(ToolUse call) => controller._askPermission(call);
}

class AgentController extends Notifier<AgentState> {
  StreamSubscription<AgentEvent>? _sub;
  final _notes = <String>[];
  String? _sentContextKey;
  final _allowOnce = <String>{};

  @override
  AgentState build() {
    ref.listen(currentWorkspaceProvider.select((s) => s.value?.repo.fullName), (
      prev,
      next,
    ) {
      if (prev != next) newConversation();
    });
    ref.onDispose(() => _sub?.cancel());
    return const AgentState();
  }

  void _touch() => state = state.copyWith();

  void setAttachOpenFile(bool v) => state = state.copyWith(attachOpenFile: v);
  void setAttachSelection(bool v) => state = state.copyWith(attachSelection: v);
  void setAutoRun(bool v) => state = state.copyWith(autoRun: v);
  void addExtraPath(String p) =>
      state = state.copyWith(extraPaths: {...state.extraPaths, p}.toList());
  void removeExtraPath(String p) =>
      state = state.copyWith(extraPaths: [...state.extraPaths]..remove(p));

  /// Marks the repository as allowed for this session only (FR-69).
  void allowOnce(String repoFullName) => _allowOnce.add(repoFullName);

  bool isAllowed(RepositoryRef repo) =>
      repo.effectiveAiAccess == AiAccess.allowed ||
      _allowOnce.contains(repo.fullName);

  void newConversation() {
    _sub?.cancel();
    _sub = null;
    _notes.clear();
    _sentContextKey = null;
    state = const AgentState();
  }

  ContextPreview preview() {
    final open = ref.read(openFilesProvider).active;
    final sel = ref.read(selectionProvider);
    final rules = ref.read(ignoreRulesProvider).value;
    final path = state.attachOpenFile ? open : null;
    return ContextPreview(
      path: path,
      selectionLabel:
          path != null &&
              state.attachSelection &&
              sel != null &&
              sel.path == path
          ? sel.label
          : null,
      includeTree: state.conversation == null,
      extraPaths: state.extraPaths,
      restricted: path != null && (rules?.isIgnored(path) ?? false),
    );
  }

  Future<bool> _askPermission(ToolUse call) async {
    if (!ResearchTools.executionTools.contains(call.name)) return true;
    if (state.autoRun || ref.read(currentSettingsProvider).autoRunCode) {
      return true;
    }
    final req = PermissionRequest(call);
    state = state.copyWith(permission: req);
    final allowed = await req.completer.future;
    state = state.copyWith(clearPermission: true);
    return allowed;
  }

  void respondPermission(bool allow, {bool always = false}) {
    final p = state.permission;
    if (p == null || p.completer.isCompleted) return;
    if (always) state = state.copyWith(autoRun: true);
    p.completer.complete(allow);
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.running) return;
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    if (ws.repo.effectiveAiAccess == AiAccess.denied) return;
    final key = await ref
        .read(secureStoreProvider)
        .read(SecureStore.anthropicKey);
    if (key == null) {
      state = state.copyWith(
        items: [
          ...state.items,
          UserChatItem(trimmed),
          const NoticeChatItem(NoticeKind.missingKey),
        ],
      );
      return;
    }
    final settings = ref.read(currentSettingsProvider);
    final rules = await ref.read(ignoreRulesProvider.future);
    final service = ref.read(agentServiceProvider);

    // Context (docs/07 §3). Sent with the first message and when it changes.
    final preview = this.preview();
    String? contextBlock;
    String? contextLabel;
    var contextKey = '';
    OpenFileContext? open;
    if (preview.path != null) {
      try {
        final f = await ref.read(fileContentProvider(preview.path!).future);
        final sel = preview.selectionLabel == null
            ? null
            : ref.read(selectionProvider);
        List<String>? pages;
        if (f.kind == FileKind.pdf && !rules.isIgnored(f.path)) {
          final cache = ref.read(pdfTextCacheProvider);
          pages = cache[f.blobSha ?? f.path] ??= await extractPdfText(f.bytes);
        }
        open = OpenFileContext(
          content: f,
          selection: sel,
          pdfPages: pages,
          currentPage: ref.read(pdfPageProvider)[f.path],
        );
        contextKey =
            '${f.path}:${f.blobSha}:${sel?.label}:${sel?.text.hashCode}';
        contextLabel = [f.path, ?preview.selectionLabel].join(' ');
      } on AppFailure {
        open = null;
      }
    }
    final extras = <String>[];
    for (final p in state.extraPaths) {
      if (rules.isIgnored(p)) continue;
      try {
        final f = await ref.read(workspaceServiceProvider).loadFile(ws, p);
        extras.add(
          '<attached_file path="${f.path}">\n${ContextBuilder.renderFile(f)}\n</attached_file>',
        );
        contextKey += '|${f.path}:${f.blobSha}';
      } on AppFailure {
        continue;
      }
    }
    final firstMessage = state.conversation == null;
    if (firstMessage || contextKey != _sentContextKey) {
      final base = ContextBuilder.build(
        workspace: ws,
        rules: rules,
        open: open,
        includeTree: firstMessage,
      );
      contextBlock = extras.isEmpty ? base : '$base\n${extras.join('\n')}';
      if (!firstMessage) {
        contextBlock = '<updated_context>\n$contextBlock\n</updated_context>';
      }
    }

    var conversation = state.conversation;
    conversation ??= await service.createConversation(ws.repo, trimmed);
    final notes = [..._notes];
    _notes.clear();
    final userMessage = AgentService.userMessage(
      trimmed,
      context: contextBlock,
      notes: notes,
    );
    _sentContextKey = contextKey;

    state = state.copyWith(
      conversation: conversation,
      running: true,
      items: [
        ...state.items,
        UserChatItem(
          trimmed,
          contextLabel: contextBlock == null
              ? null
              : (contextLabel ?? 'context'),
        ),
      ],
    );

    final tools = ResearchTools(
      ToolEnvironment(
        workspace: () => ref.read(currentWorkspaceProvider).value ?? ws,
        workspaces: ref.read(workspaceServiceProvider),
        editing: ref.read(editingServiceProvider),
        db: ref.read(databaseProvider),
        blobs: ref.read(blobStoreProvider),
        rules: rules,
        conversationId: conversation.id,
        pdfText: extractPdfText,
        execution: ref.read(executionServiceProvider),
        onProposal: _onProposal,
        onCommitRequest: (r) => state = state.copyWith(
          items: [...state.items, CommitRequestChatItem(r)],
        ),
      ),
    );

    final completer = Completer<void>();
    _sub = service
        .runTurn(
          conversation: conversation,
          apiKey: key,
          settings: settings,
          userMessage: userMessage,
          tools: tools.definitions(),
          handlers: tools.handlers(),
          gate: _Gate(this),
        )
        .listen(
          _onEvent,
          onError: (Object e) {
            state = state.copyWith(
              running: false,
              items: [...state.items, NoticeChatItem(NoticeKind.error, '$e')],
            );
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            _finishAssistant();
            state = state.copyWith(running: false);
            if (!completer.isCompleted) completer.complete();
          },
        );
    return completer.future;
  }

  AssistantChatItem? get _currentAssistant {
    final last = state.items.isEmpty ? null : state.items.last;
    return last is AssistantChatItem && !last.done ? last : null;
  }

  void _finishAssistant() {
    final a = _currentAssistant;
    if (a != null) a.done = true;
  }

  void _onEvent(AgentEvent e) {
    switch (e) {
      case RequestStarted():
        _finishAssistant();
        state = state.copyWith(items: [...state.items, AssistantChatItem()]);
      case AgentTextDelta(:final text):
        _currentAssistant?.text += text;
        _touch();
      case AgentThinkingDelta(:final text):
        _currentAssistant?.thinking += text;
        _touch();
      case ToolCallStarted(:final call):
        _currentAssistant?.tools.add(ToolCallView(call));
        _touch();
      case ToolCallFinished(:final call, :final result):
        for (final item in state.items.reversed) {
          if (item is AssistantChatItem) {
            final view = item.tools
                .where((t) => t.call.id == call.id)
                .firstOrNull;
            if (view != null) {
              view.result = result;
              break;
            }
          }
        }
        _touch();
      case MessageAppended(:final message, :final usage, :final model):
        if (!message.isUser) {
          final a = _currentAssistant;
          if (a != null) {
            a.usage = usage;
            a.model = model;
          }
          final tokens = usage?.totalInputTokens ?? 0;
          state = state.copyWith(lastInputTokens: tokens);
        }
      case TurnFinished(:final stopReason, :final stopDetails):
        final a = _currentAssistant;
        final items = [...state.items];
        switch (stopReason) {
          case 'refusal':
            if (a != null && a.tools.isEmpty) items.remove(a);
            items.add(
              NoticeChatItem(
                NoticeKind.refusal,
                stopDetails?['explanation'] as String? ??
                    stopDetails?['category'] as String?,
              ),
            );
          case 'max_tokens':
            items.add(const NoticeChatItem(NoticeKind.maxTokens));
          case 'tool_limit':
          case 'pause_limit':
            items.add(const NoticeChatItem(NoticeKind.toolLimit));
        }
        if (state.lastInputTokens > AgentService.contextWarningTokens) {
          items.add(const NoticeChatItem(NoticeKind.contextLarge));
        }
        state = state.copyWith(items: items);
      case AgentFailed(:final error):
        state = state.copyWith(
          items: [
            ...state.items,
            NoticeChatItem(
              NoticeKind.error,
              error.isAuthError
                  ? 'auth'
                  : (error.isRateLimited ? 'rate_limit' : error.message),
            ),
          ],
        );
    }
  }

  void _onProposal(Proposal p) {
    final items = [...state.items];
    final idx = items.indexWhere(
      (i) => i is ProposalChatItem && i.proposal.id == p.id,
    );
    if (idx >= 0) {
      (items[idx] as ProposalChatItem).proposal = p;
    } else {
      items.add(ProposalChatItem(p));
    }
    state = state.copyWith(items: items);
  }

  /// Stops the current turn; received text is kept.
  void stop() {
    _sub?.cancel();
    _sub = null;
    final p = state.permission;
    if (p != null && !p.completer.isCompleted) p.completer.complete(false);
    _finishAssistant();
    state = state.copyWith(running: false, clearPermission: true);
  }

  Future<void> approve(Proposal p) async {
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    await ref.read(agentServiceProvider).approveProposal(ws, p.id);
    _setProposalStatus(p.id, ProposalStatus.approved);
  }

  Future<void> reject(Proposal p) async {
    final note = await ref.read(agentServiceProvider).rejectProposal(p.id);
    _notes.add(note);
    _setProposalStatus(p.id, ProposalStatus.rejected);
  }

  Future<void> approveAll() async {
    for (final item in state.items) {
      if (item is ProposalChatItem &&
          item.proposal.status == ProposalStatus.pending) {
        await approve(item.proposal);
      }
    }
  }

  void _setProposalStatus(String id, ProposalStatus status) {
    for (final item in state.items) {
      if (item is ProposalChatItem && item.proposal.id == id) {
        item.proposal = item.proposal.copyWith(status: status);
      }
    }
    _touch();
  }

  void markCommitRequest(String id, CommitRequestStatus status) {
    for (final item in state.items) {
      if (item is CommitRequestChatItem && item.request.id == id) {
        item.request = CommitRequest(
          id: item.request.id,
          conversationId: item.request.conversationId,
          message: item.request.message,
          paths: item.request.paths,
          status: status,
          createdAt: item.request.createdAt,
        );
      }
    }
    _touch();
  }

  /// Restores a saved conversation (FR-66).
  Future<void> load(Conversation c) async {
    newConversation();
    final db = ref.read(databaseProvider);
    final messages = await db.messagesFor(c.id);
    final proposals = {for (final p in await db.proposalsFor(c.id)) p.id: p};
    final requests = {
      for (final r in await db.commitRequestsFor(c.id)) r.id: r,
    };
    final items = <ChatItem>[];
    final views = <String, ToolCallView>{};
    var lastTokens = 0;
    for (final m in messages) {
      if (m.role == 'user') {
        String? text;
        String? label;
        for (final b in m.blocks) {
          if (b['type'] == 'tool_result') {
            final view = views[b['tool_use_id']];
            if (view != null) {
              final content = b['content'];
              view.result = ToolResult(
                content is String ? content : jsonEncode(content),
                isError: b['is_error'] == true,
              );
              if (view.call.name == 'propose_change' ||
                  view.call.name == 'request_commit') {
                try {
                  final j =
                      jsonDecode(view.result!.content) as Map<String, dynamic>;
                  final p = proposals[j['proposal_id']];
                  if (p != null) items.add(ProposalChatItem(p));
                  final r = requests[j['request_id']];
                  if (r != null) items.add(CommitRequestChatItem(r));
                } on FormatException {
                  // Error results are plain text.
                }
              }
            }
          } else if (b['type'] == 'text') {
            final t = b['text'] as String;
            if (t.startsWith('<context>') ||
                t.startsWith('<updated_context>')) {
              label =
                  RegExp(
                    r'<open_file path="([^"]+)"',
                  ).firstMatch(t)?.group(1) ??
                  'context';
            } else if (!t.startsWith('<system_note>')) {
              text = t;
            }
          }
        }
        if (text != null) items.add(UserChatItem(text, contextLabel: label));
      } else {
        final a = AssistantChatItem()
          ..done = true
          ..model = m.model
          ..usage = m.usage == null ? null : Usage.fromJson(m.usage!);
        for (final b in m.blocks) {
          switch (b['type']) {
            case 'text':
              a.text += b['text'] as String;
            case 'thinking':
              a.thinking += (b['thinking'] as String?) ?? '';
            case 'tool_use':
              final view = ToolCallView(ToolUse.fromBlock(b));
              views[view.call.id] = view;
              a.tools.add(view);
          }
        }
        lastTokens = a.usage?.totalInputTokens ?? lastTokens;
        items.add(a);
      }
    }
    state = AgentState(
      conversation: c,
      items: items,
      lastInputTokens: lastTokens,
    );
    _sentContextKey = 'restored';
  }
}

final agentControllerProvider = NotifierProvider<AgentController, AgentState>(
  AgentController.new,
);
