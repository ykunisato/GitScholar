import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/infrastructure/local/app_database.dart';

/// Schema v1 had no pinning or offline columns (docs/03_data_model.md §2).
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    dir = await Directory.systemTemp.createTemp('gitscholar_migration');
    file = File('${dir.path}/db.sqlite');
  });
  tearDown(() => dir.delete(recursive: true));

  test('upgrades a v1 database and keeps existing rows', () async {
    // Build the current schema, then strip it back to v1.
    final v2 = AppDatabase(NativeDatabase(file));
    await v2.customStatement('SELECT 1');
    await v2
        .into(v2.repositories)
        .insert(
          RepositoriesCompanion.insert(
            fullName: 'alice/research',
            owner: 'alice',
            name: 'research',
            isPrivate: true,
            defaultBranch: 'main',
            description: const Value('notes'),
            updatedAt: DateTime(2026),
          ),
        );
    for (final column in [
      'pinned_at',
      'offline_paths_json',
      'offline_commit_sha',
      'offline_updated_at',
    ]) {
      await v2.customStatement('ALTER TABLE repositories DROP COLUMN $column');
    }
    await v2.customStatement('PRAGMA user_version = 1');
    await v2.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    final repo = await upgraded.repository('alice/research');
    expect(repo, isNotNull);
    expect(repo!.description, 'notes');
    expect(repo.isPinned, isFalse);
    expect(repo.isOffline, isFalse);

    // The new columns work after the upgrade.
    await upgraded.setPinnedAt('alice/research', DateTime(2026, 2));
    await upgraded.setOfflineState(
      'alice/research',
      paths: const ['notes'],
      commitSha: 'c1',
      updatedAt: DateTime(2026, 3),
    );
    final after = (await upgraded.repository('alice/research'))!;
    expect(after.isPinned, isTrue);
    expect(after.offlinePaths, ['notes']);
    expect(after.offlineCommitSha, 'c1');
    expect(await upgraded.pinnedCount(), 1);
    expect(await upgraded.offlineRepoFullNames(), {'alice/research'});
    await upgraded.close();
  });
}
