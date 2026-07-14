import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/engine/stroke_pipeline.dart';
import 'package:paper_ink/src/ui/proof_sheet.dart';

void main() {
  group('starter brush proof plan', () {
    test('covers each starter brush exactly once in catalog order', () {
      final ProofSheetPlan plan = buildStarterProofSheetPlan();

      expect(
        plan.rows.map((ProofBrushRowPlan row) => row.brush.id),
        orderedEquals(<String>[
          'fineliner',
          'technical',
          'ballpoint',
          'brushpen',
          'pencilhb',
          'eraserpixel',
        ]),
      );
      expect(
        plan.rows.map((ProofBrushRowPlan row) => row.brush.id).toSet(),
        hasLength(6),
      );
    });

    test('every row contains all three motifs and a five-ray tilt fan', () {
      final ProofSheetPlan plan = buildStarterProofSheetPlan(
        recorder: _emptyRecorder,
      );

      for (final ProofBrushRowPlan row in plan.rows) {
        expect(
          row.motifs.map((ProofMotifPlan motif) => motif.kind),
          orderedEquals(ProofMotifKind.values),
          reason: row.brush.id,
        );
        expect(row.motifs[0].strokes, hasLength(1));
        expect(row.motifs[1].strokes, hasLength(1));
        expect(row.motifs[2].strokes, hasLength(5));
      }
    });

    test('seeds and raw samples are deterministic and immutable', () {
      final ProofSheetPlan first = buildStarterProofSheetPlan(
        recorder: _emptyRecorder,
      );
      final ProofSheetPlan second = buildStarterProofSheetPlan(
        recorder: _emptyRecorder,
      );
      final List<ProofStrokePlan> left = _allStrokes(first);
      final List<ProofStrokePlan> right = _allStrokes(second);

      expect(
        left.map((ProofStrokePlan stroke) => stroke.seed),
        orderedEquals(right.map((ProofStrokePlan stroke) => stroke.seed)),
      );
      expect(
        left.map((ProofStrokePlan stroke) => stroke.seed).toSet(),
        hasLength(left.length),
      );
      for (var index = 0; index < left.length; index += 1) {
        expect(left[index].samples, orderedEquals(right[index].samples));
      }
      expect(
        () => left.first.samples.add(left.first.samples.first),
        throwsUnsupportedError,
      );
    });

    test('real pipeline and brush engine emit deterministic stamps', () {
      final ProofSheetPlan first = buildStarterProofSheetPlan();
      final ProofSheetPlan second = buildStarterProofSheetPlan();
      final List<ProofStrokePlan> left = _allStrokes(first);
      final List<ProofStrokePlan> right = _allStrokes(second);

      expect(left, hasLength(right.length));
      for (var index = 0; index < left.length; index += 1) {
        expect(left[index].stamps, isNotEmpty, reason: 'stroke $index');
        expect(
          left[index].stamps.map(_stampSignature),
          orderedEquals(right[index].stamps.map(_stampSignature)),
          reason: 'stroke $index',
        );
      }
    });

    test('pressure and tilt recipes retain their defining channels', () {
      final ProofSheetPlan plan = buildStarterProofSheetPlan(
        recorder: _emptyRecorder,
      );

      for (final ProofBrushRowPlan row in plan.rows) {
        final List<StrokeSample> pressure = row
            .motifs[ProofMotifKind.pressureRamp.index]
            .strokes
            .single
            .samples;
        expect(pressure.first.pressure, lessThan(pressure.last.pressure));
        final List<ProofStrokePlan> fan =
            row.motifs[ProofMotifKind.tiltFan.index].strokes;
        expect(fan.first.samples.first.tilt.distance, 0);
        expect(
          fan.last.samples.first.tilt.distance,
          closeTo(math.pi / 2, 1e-12),
        );
      }
    });

    test('clear brush is white-on-gray visible and remains clear blend', () {
      final ProofSheetPlan plan = buildStarterProofSheetPlan();
      final ProofBrushRowPlan eraser = plan.rows.singleWhere(
        (ProofBrushRowPlan row) => row.brush.id == 'eraserpixel',
      );

      expect(eraser.brush.blend.kind, BrushBlend.clear);
      expect(
        eraser.motifs.every((ProofMotifPlan motif) => motif.showsClearBackdrop),
        isTrue,
      );
      expect(
        _rowStamps(
          eraser,
        ).every((ResolvedBrushStamp stamp) => stamp.blend == BrushBlend.clear),
        isTrue,
      );
      for (final ProofBrushRowPlan row in plan.rows.where(
        (ProofBrushRowPlan row) => row.brush.id != 'eraserpixel',
      )) {
        expect(
          row.motifs.any((ProofMotifPlan motif) => motif.showsClearBackdrop),
          isFalse,
          reason: row.brush.id,
        );
      }
    });

    test('injectable recorder receives every recipe synchronously', () {
      var calls = 0;
      final ProofSheetPlan plan = buildStarterProofSheetPlan(
        recorder:
            ({
              required BrushSpec brush,
              required List<StrokeSample> samples,
              required int seed,
            }) {
              calls += 1;
              expect(starterBrushesById[brush.id], same(brush));
              expect(samples, isNotEmpty);
              expect(seed, isNonNegative);
              return const <ResolvedBrushStamp>[];
            },
      );

      expect(calls, 6 * (1 + 1 + 5));
      expect(_allStrokes(plan), hasLength(calls));
    });
  });

  group('full brush proof plan', () {
    test('covers all sixteen drawing brushes and excludes the eraser', () {
      final ProofSheetPlan plan = buildFullProofSheetPlan(
        recorder: _emptyRecorder,
      );

      expect(plan.size, fullProofSheetSize);
      expect(
        plan.rows.map((ProofBrushRowPlan row) => row.brush.id),
        orderedEquals(drawingBrushes.map((BrushSpec brush) => brush.id)),
      );
      expect(plan.rows, hasLength(16));
      expect(
        plan.rows.map((row) => row.brush.id),
        isNot(contains('eraserpixel')),
      );
    });

    test(
      'packs two columns of eight rows entirely inside the golden canvas',
      () {
        final ProofSheetPlan plan = buildFullProofSheetPlan(
          recorder: _emptyRecorder,
        );

        expect(
          plan.rows.take(8).map((row) => row.bounds.left).toSet(),
          hasLength(1),
        );
        expect(
          plan.rows.skip(8).map((row) => row.bounds.left).toSet(),
          hasLength(1),
        );
        expect(
          plan.rows[8].bounds.left,
          greaterThan(plan.rows[0].bounds.right),
        );
        // Bounds must fit within the canvas; allow a sub-pixel float epsilon
        // so accumulated layout arithmetic that lands exactly on an edge
        // (e.g. 468.00000000000006 vs 468.0) is not a spurious overflow.
        const double edgeEpsilon = 1e-6;
        for (final ProofBrushRowPlan row in plan.rows) {
          expect(row.bounds.left, greaterThanOrEqualTo(0));
          expect(row.bounds.top, greaterThanOrEqualTo(0));
          expect(
            row.bounds.right,
            lessThanOrEqualTo(plan.size.width + edgeEpsilon),
          );
          expect(
            row.bounds.bottom,
            lessThanOrEqualTo(plan.size.height + edgeEpsilon),
          );
          for (final ProofMotifPlan motif in row.motifs) {
            expect(motif.bounds.left, greaterThanOrEqualTo(row.bounds.left));
            expect(motif.bounds.top, greaterThanOrEqualTo(row.bounds.top));
            expect(
              motif.bounds.right,
              lessThanOrEqualTo(row.bounds.right + edgeEpsilon),
            );
            expect(
              motif.bounds.bottom,
              lessThanOrEqualTo(row.bounds.bottom + edgeEpsilon),
            );
          }
        }
      },
    );

    test('records seven synchronous deterministic recipes per brush', () {
      var calls = 0;
      final ProofSheetPlan plan = buildFullProofSheetPlan(
        recorder:
            ({
              required BrushSpec brush,
              required List<StrokeSample> samples,
              required int seed,
            }) {
              calls += 1;
              expect(drawingBrushesById[brush.id], same(brush));
              expect(samples, isNotEmpty);
              return const <ResolvedBrushStamp>[];
            },
      );

      expect(calls, 16 * 7);
      expect(_allStrokes(plan), hasLength(calls));
    });

    test('shade brushes render against the fixed middle-gray proof field', () {
      final ProofSheetPlan plan = buildFullProofSheetPlan(
        recorder: _emptyRecorder,
      );
      final ProofBrushRowPlan tone = plan.rows.singleWhere(
        (ProofBrushRowPlan row) => row.brush.id == 'toneshader',
      );

      expect(tone.brush.blend.kind, BrushBlend.shade);
      expect(
        tone.motifs.map((ProofMotifPlan motif) => motif.shadeDirection),
        everyElement(tone.brush.blend.shadeDirection),
      );
    });

    test('rejects partial or duplicate full catalogs before painting', () {
      expect(
        () => buildFullProofSheetPlan(
          brushes: drawingBrushes.take(15).toList(growable: false),
          recorder: _emptyRecorder,
        ),
        throwsArgumentError,
      );
      expect(
        () => buildFullProofSheetPlan(
          brushes: <BrushSpec>[...drawingBrushes.take(15), finelinerBrush],
          recorder: _emptyRecorder,
        ),
        throwsArgumentError,
      );
    });
  });
}

List<ResolvedBrushStamp> _emptyRecorder({
  required BrushSpec brush,
  required List<StrokeSample> samples,
  required int seed,
}) => const <ResolvedBrushStamp>[];

List<ProofStrokePlan> _allStrokes(ProofSheetPlan plan) => <ProofStrokePlan>[
  for (final ProofBrushRowPlan row in plan.rows)
    for (final ProofMotifPlan motif in row.motifs) ...motif.strokes,
];

Iterable<ResolvedBrushStamp> _rowStamps(ProofBrushRowPlan row) sync* {
  for (final ProofMotifPlan motif in row.motifs) {
    for (final ProofStrokePlan stroke in motif.strokes) {
      yield* stroke.stamps;
    }
  }
}

Object _stampSignature(ResolvedBrushStamp stamp) => (
  stamp.center,
  stamp.diameterX,
  stamp.diameterY,
  stamp.angleRadians,
  stamp.colorArgb,
  stamp.flow,
  stamp.blend,
  stamp.grain?.patternId,
  stamp.grain?.scale,
  stamp.grain?.movement,
  stamp.grain?.depth,
  stamp.grain?.seed,
);
