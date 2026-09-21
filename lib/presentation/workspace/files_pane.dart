import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/services/file_kind_detector.dart';
import '../../domain/services/tree_view.dart';
import '../agent/agent_controller.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../editing/move_file_sheet.dart';

class ExpandedDirsController extends Notifier<Set<String>> {
  String? _key;

  @override
  Set<String> build() {
    final ws = ref.watch(
      currentWorkspaceProvider.select(
        (s) => s.value == null
            ? null
            : '${s.value!.repo.fullName}@${s.value!.branch}',
      ),
    );
    _key = ws == null ? null : 'expanded:$ws';
    if (_key != null) {
      ref.read(databaseProvider).getValue(_key!).then((v) {
        if (v is List) state = {for (final p in v) '$p'};
      });
    }
    return const {};
  }

  void toggle(String path) {
    final next = {...state};
    if (!next.remove(path)) next.add(path);
    state = next;
    if (_key != null) ref.read(databaseProvider).setValue(_key!, next.toList());
  }
}

final expandedDirsProvider =
    NotifierProvider<ExpandedDirsController, Set<String>>(
      ExpandedDirsController.new,
    );

/// Effective tree including pending changes.
final treeProvider = Provider<TreeNode?>((ref) {
  final ws = ref.watch(currentWorkspaceProvider).value;
  if (ws == null) return null;
  return buildTree(
    ws.entries,
    ref.watch(pendingChangesProvider).value ?? const [],
  );
});

/// File tree (docs/08_ui_spec.md §3.3).
class FilesPane extends ConsumerStatefulWidget {
  const FilesPane({super.key});

  @override
  ConsumerState<FilesPane> createState() => _FilesPaneState();
}

class _FilesPaneState extends ConsumerState<FilesPane> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final ws = ref.watch(currentWorkspaceProvider).value;
    final root = ref.watch(treeProvider);
    final expanded = ref.watch(expandedDirsProvider);
    final active = ref.watch(openFilesProvider).active;
    final status = ref.watch(workspaceStatusProvider);
    if (ws == null || root == null) return const SizedBox.shrink();
    final rows = _filter.isEmpty
        ? flattenVisible(root, expanded)
        : filterFiles(root, _filter);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('fileFilter'),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.filter_list, size: 18),
                      hintText: l.filterFiles,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
                IconButton(
                  tooltip: l.newFile,
                  icon: const Icon(Icons.note_add_outlined),
                  onPressed: () => _newFile(context, ''),
                ),
              ],
            ),
          ),
          if (status.refreshing) const LinearProgressIndicator(minHeight: 2),
          if (ws.truncated)
            MaterialBanner(
              content: Text(l.treeTruncated),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(
            child: rows.isEmpty
                ? EmptyState(icon: Icons.search_off, message: l.noFiles)
                : ListView.builder(
                    key: const Key('fileTree'),
                    itemCount: rows.length,
                    itemExtent: 36,
                    itemBuilder: (context, i) => TreeRow(
                      node: rows[i],
                      flat: _filter.isNotEmpty,
                      expanded: expanded.contains(rows[i].path),
                      selected: rows[i].path == active,
                      onTap: () => rows[i].isDirectory
                          ? ref
                                .read(expandedDirsProvider.notifier)
                                .toggle(rows[i].path)
                          : (rows[i].marker == ChangeMarker.deleted
                                ? null
                                : openPath(context, ref, rows[i].path)),
                      onLongPress: () => _menu(context, rows[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _menu(BuildContext context, TreeNode node) async {
    final l = context.l10n;
    final ws = ref.read(currentWorkspaceProvider).value!;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(node.path, style: monoStyle(ctx))),
            if (node.isDirectory)
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: Text(l.newFile),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
            if (!node.isDirectory && node.marker != ChangeMarker.deleted) ...[
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: Text(l.askAiAboutFile),
                onTap: () => Navigator.pop(ctx, 'ai'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: Text(l.rename),
                onTap: () => Navigator.pop(ctx, 'rename'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: Text(l.moveFile),
                onTap: () => Navigator.pop(ctx, 'move'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l.delete),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(l.copyPath),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.open_in_browser),
              title: Text(l.openOnGitHub),
              onTap: () => Navigator.pop(ctx, 'github'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    final editing = ref.read(editingServiceProvider);
    try {
      switch (choice) {
        case 'new':
          await _newFile(context, node.path);
        case 'ai':
          openPath(context, ref, node.path);
          ref.read(agentControllerProvider.notifier).setAttachOpenFile(true);
          ref.read(shellProvider.notifier).toggleAgent();
        case 'rename':
          final to = await textInputDialog(
            context,
            title: l.rename,
            label: l.path,
            initial: node.path,
          );
          if (to != null && to.trim() != node.path) {
            await editing.renameFile(ws, node.path, to);
            ref.read(openFilesProvider.notifier).rename(node.path, to.trim());
          }
        case 'move':
          await showMoveFileSheet(context, ref, node.path);
        case 'delete':
          final ok = await confirmDialog(
            context,
            title: l.delete,
            message: l.deleteFileConfirm(node.path),
            confirmLabel: l.delete,
            destructive: true,
          );
          if (ok) {
            await editing.deleteFile(ws, node.path);
            ref.read(openFilesProvider.notifier).close(node.path);
          }
        case 'copy':
          await Clipboard.setData(ClipboardData(text: node.path));
          if (context.mounted) showSnack(context, l.copied);
        case 'github':
          final kind = node.isDirectory ? 'tree' : 'blob';
          await launchUrl(
            Uri.parse(
              'https://github.com/${ws.repo.fullName}/$kind/${Uri.encodeComponent(ws.branch)}/${node.path}',
            ),
            mode: LaunchMode.externalApplication,
          );
      }
    } on AppFailure catch (e) {
      if (context.mounted) showSnack(context, failureMessage(context, e));
    }
  }

  Future<void> _newFile(BuildContext context, String dir) async {
    final l = context.l10n;
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    final path = await textInputDialog(
      context,
      title: l.newFile,
      label: l.path,
      initial: dir.isEmpty ? '' : '$dir/',
    );
    if (path == null || path.trim().isEmpty) return;
    try {
      final initial = FileKindDetector.fromPath(path) == FileKind.notebook
          ? Uint8List.fromList(
              utf8.encode(
                '{\n "cells": [],\n "metadata": {},\n "nbformat": 4,\n "nbformat_minor": 5\n}\n',
              ),
            )
          : null;
      final c = await ref
          .read(editingServiceProvider)
          .createFile(ws, path, initial);
      if (context.mounted) {
        openPath(context, ref, c.path);
        ref.read(shellProvider.notifier).setEditing(c.path, true);
      }
    } on AppFailure catch (e) {
      if (context.mounted) showSnack(context, failureMessage(context, e));
    }
  }
}

class TreeRow extends StatelessWidget {
  const TreeRow({
    super.key,
    required this.node,
    required this.flat,
    required this.expanded,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final TreeNode node;
  final bool flat;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.colors;
    final kind = FileKindDetector.fromPath(node.path);
    final (markerText, markerColor) = switch (node.marker) {
      ChangeMarker.modified => ('●', scheme.primary),
      ChangeMarker.aiModified => ('◐', colors.aiBadge),
      ChangeMarker.created => ('+', colors.diffAddedText),
      ChangeMarker.deleted => ('−', colors.diffRemovedText),
      ChangeMarker.none => ('', scheme.onSurface),
    };
    return Semantics(
      label: node.path,
      button: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: Container(
          color: selected ? scheme.secondaryContainer : null,
          padding: EdgeInsets.only(
            left: flat ? 8 : 8.0 + node.depth * 14,
            right: 8,
          ),
          child: Row(
            children: [
              if (node.isDirectory)
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                )
              else
                const SizedBox(width: 18),
              Icon(
                node.isDirectory
                    ? (expanded ? Icons.folder_open : Icons.folder)
                    : fileIcon(kind),
                size: 18,
                color: node.isDirectory
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  flat ? node.path : node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    decoration: node.marker == ChangeMarker.deleted
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
              ),
              if (markerText.isNotEmpty)
                Text(
                  markerText,
                  style: TextStyle(
                    color: markerColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
