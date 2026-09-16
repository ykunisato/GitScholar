import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'domain/entities/entities.dart';
import 'presentation/agent/conversation_list_screen.dart';
import 'presentation/auth/sign_in_screen.dart';
import 'presentation/core/providers.dart';
import 'presentation/editing/changes_screen.dart';
import 'presentation/execution/execution_log_screen.dart';
import 'presentation/repositories/repository_list_screen.dart';
import 'presentation/settings/settings_screen.dart';
import 'presentation/workspace/workspace_shell.dart';

class _AuthRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Routes (docs/08_ui_spec.md §1).
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh();
  ref.listen(authControllerProvider, (_, _) => refresh.ping());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/repos',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loc = state.matchedLocation;
      if (auth.isLoading && auth.value == null) {
        return loc == '/splash' ? null : '/splash';
      }
      final signedIn = auth.value is SignedIn;
      if (!signedIn) return loc == '/signin' ? null : '/signin';
      if (loc == '/signin' || loc == '/splash') return '/repos';
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (_, _) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      GoRoute(path: '/signin', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/repos', builder: (_, _) => const RepositoryListScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(
        path: '/ws/:owner/:repo',
        builder: (_, s) => WorkspaceShell(
          owner: s.pathParameters['owner']!,
          name: s.pathParameters['repo']!,
          branch: s.uri.queryParameters['branch'],
          initialPath: s.uri.queryParameters['path'],
        ),
        routes: [
          GoRoute(path: 'changes', builder: (_, _) => const ChangesScreen()),
          GoRoute(
            path: 'changes/:id',
            builder: (_, s) => DiffScreen(changeId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: 'conversations',
            builder: (_, _) => const ConversationListScreen(),
          ),
          GoRoute(path: 'runs', builder: (_, _) => const ExecutionLogScreen()),
        ],
      ),
    ],
  );
});
