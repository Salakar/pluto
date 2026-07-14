import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:meta/meta.dart';
import 'package:pluto_core/pluto_core.dart';

import 'pen_sample.dart';

/// Source of high-precision pen lifecycle events.
abstract interface class PenEvents {
  /// Typed pen event stream.
  Stream<PenEvent> get events;
}

/// High-precision pen input.
final class PlutoPen implements PenEvents {
  /// Creates a pen facade backed by [transport].
  @visibleForTesting
  PlutoPen.withTransport(PlutoTransport transport) : _transport = transport;

  /// The process-wide instance backed by real embedder channels.
  static final PlutoPen instance = PlutoPen.withTransport(
    ChannelTransport.shared,
  );

  static PenRingSource? _debugRingSource;
  static bool _isCursorOpen = false;

  final PlutoTransport _transport;

  /// Installs [source] for host-side cursor tests.
  @visibleForTesting
  static void debugSetRingSource(PenRingSource? source) {
    _debugRingSource = source;
    _isCursorOpen = false;
  }

  @override
  Stream<PenEvent> get events {
    return _transport
        .events(
          channel: plutoPenEventsChannel,
          arguments: const <String, Object?>{'includeHover': true},
        )
        .map(
          (Object? event) => _penEventFromMap(_stringMap(event, 'pen event')),
        );
  }

  /// Latest known pen state.
  Future<PenState> currentState() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoPenChannel,
      method: penCurrentStateMethod,
    );
    return PenState.fromMap(_stringMap(payload, 'pen state'));
  }

  /// Static description of the digitizer.
  Future<PenCapabilities> capabilities() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoPenChannel,
      method: penCapabilitiesMethod,
    );
    return PenCapabilities.fromMap(_stringMap(payload, 'pen capabilities'));
  }

  /// Opens the high-rate sample cursor.
  PenSampleCursor openSampleCursor() {
    if (_isCursorOpen) {
      throw StateError('A PenSampleCursor is already open in this isolate.');
    }
    final PenRingSource? source = _debugRingSource;
    if (source == null) {
      throw PlutoUnsupportedException(Capability.penSampleRing);
    }
    _isCursorOpen = true;
    return PenSampleCursor._(source, () {
      _isCursorOpen = false;
    });
  }
}

/// Host-readable pen ring memory.
abstract interface class PenRingSource {
  /// Ring memory beginning with the doc-04 ring header.
  ByteData get data;
}

/// ByteData-backed [PenRingSource].
final class ByteDataPenRingSource implements PenRingSource {
  /// Creates a byte-data ring source.
  const ByteDataPenRingSource(this.data);

  @override
  final ByteData data;
}

/// Pull-based reader over the embedder's shared-memory pen ring.
final class PenSampleCursor {
  PenSampleCursor._(this._source, this._onClose) {
    _validateHeader(_source.data);
    final int writeIndex = _source.data.getUint64(
      _writeIndexOffset,
      Endian.little,
    );
    final int capacity = _source.data.getUint32(_capacityOffset, Endian.little);
    _cursor = math.max(0, writeIndex - capacity);
    _batch = PenSampleBatch._(capacity);
  }

  final PenRingSource _source;
  final void Function() _onClose;
  late final PenSampleBatch _batch;
  int _cursor = 0;
  int _droppedSampleCount = 0;
  bool _isClosed = false;

  /// Copies all pending samples into a reusable batch and returns it.
  PenSampleBatch drain() {
    if (_isClosed) {
      throw StateError('PenSampleCursor is closed.');
    }
    final ByteData data = _source.data;
    _validateHeader(data);
    final int capacity = data.getUint32(_capacityOffset, Endian.little);
    final int writeIndex = data.getUint64(_writeIndexOffset, Endian.little);
    final int ringDropped = data.getUint64(_droppedOffset, Endian.little);
    if (ringDropped > _droppedSampleCount) {
      _droppedSampleCount = ringDropped;
    }
    if (writeIndex - _cursor > capacity) {
      _droppedSampleCount += writeIndex - _cursor - capacity;
      _cursor = writeIndex - capacity;
    }
    var length = 0;
    while (_cursor < writeIndex) {
      final int slot = _cursor & (capacity - 1);
      final int offset = _headerSize + slot * _recordSize;
      final int sequence = data.getUint32(offset + 8, Endian.little);
      if (sequence != (_cursor & 0xffffffff)) {
        _droppedSampleCount++;
        _cursor++;
        continue;
      }
      _batch._write(length, data, offset);
      length++;
      _cursor++;
    }
    _batch._length = length;
    return _batch;
  }

  /// Samples lost to ring overwrite or device-side resyncs since open.
  int get droppedSampleCount => _droppedSampleCount;

  /// Releases the cursor.
  void close() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _onClose();
  }
}

/// Struct-of-arrays view over one drained batch.
final class PenSampleBatch {
  PenSampleBatch._(int capacity)
    : _timestampsUs = Uint64List(capacity),
      _xPx = Float32List(capacity),
      _yPx = Float32List(capacity),
      _pressure = Float32List(capacity),
      _tiltX = Float32List(capacity),
      _tiltY = Float32List(capacity),
      _distance = Float32List(capacity),
      _tool = Uint8List(capacity),
      _buttons = Uint8List(capacity),
      _rawX = Uint16List(capacity),
      _rawY = Uint16List(capacity),
      _rawPressure = Uint16List(capacity),
      _rawDistance = Uint16List(capacity),
      _rawTiltX = Int16List(capacity),
      _rawTiltY = Int16List(capacity);

  int _length = 0;
  final Uint64List _timestampsUs;
  final Float32List _xPx;
  final Float32List _yPx;
  final Float32List _pressure;
  final Float32List _tiltX;
  final Float32List _tiltY;
  final Float32List _distance;
  final Uint8List _tool;
  final Uint8List _buttons;
  final Uint16List _rawX;
  final Uint16List _rawY;
  final Uint16List _rawPressure;
  final Uint16List _rawDistance;
  final Int16List _rawTiltX;
  final Int16List _rawTiltY;

  /// Number of valid entries in every list.
  int get length => _length;

  /// Monotonic microsecond timestamps.
  Uint64List get timestampsUs => _timestampsUs;

  /// Panel-space x positions in physical pixels.
  Float32List get xPx => _xPx;

  /// Panel-space y positions in physical pixels.
  Float32List get yPx => _yPx;

  /// Normalized pressure values.
  Float32List get pressure => _pressure;

  /// Tilt x values in radians.
  Float32List get tiltX => _tiltX;

  /// Tilt y values in radians.
  Float32List get tiltY => _tiltY;

  /// Normalized hover-distance values.
  Float32List get distance => _distance;

  /// Tool values: 0 none, 1 pen, 2 eraser.
  Uint8List get tool => _tool;

  /// Per-sample [PenButtons] bits.
  Uint8List get buttons => _buttons;

  /// Materializes sample [index] as an immutable [PenSample].
  PenSample sampleAt(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final int toolValue = _tool[index];
    return PenSample(
      timestamp: Duration(microseconds: _timestampsUs[index]),
      position: Offset(_xPx[index], _yPx[index]),
      rawPosition: Offset(_rawX[index].toDouble(), _rawY[index].toDouble()),
      pressure: _pressure[index],
      rawPressure: _rawPressure[index],
      tilt: Offset(_tiltX[index], _tiltY[index]),
      rawTilt: Offset(_rawTiltX[index].toDouble(), _rawTiltY[index].toDouble()),
      distance: _distance[index],
      rawDistance: _rawDistance[index],
      tool: toolValue == 2 ? PenTool.eraser : PenTool.pen,
      buttons: PenButtons(_buttons[index]),
    );
  }

  void _write(int index, ByteData data, int offset) {
    final int flags = data.getUint16(offset + 12, Endian.little);
    final int rawPressure = data.getUint16(offset + 18, Endian.little);
    final int rawDistance = data.getUint16(offset + 20, Endian.little);
    final int rawTiltX = data.getInt16(offset + 22, Endian.little);
    final int rawTiltY = data.getInt16(offset + 24, Endian.little);
    _timestampsUs[index] = data.getUint64(offset, Endian.little);
    _xPx[index] = data.getFloat32(offset + 28, Endian.little);
    _yPx[index] = data.getFloat32(offset + 32, Endian.little);
    _pressure[index] = rawPressure / 4096;
    _tiltX[index] = rawTiltX * math.pi / 18000;
    _tiltY[index] = rawTiltY * math.pi / 18000;
    _distance[index] = rawDistance / 65535;
    _tool[index] = flags & _flagEraser != 0 ? 2 : 1;
    _buttons[index] =
        (flags & _flagPrimary != 0 ? PenButtons.primaryBit : 0) |
        (flags & _flagSecondary != 0 ? PenButtons.secondaryBit : 0);
    _rawX[index] = data.getUint16(offset + 14, Endian.little);
    _rawY[index] = data.getUint16(offset + 16, Endian.little);
    _rawPressure[index] = rawPressure;
    _rawDistance[index] = rawDistance;
    _rawTiltX[index] = rawTiltX;
    _rawTiltY[index] = rawTiltY;
  }
}

const int _magic = 0x52544c50;
const int _recordSize = 40;
const int _headerSize = 64;
const int _capacityOffset = 12;
const int _writeIndexOffset = 16;
const int _droppedOffset = 24;
const int _flagEraser = 0x4;
const int _flagPrimary = 0x8;
const int _flagSecondary = 0x10;

PenEvent _penEventFromMap(Map<String, Object?> map) {
  final PenSample sample = PenSample.fromMap(map);
  return switch (_stringAt(map, 'event')) {
    'enteredProximity' || 'enter' => PenEnteredProximityEvent(sample: sample),
    'hover' => PenHoverEvent(sample: sample),
    'down' => PenDownEvent(sample: sample),
    'move' => PenMoveEvent(sample: sample),
    'up' => PenUpEvent(sample: sample),
    'leftProximity' || 'leave' => PenLeftProximityEvent(sample: sample),
    'buttonsChanged' || 'buttons' => PenButtonsChangedEvent(
      sample: sample,
      previous: PenButtons(_optionalIntAt(map, 'previousButtons') ?? 0),
    ),
    _ => throw const FormatException('Unknown pen event.'),
  };
}

void _validateHeader(ByteData data) {
  if (data.getUint32(0, Endian.little) != _magic) {
    throw const FormatException('Invalid pen ring magic.');
  }
  if (data.getUint32(8, Endian.little) != _recordSize) {
    throw const FormatException('Invalid pen ring record size.');
  }
}

Map<String, Object?> _stringMap(Object? value, String path) {
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is String) {
        result[key] = entry.value;
      }
    }
    return result;
  }
  throw FormatException('Expected $path to be a map.');
}

String _stringAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected $key to be a string.');
}

int? _optionalIntAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  throw FormatException('Expected $key to be an int.');
}
