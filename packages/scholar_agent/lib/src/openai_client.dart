import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'llm_client.dart';
import 'models.dart';
import 'request.dart';
import 'sse.dart';

/// Client for OpenAI-compatible chat completions (OpenAI, OpenRouter, and
/// self-hosted servers that speak the same API). See ADR-0010.
class OpenAiClient implements LlmClient {
  /// Creates a client for an OpenAI-compatible endpoint.
  OpenAiClient({
    required this.apiKey,
    this.baseUrl = openAiBaseUrl,
    http.Client? client,
    this.extraHeaders = const {},
    this.maxRetries = 2,
    Future<void> Function(Duration)? delay,
  }) : _http = client ?? http.Client(),
       _delay = delay ?? Future<void>.delayed;

  /// OpenAI.
  static const openAiBaseUrl = 'https://api.openai.com/v1';

  /// OpenRouter, which proxies many providers behind the same API.
  static const openRouterBaseUrl = 'https://openrouter.ai/api/v1';

  /// API key sent as a bearer token.
  final String apiKey;

  /// Endpoint root, e.g. [openAiBaseUrl] or [openRouterBaseUrl].
  final String baseUrl;

  /// Extra headers, e.g. OpenRouter's `HTTP-Referer` and `X-Title`.
  final Map<String, String> extraHeaders;

  /// Retries for connection and 5xx errors before the stream starts.
  final int maxRetries;

  final http.Client _http;
  final Future<void> Function(Duration) _delay;

  /// OpenAI's newer models reject `max_tokens`; other servers expect it.
  bool get _usesMaxCompletionTokens => baseUrl.contains('api.openai.com');

  /// Request body for [request].
  JsonMap buildBody(MessageRequest request) => {
    'model': request.model,
    'messages': toChatMessages(request.system, request.messages),
    if (_usesMaxCompletionTokens)
      'max_completion_tokens': request.maxTokens
    else
      'max_tokens': request.maxTokens,
    'stream': true,
    'stream_options': {'include_usage': true},
    if (request.tools.isNotEmpty) ...{
      'tools': toChatTools(request.tools),
      'tool_choice': 'auto',
    },
  };

  /// Converts canonical messages to the chat completions format.
  ///
  /// Thinking blocks are dropped: they are provider specific and must not be
  /// replayed to another model.
  static List<JsonMap> toChatMessages(
    List<JsonMap> system,
    List<Message> messages,
  ) {
    final out = <JsonMap>[];
    final systemText = [
      for (final b in system)
        if (b['type'] == 'text') b['text'] as String,
    ].join('\n\n');
    if (systemText.isNotEmpty) {
      out.add({'role': 'system', 'content': systemText});
    }
    for (final m in messages) {
      final texts = [
        for (final b in m.content)
          if (b['type'] == 'text') b['text'] as String,
      ];
      if (m.isUser) {
        // Tool results are their own messages and must precede the next turn.
        for (final b in m.content) {
          if (b['type'] != 'tool_result') continue;
          final content = b['content'];
          out.add({
            'role': 'tool',
            'tool_call_id': b['tool_use_id'],
            'content': content is String ? content : jsonEncode(content),
          });
        }
        if (texts.isNotEmpty) {
          out.add({'role': 'user', 'content': texts.join('\n\n')});
        }
      } else {
        final calls = [
          for (final b in m.content)
            if (b['type'] == 'tool_use')
              {
                'id': b['id'],
                'type': 'function',
                'function': {
                  'name': b['name'],
                  'arguments': jsonEncode(b['input'] ?? const {}),
                },
              },
        ];
        if (texts.isEmpty && calls.isEmpty) continue;
        out.add({
          'role': 'assistant',
          'content': texts.isEmpty ? null : texts.join('\n\n'),
          if (calls.isNotEmpty) 'tool_calls': calls,
        });
      }
    }
    return out;
  }

  /// Converts tool definitions to the chat completions format.
  static List<JsonMap> toChatTools(List<ToolDefinition> tools) => [
    for (final t in tools)
      {
        'type': 'function',
        'function': {
          'name': t.name,
          'description': t.description,
          'parameters': t.inputSchema,
          if (t.strict) 'strict': true,
        },
      },
  ];

  /// Maps a finish reason to the canonical stop reason.
  static String? stopReasonFor(String? finishReason) => switch (finishReason) {
    'stop' => 'end_turn',
    'tool_calls' || 'function_call' => 'tool_use',
    'length' => 'max_tokens',
    'content_filter' => 'refusal',
    _ => finishReason,
  };

  @override
  Stream<LlmEvent> streamTurn(MessageRequest request) async* {
    final response = await _sendWithRetry(request);
    final text = StringBuffer();
    final calls = <int, _ToolCallBuffer>{};
    String? finishReason;
    String? model;
    var usage = const Usage();

    await for (final event in parseSse(response.stream)) {
      final data = event.data;
      if (data.isEmpty || data == '[DONE]') continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      final chunk = Map<String, dynamic>.from(decoded);
      if (chunk['error'] != null) {
        final err = chunk['error'];
        throw LlmApiException(
          0,
          err is Map ? '${err['message'] ?? err}' : '$err',
          type: err is Map ? err['type'] as String? : null,
          midStream: true,
        );
      }
      model ??= chunk['model'] as String?;
      if (chunk['usage'] is Map) {
        usage = _usageFrom(Map<String, dynamic>.from(chunk['usage'] as Map));
      }
      final choices = chunk['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = Map<String, dynamic>.from(choices.first as Map);
      finishReason = (choice['finish_reason'] as String?) ?? finishReason;
      final delta = choice['delta'];
      if (delta is! Map) continue;
      final d = Map<String, dynamic>.from(delta);

      final content = d['content'];
      if (content is String && content.isNotEmpty) {
        text.write(content);
        yield LlmTextDelta(content);
      }
      // Reasoning summaries, where the provider exposes them.
      final reasoning = d['reasoning'] ?? d['reasoning_content'];
      if (reasoning is String && reasoning.isNotEmpty) {
        yield LlmThinkingDelta(reasoning);
      }
      final toolCalls = d['tool_calls'];
      if (toolCalls is List) {
        for (final raw in toolCalls) {
          final call = Map<String, dynamic>.from(raw as Map);
          final index = (call['index'] as num?)?.toInt() ?? 0;
          final buffer = calls[index] ??= _ToolCallBuffer();
          buffer.id = (call['id'] as String?) ?? buffer.id;
          final fn = call['function'];
          if (fn is Map) {
            buffer.name = (fn['name'] as String?) ?? buffer.name;
            final args = fn['arguments'];
            if (args is String) buffer.arguments.write(args);
          }
        }
      }
    }

    final blocks = <JsonMap>[
      if (text.isNotEmpty) {'type': 'text', 'text': text.toString()},
      for (final entry in (calls.keys.toList()..sort()).map((k) => calls[k]!))
        entry.toBlock(),
    ];
    yield LlmTurnComplete(
      message: Message('assistant', blocks),
      stopReason:
          stopReasonFor(finishReason) ??
          (calls.isEmpty ? 'end_turn' : 'tool_use'),
      usage: usage,
      model: model ?? request.model,
    );
  }

  static Usage _usageFrom(JsonMap j) {
    final details = j['prompt_tokens_details'];
    final cached = details is Map
        ? (details['cached_tokens'] as num?)?.toInt() ?? 0
        : 0;
    final prompt = (j['prompt_tokens'] as num?)?.toInt() ?? 0;
    return Usage(
      inputTokens: prompt - cached < 0 ? prompt : prompt - cached,
      outputTokens: (j['completion_tokens'] as num?)?.toInt() ?? 0,
      cacheReadInputTokens: cached,
    );
  }

  Future<http.StreamedResponse> _sendWithRetry(MessageRequest request) async {
    var attempt = 0;
    while (true) {
      try {
        return await _send(request);
      } on LlmApiException catch (e) {
        final retryable = e.statusCode == 0 || e.statusCode >= 500;
        if (!retryable || attempt >= maxRetries) rethrow;
        await _delay(Duration(seconds: 1 << attempt));
        attempt++;
      }
    }
  }

  Future<http.StreamedResponse> _send(MessageRequest request) async {
    final req = http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..headers['content-type'] = 'application/json'
      ..headers.addAll(extraHeaders)
      ..body = jsonEncode(buildBody(request));
    final http.StreamedResponse res;
    try {
      res = await _http.send(req);
    } on SocketException catch (e) {
      throw LlmApiException(0, e.message);
    } on http.ClientException catch (e) {
      throw LlmApiException(0, e.message);
    }
    if (res.statusCode >= 400) {
      final body = await res.stream.bytesToString();
      var message = 'HTTP ${res.statusCode}';
      String? type;
      try {
        final j = jsonDecode(body);
        if (j is Map && j['error'] is Map) {
          final err = j['error'] as Map;
          message = '${err['message'] ?? message}';
          type = err['type'] as String?;
        }
      } on FormatException {
        // Keep the generic message.
      }
      final retry = int.tryParse(res.headers['retry-after'] ?? '');
      throw LlmApiException(
        res.statusCode,
        message,
        type: type,
        retryAfter: retry == null ? null : Duration(seconds: retry),
      );
    }
    return res;
  }

  @override
  void close() => _http.close();
}

class _ToolCallBuffer {
  String? id;
  String? name;
  final arguments = StringBuffer();

  JsonMap toBlock() {
    JsonMap input;
    try {
      final raw = arguments.toString();
      input = raw.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } on FormatException {
      input = <String, dynamic>{};
    }
    return {
      'type': 'tool_use',
      'id': id ?? 'call_${name ?? 'tool'}',
      'name': name ?? '',
      'input': input,
    };
  }
}
