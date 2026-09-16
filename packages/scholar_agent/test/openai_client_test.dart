import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scholar_agent/scholar_agent.dart';
import 'package:test/test.dart';

String sse(List<Object> chunks) =>
    '${chunks.map((c) => 'data: ${c is String ? c : jsonEncode(c)}\n\n').join()}data: [DONE]\n\n';

http.StreamedResponse streamed(String body, {int status = 200}) =>
    http.StreamedResponse(Stream.value(utf8.encode(body)), status);

void main() {
  const tool = ToolDefinition(
    name: 'read_file',
    description: 'Read a file',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
      'additionalProperties': false,
    },
  );

  group('request conversion', () {
    test('system, user, assistant tool calls and tool results', () {
      final messages = [
        Message.userText('Summarise the note'),
        const Message('assistant', [
          {'type': 'thinking', 'thinking': 'internal', 'signature': 'sig'},
          {'type': 'text', 'text': 'Let me read it.'},
          {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'read_file',
            'input': {'path': 'notes/a.md'},
          },
        ]),
        const Message('user', [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'content': 'note body',
          },
        ]),
      ];
      final out = OpenAiClient.toChatMessages(const [
        {'type': 'text', 'text': 'You are a research assistant.'},
      ], messages);

      expect(out[0], {
        'role': 'system',
        'content': 'You are a research assistant.',
      });
      expect(out[1], {'role': 'user', 'content': 'Summarise the note'});
      final assistant = out[2];
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], 'Let me read it.');
      expect(
        assistant.toString(),
        isNot(contains('internal')),
        reason: 'thinking is not replayed',
      );
      final call = (assistant['tool_calls'] as List).single as Map;
      expect(call['id'], 'call_1');
      expect((call['function'] as Map)['name'], 'read_file');
      expect(jsonDecode((call['function'] as Map)['arguments'] as String), {
        'path': 'notes/a.md',
      });
      expect(out[3], {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': 'note body',
      });
    });

    test('tools become function definitions', () {
      final tools = OpenAiClient.toChatTools(const [tool]);
      expect(tools.single['type'], 'function');
      final fn = tools.single['function'] as Map;
      expect(fn['name'], 'read_file');
      expect((fn['parameters'] as Map)['additionalProperties'], isFalse);
      expect(fn['strict'], isTrue);
    });

    test('body uses the right token field per endpoint', () {
      final request = MessageRequest(
        model: 'gpt-5',
        messages: [Message.userText('hi')],
        tools: const [tool],
        maxTokens: 1234,
      );
      final openAi = OpenAiClient(apiKey: 'k').buildBody(request);
      expect(openAi['max_completion_tokens'], 1234);
      expect(openAi.containsKey('max_tokens'), isFalse);
      expect(openAi['stream'], isTrue);
      expect(openAi['tool_choice'], 'auto');

      final router = OpenAiClient(
        apiKey: 'k',
        baseUrl: OpenAiClient.openRouterBaseUrl,
      ).buildBody(request);
      expect(router['max_tokens'], 1234);
      expect(router.containsKey('max_completion_tokens'), isFalse);
    });

    test('stop reasons map to the canonical names', () {
      expect(OpenAiClient.stopReasonFor('stop'), 'end_turn');
      expect(OpenAiClient.stopReasonFor('tool_calls'), 'tool_use');
      expect(OpenAiClient.stopReasonFor('length'), 'max_tokens');
      expect(OpenAiClient.stopReasonFor('content_filter'), 'refusal');
      expect(OpenAiClient.stopReasonFor(null), isNull);
    });
  });

  group('streaming', () {
    test('text deltas build one assistant message', () async {
      final body = sse([
        {
          'model': 'gpt-5',
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'Hello '},
            },
          ],
        },
        {
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'world'},
            },
          ],
        },
        {
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
          ],
        },
        {
          'choices': [],
          'usage': {
            'prompt_tokens': 30,
            'completion_tokens': 5,
            'prompt_tokens_details': {'cached_tokens': 10},
          },
        },
      ]);
      final client = OpenAiClient(
        apiKey: 'k',
        client: MockClient.streaming((req, _) async {
          expect(req.headers['Authorization'], 'Bearer k');
          expect(
            req.url.toString(),
            'https://api.openai.com/v1/chat/completions',
          );
          return streamed(body);
        }),
      );
      final events = await client
          .streamTurn(
            MessageRequest(model: 'gpt-5', messages: [Message.userText('hi')]),
          )
          .toList();
      expect(
        events.whereType<LlmTextDelta>().map((e) => e.text).join(),
        'Hello world',
      );
      final done = events.last as LlmTurnComplete;
      expect(done.stopReason, 'end_turn');
      expect(done.message.text, 'Hello world');
      expect(done.usage.outputTokens, 5);
      expect(done.usage.cacheReadInputTokens, 10);
      expect(done.usage.inputTokens, 20);
      expect(done.model, 'gpt-5');
    });

    test('tool calls are assembled from argument fragments', () async {
      final body = sse([
        {
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_9',
                    'type': 'function',
                    'function': {'name': 'read_file', 'arguments': '{"pa'},
                  },
                ],
              },
            },
          ],
        },
        {
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': 'th":"notes/a.md"}'},
                  },
                ],
              },
            },
          ],
        },
        {
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'},
          ],
        },
      ]);
      final client = OpenAiClient(
        apiKey: 'k',
        client: MockClient.streaming((_, _) async => streamed(body)),
      );
      final events = await client
          .streamTurn(
            MessageRequest(
              model: 'gpt-5',
              messages: const [],
              tools: const [tool],
            ),
          )
          .toList();
      final done = events.last as LlmTurnComplete;
      expect(done.stopReason, 'tool_use');
      final call = done.message.toolUses.single;
      expect(call.id, 'call_9');
      expect(call.name, 'read_file');
      expect(call.input, {'path': 'notes/a.md'});
    });

    test('reasoning deltas surface as thinking', () async {
      final body = sse([
        {
          'choices': [
            {
              'index': 0,
              'delta': {'reasoning': 'weighing options'},
            },
          ],
        },
        {
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'done'},
              'finish_reason': 'stop',
            },
          ],
        },
      ]);
      final client = OpenAiClient(
        apiKey: 'k',
        client: MockClient.streaming((_, _) async => streamed(body)),
      );
      final events = await client
          .streamTurn(MessageRequest(model: 'x', messages: const []))
          .toList();
      expect(
        events.whereType<LlmThinkingDelta>().single.text,
        'weighing options',
      );
      final done = events.last as LlmTurnComplete;
      expect(
        done.message.content.where((b) => b['type'] == 'thinking'),
        isEmpty,
        reason: 'reasoning is shown but never replayed',
      );
    });

    test('http errors and mid-stream errors are reported', () async {
      final failing = OpenAiClient(
        apiKey: 'bad',
        delay: (_) async {},
        client: MockClient.streaming(
          (_, _) async => streamed(
            jsonEncode({
              'error': {
                'message': 'Incorrect API key provided',
                'type': 'invalid_request_error',
              },
            }),
            status: 401,
          ),
        ),
      );
      await expectLater(
        failing
            .streamTurn(MessageRequest(model: 'x', messages: const []))
            .toList(),
        throwsA(
          isA<LlmApiException>()
              .having((e) => e.isAuthError, 'auth', isTrue)
              .having(
                (e) => e.message,
                'message',
                'Incorrect API key provided',
              ),
        ),
      );

      final midStream = OpenAiClient(
        apiKey: 'k',
        client: MockClient.streaming(
          (_, _) async => streamed(
            sse([
              {
                'error': {
                  'message': 'upstream is down',
                  'type': 'server_error',
                },
              },
            ]),
          ),
        ),
      );
      await expectLater(
        midStream
            .streamTurn(MessageRequest(model: 'x', messages: const []))
            .toList(),
        throwsA(
          isA<LlmApiException>().having(
            (e) => e.midStream,
            'midStream',
            isTrue,
          ),
        ),
      );
    });

    test('retries 5xx before the stream starts', () async {
      var calls = 0;
      final delays = <Duration>[];
      final client = OpenAiClient(
        apiKey: 'k',
        delay: (d) async => delays.add(d),
        client: MockClient.streaming((_, _) async {
          calls++;
          if (calls == 1) {
            return streamed('{"error":{"message":"overloaded"}}', status: 503);
          }
          return streamed(
            sse([
              {
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': 'ok'},
                    'finish_reason': 'stop',
                  },
                ],
              },
            ]),
          );
        }),
      );
      final events = await client
          .streamTurn(MessageRequest(model: 'x', messages: const []))
          .toList();
      expect(calls, 2);
      expect(delays, [const Duration(seconds: 1)]);
      expect((events.last as LlmTurnComplete).message.text, 'ok');
    });
  });

  test(
    'the agent loop runs tools through an OpenAI-compatible provider',
    () async {
      var turn = 0;
      final client = OpenAiClient(
        apiKey: 'k',
        client: MockClient.streaming((req, bodyStream) async {
          turn++;
          if (turn == 1) {
            return streamed(
              sse([
                {
                  'choices': [
                    {
                      'index': 0,
                      'delta': {
                        'tool_calls': [
                          {
                            'index': 0,
                            'id': 'call_1',
                            'function': {
                              'name': 'read_file',
                              'arguments': '{"path":"a.md"}',
                            },
                          },
                        ],
                      },
                      'finish_reason': 'tool_calls',
                    },
                  ],
                },
              ]),
            );
          }
          // The tool result must reach the provider as a tool message.
          final sent =
              jsonDecode(await bodyStream.bytesToString())
                  as Map<String, dynamic>;
          final roles = [
            for (final m in sent['messages'] as List) (m as Map)['role'],
          ];
          expect(roles, containsAllInOrder(['assistant', 'tool']));
          return streamed(
            sse([
              {
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': 'a.md says hi'},
                    'finish_reason': 'stop',
                  },
                ],
              },
            ]),
          );
        }),
      );
      final loop = AgentLoop(
        client: client,
        handlers: {
          'read_file': (input) async =>
              ToolResult('contents of ${input['path']}'),
        },
      );
      final history = [Message.userText('read a.md')];
      final events = await loop
          .runTurn(
            history: history,
            buildRequest: (h) => MessageRequest(model: 'gpt-5', messages: h),
          )
          .toList();
      expect(
        events.whereType<ToolCallFinished>().single.result.content,
        'contents of a.md',
      );
      expect(
        events.last,
        isA<TurnFinished>().having((e) => e.stopReason, 'stop', 'end_turn'),
      );
      expect(history.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'assistant',
      ]);
      expect(history.last.text, 'a.md says hi');
    },
  );
}
