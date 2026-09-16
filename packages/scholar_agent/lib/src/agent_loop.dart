import 'dart:async';

import 'accumulator.dart';
import 'client.dart';
import 'errors.dart';
import 'models.dart';
import 'request.dart';

/// Runs a tool.
typedef ToolHandler = Future<ToolResult> Function(JsonMap input);

/// Decides whether a tool call may run (docs/07_ai_agent.md §5.1).
abstract class PermissionGate {
  /// Returns true to allow [call].
  Future<bool> allow(ToolUse call);
}

/// Allows every call.
class AllowAllGate implements PermissionGate {
  /// Creates the gate.
  const AllowAllGate();

  @override
  Future<bool> allow(ToolUse call) async => true;
}

/// Events emitted by [AgentLoop.runTurn].
sealed class AgentEvent {
  const AgentEvent();
}

/// A request to the model started.
class RequestStarted extends AgentEvent {
  /// Creates the event.
  const RequestStarted(this.iteration);

  /// Zero-based request number within the turn.
  final int iteration;
}

/// Streaming text.
class AgentTextDelta extends AgentEvent {
  /// Creates the event.
  const AgentTextDelta(this.text);

  /// Appended text.
  final String text;
}

/// Streaming thinking summary.
class AgentThinkingDelta extends AgentEvent {
  /// Creates the event.
  const AgentThinkingDelta(this.text);

  /// Appended text.
  final String text;
}

/// A tool call is about to run.
class ToolCallStarted extends AgentEvent {
  /// Creates the event.
  const ToolCallStarted(this.call);

  /// The call.
  final ToolUse call;
}

/// A tool call finished.
class ToolCallFinished extends AgentEvent {
  /// Creates the event.
  const ToolCallFinished(this.call, this.result);

  /// The call.
  final ToolUse call;

  /// The result.
  final ToolResult result;
}

/// A message was appended to the history. Persist it.
class MessageAppended extends AgentEvent {
  /// Creates the event.
  const MessageAppended(this.message, {this.usage, this.model});

  /// The message.
  final Message message;

  /// Usage for assistant messages.
  final Usage? usage;

  /// Model that produced an assistant message.
  final String? model;
}

/// The turn ended.
class TurnFinished extends AgentEvent {
  /// Creates the event.
  const TurnFinished(this.stopReason, {this.stopDetails, this.partialText});

  /// Final stop reason (`end_turn`, `max_tokens`, `refusal`, `tool_limit`,
  /// `pause_limit`).
  final String? stopReason;

  /// Stop details for refusals.
  final JsonMap? stopDetails;

  /// Discarded partial text (refusals).
  final String? partialText;
}

/// The turn failed.
class AgentFailed extends AgentEvent {
  /// Creates the event.
  const AgentFailed(this.error);

  /// The error.
  final AnthropicApiException error;
}

/// In-app tool-use loop (docs/07_ai_agent.md §5, ADR-0005).
class AgentLoop {
  /// Creates a loop.
  AgentLoop({
    required this.client,
    required this.handlers,
    this.gate = const AllowAllGate(),
    this.maxToolCalls = 25,
    this.toolTimeout = const Duration(seconds: 60),
    this.maxPauseRetries = 3,
  });

  /// API client.
  final AnthropicClient client;

  /// Tool handlers by name.
  final Map<String, ToolHandler> handlers;

  /// Permission gate.
  final PermissionGate gate;

  /// Maximum tool calls per turn.
  final int maxToolCalls;

  /// Timeout per tool call.
  final Duration toolTimeout;

  /// Maximum `pause_turn` continuations.
  final int maxPauseRetries;

  /// Runs one user turn. [history] must end with the new user message and is
  /// appended to in place (append-only).
  Stream<AgentEvent> runTurn({
    required List<Message> history,
    required MessageRequest Function(List<Message> history) buildRequest,
  }) async* {
    var toolCalls = 0;
    var pauses = 0;
    for (var iteration = 0; ; iteration++) {
      yield RequestStarted(iteration);
      final acc = MessageAccumulator();
      try {
        await for (final event in client.streamMessage(
          buildRequest(List.unmodifiable(history)),
        )) {
          for (final delta in acc.apply(event)) {
            switch (delta) {
              case TextDeltaOut(:final text):
                yield AgentTextDelta(text);
              case ThinkingDeltaOut(:final text):
                yield AgentThinkingDelta(text);
              case BlockStartedOut() || BlockFinishedOut():
                break;
            }
          }
        }
      } on AnthropicApiException catch (e) {
        yield AgentFailed(e);
        return;
      } on FormatException catch (e) {
        yield AgentFailed(AnthropicApiException(0, e.message, midStream: true));
        return;
      }

      if (!acc.done && acc.stopReason == null) {
        yield const AgentFailed(
          AnthropicApiException(0, 'stream ended early', midStream: true),
        );
        return;
      }

      if (acc.stopReason == 'refusal') {
        // Discard partial output; never echo a refused response.
        final partial = [
          for (final b in acc.content)
            if (b['type'] == 'text') b['text'] as String,
        ].join();
        yield TurnFinished(
          'refusal',
          stopDetails: acc.stopDetails,
          partialText: partial,
        );
        return;
      }

      final assistant = Message('assistant', acc.contentForHistory());
      history.add(assistant);
      yield MessageAppended(assistant, usage: acc.usage, model: acc.model);

      switch (acc.stopReason) {
        case 'tool_use':
          final calls = assistant.toolUses;
          if (toolCalls + calls.length > maxToolCalls) {
            final results = Message('user', [
              for (final c in calls)
                const ToolResult.error(
                  'Tool call limit for this turn reached. Stop and '
                  'summarise progress for the user.',
                ).toBlock(c.id),
            ]);
            history.add(results);
            yield MessageAppended(results);
            yield const TurnFinished('tool_limit');
            return;
          }
          toolCalls += calls.length;
          for (final c in calls) {
            yield ToolCallStarted(c);
          }
          final results = await Future.wait(calls.map(_runTool));
          for (final (i, c) in calls.indexed) {
            yield ToolCallFinished(c, results[i]);
          }
          final message = Message('user', [
            for (final (i, c) in calls.indexed) results[i].toBlock(c.id),
          ]);
          history.add(message);
          yield MessageAppended(message);
        case 'pause_turn':
          if (++pauses > maxPauseRetries) {
            yield const TurnFinished('pause_limit');
            return;
          }
        default:
          yield TurnFinished(acc.stopReason, stopDetails: acc.stopDetails);
          return;
      }
    }
  }

  Future<ToolResult> _runTool(ToolUse call) async {
    final handler = handlers[call.name];
    if (handler == null) {
      return ToolResult.error('Unknown tool: ${call.name}');
    }
    try {
      if (!await gate.allow(call)) {
        return const ToolResult.error('The user declined this tool call.');
      }
      return await handler(call.input).timeout(toolTimeout);
    } on TimeoutException {
      return ToolResult.error(
        'Tool timed out after ${toolTimeout.inSeconds} seconds.',
      );
    } on Object catch (e) {
      return ToolResult.error('Tool failed: $e');
    }
  }
}
