import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';

void main() {
  group('deterministic brush math', () {
    test('repository PRNG repeats a seed and separates different seeds', () {
      final first = BrushRandom(0x123456789abcdef0);
      final again = BrushRandom(0x123456789abcdef0);
      final other = BrushRandom(0x123456789abcdef1);

      final a = List<int>.generate(12, (_) => first.nextUint32());
      final b = List<int>.generate(12, (_) => again.nextUint32());
      final c = List<int>.generate(12, (_) => other.nextUint32());

      expect(a, b);
      expect(c, isNot(a));
      expect(a, everyElement(inInclusiveRange(0, 0xffffffff)));
    });

    test('zero seed is a non-degenerate deterministic stream', () {
      final random = BrushRandom(0);
      final values = List<int>.generate(8, (_) => random.nextUint32());

      expect(values.toSet().length, greaterThan(1));
      expect(values, isNot(contains(0)));
    });

    test('velocity normalization is bounded and scale aware', () {
      expect(normalizeBrushVelocity(0, size: 4), 0);
      expect(normalizeBrushVelocity(240, size: 4), closeTo(0.5, 1e-12));
      expect(
        normalizeBrushVelocity(240, size: 8),
        lessThan(normalizeBrushVelocity(240, size: 4)),
      );
    });

    test('ballpoint skip predicate is rare and speed dependent', () {
      expect(
        isBallpointSkipFleck(normalizedVelocity: 0, randomUnit: 0),
        isFalse,
      );
      expect(
        isBallpointSkipFleck(normalizedVelocity: 1, randomUnit: 0.029),
        isTrue,
      );
      expect(
        isBallpointSkipFleck(normalizedVelocity: 1, randomUnit: 0.031),
        isFalse,
      );
    });

    test('quantization snaps flow to the requested lattice', () {
      expect(quantizeBrushFlow(0.37, 0), 0.37);
      expect(quantizeBrushFlow(0.37, 4), 0.25);
      expect(quantizeBrushFlow(0.64, 4), 0.75);
      expect(quantizeBrushFlow(2, 4), 1);
    });

    test('paper tooth is varied and exactly 64 by 64 tileable', () {
      final sample = proceduralGrainValue('paperTooth', 7.25, 19.75);

      expect(proceduralGrainValue('paperTooth', 71.25, 83.75), sample);
      expect(proceduralGrainValue('paperTooth', 8.25, 19.75), isNot(sample));
      expect(sample, inInclusiveRange(0, 1));
    });
  });

  group('stamp along path', () {
    test('fineliner is pressure invariant', () {
      final low = _renderDot(finelinerBrush, pressure: 0);
      final high = _renderDot(finelinerBrush, pressure: 1);

      expect(low.diameterX, high.diameterX);
      expect(low.diameterY, high.diameterY);
      expect(low.flow, high.flow);
      expect(low.diameterX, finelinerBrush.sizeDefault);
    });

    test('technical pen has a full-size zero-taper endpoint', () {
      final target = RecordingBrushStampTarget();
      final engine = BrushEngine(
        spec: technicalBrush,
        target: target,
        seed: 1,
        colorArgb: 0xff000000,
      );

      engine.stampAlong(<BrushPoint>[_point(0, micros: 0)]);
      engine.stampAlong(<BrushPoint>[_point(5, micros: 5000)]);
      engine.finalize();

      expect(target.stamps.last.diameterX, technicalBrush.sizeDefault);
      expect(target.stamps.last.center.dx, closeTo(5, 1e-9));
    });

    test('ballpoint pressure curve widens from 0.75 to 1.0 scale', () {
      final low = _renderDot(ballpointBrush, pressure: 0);
      final high = _renderDot(ballpointBrush, pressure: 1);

      expect(low.diameterX, closeTo(2.25, 1e-12));
      expect(high.diameterX, closeTo(3, 1e-12));
      expect(high.diameterX, greaterThan(low.diameterX));
    });

    test('fast ballpoint is eight-percent-class thinner and lighter', () {
      final slow = _renderLine(
        ballpointBrush,
        endMicros: Duration.microsecondsPerSecond,
      );
      final fast = _renderLine(ballpointBrush, endMicros: 1000);
      final slowMoving = slow.where((stamp) => stamp.center.dx > 0);
      final fastMoving = fast.where((stamp) => stamp.center.dx > 0);

      expect(fastMoving, isNotEmpty);
      expect(
        fastMoving.map((stamp) => stamp.diameterX).reduce(math.max),
        lessThan(slowMoving.map((stamp) => stamp.diameterX).reduce(math.max)),
      );
      expect(
        fastMoving.map((stamp) => stamp.flow).reduce(math.max),
        lessThan(slowMoving.map((stamp) => stamp.flow).reduce(math.max)),
      );
    });

    test('ballpoint flecks repeat by seed and omit rare impressions', () {
      final first = _renderLine(
        ballpointBrush,
        seed: 407,
        distance: 600,
        endMicros: 1000,
      );
      final again = _renderLine(
        ballpointBrush,
        seed: 407,
        distance: 600,
        endMicros: 1000,
      );
      final other = _renderLine(
        ballpointBrush,
        seed: 408,
        distance: 600,
        endMicros: 1000,
      );

      expect(
        first.map((stamp) => stamp.center),
        again.map((stamp) => stamp.center),
      );
      expect(
        first.map((stamp) => stamp.center),
        isNot(other.map((stamp) => stamp.center)),
      );
      expect(first.length, lessThan(1001));
      expect(first.length, greaterThan(900));
    });

    test('brush pen pressure controls both diameter and flow', () {
      final low = _renderDot(brushpenBrush, pressure: 0);
      final high = _renderDot(brushpenBrush, pressure: 1);

      expect(low.diameterX, closeTo(2.5, 1e-12));
      expect(high.diameterX, closeTo(10, 1e-12));
      expect(low.flow, closeTo(0.35, 1e-12));
      expect(high.flow, 1);
    });

    test('brush pen finalization emits a tapered tail', () {
      final stamps = _renderLine(brushpenBrush, distance: 40, endMicros: 40000);
      final body = stamps.firstWhere(
        (stamp) => stamp.center.dx > 20 && stamp.center.dx < 25,
      );
      final tail = stamps.last;

      expect(tail.center.dx, closeTo(40, 1e-7));
      expect(tail.diameterX, lessThan(body.diameterX * 0.2));
      expect(tail.flow, lessThan(body.flow * 0.2));
    });

    test('a brush pen tap remains visible despite head and tail taper', () {
      final stamp = _renderDot(brushpenBrush, pressure: 1);

      expect(stamp.diameterX, brushpenBrush.sizeDefault);
      expect(stamp.flow, 1);
    });

    test('spacing residual is invariant to incremental chunk boundaries', () {
      final allAtOnce = RecordingBrushStampTarget();
      final incremental = RecordingBrushStampTarget();
      final points = <BrushPoint>[
        _point(0, micros: 0),
        _point(2.7, micros: 2700),
        _point(8, micros: 8000),
      ];
      final firstEngine = BrushEngine(
        spec: finelinerBrush,
        target: allAtOnce,
        seed: 99,
        colorArgb: 0xff010203,
      );
      final secondEngine = BrushEngine(
        spec: finelinerBrush,
        target: incremental,
        seed: 99,
        colorArgb: 0xff010203,
      );

      firstEngine.stampAlong(points);
      firstEngine.finalize();
      for (final point in points) {
        secondEngine.stampAlong(<BrushPoint>[point]);
      }
      secondEngine.finalize();

      expect(
        incremental.stamps.map((stamp) => stamp.center),
        allAtOnce.stamps.map((stamp) => stamp.center),
      );
      expect(secondEngine.spacingResidual, firstEngine.spacingResidual);
    });

    test('configured spacing places regular fineliner centers', () {
      final stamps = _renderLine(finelinerBrush, distance: 3, endMicros: 3000);

      expect(stamps, hasLength(6));
      final expected = <double>[0, 0.6, 1.2, 1.8, 2.4, 3.0];
      for (var index = 0; index < expected.length; index += 1) {
        expect(stamps[index].center.dx, closeTo(expected[index], 1e-9));
      }
    });

    test('seeded jitter repeats exactly and changes with the seed', () {
      final spec = _customSpec(id: 'jitter', jitter: 0.4);
      final first = _renderLine(spec, seed: 71);
      final again = _renderLine(spec, seed: 71);
      final other = _renderLine(spec, seed: 72);

      expect(
        first.map((stamp) => stamp.center),
        again.map((stamp) => stamp.center),
      );
      expect(
        first.map((stamp) => stamp.center),
        isNot(other.map((stamp) => stamp.center)),
      );
      expect(first.skip(1).any((stamp) => stamp.center.dy != 0), isTrue);
    });

    test('ellipse nib resolves its axes and angle before target dispatch', () {
      final spec = _customSpec(
        id: 'ellipse',
        nib: const NibShape.ellipse(angleDegrees: 30, ratio: 0.5),
      );
      final stamp = _renderDot(spec, pressure: 1);

      expect(stamp.diameterX, 10);
      expect(stamp.diameterY, 5);
      expect(stamp.angleRadians, closeTo(math.pi / 6, 1e-12));
    });

    test('HB pencil resolves fixed half-depth tooth and four-level flow', () {
      final stamp = _renderDot(pencilHbBrush, pressure: 0.5);
      final grain = stamp.grain!;

      expect(grain.patternId, 'paperTooth');
      expect(grain.movement, GrainMovement.fixed);
      expect(grain.depth, 0.5);
      expect(stamp.flow * 4, closeTo((stamp.flow * 4).round(), 1e-12));
      expect(
        grain.coverageAt(const Offset(7, 9), stampCenter: const Offset(0, 0)),
        grain.coverageAt(
          const Offset(7, 9),
          stampCenter: const Offset(300, 400),
        ),
      );
    });

    test('pixel eraser dispatches clear-blend pressure-sized stamps', () {
      final low = _renderDot(eraserPixelBrush, pressure: 0);
      final high = _renderDot(eraserPixelBrush, pressure: 1);

      expect(low.blend, BrushBlend.clear);
      expect(low.diameterX, closeTo(9.6, 1e-12));
      expect(high.diameterX, 16);
    });

    test('finalized engine rejects further stamps and finalization', () {
      final engine = BrushEngine(
        spec: finelinerBrush,
        target: RecordingBrushStampTarget(),
        seed: 1,
        colorArgb: 0xff000000,
      );
      engine.stampAlong(<BrushPoint>[_point(0, micros: 0)]);
      engine.finalize();

      expect(() => engine.stampAlong(<BrushPoint>[]), throwsStateError);
      expect(engine.finalize, throwsStateError);
    });
  });

  group('clear COW composite', () {
    test('partial clear uses premultiplied destination-out math', () {
      const key = TileKey(0, 0);
      final before = _pixelTile(<int>[100, 50, 20, 200]);
      final store = TileStore()..publish('L', key, before);
      final mask = Uint8List.fromList(<int>[0, 0, 0, 128]);

      final result = compositeClearMask(
        tiles: store,
        layerId: 'L',
        candidateKeys: const <TileKey>[key],
        maskPixels: mask,
        maskOriginX: 0,
        maskOriginY: 0,
        maskWidth: 1,
        maskHeight: 1,
      );

      expect(identical(result.beforeTiles[key], before), isTrue);
      expect(result.afterTiles[key]!.pixels.sublist(0, 4), <int>[
        50,
        25,
        10,
        100,
      ]);
      expect(identical(store.tile('L', key), before), isTrue);
    });

    test('opaque clear returns null for a newly transparent sparse tile', () {
      const key = TileKey(0, 0);
      final before = _pixelTile(<int>[12, 34, 56, 255]);
      final store = TileStore()..publish('L', key, before);

      final result = compositeClearMask(
        tiles: store,
        layerId: 'L',
        candidateKeys: const <TileKey>[key],
        maskPixels: Uint8List.fromList(<int>[255, 255, 255, 255]),
        maskOriginX: 0,
        maskOriginY: 0,
        maskWidth: 1,
        maskHeight: 1,
      );

      expect(result.afterTiles, <TileKey, Tile?>{key: null});
      expect(result.beforeTiles[key], same(before));
    });

    test('transparent and absent candidates remain publish-neutral', () {
      const occupied = TileKey(0, 0);
      const absent = TileKey(1, 0);
      final before = _pixelTile(<int>[10, 20, 30, 255]);
      final store = TileStore()..publish('L', occupied, before);

      final result = compositeClearMask(
        tiles: store,
        layerId: 'L',
        candidateKeys: const <TileKey>[occupied, absent, occupied],
        maskPixels: Uint8List(4),
        maskOriginX: 0,
        maskOriginY: 0,
        maskWidth: 1,
        maskHeight: 1,
      );

      expect(result.isEmpty, isTrue);
      expect(result.beforeTiles, isEmpty);
      expect(store.tile('L', occupied), same(before));
    });
  });
}

BrushPoint _point(
  double x, {
  required int micros,
  double pressure = 1,
  double tilt = 0,
}) => BrushPoint(
  point: Offset(x, 0),
  pressure: pressure,
  tilt: tilt,
  timestamp: Duration(microseconds: micros),
);

ResolvedBrushStamp _renderDot(BrushSpec spec, {required double pressure}) {
  final target = RecordingBrushStampTarget();
  final engine = BrushEngine(
    spec: spec,
    target: target,
    seed: 17,
    colorArgb: 0xff123456,
  );
  engine.stampAlong(<BrushPoint>[_point(0, micros: 0, pressure: pressure)]);
  engine.finalize();
  return target.stamps.single;
}

List<ResolvedBrushStamp> _renderLine(
  BrushSpec spec, {
  int seed = 17,
  double distance = 30,
  int endMicros = 30000,
}) {
  final target = RecordingBrushStampTarget();
  final engine = BrushEngine(
    spec: spec,
    target: target,
    seed: seed,
    colorArgb: 0xff123456,
  );
  engine.stampAlong(<BrushPoint>[
    _point(0, micros: 0),
    _point(distance, micros: endMicros),
  ]);
  engine.finalize();
  return target.stamps;
}

BrushSpec _customSpec({
  required String id,
  double jitter = 0,
  NibShape nib = const NibShape.disc(),
}) => BrushSpec(
  id: id,
  name: id,
  kind: BrushClass.stamp,
  sizeMin: 1,
  sizeMax: 20,
  sizeDefault: 10,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.2,
  jitter: jitter,
  nib: nib,
  grain: null,
  taper: TaperSpec.none,
  blend: const BlendBehavior.opaque(),
  smoothing: 0,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: 0.5,
  velocityThins: false,
  quantizeLevels: 0,
);

Tile _pixelTile(List<int> rgba) {
  final pixels = Uint8List(Tile.byteLength)..setRange(0, 4, rgba);
  return Tile.takeOwnership(pixels);
}
