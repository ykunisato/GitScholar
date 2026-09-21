import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'dto.dart';
import 'exception.dart';

/// Outcome of a single poll of the token endpoint.
sealed class DevicePollResult {
  const DevicePollResult();
}

/// The user authorised the device.
class DevicePollToken extends DevicePollResult {
  /// Creates a successful poll result.
  const DevicePollToken(this.token);

  /// The access token.
  final String token;
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
    final token = j['access_token'];
    if (token is String && token.isNotEmpty) return DevicePollToken(token);
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
  Future<String> pollForToken(
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
        case DevicePollToken(:final token):
          return token;
        case DevicePollPending(interval: final next):
          interval = next;
        case DevicePollFailed(:final error):
          throw error;
      }
    }
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
