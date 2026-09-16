/// Error returned by the GitHub API or transport.
class GitHubApiException implements Exception {
  /// Creates the exception.
  const GitHubApiException(
    this.statusCode,
    this.message, {
    this.headers = const {},
    this.errorCode,
  });

  /// HTTP status, or 0 for transport errors.
  final int statusCode;

  /// Message from the response body or transport.
  final String message;

  /// Response headers (lowercase keys).
  final Map<String, String> headers;

  /// OAuth error code (Device Flow), e.g. `expired_token`.
  final String? errorCode;

  /// Whether this is a transport-level failure (no HTTP response).
  bool get isNetworkError => statusCode == 0 && errorCode == null;

  /// Whether the response indicates an exhausted rate limit.
  bool get isRateLimited =>
      (statusCode == 403 || statusCode == 429) &&
      (headers['x-ratelimit-remaining'] == '0' ||
          headers.containsKey('retry-after'));

  /// When the rate limit resets, if known.
  DateTime? get rateLimitResetAt {
    final retry = int.tryParse(headers['retry-after'] ?? '');
    if (retry != null) return DateTime.now().add(Duration(seconds: retry));
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (reset != null) {
      return DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
    }
    return null;
  }

  @override
  String toString() => 'GitHubApiException($statusCode, $message)';
}
