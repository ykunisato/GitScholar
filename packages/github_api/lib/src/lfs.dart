import 'dart:convert';
import 'dart:typed_data';

/// A Git LFS pointer: what the Git blob actually contains when a file is
/// stored with LFS.
///
/// ```
/// version https://git-lfs.github.com/spec/v1
/// oid sha256:4d7a2146...
/// size 12345
/// ```
class LfsPointer {
  /// Creates a pointer.
  const LfsPointer({
    required this.oid,
    required this.size,
    this.hashAlgo = 'sha256',
  });

  /// Object id, without the `sha256:` prefix.
  ///
  /// The pointer file writes the algorithm and the digest together, but the
  /// batch API takes them apart: an `oid` of `sha256:abc…` is not found on
  /// the server.
  final String oid;

  /// Algorithm [oid] was produced with. The spec only defines `sha256`.
  final String hashAlgo;

  /// Size of the real content in bytes.
  final int size;

  /// The largest a pointer can be. Anything bigger is real content, so the
  /// parser does not scan whole documents looking for text.
  static const maxPointerBytes = 1024;

  /// First line of every pointer file.
  static const _versionPrefix = 'version https://git-lfs.github.com/spec/v1';

  /// Parses [bytes] as a pointer, or returns null when it is not one.
  static LfsPointer? parse(Uint8List bytes) {
    if (bytes.length > maxPointerBytes || bytes.isEmpty) return null;
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return null;
    }
    if (!text.startsWith(_versionPrefix)) return null;
    String? oid;
    var hashAlgo = 'sha256';
    int? size;
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('oid ')) {
        final value = trimmed.substring(4).trim();
        final colon = value.indexOf(':');
        if (colon > 0) {
          hashAlgo = value.substring(0, colon);
          oid = value.substring(colon + 1);
        } else {
          oid = value;
        }
      }
      if (trimmed.startsWith('size ')) {
        size = int.tryParse(trimmed.substring(5).trim());
      }
    }
    if (oid == null || oid.isEmpty || size == null) return null;
    return LfsPointer(oid: oid, hashAlgo: hashAlgo, size: size);
  }

  @override
  bool operator ==(Object other) =>
      other is LfsPointer &&
      other.oid == oid &&
      other.hashAlgo == hashAlgo &&
      other.size == size;

  @override
  int get hashCode => Object.hash(oid, hashAlgo, size);

  @override
  String toString() => 'LfsPointer($hashAlgo:$oid, $size)';
}
