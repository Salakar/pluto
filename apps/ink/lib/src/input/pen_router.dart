import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:pluto_pen/pluto_pen.dart';

/// Channel-side pen lifecycle phase represented by [PenMetadata].
enum PenMetadataPhase {
  /// No channel event has arrived yet.
  unknown,

  /// The pen entered digitizer proximity.
  enteredProximity,

  /// The pen moved while hovering.
  hover,

  /// The pen tip or eraser made contact.
  down,

  /// The contacting pen moved.
  move,

  /// Pen contact ended while proximity remains.
  up,

  /// The pen left digitizer proximity.
  leftProximity,

  /// A barrel button changed state.
  buttonsChanged,
}

/// Latest low-cardinality metadata received from `pluto/pen/events`.
final class PenMetadata {
  const PenMetadata({
    required this.phase,
    required this.timestamp,
    required this.logicalPosition,
    required this.rawPosition,
    required this.tool,
    required this.tilt,
    required this.rawTilt,
    required this.buttons,
    required this.hoverDistance,
    required this.rawDistance,
    required this.isInProximity,
    required this.isInContact,
    required this.hasChannelSample,
  });

  /// Initial metadata used before the first channel event.
  static const PenMetadata initial = PenMetadata(
    phase: PenMetadataPhase.unknown,
    timestamp: Duration.zero,
    logicalPosition: Offset.zero,
    rawPosition: Offset.zero,
    tool: PenTool.pen,
    tilt: Offset.zero,
    rawTilt: Offset.zero,
    buttons: PenButtons.none,
    hoverDistance: 1,
    rawDistance: 0,
    isInProximity: false,
    isInContact: false,
    hasChannelSample: false,
  );

  /// Channel lifecycle phase.
  final PenMetadataPhase phase;

  /// Monotonic channel timestamp.
  final Duration timestamp;

  /// Channel panel position converted from physical pixels to logical pixels.
  final Offset logicalPosition;

  /// Untransformed digitizer coordinates.
  final Offset rawPosition;

  /// Active pen or eraser end.
  final PenTool tool;

  /// Normalized tilt in radians.
  final Offset tilt;

  /// Raw tilt in centi-degrees.
  final Offset rawTilt;

  /// Barrel button bits.
  final PenButtons buttons;

  /// Normalized hover distance.
  final double hoverDistance;

  /// Raw ABS_DISTANCE value.
  final int rawDistance;

  /// Whether the channel reports the pen in digitizer range.
  final bool isInProximity;

  /// Whether the channel reports tip or eraser contact.
  final bool isInContact;

  /// Whether these values came from a real channel sample.
  final bool hasChannelSample;
}

/// Geometry-side lifecycle phase from Flutter pointer delivery.
enum PenInputPhase {
  /// Hover movement.
  hover,

  /// Contact began.
  down,

  /// Contact movement.
  move,

  /// Contact ended.
  up,

  /// Flutter cancelled the pointer sequence.
  cancel,
}

/// One Flutter geometry sample stamped with the latest channel metadata.
final class PenInputSample {
  const PenInputSample({
    required this.phase,
    required this.pointer,
    required this.device,
    required this.timestamp,
    required this.position,
    required this.localPosition,
    required this.pressure,
    required this.normalizedPressure,
    required this.metadata,
  });

  /// Flutter pointer lifecycle phase.
  final PenInputPhase phase;

  /// Flutter pointer identifier.
  final int pointer;

  /// Flutter input-device identifier.
  final int device;

  /// Flutter pointer timestamp.
  final Duration timestamp;

  /// Global logical position.
  final Offset position;

  /// Canvas-local logical position.
  final Offset localPosition;

  /// Pressure as delivered by Flutter.
  final double pressure;

  /// Pressure normalized using Flutter's reported range, when usable.
  final double? normalizedPressure;

  /// Latest channel metadata at routing time.
  final PenMetadata metadata;
}

/// Merges Flutter stylus geometry with injectable `pluto_pen` metadata.
///
/// The two sources intentionally are not matched sample-for-sample. Metadata
/// changes slowly, so [handlePointerEvent] stamps [latestPenMeta] onto each
/// accepted Flutter stylus event.
final class PenRouter {
  PenRouter({required this.penEvents, required this.devicePixelRatio}) {
    if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) {
      throw ArgumentError.value(
        devicePixelRatio,
        'devicePixelRatio',
        'must be finite and greater than zero',
      );
    }
  }

  /// Injectable channel metadata source.
  final PenEvents penEvents;

  /// Physical panel pixels per logical Flutter pixel.
  final double devicePixelRatio;
  final StreamController<PenMetadata> _metadataController =
      StreamController<PenMetadata>.broadcast(sync: true);
  final StreamController<PenInputSample> _inputController =
      StreamController<PenInputSample>.broadcast(sync: true);

  StreamSubscription<PenEvent>? _subscription;
  PenMetadata _latestPenMeta = PenMetadata.initial;
  Object? _lastMetadataError;
  bool _isDisposed = false;

  /// Latest channel metadata, or [PenMetadata.initial] before the first event.
  PenMetadata get latestPenMeta => _latestPenMeta;

  /// Metadata updates after physical-to-logical position normalization.
  Stream<PenMetadata> get metadataEvents => _metadataController.stream;

  /// Routed Flutter geometry samples.
  Stream<PenInputSample> get inputSamples => _inputController.stream;

  /// Most recent channel-stream error, retained for diagnostics.
  Object? get lastMetadataError => _lastMetadataError;

  /// Whether channel metadata subscription is active.
  bool get isStarted => _subscription != null;

  /// Starts listening to the injected metadata source.
  ///
  /// Calling this method more than once is harmless.
  void start() {
    _checkNotDisposed();
    if (_subscription != null) {
      return;
    }
    _subscription = penEvents.events.listen(
      _handlePenEvent,
      onError: (Object error, StackTrace stackTrace) {
        _lastMetadataError = error;
      },
    );
  }

  /// Routes one Flutter pointer event when it is stylus geometry.
  ///
  /// Touch, mouse, and unsupported pointer phases return null. Stylus and
  /// inverted-stylus kinds are accepted; the channel's [PenMetadata.tool]
  /// remains authoritative for the eraser-end override.
  PenInputSample? handlePointerEvent(PointerEvent event) {
    _checkNotDisposed();
    if (!_isStylus(event.kind)) {
      return null;
    }
    final PenInputPhase? phase = switch (event) {
      PointerHoverEvent() => PenInputPhase.hover,
      PointerDownEvent() => PenInputPhase.down,
      PointerMoveEvent() => PenInputPhase.move,
      PointerUpEvent() => PenInputPhase.up,
      PointerCancelEvent() => PenInputPhase.cancel,
      _ => null,
    };
    if (phase == null) {
      return null;
    }
    final double pressureRange = event.pressureMax - event.pressureMin;
    final double? normalizedPressure = pressureRange <= 0
        ? null
        : ((event.pressure - event.pressureMin) / pressureRange).clamp(
            0.0,
            1.0,
          );
    final PenMetadata metadata =
        !_latestPenMeta.hasChannelSample &&
            event.kind == PointerDeviceKind.invertedStylus
        ? PenMetadata(
            phase: _latestPenMeta.phase,
            timestamp: _latestPenMeta.timestamp,
            logicalPosition: _latestPenMeta.logicalPosition,
            rawPosition: _latestPenMeta.rawPosition,
            tool: PenTool.eraser,
            tilt: _latestPenMeta.tilt,
            rawTilt: _latestPenMeta.rawTilt,
            buttons: _latestPenMeta.buttons,
            hoverDistance: _latestPenMeta.hoverDistance,
            rawDistance: _latestPenMeta.rawDistance,
            isInProximity: _latestPenMeta.isInProximity,
            isInContact: _latestPenMeta.isInContact,
            hasChannelSample: false,
          )
        : _latestPenMeta;
    final PenInputSample sample = PenInputSample(
      phase: phase,
      pointer: event.pointer,
      device: event.device,
      timestamp: event.timeStamp,
      position: event.position,
      localPosition: event.localPosition,
      pressure: event.pressure,
      normalizedPressure: normalizedPressure,
      metadata: metadata,
    );
    _inputController.add(sample);
    return sample;
  }

  /// Cancels the channel subscription and closes both output streams.
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _metadataController.close();
    await _inputController.close();
  }

  void _handlePenEvent(PenEvent event) {
    final PenSample sample = event.sample;
    final (PenMetadataPhase, bool, bool) state = switch (event) {
      PenEnteredProximityEvent() => (
        PenMetadataPhase.enteredProximity,
        true,
        false,
      ),
      PenHoverEvent() => (PenMetadataPhase.hover, true, false),
      PenDownEvent() => (PenMetadataPhase.down, true, true),
      PenMoveEvent() => (PenMetadataPhase.move, true, true),
      PenUpEvent() => (PenMetadataPhase.up, true, false),
      PenLeftProximityEvent() => (PenMetadataPhase.leftProximity, false, false),
      PenButtonsChangedEvent() => (
        PenMetadataPhase.buttonsChanged,
        true,
        _latestPenMeta.isInContact,
      ),
    };
    _latestPenMeta = PenMetadata(
      phase: state.$1,
      timestamp: sample.timestamp,
      logicalPosition: Offset(
        sample.position.dx / devicePixelRatio,
        sample.position.dy / devicePixelRatio,
      ),
      rawPosition: sample.rawPosition,
      tool: sample.tool,
      tilt: sample.tilt,
      rawTilt: sample.rawTilt,
      buttons: sample.buttons,
      hoverDistance: sample.distance,
      rawDistance: sample.rawDistance,
      isInProximity: state.$2,
      isInContact: state.$3,
      hasChannelSample: true,
    );
    _metadataController.add(_latestPenMeta);
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError('PenRouter is disposed.');
    }
  }
}

bool _isStylus(PointerDeviceKind kind) {
  return kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;
}
