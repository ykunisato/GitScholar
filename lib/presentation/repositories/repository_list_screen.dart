import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/repositories/pin_service.dart';
import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../core/providers.dart';
import '../core/widgets.dart';

enum RepoSort { updated, name }

class RepositoryListController extends AsyncNotifier<List<RepositoryRef>> {
  final progress = ValueNotifier<int>(0);

  @override
  Future<List<RepositoryRef>> build() async {
    final service = ref.watch(workspaceServiceProvider);
    final cached = await ref.read(databaseProvider).allRepositories();
    if (cached.isNotEmpty) {
      // Show cache immediately, refresh in background.
      unawaited(Future.microtask(reload));
      return cached;
    }
    return service.listRepositories(onProgress: (n) => progress.value = n);
  }

  Future<void> reload() async {
    try {
      final list = await ref
          .read(workspaceServiceProvider)
          .listRepositories(onProgress: (n) => progress.value = n);
      state = AsyncData(list);
    } on AuthFailure {
      await ref.read(authControllerProvider.notifier).onAuthFailure();
    } on AppFailure catch (e, st) {
      if (state.value == null) state = AsyncError(e, st);
    }
  }

  /// Reads the repositories back from the database (after pinning etc.).
  Future<void> refreshFromDb() async {
    state = AsyncData(await ref.read(databaseProvider).allRepositories());
  }

  /// Pins or unpins. Returns false when the pin limit is reached (FR-16).
  Future<bool> togglePin(RepositoryRef repo) async {
    final ok = await ref.read(pinServiceProvider).toggle(repo);
    if (ok) await refreshFromDb();
    return ok;
  }

  /// Deletes the offline copy of [repo] (FR-30b).
  Future<void> removeOffline(RepositoryRef repo) async {
    await ref.read(offlineServiceProvider).remove(repo);
    await refreshFromDb();
  }
}

final repositoryListProvider =
    AsyncNotifierProvider<RepositoryListController, List<RepositoryRef>>(
      RepositoryListController.new,
    );

/// Repository picker (docs/08_ui_spec.md §3.2).
class RepositoryListScreen extends ConsumerStatefulWidget {
  const RepositoryListScreen({super.key, this.restoreLast = true});

  final bool restoreLast;

  @override
  ConsumerState<RepositoryListScreen> createState() =>
      _RepositoryListScreenState();
}

bool _restoredThisLaunch = false;

class _RepositoryListScreenState extends ConsumerState<RepositoryListScreen> {
  String _query = '';
  RepoSort _sort = RepoSort.updated;

  @override
  void initState() {
    super.initState();
    if (widget.restoreLast && !_restoredThisLaunch) {
      _restoredThisLaunch = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
    }
  }

  Future<void> _restore() async {
    final last = await ref.read(databaseProvider).getValue('last_workspace');
    if (last is Map && mounted) {
      final fullName = last['repo'] as String;
      if (await ref.read(databaseProvider).repository(fullName) != null &&
          mounted) {
        context.go(
          '/ws/$fullName?branch=${Uri.encodeQueryComponent('${last['branch']}')}',
        );
      }
    }
  }

  Future<void> _togglePin(RepositoryRef repo) async {
    final l = context.l10n;
    final ok = await ref.read(repositoryListProvider.notifier).togglePin(repo);
    if (!ok && mounted) showSnack(context, l.pinLimit(PinService.maxPinned));
  }

  Future<void> _menu(RepositoryRef repo) async {
    final l = context.l10n;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(repo.fullName)),
            ListTile(
              leading: Icon(
                repo.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              title: Text(repo.isPinned ? ctx.l10n.unpin : ctx.l10n.pin),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            if (repo.isOffline)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(ctx.l10n.offlineDelete),
                onTap: () => Navigator.pop(ctx, 'offline_delete'),
              )
            else
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: Text(ctx.l10n.offlineTitle),
                subtitle: Text(ctx.l10n.offlineOpenRepoFirst),
                onTap: () => Navigator.pop(ctx, 'open'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'pin':
        await _togglePin(repo);
      case 'open':
        context.go('/ws/${repo.fullName}');
      case 'offline_delete':
        final ok = await confirmDialog(
          context,
          title: l.offlineDelete,
          message: l.offlineDeleteConfirm(repo.fullName),
          confirmLabel: l.delete,
          destructive: true,
        );
        if (ok) {
          await ref.read(repositoryListProvider.notifier).removeOffline(repo);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final repos = ref.watch(repositoryListProvider);
    final auth = ref.watch(authControllerProvider).value;
    final user = auth is SignedIn ? auth.user : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.repositories),
        actions: [
          PopupMenuButton<String>(
            icon: CircleAvatar(
              radius: 14,
              backgroundImage: user != null && user.avatarUrl.isNotEmpty
                  ? NetworkImage(user.avatarUrl)
                  : null,
              child: user == null || user.avatarUrl.isEmpty
                  ? const Icon(Icons.person, size: 16)
                  : null,
            ),
            onSelected: (v) async {
              if (v == 'settings') unawaited(context.push('/settings'));
              if (v == 'signout') {
                final ok = await confirmDialog(
                  context,
                  title: l.signOut,
                  message: l.signOutConfirm,
                  confirmLabel: l.signOut,
                  destructive: true,
                );
                if (ok) {
                  await ref.read(authControllerProvider.notifier).signOut();
                }
              }
            },
            itemBuilder: (ctx) => [
              if (user != null)
                PopupMenuItem(enabled: false, child: Text(user.login)),
              PopupMenuItem(value: 'settings', child: Text(l.settings)),
              PopupMenuItem(value: 'signout', child: Text(l.signOut)),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('repoSearch'),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: l.searchRepositories,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v.toLowerCase()),
                  ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<RepoSort>(
                  segments: [
                    ButtonSegment(
                      value: RepoSort.updated,
                      label: Text(l.sortUpdated),
                    ),
                    ButtonSegment(
                      value: RepoSort.name,
                      label: Text(l.sortName),
                    ),
                  ],
                  selected: {_sort},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _sort = s.first),
                ),
              ],
            ),
          ),
          Expanded(
            child: switch (repos) {
              AsyncData(:final value) => RefreshIndicator(
                onRefresh: ref.read(repositoryListProvider.notifier).reload,
                child: _list(value),
              ),
              AsyncError(:final error) => FailureView(
                error: error,
                onRetry: () => ref.invalidate(repositoryListProvider),
              ),
              _ => Center(
                child: ValueListenableBuilder<int>(
                  valueListenable: ref
                      .read(repositoryListProvider.notifier)
                      .progress,
                  builder: (_, n, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(l.loadedCount(n)),
                    ],
                  ),
                ),
              ),
            },
          ),
        ],
      ),
    );
  }

  Widget _list(List<RepositoryRef> all) {
    final l = context.l10n;
    final filtered = [
      for (final r in all)
        if (_query.isEmpty ||
            r.fullName.toLowerCase().contains(_query) ||
            (r.description ?? '').toLowerCase().contains(_query))
          r,
    ];
    filtered.sort(
      (a, b) => _sort == RepoSort.name
          ? a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase())
          : b.updatedAt.compareTo(a.updatedAt),
    );
    // Pinned repositories always come first (FR-16).
    final pinned = _query.isEmpty
        ? PinService.pinnedOf(all)
        : PinService.pinnedOf(filtered);
    final pinnedNames = {for (final r in pinned) r.fullName};
    final rest = [
      for (final r in filtered)
        if (!pinnedNames.contains(r.fullName)) r,
    ];
    final recent = _query.isEmpty
        ? ([
                for (final r in rest)
                  if (r.lastOpenedAt != null) r,
              ]..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!)))
              .take(5)
              .toList()
        : <RepositoryRef>[];
    final rows = <Object>[
      if (pinned.isNotEmpty) l.pinnedSection,
      ...pinned,
      if (recent.isNotEmpty) l.recent,
      ...recent,
      if (pinned.isNotEmpty || recent.isNotEmpty) l.allRepositories,
      ...rest,
    ];
    if (filtered.isEmpty) {
      return ListView(
        children: [
          EmptyState(
            icon: Icons.folder_off_outlined,
            message: l.noRepositories,
          ),
        ],
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row is String) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(row, style: Theme.of(context).textTheme.labelLarge),
          );
        }
        final r = row as RepositoryRef;
        return ListTile(
          leading: Icon(r.isPrivate ? Icons.lock_outline : Icons.book_outlined),
          title: Row(
            children: [
              Flexible(
                child: Text(r.fullName, overflow: TextOverflow.ellipsis),
              ),
              if (r.isPrivate) ...[const SizedBox(width: 6), Badge2(l.private)],
              if (r.isOffline) ...[
                const SizedBox(width: 6),
                Badge2(
                  l.offlineBadge,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ],
            ],
          ),
          subtitle: Text(
            [
              if (r.description != null && r.description!.isNotEmpty)
                r.description!,
              MaterialLocalizations.of(context).formatMediumDate(r.updatedAt),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            key: Key('pin-${r.fullName}'),
            tooltip: r.isPinned ? l.unpin : l.pin,
            icon: Icon(r.isPinned ? Icons.push_pin : Icons.push_pin_outlined),
            color: r.isPinned ? Theme.of(context).colorScheme.primary : null,
            onPressed: () => _togglePin(r),
          ),
          onTap: () => context.go('/ws/${r.fullName}'),
          onLongPress: () => _menu(r),
        );
      },
    );
  }
}
