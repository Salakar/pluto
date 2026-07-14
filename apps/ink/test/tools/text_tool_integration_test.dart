import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/text_tool.dart';
import 'package:paper_ink/src/tools/tool.dart';

void main() {
  group('text tool integration', () {
    test('edit operations flow into one rasterized journal command', () {
      final TextToolController controller = TextToolController(
        options: TextOptions(
          fontFamily: TextFontFamily.inter,
          size: 24,
          weight: InkTextWeight.medium,
          colorArgb: 0xff102030,
        ),
      );

      final TextBlockDraft placed = controller.place(
        point: const Offset(12, 18),
        width: 180,
        height: 60,
      );
      expect(placed.bounds, const Rect.fromLTWH(12, 18, 180, 60));
      expect(controller.hasLiveState, isTrue);

      controller.updateText('field notes');
      controller.dragBy(const Offset(8, -3));
      final TextOptions committedOptions = TextOptions(
        fontFamily: TextFontFamily.jetBrainsMono,
        size: 48,
        weight: InkTextWeight.extraBold,
        colorArgb: 0xffa1b2c3,
      );
      controller.setOptions(committedOptions);
      controller.resize(TextResizeHandle.bottomRight, const Offset(260, 135));

      final TextCommitCommand command = controller.commit(
        activeLayerId: 'ink-layer',
      );

      expect(command, isA<JournaledToolCommand>());
      expect(command.layerId, 'ink-layer');
      expect(command.journalKind, JournalKind.text);
      expect(command.rasterizeAtCommit, isTrue);
      expect(command.metadata.text, 'field notes');
      expect(command.metadata.bounds, const Rect.fromLTRB(20, 15, 260, 135));
      expect(command.metadata.fontFamily, TextFontFamily.jetBrainsMono);
      expect(command.metadata.size, 48);
      expect(command.metadata.weight, InkTextWeight.extraBold);
      expect(command.metadata.colorArgb, 0xffa1b2c3);
      expect(command.metadata.toJson(), <String, Object>{
        'text': 'field notes',
        'bounds': <double>[20, 15, 240, 120],
        'fontFamily': 'JetBrains Mono',
        'size': 48,
        'weight': 800,
        'colorArgb': 0xffa1b2c3,
      });
      expect(controller.lastCommit, same(command));
      expect(controller.draft, isNull);
      expect(controller.hasLiveState, isFalse);
    });

    test('dock options can target the current draft or the next placement', () {
      final TextOptions first = TextOptions(
        size: 16,
        weight: InkTextWeight.medium,
      );
      final TextOptions currentDraftOptions = first.copyWith(
        size: 32,
        weight: InkTextWeight.bold,
      );
      final TextOptions nextPlacementOptions = currentDraftOptions.copyWith(
        size: 96,
        weight: InkTextWeight.extraBold,
      );
      final TextToolController controller = TextToolController(options: first);
      controller.place(point: Offset.zero);

      controller.setOptions(currentDraftOptions);
      expect(controller.options, same(currentDraftOptions));
      expect(controller.draft!.options, same(currentDraftOptions));

      controller.setOptions(nextPlacementOptions, applyToDraft: false);
      expect(controller.options, same(nextPlacementOptions));
      expect(controller.draft!.options, same(currentDraftOptions));

      controller.cancel();
      final TextBlockDraft next = controller.place(point: const Offset(4, 5));
      expect(next.options, same(nextPlacementOptions));
      expect(next.bounds.height, 144);
    });

    test('all resize handles enforce the usable text-block minimum', () {
      final TextToolController controller = TextToolController(
        options: TextOptions(size: 48),
      );

      controller.place(point: const Offset(100, 100), width: 200, height: 100);
      expect(
        controller
            .resize(TextResizeHandle.topLeft, const Offset(290, 190))
            .bounds,
        const Rect.fromLTRB(204, 140, 300, 200),
      );

      controller.cancel();
      controller.place(point: const Offset(100, 100), width: 200, height: 100);
      expect(
        controller
            .resize(TextResizeHandle.topRight, const Offset(110, 190))
            .bounds,
        const Rect.fromLTRB(100, 140, 196, 200),
      );

      controller.cancel();
      controller.place(point: const Offset(100, 100), width: 200, height: 100);
      expect(
        controller
            .resize(TextResizeHandle.bottomLeft, const Offset(290, 110))
            .bounds,
        const Rect.fromLTRB(204, 100, 300, 160),
      );

      controller.cancel();
      controller.place(point: const Offset(100, 100), width: 200, height: 100);
      expect(
        controller
            .resize(TextResizeHandle.bottomRight, const Offset(110, 110))
            .bounds,
        const Rect.fromLTRB(100, 100, 196, 160),
      );
    });

    test(
      'the journal command restores the exact editable draft after undo',
      () {
        final TextToolController controller = TextToolController(
          options: TextOptions(
            fontFamily: TextFontFamily.jetBrainsMono,
            size: 64,
            weight: InkTextWeight.semiBold,
            colorArgb: 0xff405060,
          ),
        );
        controller.place(point: const Offset(30, 40), width: 320, height: 120);
        controller.updateText('editable after undo');
        final TextCommitCommand command = controller.commit(
          activeLayerId: 'notes',
        );

        expect(controller.restoreLastCommitForEditing(), isTrue);
        final TextBlockDraft restored = controller.draft!;
        expect(restored.text, command.metadata.text);
        expect(restored.bounds, command.metadata.bounds);
        expect(restored.options.fontFamily, command.metadata.fontFamily);
        expect(restored.options.size, command.metadata.size);
        expect(restored.options.weight, command.metadata.weight);
        expect(restored.options.colorArgb, command.metadata.colorArgb);
      },
    );

    test('durable metadata restores editing without a session commit', () {
      final TextJournalMetadata metadata = TextJournalMetadata.fromJson(
        <String, Object?>{
          'text': 'reopened block',
          'bounds': <Object?>[20, 30, 180, 72],
          'fontFamily': 'JetBrains Mono',
          'size': 48,
          'weight': 700,
          'colorArgb': 0xff203040,
        },
      );
      final TextToolController controller = TextToolController();

      controller.restoreMetadataForEditing(metadata);

      expect(controller.draft!.text, 'reopened block');
      expect(controller.draft!.bounds, const Rect.fromLTWH(20, 30, 180, 72));
      expect(
        controller.draft!.options.fontFamily,
        TextFontFamily.jetBrainsMono,
      );
      expect(controller.draft!.options.size, 48);
      expect(controller.draft!.options.weight, InkTextWeight.bold);
      expect(controller.draft!.options.colorArgb, 0xff203040);
      expect(controller.options, same(controller.draft!.options));
    });
  });
}
