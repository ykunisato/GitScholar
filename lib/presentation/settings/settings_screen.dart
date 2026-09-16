import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:scholar_agent/scholar_agent.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../infrastructure/execution/jupyter_client.dart';
import '../../infrastructure/local/secure_store.dart';
import '../core/providers.dart';
import '../core/widgets.dart';

/// Settings (docs/08_ui_spec.md §3.7).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _apiKey = TextEditingController();
  final _jupyterUrl = TextEditingController();
  final _jupyterToken = TextEditingController();
  bool _hasApiKey = false;
  bool _hasJupyterToken = false;
  String? _aiTest;
  String? _jupyterTest;
  List<String> _kernels = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final secure = ref.read(secureStoreProvider);
    final key = await secure.read(SecureStore.anthropicKey);
    final jt = await secure.read(SecureStore.jupyterToken);
    final s = await ref.read(settingsProvider.future);
    if (!mounted) return;
    setState(() {
      _hasApiKey = key != null;
      _hasJupyterToken = jt != null;
      _jupyterUrl.text = s.jupyterBaseUrl ?? '';
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _jupyterUrl.dispose();
    _jupyterToken.dispose();
    super.dispose();
  }

  Future<void> _update(Settings Function(Settings) f) =>
      ref.read(settingsProvider.notifier).change(f);

  Future<void> _saveApiKey() async {
    final key = _apiKey.text.trim();
    if (key.isEmpty) return;
    await ref.read(secureStoreProvider).write(SecureStore.anthropicKey, key);
    _apiKey.clear();
    setState(() => _hasApiKey = true);
    if (mounted) showSnack(context, context.l10n.saved);
  }

  Future<void> _testAi() async {
    final l = context.l10n;
    setState(() => _aiTest = l.testing);
    final key = await ref
        .read(secureStoreProvider)
        .read(SecureStore.anthropicKey);
    if (key == null) {
      setState(() => _aiTest = l.apiKeyMissing);
      return;
    }
    final s = ref.read(currentSettingsProvider);
    try {
      final client = ref.read(anthropicClientFactoryProvider)(key);
      await client
          .streamMessage(
            MessageRequest(
              model: s.aiModel,
              maxTokens: 64,
              autoCache: false,
              messages: [Message.userText('ping')],
            ),
          )
          .drain<void>();
      if (mounted) setState(() => _aiTest = l.connectionOk);
    } on AnthropicApiException catch (e) {
      if (mounted) {
        setState(() => _aiTest = e.isAuthError ? l.apiKeyInvalid : e.message);
      }
    }
  }

  Future<void> _saveJupyter() async {
    final url = _jupyterUrl.text.trim();
    final token = _jupyterToken.text.trim();
    if (token.isNotEmpty) {
      await ref
          .read(secureStoreProvider)
          .write(SecureStore.jupyterToken, token);
      _jupyterToken.clear();
      _hasJupyterToken = true;
    }
    await _update(
      (s) => url.isEmpty
          ? s.copyWith(clearJupyter: true)
          : s.copyWith(jupyterBaseUrl: url),
    );
    ref.invalidate(jupyterTokenProvider);
    if (mounted) {
      setState(() {});
      showSnack(context, context.l10n.saved);
    }
  }

  Future<void> _testJupyter() async {
    final l = context.l10n;
    setState(() => _jupyterTest = l.testing);
    final token = await ref
        .read(secureStoreProvider)
        .read(SecureStore.jupyterToken);
    try {
      final client = JupyterClient(
        baseUrl: _jupyterUrl.text.trim(),
        token: token ?? '',
        client: ref.read(httpClientProvider),
      );
      final version = await client.status();
      final specs = await client.kernelSpecs();
      if (mounted) {
        setState(() {
          _kernels = [for (final s in specs) s.name];
          _jupyterTest = l.jupyterConnected(version);
        });
      }
    } on AppFailure catch (e) {
      if (mounted) setState(() => _jupyterTest = failureMessage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final s = ref.watch(currentSettingsProvider);
    final auth = ref.watch(authControllerProvider).value;
    final user = auth is SignedIn ? auth.user : null;
    int? rate;
    try {
      rate = ref.watch(githubRepositoryProvider).rateLimitRemaining;
    } on AuthFailure {
      rate = null;
    }
    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _Section(l.account),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(user?.login ?? '-'),
                  subtitle: rate == null
                      ? null
                      : Text(l.rateLimitRemaining(rate)),
                  trailing: TextButton(
                    onPressed: user == null ? null : () => _signOut(context),
                    child: Text(l.signOut),
                  ),
                ),
                _Section(l.aiSection),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    key: const Key('apiKeyField'),
                    controller: _apiKey,
                    obscureText: true,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l.anthropicApiKey,
                      helperText: _hasApiKey ? l.apiKeySaved : l.apiKeyHelp,
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.save),
                        onPressed: _saveApiKey,
                      ),
                    ),
                    onSubmitted: (_) => _saveApiKey(),
                  ),
                ),
                Row(
                  children: [
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _testAi,
                      child: Text(l.testConnection),
                    ),
                    if (_hasApiKey)
                      TextButton(
                        onPressed: () async {
                          await ref
                              .read(secureStoreProvider)
                              .delete(SecureStore.anthropicKey);
                          setState(() => _hasApiKey = false);
                        },
                        child: Text(l.delete),
                      ),
                    if (_aiTest != null)
                      Expanded(
                        child: Text(_aiTest!, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
                ListTile(
                  title: Text(l.model),
                  trailing: DropdownButton<String>(
                    value: ClaudeModels.all.contains(s.aiModel)
                        ? s.aiModel
                        : ClaudeModels.opus5,
                    items: [
                      DropdownMenuItem(
                        value: ClaudeModels.opus5,
                        child: const Text('Claude Opus 5'),
                      ),
                      DropdownMenuItem(
                        value: ClaudeModels.sonnet5,
                        child: const Text('Claude Sonnet 5'),
                      ),
                      DropdownMenuItem(
                        value: ClaudeModels.fable51,
                        child: const Text('Claude Fable 5.1'),
                      ),
                    ],
                    onChanged: (v) => _update((s) => s.copyWith(aiModel: v)),
                  ),
                ),
                ListTile(
                  title: Text(l.effort),
                  subtitle: Text(l.effortHelp),
                  trailing: DropdownButton<String>(
                    value: s.aiEffort,
                    items: [
                      for (final e in effortLevels)
                        DropdownMenuItem(value: e, child: Text(e)),
                    ],
                    onChanged: (v) => _update((s) => s.copyWith(aiEffort: v)),
                  ),
                ),
                SwitchListTile(
                  title: Text(l.showThinkingSummary),
                  value: s.aiShowThinkingSummary,
                  onChanged: (v) =>
                      _update((s) => s.copyWith(aiShowThinkingSummary: v)),
                ),
                SwitchListTile(
                  title: Text(l.autoRunCode),
                  subtitle: Text(l.autoRunCodeHelp),
                  value: s.autoRunCode,
                  onChanged: (v) => _update((s) => s.copyWith(autoRunCode: v)),
                ),
                SwitchListTile(
                  title: Text(l.logAiContent),
                  value: s.logAiContent,
                  onChanged: (v) => _update((s) => s.copyWith(logAiContent: v)),
                ),
                _Section(l.executionSection),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      TextField(
                        controller: _jupyterUrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: l.jupyterUrl,
                          hintText: 'https://hub.example.org/user/you/',
                        ),
                      ),
                      TextField(
                        controller: _jupyterToken,
                        obscureText: true,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: l.jupyterToken,
                          helperText: _hasJupyterToken ? l.apiKeySaved : null,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    const SizedBox(width: 8),
                    TextButton(onPressed: _saveJupyter, child: Text(l.save)),
                    TextButton(
                      onPressed: _testJupyter,
                      child: Text(l.testConnection),
                    ),
                    if (_jupyterTest != null)
                      Expanded(
                        child: Text(
                          _jupyterTest!,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
                ListTile(
                  title: Text(l.defaultKernel),
                  trailing: DropdownButton<String>(
                    value: s.jupyterKernel,
                    items: [
                      for (final k in {..._kernels, s.jupyterKernel})
                        DropdownMenuItem(value: k, child: Text(k)),
                    ],
                    onChanged: (v) =>
                        _update((s) => s.copyWith(jupyterKernel: v)),
                  ),
                ),
                _Section(l.cacheSection),
                _CacheTile(
                  limitMb: s.cacheLimitMb,
                  onLimit: (v) => _update((s) => s.copyWith(cacheLimitMb: v)),
                ),
                _Section(l.displaySection),
                ListTile(
                  title: Text(l.theme),
                  trailing: DropdownButton<String>(
                    value: s.themeMode,
                    items: [
                      DropdownMenuItem(
                        value: 'system',
                        child: Text(l.themeSystem),
                      ),
                      DropdownMenuItem(
                        value: 'light',
                        child: Text(l.themeLight),
                      ),
                      DropdownMenuItem(value: 'dark', child: Text(l.themeDark)),
                    ],
                    onChanged: (v) => _update((s) => s.copyWith(themeMode: v)),
                  ),
                ),
                ListTile(
                  title: Text(l.language),
                  trailing: DropdownButton<String>(
                    value: s.locale ?? 'system',
                    items: [
                      DropdownMenuItem(
                        value: 'system',
                        child: Text(l.themeSystem),
                      ),
                      const DropdownMenuItem(value: 'ja', child: Text('日本語')),
                      const DropdownMenuItem(
                        value: 'en',
                        child: Text('English'),
                      ),
                    ],
                    onChanged: (v) => _update(
                      (s) => v == 'system'
                          ? s.copyWith(clearLocale: true)
                          : s.copyWith(locale: v),
                    ),
                  ),
                ),
                ListTile(
                  title: Text(l.editorFontSize),
                  subtitle: Slider(
                    min: 10,
                    max: 24,
                    divisions: 14,
                    label: s.editorFontSize.round().toString(),
                    value: s.editorFontSize.clamp(10, 24),
                    onChanged: (v) =>
                        _update((s) => s.copyWith(editorFontSize: v)),
                  ),
                ),
                SwitchListTile(
                  title: Text(l.wordWrap),
                  value: s.wordWrap,
                  onChanged: (v) => _update((s) => s.copyWith(wordWrap: v)),
                ),
                _Section(l.about),
                ListTile(
                  title: const Text('GitScholar'),
                  subtitle: const Text('0.1.0'),
                ),
                ListTile(
                  title: Text(l.designDocs),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => launchUrl(
                    Uri.parse(
                      'https://github.com/ykunisato/GitScholar/tree/main/docs',
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Future<void> _signOut(BuildContext context) async {
    final l = context.l10n;
    var deletePending = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.signOut),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.signOutConfirm),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: deletePending,
                onChanged: (v) => setLocal(() => deletePending = v ?? false),
                title: Text(l.deletePendingChanges),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.signOut),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await ref
          .read(authControllerProvider.notifier)
          .signOut(deletePendingChanges: deletePending);
    }
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _CacheTile extends ConsumerStatefulWidget {
  const _CacheTile({required this.limitMb, required this.onLimit});

  final int limitMb;
  final ValueChanged<int> onLimit;

  @override
  ConsumerState<_CacheTile> createState() => _CacheTileState();
}

class _CacheTileState extends ConsumerState<_CacheTile> {
  int? _total;
  List<(String, int)> _perRepo = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final blobs = ref.read(blobStoreProvider);
    final db = ref.read(databaseProvider);
    final total = await blobs.totalSize();
    final repos = await db.allRepositories();
    final per = <(String, int)>[];
    for (final r in repos) {
      final size = await blobs.sizeForRepo(r.fullName);
      if (size > 0) per.add((r.fullName, size));
    }
    if (mounted) {
      setState(() {
        _total = total;
        _perRepo = per;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final blobs = ref.read(blobStoreProvider);
    return Column(
      children: [
        ListTile(
          title: Text(l.cacheUsage),
          subtitle: Text(
            _total == null
                ? '...'
                : l.cacheUsageOf(
                    formatBytes(_total!),
                    formatBytes(widget.limitMb * 1024 * 1024),
                  ),
          ),
          trailing: TextButton(
            onPressed: () async {
              await blobs.clear();
              await _refresh();
            },
            child: Text(l.clearAll),
          ),
        ),
        ListTile(
          title: Text(l.cacheLimit),
          trailing: DropdownButton<int>(
            value: widget.limitMb,
            items: [
              for (final mb in {512, 1024, 2048, 4096, 8192, widget.limitMb})
                DropdownMenuItem(
                  value: mb,
                  child: Text(formatBytes(mb * 1024 * 1024)),
                ),
            ],
            onChanged: (v) async {
              if (v == null) return;
              widget.onLimit(v);
              await blobs.evict(targetBytes: v * 1024 * 1024);
              await _refresh();
            },
          ),
        ),
        for (final (repo, size) in _perRepo)
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_outlined),
            title: Text(repo),
            subtitle: Text(formatBytes(size)),
            trailing: IconButton(
              tooltip: l.delete,
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await blobs.deleteForRepo(repo);
                await _refresh();
              },
            ),
          ),
      ],
    );
  }
}
