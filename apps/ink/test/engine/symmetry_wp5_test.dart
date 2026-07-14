import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/engine/brush_tool_hooks.dart';
import 'package:paper_ink/src/engine/compositor.dart';
import 'package:paper_ink/src/engine/selection_mask.dart';
import 'package:paper_ink/src/engine/symmetry.dart';

void main() {
  group('symmetry point math', () {
    test('off mode emits only the source point', () {
      final configuration = SymmetryConfiguration.off();

      expect(configuration.mirrorPoint(SymmetryPoint(3, 4)), <SymmetryPoint>[
        SymmetryPoint(3, 4),
      ]);
    });

    test('vertical mode reflects x around its vertical axis', () {
      final configuration = SymmetryConfiguration(
        mode: SymmetryMode.vertical,
        axisX: 10,
        axisY: 0,
      );

      expect(configuration.mirrorPoint(SymmetryPoint(7, 2)), <SymmetryPoint>[
        SymmetryPoint(7, 2),
        SymmetryPoint(13, 2),
      ]);
    });

    test('horizontal mode reflects y around its horizontal axis', () {
      final configuration = SymmetryConfiguration(
        mode: SymmetryMode.horizontal,
        axisX: 0,
        axisY: 5,
      );

      expect(configuration.mirrorPoint(SymmetryPoint(2, 3)), <SymmetryPoint>[
        SymmetryPoint(2, 3),
        SymmetryPoint(2, 7),
      ]);
    });

    test('quad mode emits journal-stable quadrant order', () {
      final configuration = SymmetryConfiguration(
        mode: SymmetryMode.quad,
        axisX: 10,
        axisY: 20,
      );

      expect(configuration.mirrorPoint(SymmetryPoint(8, 17)), <SymmetryPoint>[
        SymmetryPoint(8, 17),
        SymmetryPoint(12, 17),
        SymmetryPoint(8, 23),
        SymmetryPoint(12, 23),
      ]);
    });

    test('points on one axis deduplicate coincident copies', () {
      final configuration = SymmetryConfiguration(
        mode: SymmetryMode.quad,
        axisX: 10,
        axisY: 20,
      );

      expect(configuration.mirrorPoint(SymmetryPoint(10, 17)), <SymmetryPoint>[
        SymmetryPoint(10, 17),
        SymmetryPoint(10, 23),
      ]);
    });

    test('point at the axes intersection emits exactly one copy', () {
      final configuration = SymmetryConfiguration(
        mode: SymmetryMode.quad,
        axisX: 10,
        axisY: 20,
      );

      expect(configuration.mirrorPoint(SymmetryPoint(10, 20)), hasLength(1));
    });

    test('reflection transforms direction vectors and angles', () {
      final reflection = SymmetryConfiguration(
        mode: SymmetryMode.vertical,
        axisX: 0,
        axisY: 0,
      ).reflections.last;

      expect(
        reflection.applyToVector(SymmetryPoint(2, 3)),
        SymmetryPoint(-2, 3),
      );
      expect(
        reflection.applyToAngle(math.pi / 6),
        closeTo(5 * math.pi / 6, 1e-12),
      );
    });

    test('invalid axes and epsilon are rejected', () {
      expect(
        () => SymmetryConfiguration(
          mode: SymmetryMode.vertical,
          axisX: double.nan,
          axisY: 0,
        ),
        throwsArgumentError,
      );
      final configuration = SymmetryConfiguration.off();
      expect(
        () => configuration.mirrorPoint(SymmetryPoint(0, 0), epsilon: -1),
        throwsArgumentError,
      );
    });
  });

  group('generic symmetry stream hook', () {
    test('preserves original identity and transforms each mirrored copy', () {
      final source = _TestStamp(2, 3, 'source');
      final hook = SymmetryMirrorHook<_TestStamp>(
        configuration: SymmetryConfiguration(
          mode: SymmetryMode.quad,
          axisX: 5,
          axisY: 7,
        ),
        xOf: (value) => value.x,
        yOf: (value) => value.y,
        reflectedCopy: (value, reflection) {
          final point = reflection.applyToPoint(
            SymmetryPoint(value.x, value.y),
          );
          return _TestStamp(point.x, point.y, 'copy');
        },
      );
      final expanded = hook.expand(source);

      expect(identical(expanded.first, source), isTrue);
      expect(
        <(double, double)>[for (final value in expanded) (value.x, value.y)],
        <(double, double)>[(2, 3), (8, 3), (2, 11), (8, 11)],
      );
    });

    test('expandAll keeps copies grouped by source stamp', () {
      final hook = SymmetryMirrorHook<_TestStamp>(
        configuration: SymmetryConfiguration(
          mode: SymmetryMode.vertical,
          axisX: 0,
          axisY: 0,
        ),
        xOf: (value) => value.x,
        yOf: (value) => value.y,
        reflectedCopy: (value, reflection) {
          final point = reflection.applyToPoint(
            SymmetryPoint(value.x, value.y),
          );
          return _TestStamp(point.x, point.y, value.label);
        },
      );

      expect(
        hook
            .expandAll(<_TestStamp>[
              _TestStamp(1, 0, 'a'),
              _TestStamp(2, 0, 'b'),
            ])
            .map((value) => '${value.label}:${value.x}'),
        <String>['a:1.0', 'a:-1.0', 'b:2.0', 'b:-2.0'],
      );
    });
  });

  group('brush-engine symmetry and mask seams', () {
    test('brush target mirrors complete stamps and unions damage', () {
      final recording = RecordingBrushStampTarget();
      final target = SymmetryBrushStampTarget(
        target: recording,
        configuration: SymmetryConfiguration(
          mode: SymmetryMode.quad,
          axisX: 10,
          axisY: 20,
        ),
      );
      final source = _resolvedStamp(const Offset(8, 17));
      final damage = target.stamp(source);

      expect(recording.stamps, hasLength(4));
      expect(recording.stamps.first, same(source));
      expect(recording.stamps.map((stamp) => stamp.center), const <Offset>[
        Offset(8, 17),
        Offset(12, 17),
        Offset(8, 23),
        Offset(12, 23),
      ]);
      expect(
        damage,
        recording.stamps
            .map((stamp) => stamp.bounds)
            .reduce((a, b) => a.expandToInclude(b)),
      );
    });

    test('mirrored brush copy preserves resolved non-geometric fields', () {
      final recording = RecordingBrushStampTarget();
      SymmetryBrushStampTarget(
        target: recording,
        configuration: SymmetryConfiguration(
          mode: SymmetryMode.vertical,
          axisX: 10,
          axisY: 0,
        ),
      ).stamp(_resolvedStamp(const Offset(8, 17)));
      final copy = recording.stamps.last;

      expect(copy.diameterX, 6);
      expect(copy.diameterY, 3);
      expect(copy.colorArgb, 0x80402010);
      expect(copy.flow, 0.75);
      expect(copy.blend, BrushBlend.multiply);
      expect(copy.nibKind, NibKind.chisel);
      expect(copy.textureMaskId, 'texture');
      expect(copy.maxOverlapSteps, 2);
      expect(copy.minimumLumaLevel, 12);
      expect(copy.grain!.patternId, 'hatch45');
      expect(copy.grain!.seed, 99);
      expect(copy.angleRadians, closeTo(5 * math.pi / 6, 1e-12));
      expect(copy.grain!.angleRadians, closeTo(3 * math.pi / 4, 1e-12));
    });

    test('symmetry target deduplicates stamps centered on an axis', () {
      final recording = RecordingBrushStampTarget();
      SymmetryBrushStampTarget(
        target: recording,
        configuration: SymmetryConfiguration(
          mode: SymmetryMode.quad,
          axisX: 10,
          axisY: 20,
        ),
      ).stamp(_resolvedStamp(const Offset(10, 17)));

      expect(recording.stamps, hasLength(2));
    });

    test('stroke buffer target clips grain-ready coverage to selection', () {
      final buffer = StrokeBuffer(documentSize: const Size(4, 2));
      final selection = SelectionMask.fromBools(
        width: 4,
        height: 2,
        selected: const <bool>[
          true,
          true,
          false,
          false,
          true,
          true,
          false,
          false,
        ],
      );
      StrokeBufferBrushTarget(
        buffer: buffer,
        selection: selection,
      ).stamp(_resolvedStamp(const Offset(2, 1), grain: false));
      final snapshot = buffer.snapshot();

      expect(_alphaAt(snapshot, 0, 0), greaterThan(0));
      expect(_alphaAt(snapshot, 1, 1), greaterThan(0));
      expect(_alphaAt(snapshot, 2, 1), 0);
      expect(_alphaAt(snapshot, 3, 0), 0);
    });

    test('partial selection coverage scales stamp alpha', () {
      final buffer = StrokeBuffer(documentSize: const Size(1, 1));
      final selection = SelectionMask(
        width: 1,
        height: 1,
        coverage: Uint8List.fromList(<int>[128]),
      );
      StrokeBufferBrushTarget(buffer: buffer, selection: selection).stamp(
        ResolvedBrushStamp(
          center: const Offset(0.5, 0.5),
          diameterX: 2,
          diameterY: 2,
          angleRadians: 0,
          colorArgb: 0xff000000,
          flow: 1,
          blend: BrushBlend.opaque,
          grain: null,
        ),
      );

      expect(_alphaAt(buffer.snapshot(), 0, 0), 128);
    });
  });
}

final class _TestStamp {
  _TestStamp(this.x, this.y, this.label);

  final double x;
  final double y;
  final String label;
}

ResolvedBrushStamp _resolvedStamp(Offset center, {bool grain = true}) =>
    ResolvedBrushStamp(
      center: center,
      diameterX: 6,
      diameterY: 3,
      angleRadians: math.pi / 6,
      colorArgb: 0x80402010,
      flow: 0.75,
      blend: BrushBlend.multiply,
      grain: grain
          ? const ResolvedBrushGrain(
              patternId: 'hatch45',
              scale: 2,
              movement: GrainMovement.moving,
              depth: 0.5,
              seed: 99,
              densityLevel: 3,
              angleRadians: math.pi / 4,
            )
          : null,
      nibKind: NibKind.chisel,
      textureMaskId: 'texture',
      maxOverlapSteps: 2,
      minimumLumaLevel: 12,
    );

int _alphaAt(StrokeBufferSnapshot snapshot, int documentX, int documentY) {
  final localX = documentX - snapshot.originX;
  final localY = documentY - snapshot.originY;
  return snapshot.pixels[(localY * snapshot.width + localX) * 4 + 3];
}
