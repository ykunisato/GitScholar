import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'app_database.dart';

/// Content-addressed file cache keyed by Git blob SHA
/// (docs/03_data_model.md §3).
abstract class BlobStore {
  Future<Uint8List?> read(String sha);
  Future<void> write(String sha, Uint8List bytes, {String? repoFullName});
  Future<bool> exists(String sha);
  Future<void> delete(String sha);
  Future<int> totalSize();
  Future<int> sizeForRepo(String repoFullName);

  /// Deletes least-recently-used blobs until at most [targetBytes] remain.
  /// Blobs referenced by pending changes are kept.
  Future<void> evict({required int targetBytes});

  /// Deletes blobs cached for [repoFullName] (except pinned ones).
  Future<void> deleteForRepo(String repoFullName);

  /// Deletes all unpinned blobs.
  Future<void> clear();
}

/// [BlobStore] backed by files under a directory plus DB metadata.
class FileBlobStore implements BlobStore {
  FileBlobStore({required this.root, required this.db});

  final Directory root;
  final AppDatabase db;

  File _file(String sha) {
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) {
      throw ArgumentError.value(sha, 'sha', 'not a SHA-1');
    }
    return File(p.join(root.path, sha.substring(0, 2), sha));
  }

  @override
  Future<Uint8List?> read(String sha) async {
    final f = _file(sha);
    if (!await f.exists()) return null;
    await db.touchBlob(sha);
    return f.readAsBytes();
  }

  @override
  Future<void> write(
    String sha,
    Uint8List bytes, {
    String? repoFullName,
  }) async {
    final f = _file(sha);
    if (!await f.exists()) {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    }
    await db.recordBlob(sha, bytes.length, repoFullName: repoFullName);
  }

  @override
  Future<bool> exists(String sha) => _file(sha).exists();

  @override
  Future<void> delete(String sha) async {
    final f = _file(sha);
    if (await f.exists()) await f.delete();
    await db.forgetBlob(sha);
  }

  @override
  Future<int> totalSize() => db.totalBlobBytes();

  @override
  Future<int> sizeForRepo(String repoFullName) =>
      db.blobBytesForRepo(repoFullName);

  @override
  Future<void> evict({required int targetBytes}) async {
    var total = await totalSize();
    if (total <= targetBytes) return;
    final pinned = await db.pinnedBlobShas();
    final offlineRepos = await db.offlineRepoFullNames();
    for (final row in await db.blobsByLastAccess()) {
      if (total <= targetBytes) break;
      if (pinned.contains(row.sha)) continue;
      // Files kept for offline use are never evicted (FR-28).
      if (row.repoFullName != null && offlineRepos.contains(row.repoFullName)) {
        continue;
      }
      await delete(row.sha);
      total -= row.size;
    }
  }

  @override
  Future<void> deleteForRepo(String repoFullName) async {
    final pinned = await db.pinnedBlobShas();
    for (final sha in await db.blobShasForRepo(repoFullName)) {
      if (!pinned.contains(sha)) await delete(sha);
    }
  }

  @override
  Future<void> clear() async {
    final pinned = await db.pinnedBlobShas();
    final offlineRepos = await db.offlineRepoFullNames();
    for (final row in await db.blobsByLastAccess()) {
      if (pinned.contains(row.sha)) continue;
      if (row.repoFullName != null && offlineRepos.contains(row.repoFullName)) {
        continue;
      }
      await delete(row.sha);
    }
  }
}
