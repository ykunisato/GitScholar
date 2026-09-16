/// One emoji reaction group as returned by GraphQL.
class ReactionGroupDto {
  /// Creates a group.
  const ReactionGroupDto({
    required this.content,
    required this.count,
    required this.viewerHasReacted,
  });

  /// Parses a `reactionGroups` entry.
  factory ReactionGroupDto.fromGraphQl(Map<String, dynamic> j) =>
      ReactionGroupDto(
        content: '${j['content']}',
        count:
            ((j['reactors'] as Map<String, dynamic>?)?['totalCount'] as num?)
                ?.toInt() ??
            0,
        viewerHasReacted: j['viewerHasReacted'] == true,
      );

  /// Parses a `reactionGroups` list, which may be absent.
  static List<ReactionGroupDto> listFrom(Object? groups) => [
    for (final g in (groups ?? const <Object?>[]) as List)
      ReactionGroupDto.fromGraphQl(g as Map<String, dynamic>),
  ];

  /// Value of the GraphQL `ReactionContent` enum.
  final String content;

  /// How many people reacted.
  final int count;

  /// Whether the signed-in user is one of them.
  final bool viewerHasReacted;
}

/// An issue (pull requests are filtered out by the client).
class IssueDto {
  /// Creates an issue.
  const IssueDto({
    required this.nodeId,
    required this.number,
    required this.title,
    required this.author,
    required this.updatedAt,
    required this.commentCount,
    required this.isOpen,
    required this.htmlUrl,
    this.body = '',
  });

  /// Parses JSON from the issues API.
  factory IssueDto.fromJson(Map<String, dynamic> j) => IssueDto(
    nodeId: (j['node_id'] ?? '') as String,
    number: (j['number'] as num).toInt(),
    title: (j['title'] ?? '') as String,
    author: ((j['user'] as Map<String, dynamic>?)?['login'] ?? '') as String,
    updatedAt: DateTime.tryParse('${j['updated_at']}') ?? DateTime(1970),
    commentCount: (j['comments'] as num?)?.toInt() ?? 0,
    isOpen: j['state'] != 'closed',
    htmlUrl: (j['html_url'] ?? '') as String,
    body: (j['body'] ?? '') as String,
  );

  /// Whether the JSON is a pull request rather than an issue.
  static bool isPullRequest(Map<String, dynamic> j) =>
      j['pull_request'] != null;

  /// GraphQL node id, used to react to the issue.
  final String nodeId;

  /// Issue number.
  final int number;

  /// Title.
  final String title;

  /// Author login.
  final String author;

  /// Last update time.
  final DateTime updatedAt;

  /// Number of comments.
  final int commentCount;

  /// Whether the issue is open.
  final bool isOpen;

  /// Web URL.
  final String htmlUrl;

  /// Opening post.
  final String body;
}

/// A comment on an issue or a discussion.
class ThreadCommentDto {
  /// Creates a comment.
  const ThreadCommentDto({
    required this.id,
    required this.author,
    required this.body,
    required this.createdAt,
    this.nodeId = '',
    this.reactions = const [],
  });

  /// Parses an issue comment.
  factory ThreadCommentDto.fromIssueJson(Map<String, dynamic> j) =>
      ThreadCommentDto(
        id: '${j['id']}',
        nodeId: (j['node_id'] ?? '') as String,
        author:
            ((j['user'] as Map<String, dynamic>?)?['login'] ?? '') as String,
        body: (j['body'] ?? '') as String,
        createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime(1970),
      );

  /// Parses a discussion comment node.
  factory ThreadCommentDto.fromGraphQl(Map<String, dynamic> j) =>
      ThreadCommentDto(
        id: '${j['id']}',
        // A discussion comment's GraphQL id is already its node id.
        nodeId: '${j['id']}',
        reactions: ReactionGroupDto.listFrom(j['reactionGroups']),
        author:
            ((j['author'] as Map<String, dynamic>?)?['login'] ?? '') as String,
        body: (j['body'] ?? '') as String,
        createdAt: DateTime.tryParse('${j['createdAt']}') ?? DateTime(1970),
      );

  /// Comment id.
  final String id;

  /// GraphQL node id, used to react to the comment.
  final String nodeId;

  /// Reactions on this comment.
  final List<ReactionGroupDto> reactions;

  /// Author login.
  final String author;

  /// Markdown body.
  final String body;

  /// Creation time.
  final DateTime createdAt;
}

/// A repository discussion.
class DiscussionDto {
  /// Creates a discussion.
  const DiscussionDto({
    required this.nodeId,
    required this.number,
    required this.title,
    required this.author,
    required this.updatedAt,
    required this.commentCount,
    required this.url,
    this.category,
    this.body = '',
    this.comments = const [],
    this.reactions = const [],
  });

  /// Parses a discussion node.
  factory DiscussionDto.fromGraphQl(Map<String, dynamic> j) => DiscussionDto(
    nodeId: '${j['id']}',
    number: (j['number'] as num?)?.toInt() ?? 0,
    title: (j['title'] ?? '') as String,
    author: ((j['author'] as Map<String, dynamic>?)?['login'] ?? '') as String,
    updatedAt: DateTime.tryParse('${j['updatedAt']}') ?? DateTime(1970),
    commentCount:
        ((j['comments'] as Map<String, dynamic>?)?['totalCount'] as num?)
            ?.toInt() ??
        0,
    url: (j['url'] ?? '') as String,
    category: (j['category'] as Map<String, dynamic>?)?['name'] as String?,
    body: (j['body'] ?? '') as String,
    reactions: ReactionGroupDto.listFrom(j['reactionGroups']),
    comments: [
      for (final c
          in ((j['comments'] as Map<String, dynamic>?)?['nodes'] ??
                  const <Object?>[])
              as List)
        ThreadCommentDto.fromGraphQl(c as Map<String, dynamic>),
    ],
  );

  /// GraphQL node id, required to add a comment.
  final String nodeId;

  /// Discussion number.
  final int number;

  /// Title.
  final String title;

  /// Author login.
  final String author;

  /// Last update time.
  final DateTime updatedAt;

  /// Number of comments.
  final int commentCount;

  /// Web URL.
  final String url;

  /// Category name.
  final String? category;

  /// Opening post.
  final String body;

  /// Comments, when the detail query asked for them.
  final List<ThreadCommentDto> comments;

  /// Reactions on the opening post.
  final List<ReactionGroupDto> reactions;
}
