import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/editing/change_diff.dart';
import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import 'commit_sheet.dart';
import 'diff_view.dart';

/// Loads diff contents for a change id.
final changeContentsProvider = FutureProvider.autoDispose
    .family<ChangeContents, String>((ref, id) async {
      final ws = ref.watch(currentWorkspaceProvider).value;
      final changes = ref.watch(pendingChangesProvider).value ?? const [];
      final change = changes.where((c) => c.id == id).firstOrNull;
      if (ws == null || change == null) {
        throw const NotFoundFailure('Change not found');
      }
      return ref.read(changeDiffLoaderProvider).load(ws, change);
    });

/// List of uncommitted changes (docs/06 §3.1).
class ChangesScreen extends ConsumerWidget {
  const ChangesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final changes = ref.watch(committableChangesProvider);
    final ws = ref.watch(currentWorkspaceProvider).value;
    return Scaffold(
      appBar: AppBar(title: Text(l.changesTitle(changes.length))),
      floatingActionButton: changes.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const Key('commitFab'),
              onPressed: () => showCommitSheet(context),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text(l.commit),
            ),
      body: ws == null
          ? const SizedBox.shrink()
          : changes.isEmpty
          ? EmptyState(icon: Icons.check_circle_outline, message: l.noChanges)
          : ListView.separated(
              itemCount: changes.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (context, i) => ChangeTile(change: changes[i]),
            ),
    );
  }
}

class ChangeTile extends ConsumerWidget {
  const ChangeTile({super.key, required this.change, this.onTap});

  final PendingChange change;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final colors = context.colors;
    final contents = ref.watch(changeContentsProvider(change.id));
    final stats = contents.value?.computeStats();
    final kindLabel = switch (change.kind) {
      ChangeKind.modify => l.kindModified,
      ChangeKind.create => l.kindCreated,
      ChangeKind.delete => l.kindDeleted,
      ChangeKind.rename => l.kindRenamed,
    };
    final ws = ref.watch(currentWorkspaceProvider).value;
    return ListTile(
      leading: Icon(switch (change.kind) {
        ChangeKind.create => Icons.add_circle_outline,
        ChangeKind.delete => Icons.remove_circle_outline,
        ChangeKind.rename => Icons.drive_file_rename_outline,
        ChangeKind.modify => Icons.edit_outlined,
      }),
      title: Text(change.path, overflow: TextOverflow.ellipsis),
      subtitle: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(kindLabel),
          if (stats != null) ...[
            Text(
              '+${stats.added}',
              style: TextStyle(color: colors.diffAddedText),
            ),
            Text(
              '-${stats.deleted}',
              style: TextStyle(color: colors.diffRemovedText),
            ),
          ],
          if (change.origin == ChangeOrigin.ai)
            Badge2('AI', color: colors.aiBadge),
          if (change.upstreamChanged)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber,
                  size: 14,
                  color: Theme.of(context).colorScheme.error,
                ),
                Text(
                  l.upstreamChanged,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: l.discard,
        icon: const Icon(Icons.undo),
        onPressed: () async {
          final ok = await confirmDialog(
            context,
            title: l.discard,
            message: l.discardConfirm(change.path),
            confirmLabel: l.discard,
            destructive: true,
          );
          if (ok) await ref.read(editingServiceProvider).discard(change.id);
        },
      ),
      onTap:
          onTap ??
          () => context.push('/ws/${ws!.repo.fullName}/changes/${change.id}'),
    );
  }
}

class DiffScreen extends ConsumerWidget {
  const DiffScreen({super.key, required this.changeId});

  final String changeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final contents = ref.watch(changeContentsProvider(changeId));
    final change = (ref.watch(pendingChangesProvider).value ?? const [])
        .where((c) => c.id == changeId)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Text(change?.path ?? l.diff, overflow: TextOverflow.ellipsis),
        actions: [
          if (change != null)
            IconButton(
              tooltip: l.discard,
              icon: const Icon(Icons.undo),
              onPressed: () async {
                final ok = await confirmDialog(
                  context,
                  title: l.discard,
                  message: l.discardConfirm(change.path),
                  confirmLabel: l.discard,
                  destructive: true,
                );
                if (ok) {
                  await ref.read(editingServiceProvider).discard(change.id);
                  if (context.mounted) context.pop();
                }
              },
            ),
        ],
      ),
      body: switch (contents) {
        AsyncData(:final value) => ChangeDiffView(contents: value),
        AsyncError(:final error) => FailureView(
          error: error,
          onRetry: () => ref.invalidate(changeContentsProvider(changeId)),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
