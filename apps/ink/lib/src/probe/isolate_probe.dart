import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

const int _tileWidth = 256;
const int _tileHeight = 256;
const int _bytesPerPixel = 4;
const int _tileByteCount = _tileWidth * _tileHeight * _bytesPerPixel;
const int _tileCount = 4;
const int _iterationCount = 32;
const Duration _workerResponseTimeout = Duration(seconds: 10);

/// Runs the worker-isolate blend benchmark.
abstract interface class IsolateProbeRunner {
  /// Performs all 32 round trips and returns their timing distributions.
  Future<IsolateProbeResult> run();
}

/// Per-iteration round-trip and worker-only blend durations.
final class IsolateProbeResult {
  IsolateProbeResult({
    required List<double> roundTripMilliseconds,
    required List<double> blendMilliseconds,
  }) : roundTripMilliseconds = List<double>.unmodifiable(roundTripMilliseconds),
       blendMilliseconds = List<double>.unmodifiable(blendMilliseconds);

  /// Main-isolate transfer, worker, return, and materialization durations.
  final List<double> roundTripMilliseconds;

  /// Alpha-blend loop durations measured inside the worker isolate.
  final List<double> blendMilliseconds;
}

/// Real isolate runner that reuses one worker for every benchmark iteration.
final class IsolateBlendProbeRunner implements IsolateProbeRunner {
  const IsolateBlendProbeRunner();

  @override
  Future<IsolateProbeResult> run() async {
    final ReceivePort responses = ReceivePort('ink-probe-responses');
    final StreamIterator<Object?> messages = StreamIterator<Object?>(responses);
    Isolate? isolate;
    SendPort? commands;
    try {
      isolate = await Isolate.spawn<SendPort>(
        _blendWorkerMain,
        responses.sendPort,
        debugName: 'ink-probe-blend-worker',
      );
      if (!await messages.moveNext().timeout(_workerResponseTimeout) ||
          messages.current is! SendPort) {
        throw StateError('Blend worker did not publish its command port.');
      }
      commands = messages.current! as SendPort;

      final List<double> roundTripMilliseconds = <double>[];
      final List<double> blendMilliseconds = <double>[];
      for (var iteration = 0; iteration < _iterationCount; iteration++) {
        final List<Uint8List> tiles = List<Uint8List>.generate(
          _tileCount,
          (int tile) => _buildTile(iteration: iteration, tile: tile),
          growable: false,
        );
        final Stopwatch stopwatch = Stopwatch()..start();
        final List<TransferableTypedData> transfers = tiles
            .map(
              (Uint8List tile) =>
                  TransferableTypedData.fromList(<TypedData>[tile]),
            )
            .toList(growable: false);
        commands.send(transfers);
        if (!await messages.moveNext().timeout(_workerResponseTimeout)) {
          throw StateError('Blend worker closed before replying.');
        }
        final Object? response = messages.current;
        if (response is! List<Object?> || response.length != 2) {
          throw StateError('Blend worker returned an invalid response.');
        }
        final Object? outputTransfer = response[0];
        final Object? blendMicroseconds = response[1];
        if (outputTransfer is! TransferableTypedData ||
            blendMicroseconds is! int) {
          throw StateError('Blend worker response has invalid fields.');
        }
        final Uint8List output = outputTransfer.materialize().asUint8List();
        if (output.lengthInBytes != _tileByteCount) {
          throw StateError('Blend worker returned a truncated tile.');
        }
        stopwatch.stop();
        roundTripMilliseconds.add(stopwatch.elapsedMicroseconds / 1000);
        blendMilliseconds.add(blendMicroseconds / 1000);
      }

      commands.send(null);
      return IsolateProbeResult(
        roundTripMilliseconds: roundTripMilliseconds,
        blendMilliseconds: blendMilliseconds,
      );
    } finally {
      await messages.cancel();
      responses.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }
}

@pragma('vm:entry-point')
void _blendWorkerMain(SendPort parentPort) {
  final ReceivePort commands = ReceivePort('ink-probe-blend-commands');
  parentPort.send(commands.sendPort);
  commands.listen((Object? message) {
    if (message == null) {
      commands.close();
      return;
    }
    if (message is! List<Object?> || message.length != _tileCount) {
      throw StateError('Blend worker received an invalid request.');
    }
    final List<Uint8List> tiles = <Uint8List>[];
    for (final Object? value in message) {
      if (value is! TransferableTypedData) {
        throw StateError('Blend worker request contains invalid tile data.');
      }
      final Uint8List tile = value.materialize().asUint8List();
      if (tile.lengthInBytes != _tileByteCount) {
        throw StateError('Blend worker request contains a truncated tile.');
      }
      tiles.add(tile);
    }
    final Stopwatch blendStopwatch = Stopwatch()..start();
    final Uint8List output = _alphaBlend(tiles);
    blendStopwatch.stop();
    parentPort.send(<Object?>[
      TransferableTypedData.fromList(<TypedData>[output]),
      blendStopwatch.elapsedMicroseconds,
    ]);
  });
}

Uint8List _buildTile({required int iteration, required int tile}) {
  final Uint8List bytes = Uint8List(_tileByteCount);
  for (var pixel = 0; pixel < _tileWidth * _tileHeight; pixel++) {
    final int x = pixel & 0xff;
    final int y = pixel >> 8;
    final int offset = pixel * _bytesPerPixel;
    final int alpha = 48 + ((x + y + iteration * 5 + tile * 31) & 0x7f);
    bytes[offset] =
        (((x + iteration * 13 + tile * 41) & 0xff) * alpha + 127) ~/ 255;
    bytes[offset + 1] =
        (((y * 3 + iteration * 19 + tile * 23) & 0xff) * alpha + 127) ~/ 255;
    bytes[offset + 2] =
        (((x ^ y ^ (iteration * 7) ^ (tile * 61)) & 0xff) * alpha + 127) ~/ 255;
    bytes[offset + 3] = alpha;
  }
  return bytes;
}

Uint8List _alphaBlend(List<Uint8List> tiles) {
  final Uint8List output = Uint8List(_tileByteCount);
  for (final Uint8List source in tiles) {
    for (var offset = 0; offset < _tileByteCount; offset += _bytesPerPixel) {
      final int sourceAlpha = source[offset + 3];
      final int inverseSourceAlpha = 255 - sourceAlpha;
      for (var channel = 0; channel < 3; channel++) {
        output[offset + channel] =
            source[offset + channel] +
            (output[offset + channel] * inverseSourceAlpha + 127) ~/ 255;
      }
      output[offset + 3] =
          sourceAlpha + (output[offset + 3] * inverseSourceAlpha + 127) ~/ 255;
    }
  }
  return output;
}
