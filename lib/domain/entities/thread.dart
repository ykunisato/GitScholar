/// Emoji reaction kinds supported by GitHub (FR-99).
enum ReactionKind {
  thumbsUp('THUMBS_UP', '+1', '\u{1F44D}'),
  thumbsDown('THUMBS_DOWN', '-1', '\u{1F44E}'),
  laugh('LAUGH', 'laugh', '\u{1F604}'),
  hooray('HOORAY', 'hooray', '\u{1F389}'),
  confused('CONFUSED', 'confused', '\u{1F615}'),
  heart('HEART', 'heart', '\u{2764}\u{FE0F}'),
  rocket('ROCKET', 'rocket', '\u{1F680}'),
  eyes('EYES', 'eyes', '\u{1F440}');

  const ReactionKind(this.graphQlName, this.restName, this.emoji);

  /// Value of the GraphQL `ReactionContent` enum.
  final String graphQlName;

  /// Value of the REST `content` field.
  final String restName;

  /// Emoji shown in the UI.
  final String emoji;

  /// Looks up a kind by its GraphQL name; null when GitHub adds a new one.
  static ReactionKind? fromGraphQl(String? name) {
    for (final k in values) {
      if (k.graphQlName == name) return k;
    }
    return null;
  }
}

/// How many people reacted with one emoji, and whether the signed-in user is
/// one of them.
class Reaction {
  const Reaction({required this.kind, required this.count, required this.mine});

  final ReactionKind kind;
  final int count;

  /// Whether the signed-in user reacted with [kind].
  final bool mine;

  /// Returns a copy with the signed-in user's reaction toggled, used to update
  /// the UI before the server answers.
  Reaction toggled() =>
      Reaction(kind: kind, count: count + (mine ? -1 : 1), mine: !mine);
}

/// Whether a thread is a GitHub Discussion or an Issue (FR-97).
enum ThreadKind { discussion, issue }

/// One row in the thread list.
class RepoThread {
  const RepoThread({
    required this.kind,
    required this.number,
    required this.title,
    required this.author,
    required this.updatedAt,
    required this.commentCount,
    required this.url,
    this.category,
    this.isOpen = true,
  });

  final ThreadKind kind;

  /// Issue or discussion number, as shown on GitHub.
  final int number;

  final String title;
  final String author;
  final DateTime updatedAt;
  final int commentCount;

  /// Web URL, used by "open on GitHub".
  final String url;

  /// Discussion category name. Null for issues.
  final String? category;

  /// Issues only; discussions are always listed as open.
  final bool isOpen;
}

/// A comment inside a thread.
class ThreadComment {
  const ThreadComment({
    required this.id,
    required this.author,
    required this.body,
    required this.createdAt,
    this.nodeId = '',
    this.reactions = const [],
  });

  final String id;
  final String author;
  final String body;
  final DateTime createdAt;

  /// GraphQL node id, needed to react to this comment (FR-99).
  final String nodeId;

  final List<Reaction> reactions;

  /// Returns a copy with [reactions] replaced.
  ThreadComment withReactions(List<Reaction> reactions) => ThreadComment(
    id: id,
    author: author,
    body: body,
    createdAt: createdAt,
    nodeId: nodeId,
    reactions: reactions,
  );
}

/// A thread with its body and comments.
class ThreadDetail {
  const ThreadDetail({
    required this.thread,
    required this.body,
    required this.comments,
    this.nodeId,
    this.reactions = const [],
  });

  final RepoThread thread;

  /// Opening post. Empty when the author left it blank.
  final String body;

  final List<ThreadComment> comments;

  /// GraphQL node id, needed to comment on a discussion and to react to the
  /// opening post.
  final String? nodeId;

  /// Reactions on the opening post (FR-99).
  final List<Reaction> reactions;

  /// Returns a copy with the given parts replaced.
  ThreadDetail copyWith({
    List<ThreadComment>? comments,
    List<Reaction>? reactions,
  }) => ThreadDetail(
    thread: thread,
    body: body,
    comments: comments ?? this.comments,
    nodeId: nodeId,
    reactions: reactions ?? this.reactions,
  );
}
