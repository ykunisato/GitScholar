import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:gitscholar/application/editing/commit_service.dart';
import 'package:gitscholar/application/editing/editing_service.dart';
import 'package:gitscholar/application/workspace/workspace_service.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/infrastructure/local/app_database.dart';
import 'package:gitscholar/infrastructure/local/blob_store.dart';

import 'fake_github.dart';

/// Wires services against an in-memory DB, temp blob dir and FakeGitHub.
class TestEnv {
  TestEnv._(this.dir, this.db, this.blobs, this.github)
    : workspaces = WorkspaceService(github: github, db: db, blobs: blobs) {
    editing = EditingService(db: db, blobs: blobs, workspaces: workspaces);
    commits = CommitService(
      github: github,
      db: db,
      blobs: blobs,
      workspaces: workspaces,
    );
  }

  static Future<TestEnv> create({FakeGitHub? github}) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final dir = await Directory.systemTemp.createTemp('gitscholar_test');
    final db = AppDatabase(NativeDatabase.memory());
    return TestEnv._(
      dir,
      db,
      FileBlobStore(root: dir, db: db),
      github ?? FakeGitHub(),
    );
  }

  final Directory dir;
  final AppDatabase db;
  final FileBlobStore blobs;
  final FakeGitHub github;
  final WorkspaceService workspaces;
  late final EditingService editing;
  late final CommitService commits;

  RepositoryRef get repo => FakeGitHub.repo;

  Future<Workspace> open([String branch = 'main']) async {
    await db.upsertRepositories([repo]);
    return (await workspaces.refresh(repo, branch)).workspace;
  }

  Future<List<PendingChange>> pending(Workspace ws) =>
      db.pendingChangesFor(ws.repo.fullName, ws.branch);

  Future<void> dispose() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
