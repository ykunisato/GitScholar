import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'dto.dart';
import 'exception.dart';

/// Outcome of a single poll of the token endpoint.
sealed class DevicePollResult {
  const DevicePollResult();
}

/// What GitHub hands back when a sign-in succeeds.
///
/// An OAuth App token normally has no expiry, but a GitHub App token, and an
/// OAuth App token when the app opts into expiring tokens, lives for a few
/// hours and comes with a refresh token. Dropping those fields means the user
/// is signed out when the token dies (docs/04 §1.3).
class GitHubCredentials {
  /// Creates a set of credentials.
  const GitHubCredentials({
    required this.token,
    this.expiresIn,
    this.refreshToken,
    this.refreshTokenExpiresIn,
  });

  /// Reads the token response. Returns null when it carries no token.
  static GitHubCredentials? fromJson(Map<String, dynamic> j) {
    final token = j['access_token'];
    if (token is! String || token.isEmpty) return null;
    final refresh = j['refresh_token'];
    return GitHubCredentials(
      token: token,
      expiresIn: (j['expires_in'] as num?)?.toInt(),
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
      refreshTokenExpiresIn: (j['refresh_token_expires_in'] as num?)?.toInt(),
    );
  }

  /// The access token.
  final String token;

  /// Seconds the access token is valid for, or null when it does not expire.
  final int? expiresIn;

  /// Token that buys a new access token, when there is one.
  final String? refreshToken;

  /// Seconds the refresh token is valid for.
  final int? refreshTokenExpiresIn;

  /// When the access token dies, counted from [from].
  DateTime? expiresAt(DateTime from) =>
      expiresIn == null ? null : from.add(Duration(seconds: expiresIn!));

  /// Whether GitHub said this token expires.
  bool get expires => expiresIn != null;
}

/// The user authorised the device.
class DevicePollToken extends DevicePollResult {
  /// Creates a successful poll result.
  const DevicePollToken(this.credentials);

  /// Access token and, when the token expires, how to renew it.
  final GitHubCredentials credentials;

  /// The access token.
  String get token => credentials.token;
}

/// The user has not authorised yet. [interval] is the wait before the next
/// poll, raised when GitHub asks the client to slow down.
class DevicePollPending extends DevicePollResult {
  /// Creates a pending result.
  const DevicePollPending(this.interval);

  /// Seconds to wait before polling again.
  final int interval;
}

/// The flow cannot continue (expired code, denied, unknown client).
class DevicePollFailed extends DevicePollResult {
  /// Creates a terminal failure result.
  const DevicePollFailed(this.error);

  /// Why the flow cannot continue.
  final GitHubApiException error;
}

/// OAuth Device Flow. See docs/04_github_integration.md §1.
class GitHubDeviceFlow {
  /// Creates a device flow helper.
  GitHubDeviceFlow({
    required this.clientId,
    http.Client? client,
    this.baseUrl = 'https://github.com',
    this.timeout = const Duration(seconds: 20),
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _delay = delay ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  /// OAuth App client id.
  final String clientId;

  /// github.com base URL.
  final String baseUrl;

  /// How long a single request may take.
  ///
  /// Without it a stalled connection leaves the sign-in screen spinning with
  /// no way out but to start over.
  final Duration timeout;

  final http.Client _http;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;

  /// Requests a device and user code.
  Future<DeviceCodeResponse> requestCode({
    List<String> scopes = const ['repo', 'read:user'],
  }) async {
    final res = await _post('/login/device/code', {
      'client_id': clientId,
      'scope': scopes.join(' '),
    });
    final j = _decode(res);
    if (j['error'] != null) {
      throw GitHubApiException(
        res.statusCode,
        '${j['error_description'] ?? j['error']}',
        errorCode: '${j['error']}',
      );
    }
    return DeviceCodeResponse.fromJson(j);
  }

  /// Polls the token endpoint once, without waiting.
  ///
  /// Used when the app returns to the foreground after the user authorised
  /// in the browser, so sign-in finishes immediately.
  Future<DevicePollResult> pollOnce(
    DeviceCodeResponse code, {
    int? interval,
  }) async {
    final res = await _post('/login/oauth/access_token', {
      'client_id': clientId,
      'device_code': code.deviceCode,
      'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
    });
    final j = _decode(res);
    final credentials = GitHubCredentials.fromJson(j);
    if (credentials != null) return DevicePollToken(credentials);
    final current = interval ?? code.interval;
    switch (j['error']) {
      case 'authorization_pending':
        return DevicePollPending(current);
      case 'slow_down':
        return DevicePollPending(current + 5);
      default:
        return DevicePollFailed(
          GitHubApiException(
            res.statusCode,
            '${j['error_description'] ?? j['error']}',
            errorCode: '${j['error']}',
          ),
        );
    }
  }

  /// Polls until the user authorises, returning the access token.
  ///
  /// Completing [cancel] aborts with a `cancelled` [GitHubApiException].
  /// With [immediate] the first poll happens without waiting.
  Future<GitHubCredentials> pollForToken(
    DeviceCodeResponse code, {
    Future<void>? cancel,
    bool immediate = false,
  }) async {
    var cancelled = false;
    unawaited(cancel?.then((_) => cancelled = true));
    var interval = code.interval;
    var first = true;
    final deadline = _now().add(Duration(seconds: code.expiresIn));
    while (true) {
      if (!(first && immediate)) {
        await _delay(Duration(seconds: interval));
      }
      first = false;
      if (cancelled) {
        throw const GitHubApiException(0, 'cancelled', errorCode: 'cancelled');
      }
      if (_now().isAfter(deadline)) {
        throw const GitHubApiException(
          0,
          'Device code expired',
          errorCode: 'expired_token',
        );
      }
      final result = await pollOnce(code, interval: interval);
      switch (result) {
        case DevicePollToken(:final credentials):
          return credentials;
        case DevicePollPending(interval: final next):
          interval = next;
        case DevicePollFailed(:final error):
          throw error;
      }
    }
  }

  /// Exchanges a refresh token for a new access token (docs/04 §1.3).
  ///
  /// GitHub answers with `error: bad_refresh_token` once the refresh token
  /// itself has expired, which is a real sign-out.
  Future<GitHubCredentials> refresh(String refreshToken) async {
    final res = await _post('/login/oauth/access_token', {
      'client_id': clientId,
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    });
    final j = _decode(res);
    final credentials = GitHubCredentials.fromJson(j);
    if (credentials == null) {
      throw GitHubApiException(
        res.statusCode,
        '${j['error_description'] ?? j['error'] ?? 'Refresh failed'}',
        errorCode: '${j['error'] ?? 'refresh_failed'}',
      );
    }
    return credentials;
  }

  /// The current polling interval is exposed for tests via [pollForToken].
  Future<http.Response> _post(String path, Map<String, String> body) async {
    try {
      return await _http
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {'Accept': 'application/json'},
            body: body,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const GitHubApiException(0, 'timeout', errorCode: 'timeout');
    } on http.ClientException catch (e) {
      throw GitHubApiException(0, e.message);
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } on FormatException {
      throw GitHubApiException(res.statusCode, 'Unexpected response');
    }
  }
}
