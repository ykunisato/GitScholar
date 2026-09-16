import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:github_api/github_api.dart';
import 'package:http/http.dart' as http;
import 'package:scholar_agent/scholar_agent.dart';

import '../../application/agent/agent_service.dart';
import '../../application/offline/offline_service.dart';
import '../../application/repositories/pin_service.dart';
import '../../application/auth/auth_service.dart';
import '../../application/editing/change_diff.dart';
import '../../application/editing/commit_service.dart';
import '../../application/editing/editing_service.dart';
import '../../application/editing/pdf_sidecar_service.dart';
import '../../application/threads/thread_service.dart';
import '../../application/execution/execution_service.dart';
import '../../application/workspace/workspace_service.dart';
import '../../config.dart';
import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/repositories/github_repository.dart';
import '../../domain/services/ignore_rules.dart';
import '../../infrastructure/execution/jupyter_client.dart';
import '../../infrastructure/github/github_gateway.dart';
import '../../infrastructure/local/app_database.dart';
import '../../infrastructure/local/blob_store.dart';
import '../../infrastructure/local/secure_store.dart';
import '../../infrastructure/local/settings_store.dart';
import '../../infrastructure/logging/app_logger.dart';

// ------------------------------------------------------------ infrastructure
// Overridden in main.dart and in tests.

final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider'),
);
final blobStoreProvider = Provider<BlobStore>(
  (ref) => throw UnimplementedError('blobStoreProvider'),
);
final secureStoreProvider = Provider<SecureStore>(
  (ref) => PlatformSecureStore(),
);
final loggerProvider = Provider<AppLogger>((ref) => AppLogger());

final httpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

/// Builds a GitHub gateway for a token (overridable for tests).
final githubGatewayFactoryProvider =
    Provider<GitHubRepository Function(String token)>((ref) {
      final db = ref.watch(databaseProvider);
      final client = ref.watch(httpClientProvider);
      return (token) {
        late final GitHubGateway gateway;
        gateway = GitHubGateway(
          GitHubClient(
            token: token,
            client: client,
            etagCache: DriftETagCache(db),
            onRateLimit: (remaining, _) =>
                gateway.rateLimitRemaining = remaining,
          ),
        );
        return gateway;
      };
    });

/// Device Flow factory (overridable for tests).
final deviceFlowFactoryProvider = Provider<GitHubDeviceFlow Function()>((ref) {
  final client = ref.watch(httpClientProvider);
  return () =>
      GitHubDeviceFlow(clientId: AppConfig.githubClientId, client: client);
});

/// Model client factory for the configured provider (ADR-0010).
/// Overridable for tests.
final llmClientFactoryProvider = Provider<LlmClient Function(String apiKey)>((
  ref,
) {
  final client = ref.watch(httpClientProvider);
  final settings = ref.watch(currentSettingsProvider);
  return (key) => buildLlmClient(
    provider: settings.aiProvider,
    apiKey: key,
    baseUrl: settings.aiBaseUrl,
    client: client,
  );
});

/// Creates the client for [provider]. OpenAI, OpenRouter and self-hosted
/// servers all speak the same chat completions API.
LlmClient buildLlmClient({
  required String provider,
  required String apiKey,
  String? baseUrl,
  http.Client? client,
}) {
  final url = (baseUrl ?? '').trim();
  switch (provider) {
    case 'openai':
      return OpenAiClient(
        apiKey: apiKey,
        baseUrl: url.isEmpty ? OpenAiClient.openAiBaseUrl : url,
        client: client,
      );
    case 'openrouter':
      return OpenAiClient(
        apiKey: apiKey,
        baseUrl: url.isEmpty ? OpenAiClient.openRouterBaseUrl : url,
        client: client,
        extraHeaders: const {
          'HTTP-Referer': 'https://github.com/ykunisato/GitScholar',
          'X-Title': 'GitScholar',
        },
      );
    case 'custom':
      return OpenAiClient(
        apiKey: apiKey,
        baseUrl: url.isEmpty ? OpenAiClient.openAiBaseUrl : url,
        client: client,
      );
    default:
      return AnthropicClient.withApiKey(apiKey, client: client);
  }
}

/// Model ids offered for [provider]; empty means free text.
List<String> modelChoicesFor(String provider) =>
    provider == 'anthropic' ? ClaudeModels.all : const [];

/// Default model when switching to [provider].
String defaultModelFor(String provider) =>
    provider == 'anthropic' ? ClaudeModels.opus5 : '';

// ------------------------------------------------------------------ settings

class SettingsController extends AsyncNotifier<Settings> {
  @override
  Future<Settings> build() => SettingsStore(ref.watch(databaseProvider)).load();

  Future<void> change(Settings Function(Settings) update) async {
    final next = update(state.value ?? const Settings());
    state = AsyncData(next);
    await SettingsStore(ref.read(databaseProvider)).save(next);
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsController, Settings>(
  SettingsController.new,
);

/// Settings with defaults while loading.
final currentSettingsProvider = Provider<Settings>(
  (ref) => ref.watch(settingsProvider).value ?? const Settings(),
);

// --------------------------------------------------------------------- auth

/// The GitHub token, loaded at startup and updated on sign-in/out.
class GitHubTokenController extends Notifier<String?> {
  GitHubTokenController([this.initial]);

  final String? initial;

  @override
  String? build() => initial;

  void set(String? token) => state = token;
}

final githubTokenProvider = NotifierProvider<GitHubTokenController, String?>(
  GitHubTokenController.new,
);

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(
    secure: ref.watch(secureStoreProvider),
    db: ref.watch(databaseProvider),
    blobs: ref.watch(blobStoreProvider),
    deviceFlow: ref.watch(deviceFlowFactoryProvider),
    gatewayFor: ref.watch(githubGatewayFactoryProvider),
  );
});

class AuthController extends AsyncNotifier<AuthState> {
  Completer<void>? _cancel;
  AppLifecycleListener? _lifecycle;
  bool _pollingOnResume = false;

  /// Device code of the sign-in running in this session. Kept in memory so
  /// the flow survives even when secure storage cannot return it.
  DeviceCodeResponse? _pendingCode;

  @override
  Future<AuthState> build() async {
    // Signing in involves a trip to the browser, so this provider must
    // outlive the screens that watch it.
    ref.keepAlive();
    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(onResumed()));
    ref.onDispose(() {
      _lifecycle?.dispose();
      _lifecycle = null;
    });

    final service = ref.read(authServiceProvider);
    final user = await service.restore();
    final token = await ref
        .read(secureStoreProvider)
        .read(SecureStore.githubToken);
    ref.read(githubTokenProvider.notifier).set(token);
    if (user != null) return SignedIn(user);

    // The device can freeze or kill the app while the browser is in front,
    // so a sign-in may be waiting to be finished (FR-10).
    final pending = await service.pendingCode();
    if (pending != null) {
      unawaited(_resume(pending));
      return PendingDeviceCode(
        userCode: pending.userCode,
        verificationUri: pending.verificationUri,
        expiresAt: DateTime.now().add(Duration(seconds: pending.expiresIn)),
      );
    }
    return const SignedOut();
  }

  /// Continues polling for a device code saved by an earlier run.
  Future<void> _resume(DeviceCodeResponse code) async {
    _pendingCode = code;
    _cancel = Completer<void>();
    try {
      final user = await ref
          .read(authServiceProvider)
          .complete(code, cancel: _cancel!.future, immediate: true);
      await _onSignedIn(user);
    } on AuthFailure catch (e, st) {
      // The screen (and this provider) can be gone by now.
      if (!ref.mounted) return;
      state = e.code == 'cancelled'
          ? const AsyncData(SignedOut())
          : AsyncError(e, st);
    } on AppFailure {
      // Offline: keep showing the code and retry on the next resume.
    }
  }

  /// Polls once when the app returns from the browser, so sign-in finishes
  /// as soon as the user comes back.
  Future<void> onResumed() async {
    if (_pollingOnResume || state.value is! PendingDeviceCode) return;
    final service = ref.read(authServiceProvider);
    // Prefer the code held in memory: secure storage can come back empty on
    // some devices, and losing it must not abort a sign-in in progress.
    final code = _pendingCode ?? await service.pendingCode();
    if (code == null) return;
    _pollingOnResume = true;
    try {
      final user = await service.pollOnce(code);
      if (user != null) await _onSignedIn(user);
    } on AuthFailure catch (e, st) {
      if (!ref.mounted) return;
      state = AsyncError(e, st);
    } on AppFailure {
      // Offline: the running loop retries.
    } finally {
      _pollingOnResume = false;
    }
  }

  Future<void> _onSignedIn(GitHubUser user) async {
    _pendingCode = null;
    if (!ref.mounted) return;
    final token = await ref
        .read(secureStoreProvider)
        .read(SecureStore.githubToken);
    if (!ref.mounted) return;
    ref.read(githubTokenProvider.notifier).set(token);
    state = AsyncData(SignedIn(user));
  }

  /// Runs the Device Flow. UI observes [PendingDeviceCode].
  Future<void> signIn() async {
    if (!AppConfig.hasGitHubClientId) {
      state = AsyncError(
        const AuthFailure(
          'GitHub client id is not configured',
          code: 'no_client_id',
        ),
        StackTrace.current,
      );
      return;
    }
    final service = ref.read(authServiceProvider);
    _cancel = Completer<void>();
    try {
      final code = await service.start();
      _pendingCode = code;
      if (!ref.mounted) return;
      state = AsyncData(
        PendingDeviceCode(
          userCode: code.userCode,
          verificationUri: code.verificationUri,
          expiresAt: DateTime.now().add(Duration(seconds: code.expiresIn)),
        ),
      );
      final user = await service.complete(code, cancel: _cancel!.future);
      await _onSignedIn(user);
    } on AuthFailure catch (e, st) {
      if (!ref.mounted) return;
      if (e.code == 'cancelled') {
        state = const AsyncData(SignedOut());
      } else {
        state = AsyncError(e, st);
      }
    } on AppFailure catch (e, st) {
      if (!ref.mounted) return;
      state = AsyncError(e, st);
    }
  }

  void cancelSignIn() {
    _pendingCode = null;
    if (_cancel != null && !_cancel!.isCompleted) _cancel!.complete();
    if (!ref.mounted) return;
    unawaited(ref.read(authServiceProvider).clearPendingCode());
    state = const AsyncData(SignedOut());
  }

  void resetError() => state = const AsyncData(SignedOut());

  Future<void> signOut({bool deletePendingChanges = false}) async {
    await ref
        .read(authServiceProvider)
        .signOut(deletePendingChanges: deletePendingChanges);
    ref.read(githubTokenProvider.notifier).set(null);
    ref.invalidate(currentWorkspaceProvider);
    state = const AsyncData(SignedOut());
  }

  /// Called when any request reports a revoked token (docs/04 §1.2).
  Future<void> onAuthFailure() async {
    await ref.read(secureStoreProvider).delete(SecureStore.githubToken);
    ref.read(githubTokenProvider.notifier).set(null);
    state = const AsyncData(SignedOut());
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

// ------------------------------------------------------------------ services

final githubRepositoryProvider = Provider<GitHubRepository>((ref) {
  final token = ref.watch(githubTokenProvider);
  if (token == null) throw const AuthFailure('Not signed in');
  return ref.watch(githubGatewayFactoryProvider)(token);
});

final workspaceServiceProvider = Provider<WorkspaceService>(
  (ref) => WorkspaceService(
    github: ref.watch(githubRepositoryProvider),
    db: ref.watch(databaseProvider),
    blobs: ref.watch(blobStoreProvider),
  ),
);

final editingServiceProvider = Provider<EditingService>(
  (ref) => EditingService(
    db: ref.watch(databaseProvider),
    blobs: ref.watch(blobStoreProvider),
    workspaces: ref.watch(workspaceServiceProvider),
  ),
);

final commitServiceProvider = Provider<CommitService>(
  (ref) => CommitService(
    github: ref.watch(githubRepositoryProvider),
    db: ref.watch(databaseProvider),
    blobs: ref.watch(blobStoreProvider),
    workspaces: ref.watch(workspaceServiceProvider),
  ),
);

final changeDiffLoaderProvider = Provider<ChangeDiffLoader>(
  (ref) => ChangeDiffLoader(
    blobs: ref.watch(blobStoreProvider),
    workspaces: ref.watch(workspaceServiceProvider),
  ),
);

final threadServiceProvider = Provider<ThreadService>(
  (ref) => ThreadService(ref.watch(githubRepositoryProvider)),
);

final pdfSidecarServiceProvider = Provider<PdfSidecarService>(
  (ref) => PdfSidecarService(
    editing: ref.watch(editingServiceProvider),
    workspaces: ref.watch(workspaceServiceProvider),
  ),
);

final agentServiceProvider = Provider<AgentService>(
  (ref) => AgentService(
    db: ref.watch(databaseProvider),
    blobs: ref.watch(blobStoreProvider),
    editing: ref.watch(editingServiceProvider),
    clientFor: ref.watch(llmClientFactoryProvider),
  ),
);

/// Jupyter token presence (secure storage), refreshed after settings changes.
final jupyterTokenProvider = FutureProvider<String?>((ref) {
  ref.watch(settingsProvider);
  return ref.watch(secureStoreProvider).read(SecureStore.jupyterToken);
});

/// Execution service, or null when no backend is configured.
final executionServiceProvider = Provider<ExecutionService?>((ref) {
  final settings = ref.watch(currentSettingsProvider);
  final token = ref.watch(jupyterTokenProvider).value;
  final url = settings.jupyterBaseUrl;
  if (url == null || url.isEmpty || token == null) return null;
  try {
    final service = ExecutionService(
      backend: JupyterClient(
        baseUrl: url,
        token: token,
        client: ref.watch(httpClientProvider),
      ),
      db: ref.watch(databaseProvider),
      workspaces: ref.watch(workspaceServiceProvider),
      editing: ref.watch(editingServiceProvider),
      kernelName: settings.jupyterKernel,
    );
    ref.onDispose(() => unawaited(service.shutdownAll()));
    return service;
  } on AppFailure {
    return null;
  }
});

// ---------------------------------------------------------------- workspace

/// Status of background workspace refreshes.
class WorkspaceStatus {
  const WorkspaceStatus({
    this.refreshing = false,
    this.error,
    this.changedPaths = const {},
    this.upToDate = false,
  });

  final bool refreshing;
  final AppFailure? error;

  /// Remote changes to files the user may have open (docs/04 §3.2 step 7).
  final Set<String> changedPaths;
  final bool upToDate;
}

class WorkspaceStatusController extends Notifier<WorkspaceStatus> {
  @override
  WorkspaceStatus build() => const WorkspaceStatus();

  void set(WorkspaceStatus s) => state = s;

  void acknowledge(String path) => state = WorkspaceStatus(
    refreshing: state.refreshing,
    error: state.error,
    changedPaths: {...state.changedPaths}..remove(path),
  );
}

final workspaceStatusProvider =
    NotifierProvider<WorkspaceStatusController, WorkspaceStatus>(
      WorkspaceStatusController.new,
    );

class WorkspaceController extends AsyncNotifier<Workspace?> {
  @override
  Future<Workspace?> build() async => null;

  WorkspaceService get _service => ref.read(workspaceServiceProvider);

  /// Opens [repo] on [branch]: cached tree first, then refresh (docs/04 §3.1).
  Future<void> open(RepositoryRef repo, {String? branch}) async {
    final b = branch ?? repo.defaultBranch;
    final db = ref.read(databaseProvider);
    await db.markRepositoryOpened(repo.fullName, DateTime.now());
    await db.setValue('last_workspace', {'repo': repo.fullName, 'branch': b});
    final stored = await db.repository(repo.fullName) ?? repo;
    final cached = await _service.cached(stored, b);
    if (cached != null) {
      state = AsyncData(cached);
      unawaited(refresh());
    } else {
      state = const AsyncLoading();
      try {
        final r = await _service.refresh(stored, b);
        state = AsyncData(r.workspace);
      } on AppFailure catch (e, st) {
        await _handle(e);
        state = AsyncError(e, st);
      }
    }
  }

  /// Re-fetches the branch head and tree.
  Future<void> refresh() async {
    final current = state.value;
    if (current == null) return;
    final status = ref.read(workspaceStatusProvider.notifier);
    status.set(const WorkspaceStatus(refreshing: true));
    try {
      final r = await _service.refresh(
        current.repo,
        current.branch,
        current: current,
      );
      state = AsyncData(r.workspace);
      status.set(
        WorkspaceStatus(changedPaths: r.changedPaths, upToDate: !r.changed),
      );
    } on AppFailure catch (e) {
      await _handle(e);
      status.set(WorkspaceStatus(error: e));
    }
  }

  Future<void> switchBranch(String branch) async {
    final current = state.value;
    if (current == null || current.branch == branch) return;
    await open(current.repo, branch: branch);
  }

  /// Replaces the workspace after a commit.
  void replace(Workspace ws) => state = AsyncData(ws);

  /// Pins or unpins the open repository. False when the limit is reached.
  Future<bool> togglePin() async {
    final current = state.value;
    if (current == null) return true;
    final ok = await ref.read(pinServiceProvider).toggle(current.repo);
    if (!ok) return false;
    final repo = await ref
        .read(databaseProvider)
        .repository(current.repo.fullName);
    if (repo != null) state = AsyncData(current.copyWith(repo: repo));
    return true;
  }

  /// Updates the repository AI access policy.
  Future<void> setAiAccess(AiAccess access) async {
    final current = state.value;
    if (current == null) return;
    await ref
        .read(databaseProvider)
        .setRepositoryAiAccess(current.repo.fullName, access);
    state = AsyncData(
      current.copyWith(repo: current.repo.copyWith(aiAccess: access)),
    );
  }

  void close() => state = const AsyncData(null);

  Future<void> _handle(AppFailure e) async {
    if (e is AuthFailure) {
      await ref.read(authControllerProvider.notifier).onAuthFailure();
    }
  }
}

final currentWorkspaceProvider =
    AsyncNotifierProvider<WorkspaceController, Workspace?>(
      WorkspaceController.new,
    );

/// Pending and proposed changes of the current workspace.
final pendingChangesProvider = StreamProvider<List<PendingChange>>((ref) {
  final ws = ref.watch(
    currentWorkspaceProvider.select(
      (s) => s.value == null ? null : (s.value!.repo.fullName, s.value!.branch),
    ),
  );
  if (ws == null) return Stream.value(const []);
  return ref.watch(databaseProvider).watchPendingChanges(ws.$1, ws.$2);
});

/// Only changes that are not AI proposals.
final committableChangesProvider = Provider<List<PendingChange>>(
  (ref) => [
    for (final c
        in ref.watch(pendingChangesProvider).value ?? const <PendingChange>[])
      if (c.isPending) c,
  ],
);

/// `.gitscholarignore` rules for the current workspace.
final ignoreRulesProvider = FutureProvider<IgnoreRules>((ref) async {
  final ws = ref.watch(currentWorkspaceProvider).value;
  if (ws == null) return IgnoreRules.fromFile(null);
  ref.watch(pendingChangesProvider);
  try {
    return IgnoreRules.fromFile(
      await ref
          .read(workspaceServiceProvider)
          .tryReadText(ws, IgnoreRules.fileName),
    );
  } on AppFailure {
    return IgnoreRules.fromFile(null);
  }
});

// ------------------------------------------------------------------ viewers

class OpenFilesState {
  const OpenFilesState({this.tabs = const [], this.active});

  final List<String> tabs;
  final String? active;
}

class OpenFilesController extends Notifier<OpenFilesState> {
  static const maxTabs = 8;

  @override
  OpenFilesState build() {
    ref.listen(currentWorkspaceProvider.select((s) => s.value?.repo.fullName), (
      prev,
      next,
    ) {
      if (prev != next) state = const OpenFilesState();
    });
    return const OpenFilesState();
  }

  void open(String path) {
    final tabs = [...state.tabs];
    if (!tabs.contains(path)) {
      tabs.add(path);
      while (tabs.length > maxTabs) {
        tabs.removeAt(0);
      }
    }
    state = OpenFilesState(tabs: tabs, active: path);
  }

  void close(String path) {
    final tabs = [...state.tabs]..remove(path);
    final active = state.active == path
        ? (tabs.isEmpty ? null : tabs.last)
        : state.active;
    state = OpenFilesState(tabs: tabs, active: active);
  }

  void rename(String from, String to) {
    state = OpenFilesState(
      tabs: [for (final t in state.tabs) t == from ? to : t],
      active: state.active == from ? to : state.active,
    );
  }

  void closeAll() => state = const OpenFilesState();
}

final openFilesProvider = NotifierProvider<OpenFilesController, OpenFilesState>(
  OpenFilesController.new,
);

/// Loads file content for [path] in the current workspace. Re-evaluated when
/// the workspace or pending changes change.
final fileContentProvider = FutureProvider.autoDispose
    .family<FileContent, String>((ref, path) async {
      final ws = ref.watch(currentWorkspaceProvider).value;
      if (ws == null) throw const NotFoundFailure('No workspace');
      final pending = ref.watch(pendingChangesProvider).value ?? const [];
      // Only reload when this path's change (or the base tree) changes.
      final change = pending
          .where((c) => c.isPending && (c.path == path || c.oldPath == path))
          .map((c) => '${c.kind}:${c.contentSha}')
          .join();
      ref.watch(Provider((_) => change));
      try {
        return await ref.read(workspaceServiceProvider).loadFile(ws, path);
      } on AuthFailure {
        await ref.read(authControllerProvider.notifier).onAuthFailure();
        rethrow;
      }
    });

class SelectionController extends Notifier<ViewerSelection?> {
  @override
  ViewerSelection? build() => null;

  void set(ViewerSelection? s) => state = s;
}

/// Current viewer selection, used as AI context (FR-62).
final selectionProvider =
    NotifierProvider<SelectionController, ViewerSelection?>(
      SelectionController.new,
    );

class PdfPageController extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  void set(String path, int page) => state = {...state, path: page};
}

/// Current PDF page per path.
final pdfPageProvider = NotifierProvider<PdfPageController, Map<String, int>>(
  PdfPageController.new,
);

/// Extracted PDF page texts by blob SHA (AI context).
final pdfTextCacheProvider = Provider<Map<String, List<String>>>((ref) => {});

/// Highlights stored beside the PDF at the given path (FR-90). Reloads when
/// the sidecar file changes.
final pdfAnnotationsProvider = FutureProvider.autoDispose
    .family<PdfAnnotations, String>((ref, path) async {
      final ws = ref.watch(currentWorkspaceProvider).value;
      if (ws == null) return PdfAnnotations.empty;
      final sidecar = PdfSidecarService.annotationsPathFor(path);
      final pending = ref.watch(pendingChangesProvider).value ?? const [];
      final change = pending
          .where((c) => c.isPending && c.path == sidecar)
          .map((c) => '${c.kind}:${c.contentSha}')
          .join();
      ref.watch(Provider((_) => change));
      return ref.read(pdfSidecarServiceProvider).load(ws, path);
    });

/// Whether the threads pane shows discussions or issues (FR-97). The choice
/// is remembered, and the first open shows discussions.
class ThreadKindController extends Notifier<ThreadKind> {
  static const storageKey = 'thread_kind';

  @override
  ThreadKind build() {
    _restore();
    return ThreadKind.discussion;
  }

  Future<void> _restore() async {
    final v = await ref.read(databaseProvider).getValue(storageKey);
    if (ref.mounted && v == ThreadKind.issue.name) state = ThreadKind.issue;
  }

  void set(ThreadKind kind) {
    state = kind;
    ref.read(databaseProvider).setValue(storageKey, kind.name);
  }
}

final threadKindProvider = NotifierProvider<ThreadKindController, ThreadKind>(
  ThreadKindController.new,
);

/// Threads of the selected kind for the open repository. A null value means
/// discussions are turned off for the repository.
final threadListProvider = FutureProvider.autoDispose<List<RepoThread>?>((
  ref,
) async {
  final repo = ref.watch(currentWorkspaceProvider.select((s) => s.value?.repo));
  if (repo == null) return const [];
  final kind = ref.watch(threadKindProvider);
  try {
    return await ref.read(threadServiceProvider).list(repo, kind);
  } on AuthFailure {
    await ref.read(authControllerProvider.notifier).onAuthFailure();
    rethrow;
  }
});

// ---------------------------------------------------------------------- UI

enum PhonePane { files, viewer, threads, agent }

class ShellState {
  const ShellState({
    this.showFiles = true,
    this.showAgent = true,
    this.phonePane = PhonePane.files,
    this.editing = const {},
  });

  final bool showFiles;
  final bool showAgent;
  final PhonePane phonePane;

  /// Paths currently in edit mode.
  final Set<String> editing;

  ShellState copyWith({
    bool? showFiles,
    bool? showAgent,
    PhonePane? phonePane,
    Set<String>? editing,
  }) => ShellState(
    showFiles: showFiles ?? this.showFiles,
    showAgent: showAgent ?? this.showAgent,
    phonePane: phonePane ?? this.phonePane,
    editing: editing ?? this.editing,
  );
}

class ShellController extends Notifier<ShellState> {
  @override
  ShellState build() {
    // The viewer pane is useless without a file, so fall back to the file
    // tree when the last tab closes (docs/08 §2).
    ref.listen(openFilesProvider.select((s) => s.active), (prev, next) {
      if (next == null && state.phonePane == PhonePane.viewer) {
        state = state.copyWith(phonePane: PhonePane.files);
      }
    });
    return const ShellState();
  }

  void toggleFiles() => state = state.copyWith(showFiles: !state.showFiles);
  void toggleAgent() => state = state.copyWith(
    showAgent: !state.showAgent,
    phonePane: PhonePane.agent,
  );

  /// Shows [p]. Selecting the viewer with no open file shows the file tree
  /// instead, so the user never lands on an empty viewer.
  void showPane(PhonePane p) {
    final target =
        p == PhonePane.viewer && ref.read(openFilesProvider).active == null
        ? PhonePane.files
        : p;
    state = state.copyWith(
      phonePane: target,
      showAgent: target == PhonePane.agent ? true : null,
    );
  }

  void setEditing(String path, bool editing) => state = state.copyWith(
    editing: editing
        ? {...state.editing, path}
        : ({...state.editing}..remove(path)),
  );
}

final shellProvider = NotifierProvider<ShellController, ShellState>(
  ShellController.new,
);

// ----------------------------------------------------- pinning and offline

final pinServiceProvider = Provider<PinService>(
  (ref) => PinService(ref.watch(databaseProvider)),
);

final offlineServiceProvider = Provider<OfflineService>(
  (ref) => OfflineService(
    db: ref.watch(databaseProvider),
    blobs: ref.watch(blobStoreProvider),
    workspaces: ref.watch(workspaceServiceProvider),
  ),
);

/// State of an offline download (FR-27).
class OfflineDownloadState {
  const OfflineDownloadState({
    required this.repoFullName,
    required this.progress,
    this.error,
  });

  final String repoFullName;
  final OfflineProgress progress;
  final AppFailure? error;

  bool get running => !progress.finished && error == null;
}

class OfflineController extends Notifier<OfflineDownloadState?> {
  StreamSubscription<OfflineProgress>? _sub;

  @override
  OfflineDownloadState? build() {
    ref.onDispose(() => _sub?.cancel());
    return null;
  }

  /// Downloads [prefixes] (empty means the whole repository).
  Future<void> start(Workspace ws, List<String> prefixes) async {
    if (state?.running ?? false) return;
    final rules = await ref.read(ignoreRulesProvider.future);
    final completer = Completer<void>();
    state = OfflineDownloadState(
      repoFullName: ws.repo.fullName,
      progress: const OfflineProgress(done: 0, total: 0),
    );
    _sub = ref
        .read(offlineServiceProvider)
        .download(ws, prefixes: prefixes, rules: rules)
        .listen(
          (p) => state = OfflineDownloadState(
            repoFullName: ws.repo.fullName,
            progress: p,
          ),
          onError: (Object e, StackTrace st) {
            state = OfflineDownloadState(
              repoFullName: ws.repo.fullName,
              progress:
                  state?.progress ?? const OfflineProgress(done: 0, total: 0),
              error: e is AppFailure ? e : UnknownFailure('$e'),
            );
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            unawaited(_refreshRepo(ws.repo.fullName));
            if (!completer.isCompleted) completer.complete();
          },
        );
    await completer.future;
  }

  /// Stops the download; files already downloaded are kept.
  Future<void> cancel() async {
    await _sub?.cancel();
    _sub = null;
    final current = state;
    if (current != null) {
      state = OfflineDownloadState(
        repoFullName: current.repoFullName,
        progress: OfflineProgress(
          done: current.progress.done,
          total: current.progress.total,
          failed: current.progress.failed,
          bytes: current.progress.bytes,
          finished: true,
          cancelled: true,
        ),
      );
      await _refreshRepo(current.repoFullName);
    }
  }

  /// Removes the offline copy.
  Future<void> remove(RepositoryRef repo) async {
    await ref.read(offlineServiceProvider).remove(repo);
    await _refreshRepo(repo.fullName);
  }

  void clear() => state = null;

  Future<void> _refreshRepo(String fullName) async {
    final repo = await ref.read(databaseProvider).repository(fullName);
    final ws = ref.read(currentWorkspaceProvider).value;
    if (repo != null && ws != null && ws.repo.fullName == fullName) {
      ref
          .read(currentWorkspaceProvider.notifier)
          .replace(ws.copyWith(repo: repo));
    }
  }
}

final offlineControllerProvider =
    NotifierProvider<OfflineController, OfflineDownloadState?>(
      OfflineController.new,
    );

/// Offline files whose remote version changed (FR-29).
final offlineOutdatedProvider = FutureProvider.autoDispose<int>((ref) async {
  final ws = ref.watch(currentWorkspaceProvider).value;
  if (ws == null || !ws.repo.isOffline) return 0;
  final rules = await ref.watch(ignoreRulesProvider.future);
  return (await ref.read(offlineServiceProvider).outdated(ws, rules)).length;
});
