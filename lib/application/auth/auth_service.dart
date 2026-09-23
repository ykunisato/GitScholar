import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:github_api/github_api.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/repositories/github_repository.dart';
import '../../infrastructure/github/github_gateway.dart';
import '../../infrastructure/local/app_database.dart';
import '../../infrastructure/local/blob_store.dart';
import '../../infrastructure/local/secure_store.dart';

/// Sign-in with GitHub Device Flow and sign-out (FR-10..12).
class AuthService {
  AuthService({
    required this.secure,
    required this.db,
    required this.blobs,
    required this.deviceFlow,
    required this.gatewayFor,
  });

  final SecureStore secure;
  final AppDatabase db;
  final BlobStore blobs;
  final GitHubDeviceFlow Function() deviceFlow;
  final GitHubRepository Function(String token) gatewayFor;

  static const _userKey = 'github_user';

  /// When the access token dies, when GitHub said it does. Not a secret: it
  /// is a timestamp, and it has to be readable before the token is used.
  static const _expiresAtKey = 'github_token_expires_at';

  /// Key of the authentication event trail (docs/09 §1).
  static const authLogKey = 'auth_log';

  /// How many events are kept.
  static const _authLogLimit = 30;

  /// Short fingerprint of a token, for the event trail.
  ///
  /// The token itself must never be written anywhere but secure storage
  /// (docs/09 §1). A hash prefix is enough to tell "GitHub rejected the token
  /// we stored" from "we read back something else".
  static String fingerprint(String token) =>
      '${sha256.convert(utf8.encode(token))}'.substring(0, 8);

  /// Appends an authentication event so that a sign-out happening hours later
  /// can be explained without reproducing it. Logcat is useless here: the
  /// buffer has rotated long before the user notices.
  Future<void> recordEvent(String reason, {String? detail}) async {
    try {
      final existing = await db.getValue(authLogKey);
      final entries = <Object?>[
        if (existing is List) ...existing,
        {
          'at': DateTime.now().toUtc().toIso8601String(),
          'reason': reason,
          'detail': ?detail,
        },
      ];
      await db.setValue(
        authLogKey,
        entries.length > _authLogLimit
            ? entries.sublist(entries.length - _authLogLimit)
            : entries,
      );
    } catch (_) {
      // 記録は補助。失敗しても認証の本筋は止めない。
    }
  }

  /// Restores the session. Returns null when signed out. Uses the cached
  /// user when offline.
  Future<GitHubUser?> restore() async {
    final String? token;
    try {
      token = await secure.read(SecureStore.githubToken);
    } on SecureStorageFailure catch (e) {
      // 保存領域が読めないだけ。トークンは消さず、次回の起動に賭ける。
      await recordEvent('restore_storage_failed', detail: e.message);
      return null;
    }
    if (token == null) {
      await recordEvent('restore_no_token_stored');
      return null;
    }
    // 期限切れが分かっているなら、断られるのを待たずに更新する。
    final expired = await _tokenExpired();
    if (expired) {
      final renewed = await _refresh('token_expired');
      if (renewed == null) return null;
      return _userFor(renewed);
    }
    try {
      final user = await gatewayFor(token).currentUser();
      await _cacheUser(user);
      return user;
    } on AuthFailure catch (e) {
      // 更新できるなら、拒否されただけではサインアウトにしない。
      final renewed = await _refresh(
        'rejected',
        detail: '${e.message} fp=${fingerprint(token)}',
      );
      if (renewed != null) return _userFor(renewed);
      // GitHub がこのトークンを拒否し、更新もできない。ここでだけ削除してよい。
      await recordEvent(
        'restore_rejected_by_github',
        detail: '${e.message} fp=${fingerprint(token)} len=${token.length}',
      );
      await _clearCredentials();
      return null;
    } on AppFailure {
      final cached = await db.getValue(_userKey);
      if (cached is Map) {
        return GitHubUser(
          login: cached['login'] as String,
          id: cached['id'] as int,
          avatarUrl: cached['avatarUrl'] as String? ?? '',
          name: cached['name'] as String?,
        );
      }
      rethrow;
    }
  }

  /// Whether the stored token is known to have expired.
  Future<bool> _tokenExpired() async {
    final raw = await db.getValue(_expiresAtKey);
    if (raw is! String) return false;
    final at = DateTime.tryParse(raw);
    // 時計のずれと往復の時間を見込んで、少し手前で切り替える。
    return at != null &&
        DateTime.now().toUtc().isAfter(at.subtract(const Duration(minutes: 1)));
  }

  /// Renews the access token while the app is running (docs/04 §1.3b).
  ///
  /// A token that lives 8 hours can die with the app open, and the request
  /// that hits the expiry gets a 401 like any other. Without this the user is
  /// signed out mid-session even though the session could continue.
  Future<String?> tryRefresh({String why = 'rejected_in_session'}) =>
      _refresh(why);

  /// Exchanges the stored refresh token for a new access token.
  ///
  /// Returns null when there is nothing to refresh or GitHub refuses, which
  /// is the only case that is a real sign-out.
  Future<String?> _refresh(String why, {String? detail}) async {
    final String? refreshToken;
    try {
      refreshToken = await secure.read(SecureStore.githubRefreshToken);
    } on SecureStorageFailure {
      return null;
    }
    if (refreshToken == null) return null;
    try {
      final credentials = await deviceFlow().refresh(refreshToken);
      await _storeCredentials(credentials);
      await recordEvent('token_refreshed', detail: why);
      return credentials.token;
    } on GitHubApiException catch (e) {
      await recordEvent(
        'refresh_failed',
        detail: '$why ${e.errorCode ?? ''} ${e.message}'.trim(),
      );
      if (e.statusCode == 0 && e.errorCode == 'timeout') return null;
      await _clearCredentials();
      return null;
    } on SecureStorageFailure {
      return null;
    }
  }

  Future<GitHubUser> _userFor(String token) async {
    final user = await gatewayFor(token).currentUser();
    await _cacheUser(user);
    return user;
  }

  Future<void> _storeCredentials(GitHubCredentials credentials) async {
    await secure.write(SecureStore.githubToken, credentials.token);
    final refresh = credentials.refreshToken;
    if (refresh != null) {
      await secure.write(SecureStore.githubRefreshToken, refresh);
    } else {
      await secure.delete(SecureStore.githubRefreshToken);
    }
    final expiresAt = credentials.expiresAt(DateTime.now().toUtc());
    if (expiresAt == null) {
      await db.deleteValue(_expiresAtKey);
    } else {
      await db.setValue(_expiresAtKey, expiresAt.toIso8601String());
    }
  }

  Future<void> _clearCredentials() async {
    await secure.delete(SecureStore.githubToken);
    await secure.delete(SecureStore.githubRefreshToken);
    await db.deleteValue(_expiresAtKey);
  }

  /// Device code of a sign-in still in progress, or null when there is none
  /// or it expired (the saved copy is then discarded).
  Future<DeviceCodeResponse?> pendingCode() async {
    final raw = await secure.read(SecureStore.githubDeviceCode);
    if (raw == null) return null;
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      await clearPendingCode();
      return null;
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      j['expires_at'] as int,
    );
    final remaining = expiresAt.difference(DateTime.now()).inSeconds;
    if (remaining <= 0) {
      await clearPendingCode();
      return null;
    }
    return DeviceCodeResponse(
      deviceCode: j['device_code'] as String,
      userCode: j['user_code'] as String,
      verificationUri: Uri.parse(j['verification_uri'] as String),
      expiresIn: remaining,
      interval: j['interval'] as int,
    );
  }

  /// Forgets a sign-in in progress.
  Future<void> clearPendingCode() =>
      secure.delete(SecureStore.githubDeviceCode);

  Future<void> _savePendingCode(DeviceCodeResponse code) => secure.write(
    SecureStore.githubDeviceCode,
    jsonEncode({
      'device_code': code.deviceCode,
      'user_code': code.userCode,
      'verification_uri': code.verificationUri.toString(),
      'interval': code.interval,
      'expires_at': DateTime.now()
          .add(Duration(seconds: code.expiresIn))
          .millisecondsSinceEpoch,
    }),
  );

  /// Polls once. Returns the user once the browser authorisation is done and
  /// null while it is still pending. Terminal errors clear the saved code.
  Future<GitHubUser?> pollOnce(DeviceCodeResponse code) async {
    final DevicePollResult result;
    try {
      result = await deviceFlow().pollOnce(code);
    } on GitHubApiException catch (e) {
      throw NetworkFailure(e.message, cause: e);
    }
    switch (result) {
      case DevicePollToken(:final credentials):
        return _finishSignIn(credentials);
      case DevicePollPending():
        return null;
      case DevicePollFailed(:final error):
        await clearPendingCode();
        throw AuthFailure(error.message, cause: error, code: error.errorCode);
    }
  }

  /// Requests a device code and remembers it, so the sign-in survives the
  /// app being backgrounded while the user authorises in the browser.
  Future<DeviceCodeResponse> start() async {
    try {
      final code = await deviceFlow().requestCode();
      await _savePendingCode(code);
      return code;
    } on GitHubApiException catch (e) {
      // GitHub answers 404 when the client id is unknown, and
      // device_flow_disabled when Device Flow is off for the OAuth App.
      if (e.statusCode == 404 || e.errorCode == 'device_flow_disabled') {
        throw AuthFailure(e.message, cause: e, code: 'invalid_client_id');
      }
      throw mapGitHubException(e);
    }
  }

  /// Polls until authorised, stores the token and returns the user.
  ///
  /// With [immediate] the first poll happens without waiting, which is what
  /// the app does when it returns from the browser.
  Future<GitHubUser> complete(
    DeviceCodeResponse code, {
    Future<void>? cancel,
    bool immediate = false,
  }) async {
    final GitHubCredentials credentials;
    try {
      credentials = await deviceFlow().pollForToken(
        code,
        cancel: cancel,
        immediate: immediate,
      );
    } on GitHubApiException catch (e) {
      if (e.errorCode != 'cancelled') await clearPendingCode();
      throw AuthFailure(e.message, cause: e, code: e.errorCode);
    }
    return _finishSignIn(credentials);
  }

  Future<GitHubUser> _finishSignIn(GitHubCredentials credentials) async {
    await _storeCredentials(credentials);
    // 何時間で切れるトークンなのかは、ここでしか分からない。
    await recordEvent(
      'signed_in',
      detail:
          'expires_in=${credentials.expiresIn ?? 'none'} '
          'refresh=${credentials.refreshToken == null ? 'no' : 'yes'} '
          'fp=${fingerprint(credentials.token)}',
    );
    await clearPendingCode();
    return _userFor(credentials.token);
  }

  Future<void> _cacheUser(GitHubUser u) => db.setValue(_userKey, {
    'login': u.login,
    'id': u.id,
    'avatarUrl': u.avatarUrl,
    'name': u.name,
  });

  /// Signs out: deletes the token, conversations and private-repo caches.
  /// Pending changes are deleted only when [deletePendingChanges] is true.
  Future<void> signOut({bool deletePendingChanges = false}) async {
    await _clearCredentials();
    await clearPendingCode();
    await db.deleteValue(_userKey);
    await db.deleteAllConversations();
    if (deletePendingChanges) await db.deleteAllPendingChanges();
    for (final repo in await db.allRepositories()) {
      if (repo.isPrivate) {
        await blobs.deleteForRepo(repo.fullName);
        await db.deleteRepositoryData(repo.fullName);
      }
    }
  }
}
