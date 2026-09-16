import 'dart:async';

import 'package:scholar_agent/scholar_agent.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../infrastructure/ai/system_prompt.dart';
import '../../infrastructure/local/app_database.dart';
import '../../infrastructure/local/blob_store.dart';
import '../editing/editing_service.dart';

/// Conversation persistence, turn execution and proposal approval
/// (docs/07_ai_agent.md §5-6).
class AgentService {
  AgentService({
    required this.db,
    required this.blobs,
    required this.editing,
    required this.clientFor,
    DateTime Function()? clock,
    String Function()? newId,
  }) : _clock = clock ?? DateTime.now,
       _newId = newId ?? const Uuid().v4;

  final AppDatabase db;
  final BlobStore blobs;
  final EditingService editing;
  final AnthropicClient Function(String apiKey) clientFor;
  final DateTime Function() _clock;
  final String Function() _newId;

  /// Tokens above which the UI suggests starting a new conversation.
  static const contextWarningTokens = 150000;

  Future<Conversation> createConversation(
    RepositoryRef repo,
    String firstMessage,
  ) async {
    final now = _clock();
    final title = firstMessage.trim().replaceAll(RegExp(r'\s+'), ' ');
    final c = Conversation(
      id: _newId(),
      repoFullName: repo.fullName,
      title: title.length > 40
          ? title.substring(0, 40)
          : (title.isEmpty ? 'New conversation' : title),
      createdAt: now,
      updatedAt: now,
    );
    await db.putConversation(c);
    return c;
  }

  Future<List<Message>> history(String conversationId) async => [
    for (final m in await db.messagesFor(conversationId))
      Message(m.role, m.blocks),
  ];

  /// Builds the user message: optional context block, system notes, text.
  static Message userMessage(
    String text, {
    String? context,
    List<String> notes = const [],
  }) => Message('user', [
    if (context != null) {'type': 'text', 'text': context},
    for (final n in notes)
      {'type': 'text', 'text': '<system_note>$n</system_note>'},
    {'type': 'text', 'text': text},
  ]);

  /// Runs one turn, persisting every appended message.
  Stream<AgentEvent> runTurn({
    required Conversation conversation,
    required String apiKey,
    required Settings settings,
    required Message userMessage,
    required List<ToolDefinition> tools,
    required Map<String, ToolHandler> handlers,
    PermissionGate gate = const AllowAllGate(),
  }) async* {
    final history = await this.history(conversation.id);
    if (history.isNotEmpty && history.last.isUser) {
      // A previous turn failed after the user message was stored; the new
      // message would create two consecutive user turns, so merge by
      // appending the new blocks as a separate message is invalid. Start
      // from the stored message and add the new text to it instead.
      final merged = Message('user', [
        ...history.last.content,
        ...userMessage.content,
      ]);
      history
        ..removeLast()
        ..add(merged);
      await _replaceLastUserMessage(conversation.id, merged);
    } else {
      history.add(userMessage);
      await _persist(conversation.id, userMessage);
    }
    final loop = AgentLoop(
      client: clientFor(apiKey),
      handlers: handlers,
      gate: gate,
    );
    await for (final event in loop.runTurn(
      history: history,
      buildRequest: (h) => MessageRequest.forModel(
        model: settings.aiModel,
        messages: h,
        effort: settings.aiEffort,
        showThinkingSummary: settings.aiShowThinkingSummary,
        system: const [
          {
            'type': 'text',
            'text': researchSystemPrompt,
            'cache_control': {'type': 'ephemeral'},
          },
        ],
        tools: tools,
        clearOldToolUses: true,
      ),
    )) {
      if (event is MessageAppended) {
        await _persist(
          conversation.id,
          event.message,
          usage: event.usage,
          model: event.model,
        );
      }
      yield event;
    }
    await db.putConversation(
      Conversation(
        id: conversation.id,
        repoFullName: conversation.repoFullName,
        title: conversation.title,
        createdAt: conversation.createdAt,
        updatedAt: _clock(),
      ),
    );
  }

  Future<void> _persist(
    String conversationId,
    Message m, {
    Usage? usage,
    String? model,
  }) => db.addMessage(
    StoredMessage(
      id: _newId(),
      conversationId: conversationId,
      role: m.role,
      blocks: m.content,
      usage: usage?.toJson(),
      model: model,
      createdAt: _clock(),
    ),
  );

  Future<void> _replaceLastUserMessage(
    String conversationId,
    Message merged,
  ) async {
    final stored = await db.messagesFor(conversationId);
    final last = stored.last;
    await (db.delete(db.messages)..where((t) => t.id.equals(last.id))).go();
    await db.addMessage(
      StoredMessage(
        id: last.id,
        conversationId: conversationId,
        role: 'user',
        blocks: merged.content,
        createdAt: last.createdAt,
      ),
    );
  }

  /// Applies a proposal: the proposed content becomes a normal pending change.
  Future<void> approveProposal(Workspace ws, String proposalId) async {
    final p = await db.proposal(proposalId);
    if (p == null || p.status != ProposalStatus.pending) {
      throw const NotFoundFailure('Proposal not found');
    }
    final change = await db.pendingChange(p.pendingChangeId);
    if (change == null) {
      throw const NotFoundFailure('Proposal content not found');
    }
    PendingChange? applied;
    if (change.kind == ChangeKind.delete) {
      applied = await editing.deleteFile(ws, change.path);
    } else {
      final bytes = await blobs.read(change.contentSha!);
      if (bytes == null) {
        throw const ValidationFailure('Proposal content missing');
      }
      // Delete the proposed row first so it does not pin the path.
      await db.deletePendingChange(change.id);
      applied = await editing.saveBytes(
        ws,
        change.path,
        bytes,
        origin: ChangeOrigin.ai,
      );
    }
    await db.deletePendingChange(change.id);
    await db.putProposal(
      p.copyWith(
        status: ProposalStatus.approved,
        pendingChangeId: applied?.id ?? change.id,
      ),
    );
  }

  /// Rejects a proposal. Returns a note to send with the next user message.
  Future<String> rejectProposal(String proposalId) async {
    final p = await db.proposal(proposalId);
    if (p == null) throw const NotFoundFailure('Proposal not found');
    await db.deletePendingChange(p.pendingChangeId);
    await db.putProposal(p.copyWith(status: ProposalStatus.rejected));
    return 'The user rejected your proposal ${p.id} for ${p.path}.';
  }

  Future<void> resolveCommitRequest(
    CommitRequest r,
    CommitRequestStatus status,
  ) => db.putCommitRequest(
    CommitRequest(
      id: r.id,
      conversationId: r.conversationId,
      message: r.message,
      paths: r.paths,
      status: status,
      createdAt: r.createdAt,
    ),
  );
}
