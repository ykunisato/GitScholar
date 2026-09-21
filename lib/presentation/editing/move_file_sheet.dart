import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/failures.dart';
import '../../domain/services/companion_files.dart';
import '../../domain/services/tree_view.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../core/widgets.dart';

/// Moves a file into another folder of the same repository (FR-49).
///
/// The move becomes a pending change like any other edit, so nothing reaches
/// GitHub until the user commits.
Future<void> showMoveFileSheet(
  BuildContext context,
  WidgetRef ref,
  String path,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (ctx) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
    child: SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.75,
      child: _MoveFileSheet(path: path),
    ),
  ),
);

class _MoveFileSheet extends ConsumerStatefulWidget {
  const _MoveFileSheet({required this.path});

  final String path;

  @override
  ConsumerState<_MoveFileSheet> createState() => _MoveFileSheetState();
}

class _MoveFileSheetState extends ConsumerState<_MoveFileSheet> {
  final _dir = TextEditingController();
  Object? _error;
  var _moving = false;

  /// Folder the file is in now. The root is the empty string.
  late final String _from = widget.path.contains('/')
      ? widget.path.substring(0, widget.path.lastIndexOf('/'))
      : '';

  String get _name => widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    _dir.text = _from;
  }

  @override
  void dispose() {
    _dir.dispose();
    super.dispose();
  }

  /// Every folder of the repository, in tree order.
  List<String> _folders() {
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return const [];
    final root = buildTree(
      ws.entries,
      ref.read(pendingChangesProvider).value ?? const [],
    );
    final out = <String>[];
    void walk(TreeNode node) {
      for (final child in node.children) {
        if (!child.isDirectory) continue;
        out.add(child.path);
        walk(child);
      }
    }

    walk(root);
    return out;
  }

  Future<void> _move() async {
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null || _moving) return;
    final l = context.l10n;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final target = _dir.text.trim();
    setState(() => _moving = true);
    try {
      await ref.read(editingServiceProvider).moveFile(ws, widget.path, target);
      final to = target.isEmpty ? _name : '$target/$_name';
      final files = ref.read(openFilesProvider.notifier)
        ..rename(widget.path, to);
      // 注釈とメモも一緒に動くので、開いていればタブも追従させる。
      final companions = companionPathsFor(widget.path);
      final moved = companionPathsFor(to);
      for (var i = 0; i < companions.length && i < moved.length; i++) {
        files.rename(companions[i], moved[i]);
      }
      if (!mounted) return;
      navigator.pop();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l.moveDone(to))));
    } on AppFailure catch (e) {
      if (mounted) {
        setState(() {
          _moving = false;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final target = _dir.text.trim();
    final folders = _folders();
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            l.moveDestination,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(widget.path, style: monoStyle(context)),
        ),
        // Flexible なので、下の入力とボタンの場所を先に取ってから残りを使う。
        // Expanded にすると、背の低い画面で入力が押し出されてはみ出す。
        Flexible(
          child: ListView.builder(
            key: const Key('moveFolderList'),
            itemCount: folders.length + 1,
            itemBuilder: (context, i) {
              final folder = i == 0 ? '' : folders[i - 1];
              final depth = folder.isEmpty ? 0 : '/'.allMatches(folder).length;
              return ListTile(
                key: Key('moveTo-$folder'),
                dense: true,
                contentPadding: EdgeInsets.only(
                  left: 16.0 + depth * 16,
                  right: 16,
                ),
                leading: Icon(
                  folder == target
                      ? Icons.folder
                      : (folder.isEmpty
                            ? Icons.home_outlined
                            : Icons.folder_outlined),
                ),
                title: Text(
                  folder.isEmpty ? l.repositoryRoot : folder.split('/').last,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: folder == _from ? Text(l.currentFolder) : null,
                selected: folder == target,
                trailing: folder == target ? const Icon(Icons.check) : null,
                onTap: () => setState(() => _dir.text = folder),
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('moveFolderPath'),
                controller: _dir,
                decoration: InputDecoration(
                  labelText: l.newFolder,
                  hintText: l.repositoryRoot,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (companionPathsFor(widget.path).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l.moveCompanionsNote,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    failureMessage(context, error),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('moveConfirm'),
                onPressed: target == _from || _moving ? null : _move,
                icon: _moving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.drive_file_move_outline),
                label: Text(l.moveFile),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
