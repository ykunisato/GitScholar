import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secret storage (docs/09_security_privacy.md §1). Secrets must never be
/// written anywhere else.
abstract class SecureStore {
  static const githubToken = 'github_access_token';
  static const anthropicKey = 'anthropic_api_key';
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

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException {
      // A value we cannot decrypt is as good as absent.
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException {
      // Storage problems must not break sign-in; the session still works.
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
