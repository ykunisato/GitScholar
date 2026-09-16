/// Error from the Anthropic API or transport.
class AnthropicApiException implements Exception {
  /// Creates the exception.
  const AnthropicApiException(
    this.statusCode,
    this.message, {
    this.type,
    this.retryAfter,
    this.midStream = false,
  });

  /// HTTP status, or 0 for transport / stream errors.
  final int statusCode;

  /// Error message.
  final String message;

  /// API error type, e.g. `overloaded_error`.
  final String? type;

  /// Server-suggested wait before retrying.
  final Duration? retryAfter;

  /// Whether the error happened after the stream had started.
  final bool midStream;

  /// Whether the request may succeed if retried later.
  bool get isRetryable =>
      statusCode == 0 ||
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode >= 500 ||
      type == 'overloaded_error';

  /// Whether the API key is invalid.
  bool get isAuthError => statusCode == 401 || statusCode == 403;

  /// Whether this is a rate limit.
  bool get isRateLimited => statusCode == 429 || type == 'rate_limit_error';

  @override
  String toString() => 'AnthropicApiException($statusCode, $type, $message)';
}
