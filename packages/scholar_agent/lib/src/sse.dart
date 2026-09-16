import 'dart:async';
import 'dart:convert';

import 'models.dart';

/// A raw server-sent event.
class SseEvent {
  /// Creates an event.
  const SseEvent(this.event, this.data);

  /// `event:` field (may be empty).
  final String event;

  /// Joined `data:` lines.
  final String data;
}

/// Parses a byte stream into [SseEvent]s.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) => bytes
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .transform(StreamTransformer<String, SseEvent>.fromBind(_bindLines));

Stream<SseEvent> _bindLines(Stream<String> lines) async* {
  var event = '';
  final data = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      if (data.isNotEmpty || event.isNotEmpty) {
        yield SseEvent(event, data.join('\n'));
      }
      event = '';
      data.clear();
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
    }
  }
  if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
}

/// A decoded Messages API stream event.
class ApiStreamEvent {
  /// Creates an event.
  const ApiStreamEvent(this.type, this.data);

  /// Event type (`message_start`, `content_block_delta`, ...).
  final String type;

  /// Decoded JSON payload.
  final JsonMap data;
}

/// Decodes [SseEvent]s into [ApiStreamEvent]s, skipping undecodable data.
Stream<ApiStreamEvent> decodeApiEvents(Stream<SseEvent> events) async* {
  await for (final e in events) {
    if (e.data.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(e.data);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final map = Map<String, dynamic>.from(decoded);
    yield ApiStreamEvent((map['type'] ?? e.event) as String, map);
  }
}
