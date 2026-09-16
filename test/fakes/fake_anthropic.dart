import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Scripted Anthropic API (docs/10 §2): each request pops the next response.
class FakeAnthropic {
  FakeAnthropic(this.responses);

  final List<List<Map<String, dynamic>>> responses;
  final requests = <Map<String, dynamic>>[];
  final headers = <Map<String, String>>[];

  http.Client get client => MockClient((req) async {
    requests.add(jsonDecode(req.body) as Map<String, dynamic>);
    headers.add(req.headers);
    final events = responses.removeAt(0);
    final body = events
        .map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n')
        .join();
    return http.Response(
      body,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });

  static List<Map<String, dynamic>> text(
    String text, {
    String stop = 'end_turn',
  }) => [
    {
      'type': 'message_start',
      'message': {
        'id': 'm',
        'model': 'claude-opus-5',
        'usage': {'input_tokens': 5},
      },
    },
    {
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    },
    {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': text},
    },
    {'type': 'content_block_stop', 'index': 0},
    {
      'type': 'message_delta',
      'delta': {'stop_reason': stop},
      'usage': {'output_tokens': 2},
    },
    {'type': 'message_stop'},
  ];

  static List<Map<String, dynamic>> toolUse(
    String id,
    String name,
    Map<String, dynamic> input,
  ) => [
    {
      'type': 'message_start',
      'message': {
        'id': 'm',
        'model': 'claude-opus-5',
        'usage': {'input_tokens': 5},
      },
    },
    {
      'type': 'content_block_start',
      'index': 0,
      'content_block': {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': {},
      },
    },
    {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input)},
    },
    {'type': 'content_block_stop', 'index': 0},
    {
      'type': 'message_delta',
      'delta': {'stop_reason': 'tool_use'},
      'usage': {'output_tokens': 2},
    },
    {'type': 'message_stop'},
  ];
}
