import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/entities.dart';
import '../../domain/services/file_kind_detector.dart';
import '../agent/agent_controller.dart';
import '../core/providers.dart';
import '../core/widgets.dart';
import '../editing/copy_to_repo_sheet.dart';
import '../viewers/viewer_dispatcher.dart';

/// Tabs, per-file toolbar and viewer (docs/08_ui_spec.md §3.4).
class ViewerPane extends ConsumerWidget {
  const ViewerPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final open = ref.watch(openFilesProvider);
    final ws = ref.watch(currentWorkspaceProvider).value;
    final status = ref.watch(workspaceStatusProvider);
    final pending = ref.watch(committableChangesProvider);
    final active = open.active;
    if (active == null || ws == null) {
      return EmptyState(icon: Icons.menu_book_outlined, message: l.noFileOpen);
    }
    final kind = FileKindDetector.fromPath(active);
    final editable =
        FileKindDetector.isTextEditable(kind) || kind == FileKind.notebook;
    final editing = ref.watch(
      shellProvider.select((s) => s.editing.contains(active)),
    );
    final changedPaths = {for (final c in pending) c.path};
    // コピーには中身が要るので、読み込みが終わるまでボタンは押せない。
    final content = ref.watch(fileContentProvider(active)).value;
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final t in open.tabs)
                _Tab(
                  path: t,
                  active: t == active,
                  changed: changedPaths.contains(t),
                  onTap: () => ref.read(openFilesProvider.notifier).open(t),
                  onClose: () {
                    ref.read(shellProvider.notifier).setEditing(t, false);
                    ref.read(openFilesProvider.notifier).close(t);
                  },
                ),
            ],
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(fileIcon(kind), size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  active,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (editable)
                IconButton(
                  key: const Key('editToggle'),
                  tooltip: editing ? l.viewMode : l.editMode,
                  isSelected: editing,
                  icon: const Icon(Icons.edit_outlined),
                  selectedIcon: const Icon(Icons.edit),
                  onPressed: () => ref
                      .read(shellProvider.notifier)
                      .setEditing(active, !editing),
                ),
              IconButton(
                key: const Key('copyToRepo'),
                tooltip: l.copyToRepo,
                icon: const Icon(Icons.drive_file_move_outline),
                onPressed: content == null
                    ? null
                    : () => showCopyToRepoSheet(context, ref, content),
              ),
              IconButton(
                tooltip: l.askAiAboutFile,
                icon: const Icon(Icons.auto_awesome_outlined),
                onPressed: () {
                  ref
                      .read(agentControllerProvider.notifier)
                      .setAttachOpenFile(true);
                  ref.read(shellProvider.notifier).showPane(PhonePane.agent);
                },
              ),
              IconButton(
                tooltip: l.openOnGitHub,
                icon: const Icon(Icons.open_in_browser),
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://github.com/${ws.repo.fullName}/blob/${Uri.encodeComponent(ws.branch)}/$active',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ],
          ),
        ),
        if (status.changedPaths.contains(active))
          MaterialBanner(
            content: Text(l.remoteUpdated),
            actions: [
              TextButton(
                onPressed: () => ref
                    .read(workspaceStatusProvider.notifier)
                    .acknowledge(active),
                child: Text(l.ok),
              ),
            ],
          ),
        const Divider(),
        Expanded(
          child: ViewerDispatcher(key: ValueKey(active), path: active),
        ),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.path,
    required this.active,
    required this.changed,
    required this.onTap,
    required this.onClose,
  });

  final String path;
  final bool active;
  final bool changed;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 2),
        decoration: BoxDecoration(
          color: active ? scheme.surface : scheme.surfaceContainer,
          border: Border(
            bottom: BorderSide(
              color: active ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(
              path.split('/').last,
              style: TextStyle(
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            if (changed)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.circle, size: 8, color: scheme.primary),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: const Icon(Icons.close),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
