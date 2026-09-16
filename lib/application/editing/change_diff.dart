import 'dart:convert';
import 'dart:typed_data';

import 'package:nbformat/nbformat.dart';
import 'package:text_diff/text_diff.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../domain/services/file_kind_detector.dart';
import '../../infrastructure/local/blob_store.dart';
import '../workspace/workspace_service.dart';
import 'notebook_diff.dart';

/// Old and new content of a change, ready for display.
class ChangeContents {
  const ChangeContents({required this.change, this.oldBytes, this.newBytes});

  final PendingChange change;
  final Uint8List? oldBytes;
  final Uint8List? newBytes;

  FileKind get kind => FileKindDetector.fromPath(change.path);

  String? get oldText => _decode(oldBytes);
  String? get newText => _decode(newBytes);

  bool get isBinary =>
      (oldBytes != null && FileKindDetector.looksBinary(oldBytes!)) ||
      (newBytes != null && FileKindDetector.looksBinary(newBytes!));

  static String? _decode(Uint8List? b) {
    if (b == null) return null;
    try {
      return utf8.decode(b);
    } on FormatException {
      return null;
    }
  }

  /// Line diff (throws [DiffTooLarge]).
  List<DiffLine> lineDiff() => diffLines(oldText ?? '', newText ?? '');

  /// Added/deleted counts, or null if not computable.
  DiffStats? computeStats() {
    if (isBinary) return null;
    try {
      return stats(lineDiff());
    } on DiffTooLarge {
      return null;
    }
  }

  /// Cell-level notebook diff, or null if either side fails to parse.
  List<CellDiff>? notebookDiff() {
    try {
      final a = (oldText ?? '').isEmpty ? Notebook() : parseNotebook(oldText!);
      final b = (newText ?? '').isEmpty ? Notebook() : parseNotebook(newText!);
      return diffNotebooks(a, b);
    } on NbformatException {
      return null;
    }
  }

  /// Unified diff text.
  String unified() => toUnified(
    toHunks(lineDiff()),
    oldPath: change.sourcePath,
    newPath: change.path,
  );
}

/// Loads [ChangeContents] for pending changes.
class ChangeDiffLoader {
  ChangeDiffLoader({required this.blobs, required this.workspaces});

  final BlobStore blobs;
  final WorkspaceService workspaces;

  Future<ChangeContents> load(Workspace ws, PendingChange c) async {
    Uint8List? oldBytes;
    if (c.baseBlobSha != null) {
      oldBytes = (await workspaces.loadBlob(
        ws,
        c.sourcePath,
        c.baseBlobSha!,
      )).bytes;
    }
    Uint8List? newBytes;
    if (c.contentSha != null) {
      newBytes = await blobs.read(c.contentSha!);
      if (newBytes == null) {
        throw ValidationFailure('Content missing for ${c.path}');
      }
    }
    return ChangeContents(change: c, oldBytes: oldBytes, newBytes: newBytes);
  }
}
