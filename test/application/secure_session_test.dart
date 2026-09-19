import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/failures.dart';
import 'package:gitscholar/infrastructure/local/secure_store.dart';

/// Storage that fails a given number of times before behaving.
class _FlakyStorage implements FlutterSecureStorage {
  _FlakyStorage({this.failReads = 0, this.dropWrites = false});

  final values = <String, String>{};
  int failReads;
  bool dropWrites;
  var reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    if (failReads > 0) {
      failReads--;
      throw PlatformException(code: 'decrypt');
    }
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (dropWrites) return; // 書けたふりをする
    if (value != null) values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('PlatformSecureStore', () {
    test('retries a read that fails once', () async {
      final flaky = _FlakyStorage(failReads: 1)
        ..values[SecureStore.githubToken] = 'tok';
      final store = PlatformSecureStore(flaky);
      expect(await store.read(SecureStore.githubToken), 'tok');
      expect(flaky.reads, 2, reason: '1度目は失敗し、再試行で成功する');
    });

    test('reports a read that keeps failing instead of returning null', () {
      final store = PlatformSecureStore(_FlakyStorage(failReads: 5));
      // null を返すと「保存されていない」と誤解され、サインアウトにつながる。
      expect(
        () => store.read(SecureStore.githubToken),
        throwsA(isA<SecureStorageFailure>()),
      );
    });

    test('reports a write that did not stick', () {
      final store = PlatformSecureStore(_FlakyStorage(dropWrites: true));
      // 握りつぶすと、セッションはメモリ上だけになり再起動で消える。
      expect(
        () => store.write(SecureStore.githubToken, 'tok'),
        throwsA(isA<SecureStorageFailure>()),
      );
    });

    test('a normal write can be read back', () async {
      final store = PlatformSecureStore(_FlakyStorage());
      await store.write(SecureStore.githubToken, 'tok');
      expect(await store.read(SecureStore.githubToken), 'tok');
    });
  });
}
