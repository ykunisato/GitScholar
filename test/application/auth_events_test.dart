import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:github_api/github_api.dart';
import 'package:gitscholar/application/auth/auth_service.dart';
import 'package:gitscholar/domain/failures.dart';
import 'package:gitscholar/infrastructure/local/secure_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fakes/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  AuthService serviceFor({
    InMemorySecureStore? secure,
    GitHubDeviceFlow Function()? deviceFlow,
  }) => AuthService(
    secure: secure ?? InMemorySecureStore(),
    db: env.db,
    blobs: env.blobs,
    deviceFlow: deviceFlow ?? () => throw UnimplementedError(),
    gatewayFor: (_) => env.github,
  );

  /// Device flow answering every token request with [body].
  GitHubDeviceFlow flowReturning(
    Map<String, dynamic> body, {
    List<String>? bodies,
  }) => GitHubDeviceFlow(
    clientId: 'cid',
    client: MockClient((req) async {
      bodies?.add(req.body);
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  List<Map<String, Object?>> logOf(List<Object?> raw) => [
    for (final e in raw) (e! as Map).cast<String, Object?>(),
  ];

  Future<List<Map<String, Object?>>> events() async =>
      logOf(await env.db.getValue(AuthService.authLogKey) as List);

  test('records events in order and keeps the newest', () async {
    final auth = serviceFor();
    for (var i = 0; i < 35; i++) {
      await auth.recordEvent('event_$i');
    }
    final log = await env.db.getValue(AuthService.authLogKey) as List;
    expect(log, hasLength(30), reason: '古いものから捨てる');
    expect((log.first as Map)['reason'], 'event_5');
    expect((log.last as Map)['reason'], 'event_34');
    expect((log.last as Map)['at'], isA<String>());
  });

  test('keeps the detail when given', () async {
    final auth = serviceFor();
    await auth.recordEvent('restore_storage_failed', detail: 'boom');
    final log = await env.db.getValue(AuthService.authLogKey) as List;
    expect((log.single as Map)['detail'], 'boom');
  });

  group('expiring tokens', () {
    test('a sign-in records the expiry and keeps the refresh token', () async {
      final secure = InMemorySecureStore();
      final auth = serviceFor(
        secure: secure,
        deviceFlow: () => flowReturning({
          'access_token': 'ghu_x',
          'expires_in': 28800,
          'refresh_token': 'ghr_y',
        }),
      );
      await auth.complete(
        DeviceCodeResponse(
          deviceCode: 'd',
          userCode: 'U',
          verificationUri: Uri.parse('https://github.com/login/device'),
          expiresIn: 900,
          interval: 0,
        ),
        immediate: true,
      );

      expect(secure.values[SecureStore.githubToken], 'ghu_x');
      expect(secure.values[SecureStore.githubRefreshToken], 'ghr_y');
      final signedIn = (await events()).last;
      expect(signedIn['reason'], 'signed_in');
      expect(signedIn['detail'], contains('expires_in=28800'));
      expect(signedIn['detail'], contains('refresh=yes'));
      // トークンそのものは記録に残さない。
      expect(signedIn['detail'], isNot(contains('ghu_x')));
    });

    test('a rejected token is refreshed instead of signing out', () async {
      final secure = InMemorySecureStore()
        ..values[SecureStore.githubToken] = 'ghu_old'
        ..values[SecureStore.githubRefreshToken] = 'ghr_old';
      final bodies = <String>[];
      final auth = serviceFor(
        secure: secure,
        deviceFlow: () => flowReturning({
          'access_token': 'ghu_new',
          'expires_in': 28800,
          'refresh_token': 'ghr_new',
        }, bodies: bodies),
      );
      env.github.failNext = const AuthFailure('Bad credentials');

      final user = await auth.restore();
      expect(user, isNotNull, reason: 'サインインは続く');
      expect(secure.values[SecureStore.githubToken], 'ghu_new');
      expect(secure.values[SecureStore.githubRefreshToken], 'ghr_new');
      expect(bodies.single, contains('grant_type=refresh_token'));
      expect(
        (await events()).map((e) => e['reason']),
        contains('token_refreshed'),
      );
    });

    test('an expired token is refreshed before it is used', () async {
      final secure = InMemorySecureStore()
        ..values[SecureStore.githubToken] = 'ghu_old'
        ..values[SecureStore.githubRefreshToken] = 'ghr_old';
      final auth = serviceFor(
        secure: secure,
        deviceFlow: () =>
            flowReturning({'access_token': 'ghu_new', 'expires_in': 28800}),
      );
      await env.db.setValue(
        'github_token_expires_at',
        DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
      );

      expect(await auth.restore(), isNotNull);
      expect(secure.values[SecureStore.githubToken], 'ghu_new');
      // 期限切れと分かっているので、断られるのを待たない。
      expect(env.github.calls, isNot(contains('user_rejected')));
      final reasons = (await events()).map((e) => e['reason']).toList();
      expect(reasons, contains('token_refreshed'));
      expect(reasons, isNot(contains('restore_rejected_by_github')));
    });

    test('mid-session renewal keeps the stored token usable', () async {
      // アプリを開いたまま8時間経つと、復帰ではなく普通のAPI呼び出しが
      // 401を受け取る。そこからでも更新できる。
      final secure = InMemorySecureStore()
        ..values[SecureStore.githubToken] = 'ghu_old'
        ..values[SecureStore.githubRefreshToken] = 'ghr_old';
      final auth = serviceFor(
        secure: secure,
        deviceFlow: () =>
            flowReturning({'access_token': 'ghu_new', 'expires_in': 28800}),
      );

      expect(await auth.tryRefresh(), 'ghu_new');
      expect(secure.values[SecureStore.githubToken], 'ghu_new');
      expect((await events()).last['reason'], 'token_refreshed');
    });

    test('nothing to renew without a refresh token', () async {
      final auth = serviceFor(
        secure: InMemorySecureStore()
          ..values[SecureStore.githubToken] = 'gho_old',
      );
      expect(await auth.tryRefresh(), isNull);
    });

    test('an expired refresh token is a real sign-out', () async {
      final secure = InMemorySecureStore()
        ..values[SecureStore.githubToken] = 'ghu_old'
        ..values[SecureStore.githubRefreshToken] = 'ghr_old';
      final auth = serviceFor(
        secure: secure,
        deviceFlow: () => flowReturning({'error': 'bad_refresh_token'}),
      );
      env.github.failNext = const AuthFailure('Bad credentials');

      expect(await auth.restore(), isNull);
      expect(secure.values[SecureStore.githubToken], isNull);
      expect(secure.values[SecureStore.githubRefreshToken], isNull);
      expect(
        (await events()).map((e) => e['reason']),
        contains('refresh_failed'),
      );
    });

    test(
      'without a refresh token the rejection is recorded as before',
      () async {
        final secure = InMemorySecureStore()
          ..values[SecureStore.githubToken] = 'ghu_old';
        final auth = serviceFor(secure: secure);
        env.github.failNext = const AuthFailure('Bad credentials');

        expect(await auth.restore(), isNull);
        final last = (await events()).last;
        expect(last['reason'], 'restore_rejected_by_github');
        expect(last['detail'], contains('Bad credentials'));
        expect(last['detail'], contains('fp='));
        expect(last['detail'], isNot(contains('ghu_old')));
      },
    );
  });
}
