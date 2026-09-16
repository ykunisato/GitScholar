import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/presentation/core/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:github_api/github_api.dart';
import 'package:gitscholar/application/auth/auth_service.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/failures.dart';
import 'package:gitscholar/infrastructure/local/secure_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fakes/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  AuthService service(http.Client client, {SecureStore? secure}) => AuthService(
    secure: secure ?? InMemorySecureStore(),
    db: env.db,
    blobs: env.blobs,
    deviceFlow: () => GitHubDeviceFlow(
      clientId: 'bogus',
      client: client,
      delay: (_) async {},
    ),
    gatewayFor: (_) => env.github,
  );

  http.Client json(String body, {int status = 200}) => MockClient(
    (_) async => http.Response(
      body,
      status,
      headers: {'content-type': 'application/json'},
    ),
  );

  test('unknown client id gives a specific failure', () async {
    await expectLater(
      service(json('{"error":"Not Found"}', status: 404)).start(),
      throwsA(
        isA<AuthFailure>().having((e) => e.code, 'code', 'invalid_client_id'),
      ),
    );
  });

  test('device flow disabled gives the same failure', () async {
    await expectLater(
      service(
        json(
          '{"error":"device_flow_disabled","error_description":"Device flow is not enabled"}',
        ),
      ).start(),
      throwsA(
        isA<AuthFailure>().having((e) => e.code, 'code', 'invalid_client_id'),
      ),
    );
  });

  test('restore without a token returns null', () async {
    expect(await service(json('{}')).restore(), isNull);
    expect(env.github.calls, isEmpty);
  });

  test('restore deletes a revoked token', () async {
    final secure = InMemorySecureStore()
      ..values[SecureStore.githubToken] = 'revoked';
    env.github.failNext = const AuthFailure('Bad credentials');
    expect(await service(json('{}'), secure: secure).restore(), isNull);
    expect(secure.values.containsKey(SecureStore.githubToken), isFalse);
  });

  test('restore falls back to the cached user when offline', () async {
    final secure = InMemorySecureStore()
      ..values[SecureStore.githubToken] = 'tok';
    final s = service(json('{}'), secure: secure);
    expect((await s.restore())!.login, 'alice');
    env.github.failNext = const NetworkFailure('offline');
    expect((await s.restore())!.login, 'alice');
  });

  test('sign in stores the token and returns the user', () async {
    final secure = InMemorySecureStore();
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/login/device/code')) {
        return http.Response(
          '{"device_code":"dc","user_code":"ABCD-1234",'
          '"verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"access_token":"gho_test"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final s = service(client, secure: secure);
    final code = await s.start();
    expect(code.userCode, 'ABCD-1234');
    final user = await s.complete(code);
    expect(user.login, 'alice');
    expect(secure.values[SecureStore.githubToken], 'gho_test');
  });

  test(
    'start remembers the device code so sign-in survives the browser trip',
    () async {
      final secure = InMemorySecureStore();
      final s = service(
        json(
          '{"device_code":"dc","user_code":"ABCD-1234",'
          '"verification_uri":"https://github.com/login/device",'
          '"expires_in":900,"interval":5}',
        ),
        secure: secure,
      );
      final code = await s.start();
      expect(secure.values[SecureStore.githubDeviceCode], isNotNull);
      final saved = await s.pendingCode();
      expect(saved!.deviceCode, code.deviceCode);
      expect(saved.userCode, 'ABCD-1234');
      expect(saved.interval, 5);
      expect(saved.expiresIn, lessThanOrEqualTo(900));
    },
  );

  test('a saved code that expired is discarded', () async {
    final secure = InMemorySecureStore()
      ..values[SecureStore.githubDeviceCode] = jsonEncode({
        'device_code': 'dc',
        'user_code': 'AB',
        'verification_uri': 'https://github.com/login/device',
        'interval': 5,
        'expires_at': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      });
    final s = service(json('{}'), secure: secure);
    expect(await s.pendingCode(), isNull);
    expect(secure.values.containsKey(SecureStore.githubDeviceCode), isFalse);
  });

  test('a corrupt saved code is discarded', () async {
    final secure = InMemorySecureStore()
      ..values[SecureStore.githubDeviceCode] = 'not json';
    expect(await service(json('{}'), secure: secure).pendingCode(), isNull);
    expect(secure.values.containsKey(SecureStore.githubDeviceCode), isFalse);
  });

  test('pollOnce finishes sign-in after the user authorises', () async {
    final secure = InMemorySecureStore();
    var authorised = false;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/login/device/code')) {
        return http.Response(
          '{"device_code":"dc","user_code":"AB",'
          '"verification_uri":"https://github.com/login/device",'
          '"expires_in":900,"interval":5}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        authorised
            ? '{"access_token":"gho_done"}'
            : '{"error":"authorization_pending"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final s = service(client, secure: secure);
    final code = await s.start();
    expect(
      await s.pollOnce(code),
      isNull,
      reason: 'still waiting for the browser',
    );
    expect(secure.values[SecureStore.githubDeviceCode], isNotNull);
    authorised = true;
    final user = await s.pollOnce(code);
    expect(user!.login, 'alice');
    expect(secure.values[SecureStore.githubToken], 'gho_done');
    expect(
      secure.values.containsKey(SecureStore.githubDeviceCode),
      isFalse,
      reason: 'the finished sign-in is forgotten',
    );
  });

  test('a denied authorisation clears the saved code', () async {
    final secure = InMemorySecureStore();
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/login/device/code')) {
        return http.Response(
          '{"device_code":"dc","user_code":"AB",'
          '"verification_uri":"https://github.com/login/device",'
          '"expires_in":900,"interval":5}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"error":"access_denied"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final s = service(client, secure: secure);
    final code = await s.start();
    await expectLater(
      s.pollOnce(code),
      throwsA(
        isA<AuthFailure>().having((e) => e.code, 'code', 'access_denied'),
      ),
    );
    expect(secure.values.containsKey(SecureStore.githubDeviceCode), isFalse);
  });

  test('sign out forgets a sign-in in progress', () async {
    final secure = InMemorySecureStore()
      ..values[SecureStore.githubToken] = 'tok'
      ..values[SecureStore.githubDeviceCode] = '{}';
    await service(json('{}'), secure: secure).signOut();
    expect(secure.values.containsKey(SecureStore.githubDeviceCode), isFalse);
  });

  group('resume after the browser trip', () {
    /// Regression: on some devices secure storage comes back empty while the
    /// app is in the browser. Sign-in must still finish, and a sign-in in
    /// progress must never be downgraded to signed out.
    ProviderContainer containerFor({
      required InMemorySecureStore secure,
      required http.Client client,
    }) {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(env.db),
          blobStoreProvider.overrideWithValue(env.blobs),
          secureStoreProvider.overrideWithValue(secure),
          githubGatewayFactoryProvider.overrideWithValue((_) => env.github),
          deviceFlowFactoryProvider.overrideWithValue(
            () => GitHubDeviceFlow(
              clientId: 'cid',
              client: client,
              delay: (_) =>
                  Future<void>.delayed(const Duration(milliseconds: 20)),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('keeps waiting when storage lost the code, then signs in', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      var authorised = false;
      // A sign-in was already started before the app went to the browser.
      final secure = InMemorySecureStore()
        ..values[SecureStore.githubDeviceCode] = jsonEncode({
          'device_code': 'dc',
          'user_code': 'AB',
          'verification_uri': 'https://github.com/login/device',
          'interval': 1,
          'expires_at': DateTime.now()
              .add(const Duration(minutes: 10))
              .millisecondsSinceEpoch,
        });
      final client = MockClient(
        (req) async => http.Response(
          authorised
              ? '{"access_token":"gho_ok"}'
              : '{"error":"authorization_pending"}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final container = containerFor(secure: secure, client: client);

      // Building the controller restores the code screen and resumes polling.
      await container.read(authControllerProvider.future);
      final controller = container.read(authControllerProvider.notifier);
      expect(
        container.read(authControllerProvider).value,
        isA<PendingDeviceCode>(),
        reason: 'an interrupted sign-in is picked up again',
      );

      // The device wipes secure storage while the browser is in front.
      secure.values.clear();
      await controller.onResumed();
      expect(
        container.read(authControllerProvider).value,
        isA<PendingDeviceCode>(),
        reason: 'losing the saved code must not cancel the sign-in',
      );

      // Coming back after authorising finishes sign-in from the kept code.
      authorised = true;
      await controller.onResumed();
      expect(container.read(authControllerProvider).value, isA<SignedIn>());
      expect(secure.values[SecureStore.githubToken], 'gho_ok');
      controller.cancelSignIn();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  test('sign out clears token, conversations and private caches', () async {
    final secure = InMemorySecureStore()
      ..values[SecureStore.githubToken] = 'tok';
    env.github.seed({'a.md': 'x'});
    final ws = await env.open();
    await env.workspaces.loadFile(ws, 'a.md');
    await env.db.putConversation(
      Conversation(
        id: 'c',
        repoFullName: ws.repo.fullName,
        title: 't',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    expect(await env.blobs.sizeForRepo(ws.repo.fullName), greaterThan(0));
    await service(json('{}'), secure: secure).signOut();
    expect(secure.values.containsKey(SecureStore.githubToken), isFalse);
    expect(await env.db.conversationsFor(ws.repo.fullName), isEmpty);
    expect(
      await env.blobs.sizeForRepo(ws.repo.fullName),
      0,
      reason: 'private repo cache is cleared',
    );
    expect(await env.db.loadWorkspace(ws.repo, 'main'), isNull);
  });
}
