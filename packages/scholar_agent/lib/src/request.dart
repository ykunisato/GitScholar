import 'models.dart';

/// Model ids offered in settings (docs/07_ai_agent.md §1).
abstract final class ClaudeModels {
  /// Default model.
  static const opus5 = 'claude-opus-5';

  /// Faster, cheaper model.
  static const sonnet5 = 'claude-sonnet-5';

  /// Most capable model.
  static const fable51 = 'claude-fable-5-1';

  /// All selectable models.
  static const all = [opus5, sonnet5, fable51];

  /// Beta header for `fallbacks: "default"`.
  static const fallbackBeta = 'server-side-fallback-2026-07-01';

  /// Beta header for context editing.
  static const contextManagementBeta = 'context-management-2025-06-27';

  /// Whether [model] supports server-side `fallbacks: "default"`.
  static bool supportsDefaultFallback(String model) =>
      model == opus5 || model == fable51;
}

/// Effort levels.
const effortLevels = ['low', 'medium', 'high', 'xhigh', 'max'];

/// A Messages API request.
class MessageRequest {
  /// Creates a request.
  const MessageRequest({
    required this.model,
    required this.messages,
    this.maxTokens = 32000,
    this.system = const [],
    this.tools = const [],
    this.thinking,
    this.effort,
    this.fallbacks,
    this.betas = const [],
    this.stream = true,
    this.autoCache = true,
    this.clearOldToolUses = false,
  });

  /// Builds a request with the model-specific defaults from
  /// docs/07_ai_agent.md §2.
  factory MessageRequest.forModel({
    required String model,
    required List<Message> messages,
    List<JsonMap> system = const [],
    List<ToolDefinition> tools = const [],
    String effort = 'high',
    bool showThinkingSummary = true,
    int maxTokens = 32000,
    bool clearOldToolUses = false,
  }) {
    final fallback = ClaudeModels.supportsDefaultFallback(model);
    return MessageRequest(
      model: model,
      messages: messages,
      system: system,
      tools: tools,
      maxTokens: maxTokens,
      thinking: {
        'type': 'adaptive',
        if (showThinkingSummary) 'display': 'summarized',
      },
      effort: effort,
      fallbacks: fallback ? 'default' : null,
      clearOldToolUses: clearOldToolUses,
      betas: [
        if (fallback) ClaudeModels.fallbackBeta,
        if (clearOldToolUses) ClaudeModels.contextManagementBeta,
      ],
    );
  }

  /// Model id.
  final String model;

  /// Conversation.
  final List<Message> messages;

  /// Maximum output tokens.
  final int maxTokens;

  /// System text blocks (may carry `cache_control`).
  final List<JsonMap> system;

  /// Tools.
  final List<ToolDefinition> tools;

  /// Thinking config.
  final JsonMap? thinking;

  /// `output_config.effort`.
  final String? effort;

  /// `fallbacks` parameter (`"default"` or a list).
  final Object? fallbacks;

  /// `anthropic-beta` values.
  final List<String> betas;

  /// Whether to stream.
  final bool stream;

  /// Adds top-level `cache_control` so the API places a breakpoint on the
  /// last cacheable block (prompt caching for the growing history).
  final bool autoCache;

  /// Enables server-side clearing of old tool results
  /// (`context_management.edits: clear_tool_uses`). Requires
  /// [ClaudeModels.contextManagementBeta]. History is never edited
  /// client-side, which keeps thinking-block replay valid.
  final bool clearOldToolUses;

  /// Returns a copy with different messages.
  MessageRequest withMessages(List<Message> messages) => MessageRequest(
    model: model,
    messages: messages,
    maxTokens: maxTokens,
    system: system,
    tools: tools,
    thinking: thinking,
    effort: effort,
    fallbacks: fallbacks,
    betas: betas,
    stream: stream,
    autoCache: autoCache,
    clearOldToolUses: clearOldToolUses,
  );

  /// JSON body.
  JsonMap toJson() => {
    'model': model,
    'max_tokens': maxTokens,
    if (stream) 'stream': true,
    if (autoCache) 'cache_control': {'type': 'ephemeral'},
    if (clearOldToolUses)
      'context_management': {
        'edits': [
          {'type': 'clear_tool_uses_20250919'},
        ],
      },
    'thinking': ?thinking,
    if (effort != null) 'output_config': {'effort': effort},
    'fallbacks': ?fallbacks,
    if (system.isNotEmpty) 'system': system,
    if (tools.isNotEmpty) 'tools': [for (final t in tools) t.toJson()],
    'messages': [for (final m in messages) m.toJson()],
  };
}
