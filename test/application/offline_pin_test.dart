import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/application/offline/offline_service.dart';
import 'package:gitscholar/application/repositories/pin_service.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/services/ignore_rules.dart';

import '../fakes/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    env.github.seed({
      'README.md': '# Research\n',
      'notes/a.md': 'note a\n',
      'notes/b.md': 'note b\n',
      'analysis/model.R': 'x <- 1\n',
      '.env': 'SECRET=1\n',
    });
  });
  tearDown(() => env.dispose());

  IgnoreRules rules() => IgnoreRules.fromFile(null);

  group('PinService', () {
    test('pins, unpins and enforces the limit of 10', () async {
      final repos = [
        for (var i = 0; i < 12; i++)
          RepositoryRef(
            owner: 'o',
            name: 'r$i',
            isPrivate: false,
            defaultBranch: 'main',
            updatedAt: DateTime(2026, 1, i + 1),
          ),
      ];
      await env.db.upsertRepositories(repos);
      var clock = DateTime(2026);
      final pins = PinService(
        env.db,
        clock: () => clock = clock.add(const Duration(minutes: 1)),
      );
      for (var i = 0; i < PinService.maxPinned; i++) {
        expect(await pins.toggle(repos[i]), isTrue, reason: 'pin $i');
      }
      expect(await pins.isFull(), isTrue);
      expect(
        await pins.toggle(repos[10]),
        isFalse,
        reason: 'eleventh pin is refused',
      );
      final stored = await env.db.allRepositories();
      expect(PinService.pinnedOf(stored), hasLength(10));
      expect(
        PinService.pinnedOf(stored).first.name,
        'r0',
        reason: 'ordered by pin time',
      );

      final first = stored.firstWhere((r) => r.name == 'r0');
      expect(await pins.toggle(first), isTrue);
      expect(await env.db.pinnedCount(), 9);
      expect(
        await pins.toggle(repos[10]),
        isTrue,
        reason: 'room again after unpinning',
      );
    });

    test('pinning survives a repository list refresh', () async {
      await env.db.upsertRepositories([env.repo]);
      await PinService(env.db).toggle(env.repo);
      await env.db.upsertRepositories([env.repo]);
      expect((await env.db.repository(env.repo.fullName))!.isPinned, isTrue);
    });
  });

  group('OfflineService', () {
    OfflineService service() => OfflineService(
      db: env.db,
      blobs: env.blobs,
      workspaces: env.workspaces,
    );

    test(
      'targets exclude ignored files and respect folder selection',
      () async {
        final ws = await env.open();
        expect(
          OfflineService.targets(ws, const [], rules()).map((e) => e.path),
          containsAll(['README.md', 'notes/a.md', 'analysis/model.R']),
        );
        expect(
          OfflineService.targets(ws, const [], rules()).map((e) => e.path),
          isNot(contains('.env')),
        );
        expect(
          OfflineService.targets(ws, const [
            'notes',
          ], rules()).map((e) => e.path),
          ['notes/a.md', 'notes/b.md'],
        );
        expect(OfflineService.topLevelFolders(ws), ['analysis', 'notes']);
        expect(OfflineService.skippedCount(ws, const [], rules()), 1);
      },
    );

    test('estimate counts cached files separately', () async {
      final ws = await env.open();
      final before = await service().estimate(ws, const [], rules());
      expect(before.totalFiles, 4);
      expect(before.cachedFiles, 0);
      expect(before.missingBytes, before.totalBytes);
      await env.workspaces.loadFile(ws, 'notes/a.md');
      final after = await service().estimate(ws, const [], rules());
      expect(after.cachedFiles, 1);
      expect(after.missingFiles, 3);
    });

    test('download stores every file and records the commit', () async {
      final ws = await env.open();
      final progress = await service()
          .download(ws, prefixes: const [], rules: rules())
          .toList();
      expect(progress.last.finished, isTrue);
      expect(progress.last.done, 4);
      expect(progress.last.failed, 0);
      for (final e in OfflineService.targets(ws, const [], rules())) {
        expect(await env.blobs.exists(e.sha), isTrue, reason: e.path);
      }
      final repo = (await env.db.repository(ws.repo.fullName))!;
      expect(repo.isOffline, isTrue);
      expect(
        repo.offlinePaths,
        isEmpty,
        reason: 'empty list means the whole repository',
      );
      expect(repo.offlineCommitSha, ws.baseCommitSha);
      expect(repo.offlineUpdatedAt, isNotNull);
      expect(repo.offlineCovers('notes/a.md'), isTrue);
    });

    test('files are readable with no network after download', () async {
      final ws = await env.open();
      await service()
          .download(ws, prefixes: const [], rules: rules())
          .drain<void>();
      env.github.calls.clear();
      env.github.failNext = null;
      env.github.blobs
          .clear(); // simulate being offline: nothing can be fetched
      final f = await env.workspaces.loadFile(ws, 'analysis/model.R');
      expect(f.text, 'x <- 1\n');
      expect(env.github.calls, isEmpty);
    });

    test('folder selection only downloads that folder', () async {
      final ws = await env.open();
      await service()
          .download(ws, prefixes: const ['notes'], rules: rules())
          .drain<void>();
      final repo = (await env.db.repository(ws.repo.fullName))!;
      expect(repo.offlinePaths, ['notes']);
      expect(repo.offlineCovers('notes/a.md'), isTrue);
      expect(repo.offlineCovers('README.md'), isFalse);
      expect(await env.blobs.exists(ws.entry('notes/a.md')!.sha), isTrue);
      expect(await env.blobs.exists(ws.entry('README.md')!.sha), isFalse);
    });

    test(
      'cancelling keeps downloaded files and marks the copy partial',
      () async {
        final ws = await env.open();
        final seen = <OfflineProgress>[];
        // Cancel from inside the listener so the run stops at a known point,
        // however fast the downloads are.
        late final StreamSubscription<OfflineProgress> sub;
        final stopped = Completer<void>();
        sub = service().download(ws, prefixes: const [], rules: rules()).listen(
          (p) {
            seen.add(p);
            if (p.done == 1 && !stopped.isCompleted) {
              stopped.complete(sub.cancel());
            }
          },
        );
        await stopped.future;
        final repo = (await env.db.repository(ws.repo.fullName))!;
        expect(seen.last.done, 1, reason: 'stopped after the first file');
        expect(repo.isOffline, isTrue, reason: 'partial copy stays protected');
        expect(
          repo.offlineCommitSha,
          isNull,
          reason: 'partial copy has no commit recorded',
        );
        final first = OfflineService.targets(ws, const [], rules()).first;
        expect(
          await env.blobs.exists(first.sha),
          isTrue,
          reason: 'the downloaded file is kept',
        );
      },
    );

    test('outdated reports files changed on the remote', () async {
      final ws = await env.open();
      await service()
          .download(ws, prefixes: const [], rules: rules())
          .drain<void>();
      final repo = (await env.db.repository(ws.repo.fullName))!;
      expect(
        await service().outdated(ws.copyWith(repo: repo), rules()),
        isEmpty,
      );
      env.github.seed({
        'README.md': '# Research\n',
        'notes/a.md': 'changed remotely\n',
        'notes/b.md': 'note b\n',
        'analysis/model.R': 'x <- 1\n',
        '.env': 'SECRET=1\n',
      });
      final refreshed = (await env.workspaces.refresh(
        env.repo,
        'main',
        current: ws,
      )).workspace;
      final stale = await service().outdated(refreshed, rules());
      expect(stale.map((e) => e.path), ['notes/a.md']);
    });

    test('offline files survive cache eviction', () async {
      final ws = await env.open();
      await service()
          .download(ws, prefixes: const [], rules: rules())
          .drain<void>();
      await env.blobs.evict(targetBytes: 0);
      for (final e in OfflineService.targets(ws, const [], rules())) {
        expect(
          await env.blobs.exists(e.sha),
          isTrue,
          reason: '${e.path} must not be evicted',
        );
      }
      await env.blobs.clear();
      expect(await env.blobs.exists(ws.entry('notes/a.md')!.sha), isTrue);
    });

    test('remove clears the flag and deletes the files', () async {
      final ws = await env.open();
      await service()
          .download(ws, prefixes: const [], rules: rules())
          .drain<void>();
      final repo = (await env.db.repository(ws.repo.fullName))!;
      await service().remove(repo);
      final after = (await env.db.repository(ws.repo.fullName))!;
      expect(after.isOffline, isFalse);
      expect(await env.blobs.sizeForRepo(ws.repo.fullName), 0);
    });
  });
}
