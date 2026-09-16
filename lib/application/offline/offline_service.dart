import 'dart:async';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/services/ignore_rules.dart';
import '../../infrastructure/local/app_database.dart';
import '../../infrastructure/local/blob_store.dart';
import '../workspace/workspace_service.dart';

/// Size of an offline selection (FR-27).
class OfflineEstimate {
  const OfflineEstimate({
    required this.totalFiles,
    required this.totalBytes,
    required this.cachedFiles,
    required this.cachedBytes,
    required this.skippedFiles,
  });

  final int totalFiles;
  final int totalBytes;

  /// Files already on the device.
  final int cachedFiles;
  final int cachedBytes;

  /// Files left out because they are ignored or too large.
  final int skippedFiles;

  int get missingFiles => totalFiles - cachedFiles;
  int get missingBytes => totalBytes - cachedBytes;
}

/// Progress of a download.
class OfflineProgress {
  const OfflineProgress({
    required this.done,
    required this.total,
    this.failed = 0,
    this.bytes = 0,
    this.currentPath,
    this.finished = false,
    this.cancelled = false,
  });

  final int done;
  final int total;
  final int failed;

  /// Bytes downloaded in this run.
  final int bytes;
  final String? currentPath;
  final bool finished;
  final bool cancelled;

  double get fraction => total == 0 ? 1 : done / total;
}

/// Downloads repository files for offline use and keeps them out of cache
/// eviction (FR-27, FR-28, FR-29, FR-30b).
class OfflineService {
  OfflineService({
    required this.db,
    required this.blobs,
    required this.workspaces,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final BlobStore blobs;
  final WorkspaceService workspaces;
  final DateTime Function() _clock;

  /// Files larger than this are never downloaded in bulk.
  static const maxFileBytes = 100 * 1024 * 1024;

  /// Top-level directories of the workspace, for the selection UI.
  static List<String> topLevelFolders(Workspace ws) {
    final out = <String>{};
    for (final e in ws.entries) {
      if (e.type != TreeEntryType.tree) continue;
      if (!e.path.contains('/')) out.add(e.path);
    }
    final list = out.toList()..sort();
    return list;
  }

  /// Blobs covered by [prefixes] (empty means the whole repository),
  /// excluding ignored and oversized files.
  static List<TreeEntry> targets(
    Workspace ws,
    List<String> prefixes,
    IgnoreRules rules,
  ) => [
    for (final e in ws.blobs)
      if (_covered(e.path, prefixes) &&
          !rules.isIgnored(e.path) &&
          (e.size ?? 0) <= maxFileBytes)
        e,
  ];

  /// Files left out of [targets] because of ignore rules or size.
  static int skippedCount(
    Workspace ws,
    List<String> prefixes,
    IgnoreRules rules,
  ) => [
    for (final e in ws.blobs)
      if (_covered(e.path, prefixes) &&
          (rules.isIgnored(e.path) || (e.size ?? 0) > maxFileBytes))
        e,
  ].length;

  static bool _covered(String path, List<String> prefixes) =>
      prefixes.isEmpty ||
      prefixes.any((p) => path == p || path.startsWith('$p/'));

  /// Counts and sizes for the selection.
  Future<OfflineEstimate> estimate(
    Workspace ws,
    List<String> prefixes,
    IgnoreRules rules,
  ) async {
    final entries = targets(ws, prefixes, rules);
    var cachedFiles = 0;
    var cachedBytes = 0;
    var totalBytes = 0;
    for (final e in entries) {
      final size = e.size ?? 0;
      totalBytes += size;
      if (await blobs.exists(e.sha)) {
        cachedFiles++;
        cachedBytes += size;
      }
    }
    return OfflineEstimate(
      totalFiles: entries.length,
      totalBytes: totalBytes,
      cachedFiles: cachedFiles,
      cachedBytes: cachedBytes,
      skippedFiles: skippedCount(ws, prefixes, rules),
    );
  }

  /// Downloads the missing files, emitting progress after each one.
  ///
  /// The repository is marked offline before the first download so the files
  /// are protected from cache eviction while they arrive. Cancelling the
  /// stream subscription stops after the current file and keeps what was
  /// already downloaded.
  Stream<OfflineProgress> download(
    Workspace ws, {
    required List<String> prefixes,
    required IgnoreRules rules,
  }) async* {
    final entries = targets(ws, prefixes, rules);
    // Mark the copy as partial up front: the repository counts as offline
    // straight away (so the files are protected from eviction), but no commit
    // is recorded until a full pass finishes. A cancelled or failed run
    // therefore leaves the copy marked partial without relying on cleanup.
    await db.setOfflineState(
      ws.repo.fullName,
      paths: List.unmodifiable(prefixes),
      updatedAt: _clock(),
    );
    var done = 0;
    var failed = 0;
    var bytes = 0;
    yield OfflineProgress(done: 0, total: entries.length);
    for (final e in entries) {
      if (await blobs.exists(e.sha)) {
        done++;
        yield OfflineProgress(
          done: done,
          total: entries.length,
          failed: failed,
          bytes: bytes,
          currentPath: e.path,
        );
        continue;
      }
      try {
        final f = await workspaces.loadBlob(ws, e.path, e.sha, size: e.size);
        bytes += f.size;
      } on AppFailure {
        failed++;
      }
      done++;
      yield OfflineProgress(
        done: done,
        total: entries.length,
        failed: failed,
        bytes: bytes,
        currentPath: e.path,
      );
    }
    // Everything was visited: record the commit the copy matches.
    await db.setOfflineState(
      ws.repo.fullName,
      paths: List.unmodifiable(prefixes),
      commitSha: ws.baseCommitSha,
      updatedAt: _clock(),
    );
    yield OfflineProgress(
      done: done,
      total: entries.length,
      failed: failed,
      bytes: bytes,
      finished: true,
    );
  }

  /// Offline files whose remote SHA changed since the download (FR-29).
  Future<List<TreeEntry>> outdated(Workspace ws, IgnoreRules rules) async {
    final repo = await db.repository(ws.repo.fullName) ?? ws.repo;
    final prefixes = repo.offlinePaths;
    if (prefixes == null) return const [];
    final out = <TreeEntry>[];
    for (final e in targets(ws, prefixes, rules)) {
      if (!await blobs.exists(e.sha)) out.add(e);
    }
    return out;
  }

  /// Turns offline use off and optionally deletes the downloaded files.
  Future<void> remove(RepositoryRef repo, {bool deleteFiles = true}) async {
    await db.setOfflineState(repo.fullName, paths: null);
    if (deleteFiles) await blobs.deleteForRepo(repo.fullName);
  }
}
