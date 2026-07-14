import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/export.dart';
import 'package:paper_ink/src/document/document_io.dart';
import 'package:paper_ink/src/document/tile_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('thumbnail dimensions keep aspect with an exact 424px long edge', () {
    expect(
      inkThumbnailSize(width: 1908, height: 3392),
      InkPixelSize(width: 239, height: 424),
    );
    expect(
      inkThumbnailSize(width: 2048, height: 1024),
      InkPixelSize(width: 424, height: 212),
    );
    expect(
      inkThumbnailSize(width: 1, height: 4096),
      InkPixelSize(width: 1, height: 424),
    );
  });

  testWidgets('fixed document produces byte-stable real PNG and USTAR', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Directory temporary = await Directory.systemTemp.createTemp(
        'ink-wp8-stable-',
      );
      try {
        final _ExportFixture fixture = await _createFixture(temporary);
        final List<InkExportPhase> phases = <InkExportPhase>[];

        final InkExportSuccess firstPng =
            await fixture.transfers.export(
                  artworkId: fixture.document.id,
                  kind: InkExportKind.png1x,
                  onProgress: phases.add,
                )
                as InkExportSuccess;
        final Uint8List firstPngBytes = await File(firstPng.path).readAsBytes();
        final InkExportSuccess secondPng =
            await fixture.transfers.export(
                  artworkId: fixture.document.id,
                  kind: InkExportKind.png1x,
                )
                as InkExportSuccess;
        final Uint8List secondPngBytes = await File(
          secondPng.path,
        ).readAsBytes();

        expect(firstPngBytes, orderedEquals(secondPngBytes));
        expect(
          firstPngBytes.take(8),
          orderedEquals(const <int>[137, 80, 78, 71, 13, 10, 26, 10]),
        );
        expect(phases, <InkExportPhase>[
          InkExportPhase.flattening,
          InkExportPhase.writing,
          InkExportPhase.done,
        ]);

        final Directory journal = Directory(
          '${fixture.store.artworkDirectory(fixture.document.id).path}/journal',
        );
        await journal.create();
        await File(
          '${journal.path}/00000007.json',
        ).writeAsString('{"must":"not be archived"}', flush: true);

        final InkExportSuccess firstPack =
            await fixture.transfers.export(
                  artworkId: fixture.document.id,
                  kind: InkExportKind.inkpack,
                )
                as InkExportSuccess;
        final Uint8List firstPackBytes = await File(
          firstPack.path,
        ).readAsBytes();
        final InkExportSuccess secondPack =
            await fixture.transfers.export(
                  artworkId: fixture.document.id,
                  kind: InkExportKind.inkpack,
                )
                as InkExportSuccess;
        final Uint8List secondPackBytes = await File(
          secondPack.path,
        ).readAsBytes();

        expect(firstPackBytes, orderedEquals(secondPackBytes));
        expect(
          utf8.decode(firstPackBytes, allowMalformed: true),
          isNot(contains('journal/')),
        );
        expect(firstPackBytes.length % 512, 0);
      } finally {
        await temporary.delete(recursive: true);
      }
    });
  });

  testWidgets('PNG scale and real thumbnail dimensions match the canvas', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Directory temporary = await Directory.systemTemp.createTemp(
        'ink-wp8-dimensions-',
      );
      try {
        final _ExportFixture fixture = await _createFixture(temporary);
        final InkExportSuccess png =
            await fixture.transfers.export(
                  artworkId: fixture.document.id,
                  kind: InkExportKind.png2x,
                )
                as InkExportSuccess;
        final Uint8List firstPngBytes = await File(png.path).readAsBytes();
        final InkExportSuccess repeatedPng =
            await fixture.transfers.export(
                  artworkId: fixture.document.id,
                  kind: InkExportKind.png2x,
                )
                as InkExportSuccess;
        expect(
          await File(repeatedPng.path).readAsBytes(),
          orderedEquals(firstPngBytes),
        );
        final ui.Codec pngCodec = await ui.instantiateImageCodec(firstPngBytes);
        final ui.FrameInfo pngFrame = await pngCodec.getNextFrame();
        expect(pngFrame.image.width, 16);
        expect(pngFrame.image.height, 8);
        pngFrame.image.dispose();
        pngCodec.dispose();

        final File thumb = File(
          '${fixture.store.artworkDirectory(fixture.document.id).path}/thumb.png',
        );
        final ui.Codec thumbCodec = await ui.instantiateImageCodec(
          await thumb.readAsBytes(),
        );
        final ui.FrameInfo thumbFrame = await thumbCodec.getNextFrame();
        expect(thumbFrame.image.width, 424);
        expect(thumbFrame.image.height, 212);
        thumbFrame.image.dispose();
        thumbCodec.dispose();
      } finally {
        await temporary.delete(recursive: true);
      }
    });
  });

  testWidgets('inkpack round trip preserves manifest and exact tile bytes', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final Directory temporary = await Directory.systemTemp.createTemp(
        'ink-wp8-roundtrip-',
      );
      try {
        final _ExportFixture fixture = await _createFixture(temporary);
        final InkExportSuccess archive =
            await fixture.transfers.export(
                  artworkId: fixture.document.id,
                  kind: InkExportKind.inkpack,
                )
                as InkExportSuccess;
        final InkDocumentTransferService importer = InkDocumentTransferService(
          store: fixture.store,
          exportsDirectory: fixture.exports,
          nowMilliseconds: () => 2222,
          idGenerator: () => 'fresh-import-id',
        );

        final GalleryEntry? importedEntry = await importer.importInkpack(
          File(archive.path),
        );
        expect(importedEntry, isNotNull);
        expect(importedEntry!.id, 'fresh-import-id');
        final LoadedInkDocument original = (await fixture.store.openDocument(
          fixture.document.id,
        ))!;
        final LoadedInkDocument imported = (await fixture.store.openDocument(
          importedEntry.id,
        ))!;
        await (original.loadRemaining(), imported.loadRemaining()).wait;

        final Map<String, Object?> originalManifest = original.document.toJson()
          ..['id'] = '<fresh>';
        final Map<String, Object?> importedManifest = imported.document.toJson()
          ..['id'] = '<fresh>';
        expect(importedManifest, equals(originalManifest));
        expect(
          imported.tiles.locations,
          orderedEquals(original.tiles.locations),
        );
        for (final TileLocation location in original.tiles.locations) {
          expect(
            imported.tiles.tile(location.layerId, location.key)!.pixels,
            orderedEquals(
              original.tiles.tile(location.layerId, location.key)!.pixels,
            ),
          );
        }
        expect((await fixture.store.loadGallery()).first.id, importedEntry.id);
      } finally {
        await temporary.delete(recursive: true);
      }
    });
  });

  testWidgets(
    'corrupt tar and unknown schema skip with a reason and no throw',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Directory temporary = await Directory.systemTemp.createTemp(
          'ink-wp8-invalid-',
        );
        try {
          final _ExportFixture fixture = await _createFixture(temporary);
          final File corrupt = File('${temporary.path}/corrupt.inkpack');
          await corrupt.writeAsBytes(Uint8List(1024), flush: true);
          expect(await fixture.transfers.importInkpack(corrupt), isNull);
          expect(fixture.transfers.lastImportFailureReason, isNotEmpty);

          final InkExportSuccess valid =
              await fixture.transfers.export(
                    artworkId: fixture.document.id,
                    kind: InkExportKind.inkpack,
                  )
                  as InkExportSuccess;
          final Uint8List badSchemaBytes = await File(valid.path).readAsBytes();
          final int schemaOffset = _indexOfBytes(
            badSchemaBytes,
            utf8.encode('"schema":1'),
          );
          expect(schemaOffset, greaterThanOrEqualTo(0));
          badSchemaBytes[schemaOffset + '"schema":'.length] = 0x39;
          final File badSchema = File('${temporary.path}/schema-9.inkpack');
          await badSchema.writeAsBytes(badSchemaBytes, flush: true);

          expect(await fixture.transfers.importInkpack(badSchema), isNull);
          expect(fixture.transfers.lastImportFailureReason, contains('schema'));

          final Uint8List corruptThumbnailBytes = await File(
            valid.path,
          ).readAsBytes();
          final int thumbnailHeader = _indexOfBytes(
            corruptThumbnailBytes,
            ascii.encode('thumb.png'),
          );
          expect(thumbnailHeader, greaterThanOrEqualTo(0));
          final int thumbnailData = thumbnailHeader + 512;
          corruptThumbnailBytes.fillRange(
            thumbnailData + 24,
            thumbnailData + 152,
            0,
          );
          final File badThumbnail = File(
            '${temporary.path}/bad-thumbnail.inkpack',
          );
          await badThumbnail.writeAsBytes(corruptThumbnailBytes, flush: true);

          expect(await fixture.transfers.importInkpack(badThumbnail), isNull);
          expect(
            fixture.transfers.lastImportFailureReason,
            contains('thumbnail'),
          );
        } finally {
          await temporary.delete(recursive: true);
        }
      });
    },
  );

  test('encoder failure leaves no partial user-visible export', () async {
    final Directory temporary = await Directory.systemTemp.createTemp(
      'ink-wp8-failure-',
    );
    try {
      final _ExportFixture fixture = await _createFixture(temporary);
      final InkDocumentTransferService failing = InkDocumentTransferService(
        store: fixture.store,
        exportsDirectory: fixture.exports,
        nowMilliseconds: () => 3333,
        pngEncoder: (InkRasterImage image, {required int scale}) =>
            throw const FileSystemException('No space left on device'),
      );

      final InkExportResult result = await failing.export(
        artworkId: fixture.document.id,
        kind: InkExportKind.png1x,
      );

      expect(result, isA<InkExportFailure>());
      expect((result as InkExportFailure).reason, contains('No space'));
      expect(
        fixture.exports.existsSync()
            ? fixture.exports.listSync().whereType<File>()
            : const <File>[],
        isEmpty,
      );
    } finally {
      await temporary.delete(recursive: true);
    }
  });
}

final class _ExportFixture {
  const _ExportFixture({
    required this.store,
    required this.document,
    required this.exports,
    required this.transfers,
  });

  final DocumentStore store;
  final InkDocument document;
  final Directory exports;
  final InkDocumentTransferService transfers;
}

Future<_ExportFixture> _createFixture(Directory temporary) async {
  final Directory documents = Directory('${temporary.path}/documents');
  final Directory exports = Directory('${documents.path}/exports');
  await exports.create(recursive: true);
  final DocumentStore store = DocumentStore(
    root: documents,
    nowMilliseconds: () => 1111,
  );
  final Uint8List bottomPixels = Uint8List(Tile.byteLength);
  final Uint8List topPixels = Uint8List(Tile.byteLength);
  final Uint8List preservedOffCanvasPixels = Uint8List(Tile.byteLength)
    ..setRange(0, 4, const <int>[18, 52, 86, 255]);
  for (var pixel = 0; pixel < 32; pixel += 1) {
    final int offset = pixel * 4;
    bottomPixels[offset] = 220;
    bottomPixels[offset + 1] = 40;
    bottomPixels[offset + 2] = 20;
    bottomPixels[offset + 3] = 255;
    topPixels[offset] = 0;
    topPixels[offset + 1] = 40;
    topPixels[offset + 2] = 100;
    topPixels[offset + 3] = 128;
  }
  final TileStore tiles = TileStore()
    ..publish('L1', const TileKey(0, 0), Tile.takeOwnership(bottomPixels))
    ..publish(
      'L1',
      const TileKey(20, -3),
      Tile.takeOwnership(preservedOffCanvasPixels),
    )
    ..publish('L2', const TileKey(0, 0), Tile.takeOwnership(topPixels));
  final InkDocument source = InkDocument(
    id: 'stable-document',
    name: 'Stable / Study',
    createdAtMs: 100,
    modifiedAtMs: 200,
    canvas: CanvasSpec(width: 8, height: 4),
    layers: <InkLayer>[
      InkLayer(id: 'L1', name: 'bottom'),
      InkLayer(id: 'L2', name: 'top', opacity: 75, blend: 'multiply'),
    ],
    activeLayerId: 'L2',
    view: InkViewState(),
    tool: InkToolState(
      toolId: 'draw',
      brushId: 'fineliner',
      color: '#1D3E74',
      size: 4,
    ),
    journalHeadSeq: 7,
  );
  final InkDocument persisted = await store.saveDocument(source, tiles);
  final InkDocumentTransferService transfers = InkDocumentTransferService(
    store: store,
    exportsDirectory: exports,
    nowMilliseconds: () => 1111,
  );
  return _ExportFixture(
    store: store,
    document: persisted,
    exports: exports,
    transfers: transfers,
  );
}

int _indexOfBytes(Uint8List haystack, List<int> needle) {
  for (var offset = 0; offset <= haystack.length - needle.length; offset += 1) {
    var matches = true;
    for (var index = 0; index < needle.length; index += 1) {
      if (haystack[offset + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return offset;
    }
  }
  return -1;
}
