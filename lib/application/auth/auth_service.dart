import 'dart:convert';

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

  /// Restores the session. Returns null when signed out. Uses the cached
  /// user when offline.
  Future<GitHubUser?> restore() async {
    final token = await secure.read(SecureStore.githubToken);
    if (token == null) return null;
    try {
      final user = await gatewayFor(token).currentUser();
      await _cacheUser(user);
      return user;
    } on AuthFailure {
      await secure.delete(SecureStore.githubToken);
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
      case DevicePollToken(:final token):
        return _finishSignIn(token);
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
    final String token;
    try {
      token = await deviceFlow().pollForToken(
        code,
        cancel: cancel,
        immediate: immediate,
      );
    } on GitHubApiException catch (e) {
      if (e.errorCode != 'cancelled') await clearPendingCode();
      throw AuthFailure(e.message, cause: e, code: e.errorCode);
    }
    return _finishSignIn(token);
  }

  Future<GitHubUser> _finishSignIn(String token) async {
    await secure.write(SecureStore.githubToken, token);
    await clearPendingCode();
    final user = await gatewayFor(token).currentUser();
    await _cacheUser(user);
    return user;
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
    await secure.delete(SecureStore.githubToken);
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
