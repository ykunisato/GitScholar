/// A JSON object.
typedef JsonMap = Map<String, dynamic>;

/// A conversation message. Content blocks are kept as raw JSON so that
/// thinking blocks and unknown block types round-trip unchanged
/// (docs/07_ai_agent.md §2).
class Message {
  /// Creates a message.
  const Message(this.role, this.content);

  /// User message from plain text.
  factory Message.userText(String text) => Message('user', [
    {'type': 'text', 'text': text},
  ]);

  /// Parses JSON.
  factory Message.fromJson(JsonMap json) => Message(json['role'] as String, [
    for (final b in json['content'] as List)
      Map<String, dynamic>.from(b as Map),
  ]);

  /// `user` or `assistant`.
  final String role;

  /// Content blocks.
  final List<JsonMap> content;

  /// Whether this is a user message.
  bool get isUser => role == 'user';

  /// Concatenated text of all `text` blocks.
  String get text => [
    for (final b in content)
      if (b['type'] == 'text') b['text'] as String,
  ].join();

  /// `tool_use` blocks in this message.
  List<ToolUse> get toolUses => [
    for (final b in content)
      if (b['type'] == 'tool_use') ToolUse.fromBlock(b),
  ];

  /// JSON form.
  JsonMap toJson() => {'role': role, 'content': content};
}

/// A tool call requested by the model.
class ToolUse {
  /// Creates a tool use.
  const ToolUse({required this.id, required this.name, required this.input});

  /// From a `tool_use` content block.
  factory ToolUse.fromBlock(JsonMap block) => ToolUse(
    id: block['id'] as String,
    name: block['name'] as String,
    input: Map<String, dynamic>.from((block['input'] ?? const {}) as Map),
  );

  /// Tool use id.
  final String id;

  /// Tool name.
  final String name;

  /// Parsed input.
  final JsonMap input;
}

/// Result of running a tool.
class ToolResult {
  /// Creates a result.
  const ToolResult(this.content, {this.isError = false});

  /// Error result.
  const ToolResult.error(this.content) : isError = true;

  /// Text content returned to the model.
  final String content;

  /// Whether the tool failed.
  final bool isError;

  /// `tool_result` block for [toolUseId].
  JsonMap toBlock(String toolUseId) => {
    'type': 'tool_result',
    'tool_use_id': toolUseId,
    'content': content,
    if (isError) 'is_error': true,
  };
}

/// A tool the model may call. Always strict with a closed schema.
class ToolDefinition {
  /// Creates a definition.
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.strict = true,
  });

  /// Tool name.
  final String name;

  /// Description shown to the model.
  final String description;

  /// JSON schema (object with `additionalProperties: false`).
  final JsonMap inputSchema;

  /// Whether to enforce schema-valid arguments.
  final bool strict;

  /// JSON form.
  JsonMap toJson() => {
    'name': name,
    'description': description,
    'input_schema': inputSchema,
    if (strict) 'strict': true,
  };
}

/// Token usage of one response.
class Usage {
  /// Creates usage.
  const Usage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadInputTokens = 0,
    this.cacheCreationInputTokens = 0,
    this.servedByFallback = false,
  });

  /// Parses a `usage` object.
  factory Usage.fromJson(JsonMap j) => Usage(
    inputTokens: (j['input_tokens'] as num?)?.toInt() ?? 0,
    outputTokens: (j['output_tokens'] as num?)?.toInt() ?? 0,
    cacheReadInputTokens: (j['cache_read_input_tokens'] as num?)?.toInt() ?? 0,
    cacheCreationInputTokens:
        (j['cache_creation_input_tokens'] as num?)?.toInt() ?? 0,
    servedByFallback:
        j['iterations'] is List &&
        (j['iterations'] as List).any(
          (e) => e is Map && e['type'] == 'fallback_message',
        ),
  );

  /// Uncached input tokens.
  final int inputTokens;

  /// Output tokens.
  final int outputTokens;

  /// Tokens read from cache.
  final int cacheReadInputTokens;

  /// Tokens written to cache.
  final int cacheCreationInputTokens;

  /// Whether a fallback model ran for this response.
  final bool servedByFallback;

  /// Total input tokens including cache.
  int get totalInputTokens =>
      inputTokens + cacheReadInputTokens + cacheCreationInputTokens;

  /// Overlays non-zero fields of [other] onto this usage.
  Usage merge(JsonMap other) {
    final o = Usage.fromJson(other);
    return Usage(
      inputTokens: other.containsKey('input_tokens')
          ? o.inputTokens
          : inputTokens,
      outputTokens: other.containsKey('output_tokens')
          ? o.outputTokens
          : outputTokens,
      cacheReadInputTokens: other.containsKey('cache_read_input_tokens')
          ? o.cacheReadInputTokens
          : cacheReadInputTokens,
      cacheCreationInputTokens: other.containsKey('cache_creation_input_tokens')
          ? o.cacheCreationInputTokens
          : cacheCreationInputTokens,
      servedByFallback: servedByFallback || o.servedByFallback,
    );
  }

  /// JSON form for persistence.
  JsonMap toJson() => {
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'cache_read_input_tokens': cacheReadInputTokens,
    'cache_creation_input_tokens': cacheCreationInputTokens,
    if (servedByFallback)
      'iterations': [
        {'type': 'fallback_message'},
      ],
  };
}
