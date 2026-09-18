import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../agent/agent_pane.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../../application/repositories/pin_service.dart';
import '../editing/commit_sheet.dart';
import '../offline/offline_sheet.dart';
import '../threads/threads_pane.dart';
import 'files_pane.dart';
import 'viewer_pane.dart';

final branchesProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  final ws = ref.watch(currentWorkspaceProvider.select((s) => s.value?.repo));
  if (ws == null) return const [];
  return ref.read(githubRepositoryProvider).listBranches(ws);
});

/// Workspace layout: 3 panes on tablets, bottom navigation on phones
/// (docs/08_ui_spec.md §2).
class WorkspaceShell extends ConsumerStatefulWidget {
  const WorkspaceShell({
    super.key,
    required this.owner,
    required this.name,
    this.branch,
    this.initialPath,
  });

  final String owner;
  final String name;
  final String? branch;
  final String? initialPath;

  @override
  ConsumerState<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends ConsumerState<WorkspaceShell> {
  double _filesWidth = 280;
  double _agentWidth = 360;
  Object? _openError;

  String get _fullName => '${widget.owner}/${widget.name}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void didUpdateWidget(WorkspaceShell old) {
    super.didUpdateWidget(old);
    // initialPath も見る。同じリポジトリを開いたまま別のファイルのリンクを
    // 共有されたとき、パスだけが変わるため（FR-100）。
    if (old.owner != widget.owner ||
        old.name != widget.name ||
        old.branch != widget.branch ||
        old.initialPath != widget.initialPath) {
      _open();
    }
  }

  Future<void> _open() async {
    final current = ref.read(currentWorkspaceProvider).value;
    if (current != null &&
        current.repo.fullName == _fullName &&
        (widget.branch == null || widget.branch == current.branch)) {
      _openInitialPath();
      return;
    }
    final db = ref.read(databaseProvider);
    var repo = await db.repository(_fullName);
    if (repo == null) {
      try {
        await ref.read(workspaceServiceProvider).listRepositories();
        repo = await db.repository(_fullName);
      } on AppFailure catch (e) {
        if (mounted) setState(() => _openError = e);
        return;
      }
    }
    if (repo == null) {
      if (mounted) setState(() => _openError = NotFoundFailure(_fullName));
      return;
    }
    final widths = await db.getValue('pane_widths');
    if (widths is Map && mounted) {
      setState(() {
        _filesWidth = (widths['files'] as num?)?.toDouble() ?? _filesWidth;
        _agentWidth = (widths['agent'] as num?)?.toDouble() ?? _agentWidth;
      });
    }
    await ref
        .read(currentWorkspaceProvider.notifier)
        .open(repo, branch: widget.branch);
    unawaited(
      ref
          .read(blobStoreProvider)
          .evict(
            targetBytes:
                ref.read(currentSettingsProvider).cacheLimitMb * 1024 * 1024,
          ),
    );
    _openInitialPath();
  }

  void _openInitialPath() {
    final p = widget.initialPath;
    if (p == null || p.isEmpty || !mounted) return;
    // openPath はタブを開いたうえで、フォンではビューアに切り替える。
    // ビューアは専用タブを持たないので、切り替えないと開いたことが見えない。
    openPath(context, ref, p);
  }

  void _saveWidths() => ref.read(databaseProvider).setValue('pane_widths', {
    'files': _filesWidth,
    'agent': _agentWidth,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final wsState = ref.watch(currentWorkspaceProvider);
    final ws = wsState.value;
    final shell = ref.watch(shellProvider);
    final changes = ref.watch(committableChangesProvider);
    final status = ref.watch(workspaceStatusProvider);
    ref.listen(workspaceStatusProvider, (prev, next) {
      if (next.error != null && prev?.error != next.error) {
        showSnack(context, failureMessage(context, next.error!));
      }
      if (next.upToDate && !(prev?.upToDate ?? false)) {
        showSnack(context, l.upToDate);
      }
    });

    if (_openError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(_fullName)),
        body: FailureView(
          error: _openError!,
          onRetry: () {
            setState(() => _openError = null);
            _open();
          },
        ),
      );
    }
    if (ws == null || ws.repo.fullName != _fullName) {
      return Scaffold(
        appBar: AppBar(title: Text(_fullName)),
        body: wsState.hasError
            ? FailureView(error: wsState.error!, onRetry: _open)
            : const Center(child: CircularProgressIndicator()),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final phone = width < Breakpoints.tablet;
    final showAgentByDefault = width >= Breakpoints.wide;
    final showAgent =
        shell.showAgent &&
        (showAgentByDefault || shell.phonePane == PhonePane.agent);

    final appBar = AppBar(
      titleSpacing: 8,
      leadingWidth: 104,
      leading: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Tooltip(
          message: l.repoListHint,
          child: TextButton.icon(
            key: const Key('repoListButton'),
            icon: const Icon(Icons.folder_copy_outlined, size: 18),
            label: Text(l.repoListShort, overflow: TextOverflow.ellipsis),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _toRepositoryList,
          ),
        ),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toRepositoryList,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(ws.repo.name, overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
          _BranchPicker(workspace: ws),
        ],
      ),
      actions: [
        IconButton(
          tooltip: l.refresh,
          icon: status.refreshing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
          onPressed: status.refreshing
              ? null
              : ref.read(currentWorkspaceProvider.notifier).refresh,
        ),
        if (ws.repo.isOffline)
          IconButton(
            tooltip: l.offlineTitle,
            icon: const Icon(Icons.cloud_done_outlined),
            onPressed: () => showOfflineSheet(context),
          ),
        IconButton(
          key: const Key('changesButton'),
          tooltip: l.changesTitle(changes.length),
          icon: Badge(
            isLabelVisible: changes.isNotEmpty,
            label: Text('${changes.length}'),
            child: const Icon(Icons.difference_outlined),
          ),
          onPressed: () => context.push('/ws/${ws.repo.fullName}/changes'),
        ),
        if (!phone) ...[
          IconButton(
            key: const Key('toggleThreads'),
            tooltip: l.threads,
            isSelected: shell.phonePane == PhonePane.threads,
            icon: const Icon(Icons.forum_outlined),
            selectedIcon: const Icon(Icons.forum),
            onPressed: () => ref
                .read(shellProvider.notifier)
                .showPane(
                  shell.phonePane == PhonePane.threads
                      ? PhonePane.viewer
                      : PhonePane.threads,
                ),
          ),
          IconButton(
            tooltip: l.toggleFiles,
            icon: Icon(
              shell.showFiles
                  ? Icons.view_sidebar_outlined
                  : Icons.view_sidebar,
            ),
            onPressed: ref.read(shellProvider.notifier).toggleFiles,
          ),
          IconButton(
            key: const Key('toggleAgent'),
            tooltip: l.toggleAgent,
            isSelected: showAgent,
            icon: const Icon(Icons.auto_awesome_outlined),
            selectedIcon: const Icon(Icons.auto_awesome),
            onPressed: () {
              if (showAgent) {
                ref.read(shellProvider.notifier).showPane(PhonePane.viewer);
                if (showAgentByDefault) {
                  ref.read(shellProvider.notifier).toggleAgent();
                }
              } else {
                ref.read(shellProvider.notifier).showPane(PhonePane.agent);
              }
            },
          ),
        ],
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'pin':
                unawaited(_togglePin());
              case 'offline':
                unawaited(showOfflineSheet(context));
              case 'runs':
                context.push('/ws/${ws.repo.fullName}/runs');
              case 'settings':
                context.push('/settings');
              case 'ai_allow':
                ref
                    .read(currentWorkspaceProvider.notifier)
                    .setAiAccess(AiAccess.allowed);
              case 'ai_deny':
                ref
                    .read(currentWorkspaceProvider.notifier)
                    .setAiAccess(AiAccess.denied);
              case 'ai_ask':
                ref
                    .read(currentWorkspaceProvider.notifier)
                    .setAiAccess(AiAccess.ask);
            }
          },
          itemBuilder: (ctx) => [
            CheckedPopupMenuItem(
              value: 'pin',
              checked: ws.repo.isPinned,
              child: Text(l.pin),
            ),
            PopupMenuItem(
              value: 'offline',
              child: Row(
                children: [
                  if (ws.repo.isOffline)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.cloud_done_outlined, size: 18),
                    ),
                  Text(l.offlineTitle),
                ],
              ),
            ),
            PopupMenuItem(value: 'runs', child: Text(l.executionLog)),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(
              value: 'ai_allow',
              checked: ws.repo.aiAccess == AiAccess.allowed,
              child: Text(l.aiAccessAllowed),
            ),
            CheckedPopupMenuItem(
              value: 'ai_ask',
              checked: ws.repo.aiAccess == AiAccess.ask,
              child: Text(l.aiAccessAsk),
            ),
            CheckedPopupMenuItem(
              value: 'ai_deny',
              checked: ws.repo.aiAccess == AiAccess.denied,
              child: Text(l.aiAccessDenied),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'settings', child: Text(l.settings)),
          ],
        ),
      ],
    );

    final Widget body;
    if (phone) {
      body = IndexedStack(
        index: shell.phonePane.index,
        children: const [FilesPane(), ViewerPane(), ThreadsPane(), AgentPane()],
      );
    } else {
      body = Row(
        children: [
          if (shell.showFiles) ...[
            SizedBox(width: _filesWidth, child: const FilesPane()),
            _DragHandle(
              onDrag: (dx) => setState(
                () => _filesWidth = (_filesWidth + dx).clamp(220, width * 0.4),
              ),
              onEnd: _saveWidths,
            ),
          ],
          Expanded(
            child: shell.phonePane == PhonePane.threads
                ? const ThreadsPane()
                : const ViewerPane(),
          ),
          if (showAgent) ...[
            _DragHandle(
              onDrag: (dx) => setState(
                () => _agentWidth = (_agentWidth - dx).clamp(280, width * 0.5),
              ),
              onEnd: _saveWidths,
            ),
            SizedBox(width: _agentWidth, child: const AgentPane()),
          ],
        ],
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyJ, meta: true):
            _toggleAgentShortcut,
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true):
            _toggleAgentShortcut,
        const SingleActivator(
          LogicalKeyboardKey.keyK,
          meta: true,
          shift: true,
        ): () =>
            showCommitSheet(context),
        const SingleActivator(
          LogicalKeyboardKey.keyK,
          control: true,
          shift: true,
        ): () =>
            showCommitSheet(context),
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): _closeTab,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true):
            _closeTab,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: appBar,
          body: body,
          bottomNavigationBar: phone
              ? NavigationBar(
                  key: const Key('phoneNav'),
                  // The viewer is reached by opening a file, so it has no
                  // destination of its own; it counts as part of Files.
                  selectedIndex: switch (shell.phonePane) {
                    PhonePane.files || PhonePane.viewer => 0,
                    PhonePane.threads => 1,
                    PhonePane.agent => 2,
                  },
                  onDestinationSelected: (i) => ref
                      .read(shellProvider.notifier)
                      .showPane(
                        const [
                          PhonePane.files,
                          PhonePane.threads,
                          PhonePane.agent,
                        ][i],
                      ),
                  destinations: [
                    NavigationDestination(
                      icon: const Icon(Icons.folder_outlined),
                      label: l.files,
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.forum_outlined),
                      label: l.threads,
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: l.ai,
                    ),
                  ],
                )
              : null,
        ),
      ),
    );
  }

  void _toRepositoryList() {
    ref.read(currentWorkspaceProvider.notifier).close();
    context.go('/repos');
  }

  Future<void> _togglePin() async {
    final l = context.l10n;
    final ok = await ref.read(currentWorkspaceProvider.notifier).togglePin();
    if (!ok && mounted) showSnack(context, l.pinLimit(PinService.maxPinned));
  }

  void _toggleAgentShortcut() {
    final shell = ref.read(shellProvider);
    ref
        .read(shellProvider.notifier)
        .showPane(
          shell.phonePane == PhonePane.agent
              ? PhonePane.viewer
              : PhonePane.agent,
        );
  }

  void _closeTab() {
    final active = ref.read(openFilesProvider).active;
    if (active != null) ref.read(openFilesProvider.notifier).close(active);
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDrag, required this.onEnd});

  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      onHorizontalDragEnd: (_) => onEnd(),
      child: SizedBox(
        width: 8,
        child: Center(
          child: VerticalDivider(
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
    ),
  );
}

class _BranchPicker extends ConsumerWidget {
  const _BranchPicker({required this.workspace});

  final Workspace workspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () async {
        final l = context.l10n;
        final branches = await ref
            .read(branchesProvider.future)
            .catchError((_) => <String>[workspace.branch]);
        if (!context.mounted) return;
        final choice = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text(
                    l.branches,
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                for (final b in branches)
                  ListTile(
                    leading: Icon(
                      b == workspace.branch ? Icons.check : Icons.call_split,
                    ),
                    title: Text(b),
                    onTap: () => Navigator.pop(ctx, b),
                  ),
              ],
            ),
          ),
        );
        if (choice != null) {
          await ref
              .read(currentWorkspaceProvider.notifier)
              .switchBranch(choice);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.call_split, size: 12),
          const SizedBox(width: 2),
          Text(workspace.branch, style: Theme.of(context).textTheme.bodySmall),
          const Icon(Icons.arrow_drop_down, size: 14),
        ],
      ),
    );
  }
}
