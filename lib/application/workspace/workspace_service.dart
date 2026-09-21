import 'package:github_api/github_api.dart' show LfsPointer;
import 'dart:typed_data';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/repositories/github_repository.dart';
import '../../domain/services/file_kind_detector.dart';
import '../../domain/services/path_utils.dart';
import '../../infrastructure/local/app_database.dart';
import '../../infrastructure/local/blob_store.dart';

/// Outcome of [WorkspaceService.refresh].
class RefreshResult {
  const RefreshResult(
    this.workspace, {
    required this.changed,
    this.changedPaths = const {},
  });

  final Workspace workspace;
  final bool changed;

  /// Blob paths whose SHA changed (or appeared/disappeared).
  final Set<String> changedPaths;
}

/// Opening, refreshing and reading workspaces (docs/04_github_integration.md §3).
class WorkspaceService {
  WorkspaceService({
    required this.github,
    required this.db,
    required this.blobs,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final GitHubRepository github;
  final AppDatabase db;
  final BlobStore blobs;
  final DateTime Function() _clock;

  /// Maximum blob size fetched from GitHub.
  static const maxBlobBytes = 100 * 1024 * 1024;

  /// Repositories from GitHub, cached in the DB; falls back to the cache
  /// when offline.
  Future<List<RepositoryRef>> listRepositories({
    bool forceRemote = true,
    void Function(int)? onProgress,
  }) async {
    if (forceRemote) {
      try {
        final remote = await github.listRepositories(onProgress: onProgress);
        await db.upsertRepositories(remote);
      } on NetworkFailure {
        final cached = await db.allRepositories();
        if (cached.isEmpty) rethrow;
      }
    }
    return db.allRepositories();
  }

  /// Cached workspace, if any.
  Future<Workspace?> cached(RepositoryRef repo, String branch) =>
      db.loadWorkspace(repo, branch);

  /// Fetches the branch head and tree when they changed.
  Future<RefreshResult> refresh(
    RepositoryRef repo,
    String branch, {
    Workspace? current,
  }) async {
    final head = await github.branchHead(repo, branch);
    if (current != null && current.baseCommitSha == head) {
      return RefreshResult(current, changed: false);
    }
    final treeSha = await github.commitTreeSha(repo, head);
    final tree = await github.tree(repo, treeSha);
    final ws = Workspace(
      repo: repo,
      branch: branch,
      baseCommitSha: head,
      treeSha: tree.sha,
      entries: tree.entries,
      truncated: tree.truncated,
      fetchedAt: _clock(),
    );
    await db.saveWorkspace(ws);
    await markUpstreamChanges(ws);
    return RefreshResult(
      ws,
      changed: true,
      changedPaths: changedBlobPaths(current, ws),
    );
  }

  /// Paths whose blob SHA differs between two workspaces.
  static Set<String> changedBlobPaths(Workspace? a, Workspace b) {
    if (a == null) return const {};
    final out = <String>{};
    for (final e in b.blobs) {
      if (a.entry(e.path)?.sha != e.sha) out.add(e.path);
    }
    for (final e in a.blobs) {
      if (b.entry(e.path) == null) out.add(e.path);
    }
    return out;
  }

  /// Flags pending changes whose base no longer matches the remote tree
  /// (docs/04 §3.2 step 6).
  Future<void> markUpstreamChanges(Workspace ws) async {
    for (final c in await db.pendingChangesFor(ws.repo.fullName, ws.branch)) {
      final changed = isUpstreamChanged(c, ws);
      if (changed != c.upstreamChanged) {
        await db.putPendingChange(c.copyWith(upstreamChanged: changed));
      }
    }
  }

  /// Whether the remote state of [c]'s paths differs from its base.
  static bool isUpstreamChanged(PendingChange c, Workspace remote) {
    switch (c.kind) {
      case ChangeKind.create:
        return remote.entry(c.path) != null;
      case ChangeKind.modify:
      case ChangeKind.delete:
        return remote.entry(c.path)?.sha != c.baseBlobSha;
      case ChangeKind.rename:
        return remote.entry(c.oldPath!)?.sha != c.baseBlobSha ||
            remote.entry(c.path) != null;
    }
  }

  /// Loads a file: pending change, then cache, then GitHub
  /// (docs/04 §3.3).
  Future<FileContent> loadFile(Workspace ws, String rawPath) async {
    final path = normalizePath(rawPath);
    final pending = await db.pendingChangesFor(ws.repo.fullName, ws.branch);
    for (final c in pending) {
      if (!c.isPending) continue;
      if (c.path == path) {
        if (c.kind == ChangeKind.delete) {
          throw NotFoundFailure('Deleted: $path');
        }
        final bytes = await blobs.read(c.contentSha!);
        if (bytes == null && c.contentSha == c.baseBlobSha) {
          // 内容を変えない移動・リネームは実体を持たない。元のblobを読めば
          // よく、LFSならそこで実体が解決される（FR-49）。
          final loaded = await loadBlob(
            ws,
            path,
            c.contentSha!,
            size: ws.entry(c.oldPath ?? path)?.size,
          );
          return FileContent(
            path: path,
            bytes: loaded.bytes,
            kind: loaded.kind,
            source: ContentSource.pending,
            blobSha: c.contentSha,
          );
        }
        if (bytes == null) {
          throw ValidationFailure('Pending content missing for $path');
        }
        return FileContent(
          path: path,
          bytes: bytes,
          kind: FileKindDetector.fromContent(path, bytes),
          source: ContentSource.pending,
          blobSha: c.contentSha,
        );
      }
      if (c.kind == ChangeKind.rename && c.oldPath == path) {
        throw NotFoundFailure('Renamed: $path -> ${c.path}');
      }
    }
    final entry = ws.entry(path);
    if (entry == null || !entry.isBlob) {
      throw NotFoundFailure('Not found: $path');
    }
    return loadBlob(ws, path, entry.sha, size: entry.size);
  }

  /// Fetches the real content when [bytes] is a Git LFS pointer (FR-102),
  /// or null when it is already the content.
  ///
  /// The tree only knows the pointer's size, so the real size is checked here
  /// against the same limit.
  Future<Uint8List?> _resolveLfs(
    Workspace ws,
    String path,
    Uint8List bytes,
  ) async {
    final pointer = LfsPointer.parse(bytes);
    if (pointer == null) return null;
    if (pointer.size > maxBlobBytes) {
      throw ValidationFailure('File too large: $path');
    }
    return github.lfsObject(
      ws.repo,
      oid: pointer.oid,
      size: pointer.size,
      hashAlgo: pointer.hashAlgo,
    );
  }

  FileContent _content(
    String path,
    Uint8List bytes,
    String sha,
    ContentSource source,
  ) => FileContent(
    path: path,
    bytes: bytes,
    kind: FileKindDetector.fromContent(path, bytes),
    source: source,
    blobSha: sha,
  );

  /// Loads blob [sha] for [path] ignoring pending changes.
  Future<FileContent> loadBlob(
    Workspace ws,
    String path,
    String sha, {
    int? size,
  }) async {
    if ((size ?? 0) > maxBlobBytes) {
      throw ValidationFailure('File too large: $path');
    }
    var source = ContentSource.cache;
    Uint8List? bytes = await blobs.read(sha);
    if (bytes == null) {
      bytes = await github.blob(ws.repo, sha);
    } else {
      // LFS に対応する前に取り込んだキャッシュには、実体ではなくポインタが
      // 入っている。開くたびに壊れたままになるので、ここでも解決する。
      final resolved = await _resolveLfs(ws, path, bytes);
      if (resolved == null) return _content(path, bytes, sha, source);
      bytes = resolved;
      // 保存庫は同じSHAの ファイル があると書き込みを省く。ポインタを実体に
      // 差し替える場面では一度消す必要がある。
      await blobs.delete(sha);
      await blobs.write(sha, bytes, repoFullName: ws.repo.fullName);
      return _content(path, bytes, sha, ContentSource.remote);
    }
    bytes = await _resolveLfs(ws, path, bytes) ?? bytes;
    await blobs.write(sha, bytes, repoFullName: ws.repo.fullName);
    source = ContentSource.remote;
    return FileContent(
      path: path,
      bytes: bytes,
      kind: FileKindDetector.fromContent(path, bytes),
      source: source,
      blobSha: sha,
    );
  }

  /// Reads a text file if present, or null.
  Future<String?> tryReadText(Workspace ws, String path) async {
    try {
      return (await loadFile(ws, path)).text;
    } on NotFoundFailure {
      return null;
    }
  }
}
