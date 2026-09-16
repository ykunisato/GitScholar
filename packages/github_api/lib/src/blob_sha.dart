import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Computes the Git blob SHA-1 of [bytes]:
/// `sha1("blob <len>" + NUL + bytes)` as lowercase hex.
String gitBlobSha(Uint8List bytes) {
  final header = ascii.encode('blob ${bytes.length}');
  final builder = BytesBuilder(copy: false)
    ..add(header)
    ..addByte(0)
    ..add(bytes);
  return sha1.convert(builder.takeBytes()).toString();
}
