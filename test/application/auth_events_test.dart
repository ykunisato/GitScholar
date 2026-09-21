import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/application/auth/auth_service.dart';
import 'package:gitscholar/infrastructure/local/secure_store.dart';

import '../fakes/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  AuthService serviceFor() => AuthService(
    secure: InMemorySecureStore(),
    db: env.db,
    blobs: env.blobs,
    deviceFlow: () => throw UnimplementedError(),
    gatewayFor: (_) => env.github,
  );

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
}
