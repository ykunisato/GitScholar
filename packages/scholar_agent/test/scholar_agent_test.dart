import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scholar_agent/scholar_agent.dart';
import 'package:test/test.dart';

String sse(List<Map<String, dynamic>> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

List<Map<String, dynamic>> textResponse(
  String text, {
  String stop = 'end_turn',
  Map<String, dynamic>? stopDetails,
}) => [
  {
    'type': 'message_start',
    'message': {
      'id': 'msg_1',
      'model': 'claude-opus-5',
      'usage': {'input_tokens': 10, 'cache_read_input_tokens': 5},
    },
  },
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'thinking', 'thinking': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'thinking_delta', 'thinking': 'hmm'},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'signature_delta', 'signature': 'sig'},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'content_block_start',
    'index': 1,
    'content_block': {'type': 'text', 'text': ''},
  },
  for (final chunk in [
    text.substring(0, text.length ~/ 2),
    text.substring(text.length ~/ 2),
  ])
    {
      'type': 'content_block_delta',
      'index': 1,
      'delta': {'type': 'text_delta', 'text': chunk},
    },
  {'type': 'content_block_stop', 'index': 1},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': stop, 'stop_details': ?stopDetails},
    'usage': {'output_tokens': 7},
  },
  {'type': 'message_stop'},
];

List<Map<String, dynamic>> toolUseResponse(
  List<(String id, String name, Map<String, dynamic> input)> calls,
) => [
  {
    'type': 'message_start',
    'message': {
      'id': 'msg_t',
      'model': 'claude-opus-5',
      'usage': {'input_tokens': 3},
    },
  },
  for (final (i, c) in calls.indexed) ...[
    {
      'type': 'content_block_start',
      'index': i,
      'content_block': {
        'type': 'tool_use',
        'id': c.$1,
        'name': c.$2,
        'input': {},
      },
    },
    {
      'type': 'content_block_delta',
      'index': i,
      'delta': {
        'type': 'input_json_delta',
        'partial_json': _head(jsonEncode(c.$3)),
      },
    },
    {
      'type': 'content_block_delta',
      'index': i,
      'delta': {
        'type': 'input_json_delta',
        'partial_json': _tail(jsonEncode(c.$3)),
      },
    },
    {'type': 'content_block_stop', 'index': i},
  ],
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'tool_use'},
    'usage': {'output_tokens': 4},
  },
  {'type': 'message_stop'},
];

/// Scripted fake: each request pops the next response body.
class Script {
  Script(this.responses);
  final List<Object> responses; // String SSE body or http.Response
  final requests = <http.Request>[];

  http.Client get client => MockClient.streaming((req, bodyStream) async {
    final body = await bodyStream.bytesToString();
    final copy = http.Request(req.method, req.url)
      ..headers.addAll(req.headers)
      ..body = body;
    requests.add(copy);
    final r = responses.removeAt(0);
    if (r is http.Response) {
      return http.StreamedResponse(
        Stream.value(r.bodyBytes),
        r.statusCode,
        headers: r.headers,
      );
    }
    // Deliver in awkward chunks to exercise line splitting.
    final bytes = utf8.encode(r as String);
    return http.StreamedResponse(
      Stream.fromIterable([
        for (var i = 0; i < bytes.length; i += 37)
          bytes.sublist(i, i + 37 > bytes.length ? bytes.length : i + 37),
      ]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });

  Map<String, dynamic> body(int i) =>
      jsonDecode(requests[i].body) as Map<String, dynamic>;
}

void main() {
  group('SSE', () {
    test(
      'parses multi-line data, comments and missing trailing blank',
      () async {
        final input =
            ': ping\nevent: a\ndata: {"x":\ndata: 1}\n\nevent: b\ndata: 2';
        final events = await parseSse(
          Stream.value(utf8.encode(input)),
        ).toList();
        expect(events.map((e) => e.event), ['a', 'b']);
        expect(events.first.data, '{"x":\n1}');
        expect(events.last.data, '2');
      },
    );

    test('decodeApiEvents skips invalid json and uses type field', () async {
      final events = await decodeApiEvents(
        Stream.fromIterable(const [
          SseEvent('ping', '{"type":"ping"}'),
          SseEvent('x', 'not json'),
          SseEvent('x', '[1]'),
          SseEvent('x', ''),
        ]),
      ).toList();
      expect(events.single.type, 'ping');
    });
  });

  group('MessageAccumulator', () {
    test('builds content, usage and stop reason', () async {
      final acc = MessageAccumulator();
      final deltas = <StreamDelta>[];
      for (final e in textResponse('Hello world')) {
        deltas.addAll(acc.apply(ApiStreamEvent(e['type'] as String, e)));
      }
      expect(acc.done, isTrue);
      expect(acc.model, 'claude-opus-5');
      expect(acc.stopReason, 'end_turn');
      expect(acc.content[0], {
        'type': 'thinking',
        'thinking': 'hmm',
        'signature': 'sig',
      });
      expect(acc.content[1]['text'], 'Hello world');
      expect(acc.usage.inputTokens, 10);
      expect(acc.usage.cacheReadInputTokens, 5);
      expect(acc.usage.outputTokens, 7);
      expect(acc.usage.totalInputTokens, 15);
      expect(
        deltas.whereType<TextDeltaOut>().map((d) => d.text).join(),
        'Hello world',
      );
      expect(deltas.whereType<ThinkingDeltaOut>().single.text, 'hmm');
    });

    test('tool_use input assembled from partial json', () {
      final acc = MessageAccumulator();
      for (final e in toolUseResponse([
        ('t1', 'read_file', {'path': 'a/b.md', 'start_line': 2}),
      ])) {
        acc.apply(ApiStreamEvent(e['type'] as String, e));
      }
      expect(acc.content.single['input'], {'path': 'a/b.md', 'start_line': 2});
    });

    test('empty tool input becomes empty map', () {
      final acc = MessageAccumulator()
        ..apply(
          const ApiStreamEvent('content_block_start', {
            'index': 0,
            'content_block': {
              'type': 'tool_use',
              'id': 't',
              'name': 'list_files',
              'input': {},
            },
          }),
        )
        ..apply(const ApiStreamEvent('content_block_stop', {'index': 0}));
      expect(acc.content.single['input'], <String, dynamic>{});
    });

    test('error event throws', () {
      expect(
        () => MessageAccumulator().apply(
          const ApiStreamEvent('error', {
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }),
        ),
        throwsA(
          isA<AnthropicApiException>()
              .having((e) => e.type, 'type', 'overloaded_error')
              .having((e) => e.midStream, 'mid', isTrue),
        ),
      );
    });

    test('fallback served usage and sanitize', () {
      final u = Usage.fromJson({
        'iterations': [
          {'type': 'message'},
          {'type': 'fallback_message'},
        ],
      });
      expect(u.servedByFallback, isTrue);
      expect(Usage.fromJson(u.toJson()).servedByFallback, isTrue);
      final blocks = [
        {'type': 'thinking', 'thinking': ''},
        {'type': 'text', 'text': 'partial'},
        {'type': 'tool_use', 'id': 'x'},
        {
          'type': 'fallback',
          'from': {'model': 'a'},
          'to': {'model': 'b'},
        },
        {'type': 'thinking', 'thinking': ''},
        {'type': 'text', 'text': 'rest'},
      ];
      expect(sanitizeFallbackContent(blocks).map((b) => b['type']), [
        'text',
        'fallback',
        'thinking',
        'text',
      ]);
      expect(sanitizeFallbackContent(blocks.sublist(0, 2)), hasLength(2));
    });
  });

  group('MessageRequest', () {
    test('opus 5 uses default fallbacks, adaptive thinking and effort', () {
      final r = MessageRequest.forModel(
        model: ClaudeModels.opus5,
        messages: [Message.userText('hi')],
        system: [
          {
            'type': 'text',
            'text': 'sys',
            'cache_control': {'type': 'ephemeral'},
          },
        ],
        tools: const [
          ToolDefinition(
            name: 't',
            description: 'd',
            inputSchema: {'type': 'object'},
          ),
        ],
        effort: 'medium',
      );
      final j = r.toJson();
      expect(j['model'], 'claude-opus-5');
      expect(j['stream'], isTrue);
      expect(j['fallbacks'], 'default');
      expect(r.betas, ['server-side-fallback-2026-07-01']);
      expect(j['thinking'], {'type': 'adaptive', 'display': 'summarized'});
      expect(j['output_config'], {'effort': 'medium'});
      expect((j['tools'] as List).single, containsPair('strict', true));
      expect(j.containsKey('temperature'), isFalse);
      expect(j.containsKey('tool_choice'), isFalse);
    });

    test('sonnet 5 has no fallbacks or beta', () {
      final r = MessageRequest.forModel(
        model: ClaudeModels.sonnet5,
        messages: const [],
        showThinkingSummary: false,
      );
      final j = r.toJson();
      expect(j.containsKey('fallbacks'), isFalse);
      expect(r.betas, isEmpty);
      expect(j['thinking'], {'type': 'adaptive'});
      expect(j.containsKey('system'), isFalse);
      expect(j.containsKey('tools'), isFalse);
    });

    test('fable 5.1 supports default fallback', () {
      expect(
        ClaudeModels.supportsDefaultFallback(ClaudeModels.fable51),
        isTrue,
      );
      expect(ClaudeModels.all, hasLength(3));
    });

    test('withMessages keeps settings', () {
      final r = MessageRequest.forModel(
        model: ClaudeModels.opus5,
        messages: const [],
      ).withMessages([Message.userText('x')]);
      expect(r.messages.single.text, 'x');
      expect(r.fallbacks, 'default');
    });

    test('auto cache and context management', () {
      final r = MessageRequest.forModel(
        model: ClaudeModels.sonnet5,
        messages: const [],
        clearOldToolUses: true,
      );
      final j = r.toJson();
      expect(j['cache_control'], {'type': 'ephemeral'});
      expect(j['context_management'], {
        'edits': [
          {'type': 'clear_tool_uses_20250919'},
        ],
      });
      expect(r.betas, ['context-management-2025-06-27']);
      expect(
        const MessageRequest(
          model: 'm',
          messages: [],
          autoCache: false,
        ).toJson().containsKey('cache_control'),
        isFalse,
      );
    });
  });

  group('AnthropicClient', () {
    test('sends headers and body, streams events', () async {
      final s = Script([sse(textResponse('ok'))]);
      final client = AnthropicClient.withApiKey('sk-test', client: s.client);
      final events = await client
          .streamMessage(
            MessageRequest.forModel(
              model: ClaudeModels.opus5,
              messages: [Message.userText('hi')],
            ),
          )
          .toList();
      expect(events.first.type, 'message_start');
      final h = s.requests.single.headers;
      expect(h['x-api-key'], 'sk-test');
      expect(h['anthropic-version'], '2023-06-01');
      expect(h['anthropic-beta'], 'server-side-fallback-2026-07-01');
      expect(
        s.requests.single.url.toString(),
        'https://api.anthropic.com/v1/messages',
      );
      expect(s.body(0)['messages'], [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        },
      ]);
      client.close();
    });

    test('retries 529 then succeeds', () async {
      final delays = <Duration>[];
      final s = Script([
        http.Response(
          jsonEncode({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'o'},
          }),
          529,
        ),
        sse(textResponse('ok')),
      ]);
      final client = AnthropicClient(
        auth: const ApiKeyHeaderProvider('k'),
        client: s.client,
        delay: (d) async => delays.add(d),
      );
      await client
          .streamMessage(MessageRequest(model: 'm', messages: const []))
          .drain<void>();
      expect(s.requests, hasLength(2));
      expect(delays, [const Duration(seconds: 1)]);
    });

    test('401 is not retried and maps to auth error', () async {
      final s = Script([
        http.Response(
          jsonEncode({
            'error': {
              'type': 'authentication_error',
              'message': 'invalid x-api-key',
            },
          }),
          401,
        ),
      ]);
      final client = AnthropicClient.withApiKey('bad', client: s.client);
      await expectLater(
        client
            .streamMessage(const MessageRequest(model: 'm', messages: []))
            .drain<void>(),
        throwsA(
          isA<AnthropicApiException>()
              .having((e) => e.isAuthError, 'auth', isTrue)
              .having((e) => e.message, 'msg', 'invalid x-api-key')
              .having((e) => e.isRetryable, 'retryable', isFalse),
        ),
      );
    });

    test('429 carries retry-after', () async {
      final s = Script([
        http.Response('oops', 429, headers: {'retry-after': '12'}),
      ]);
      final client = AnthropicClient.withApiKey('k', client: s.client);
      await expectLater(
        client
            .streamMessage(const MessageRequest(model: 'm', messages: []))
            .drain<void>(),
        throwsA(
          isA<AnthropicApiException>()
              .having((e) => e.retryAfter, 'retry', const Duration(seconds: 12))
              .having((e) => e.isRateLimited, 'rl', isTrue)
              .having((e) => e.toString(), 'str', contains('429')),
        ),
      );
    });

    test('connection error retried up to maxRetries', () async {
      var calls = 0;
      final client = AnthropicClient(
        auth: const ApiKeyHeaderProvider('k'),
        delay: (_) async {},
        client: MockClient((_) async {
          calls++;
          throw http.ClientException('down');
        }),
      );
      await expectLater(
        client
            .streamMessage(const MessageRequest(model: 'm', messages: []))
            .drain<void>(),
        throwsA(
          isA<AnthropicApiException>().having((e) => e.statusCode, 's', 0),
        ),
      );
      expect(calls, 3);
    });
  });

  group('AgentLoop', () {
    test('text only turn', () async {
      final s = Script([sse(textResponse('Answer'))]);
      final loop = AgentLoop(
        client: AnthropicClient.withApiKey('k', client: s.client),
        handlers: {},
      );
      final history = [Message.userText('Q')];
      final events = await loop
          .runTurn(
            history: history,
            buildRequest: (h) =>
                MessageRequest.forModel(model: ClaudeModels.opus5, messages: h),
          )
          .toList();
      expect(
        events.whereType<AgentTextDelta>().map((e) => e.text).join(),
        'Answer',
      );
      expect(events.whereType<AgentThinkingDelta>(), isNotEmpty);
      expect(
        events.last,
        isA<TurnFinished>().having((e) => e.stopReason, 'stop', 'end_turn'),
      );
      expect(history, hasLength(2));
      // Thinking block preserved unchanged for replay.
      expect(history[1].content.first['signature'], 'sig');
      final appended = events.whereType<MessageAppended>().single;
      expect(appended.usage!.outputTokens, 7);
      expect(appended.model, 'claude-opus-5');
    });

    test('parallel tool calls return results in one user message', () async {
      final s = Script([
        sse(
          toolUseResponse([
            ('t1', 'read_file', {'path': 'a.md'}),
            ('t2', 'search_repo', {'query': 'precision'}),
          ]),
        ),
        sse(textResponse('Done')),
      ]);
      final started = <String>[];
      final loop = AgentLoop(
        client: AnthropicClient.withApiKey('k', client: s.client),
        handlers: {
          'read_file': (input) async {
            started.add('read');
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return ToolResult('content of ${input['path']}');
          },
          'search_repo': (input) async {
            started.add('search');
            return const ToolResult.error('nothing found');
          },
        },
      );
      final history = [Message.userText('find')];
      final events = await loop
          .runTurn(
            history: history,
            buildRequest: (h) => MessageRequest(model: 'm', messages: h),
          )
          .toList();
      expect(started, ['read', 'search']);
      expect(history.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'assistant',
      ]);
      final results = history[2].content;
      expect(results, [
        {
          'type': 'tool_result',
          'tool_use_id': 't1',
          'content': 'content of a.md',
        },
        {
          'type': 'tool_result',
          'tool_use_id': 't2',
          'content': 'nothing found',
          'is_error': true,
        },
      ]);
      expect(events.whereType<ToolCallStarted>(), hasLength(2));
      expect(events.whereType<ToolCallFinished>().last.result.isError, isTrue);
      // Second request carried the tool results.
      expect((s.body(1)['messages'] as List), hasLength(3));
    });

    test('permission denied, unknown tool, timeout and exception', () async {
      final s = Script([
        sse(
          toolUseResponse([
            ('a', 'run_code', {'code': 'x'}),
            ('b', 'nope', {}),
            ('c', 'slow', {}),
            ('d', 'boom', {}),
          ]),
        ),
        sse(textResponse('ok')),
      ]);
      final loop = AgentLoop(
        client: AnthropicClient.withApiKey('k', client: s.client),
        gate: _DenyGate('run_code'),
        toolTimeout: const Duration(milliseconds: 10),
        handlers: {
          'run_code': (_) async => const ToolResult('ran'),
          'slow': (_) => Completer<ToolResult>().future,
          'boom': (_) async => throw StateError('bad'),
        },
      );
      final history = [Message.userText('go')];
      await loop
          .runTurn(
            history: history,
            buildRequest: (h) => MessageRequest(model: 'm', messages: h),
          )
          .drain<void>();
      final r = history[2].content;
      expect(r.every((b) => b['is_error'] == true), isTrue);
      expect(r[0]['content'], contains('declined'));
      expect(r[1]['content'], contains('Unknown tool'));
      expect(r[2]['content'], contains('timed out'));
      expect(r[3]['content'], contains('bad'));
    });

    test('tool call limit stops the turn with valid history', () async {
      final s = Script([
        sse(toolUseResponse([('a', 'x', {}), ('b', 'x', {})])),
      ]);
      final loop = AgentLoop(
        client: AnthropicClient.withApiKey('k', client: s.client),
        maxToolCalls: 1,
        handlers: {'x': (_) async => const ToolResult('r')},
      );
      final history = [Message.userText('go')];
      final events = await loop
          .runTurn(
            history: history,
            buildRequest: (h) => MessageRequest(model: 'm', messages: h),
          )
          .toList();
      expect(
        events.last,
        isA<TurnFinished>().having((e) => e.stopReason, 's', 'tool_limit'),
      );
      expect(history.last.content, hasLength(2));
      expect(history.last.content.first['is_error'], isTrue);
    });

    test('refusal discards partial output', () async {
      final s = Script([
        sse(
          textResponse(
            'partial',
            stop: 'refusal',
            stopDetails: {'category': 'cyber', 'explanation': 'x'},
          ),
        ),
      ]);
      final loop = AgentLoop(
        client: AnthropicClient.withApiKey('k', client: s.client),
        handlers: {},
      );
      final history = [Message.userText('q')];
      final events = await loop
          .runTurn(
            history: history,
            buildRequest: (h) => MessageRequest(model: 'm', messages: h),
          )
          .toList();
      final fin = events.last as TurnFinished;
      expect(fin.stopReason, 'refusal');
      expect(fin.stopDetails!['category'], 'cyber');
      expect(fin.partialText, 'partial');
      expect(history, hasLength(1));
    });

    test('pause_turn resends and is capped', () async {
      final s = Script([
        sse(textResponse('a', stop: 'pause_turn')),
        sse(textResponse('b', stop: 'pause_turn')),
      ]);
      final loop = AgentLoop(
        client: AnthropicClient.withApiKey('k', client: s.client),
        handlers: {},
        maxPauseRetries: 1,
      );
      final history = [Message.userText('q')];
      final events = await loop
          .runTurn(
            history: history,
            buildRequest: (h) => MessageRequest(model: 'm', messages: h),
          )
          .toList();
      expect(s.requests, hasLength(2));
      expect(
        events.last,
        isA<TurnFinished>().having((e) => e.stopReason, 's', 'pause_limit'),
      );
    });

    test('max_tokens finishes turn', () async {
      final s = Script([sse(textResponse('long', stop: 'max_tokens'))]);
      final loop = AgentLoop(
        client: AnthropicClient.withApiKey('k', client: s.client),
        handlers: {},
      );
      final events = await loop
          .runTurn(
            history: [Message.userText('q')],
            buildRequest: (h) => MessageRequest(model: 'm', messages: h),
          )
          .toList();
      expect(
        events.last,
        isA<TurnFinished>().having((e) => e.stopReason, 's', 'max_tokens'),
      );
    });

    test('api error and truncated stream surface as AgentFailed', () async {
      final s = Script([
        http.Response('{}', 400),
        'event: message_start\ndata: {"type":"message_start","message":{"id":"x"}}\n\n',
      ]);
      final loop = AgentLoop(
        client: AnthropicClient.withApiKey('k', client: s.client),
        handlers: {},
      );
      final e1 = await loop
          .runTurn(
            history: [Message.userText('q')],
            buildRequest: (h) => MessageRequest(model: 'm', messages: h),
          )
          .toList();
      expect(
        e1.last,
        isA<AgentFailed>().having((e) => e.error.statusCode, 's', 400),
      );
      final e2 = await loop
          .runTurn(
            history: [Message.userText('q')],
            buildRequest: (h) => MessageRequest(model: 'm', messages: h),
          )
          .toList();
      expect(
        e2.last,
        isA<AgentFailed>().having((e) => e.error.midStream, 'mid', isTrue),
      );
    });
  });

  test('Message helpers', () {
    final m = Message.fromJson({
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'a'},
        {
          'type': 'tool_use',
          'id': 'i',
          'name': 'n',
          'input': {'k': 1},
        },
        {'type': 'text', 'text': 'b'},
      ],
    });
    expect(m.text, 'ab');
    expect(m.isUser, isFalse);
    expect(m.toolUses.single.input, {'k': 1});
    expect(m.toJson()['role'], 'assistant');
  });
}

class _DenyGate implements PermissionGate {
  _DenyGate(this.name);
  final String name;
  @override
  Future<bool> allow(ToolUse call) async => call.name != name;
}

String _head(String s) => s.substring(0, s.length < 3 ? s.length : 3);
String _tail(String s) => s.substring(s.length < 3 ? s.length : 3);
