import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../core/providers.dart';
import '../core/widgets.dart';

/// Copies the open file into another repository (FR-101).
///
/// The copy becomes a pending change in the destination, so nothing is written
/// to GitHub until the user commits there.
Future<void> showCopyToRepoSheet(
  BuildContext context,
  WidgetRef ref,
  FileContent file,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (ctx) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
    child: SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.75,
      child: _CopyToRepoSheet(file: file),
    ),
  ),
);

class _CopyToRepoSheet extends ConsumerStatefulWidget {
  const _CopyToRepoSheet({required this.file});

  final FileContent file;

  @override
  ConsumerState<_CopyToRepoSheet> createState() => _CopyToRepoSheetState();
}

class _CopyToRepoSheetState extends ConsumerState<_CopyToRepoSheet> {
  final _search = TextEditingController();
  final _path = TextEditingController();

  List<RepositoryRef> _repos = const [];
  RepositoryRef? _target;

  /// Destination tree, loaded once a repository is chosen. Used to tell the
  /// user when the copy would replace a file.
  Workspace? _targetWorkspace;

  Object? _error;
  var _loading = true;
  var _copying = false;

  @override
  void initState() {
    super.initState();
    _path.text = widget.file.path;
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final source = ref.read(currentWorkspaceProvider).value?.repo.fullName;
    final all = await ref.read(databaseProvider).allRepositories();
    if (!mounted) return;
    setState(() {
      _repos = [
        for (final r in all)
          if (r.fullName != source) r,
      ]..sort(_byUsefulness);
      _loading = false;
    });
  }

  /// Pinned first, then recently opened, then by name.
  static int _byUsefulness(RepositoryRef a, RepositoryRef b) {
    if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
    final aOpened = a.lastOpenedAt;
    final bOpened = b.lastOpenedAt;
    if ((aOpened == null) != (bOpened == null)) return aOpened != null ? -1 : 1;
    if (aOpened != null && bOpened != null && aOpened != bOpened) {
      return bOpened.compareTo(aOpened);
    }
    return a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
  }

  Future<void> _choose(RepositoryRef repo) async {
    setState(() {
      _target = repo;
      _targetWorkspace = null;
      _error = null;
    });
    try {
      final services = ref.read(workspaceServiceProvider);
      final branch = repo.defaultBranch;
      final ws =
          await services.cached(repo, branch) ??
          (await services.refresh(repo, branch)).workspace;
      if (mounted) setState(() => _targetWorkspace = ws);
    } on AppFailure catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _copy() async {
    final target = _target;
    if (target == null || _copying) return;
    final l = context.l10n;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    setState(() => _copying = true);
    try {
      final result = await ref
          .read(fileCopyServiceProvider)
          .copy(source: widget.file, target: target, targetPath: _path.text);
      if (!mounted) return;
      navigator.pop();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              result.hasChange
                  ? l.copyDone(target.fullName)
                  : l.copySameContent,
            ),
            action: result.hasChange
                ? SnackBarAction(
                    label: l.copyViewChanges,
                    onPressed: () => router.go('/ws/${target.fullName}'),
                  )
                : null,
          ),
        );
    } on AppFailure catch (e) {
      if (mounted) {
        setState(() {
          _copying = false;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final target = _target;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              if (target != null)
                IconButton(
                  tooltip: l.copyDestination,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _target = null),
                ),
              Expanded(
                child: Text(
                  target == null ? l.copyDestination : target.fullName,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: target == null ? _repoList() : _pathStep(target)),
      ],
    );
  }

  Widget _repoList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final query = _search.text.trim().toLowerCase();
    final shown = [
      for (final r in _repos)
        if (query.isEmpty || r.fullName.toLowerCase().contains(query)) r,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            key: const Key('copyRepoSearch'),
            controller: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: context.l10n.searchRepositories,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: Icons.folder_off_outlined,
                  message: context.l10n.noRepositories,
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final r = shown[i];
                    return ListTile(
                      key: Key('copyTo-${r.fullName}'),
                      leading: Icon(
                        r.isPinned
                            ? Icons.push_pin
                            : (r.isPrivate
                                  ? Icons.lock_outline
                                  : Icons.book_outlined),
                      ),
                      title: Text(r.fullName, overflow: TextOverflow.ellipsis),
                      subtitle: Text(r.defaultBranch),
                      onTap: () => _choose(r),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _pathStep(RepositoryRef target) {
    final workspace = _targetWorkspace;
    final error = _error;
    if (error != null) {
      return FailureView(error: error, onRetry: () => _choose(target));
    }
    if (workspace == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final path = _path.text.trim();
    final replaces = path.isNotEmpty && workspace.entry(path) != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        TextField(
          key: const Key('copyPath'),
          controller: _path,
          decoration: InputDecoration(
            labelText: context.l10n.copyPathLabel,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (replaces)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(context.l10n.copyReplaceWarning)),
              ],
            ),
          ),
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('copyConfirm'),
          onPressed: path.isEmpty || _copying ? null : _copy,
          icon: _copying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.copy_all_outlined),
          label: Text(context.l10n.copyToRepo),
        ),
      ],
    );
  }
}
