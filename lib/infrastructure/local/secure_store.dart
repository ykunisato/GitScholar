import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/failures.dart';

/// Secret storage (docs/09_security_privacy.md §1). Secrets must never be
/// written anywhere else.
abstract class SecureStore {
  static const githubToken = 'github_access_token';
  static const anthropicKey = 'anthropic_api_key';

  /// Key of the API key for [provider] (ADR-0010).
  static String apiKeyFor(String provider) => switch (provider) {
    'openai' => 'openai_api_key',
    'openrouter' => 'openrouter_api_key',
    'custom' => 'custom_llm_api_key',
    _ => anthropicKey,
  };
  static const jupyterToken = 'jupyter_token';

  /// Device code of a sign-in in progress, so it survives the app being
  /// backgrounded while the user authorises in the browser (FR-10).
  static const githubDeviceCode = 'github_device_code';

  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain / Android keystore implementation.
class PlatformSecureStore implements SecureStore {
  PlatformSecureStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // The default wipes every stored value when one read fails to
            // decrypt, which silently signs the user out (docs/09 §1).
            aOptions: AndroidOptions(resetOnError: false),
          );

  final FlutterSecureStorage _storage;

  /// Reads [key], retrying once because the Android keystore occasionally
  /// fails a single call after the app is restarted.
  ///
  /// Throws [SecureStorageFailure] when it cannot be read. A failure must not
  /// be reported as null: callers would take it for "nothing stored" and sign
  /// the user out, and the stored token would then be deleted as stale.
  @override
  Future<String?> read(String key) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _storage.read(key: key);
      } on PlatformException catch (e) {
        if (attempt >= 1) {
          throw SecureStorageFailure('Could not read $key', cause: e);
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  /// Writes [key] and reads it back.
  ///
  /// Without the read back, a failed write leaves the session alive only in
  /// memory: everything works until the process is killed, and the user is
  /// then signed out for no visible reason.
  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException catch (e) {
      throw SecureStorageFailure('Could not write $key', cause: e);
    }
    final stored = await read(key);
    if (stored != value) {
      throw SecureStorageFailure('$key was not stored');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException {
      // Nothing to do.
    }
  }
}

/// In-memory implementation for tests.
class InMemorySecureStore implements SecureStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
