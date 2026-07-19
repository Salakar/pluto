import 'dart:typed_data';

/// In-memory writer for the canonical pen ring layout.
final class PenRingWriter {
  /// Creates a ring with [capacity] records.
  PenRingWriter({this.capacity = 16})
    : _bytes = Uint8List(_headerSize + capacity * recordSize) {
    if (capacity <= 0 || (capacity & (capacity - 1)) != 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be a power of two');
    }
    _data.setUint32(0, magic, Endian.little);
    _data.setUint32(4, recordSize, Endian.little);
    _data.setUint32(8, capacity, Endian.little);
    _data.setUint32(12, 0, Endian.little);
  }

  /// Magic value for the `PLTR` ring.
  static const int magic = 0x52544c50;

  /// Canonical pen record size in bytes.
  static const int recordSize = 40;

  static const int _headerSize = 64;

  final Uint8List _bytes;

  ByteData get _data => ByteData.sublistView(_bytes);

  /// Number of records the ring can hold.
  final int capacity;

  /// Ring memory as a mutable byte view.
  ByteData get data => ByteData.sublistView(_bytes);

  /// Appends one record to the ring.
  void write({
    required int timestampUs,
    required int flags,
    required int rawX,
    required int rawY,
    required int rawPressure,
    required int rawDistance,
    required int tiltXCentiDegrees,
    required int tiltYCentiDegrees,
    required int orientationTag,
    required double xLogical,
    required double yLogical,
  }) {
    final int writeIndex = _data.getUint64(16, Endian.little);
    final int slot = writeIndex & (capacity - 1);
    final int offset = _headerSize + slot * recordSize;
    _data.setUint64(offset, timestampUs, Endian.little);
    _data.setUint32(offset + 8, writeIndex, Endian.little);
    _data.setUint16(offset + 12, flags, Endian.little);
    _data.setUint16(offset + 14, rawX, Endian.little);
    _data.setUint16(offset + 16, rawY, Endian.little);
    _data.setUint16(offset + 18, rawPressure, Endian.little);
    _data.setUint16(offset + 20, rawDistance, Endian.little);
    _data.setInt16(offset + 22, tiltXCentiDegrees, Endian.little);
    _data.setInt16(offset + 24, tiltYCentiDegrees, Endian.little);
    _data.setUint16(offset + 26, orientationTag, Endian.little);
    _data.setFloat32(offset + 28, xLogical, Endian.little);
    _data.setFloat32(offset + 32, yLogical, Endian.little);
    _data.setUint32(offset + 36, 0, Endian.little);
    _data.setUint64(16, writeIndex + 1, Endian.little);
    if (writeIndex + 1 > capacity) {
      _data.setUint64(24, writeIndex + 1 - capacity, Endian.little);
    }
  }
}
