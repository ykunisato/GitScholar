import '../../domain/entities/entities.dart';
import '../../domain/services/path_utils.dart';
import '../workspace/workspace_service.dart';
import 'editing_service.dart';

/// Result of copying a file into another repository (FR-101).
class FileCopyResult {
  const FileCopyResult({required this.path, required this.change});

  /// Path in the destination repository.
  final String path;

  /// The pending change that was created, or null when the destination
  /// already holds exactly these bytes.
  final PendingChange? change;

  /// Whether anything is left to commit.
  bool get hasChange => change != null;

  /// Whether the copy replaced an existing file.
  bool get replaced => change?.kind == ChangeKind.modify;
}

/// Copies the open file into another repository (FR-101).
///
/// The copy lands as a pending change in the destination, so it goes through
/// the normal review and commit flow (ADR-0005). Nothing is written to GitHub
/// here.
class FileCopyService {
  /// Creates a service.
  FileCopyService({required this.editing, required this.workspaces});

  final EditingService editing;
  final WorkspaceService workspaces;

  /// Copies [source] into [target] at [targetPath].
  ///
  /// [branch] defaults to the destination's default branch. Throws an
  /// [AppFailure] when the destination tree cannot be read.
  Future<FileCopyResult> copy({
    required FileContent source,
    required RepositoryRef target,
    required String targetPath,
    String? branch,
  }) async {
    final path = normalizePath(targetPath);
    final destination = await _workspaceFor(target, branch);
    final change = await editing.saveBytes(destination, path, source.bytes);
    return FileCopyResult(path: path, change: change);
  }

  /// Loads the destination workspace, preferring the cached tree so that a
  /// copy does not always need the network.
  Future<Workspace> _workspaceFor(RepositoryRef repo, String? branch) async {
    final b = branch ?? repo.defaultBranch;
    final cached = await workspaces.cached(repo, b);
    if (cached != null) return cached;
    return (await workspaces.refresh(repo, b)).workspace;
  }

  /// Suggests a destination path: the same path as the source.
  static String suggestPath(String sourcePath) => normalizePath(sourcePath);
}
