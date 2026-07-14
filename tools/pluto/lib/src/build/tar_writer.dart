import 'dart:convert';
import 'dart:typed_data';

/// One file entry in a tar archive.
final class TarFileEntry {
  /// Creates a tar file entry.
  const TarFileEntry({
    required this.path,
    required this.bytes,
    this.executable = false,
  });

  /// Relative POSIX path inside the archive.
  final String path;

  /// File bytes.
  final List<int> bytes;

  /// Whether to encode executable mode.
  final bool executable;
}

/// Minimal deterministic ustar writer for Pluto packages.
final class TarArchiveWriter {
  /// Creates a tar archive writer.
  const TarArchiveWriter();

  /// Encodes [entries] as a ustar archive.
  Uint8List write(List<TarFileEntry> entries) {
    final BytesBuilder output = BytesBuilder(copy: false);
    final List<TarFileEntry> sorted = entries.toList(growable: false)
      ..sort((TarFileEntry a, TarFileEntry b) => a.path.compareTo(b.path));
    for (final TarFileEntry entry in sorted) {
      _validatePath(entry.path);
      final Uint8List header = _header(entry);
      output.add(header);
      output.add(entry.bytes);
      final int padding = _paddingFor(entry.bytes.length);
      if (padding > 0) {
        output.add(Uint8List(padding));
      }
    }
    output
      ..add(Uint8List(512))
      ..add(Uint8List(512));
    return output.takeBytes();
  }

  Uint8List _header(TarFileEntry entry) {
    final Uint8List header = Uint8List(512);
    _writeString(header, 0, 100, entry.path);
    _writeOctal(header, 100, 8, entry.executable ? 0x1ed : 0x1a4);
    _writeOctal(header, 108, 8, 0);
    _writeOctal(header, 116, 8, 0);
    _writeOctal(header, 124, 12, entry.bytes.length);
    _writeOctal(header, 136, 12, 0);
    for (int index = 148; index < 156; index += 1) {
      header[index] = 0x20;
    }
    header[156] = 0x30;
    _writeString(header, 257, 6, 'ustar');
    _writeString(header, 263, 2, '00');
    int checksum = 0;
    for (final int byte in header) {
      checksum += byte;
    }
    final String checksumText = checksum.toRadixString(8).padLeft(6, '0');
    _writeString(header, 148, 6, checksumText);
    header[154] = 0;
    header[155] = 0x20;
    return header;
  }

  void _writeString(Uint8List target, int offset, int length, String value) {
    final List<int> bytes = ascii.encode(value);
    if (bytes.length > length) {
      throw ArgumentError.value(value, 'value', 'tar field is too long');
    }
    target.setRange(offset, offset + bytes.length, bytes);
  }

  void _writeOctal(Uint8List target, int offset, int length, int value) {
    final String text = value.toRadixString(8).padLeft(length - 1, '0');
    _writeString(target, offset, length - 1, text);
    target[offset + length - 1] = 0;
  }

  int _paddingFor(int length) {
    final int remainder = length % 512;
    return remainder == 0 ? 0 : 512 - remainder;
  }

  void _validatePath(String path) {
    final List<String> segments = path.split('/');
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.codeUnits.any((int unit) => unit < 0x20 || unit == 0x7f) ||
        segments.any(
          (String segment) =>
              segment.isEmpty || segment == '.' || segment == '..',
        ) ||
        path.length > 100) {
      throw ArgumentError.value(path, 'path', 'invalid tar path');
    }
  }
}
