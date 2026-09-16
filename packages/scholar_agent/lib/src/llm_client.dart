import 'models.dart';
import 'request.dart';

/// Something a model produced while streaming one assistant turn.
sealed class LlmEvent {
  const LlmEvent();
}

/// Visible answer text.
class LlmTextDelta extends LlmEvent {
  /// Creates a text delta.
  const LlmTextDelta(this.text);

  /// Appended text.
  final String text;
}

/// Reasoning summary, when the provider exposes one.
class LlmThinkingDelta extends LlmEvent {
  /// Creates a thinking delta.
  const LlmThinkingDelta(this.text);

  /// Appended text.
  final String text;
}

/// The turn finished. [message] is the assistant turn in the canonical block
/// form used for storage and replay.
class LlmTurnComplete extends LlmEvent {
  /// Creates a completed turn.
  const LlmTurnComplete({
    required this.message,
    this.stopReason,
    this.stopDetails,
    this.usage = const Usage(),
    this.model,
  });

  /// The assistant message to append to the conversation.
  final Message message;

  /// `end_turn`, `tool_use`, `max_tokens`, `refusal` or `pause_turn`.
  final String? stopReason;

  /// Extra information about a refusal, when the provider sends any.
  final JsonMap? stopDetails;

  /// Token usage of this turn.
  final Usage usage;

  /// Model that produced the turn.
  final String? model;
}

/// A model provider that can stream one assistant turn (ADR-0010).
///
/// Implementations translate to and from the canonical message format, so the
/// agent loop, the tools and stored conversations stay provider independent.
abstract class LlmClient {
  /// Streams one assistant turn for [request].
  Stream<LlmEvent> streamTurn(MessageRequest request);

  /// Releases the underlying HTTP client.
  void close();
}
