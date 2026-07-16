import 'dart:ui';

/// Kernel MT tool classification.
enum TouchToolType {
  /// Finger contact.
  finger,

  /// Palm contact.
  palm,

  /// Unknown contact type.
  unknown;

  /// Parses a protocol tool-type name.
  static TouchToolType parse(Object? value) {
    return switch (value) {
      'finger' => TouchToolType.finger,
      'palm' => TouchToolType.palm,
      'unknown' => TouchToolType.unknown,
      _ => throw FormatException('Unknown touch tool type: $value'),
    };
  }
}

/// One tracked contact.
final class TouchContact {
  /// Creates a touch contact.
  const TouchContact({
    required this.slot,
    required this.trackingId,
    required this.position,
    required this.rawPosition,
    required this.touchMajor,
    required this.pressure,
    required this.toolType,
  });

  /// Creates a touch contact from a protocol map.
  factory TouchContact.fromMap(Map<String, Object?> map) {
    return TouchContact(
      slot: _intAt(map, 'slot'),
      trackingId: _intAt(map, 'trackingId'),
      position: Offset(_doubleAt(map, 'xPx'), _doubleAt(map, 'yPx')),
      rawPosition: Offset(
        _intAt(map, 'rawX').toDouble(),
        _intAt(map, 'rawY').toDouble(),
      ),
      touchMajor: _doubleAt(map, 'touchMajor'),
      pressure: _doubleAt(map, 'pressure'),
      toolType: TouchToolType.parse(map['toolType']),
    );
  }

  /// MT slot index.
  final int slot;

  /// Kernel tracking id.
  final int trackingId;

  /// Panel-space position in physical pixels.
  final Offset position;

  /// Raw digitizer units.
  final Offset rawPosition;

  /// Contact ellipse major axis from 0 to 1.
  final double touchMajor;

  /// Contact pressure from 0 to 1.
  final double pressure;

  /// Kernel-reported tool type.
  final TouchToolType toolType;
}

/// Typed touch event.
sealed class TouchEvent {
  /// Creates a touch event.
  const TouchEvent({required this.timestamp, required this.contact});

  /// Monotonic event time.
  final Duration timestamp;

  /// Contact that changed.
  final TouchContact contact;
}

/// Touch down event.
final class TouchDownEvent extends TouchEvent {
  /// Creates a down event.
  const TouchDownEvent({required super.timestamp, required super.contact});
}

/// Touch move event.
final class TouchMoveEvent extends TouchEvent {
  /// Creates a move event.
  const TouchMoveEvent({required super.timestamp, required super.contact});
}

/// Touch up event.
final class TouchUpEvent extends TouchEvent {
  /// Creates an up event.
  const TouchUpEvent({required super.timestamp, required super.contact});
}

/// Touch cancel event.
final class TouchCancelEvent extends TouchEvent {
  /// Creates a cancel event.
  const TouchCancelEvent({required super.timestamp, required super.contact});
}

/// A contact suppressed by palm rejection.
final class TouchRejectedEvent extends TouchEvent {
  /// Creates a rejected event.
  const TouchRejectedEvent({
    required super.timestamp,
    required super.contact,
    required this.reason,
  });

  /// Rejection reason.
  final PalmRejectionReason reason;
}

/// Why a contact was rejected.
enum PalmRejectionReason {
  /// Contact was too large.
  contactTooLarge,

  /// Pen proximity suppressed touch.
  penProximity,

  /// Folio reopen holdoff suppressed touch.
  folioReopenHoldoff,

  /// Kernel classified the contact as palm.
  kernelToolType;

  /// Parses a protocol rejection reason.
  static PalmRejectionReason parse(String value) {
    for (final PalmRejectionReason reason in PalmRejectionReason.values) {
      if (reason.name == value) {
        return reason;
      }
    }
    throw FormatException('Unknown palm rejection reason: $value');
  }
}

/// Palm-rejection tuning.
final class PalmRejectionConfig {
  /// Creates palm-rejection configuration.
  const PalmRejectionConfig({
    this.isEnabled = true,
    this.touchMajorThreshold = 60,
    this.penProximityLinger = const Duration(milliseconds: 300),
    this.folioReopenHoldoff = const Duration(milliseconds: 200),
  });

  /// Creates config from a protocol map.
  factory PalmRejectionConfig.fromMap(Map<String, Object?> map) {
    return PalmRejectionConfig(
      isEnabled: _boolAt(map, 'isEnabled'),
      touchMajorThreshold: _intAt(map, 'touchMajorThreshold'),
      penProximityLinger: Duration(
        milliseconds: _intAt(map, 'penProximityLingerMs'),
      ),
      folioReopenHoldoff: Duration(
        milliseconds: _intAt(map, 'folioReopenHoldoffMs'),
      ),
    );
  }

  /// Master switch.
  final bool isEnabled;

  /// Raw `ABS_MT_TOUCH_MAJOR` threshold.
  final int touchMajorThreshold;

  /// Touch suppression after pen leaves proximity.
  final Duration penProximityLinger;

  /// Touch suppression after folio reopen or resume.
  final Duration folioReopenHoldoff;

  /// Returns a copy with selected fields replaced.
  PalmRejectionConfig copyWith({
    bool? isEnabled,
    int? touchMajorThreshold,
    Duration? penProximityLinger,
    Duration? folioReopenHoldoff,
  }) {
    return PalmRejectionConfig(
      isEnabled: isEnabled ?? this.isEnabled,
      touchMajorThreshold: touchMajorThreshold ?? this.touchMajorThreshold,
      penProximityLinger: penProximityLinger ?? this.penProximityLinger,
      folioReopenHoldoff: folioReopenHoldoff ?? this.folioReopenHoldoff,
    );
  }

  /// Encodes this config for the platform channel.
  Map<String, Object?> toArguments() {
    return <String, Object?>{
      'isEnabled': isEnabled,
      'touchMajorThreshold': touchMajorThreshold,
      'penProximityLingerMs': penProximityLinger.inMilliseconds,
      'folioReopenHoldoffMs': folioReopenHoldoff.inMilliseconds,
    };
  }
}

/// System gestures recognized by the platform.
sealed class SystemGesture {
  /// Creates a system gesture.
  const SystemGesture({required this.timestamp});

  /// Monotonic timestamp.
  final Duration timestamp;
}

/// Which physical edge a swipe started from.
enum PanelEdge {
  /// Top edge.
  top,

  /// Bottom edge.
  bottom,

  /// Left edge.
  left,

  /// Right edge.
  right;

  /// Parses a protocol edge name.
  static PanelEdge parse(String value) {
    for (final PanelEdge edge in PanelEdge.values) {
      if (edge.name == value) {
        return edge;
      }
    }
    throw FormatException('Unknown panel edge: $value');
  }
}

/// An edge swipe system gesture.
final class EdgeSwipeGesture extends SystemGesture {
  /// Creates an edge swipe gesture.
  const EdgeSwipeGesture({
    required super.timestamp,
    required this.edge,
    required this.progress,
    required this.isComplete,
  });

  /// Starting edge.
  final PanelEdge edge;

  /// Progress from 0 to 1.
  final double progress;

  /// Whether recognition is complete.
  final bool isComplete;
}

/// A two-finger tap system gesture.
final class TwoFingerTapGesture extends SystemGesture {
  /// Creates a two-finger tap gesture.
  const TwoFingerTapGesture({required super.timestamp, required this.centroid});

  /// Gesture centroid.
  final Offset centroid;
}

/// Touch digitizer description.
final class TouchCapabilities {
  /// Creates touch digitizer capabilities.
  const TouchCapabilities({
    required this.slotCount,
    required this.rawXMax,
    required this.rawYMax,
    required this.rawTouchMajorMax,
  });

  /// Creates capabilities from a protocol map.
  factory TouchCapabilities.fromMap(Map<String, Object?> map) {
    return TouchCapabilities(
      slotCount: _intAt(map, 'slotCount'),
      rawXMax: _intAt(map, 'rawXMax'),
      rawYMax: _intAt(map, 'rawYMax'),
      rawTouchMajorMax: _intAt(map, 'rawTouchMajorMax'),
    );
  }

  /// Number of MT slots.
  final int slotCount;

  /// Maximum raw X value.
  final int rawXMax;

  /// Maximum raw Y value.
  final int rawYMax;

  /// Maximum raw touch-major value.
  final int rawTouchMajorMax;
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
