import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/offline/offline_service.dart';
import '../core/providers.dart';
import '../core/widgets.dart';

/// Opens the offline download sheet (docs/08_ui_spec.md §3.6b).
Future<void> showOfflineSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (_) => const OfflineSheet(),
    );

/// Estimate for the current selection.
final _estimateProvider = FutureProvider.autoDispose
    .family<OfflineEstimate, List<String>>((ref, prefixes) async {
      final ws = ref.watch(currentWorkspaceProvider).value;
      if (ws == null) {
        return const OfflineEstimate(
          totalFiles: 0,
          totalBytes: 0,
          cachedFiles: 0,
          cachedBytes: 0,
          skippedFiles: 0,
        );
      }
      final rules = await ref.watch(ignoreRulesProvider.future);
      return ref.read(offlineServiceProvider).estimate(ws, prefixes, rules);
    });

class OfflineSheet extends ConsumerStatefulWidget {
  const OfflineSheet({super.key});

  @override
  ConsumerState<OfflineSheet> createState() => _OfflineSheetState();
}

class _OfflineSheetState extends ConsumerState<OfflineSheet> {
  bool _wholeRepo = true;
  Set<String> _folders = {};
  bool _initialised = false;

  List<String> get _prefixes =>
      _wholeRepo ? const [] : (_folders.toList()..sort());

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final ws = ref.watch(currentWorkspaceProvider).value;
    final download = ref.watch(offlineControllerProvider);
    final controller = ref.read(offlineControllerProvider.notifier);
    if (ws == null) return const SizedBox.shrink();
    if (!_initialised) {
      _initialised = true;
      final saved = ws.repo.offlinePaths;
      if (saved != null && saved.isNotEmpty) {
        _wholeRepo = false;
        _folders = saved.toSet();
      }
    }
    final folders = OfflineService.topLevelFolders(ws);
    final estimate = ref.watch(_estimateProvider(_prefixes));
    final running = download?.running ?? false;
    final outdated = ref.watch(offlineOutdatedProvider).value ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.offlineTitle, style: Theme.of(context).textTheme.titleLarge),
          Text(ws.repo.fullName, style: Theme.of(context).textTheme.bodySmall),
          if (ws.repo.isOffline) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.cloud_done_outlined, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    ws.repo.offlineUpdatedAt == null
                        ? l.offlineEnabled
                        : l.offlineUpdatedAt(
                            MaterialLocalizations.of(
                              context,
                            ).formatMediumDate(ws.repo.offlineUpdatedAt!),
                          ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          if (outdated > 0 && !running)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.sync_problem,
                    size: 16,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(l.offlineOutdated(outdated))),
                ],
              ),
            ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(l.offlineWholeRepo)),
              ButtonSegment(value: false, label: Text(l.offlineFolders)),
            ],
            selected: {_wholeRepo},
            showSelectedIcon: false,
            onSelectionChanged: running
                ? null
                : (s) => setState(() => _wholeRepo = s.first),
          ),
          if (!_wholeRepo)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.28,
              ),
              child: folders.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(l.offlineNoFolders),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final f in folders)
                          CheckboxListTile(
                            dense: true,
                            value: _folders.contains(f),
                            onChanged: running
                                ? null
                                : (v) => setState(
                                    () => v == true
                                        ? _folders.add(f)
                                        : _folders.remove(f),
                                  ),
                            title: Text(f),
                          ),
                      ],
                    ),
            ),
          const SizedBox(height: 8),
          switch (estimate) {
            AsyncData(:final value) => Text(
              [
                l.offlineEstimate(
                  value.totalFiles,
                  formatBytes(value.totalBytes),
                ),
                if (value.cachedFiles > 0)
                  l.offlineAlreadyCached(formatBytes(value.cachedBytes)),
                if (value.skippedFiles > 0)
                  l.offlineSkipped(value.skippedFiles),
              ].join('\n'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            AsyncError(:final error) => Text(failureMessage(context, error)),
            _ => Text(l.testing),
          },
          if (download != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: download.progress.total == 0
                  ? null
                  : download.progress.fraction,
            ),
            const SizedBox(height: 4),
            Text(
              [
                l.offlineProgress(
                  download.progress.done,
                  download.progress.total,
                ),
                if (download.progress.failed > 0)
                  l.offlineFailed(download.progress.failed),
                if (download.progress.cancelled) l.offlineCancelled,
                if (download.progress.finished &&
                    !download.progress.cancelled &&
                    download.error == null)
                  l.offlineFinished(formatBytes(download.progress.bytes)),
                if (download.error != null)
                  failureMessage(context, download.error!),
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              if (ws.repo.isOffline && !running)
                TextButton.icon(
                  onPressed: () async {
                    final ok = await confirmDialog(
                      context,
                      title: l.offlineDelete,
                      message: l.offlineDeleteConfirm(ws.repo.fullName),
                      confirmLabel: l.delete,
                      destructive: true,
                    );
                    if (!ok) return;
                    await controller.remove(ws.repo);
                    controller.clear();
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l.offlineDelete),
                ),
              const Spacer(),
              if (running)
                FilledButton.tonalIcon(
                  key: const Key('offlineCancel'),
                  onPressed: controller.cancel,
                  icon: const Icon(Icons.stop),
                  label: Text(l.offlineCancel),
                )
              else
                FilledButton.icon(
                  key: const Key('offlineDownload'),
                  onPressed: (!_wholeRepo && _folders.isEmpty)
                      ? null
                      : () => controller.start(ws, _prefixes),
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: Text(
                    outdated > 0 && ws.repo.isOffline
                        ? l.offlineUpdate
                        : l.offlineDownload,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
