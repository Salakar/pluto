import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_touch/pluto_touch.dart';

void main() {
  runApp(InkLabApp());
}

/// RepaintBoundary isolating canvas damage from the HUD.
const Key inkCanvasBoundaryKey = Key('ink-canvas-boundary');

/// CustomPaint hosting the stroke painter.
const Key inkCanvasPaintKey = Key('ink-canvas-paint');

/// HUD stroke-count readout.
const Key inkStrokeCountKey = Key('ink-stroke-count');

/// Eraser mode toggle button.
const Key inkEraserToggleKey = Key('ink-eraser-toggle');

/// Clear-all button.
const Key inkClearButtonKey = Key('ink-clear-button');

/// Corner exit affordance.
const Key inkExitButtonKey = Key('ink-exit-button');

/// Stroke width used when pressure mapping is unavailable.
const double fixedInkStrokeWidth = 4;

/// Stroke width at zero pressure when pressure mapping is available.
const double minInkStrokeWidth = 2;

/// Stroke width at full pressure when pressure mapping is available.
const double maxInkStrokeWidth = 18;

/// Loads the digitizer description, throwing when the pen stack is absent.
typedef PenCapabilitiesProbe = Future<PenCapabilities> Function();

/// Maps a normalized pressure to a stroke width in logical pixels.
///
/// Degrades to [fixedInkStrokeWidth] when pressure mapping is unsupported or
/// the pointer does not report a usable pressure range.
@visibleForTesting
double strokeWidthFor({
  required bool isPressureMapped,
  required double? normalizedPressure,
}) {
  if (!isPressureMapped || normalizedPressure == null) {
    return fixedInkStrokeWidth;
  }
  return minInkStrokeWidth +
      normalizedPressure * (maxInkStrokeWidth - minInkStrokeWidth);
}

/// Pen drawing lab: pointer-event freehand canvas with pressure-mapped ink,
/// an eraser toggle, and pen/touch stream readouts.
class InkLabApp extends StatelessWidget {
  /// Creates the app; test seams default to the real Pluto services.
  InkLabApp({
    super.key,
    PenEvents? penEvents,
    TouchEvents? touchEvents,
    PenCapabilitiesProbe? penCapabilitiesProbe,
    VoidCallback? onExit,
  }) : penEvents = penEvents ?? PlutoPen.instance,
       touchEvents = touchEvents ?? PlutoTouch.instance,
       penCapabilitiesProbe = penCapabilitiesProbe ?? _probePenCapabilities,
       onExit = onExit ?? _exitToLauncher;

  /// Typed pen event source (HUD readouts + physical eraser detection).
  final PenEvents penEvents;

  /// Typed touch event source (palm rejection readout).
  final TouchEvents touchEvents;

  /// Capability probe deciding whether stroke width maps pressure.
  final PenCapabilitiesProbe penCapabilitiesProbe;

  /// Invoked by the corner exit affordance.
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: const Color(0xFFFFFFFF),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: _pageRouteBuilder,
      title: 'Ink Lab',
      home: _InkLabScreen(
        penEvents: penEvents,
        touchEvents: touchEvents,
        penCapabilitiesProbe: penCapabilitiesProbe,
        onExit: onExit,
      ),
    );
  }
}

Future<PenCapabilities> _probePenCapabilities() {
  return PlutoPen.instance.capabilities();
}

void _exitToLauncher() {
  // The embedder maps SystemNavigator.pop to a clean shutdown; the session
  // supervisor then returns to the launcher.
  unawaited(SystemNavigator.pop());
}

PageRoute<T> _pageRouteBuilder<T>(
  RouteSettings settings,
  WidgetBuilder builder,
) {
  return PageRouteBuilder<T>(
    settings: settings,
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          return builder(context);
        },
  );
}

class _InkLabScreen extends StatefulWidget {
  const _InkLabScreen({
    required this.penEvents,
    required this.touchEvents,
    required this.penCapabilitiesProbe,
    required this.onExit,
  });

  final PenEvents penEvents;
  final TouchEvents touchEvents;
  final PenCapabilitiesProbe penCapabilitiesProbe;
  final VoidCallback onExit;

  @override
  State<_InkLabScreen> createState() => _InkLabScreenState();
}

class _InkLabScreenState extends State<_InkLabScreen> {
  static const double _eraserRadius = 28;

  final List<_InkStroke> _strokes = <_InkStroke>[];
  StreamSubscription<PenEvent>? _penSubscription;
  StreamSubscription<TouchEvent>? _touchSubscription;
  _InkStroke? _activeStroke;
  int? _activePointer;
  Offset? _hoverPosition;
  bool _isEraserOn = false;
  PenTool? _streamTool;
  bool _isPenStreamLive = true;
  bool? _isPressureMapped;
  int _rawPressureMax = 0;
  double? _lastPressure;
  int _revision = 0;
  int _rejectedTouchCount = 0;
  String _touchStatus = 'Touch clear';

  bool get _isErasing => _isEraserOn || _streamTool == PenTool.eraser;

  @override
  void initState() {
    super.initState();
    _subscribe();
    unawaited(_probeCapabilities());
  }

  @override
  void didUpdateWidget(covariant _InkLabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.penEvents != widget.penEvents ||
        oldWidget.touchEvents != widget.touchEvents) {
      _penSubscription?.cancel();
      _touchSubscription?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _penSubscription?.cancel();
    _touchSubscription?.cancel();
    super.dispose();
  }

  void _subscribe() {
    _penSubscription = widget.penEvents.events.listen(
      _handlePenEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (mounted) {
          setState(() => _isPenStreamLive = false);
        }
      },
    );
    _touchSubscription = widget.touchEvents.events.listen(
      _handleTouchEvent,
      onError: (Object error, StackTrace stackTrace) {
        // Touch stream is best-effort chrome; ignore transport errors.
      },
    );
  }

  Future<void> _probeCapabilities() async {
    bool isSupported = false;
    int rawMax = 0;
    try {
      final PenCapabilities capabilities = await widget.penCapabilitiesProbe();
      isSupported = capabilities.rawPressureMax > 0;
      rawMax = capabilities.rawPressureMax;
    } on Object {
      // Pen stack absent or capability call unsupported: fixed-width ink.
      isSupported = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isPressureMapped = isSupported;
      _rawPressureMax = rawMax;
    });
  }

  // Pen stream drives the HUD readouts and physical-eraser detection; the
  // strokes themselves come from Flutter pointer events.
  void _handlePenEvent(PenEvent event) {
    setState(() {
      _revision += 1;
      if (event is PenLeftProximityEvent) {
        _streamTool = null;
        return;
      }
      _streamTool = event.sample.tool;
    });
  }

  void _handleTouchEvent(TouchEvent event) {
    final bool isRejected =
        event is TouchRejectedEvent ||
        event.contact.toolType == TouchToolType.palm ||
        event.contact.touchMajor >= 0.55;
    setState(() {
      if (isRejected) {
        _rejectedTouchCount += 1;
        _touchStatus = 'Palm rejected';
      } else {
        _touchStatus = 'Touch seen';
      }
    });
  }

  double? _normalizedPressure(PointerEvent event) {
    if (event.kind != PointerDeviceKind.stylus) {
      return null;
    }
    final double range = event.pressureMax - event.pressureMin;
    if (range <= 0) {
      return null;
    }
    final double normalized = (event.pressure - event.pressureMin) / range;
    return normalized.clamp(0.0, 1.0);
  }

  double _strokeWidthFor(PointerEvent event) {
    return strokeWidthFor(
      isPressureMapped: _isPressureMapped ?? false,
      normalizedPressure: _normalizedPressure(event),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_activePointer != null) {
      return;
    }
    _activePointer = event.pointer;
    setState(() {
      _revision += 1;
      _hoverPosition = null;
      if (_isErasing) {
        _eraseAt(event.localPosition);
        return;
      }
      _lastPressure = _normalizedPressure(event);
      final _InkStroke stroke = _InkStroke(<_InkPoint>[
        _InkPoint(event.localPosition, _strokeWidthFor(event)),
      ]);
      _activeStroke = stroke;
      _strokes.add(stroke);
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) {
      return;
    }
    setState(() {
      _revision += 1;
      if (_isErasing) {
        _eraseAt(event.localPosition);
        return;
      }
      _lastPressure = _normalizedPressure(event);
      _activeStroke?.points.add(
        _InkPoint(event.localPosition, _strokeWidthFor(event)),
      );
    });
  }

  void _handlePointerEnd(int pointer) {
    if (pointer != _activePointer) {
      return;
    }
    _activePointer = null;
    _activeStroke = null;
  }

  void _eraseAt(Offset position) {
    _strokes.removeWhere((_InkStroke stroke) {
      return stroke.points.any((_InkPoint point) {
        return (point.position - position).distance <=
            _eraserRadius + point.width / 2;
      });
    });
    _activeStroke = null;
  }

  void _toggleEraser() {
    setState(() {
      _isEraserOn = !_isEraserOn;
      _revision += 1;
    });
  }

  void _clearStrokes() {
    setState(() {
      _strokes.clear();
      _activeStroke = null;
      _activePointer = null;
      _revision += 1;
    });
  }

  String get _pressureMapReadout {
    return switch (_isPressureMapped) {
      null => 'Pressure map …',
      true => 'Pressure map on (max $_rawPressureMax)',
      false => 'Pressure map off',
    };
  }

  @override
  Widget build(BuildContext context) {
    final String pressure = _lastPressure == null
        ? '--'
        : _lastPressure!.toStringAsFixed(2);
    final String tool = !_isPenStreamLive
        ? 'stream off'
        : (_streamTool?.name ?? '--');
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text('Ink Lab', style: _titleStyle),
                      ),
                      _InkButton(
                        key: inkExitButtonKey,
                        label: '× EXIT',
                        onPressed: widget.onExit,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 18,
                    runSpacing: 6,
                    children: <Widget>[
                      Text(
                        'Strokes ${_strokes.length}',
                        key: inkStrokeCountKey,
                        style: _readoutStyle,
                      ),
                      Text(
                        'Mode ${_isErasing ? 'ERASE' : 'DRAW'}',
                        style: _readoutStyle,
                      ),
                      Text('Pressure $pressure', style: _readoutStyle),
                      Text(_pressureMapReadout, style: _readoutStyle),
                      Text('Tool $tool', style: _readoutStyle),
                      Text(
                        '$_touchStatus $_rejectedTouchCount',
                        style: _readoutStyle,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      _InkButton(
                        key: inkEraserToggleKey,
                        label: 'ERASER',
                        isActive: _isEraserOn,
                        onPressed: _toggleEraser,
                      ),
                      const SizedBox(width: 12),
                      _InkButton(
                        key: inkClearButtonKey,
                        label: 'CLEAR',
                        onPressed: _clearStrokes,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: RepaintBoundary(
                  key: inkCanvasBoundaryKey,
                  child: ClipRect(
                    child: MouseRegion(
                      onHover: (PointerHoverEvent event) {
                        setState(() {
                          _hoverPosition = event.localPosition;
                          _revision += 1;
                        });
                      },
                      onExit: (PointerExitEvent event) {
                        setState(() {
                          _hoverPosition = null;
                          _revision += 1;
                        });
                      },
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _handlePointerDown,
                        onPointerMove: _handlePointerMove,
                        onPointerUp: (PointerUpEvent event) =>
                            _handlePointerEnd(event.pointer),
                        onPointerCancel: (PointerCancelEvent event) =>
                            _handlePointerEnd(event.pointer),
                        child: CustomPaint(
                          key: inkCanvasPaintKey,
                          painter: InkLabCanvasPainter._(
                            strokes: _strokes,
                            hoverPosition: _hoverPosition,
                            isErasing: _isErasing,
                            revision: _revision,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chunky ink-bordered button driven by raw pointer events, matching the
/// launcher's paper-brutalist chrome (ink borders, inverted active state).
class _InkButton extends StatelessWidget {
  const _InkButton({
    required this.label,
    required this.onPressed,
    this.isActive = false,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (PointerDownEvent event) => onPressed(),
        child: Container(
          alignment: Alignment.center,
          constraints: const BoxConstraints(minWidth: 96, minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
            border: const Border.fromBorderSide(
              BorderSide(width: 2, color: Color(0xFF000000)),
            ),
          ),
          child: Text(
            label,
            style: isActive ? _buttonActiveStyle : _buttonStyle,
          ),
        ),
      ),
    );
  }
}

/// Paints committed strokes, the hover cursor, and the canvas chrome.
class InkLabCanvasPainter extends CustomPainter {
  const InkLabCanvasPainter._({
    required this._strokes,
    required this._hoverPosition,
    required this._isErasing,
    required this._revision,
  });

  final List<_InkStroke> _strokes;
  final Offset? _hoverPosition;
  final bool _isErasing;
  final int _revision;

  /// Number of committed strokes (test hook).
  int get strokeCount => _strokes.length;

  /// Whether the app currently owns a visible hover indicator (test hook).
  bool get hasHover => _hoverPosition != null;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    _drawGrid(canvas, size);
    for (final _InkStroke stroke in _strokes) {
      _drawStroke(canvas, stroke);
    }
    final Offset? hover = _hoverPosition;
    if (hover != null) {
      _drawHover(canvas, hover);
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(0xFF000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(InkLabCanvasPainter oldDelegate) {
    return oldDelegate._revision != _revision;
  }

  void _drawGrid(Canvas canvas, Size size) {
    final Paint grid = Paint()
      ..color = const Color(0xFFE8E8E8)
      ..strokeWidth = 1;
    for (double x = size.width / 4; x < size.width; x += size.width / 4) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = size.height / 4; y < size.height; y += size.height / 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
  }

  void _drawStroke(Canvas canvas, _InkStroke stroke) {
    if (stroke.points.isEmpty) {
      return;
    }
    if (stroke.points.length == 1) {
      final _InkPoint point = stroke.points.single;
      canvas.drawCircle(
        point.position,
        math.max(1, point.width / 2),
        Paint()..color = const Color(0xFF000000),
      );
      return;
    }
    for (int index = 1; index < stroke.points.length; index += 1) {
      final _InkPoint previous = stroke.points[index - 1];
      final _InkPoint current = stroke.points[index];
      canvas.drawLine(
        previous.position,
        current.position,
        Paint()
          ..color = const Color(0xFF000000)
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(1, (previous.width + current.width) / 2),
      );
    }
  }

  void _drawHover(Canvas canvas, Offset center) {
    final Paint outline = Paint()
      ..color = _isErasing ? const Color(0xFF000000) : const Color(0xFF555555)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, _isErasing ? 28 : 10, outline);
  }
}

final class _InkStroke {
  _InkStroke(this.points);

  final List<_InkPoint> points;
}

final class _InkPoint {
  const _InkPoint(this.position, this.width);

  final Offset position;
  final double width;
}

const TextStyle _titleStyle = TextStyle(
  color: Color(0xFF000000),
  fontSize: 34,
  fontWeight: FontWeight.w700,
  height: 1.1,
);

const TextStyle _readoutStyle = TextStyle(
  color: Color(0xFF111111),
  fontSize: 15,
  fontWeight: FontWeight.w500,
  height: 1.2,
);

const TextStyle _buttonStyle = TextStyle(
  color: Color(0xFF000000),
  fontSize: 14,
  fontWeight: FontWeight.w600,
  height: 1.4,
);

const TextStyle _buttonActiveStyle = TextStyle(
  color: Color(0xFFFFFFFF),
  fontSize: 14,
  fontWeight: FontWeight.w600,
  height: 1.4,
);
