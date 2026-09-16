import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/entities/entities.dart';

part 'app_database.g.dart';

// Schema: docs/03_data_model.md §2.

@DataClassName('RepositoryRow')
class Repositories extends Table {
  TextColumn get fullName => text()();
  TextColumn get owner => text()();
  TextColumn get name => text()();
  BoolColumn get isPrivate => boolean()();
  TextColumn get defaultBranch => text()();
  TextColumn get description => text().nullable()();
  TextColumn get htmlUrl => text().nullable()();
  TextColumn get aiAccess => text().withDefault(const Constant('ask'))();
  DateTimeColumn get lastOpenedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  /// When the user pinned the repository (FR-16); null when not pinned.
  DateTimeColumn get pinnedAt => dateTime().nullable()();

  /// JSON list of path prefixes kept offline; empty list means the whole
  /// repository. Null when offline use is off (FR-27).
  TextColumn get offlinePathsJson => text().nullable()();

  /// Commit the offline copy was downloaded from.
  TextColumn get offlineCommitSha => text().nullable()();
  DateTimeColumn get offlineUpdatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {fullName};
}

@DataClassName('WorkspaceRow')
class Workspaces extends Table {
  TextColumn get repoFullName => text()();
  TextColumn get branch => text()();
  TextColumn get baseCommitSha => text()();
  TextColumn get treeSha => text()();
  BoolColumn get truncated => boolean()();
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {repoFullName, branch};
}

@DataClassName('TreeEntryRow')
class TreeEntries extends Table {
  TextColumn get repoFullName => text()();
  TextColumn get branch => text()();
  TextColumn get path => text()();
  TextColumn get type => text()();
  TextColumn get sha => text()();
  IntColumn get size => integer().nullable()();
  TextColumn get mode => text()();

  @override
  Set<Column> get primaryKey => {repoFullName, branch, path};
}

@DataClassName('BlobRow')
class Blobs extends Table {
  TextColumn get sha => text()();
  IntColumn get size => integer()();
  TextColumn get repoFullName => text().nullable()();
  DateTimeColumn get cachedAt => dateTime()();
  DateTimeColumn get lastAccessAt => dateTime()();

  @override
  Set<Column> get primaryKey => {sha};
}

@DataClassName('PendingChangeRow')
class PendingChanges extends Table {
  TextColumn get id => text()();
  TextColumn get repoFullName => text()();
  TextColumn get branch => text()();
  TextColumn get path => text()();
  TextColumn get oldPath => text().nullable()();
  TextColumn get kind => text()();
  TextColumn get origin => text()();
  TextColumn get status => text()();
  TextColumn get baseBlobSha => text().nullable()();
  TextColumn get baseCommitSha => text()();
  TextColumn get contentBlobSha => text().nullable()();
  TextColumn get proposalId => text().nullable()();
  BoolColumn get upstreamChanged =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ConversationRow')
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get repoFullName => text()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MessageRow')
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => text()();
  TextColumn get blocksJson => text()();
  TextColumn get usageJson => text().nullable()();
  TextColumn get model => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ProposalRow')
class Proposals extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text()();
  TextColumn get path => text()();
  TextColumn get kind => text()();
  TextColumn get explanation => text()();
  TextColumn get status => text()();
  TextColumn get pendingChangeId => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CommitRequestRow')
class CommitRequests extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text()();
  TextColumn get message => text()();
  TextColumn get pathsJson => text()();
  TextColumn get status => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('KeyValueRow')
class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get valueJson => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
  tables: [
    Repositories,
    Workspaces,
    TreeEntries,
    Blobs,
    PendingChanges,
    Conversations,
    Messages,
    Proposals,
    CommitRequests,
    KeyValues,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tree_entries_sha ON tree_entries(sha)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_pending_repo ON pending_changes(repo_full_name, branch, status)',
      );
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // Pinning and offline availability (FR-16, FR-27).
        await m.addColumn(repositories, repositories.pinnedAt);
        await m.addColumn(repositories, repositories.offlinePathsJson);
        await m.addColumn(repositories, repositories.offlineCommitSha);
        await m.addColumn(repositories, repositories.offlineUpdatedAt);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  // ---------------------------------------------------------------- repos

  Future<void> upsertRepositories(List<RepositoryRef> repos) async {
    await batch((b) {
      for (final r in repos) {
        b.insert(
          repositories,
          RepositoriesCompanion.insert(
            fullName: r.fullName,
            owner: r.owner,
            name: r.name,
            isPrivate: r.isPrivate,
            defaultBranch: r.defaultBranch,
            description: Value(r.description),
            htmlUrl: Value(r.htmlUrl),
            updatedAt: r.updatedAt,
          ),
          onConflict: DoUpdate(
            (_) => RepositoriesCompanion(
              isPrivate: Value(r.isPrivate),
              defaultBranch: Value(r.defaultBranch),
              description: Value(r.description),
              htmlUrl: Value(r.htmlUrl),
              updatedAt: Value(r.updatedAt),
            ),
          ),
        );
      }
    });
  }

  Future<List<RepositoryRef>> allRepositories() async =>
      (await select(repositories).get()).map(_repo).toList();

  Future<RepositoryRef?> repository(String fullName) async {
    final row = await (select(
      repositories,
    )..where((t) => t.fullName.equals(fullName))).getSingleOrNull();
    return row == null ? null : _repo(row);
  }

  Future<void> setRepositoryAiAccess(String fullName, AiAccess access) =>
      (update(repositories)..where((t) => t.fullName.equals(fullName))).write(
        RepositoriesCompanion(aiAccess: Value(access.name)),
      );

  Future<void> markRepositoryOpened(String fullName, DateTime at) =>
      (update(repositories)..where((t) => t.fullName.equals(fullName))).write(
        RepositoriesCompanion(lastOpenedAt: Value(at)),
      );

  RepositoryRef _repo(RepositoryRow r) => RepositoryRef(
    owner: r.owner,
    name: r.name,
    isPrivate: r.isPrivate,
    defaultBranch: r.defaultBranch,
    updatedAt: r.updatedAt,
    description: r.description,
    htmlUrl: r.htmlUrl,
    aiAccess: AiAccess.values.byName(r.aiAccess),
    lastOpenedAt: r.lastOpenedAt,
    pinnedAt: r.pinnedAt,
    offlinePaths: r.offlinePathsJson == null
        ? null
        : [for (final p in jsonDecode(r.offlinePathsJson!) as List) '$p'],
    offlineCommitSha: r.offlineCommitSha,
    offlineUpdatedAt: r.offlineUpdatedAt,
  );

  // ------------------------------------------------- pinning and offline

  /// Pins or unpins a repository (FR-16).
  Future<void> setPinnedAt(String fullName, DateTime? at) =>
      (update(repositories)..where((t) => t.fullName.equals(fullName))).write(
        RepositoriesCompanion(pinnedAt: Value(at)),
      );

  /// Number of pinned repositories.
  Future<int> pinnedCount() async {
    final count = repositories.fullName.count();
    final row =
        await (selectOnly(repositories)
              ..addColumns([count])
              ..where(repositories.pinnedAt.isNotNull()))
            .getSingle();
    return row.read(count) ?? 0;
  }

  /// Marks a repository as available offline, or clears it when [paths] is
  /// null (FR-27).
  Future<void> setOfflineState(
    String fullName, {
    required List<String>? paths,
    String? commitSha,
    DateTime? updatedAt,
  }) => (update(repositories)..where((t) => t.fullName.equals(fullName))).write(
    RepositoriesCompanion(
      offlinePathsJson: Value(paths == null ? null : jsonEncode(paths)),
      offlineCommitSha: Value(commitSha),
      offlineUpdatedAt: Value(updatedAt),
    ),
  );

  /// Repositories whose files must survive cache eviction.
  Future<Set<String>> offlineRepoFullNames() async {
    final rows = await (select(
      repositories,
    )..where((t) => t.offlinePathsJson.isNotNull())).get();
    return {for (final r in rows) r.fullName};
  }

  // ---------------------------------------------------------- workspaces

  /// Saves the workspace, replacing its tree entries in one transaction.
  Future<void> saveWorkspace(Workspace ws) => transaction(() async {
    await into(workspaces).insertOnConflictUpdate(
      WorkspacesCompanion.insert(
        repoFullName: ws.repo.fullName,
        branch: ws.branch,
        baseCommitSha: ws.baseCommitSha,
        treeSha: ws.treeSha,
        truncated: ws.truncated,
        fetchedAt: ws.fetchedAt,
      ),
    );
    await (delete(treeEntries)..where(
          (t) =>
              t.repoFullName.equals(ws.repo.fullName) &
              t.branch.equals(ws.branch),
        ))
        .go();
    await batch((b) {
      b.insertAll(treeEntries, [
        for (final e in ws.entries)
          TreeEntriesCompanion.insert(
            repoFullName: ws.repo.fullName,
            branch: ws.branch,
            path: e.path,
            type: e.type.name,
            sha: e.sha,
            size: Value(e.size),
            mode: e.mode,
          ),
      ]);
    });
  });

  Future<Workspace?> loadWorkspace(RepositoryRef repo, String branch) async {
    final row =
        await (select(workspaces)..where(
              (t) =>
                  t.repoFullName.equals(repo.fullName) &
                  t.branch.equals(branch),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    final entries =
        await (select(treeEntries)..where(
              (t) =>
                  t.repoFullName.equals(repo.fullName) &
                  t.branch.equals(branch),
            ))
            .get();
    return Workspace(
      repo: repo,
      branch: branch,
      baseCommitSha: row.baseCommitSha,
      treeSha: row.treeSha,
      truncated: row.truncated,
      fetchedAt: row.fetchedAt,
      entries: [
        for (final e in entries)
          TreeEntry(
            path: e.path,
            type: TreeEntryType.values.byName(e.type),
            sha: e.sha,
            size: e.size,
            mode: e.mode,
          ),
      ],
    );
  }

  Future<void> deleteRepositoryData(String fullName) => transaction(() async {
    await (delete(
      workspaces,
    )..where((t) => t.repoFullName.equals(fullName))).go();
    await (delete(
      treeEntries,
    )..where((t) => t.repoFullName.equals(fullName))).go();
  });

  // ------------------------------------------------------------- blobs

  Future<void> recordBlob(String sha, int size, {String? repoFullName}) {
    final now = DateTime.now();
    return into(blobs).insert(
      BlobsCompanion.insert(
        sha: sha,
        size: size,
        repoFullName: Value(repoFullName),
        cachedAt: now,
        lastAccessAt: now,
      ),
      onConflict: DoUpdate((_) => BlobsCompanion(lastAccessAt: Value(now))),
    );
  }

  Future<void> touchBlob(String sha) =>
      (update(blobs)..where((t) => t.sha.equals(sha))).write(
        BlobsCompanion(lastAccessAt: Value(DateTime.now())),
      );

  Future<void> forgetBlob(String sha) =>
      (delete(blobs)..where((t) => t.sha.equals(sha))).go();

  Future<int> totalBlobBytes() async {
    final sum = blobs.size.sum();
    final row = await (selectOnly(blobs)..addColumns([sum])).getSingle();
    return row.read(sum) ?? 0;
  }

  Future<int> blobBytesForRepo(String fullName) async {
    final sum = blobs.size.sum();
    final row =
        await (selectOnly(blobs)
              ..addColumns([sum])
              ..where(blobs.repoFullName.equals(fullName)))
            .getSingle();
    return row.read(sum) ?? 0;
  }

  Future<List<BlobRow>> blobsByLastAccess() =>
      (select(blobs)..orderBy([(t) => OrderingTerm.asc(t.lastAccessAt)])).get();

  Future<List<String>> blobShasForRepo(String fullName) async =>
      (await (select(
            blobs,
          )..where((t) => t.repoFullName.equals(fullName))).get())
          .map((r) => r.sha)
          .toList();

  Future<Set<String>> pinnedBlobShas() async {
    final rows = await (select(
      pendingChanges,
    )..where((t) => t.contentBlobSha.isNotNull())).get();
    return {for (final r in rows) r.contentBlobSha!};
  }

  // ---------------------------------------------------- pending changes

  Future<List<PendingChange>> pendingChangesFor(
    String repoFullName,
    String branch,
  ) async {
    final rows =
        await (select(pendingChanges)
              ..where(
                (t) =>
                    t.repoFullName.equals(repoFullName) &
                    t.branch.equals(branch),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();
    return rows.map(_change).toList();
  }

  Stream<List<PendingChange>> watchPendingChanges(
    String repoFullName,
    String branch,
  ) =>
      (select(pendingChanges)
            ..where(
              (t) =>
                  t.repoFullName.equals(repoFullName) & t.branch.equals(branch),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch()
          .map((rows) => rows.map(_change).toList());

  Future<PendingChange?> pendingChange(String id) async {
    final row = await (select(
      pendingChanges,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _change(row);
  }

  Future<void> putPendingChange(PendingChange c) =>
      into(pendingChanges).insertOnConflictUpdate(
        PendingChangesCompanion.insert(
          id: c.id,
          repoFullName: c.repoFullName,
          branch: c.branch,
          path: c.path,
          oldPath: Value(c.oldPath),
          kind: c.kind.name,
          origin: c.origin.name,
          status: c.status.name,
          baseBlobSha: Value(c.baseBlobSha),
          baseCommitSha: c.baseCommitSha,
          contentBlobSha: Value(c.contentSha),
          proposalId: Value(c.proposalId),
          upstreamChanged: Value(c.upstreamChanged),
          createdAt: c.createdAt,
          updatedAt: c.updatedAt,
        ),
      );

  Future<void> deletePendingChange(String id) =>
      (delete(pendingChanges)..where((t) => t.id.equals(id))).go();

  Future<void> deletePendingChangesForRepo(String repoFullName) => (delete(
    pendingChanges,
  )..where((t) => t.repoFullName.equals(repoFullName))).go();

  Future<void> deleteAllPendingChanges() => delete(pendingChanges).go();

  PendingChange _change(PendingChangeRow r) => PendingChange(
    id: r.id,
    repoFullName: r.repoFullName,
    branch: r.branch,
    path: r.path,
    oldPath: r.oldPath,
    kind: ChangeKind.values.byName(r.kind),
    origin: ChangeOrigin.values.byName(r.origin),
    status: ChangeStatus.values.byName(r.status),
    baseBlobSha: r.baseBlobSha,
    baseCommitSha: r.baseCommitSha,
    contentSha: r.contentBlobSha,
    proposalId: r.proposalId,
    upstreamChanged: r.upstreamChanged,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );

  // ------------------------------------------------------- conversations

  Future<List<Conversation>> conversationsFor(String repoFullName) async {
    final rows =
        await (select(conversations)
              ..where((t) => t.repoFullName.equals(repoFullName))
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
            .get();
    return [
      for (final r in rows)
        Conversation(
          id: r.id,
          repoFullName: r.repoFullName,
          title: r.title,
          createdAt: r.createdAt,
          updatedAt: r.updatedAt,
        ),
    ];
  }

  Future<void> putConversation(Conversation c) =>
      into(conversations).insertOnConflictUpdate(
        ConversationsCompanion.insert(
          id: c.id,
          repoFullName: c.repoFullName,
          title: c.title,
          createdAt: c.createdAt,
          updatedAt: c.updatedAt,
        ),
      );

  Future<void> deleteConversation(String id) => transaction(() async {
    await (delete(messages)..where((t) => t.conversationId.equals(id))).go();
    await (delete(proposals)..where((t) => t.conversationId.equals(id))).go();
    await (delete(
      commitRequests,
    )..where((t) => t.conversationId.equals(id))).go();
    await (delete(conversations)..where((t) => t.id.equals(id))).go();
  });

  Future<void> deleteAllConversations() => transaction(() async {
    await delete(messages).go();
    await delete(proposals).go();
    await delete(commitRequests).go();
    await delete(conversations).go();
  });

  Future<void> addMessage(StoredMessage m) => into(messages).insert(
    MessagesCompanion.insert(
      id: m.id,
      conversationId: m.conversationId,
      role: m.role,
      blocksJson: jsonEncode(m.blocks),
      usageJson: Value(m.usage == null ? null : jsonEncode(m.usage)),
      model: Value(m.model),
      createdAt: m.createdAt,
    ),
  );

  Future<List<StoredMessage>> messagesFor(String conversationId) async {
    final rows =
        await (select(messages)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();
    return [
      for (final r in rows)
        StoredMessage(
          id: r.id,
          conversationId: r.conversationId,
          role: r.role,
          blocks: [
            for (final b in jsonDecode(r.blocksJson) as List)
              Map<String, dynamic>.from(b as Map),
          ],
          usage: r.usageJson == null
              ? null
              : Map<String, dynamic>.from(jsonDecode(r.usageJson!) as Map),
          model: r.model,
          createdAt: r.createdAt,
        ),
    ];
  }

  // ----------------------------------------------------------- proposals

  Future<void> putProposal(Proposal p) =>
      into(proposals).insertOnConflictUpdate(
        ProposalsCompanion.insert(
          id: p.id,
          conversationId: p.conversationId,
          path: p.path,
          kind: p.kind,
          explanation: p.explanation,
          status: p.status.name,
          pendingChangeId: p.pendingChangeId,
          createdAt: p.createdAt,
        ),
      );

  Future<Proposal?> proposal(String id) async {
    final r = await (select(
      proposals,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return r == null ? null : _proposal(r);
  }

  Future<List<Proposal>> proposalsFor(String conversationId) async =>
      (await (select(proposals)
                ..where((t) => t.conversationId.equals(conversationId))
                ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
              .get())
          .map(_proposal)
          .toList();

  Proposal _proposal(ProposalRow r) => Proposal(
    id: r.id,
    conversationId: r.conversationId,
    path: r.path,
    kind: r.kind,
    explanation: r.explanation,
    status: ProposalStatus.values.byName(r.status),
    pendingChangeId: r.pendingChangeId,
    createdAt: r.createdAt,
  );

  Future<void> putCommitRequest(CommitRequest c) =>
      into(commitRequests).insertOnConflictUpdate(
        CommitRequestsCompanion.insert(
          id: c.id,
          conversationId: c.conversationId,
          message: c.message,
          pathsJson: jsonEncode(c.paths),
          status: c.status.name,
          createdAt: c.createdAt,
        ),
      );

  Future<List<CommitRequest>> commitRequestsFor(String conversationId) async =>
      [
        for (final r in await (select(
          commitRequests,
        )..where((t) => t.conversationId.equals(conversationId))).get())
          CommitRequest(
            id: r.id,
            conversationId: r.conversationId,
            message: r.message,
            paths: [for (final p in jsonDecode(r.pathsJson) as List) '$p'],
            status: CommitRequestStatus.values.byName(r.status),
            createdAt: r.createdAt,
          ),
      ];

  // ----------------------------------------------------------- key/value

  Future<Object?> getValue(String key) async {
    final row = await (select(
      keyValues,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row == null ? null : jsonDecode(row.valueJson);
  }

  Future<void> setValue(String key, Object? value) =>
      into(keyValues).insertOnConflictUpdate(
        KeyValuesCompanion.insert(key: key, valueJson: jsonEncode(value)),
      );

  Future<void> deleteValue(String key) =>
      (delete(keyValues)..where((t) => t.key.equals(key))).go();
}
