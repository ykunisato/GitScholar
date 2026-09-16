import '../entities/changes.dart';
import '../entities/repository.dart';

/// Marker shown next to a file in the tree (docs/08_ui_spec.md §3.3).
enum ChangeMarker { none, modified, aiModified, created, deleted }

/// A node of the effective file tree.
class TreeNode {
  TreeNode({
    required this.path,
    required this.isDirectory,
    this.entry,
    this.marker = ChangeMarker.none,
  });

  final String path;
  final bool isDirectory;
  final TreeEntry? entry;
  ChangeMarker marker;
  final List<TreeNode> children = [];

  String get name => path.isEmpty ? '' : path.split('/').last;
  int get depth => path.isEmpty ? -1 : '/'.allMatches(path).length;
}

/// Builds the effective tree: remote entries plus pending creates/renames,
/// with markers for pending changes. Proposed changes are not shown.
TreeNode buildTree(List<TreeEntry> entries, List<PendingChange> changes) {
  final pending = [
    for (final c in changes)
      if (c.isPending) c,
  ];
  final root = TreeNode(path: '', isDirectory: true);
  final dirs = <String, TreeNode>{'': root};

  TreeNode dir(String path) {
    final existing = dirs[path];
    if (existing != null) return existing;
    final parentPath = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    final node = TreeNode(path: path, isDirectory: true);
    dir(parentPath).children.add(node);
    return dirs[path] = node;
  }

  final markers = <String, ChangeMarker>{};
  final extra = <String>{};
  for (final c in pending) {
    switch (c.kind) {
      case ChangeKind.modify:
        markers[c.path] = c.origin == ChangeOrigin.ai
            ? ChangeMarker.aiModified
            : ChangeMarker.modified;
      case ChangeKind.create:
        markers[c.path] = ChangeMarker.created;
        extra.add(c.path);
      case ChangeKind.delete:
        markers[c.path] = ChangeMarker.deleted;
      case ChangeKind.rename:
        markers[c.oldPath!] = ChangeMarker.deleted;
        markers[c.path] = ChangeMarker.created;
        extra.add(c.path);
    }
  }

  final seen = <String>{};
  for (final e in entries) {
    if (e.type == TreeEntryType.tree) {
      dir(e.path);
      continue;
    }
    final parentPath = e.parent;
    final node = TreeNode(
      path: e.path,
      isDirectory: false,
      entry: e,
      marker: markers[e.path] ?? ChangeMarker.none,
    );
    dir(parentPath).children.add(node);
    seen.add(e.path);
  }
  for (final p in extra) {
    if (seen.contains(p)) continue;
    final parentPath = p.contains('/')
        ? p.substring(0, p.lastIndexOf('/'))
        : '';
    dir(parentPath).children.add(
      TreeNode(path: p, isDirectory: false, marker: ChangeMarker.created),
    );
  }
  void sort(TreeNode n) {
    n.children.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    for (final c in n.children) {
      if (c.isDirectory) sort(c);
    }
  }

  sort(root);
  return root;
}

/// Flattens visible rows given the set of expanded directory paths.
List<TreeNode> flattenVisible(TreeNode root, Set<String> expanded) {
  final out = <TreeNode>[];
  void walk(TreeNode n) {
    for (final c in n.children) {
      out.add(c);
      if (c.isDirectory && expanded.contains(c.path)) walk(c);
    }
  }

  walk(root);
  return out;
}

/// Case-insensitive substring filter over file paths.
List<TreeNode> filterFiles(TreeNode root, String query) {
  final q = query.toLowerCase();
  final out = <TreeNode>[];
  void walk(TreeNode n) {
    for (final c in n.children) {
      if (c.isDirectory) {
        walk(c);
      } else if (c.path.toLowerCase().contains(q)) {
        out.add(c);
      }
    }
  }

  walk(root);
  return out;
}
