import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/input/pen_router.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_pen/pluto_pen_testing.dart';

void main() {
  group('PenRouter metadata', () {
    test('requires a finite positive device pixel ratio', () {
      const FakePenEvents events = FakePenEvents(Stream<PenEvent>.empty());

      expect(
        () => PenRouter(penEvents: events, devicePixelRatio: 0),
        throwsArgumentError,
      );
      expect(
        () => PenRouter(penEvents: events, devicePixelRatio: double.nan),
        throwsArgumentError,
      );
    });

    test('start is idempotent and initial metadata is explicit', () async {
      final StreamController<PenEvent> source =
          StreamController<PenEvent>.broadcast(sync: true);
      final PenRouter router = PenRouter(
        penEvents: FakePenEvents(source.stream),
        devicePixelRatio: 2,
      );

      expect(router.latestPenMeta.hasChannelSample, isFalse);
      router.start();
      router.start();

      expect(router.isStarted, isTrue);
      await router.dispose();
      await source.close();
    });

    test('physical channel position is divided by DPR', () async {
      final StreamController<PenEvent> source =
          StreamController<PenEvent>.broadcast(sync: true);
      final PenRouter router = PenRouter(
        penEvents: FakePenEvents(source.stream),
        devicePixelRatio: 1.65,
      )..start();

      source.add(
        PenHoverEvent(sample: _sample(position: const Offset(165, 330))),
      );

      expect(router.latestPenMeta.logicalPosition, const Offset(100, 200));
      expect(router.latestPenMeta.phase, PenMetadataPhase.hover);
      expect(router.latestPenMeta.isInProximity, isTrue);
      expect(router.latestPenMeta.isInContact, isFalse);
      await router.dispose();
      await source.close();
    });

    test(
      'tool tilt buttons and distance preserve latest channel values',
      () async {
        final StreamController<PenEvent> source =
            StreamController<PenEvent>.broadcast(sync: true);
        final PenRouter router = PenRouter(
          penEvents: FakePenEvents(source.stream),
          devicePixelRatio: 2,
        )..start();

        source.add(
          PenDownEvent(
            sample: _sample(
              tool: PenTool.eraser,
              tilt: const Offset(0.2, -0.3),
              rawTilt: const Offset(1200, -1800),
              buttons: const PenButtons(3),
              distance: 0.25,
              rawDistance: 123,
            ),
          ),
        );

        final PenMetadata meta = router.latestPenMeta;
        expect(meta.tool, PenTool.eraser);
        expect(meta.tilt, const Offset(0.2, -0.3));
        expect(meta.rawTilt, const Offset(1200, -1800));
        expect(meta.buttons.bits, 3);
        expect(meta.hoverDistance, 0.25);
        expect(meta.rawDistance, 123);
        expect(meta.isInContact, isTrue);
        await router.dispose();
        await source.close();
      },
    );

    test('all channel lifecycle events update proximity and contact', () async {
      final StreamController<PenEvent> source =
          StreamController<PenEvent>.broadcast(sync: true);
      final PenRouter router = PenRouter(
        penEvents: FakePenEvents(source.stream),
        devicePixelRatio: 1,
      )..start();
      final PenSample sample = _sample();
      final List<(PenEvent, PenMetadataPhase, bool, bool)> cases =
          <(PenEvent, PenMetadataPhase, bool, bool)>[
            (
              PenEnteredProximityEvent(sample: sample),
              PenMetadataPhase.enteredProximity,
              true,
              false,
            ),
            (
              PenHoverEvent(sample: sample),
              PenMetadataPhase.hover,
              true,
              false,
            ),
            (PenDownEvent(sample: sample), PenMetadataPhase.down, true, true),
            (PenMoveEvent(sample: sample), PenMetadataPhase.move, true, true),
            (PenUpEvent(sample: sample), PenMetadataPhase.up, true, false),
            (
              PenLeftProximityEvent(sample: sample),
              PenMetadataPhase.leftProximity,
              false,
              false,
            ),
          ];

      for (final (
            PenEvent event,
            PenMetadataPhase phase,
            bool proximity,
            bool contact,
          )
          in cases) {
        source.add(event);
        expect(router.latestPenMeta.phase, phase);
        expect(router.latestPenMeta.isInProximity, proximity);
        expect(router.latestPenMeta.isInContact, contact);
      }
      await router.dispose();
      await source.close();
    });

    test('button changes retain the previous contact state', () async {
      final StreamController<PenEvent> source =
          StreamController<PenEvent>.broadcast(sync: true);
      final PenRouter router = PenRouter(
        penEvents: FakePenEvents(source.stream),
        devicePixelRatio: 1,
      )..start();
      final PenSample down = _sample();
      final PenSample buttons = _sample(buttons: const PenButtons(1));
      source.add(PenDownEvent(sample: down));

      source.add(
        PenButtonsChangedEvent(sample: buttons, previous: PenButtons.none),
      );

      expect(router.latestPenMeta.phase, PenMetadataPhase.buttonsChanged);
      expect(router.latestPenMeta.isInContact, isTrue);
      expect(router.latestPenMeta.buttons.hasPrimary, isTrue);
      await router.dispose();
      await source.close();
    });

    test(
      'metadata stream errors are retained without discarding state',
      () async {
        final StreamController<PenEvent> source =
            StreamController<PenEvent>.broadcast(sync: true);
        final PenRouter router = PenRouter(
          penEvents: FakePenEvents(source.stream),
          devicePixelRatio: 1,
        )..start();
        source.add(PenHoverEvent(sample: _sample()));
        final StateError error = StateError('offline');

        source.addError(error, StackTrace.current);

        expect(router.lastMetadataError, same(error));
        expect(router.latestPenMeta.phase, PenMetadataPhase.hover);
        await router.dispose();
        await source.close();
      },
    );
  });

  group('PenRouter Flutter geometry', () {
    test('stamps latest metadata onto normalized stylus geometry', () async {
      final StreamController<PenEvent> source =
          StreamController<PenEvent>.broadcast(sync: true);
      final PenRouter router = PenRouter(
        penEvents: FakePenEvents(source.stream),
        devicePixelRatio: 2,
      )..start();
      source.add(
        PenHoverEvent(
          sample: _sample(tool: PenTool.eraser, position: const Offset(40, 60)),
        ),
      );

      final PenInputSample? routed = router.handlePointerEvent(
        const PointerMoveEvent(
          timeStamp: Duration(milliseconds: 9),
          pointer: 7,
          kind: PointerDeviceKind.stylus,
          device: 500,
          position: Offset(3.5, 4.5),
          pressure: 3,
          pressureMin: 1,
          pressureMax: 5,
        ),
      );

      expect(routed, isNotNull);
      expect(routed!.phase, PenInputPhase.move);
      expect(routed.pointer, 7);
      expect(routed.device, 500);
      expect(routed.position, const Offset(3.5, 4.5));
      expect(routed.normalizedPressure, 0.5);
      expect(routed.metadata.tool, PenTool.eraser);
      expect(routed.metadata.logicalPosition, const Offset(20, 30));
      await router.dispose();
      await source.close();
    });

    test('each geometry sample keeps its metadata snapshot', () async {
      final StreamController<PenEvent> source =
          StreamController<PenEvent>.broadcast(sync: true);
      final PenRouter router = PenRouter(
        penEvents: FakePenEvents(source.stream),
        devicePixelRatio: 1,
      )..start();
      source.add(PenHoverEvent(sample: _sample(tool: PenTool.pen)));
      final PenInputSample first = router.handlePointerEvent(
        const PointerDownEvent(
          pointer: 1,
          kind: PointerDeviceKind.stylus,
          device: 500,
        ),
      )!;

      source.add(PenHoverEvent(sample: _sample(tool: PenTool.eraser)));
      final PenInputSample second = router.handlePointerEvent(
        const PointerUpEvent(
          pointer: 1,
          kind: PointerDeviceKind.stylus,
          device: 500,
        ),
      )!;

      expect(first.metadata.tool, PenTool.pen);
      expect(second.metadata.tool, PenTool.eraser);
      await router.dispose();
      await source.close();
    });

    test('inverted stylus routes while touch and mouse are ignored', () async {
      final PenRouter router = PenRouter(
        penEvents: const FakePenEvents(Stream<PenEvent>.empty()),
        devicePixelRatio: 1,
      );

      final PenInputSample inverted = router.handlePointerEvent(
        const PointerHoverEvent(kind: PointerDeviceKind.invertedStylus),
      )!;

      expect(inverted.metadata.tool, PenTool.eraser);
      expect(inverted.metadata.hasChannelSample, isFalse);
      expect(
        router.handlePointerEvent(
          const PointerDownEvent(kind: PointerDeviceKind.touch),
        ),
        isNull,
      );
      expect(
        router.handlePointerEvent(
          const PointerDownEvent(kind: PointerDeviceKind.mouse),
        ),
        isNull,
      );
      await router.dispose();
    });

    test('channel tool remains authoritative for inverted geometry', () async {
      final StreamController<PenEvent> source =
          StreamController<PenEvent>.broadcast(sync: true);
      final PenRouter router = PenRouter(
        penEvents: FakePenEvents(source.stream),
        devicePixelRatio: 1,
      )..start();
      source.add(PenHoverEvent(sample: _sample(tool: PenTool.pen)));

      final PenInputSample routed = router.handlePointerEvent(
        const PointerHoverEvent(kind: PointerDeviceKind.invertedStylus),
      )!;

      expect(routed.metadata.tool, PenTool.pen);
      expect(routed.metadata.hasChannelSample, isTrue);
      await router.dispose();
      await source.close();
    });

    test(
      'unusable Flutter pressure range produces null normalization',
      () async {
        final PenRouter router = PenRouter(
          penEvents: const FakePenEvents(Stream<PenEvent>.empty()),
          devicePixelRatio: 1,
        );

        final PenInputSample? sample = router.handlePointerEvent(
          const PointerDownEvent(
            kind: PointerDeviceKind.stylus,
            pressure: 1,
            pressureMin: 1,
            pressureMax: 1,
          ),
        );

        expect(sample!.normalizedPressure, isNull);
        await router.dispose();
      },
    );

    test('routed samples are also emitted on the output stream', () async {
      final PenRouter router = PenRouter(
        penEvents: const FakePenEvents(Stream<PenEvent>.empty()),
        devicePixelRatio: 1,
      );
      final Future<PenInputSample> emitted = router.inputSamples.first;

      final PenInputSample? returned = router.handlePointerEvent(
        const PointerDownEvent(
          pointer: 12,
          kind: PointerDeviceKind.stylus,
          device: 500,
        ),
      );

      expect(await emitted, same(returned));
      await router.dispose();
    });
  });
}

PenSample _sample({
  Duration timestamp = const Duration(milliseconds: 3),
  Offset position = const Offset(10, 20),
  PenTool tool = PenTool.pen,
  Offset tilt = Offset.zero,
  Offset rawTilt = Offset.zero,
  PenButtons buttons = PenButtons.none,
  double distance = 0,
  int rawDistance = 0,
}) {
  return PenSample(
    timestamp: timestamp,
    position: position,
    rawPosition: const Offset(100, 200),
    pressure: 0.5,
    rawPressure: 2048,
    tilt: tilt,
    rawTilt: rawTilt,
    distance: distance,
    rawDistance: rawDistance,
    tool: tool,
    buttons: buttons,
  );
}
