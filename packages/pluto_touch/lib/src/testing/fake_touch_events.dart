import 'dart:async';

import '../touch_events.dart';
import '../touch_point.dart';

/// Fake touch event source for replay tests.
final class FakeTouchEvents implements TouchEvents {
  /// Creates a fake event source for [events].
  const FakeTouchEvents(this.events);

  @override
  final Stream<TouchEvent> events;
}
