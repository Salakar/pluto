import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/reference_tool.dart';

void main() {
  group('cappedReferenceDecodeSize', () {
    test('preserves aspect ratio inside asymmetric canvas bounds', () {
      final ReferenceDecodeSize size = cappedReferenceDecodeSize(
        intrinsicWidth: 6000,
        intrinsicHeight: 12000,
        maxWidth: 4096,
        maxHeight: 3000,
      );

      expect(size, ReferenceDecodeSize(width: 1500, height: 3000));
    });

    test('does not upscale an already bounded image', () {
      final ReferenceDecodeSize size = cappedReferenceDecodeSize(
        intrinsicWidth: 320,
        intrinsicHeight: 200,
        maxWidth: 4096,
        maxHeight: 4096,
      );

      expect(size, ReferenceDecodeSize(width: 320, height: 200));
    });

    test('validates source and current-canvas dimensions', () {
      expect(
        () => cappedReferenceDecodeSize(
          intrinsicWidth: 0,
          intrinsicHeight: 10,
          maxWidth: 100,
          maxHeight: 100,
        ),
        throwsArgumentError,
      );
      expect(
        () => cappedReferenceDecodeSize(
          intrinsicWidth: 10,
          intrinsicHeight: 10,
          maxWidth: maximumReferenceDecodeDimension + 1,
          maxHeight: 100,
        ),
        throwsArgumentError,
      );
    });
  });

  group('ReferenceDecode', () {
    test('defensively owns an unmodifiable exact-length RGBA payload', () {
      final Uint8List source = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final ReferenceDecode decode = ReferenceDecode(
        descriptor: ReferenceImageDescriptor(
          sourceId: 'reference-1',
          pixelWidth: 1,
          pixelHeight: 1,
        ),
        rgbaBytes: source,
      );

      source[0] = 99;
      expect(decode.rgbaBytes, <int>[1, 2, 3, 4]);
      expect(() => decode.rgbaBytes[0] = 5, throwsUnsupportedError);
    });

    test('takeOwnership exposes an unmodifiable zero-copy view', () {
      final Uint8List source = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final ReferenceDecode decode = ReferenceDecode.takeOwnership(
        descriptor: ReferenceImageDescriptor(
          sourceId: 'reference-1',
          pixelWidth: 1,
          pixelHeight: 1,
        ),
        rgbaBytes: source,
      );

      source[0] = 99;
      expect(decode.rgbaBytes, <int>[99, 2, 3, 4]);
      expect(() => decode.rgbaBytes[0] = 5, throwsUnsupportedError);
    });

    test('rejects mismatched RGBA length and over-cap descriptors', () {
      expect(
        () => ReferenceDecode(
          descriptor: ReferenceImageDescriptor(
            sourceId: 'reference-1',
            pixelWidth: 2,
            pixelHeight: 1,
          ),
          rgbaBytes: Uint8List(4),
        ),
        throwsArgumentError,
      );
      expect(
        () => ReferenceDecode(
          descriptor: ReferenceImageDescriptor(
            sourceId: 'reference-1',
            pixelWidth: maximumReferenceDecodeDimension + 1,
            pixelHeight: 1,
          ),
          rgbaBytes: Uint8List(4),
        ),
        throwsArgumentError,
      );
    });
  });

  group('ReferenceImageDecoder', () {
    test('computes the cap before asking the backend for pixels', () async {
      final _FakeReferenceDecodeBackend backend = _FakeReferenceDecodeBackend(
        intrinsicWidth: 1200,
        intrinsicHeight: 600,
      );
      final ReferenceImageDecoder decoder = ReferenceImageDecoder(
        backend: backend,
      );
      final Uint8List encodedBytes = _pngBytes();

      final ReferenceDecodeResult result = await decoder.decode(
        sourceId: 'imports/oversized.png',
        fileName: 'oversized.PNG',
        encodedBytes: encodedBytes,
        maxWidth: 400,
        maxHeight: 300,
      );

      expect(result, isA<ReferenceDecodeSuccess>());
      final ReferenceDecode decode = (result as ReferenceDecodeSuccess).decode;
      expect(decode.descriptor.sourceId, 'imports/oversized.png');
      expect(decode.descriptor.pixelWidth, 400);
      expect(decode.descriptor.pixelHeight, 200);
      expect(decode.rgbaBytes.lengthInBytes, 400 * 200 * 4);
      expect(backend.lastSource?.targetWidth, 400);
      expect(backend.lastSource?.targetHeight, 200);
      expect(backend.lastSource?.isDisposed, isTrue);
      expect(backend.lastEncodedBytes, same(encodedBytes));
    });

    test('accepts both JPEG extensions case-insensitively', () async {
      final _FakeReferenceDecodeBackend jpgBackend =
          _FakeReferenceDecodeBackend(intrinsicWidth: 4, intrinsicHeight: 3);
      final _FakeReferenceDecodeBackend jpegBackend =
          _FakeReferenceDecodeBackend(intrinsicWidth: 4, intrinsicHeight: 3);

      final ReferenceDecodeResult jpg =
          await ReferenceImageDecoder(backend: jpgBackend).decode(
            sourceId: 'one',
            fileName: 'one.JpG',
            encodedBytes: _jpegBytes(),
            maxWidth: 10,
            maxHeight: 10,
          );
      final ReferenceDecodeResult jpeg =
          await ReferenceImageDecoder(backend: jpegBackend).decode(
            sourceId: 'two',
            fileName: 'two.jpeg',
            encodedBytes: _jpegBytes(),
            maxWidth: 10,
            maxHeight: 10,
          );

      expect(jpg, isA<ReferenceDecodeSuccess>());
      expect(jpeg, isA<ReferenceDecodeSuccess>());
    });

    test(
      'rejects unsupported extensions without opening the backend',
      () async {
        final _FakeReferenceDecodeBackend backend = _FakeReferenceDecodeBackend(
          intrinsicWidth: 4,
          intrinsicHeight: 3,
        );

        final ReferenceDecodeResult result =
            await ReferenceImageDecoder(backend: backend).decode(
              sourceId: 'imports/reference.webp',
              fileName: 'reference.webp',
              encodedBytes: Uint8List.fromList(<int>[1, 2, 3]),
              maxWidth: 100,
              maxHeight: 100,
            );

        expect(result, isA<ReferenceDecodeFailure>());
        final ReferenceDecodeFailure failure = result as ReferenceDecodeFailure;
        expect(failure.kind, ReferenceDecodeFailureKind.unsupportedFormat);
        expect(failure.reason, isNotEmpty);
        expect(backend.openCount, 0);
      },
    );

    test(
      'rejects a lying supported extension without opening the backend',
      () async {
        final _FakeReferenceDecodeBackend backend = _FakeReferenceDecodeBackend(
          intrinsicWidth: 4,
          intrinsicHeight: 3,
        );

        final ReferenceDecodeResult result =
            await ReferenceImageDecoder(backend: backend).decode(
              sourceId: 'imports/not-really-png.png',
              fileName: 'not-really-png.png',
              encodedBytes: Uint8List.fromList(<int>[
                0x47,
                0x49,
                0x46,
                0x38,
                0x39,
                0x61,
              ]),
              maxWidth: 100,
              maxHeight: 100,
            );

        expect(result, isA<ReferenceDecodeFailure>());
        final ReferenceDecodeFailure failure = result as ReferenceDecodeFailure;
        expect(failure.kind, ReferenceDecodeFailureKind.unsupportedFormat);
        expect(failure.reason, isNotEmpty);
        expect(backend.openCount, 0);
      },
    );

    test(
      'maps corrupt metadata and pixels to failures instead of throws',
      () async {
        final _FakeReferenceDecodeBackend openFailureBackend =
            _FakeReferenceDecodeBackend(
              intrinsicWidth: 4,
              intrinsicHeight: 3,
              failOpen: true,
            );
        final _FakeReferenceDecodeBackend pixelFailureBackend =
            _FakeReferenceDecodeBackend(
              intrinsicWidth: 4,
              intrinsicHeight: 3,
              truncatePixels: true,
            );

        final ReferenceDecodeResult corruptMetadata =
            await ReferenceImageDecoder(backend: openFailureBackend).decode(
              sourceId: 'bad-metadata',
              fileName: 'bad.png',
              encodedBytes: _pngBytes(),
              maxWidth: 100,
              maxHeight: 100,
            );
        final ReferenceDecodeResult corruptPixels =
            await ReferenceImageDecoder(backend: pixelFailureBackend).decode(
              sourceId: 'bad-pixels',
              fileName: 'bad.jpg',
              encodedBytes: _jpegBytes(),
              maxWidth: 100,
              maxHeight: 100,
            );

        expect(
          (corruptMetadata as ReferenceDecodeFailure).kind,
          ReferenceDecodeFailureKind.corruptImage,
        );
        expect(
          (corruptPixels as ReferenceDecodeFailure).kind,
          ReferenceDecodeFailureKind.corruptImage,
        );
        expect(pixelFailureBackend.lastSource?.isDisposed, isTrue);
      },
    );

    test('returns an empty-image failure and validates API bounds', () async {
      final _FakeReferenceDecodeBackend backend = _FakeReferenceDecodeBackend(
        intrinsicWidth: 4,
        intrinsicHeight: 3,
      );
      final ReferenceImageDecoder decoder = ReferenceImageDecoder(
        backend: backend,
      );

      final ReferenceDecodeResult empty = await decoder.decode(
        sourceId: 'empty',
        fileName: 'empty.png',
        encodedBytes: Uint8List(0),
        maxWidth: 100,
        maxHeight: 100,
      );

      expect(
        (empty as ReferenceDecodeFailure).kind,
        ReferenceDecodeFailureKind.corruptImage,
      );
      expect(backend.openCount, 0);
      await expectLater(
        decoder.decode(
          sourceId: 'bounded',
          fileName: 'bounded.png',
          encodedBytes: _pngBytes(),
          maxWidth: 0,
          maxHeight: 100,
        ),
        throwsArgumentError,
      );
    });
  });
}

final class _FakeReferenceDecodeBackend implements ReferenceDecodeBackend {
  _FakeReferenceDecodeBackend({
    required this.intrinsicWidth,
    required this.intrinsicHeight,
    this.failOpen = false,
    this.truncatePixels = false,
  });

  final int intrinsicWidth;
  final int intrinsicHeight;
  final bool failOpen;
  final bool truncatePixels;
  int openCount = 0;
  _FakeReferenceDecodeSource? lastSource;
  Uint8List? lastEncodedBytes;

  @override
  Future<ReferenceDecodeSource> open(Uint8List encodedBytes) async {
    openCount += 1;
    lastEncodedBytes = encodedBytes;
    if (failOpen) {
      throw const FormatException('corrupt metadata');
    }
    final _FakeReferenceDecodeSource source = _FakeReferenceDecodeSource(
      intrinsicWidth: intrinsicWidth,
      intrinsicHeight: intrinsicHeight,
      truncatePixels: truncatePixels,
    );
    lastSource = source;
    return source;
  }
}

Uint8List _pngBytes() =>
    Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

Uint8List _jpegBytes() => Uint8List.fromList(<int>[0xff, 0xd8, 0xff]);

final class _FakeReferenceDecodeSource implements ReferenceDecodeSource {
  _FakeReferenceDecodeSource({
    required this.intrinsicWidth,
    required this.intrinsicHeight,
    required this.truncatePixels,
  });

  @override
  final int intrinsicWidth;

  @override
  final int intrinsicHeight;

  final bool truncatePixels;
  int? targetWidth;
  int? targetHeight;
  bool isDisposed = false;

  @override
  Future<Uint8List> decodeRgba({
    required int targetWidth,
    required int targetHeight,
  }) async {
    this.targetWidth = targetWidth;
    this.targetHeight = targetHeight;
    final int exactLength = targetWidth * targetHeight * 4;
    return Uint8List(truncatePixels ? exactLength - 1 : exactLength);
  }

  @override
  void dispose() {
    isDisposed = true;
  }
}
