import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_core/testing.dart';
import 'package:pluto_touch/pluto_touch.dart';
import 'package:pluto_touch/pluto_touch_testing.dart';

void main() {
  test('fake touch events emit point views', () async {
    const TouchPoint point = TouchPoint(
      timestamp: Duration(milliseconds: 5),
      id: 1,
      position: Offset(30, 40),
      phase: TouchPhase.down,
    );

    final TouchPoint emitted = await FakeTouchEvents.single(
      point,
    ).points.single;

    expect(emitted.id, 1);
    expect(emitted.phase, TouchPhase.down);
  });

  test('touch facade decodes config and capabilities', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(
        plutoTouchChannel,
        touchPalmRejectionMethod,
        (Object? arguments) => <String, Object?>{
          'isEnabled': true,
          'touchMajorThreshold': 60,
          'penProximityLingerMs': 300,
          'folioReopenHoldoffMs': 200,
        },
      )
      ..onInvoke(
        plutoTouchChannel,
        touchSetPalmRejectionMethod,
        (Object? arguments) => null,
      )
      ..onInvoke(
        plutoTouchChannel,
        touchCapabilitiesMethod,
        (Object? arguments) => <String, Object?>{
          'slotCount': 10,
          'rawXMax': 1248,
          'rawYMax': 2208,
          'rawTouchMajorMax': 255,
        },
      );

    final PlutoTouch touch = PlutoTouch.withTransport(transport);

    expect(
      (await touch.palmRejection()).penProximityLinger,
      const Duration(milliseconds: 300),
    );
    await touch.setPalmRejection(const PalmRejectionConfig());
    expect((await touch.capabilities()).slotCount, 10);
  });

  test('tap recognizer emits replayed tap', () async {
    final TouchContact contact = TouchContact(
      slot: 0,
      trackingId: 7,
      position: const Offset(10, 10),
      rawPosition: const Offset(10, 10),
      touchMajor: 0.1,
      pressure: 0.2,
      toolType: TouchToolType.finger,
    );
    final Stream<TouchEvent> events =
        Stream<TouchEvent>.fromIterable(<TouchEvent>[
          TouchDownEvent(timestamp: Duration.zero, contact: contact),
          TouchUpEvent(
            timestamp: const Duration(milliseconds: 80),
            contact: contact,
          ),
        ]);

    final List<TapGesture> gestures = await const TapGestureRecognizer()
        .recognize(events)
        .toList();

    expect(gestures.single.position, const Offset(10, 10));
  });

  test(
    'touch event and system gesture streams decode protocol payloads',
    () async {
      final FakePlutoTransport transport = FakePlutoTransport();
      final PlutoTouch touch = PlutoTouch.withTransport(transport);
      final Future<List<TouchEvent>> events = touch.events.take(5).toList();

      for (final String event in <String>[
        'down',
        'move',
        'up',
        'cancel',
        'rejected',
      ]) {
        transport.emitEvent(plutoTouchEventsChannel, _touchPayload(event));
      }

      final List<TouchEvent> decoded = await events;
      expect(decoded[0], isA<TouchDownEvent>());
      expect(decoded[1], isA<TouchMoveEvent>());
      expect(decoded[2], isA<TouchUpEvent>());
      expect(decoded[3], isA<TouchCancelEvent>());
      expect(decoded[4], isA<TouchRejectedEvent>());

      final Future<SystemGesture> gesture = touch.gestures.first;
      transport.emitEvent(plutoTouchEventsChannel, <String, Object?>{
        'gesture': 'edgeSwipe',
        'tUs': 10,
        'edge': 'left',
        'progress': 1.0,
        'isComplete': true,
      });
      expect(await gesture, isA<EdgeSwipeGesture>());

      final Future<SystemGesture> twoFinger = touch.gestures.first;
      transport.emitEvent(plutoTouchEventsChannel, <String, Object?>{
        'gesture': 'twoFingerTap',
        'tUs': 10,
        'xPx': 12.0,
        'yPx': 14.0,
      });
      expect(await twoFinger, isA<TwoFingerTapGesture>());
    },
  );

  test('long press, swipe, and two-finger recognizers emit gestures', () async {
    final TouchContact first = _contact(1, const Offset(10, 10));
    final TouchContact second = _contact(2, const Offset(30, 10));

    final List<LongPressGesture> longPresses =
        await const LongPressGestureRecognizer()
            .recognize(
              Stream<TouchEvent>.fromIterable(<TouchEvent>[
                TouchDownEvent(timestamp: Duration.zero, contact: first),
                TouchUpEvent(
                  timestamp: const Duration(milliseconds: 600),
                  contact: first,
                ),
              ]),
            )
            .toList();

    final List<SwipeGesture> swipes = await const SwipeGestureRecognizer()
        .recognize(
          Stream<TouchEvent>.fromIterable(<TouchEvent>[
            TouchDownEvent(timestamp: Duration.zero, contact: first),
            TouchUpEvent(
              timestamp: const Duration(milliseconds: 100),
              contact: _contact(1, const Offset(160, 10)),
            ),
          ]),
        )
        .toList();

    final List<TwoFingerTouchTapGesture> twoFinger =
        await const TwoFingerTapGestureRecognizer()
            .recognize(
              Stream<TouchEvent>.fromIterable(<TouchEvent>[
                TouchDownEvent(timestamp: Duration.zero, contact: first),
                TouchDownEvent(timestamp: Duration.zero, contact: second),
                TouchUpEvent(
                  timestamp: const Duration(milliseconds: 100),
                  contact: first,
                ),
                TouchUpEvent(
                  timestamp: const Duration(milliseconds: 110),
                  contact: second,
                ),
              ]),
            )
            .toList();

    expect(longPresses.single.position, const Offset(10, 10));
    expect(swipes.single.end, const Offset(160, 10));
    expect(twoFinger.single.centroid, const Offset(20, 10));
  });

  test('palm rejection validation and copyWith are typed', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(
        plutoTouchChannel,
        touchSetPalmRejectionMethod,
        (Object? arguments) => null,
      );
    final PlutoTouch touch = PlutoTouch.withTransport(transport);

    expect(
      touch.setPalmRejection(
        const PalmRejectionConfig(touchMajorThreshold: 300),
      ),
      throwsRangeError,
    );

    final PalmRejectionConfig config = const PalmRejectionConfig().copyWith(
      isEnabled: false,
      touchMajorThreshold: 42,
    );
    await touch.setPalmRejection(config);

    expect(config.isEnabled, isFalse);
    expect(config.toArguments()['touchMajorThreshold'], 42);
    expect(
      PalmRejectionReason.parse('kernelToolType'),
      PalmRejectionReason.kernelToolType,
    );
    expect(PanelEdge.parse('right'), PanelEdge.right);
  });
}

Map<String, Object?> _touchPayload(String event) {
  return <String, Object?>{
    'event': event,
    'tUs': 100,
    'slot': 0,
    'trackingId': 1,
    'xPx': 10.0,
    'yPx': 20.0,
    'rawX': 100,
    'rawY': 200,
    'touchMajor': 0.2,
    'pressure': 0.4,
    'toolType': 'finger',
    'reason': 'contactTooLarge',
  };
}

TouchContact _contact(int id, Offset position) {
  return TouchContact(
    slot: id,
    trackingId: id,
    position: position,
    rawPosition: position,
    touchMajor: 0.1,
    pressure: 0.2,
    toolType: TouchToolType.finger,
  );
}
