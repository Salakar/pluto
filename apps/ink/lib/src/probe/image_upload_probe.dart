import 'dart:typed_data';
import 'dart:ui' as ui;

const int _tileWidth = 256;
const int _tileHeight = 256;
const int _bytesPerPixel = 4;
const int _iterationCount = 32;

/// Uploads 32 varied RGBA tiles and returns the per-image elapsed milliseconds.
Future<List<double>> runImageUploadProbe() async {
  final List<double> elapsedMilliseconds = <double>[];
  for (var iteration = 0; iteration < _iterationCount; iteration++) {
    final Uint8List pixels = _buildPixels(iteration);
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: _tileWidth,
        height: _tileHeight,
        rowBytes: _tileWidth * _bytesPerPixel,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
      stopwatch.stop();
      elapsedMilliseconds.add(stopwatch.elapsedMicroseconds / 1000);
    } finally {
      if (stopwatch.isRunning) {
        stopwatch.stop();
      }
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
  return List<double>.unmodifiable(elapsedMilliseconds);
}

Uint8List _buildPixels(int iteration) {
  final Uint8List pixels = Uint8List(_tileWidth * _tileHeight * _bytesPerPixel);
  for (var pixel = 0; pixel < _tileWidth * _tileHeight; pixel++) {
    final int x = pixel & 0xff;
    final int y = pixel >> 8;
    final int offset = pixel * _bytesPerPixel;
    pixels[offset] = (x + iteration * 17) & 0xff;
    pixels[offset + 1] = (y * 3 + iteration * 29) & 0xff;
    pixels[offset + 2] = (x ^ y ^ (iteration * 11)) & 0xff;
    pixels[offset + 3] = 0xff;
  }
  return pixels;
}
