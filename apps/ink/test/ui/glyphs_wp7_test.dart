import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/ui/glyphs.dart';

void main() {
  group('WP7 drawn glyph catalog', () {
    test('contains every binding code name in stable order', () {
      expect(InkGlyph.values.map((InkGlyph glyph) => glyph.codeName), <String>[
        'benchGrip',
        'collapseChevrons',
        'markDraw',
        'markErase',
        'markSelect',
        'markTransform',
        'markFill',
        'markShape',
        'markText',
        'markPicker',
        'markGuides',
        'markCrop',
        'markReference',
        'markLayers',
        'markColor',
        'markMenu',
        'markUndo',
        'markRedo',
        'markDrying',
        'markHeavy',
        'markTrash',
        'markDuplicate',
        'markMergeDown',
        'markEyeOpen',
        'markEyeClosed',
        'markLock',
        'markUnlock',
        'markPin',
        'markFlipH',
        'markFlipV',
        'markAspect',
        'markSnap',
        'markImport',
        'markCheck',
      ]);
    });

    for (final InkGlyph glyph in InkGlyph.values) {
      test(glyph.codeName, () {
        final InkGlyphPainter painter = InkGlyphPainter(glyph: glyph);

        expect(_recordedBytes(painter, const Size.square(64)), greaterThan(0));
      });
    }

    test('six-dot grip records exactly six dot primitives', () {
      const InkGlyphPainter painter = InkGlyphPainter(
        glyph: InkGlyph.benchGrip,
      );

      expect(
        (Canvas canvas) => painter.paint(canvas, const Size.square(64)),
        paintsExactlyCountTimes(#drawCircle, 6),
      );
    });

    test('selection loop is visibly dashed rather than a solid rectangle', () {
      const InkGlyphPainter painter = InkGlyphPainter(
        glyph: InkGlyph.markSelect,
      );

      expect(
        (Canvas canvas) => painter.paint(canvas, const Size.square(64)),
        paintsExactlyCountTimes(#drawArc, 10),
      );
    });

    test('current-color ring is the only requested colored primitive', () {
      const Color selected = Color(0xffb3261e);
      const InkGlyphPainter painter = InkGlyphPainter(
        glyph: InkGlyph.markColor,
        currentColor: selected,
      );

      expect(
        (Canvas canvas) => painter.paint(canvas, const Size.square(64)),
        paints..something((Symbol method, List<dynamic> arguments) {
          if (method != #drawCircle) {
            return false;
          }
          final Paint paint = arguments[2] as Paint;
          // Paint stores channels as float32, while Color's integer
          // constructor retains double-precision channel fractions.
          return paint.color.toARGB32() == selected.toARGB32();
        }),
      );
    });

    test('empty bounds record no paint calls', () {
      const InkGlyphPainter painter = InkGlyphPainter(glyph: InkGlyph.markDraw);

      expect(
        (Canvas canvas) => painter.paint(canvas, Size.zero),
        paintsNothing,
      );
    });

    test('repaint contract tracks every visible input', () {
      const InkGlyphPainter base = InkGlyphPainter(glyph: InkGlyph.markDraw);

      expect(
        base.shouldRepaint(const InkGlyphPainter(glyph: InkGlyph.markDraw)),
        isFalse,
      );
      expect(
        base.shouldRepaint(const InkGlyphPainter(glyph: InkGlyph.markErase)),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          const InkGlyphPainter(
            glyph: InkGlyph.markDraw,
            color: Color(0xff333333),
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          const InkGlyphPainter(
            glyph: InkGlyph.markDraw,
            currentColor: Color(0xffb3261e),
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          const InkGlyphPainter(glyph: InkGlyph.markDraw, strokeWidth: 3),
        ),
        isTrue,
      );
    });
  });

  group('WP7 production brush minis', () {
    test('mini identifiers exactly match the sixteen-brush catalog', () {
      expect(
        InkBrushMini.values.map((InkBrushMini brush) => brush.brushId),
        drawingBrushes.map((BrushSpec brush) => brush.id),
      );
    });

    for (final InkBrushMini brush in InkBrushMini.values) {
      test(brush.brushId, () {
        final BrushMiniPainter painter = BrushMiniPainter(brush: brush);

        expect(_recordedBytes(painter, const Size(152, 56)), greaterThan(0));
      });
    }

    test('empty proof bounds record no paint calls', () {
      const BrushMiniPainter painter = BrushMiniPainter(
        brush: InkBrushMini.fineliner,
      );

      expect(
        (Canvas canvas) => painter.paint(canvas, Size.zero),
        paintsNothing,
      );
    });

    test('proof repaint contract tracks brush and foreground', () {
      const BrushMiniPainter base = BrushMiniPainter(
        brush: InkBrushMini.fineliner,
      );

      expect(
        base.shouldRepaint(
          const BrushMiniPainter(brush: InkBrushMini.fineliner),
        ),
        isFalse,
      );
      expect(
        base.shouldRepaint(
          const BrushMiniPainter(brush: InkBrushMini.technical),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          const BrushMiniPainter(
            brush: InkBrushMini.fineliner,
            color: Color(0xffffffff),
          ),
        ),
        isTrue,
      );
    });
  });
}

int _recordedBytes(CustomPainter painter, Size size) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  painter.paint(canvas, size);
  final ui.Picture picture = recorder.endRecording();
  final int bytes = picture.approximateBytesUsed;
  picture.dispose();
  return bytes;
}
