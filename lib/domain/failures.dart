/// Application failures (docs/02_architecture.md §7).
///
/// Infrastructure converts library exceptions into these; presentation shows
/// them via FailureView.
sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.cause});

  /// Human readable message (English; UI maps kinds to localized text).
  final String message;

  /// Underlying error.
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// Connection failure or timeout.
class NetworkFailure extends AppFailure {
  const NetworkFailure(super.message, {super.cause});
}

/// Invalid or revoked credentials.
class AuthFailure extends AppFailure {
  const AuthFailure(super.message, {super.cause, this.code});

  /// Optional machine-readable code (e.g. `expired_token`).
  final String? code;
}

/// The secure storage could not be read or written. This is **not** the
/// same as "no value stored": treating it as absent silently signs the user
/// out and can delete a still-valid token (docs/09 §1).
class SecureStorageFailure extends AppFailure {
  const SecureStorageFailure(super.message, {super.cause});
}

/// Rate limit exhausted.
class RateLimitFailure extends AppFailure {
  const RateLimitFailure(super.message, {super.cause, this.resetAt});

  /// When requests may resume.
  final DateTime? resetAt;
}

/// Missing resource.
class NotFoundFailure extends AppFailure {
  const NotFoundFailure(super.message, {super.cause});
}

/// Remote changed concurrently (docs/06_editing_diff_commit.md §4).
class ConflictFailure extends AppFailure {
  const ConflictFailure(
    super.message, {
    super.cause,
    this.conflictingPaths = const [],
  });

  /// Paths changed both locally and remotely.
  final List<String> conflictingPaths;
}

/// Invalid input, parse error, or unsupported file.
class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.cause});
}

/// AI request failed or was refused.
class AiFailure extends AppFailure {
  const AiFailure(super.message, {super.cause, this.stopReason});

  /// Stop reason when the model declined.
  final String? stopReason;
}

/// Anything else.
class UnknownFailure extends AppFailure {
  const UnknownFailure(super.message, {super.cause});
}
