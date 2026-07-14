import 'dart:async';

import '../touch_events.dart';
import '../touch_point.dart';

/// Fake touch event source for replay tests.
final class FakeTouchEvents implements TouchEvents {
  /// Creates a fake event source for [events].
  const FakeTouchEvents(this.events);

  @override
  final Stream<TouchEvent> events;

  @override
  Stream<TouchPoint> get points => events.map(TouchPoint.fromEvent);

  /// Creates a fake source that emits one [point].
  factory FakeTouchEvents.single(TouchPoint point) {
    final TouchContact contact = TouchContact(
      slot: 0,
      trackingId: point.id,
      position: point.position,
      rawPosition: point.position,
      touchMajor: 0,
      pressure: 0,
      toolType: TouchToolType.finger,
    );
    final TouchEvent event = switch (point.phase) {
      TouchPhase.down => TouchDownEvent(
        timestamp: point.timestamp,
        contact: contact,
      ),
      TouchPhase.move => TouchMoveEvent(
        timestamp: point.timestamp,
        contact: contact,
      ),
      TouchPhase.up => TouchUpEvent(
        timestamp: point.timestamp,
        contact: contact,
      ),
      TouchPhase.cancel => TouchCancelEvent(
        timestamp: point.timestamp,
        contact: contact,
      ),
      TouchPhase.rejected => TouchRejectedEvent(
        timestamp: point.timestamp,
        contact: contact,
        reason: PalmRejectionReason.contactTooLarge,
      ),
    };
    return FakeTouchEvents(Stream<TouchEvent>.value(event));
  }
}
