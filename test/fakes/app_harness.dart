import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/infrastructure/local/secure_store.dart';
import 'package:gitscholar/l10n/app_localizations.dart';
import 'package:gitscholar/presentation/core/providers.dart';
import 'package:gitscholar/presentation/core/theme.dart';
import 'package:scholar_agent/scholar_agent.dart';

import 'fake_anthropic.dart';
import 'test_env.dart';

/// Signed-in auth controller for widget tests.
class SignedInAuth extends AuthController {
  @override
  Future<AuthState> build() async =>
      SignedIn(const GitHubUser(login: 'alice', id: 1, avatarUrl: ''));
}

/// Builds a ProviderScope wired to [env] and optional [anthropic].
Widget harness(
  TestEnv env, {
  required Widget child,
  FakeAnthropic? anthropic,
  InMemorySecureStore? secure,
  Size size = const Size(1200, 800),
  List<dynamic> extraOverrides = const [],
  AuthController Function() auth = SignedInAuth.new,
}) {
  final store =
      secure ??
      (InMemorySecureStore()..values[SecureStore.githubToken] = 'tok');
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(env.db),
      blobStoreProvider.overrideWithValue(env.blobs),
      secureStoreProvider.overrideWithValue(store),
      githubGatewayFactoryProvider.overrideWithValue((_) => env.github),
      githubTokenProvider.overrideWith(() => GitHubTokenController('tok')),
      authControllerProvider.overrideWith(auth),
      if (anthropic != null)
        anthropicClientFactoryProvider.overrideWithValue(
          (key) => AnthropicClient.withApiKey(key, client: anthropic.client),
        ),
      ...extraOverrides,
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: child,
      ),
    ),
  );
}
