import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Computes the SHA-256 digest of [bytes] as lowercase hex.
String sha256Bytes(List<int> bytes) => sha256.convert(bytes).toString();

/// Computes the SHA-256 digest of [file].
Future<String> sha256File(File file) async {
  final Digest digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// Computes the Pluto directory tree hash from relative file digests.
///
/// The input map is `relative/path -> sha256 hex`. Paths are sorted and encoded
/// as `path\0hash\n` before hashing.
String sha256Tree(Map<String, String> fileDigests) {
  final List<String> paths = fileDigests.keys.toList(growable: false)..sort();
  final StringBuffer buffer = StringBuffer();
  for (final String path in paths) {
    buffer
      ..write(path)
      ..writeCharCode(0)
      ..write(fileDigests[path])
      ..write('\n');
  }
  return sha256Bytes(utf8.encode(buffer.toString()));
}
