import 'dart:convert';

import 'errors.dart';
import 'models.dart';
import 'sse.dart';

/// Incremental output derived from a stream event.
sealed class StreamDelta {
  const StreamDelta();
}

/// Text appended to content block [index].
class TextDeltaOut extends StreamDelta {
  /// Creates a delta.
  const TextDeltaOut(this.index, this.text);

  /// Block index.
  final int index;

  /// Appended text.
  final String text;
}

/// Thinking summary text appended to block [index].
class ThinkingDeltaOut extends StreamDelta {
  /// Creates a delta.
  const ThinkingDeltaOut(this.index, this.text);

  /// Block index.
  final int index;

  /// Appended text.
  final String text;
}

/// A content block started.
class BlockStartedOut extends StreamDelta {
  /// Creates a delta.
  const BlockStartedOut(this.index, this.block);

  /// Block index.
  final int index;

  /// Initial block JSON.
  final JsonMap block;
}

/// A content block finished (tool_use input is parsed at this point).
class BlockFinishedOut extends StreamDelta {
  /// Creates a delta.
  const BlockFinishedOut(this.index, this.block);

  /// Block index.
  final int index;

  /// Final block JSON.
  final JsonMap block;
}

/// Builds a complete assistant message from stream events.
class MessageAccumulator {
  final _blocks = <int, JsonMap>{};
  final _partialJson = <int, StringBuffer>{};

  /// Message id.
  String? id;

  /// Model that produced the message.
  String? model;

  /// Stop reason.
  String? stopReason;

  /// Stop details (refusals).
  JsonMap? stopDetails;

  /// Usage so far.
  Usage usage = const Usage();

  /// Whether `message_stop` was received.
  bool done = false;

  /// Content blocks in index order.
  List<JsonMap> get content {
    final keys = _blocks.keys.toList()..sort();
    return [for (final k in keys) _blocks[k]!];
  }

  /// Applies [event], returning any user-visible deltas.
  ///
  /// Throws [AnthropicApiException] for `error` events.
  List<StreamDelta> apply(ApiStreamEvent event) {
    final d = event.data;
    switch (event.type) {
      case 'message_start':
        final m = Map<String, dynamic>.from(d['message'] as Map);
        id = m['id'] as String?;
        model = m['model'] as String?;
        if (m['usage'] is Map) {
          usage = usage.merge(Map<String, dynamic>.from(m['usage'] as Map));
        }
        return const [];
      case 'content_block_start':
        final index = d['index'] as int;
        final block = Map<String, dynamic>.from(d['content_block'] as Map);
        if (block['type'] == 'tool_use') {
          _partialJson[index] = StringBuffer();
        }
        _blocks[index] = block;
        return [BlockStartedOut(index, block)];
      case 'content_block_delta':
        final index = d['index'] as int;
        final delta = Map<String, dynamic>.from(d['delta'] as Map);
        final block = _blocks[index] ??= <String, dynamic>{
          'type': 'text',
          'text': '',
        };
        switch (delta['type']) {
          case 'text_delta':
            final t = delta['text'] as String;
            block['text'] = '${block['text'] ?? ''}$t';
            return [TextDeltaOut(index, t)];
          case 'thinking_delta':
            final t = delta['thinking'] as String;
            block['thinking'] = '${block['thinking'] ?? ''}$t';
            return [ThinkingDeltaOut(index, t)];
          case 'signature_delta':
            block['signature'] = delta['signature'];
            return const [];
          case 'input_json_delta':
            (_partialJson[index] ??= StringBuffer()).write(
              delta['partial_json'] as String,
            );
            return const [];
          case 'citations_delta':
            final citations = (block['citations'] ??= <Object?>[]) as List;
            citations.add(delta['citation']);
            return const [];
          default:
            return const [];
        }
      case 'content_block_stop':
        final index = d['index'] as int;
        final block = _blocks[index];
        if (block == null) return const [];
        final partial = _partialJson.remove(index);
        if (partial != null) {
          final raw = partial.toString();
          block['input'] = raw.isEmpty
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(raw) as Map);
        }
        return [BlockFinishedOut(index, block)];
      case 'message_delta':
        final delta = d['delta'];
        if (delta is Map) {
          if (delta['stop_reason'] != null) {
            stopReason = delta['stop_reason'] as String;
          }
          if (delta['stop_details'] is Map) {
            stopDetails = Map<String, dynamic>.from(
              delta['stop_details'] as Map,
            );
          }
        }
        if (d['usage'] is Map) {
          usage = usage.merge(Map<String, dynamic>.from(d['usage'] as Map));
        }
        return const [];
      case 'message_stop':
        done = true;
        return const [];
      case 'error':
        final err = d['error'] is Map
            ? Map<String, dynamic>.from(d['error'] as Map)
            : <String, dynamic>{};
        throw AnthropicApiException(
          0,
          (err['message'] ?? 'stream error') as String,
          type: err['type'] as String?,
          midStream: true,
        );
      default:
        return const [];
    }
  }

  /// Content suitable for echoing back as the assistant turn.
  ///
  /// After a mid-output fallback, blocks before the last `fallback` marker
  /// other than text are dropped, as required by the API.
  List<JsonMap> contentForHistory() => sanitizeFallbackContent(content);
}

/// Drops non-text blocks that precede the last `fallback` block.
List<JsonMap> sanitizeFallbackContent(List<JsonMap> blocks) {
  final last = blocks.lastIndexWhere((b) => b['type'] == 'fallback');
  if (last < 0) return blocks;
  return [
    for (final (i, b) in blocks.indexed)
      if (i >= last || b['type'] == 'text') b,
  ];
}
