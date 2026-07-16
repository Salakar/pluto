import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:meta/meta.dart';
import 'package:pluto_core/pluto_core.dart';

import 'touch_point.dart';

/// Source of typed touch events.
abstract interface class TouchEvents {
  /// Typed touch event stream.
  Stream<TouchEvent> get events;
}

/// Raw touch, palm rejection, and system gestures.
final class PlutoTouch implements TouchEvents {
  /// Creates a touch facade backed by [transport].
  @visibleForTesting
  PlutoTouch.withTransport(PlutoTransport transport) : _transport = transport;

  /// The process-wide instance backed by real embedder channels.
  static final PlutoTouch instance = PlutoTouch.withTransport(
    ChannelTransport.shared,
  );

  final PlutoTransport _transport;

  @override
  Stream<TouchEvent> get events {
    return _transport
        .events(channel: plutoTouchEventsChannel)
        .map(
          (Object? event) =>
              _touchEventFromMap(_stringMap(event, 'touch event')),
        );
  }

  /// System-level gestures recognized by the embedder.
  Stream<SystemGesture> get gestures {
    return _transport
        .events(
          channel: plutoTouchEventsChannel,
          arguments: const <String, Object?>{'topic': 'gestures'},
        )
        .map(
          (Object? event) =>
              _systemGestureFromMap(_stringMap(event, 'system gesture')),
        );
  }

  /// Current palm-rejection configuration.
  Future<PalmRejectionConfig> palmRejection() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoTouchChannel,
      method: touchPalmRejectionMethod,
    );
    return PalmRejectionConfig.fromMap(_stringMap(payload, 'palm rejection'));
  }

  /// Applies [config] to the embedder input pipeline.
  Future<void> setPalmRejection(PalmRejectionConfig config) async {
    if (config.touchMajorThreshold < 0 || config.touchMajorThreshold > 255) {
      throw RangeError.range(
        config.touchMajorThreshold,
        0,
        255,
        'touchMajorThreshold',
      );
    }
    await _transport.invoke<Object?>(
      channel: plutoTouchChannel,
      method: touchSetPalmRejectionMethod,
      arguments: config.toArguments(),
    );
  }

  /// Digitizer description.
  Future<TouchCapabilities> capabilities() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoTouchChannel,
      method: touchCapabilitiesMethod,
    );
    return TouchCapabilities.fromMap(_stringMap(payload, 'touch capabilities'));
  }
}

/// Recognized high-level touch gesture.
sealed class RecognizedTouchGesture {
  /// Creates a recognized touch gesture.
  const RecognizedTouchGesture({required this.timestamp});

  /// Monotonic timestamp.
  final Duration timestamp;
}

/// Single-finger tap gesture.
final class TapGesture extends RecognizedTouchGesture {
  /// Creates a tap gesture.
  const TapGesture({required super.timestamp, required this.position});

  /// Tap position.
  final Offset position;
}

/// Single-finger long-press gesture.
final class LongPressGesture extends RecognizedTouchGesture {
  /// Creates a long-press gesture.
  const LongPressGesture({required super.timestamp, required this.position});

  /// Press position.
  final Offset position;
}

/// Swipe gesture.
final class SwipeGesture extends RecognizedTouchGesture {
  /// Creates a swipe gesture.
  const SwipeGesture({
    required super.timestamp,
    required this.start,
    required this.end,
  });

  /// Start position.
  final Offset start;

  /// End position.
  final Offset end;
}

/// Two-finger tap gesture recognized in Dart.
final class TwoFingerTouchTapGesture extends RecognizedTouchGesture {
  /// Creates a two-finger tap gesture.
  const TwoFingerTouchTapGesture({
    required super.timestamp,
    required this.centroid,
  });

  /// Gesture centroid.
  final Offset centroid;
}

/// Recognizes single-finger taps.
final class TapGestureRecognizer {
  /// Creates a tap recognizer.
  const TapGestureRecognizer({
    this.maxDuration = const Duration(milliseconds: 250),
    this.maxTravel = 24,
  });

  /// Maximum down-to-up duration.
  final Duration maxDuration;

  /// Maximum movement in pixels.
  final double maxTravel;

  /// Recognizes gestures from [events].
  Stream<TapGesture> recognize(Stream<TouchEvent> events) async* {
    _TrackedTouch? tracked;
    await for (final TouchEvent event in events) {
      switch (event) {
        case TouchDownEvent():
          tracked = _TrackedTouch(event);
        case TouchUpEvent():
          final _TrackedTouch? current = tracked;
          if (current != null &&
              current.matches(event, maxDuration, maxTravel)) {
            yield TapGesture(
              timestamp: event.timestamp,
              position: event.contact.position,
            );
          }
          tracked = null;
        case TouchCancelEvent() || TouchRejectedEvent():
          tracked = null;
        case TouchMoveEvent():
          break;
      }
    }
  }
}

/// Recognizes single-finger long presses.
final class LongPressGestureRecognizer {
  /// Creates a long-press recognizer.
  const LongPressGestureRecognizer({
    this.minDuration = const Duration(milliseconds: 500),
    this.maxTravel = 24,
  });

  /// Minimum press duration.
  final Duration minDuration;

  /// Maximum movement in pixels.
  final double maxTravel;

  /// Recognizes gestures from [events].
  Stream<LongPressGesture> recognize(Stream<TouchEvent> events) async* {
    _TrackedTouch? tracked;
    await for (final TouchEvent event in events) {
      switch (event) {
        case TouchDownEvent():
          tracked = _TrackedTouch(event);
        case TouchUpEvent():
          final _TrackedTouch? current = tracked;
          if (current != null &&
              event.timestamp - current.down.timestamp >= minDuration &&
              current.travelTo(event) <= maxTravel) {
            yield LongPressGesture(
              timestamp: event.timestamp,
              position: current.down.contact.position,
            );
          }
          tracked = null;
        case TouchCancelEvent() || TouchRejectedEvent():
          tracked = null;
        case TouchMoveEvent():
          break;
      }
    }
  }
}

/// Recognizes single-finger swipes.
final class SwipeGestureRecognizer {
  /// Creates a swipe recognizer.
  const SwipeGestureRecognizer({this.minTravel = 96});

  /// Minimum movement in pixels.
  final double minTravel;

  /// Recognizes gestures from [events].
  Stream<SwipeGesture> recognize(Stream<TouchEvent> events) async* {
    _TrackedTouch? tracked;
    await for (final TouchEvent event in events) {
      switch (event) {
        case TouchDownEvent():
          tracked = _TrackedTouch(event);
        case TouchUpEvent():
          final _TrackedTouch? current = tracked;
          if (current != null && current.travelTo(event) >= minTravel) {
            yield SwipeGesture(
              timestamp: event.timestamp,
              start: current.down.contact.position,
              end: event.contact.position,
            );
          }
          tracked = null;
        case TouchCancelEvent() || TouchRejectedEvent():
          tracked = null;
        case TouchMoveEvent():
          break;
      }
    }
  }
}

/// Recognizes two-finger taps.
final class TwoFingerTapGestureRecognizer {
  /// Creates a two-finger tap recognizer.
  const TwoFingerTapGestureRecognizer({
    this.maxDuration = const Duration(milliseconds: 300),
    this.maxTravel = 32,
  });

  /// Maximum gesture duration.
  final Duration maxDuration;

  /// Maximum movement per finger in pixels.
  final double maxTravel;

  /// Recognizes gestures from [events].
  Stream<TwoFingerTouchTapGesture> recognize(Stream<TouchEvent> events) async* {
    final Map<int, _TrackedTouch> active = <int, _TrackedTouch>{};
    final List<_TrackedTouch> completed = <_TrackedTouch>[];
    await for (final TouchEvent event in events) {
      switch (event) {
        case TouchDownEvent():
          active[event.contact.trackingId] = _TrackedTouch(event);
        case TouchUpEvent():
          final _TrackedTouch? start = active.remove(event.contact.trackingId);
          if (start != null && start.matches(event, maxDuration, maxTravel)) {
            completed.add(start.withUp(event));
          }
          if (completed.length == 2) {
            final _TrackedTouch first = completed[0];
            final _TrackedTouch second = completed[1];
            final Duration span =
                (first.up ?? first.down).timestamp - second.down.timestamp;
            if (span.abs() <= maxDuration) {
              yield TwoFingerTouchTapGesture(
                timestamp: event.timestamp,
                centroid: Offset(
                  (first.down.contact.position.dx +
                          second.down.contact.position.dx) /
                      2,
                  (first.down.contact.position.dy +
                          second.down.contact.position.dy) /
                      2,
                ),
              );
            }
            completed.clear();
          }
        case TouchCancelEvent() || TouchRejectedEvent():
          active.remove(event.contact.trackingId);
          completed.clear();
        case TouchMoveEvent():
          break;
      }
    }
  }
}

final class _TrackedTouch {
  const _TrackedTouch(this.down, [this.up]);

  final TouchDownEvent down;
  final TouchUpEvent? up;

  _TrackedTouch withUp(TouchUpEvent event) => _TrackedTouch(down, event);

  bool matches(TouchUpEvent event, Duration maxDuration, double maxTravel) {
    return event.timestamp - down.timestamp <= maxDuration &&
        travelTo(event) <= maxTravel;
  }

  double travelTo(TouchEvent event) {
    final Offset delta = event.contact.position - down.contact.position;
    return math.sqrt(delta.dx * delta.dx + delta.dy * delta.dy);
  }
}

TouchEvent _touchEventFromMap(Map<String, Object?> map) {
  final Duration timestamp = Duration(microseconds: _intAt(map, 'tUs'));
  final TouchContact contact = TouchContact.fromMap(map);
  return switch (_stringAt(map, 'event')) {
    'down' => TouchDownEvent(timestamp: timestamp, contact: contact),
    'move' => TouchMoveEvent(timestamp: timestamp, contact: contact),
    'up' => TouchUpEvent(timestamp: timestamp, contact: contact),
    'cancel' => TouchCancelEvent(timestamp: timestamp, contact: contact),
    'rejected' => TouchRejectedEvent(
      timestamp: timestamp,
      contact: contact,
      reason: PalmRejectionReason.parse(_stringAt(map, 'reason')),
    ),
    _ => throw const FormatException('Unknown touch event.'),
  };
}

SystemGesture _systemGestureFromMap(Map<String, Object?> map) {
  final Duration timestamp = Duration(microseconds: _intAt(map, 'tUs'));
  return switch (_stringAt(map, 'gesture')) {
    'edgeSwipe' => EdgeSwipeGesture(
      timestamp: timestamp,
      edge: PanelEdge.parse(_stringAt(map, 'edge')),
      progress: _doubleAt(map, 'progress'),
      isComplete: _boolAt(map, 'isComplete'),
    ),
    'twoFingerTap' => TwoFingerTapGesture(
      timestamp: timestamp,
      centroid: Offset(_doubleAt(map, 'xPx'), _doubleAt(map, 'yPx')),
    ),
    _ => throw const FormatException('Unknown system gesture.'),
  };
}

Map<String, Object?> _stringMap(Object? value, String path) {
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is String) {
        result[key] = entry.value;
      }
    }
    return result;
  }
  throw FormatException('Expected $path to be a map.');
}

String _stringAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected $key to be a string.');
}

int _intAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Expected $key to be an int.');
}

double _doubleAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value.toDouble();
  }
  if (value is double) {
    return value;
  }
  throw FormatException('Expected $key to be a number.');
}

bool _boolAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('Expected $key to be a bool.');
}
