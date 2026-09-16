/// A saved AI conversation.
class Conversation {
  const Conversation({
    required this.id,
    required this.repoFullName,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String repoFullName;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// A persisted API message (content blocks kept as raw JSON).
class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.blocks,
    required this.createdAt,
    this.usage,
    this.model,
  });

  final String id;
  final String conversationId;
  final String role;
  final List<Map<String, dynamic>> blocks;
  final Map<String, dynamic>? usage;
  final String? model;
  final DateTime createdAt;
}

enum ProposalStatus { pending, approved, rejected }

/// An AI change proposal awaiting approval (docs/07_ai_agent.md §5.1).
class Proposal {
  const Proposal({
    required this.id,
    required this.conversationId,
    required this.path,
    required this.kind,
    required this.explanation,
    required this.status,
    required this.pendingChangeId,
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String path;
  final String kind;
  final String explanation;
  final ProposalStatus status;
  final String pendingChangeId;
  final DateTime createdAt;

  Proposal copyWith({
    ProposalStatus? status,
    String? pendingChangeId,
    String? explanation,
  }) => Proposal(
    id: id,
    conversationId: conversationId,
    path: path,
    kind: kind,
    explanation: explanation ?? this.explanation,
    status: status ?? this.status,
    pendingChangeId: pendingChangeId ?? this.pendingChangeId,
    createdAt: createdAt,
  );
}

enum CommitRequestStatus { awaitingUser, done, dismissed }

/// A commit requested by the AI (never executed automatically).
class CommitRequest {
  const CommitRequest({
    required this.id,
    required this.conversationId,
    required this.message,
    required this.paths,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String message;
  final List<String> paths;
  final CommitRequestStatus status;
  final DateTime createdAt;
}
