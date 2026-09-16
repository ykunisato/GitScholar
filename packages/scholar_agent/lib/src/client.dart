import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'accumulator.dart';
import 'errors.dart';
import 'llm_client.dart';
import 'models.dart';
import 'request.dart';
import 'sse.dart';

/// Supplies authentication headers (API key today, a proxy token later;
/// docs/07_ai_agent.md §9).
abstract class HeaderProvider {
  /// Headers to add to every request.
  Future<Map<String, String>> headers();
}

/// `x-api-key` authentication.
class ApiKeyHeaderProvider implements HeaderProvider {
  /// Creates the provider.
  const ApiKeyHeaderProvider(this.apiKey);

  /// The API key.
  final String apiKey;

  @override
  Future<Map<String, String>> headers() async => {'x-api-key': apiKey};
}

/// Streaming Messages API client (Anthropic).
class AnthropicClient implements LlmClient {
  /// Creates a client.
  AnthropicClient({
    required this.auth,
    http.Client? client,
    this.baseUrl = 'https://api.anthropic.com',
    this.maxRetries = 2,
    Future<void> Function(Duration)? delay,
  }) : _http = client ?? http.Client(),
       _delay = delay ?? Future<void>.delayed;

  /// Convenience constructor for an API key.
  factory AnthropicClient.withApiKey(String apiKey, {http.Client? client}) =>
      AnthropicClient(auth: ApiKeyHeaderProvider(apiKey), client: client);

  /// Auth headers.
  final HeaderProvider auth;

  /// API base URL.
  final String baseUrl;

  /// Retries for overloaded / 5xx / connection errors before streaming starts.
  final int maxRetries;

  final http.Client _http;
  final Future<void> Function(Duration) _delay;

  /// API version header value.
  static const apiVersion = '2023-06-01';

  @override
  Stream<LlmEvent> streamTurn(MessageRequest request) async* {
    final acc = MessageAccumulator();
    await for (final event in streamMessage(request)) {
      for (final delta in acc.apply(event)) {
        switch (delta) {
          case TextDeltaOut(:final text):
            yield LlmTextDelta(text);
          case ThinkingDeltaOut(:final text):
            yield LlmThinkingDelta(text);
          case BlockStartedOut() || BlockFinishedOut():
            break;
        }
      }
    }
    if (!acc.done && acc.stopReason == null) return;
    yield LlmTurnComplete(
      message: Message('assistant', acc.contentForHistory()),
      stopReason: acc.stopReason,
      stopDetails: acc.stopDetails,
      usage: acc.usage,
      model: acc.model,
    );
  }

  /// Sends [request] and streams decoded events.
  ///
  /// Cancelling the subscription stops reading the response.
  Stream<ApiStreamEvent> streamMessage(MessageRequest request) async* {
    final response = await _sendWithRetry(request);
    yield* decodeApiEvents(parseSse(response.stream));
  }

  Future<http.StreamedResponse> _sendWithRetry(MessageRequest request) async {
    var attempt = 0;
    while (true) {
      try {
        return await _send(request);
      } on AnthropicApiException catch (e) {
        final retryable =
            e.statusCode == 0 ||
            e.statusCode >= 500 ||
            e.type == 'overloaded_error';
        if (!retryable || attempt >= maxRetries) rethrow;
        await _delay(Duration(seconds: 1 << attempt));
        attempt++;
      }
    }
  }

  Future<http.StreamedResponse> _send(MessageRequest request) async {
    final req = http.Request('POST', Uri.parse('$baseUrl/v1/messages'))
      ..headers.addAll(await auth.headers())
      ..headers['anthropic-version'] = apiVersion
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(request.toJson());
    if (request.betas.isNotEmpty) {
      req.headers['anthropic-beta'] = request.betas.join(',');
    }
    final http.StreamedResponse res;
    try {
      res = await _http.send(req);
    } on SocketException catch (e) {
      throw AnthropicApiException(0, e.message);
    } on http.ClientException catch (e) {
      throw AnthropicApiException(0, e.message);
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
        // Keep generic message.
      }
      final retry = int.tryParse(res.headers['retry-after'] ?? '');
      throw AnthropicApiException(
        res.statusCode,
        message,
        type: type,
        retryAfter: retry == null ? null : Duration(seconds: retry),
      );
    }
    return res;
  }

  /// Closes the HTTP client.
  @override
  void close() => _http.close();
}
