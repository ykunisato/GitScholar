import 'dart:convert';
import 'dart:typed_data';

import 'package:github_api/github_api.dart' show gitBlobSha;
import 'package:uuid/uuid.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/services/path_utils.dart';
import '../../infrastructure/local/app_database.dart';
import '../../infrastructure/local/blob_store.dart';
import '../workspace/workspace_service.dart';

/// Creates and updates pending changes (docs/06_editing_diff_commit.md §1).
class EditingService {
  EditingService({
    required this.db,
    required this.blobs,
    required this.workspaces,
    DateTime Function()? clock,
    String Function()? newId,
  }) : _clock = clock ?? DateTime.now,
       _newId = newId ?? const Uuid().v4;

  final AppDatabase db;
  final BlobStore blobs;
  final WorkspaceService workspaces;
  final DateTime Function() _clock;
  final String Function() _newId;

  Future<PendingChange?> _pendingAt(Workspace ws, String path) async {
    for (final c in await db.pendingChangesFor(ws.repo.fullName, ws.branch)) {
      if (c.isPending && c.path == path) return c;
    }
    return null;
  }

  /// Saves [text] for [path] (UTF-8).
  Future<PendingChange?> saveText(
    Workspace ws,
    String path,
    String text, {
    ChangeOrigin origin = ChangeOrigin.user,
  }) => saveBytes(
    ws,
    path,
    Uint8List.fromList(utf8.encode(text)),
    origin: origin,
  );

  /// Upserts the pending change for [path]. Returns null when the content
  /// equals the committed version (the change is removed).
  Future<PendingChange?> saveBytes(
    Workspace ws,
    String rawPath,
    Uint8List bytes, {
    ChangeOrigin origin = ChangeOrigin.user,
  }) async {
    final path = normalizePath(rawPath);
    final sha = gitBlobSha(bytes);
    final now = _clock();
    final existing = await _pendingAt(ws, path);
    if (existing != null) {
      if (existing.kind == ChangeKind.delete) {
        throw ValidationFailure('File is scheduled for deletion: $path');
      }
      if (existing.kind == ChangeKind.modify && sha == existing.baseBlobSha) {
        await db.deletePendingChange(existing.id);
        return null;
      }
      await blobs.write(sha, bytes, repoFullName: ws.repo.fullName);
      final updated = existing.copyWith(
        contentSha: sha,
        origin: existing.origin == ChangeOrigin.ai || origin == ChangeOrigin.ai
            ? ChangeOrigin.ai
            : ChangeOrigin.user,
        updatedAt: now,
      );
      await db.putPendingChange(updated);
      return updated;
    }
    final entry = ws.entry(path);
    if (entry != null && entry.sha == sha) return null;
    await blobs.write(sha, bytes, repoFullName: ws.repo.fullName);
    final change = PendingChange(
      id: _newId(),
      repoFullName: ws.repo.fullName,
      branch: ws.branch,
      path: path,
      kind: entry == null ? ChangeKind.create : ChangeKind.modify,
      origin: origin,
      status: ChangeStatus.pending,
      baseBlobSha: entry?.sha,
      baseCommitSha: ws.baseCommitSha,
      contentSha: sha,
      createdAt: now,
      updatedAt: now,
    );
    await db.putPendingChange(change);
    return change;
  }

  /// Creates a new (empty or given) file.
  Future<PendingChange> createFile(
    Workspace ws,
    String rawPath, [
    Uint8List? bytes,
  ]) async {
    final path = normalizePath(rawPath);
    if (await exists(ws, path)) {
      throw ValidationFailure('Already exists: $path');
    }
    final content = bytes ?? Uint8List(0);
    final sha = gitBlobSha(content);
    await blobs.write(sha, content, repoFullName: ws.repo.fullName);
    final now = _clock();
    final change = PendingChange(
      id: _newId(),
      repoFullName: ws.repo.fullName,
      branch: ws.branch,
      path: path,
      kind: ChangeKind.create,
      origin: ChangeOrigin.user,
      status: ChangeStatus.pending,
      baseCommitSha: ws.baseCommitSha,
      contentSha: sha,
      createdAt: now,
      updatedAt: now,
    );
    await db.putPendingChange(change);
    return change;
  }

  /// Whether [path] exists in the effective tree (remote plus pending).
  Future<bool> exists(Workspace ws, String path) async {
    final pending = await db.pendingChangesFor(ws.repo.fullName, ws.branch);
    for (final c in pending.where((c) => c.isPending)) {
      if (c.path == path) return c.kind != ChangeKind.delete;
      if (c.kind == ChangeKind.rename && c.oldPath == path) return false;
    }
    return ws.entry(path) != null;
  }

  /// Schedules [path] for deletion. Returns null if it only discarded a
  /// pending create.
  Future<PendingChange?> deleteFile(Workspace ws, String rawPath) async {
    final path = normalizePath(rawPath);
    final existing = await _pendingAt(ws, path);
    final now = _clock();
    if (existing != null) {
      switch (existing.kind) {
        case ChangeKind.create:
          await db.deletePendingChange(existing.id);
          return null;
        case ChangeKind.delete:
          return existing;
        case ChangeKind.modify:
          final updated = existing.copyWith(
            kind: ChangeKind.delete,
            clearContent: true,
            updatedAt: now,
          );
          await db.putPendingChange(updated);
          return updated;
        case ChangeKind.rename:
          // Deleting a renamed file deletes the original.
          await db.deletePendingChange(existing.id);
          return deleteFile(ws, existing.oldPath!);
      }
    }
    final entry = ws.entry(path);
    if (entry == null) throw NotFoundFailure('Not found: $path');
    final change = PendingChange(
      id: _newId(),
      repoFullName: ws.repo.fullName,
      branch: ws.branch,
      path: path,
      kind: ChangeKind.delete,
      origin: ChangeOrigin.user,
      status: ChangeStatus.pending,
      baseBlobSha: entry.sha,
      baseCommitSha: ws.baseCommitSha,
      createdAt: now,
      updatedAt: now,
    );
    await db.putPendingChange(change);
    return change;
  }

  /// Renames [rawFrom] to [rawTo], keeping content changes.
  Future<PendingChange> renameFile(
    Workspace ws,
    String rawFrom,
    String rawTo,
  ) async {
    final from = normalizePath(rawFrom);
    final to = normalizePath(rawTo);
    if (from == to) throw const ValidationFailure('Same path');
    if (await exists(ws, to)) throw ValidationFailure('Already exists: $to');
    final now = _clock();
    final existing = await _pendingAt(ws, from);
    if (existing != null) {
      switch (existing.kind) {
        case ChangeKind.delete:
          throw NotFoundFailure('Deleted: $from');
        case ChangeKind.create:
        case ChangeKind.rename:
          final updated = existing.copyWith(path: to, updatedAt: now);
          await db.putPendingChange(updated);
          return updated;
        case ChangeKind.modify:
          final updated = existing.copyWith(
            kind: ChangeKind.rename,
            oldPath: from,
            path: to,
            updatedAt: now,
          );
          await db.putPendingChange(updated);
          return updated;
      }
    }
    final entry = ws.entry(from);
    if (entry == null) throw NotFoundFailure('Not found: $from');
    // Commit needs the bytes to create the blob, so make sure they are cached.
    await workspaces.loadBlob(ws, from, entry.sha, size: entry.size);
    final change = PendingChange(
      id: _newId(),
      repoFullName: ws.repo.fullName,
      branch: ws.branch,
      path: to,
      oldPath: from,
      kind: ChangeKind.rename,
      origin: ChangeOrigin.user,
      status: ChangeStatus.pending,
      baseBlobSha: entry.sha,
      baseCommitSha: ws.baseCommitSha,
      contentSha: entry.sha,
      createdAt: now,
      updatedAt: now,
    );
    await db.putPendingChange(change);
    return change;
  }

  /// Discards a pending or proposed change.
  Future<void> discard(String id) => db.deletePendingChange(id);
}
