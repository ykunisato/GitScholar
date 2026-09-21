import 'dart:typed_data';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/repositories/github_repository.dart';
import '../../infrastructure/local/app_database.dart';
import '../../infrastructure/local/blob_store.dart';
import '../workspace/workspace_service.dart';

/// Result of [CommitService.commit].
class CommitOutcome {
  const CommitOutcome(this.result, this.workspace);

  final CommitResult result;
  final Workspace workspace;
}

/// Commits pending changes (docs/06_editing_diff_commit.md §3-5).
class CommitService {
  CommitService({
    required this.github,
    required this.db,
    required this.blobs,
    required this.workspaces,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final GitHubRepository github;
  final AppDatabase db;
  final BlobStore blobs;
  final WorkspaceService workspaces;
  final DateTime Function() _clock;

  /// Commits [changeIds] as one commit on the workspace branch (or on
  /// [newBranch]). Paths in [overwritePaths] are committed even if the
  /// remote changed them. Never force-pushes.
  Future<CommitOutcome> commit(
    Workspace workspace,
    List<String> changeIds, {
    required String message,
    String? newBranch,
    Set<String> overwritePaths = const {},
  }) async {
    if (message.trim().isEmpty) {
      throw const ValidationFailure('Commit message is empty');
    }
    if (changeIds.isEmpty) throw const ValidationFailure('No changes selected');
    final all = await db.pendingChangesFor(
      workspace.repo.fullName,
      workspace.branch,
    );
    final changes = [
      for (final c in all)
        if (changeIds.contains(c.id)) c,
    ];
    if (changes.length != changeIds.toSet().length) {
      throw const NotFoundFailure('Some changes no longer exist');
    }
    if (changes.any((c) => !c.isPending)) {
      throw const ValidationFailure(
        'Proposed changes must be approved before committing',
      );
    }

    final repo = workspace.repo;
    var ws = workspace;
    var branch = workspace.branch;
    final remoteHead = await github.branchHead(repo, branch);

    if (remoteHead != ws.baseCommitSha) {
      // docs/06 §4: compare against the new remote tree.
      final treeSha = await github.commitTreeSha(repo, remoteHead);
      final tree = await github.tree(repo, treeSha);
      ws = ws.copyWith(
        baseCommitSha: remoteHead,
        treeSha: tree.sha,
        entries: tree.entries,
        truncated: tree.truncated,
        fetchedAt: _clock(),
      );
      await db.saveWorkspace(ws);
      await workspaces.markUpstreamChanges(ws);
      final conflicts = <String>[];
      for (final c in changes) {
        if (!WorkspaceService.isUpstreamChanged(c, ws)) continue;
        if (c.kind == ChangeKind.delete && ws.entry(c.path) == null) continue;
        if (!overwritePaths.contains(c.path)) conflicts.add(c.path);
      }
      if (conflicts.isNotEmpty) {
        throw ConflictFailure(
          'Remote changed the same files',
          conflictingPaths: conflicts,
        );
      }
    }

    final parent = ws.baseCommitSha;
    final targetBranch = newBranch?.trim() ?? '';
    if (targetBranch.isNotEmpty) {
      branch = targetBranch;
      await github.createBranch(repo, branch, parent);
    }

    // Deleting a file that no longer exists remotely is a no-op.
    final effective = [
      for (final c in changes)
        if (!(c.kind == ChangeKind.delete && ws.entry(c.path) == null)) c,
    ];

    final sizes = <String, int>{};
    String commitSha;
    String treeSha;
    if (effective.isEmpty) {
      commitSha = parent;
      treeSha = ws.treeSha;
    } else if (effective.length == 1 &&
        (effective.single.kind == ChangeKind.modify ||
            effective.single.kind == ChangeKind.create)) {
      final c = effective.single;
      final bytes = await _bytes(c);
      sizes[c.path] = bytes.length;
      final r = await github.putFile(
        repo,
        c.path,
        bytes: bytes,
        message: message,
        branch: branch,
        sha: ws.entry(c.path)?.sha,
      );
      commitSha = r.commitSha;
      treeSha = r.treeSha;
    } else {
      final items = <TreeChange>[];
      for (final c in effective) {
        switch (c.kind) {
          case ChangeKind.delete:
            items.add(TreeChange(c.path, null));
          case ChangeKind.rename
              when c.contentSha != null && c.contentSha == c.baseBlobSha:
            // 内容が変わらない移動・リネームは、既にGitにあるblobをそのまま
            // 指せばよい。実体を送り直さないので、Git LFS のポインタが
            // 実体に置き換わってしまうこともない（FR-49, FR-102）。
            final size = ws.entry(c.oldPath!)?.size;
            if (size != null) sizes[c.path] = size;
            items.add(TreeChange(c.oldPath!, null));
            items.add(TreeChange(c.path, c.contentSha!));
          case ChangeKind.modify:
          case ChangeKind.create:
          case ChangeKind.rename:
            final bytes = await _bytes(c);
            sizes[c.path] = bytes.length;
            final sha = await github.createBlob(repo, bytes);
            if (sha != c.contentSha) {
              throw ValidationFailure('Blob SHA mismatch for ${c.path}');
            }
            if (c.kind == ChangeKind.rename) {
              items.add(TreeChange(c.oldPath!, null));
            }
            items.add(TreeChange(c.path, sha));
        }
      }
      treeSha = await github.createTree(
        repo,
        baseTree: ws.treeSha,
        changes: items,
      );
      commitSha = await github.createCommit(
        repo,
        message: message,
        tree: treeSha,
        parents: [parent],
      );
      await github.updateBranch(repo, branch, commitSha);
    }

    // Update local state without refetching the whole tree (docs/06 §3.2 step 5).
    final entries = {for (final e in ws.entries) e.path: e};
    for (final c in changes) {
      switch (c.kind) {
        case ChangeKind.delete:
          entries.remove(c.path);
        case ChangeKind.rename:
          entries.remove(c.oldPath);
          entries[c.path] = TreeEntry(
            path: c.path,
            type: TreeEntryType.blob,
            sha: c.contentSha!,
            size: sizes[c.path],
          );
        case ChangeKind.modify:
        case ChangeKind.create:
          entries[c.path] = TreeEntry(
            path: c.path,
            type: TreeEntryType.blob,
            sha: c.contentSha!,
            size: sizes[c.path],
          );
      }
    }
    final updated = ws.copyWith(
      branch: branch,
      baseCommitSha: commitSha,
      treeSha: treeSha,
      entries: entries.values.toList(),
      fetchedAt: _clock(),
    );
    await db.transaction(() async {
      for (final c in changes) {
        await db.deletePendingChange(c.id);
      }
      await db.saveWorkspace(updated);
      if (branch == workspace.branch) {
        for (final c in await db.pendingChangesFor(repo.fullName, branch)) {
          await db.putPendingChange(c.copyWith(baseCommitSha: commitSha));
        }
      }
    });
    return CommitOutcome(
      CommitResult(
        commitSha: commitSha,
        branch: branch,
        committedPaths: [for (final c in changes) c.path],
      ),
      updated,
    );
  }

  Future<Uint8List> _bytes(PendingChange c) async {
    final bytes = await blobs.read(c.contentSha!);
    if (bytes == null) throw ValidationFailure('Content missing for ${c.path}');
    return bytes;
  }
}
