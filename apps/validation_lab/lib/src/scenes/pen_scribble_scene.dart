import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../lab_style.dart';
import '../scene.dart';

/// Fullscreen freehand canvas: pen latency and stroke clarity. Pen-up
/// triggers nothing in-app; the renderer settles on its own.
///
/// If no pointer input arrives within three seconds of scene entry, a
/// deterministic zigzag + spiral draws itself via simulated strokes at
/// realistic pen speed, so unattended recordings still exercise ink. Live
/// pointer input takes over whenever it is present: it pre-empts the idle
/// trigger and stops a running script for good.
final class PenScribbleScene extends StatefulWidget {
  /// Creates the pen-scribble scene.
  const PenScribbleScene({super.key});

  @override
  State<PenScribbleScene> createState() => _PenScribbleSceneState();
}

final class _PenScribbleSceneState extends State<PenScribbleScene>
    with SceneRestFreeze {
  /// Idle window after which the self-drawing script starts.
  static const Duration _autoDrawDelay = Duration(seconds: 3);

  /// Simulated pen sample period (25 Hz).
  static const Duration _autoDrawTick = Duration(milliseconds: 40);

  /// Scripted pen speed in logical px/s; with [_autoDrawTick] this spaces
  /// samples ~19 px apart, a deliberate handwriting pace.
  static const double _autoDrawSpeed = 480;

  /// Pen-up dwell between scripted strokes, in ticks (~400 ms).
  static const int _autoDrawGapTicks = 10;

  final List<List<Offset>> _strokes = <List<Offset>>[];
  List<Offset>? _activeStroke;
  int _revision = 0;

  /// Canvas size captured at layout time; the script is scaled to it.
  Size _canvasSize = Size.zero;

  Timer? _idleTimer;
  Timer? _autoTimer;
  bool _liveInputSeen = false;

  List<List<Offset>> _script = const <List<Offset>>[];
  int _scriptStroke = 0;
  int _scriptPoint = 0;
  int _gapTicks = 0;

  @override
  void initState() {
    super.initState();
    _idleTimer = Timer(_autoDrawDelay, _startAutoDraw);
  }

  @override
  void freezeForRest() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _autoTimer?.cancel();
    super.dispose();
  }

  /// Ink source readout: LIVE once a pointer has drawn, AUTO while the
  /// script runs, DONE after it completes, IDLE while waiting.
  String get _inkMode {
    if (_liveInputSeen) {
      return 'LIVE';
    }
    if (_autoTimer != null) {
      return 'AUTO';
    }
    return _script.isEmpty ? 'IDLE' : 'DONE';
  }

  void _startAutoDraw() {
    _idleTimer = null;
    if (_liveInputSeen || _canvasSize.isEmpty) {
      return;
    }
    _script = _buildAutoScript(_canvasSize);
    _scriptStroke = 0;
    _scriptPoint = 0;
    _gapTicks = 0;
    _autoTimer = Timer.periodic(_autoDrawTick, _stepAutoDraw);
    // Repaint the INK readout only; the canvas is untouched so far.
    setState(() {});
  }

  void _stepAutoDraw(Timer timer) {
    if (_gapTicks > 0) {
      _gapTicks -= 1;
      return;
    }
    if (_scriptStroke >= _script.length) {
      timer.cancel();
      _autoTimer = null;
      // Repaint the INK readout only; the drawing is complete.
      setState(() {});
      return;
    }
    final List<Offset> stroke = _script[_scriptStroke];
    setState(() {
      if (_scriptPoint == 0) {
        _activeStroke = <Offset>[stroke.first];
        _strokes.add(_activeStroke!);
      } else {
        _activeStroke!.add(stroke[_scriptPoint]);
      }
      _revision += 1;
      _scriptPoint += 1;
      if (_scriptPoint >= stroke.length) {
        // Pen up between scripted strokes.
        _activeStroke = null;
        _scriptStroke += 1;
        _scriptPoint = 0;
        _gapTicks = _autoDrawGapTicks;
      }
    });
  }

  /// A live pointer takes over: the idle trigger and any running script
  /// are cancelled and never re-arm for this scene instance.
  void _takeOverFromScript() {
    _liveInputSeen = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _autoTimer?.cancel();
    _autoTimer = null;
    _activeStroke = null;
  }

  void _handleDown(PointerDownEvent event) {
    setState(() {
      _takeOverFromScript();
      _activeStroke = <Offset>[event.localPosition];
      _strokes.add(_activeStroke!);
      _revision += 1;
    });
  }

  void _handleMove(PointerMoveEvent event) {
    final List<Offset>? stroke = _activeStroke;
    if (stroke == null) {
      return;
    }
    setState(() {
      stroke.add(event.localPosition);
      _revision += 1;
    });
  }

  void _handleUp(PointerUpEvent event) {
    setState(() {
      _activeStroke = null;
      _revision += 1;
    });
  }

  void _clear() {
    setState(() {
      _strokes.clear();
      _activeStroke = null;
      _revision += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _handleDown,
            onPointerMove: _handleMove,
            onPointerUp: _handleUp,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                _canvasSize = constraints.biggest;
                return RepaintBoundary(
                  child: CustomPaint(
                    painter: _ScribblePainter(
                      strokes: _strokes,
                      revision: _revision,
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          left: 16,
          top: 12,
          child: IgnorePointer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('PEN SCRIBBLE', style: labHeadingStyle),
                const Text(
                  'DRAW ANYWHERE — LATENCY + STROKE CLARITY',
                  style: labCaptionStyle,
                ),
                const Text(
                  'IDLE 3 S → SELF-DRAWING ZIGZAG + SPIRAL',
                  style: labCaptionStyle,
                ),
                Text(
                  'STROKES ${_strokes.length.toString().padLeft(3, '0')} '
                  'INK $_inkMode',
                  style: labMonoStyle,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: LabCornerButton(label: 'CLEAR', onPressed: _clear),
        ),
      ],
    );
  }
}

/// Builds the deterministic self-drawing script for a canvas of [size]:
/// a zigzag band across the upper canvas, then a 2.5-turn spiral below
/// it. Pure function of the size — no randomness, no wall clock.
List<List<Offset>> _buildAutoScript(Size size) {
  final double step =
      _PenScribbleSceneState._autoDrawSpeed *
      _PenScribbleSceneState._autoDrawTick.inMilliseconds /
      1000;

  final double left = size.width * 0.12;
  final double right = size.width * 0.88;
  final double zigTop = size.height * 0.20;
  final double zigBottom = size.height * 0.42;
  const int zigSegments = 6;
  final List<Offset> zigzag = <Offset>[
    for (int i = 0; i <= zigSegments; i += 1)
      Offset(
        left + (right - left) * i / zigSegments,
        i.isEven ? zigTop : zigBottom,
      ),
  ];

  final Offset spiralCenter = Offset(size.width / 2, size.height * 0.66);
  final double spiralRadius = math.min(size.width, size.height * 0.5) * 0.34;
  const double turns = 2.5;
  const int spiralSamples = 220;
  final List<Offset> spiral = <Offset>[
    for (int i = 0; i <= spiralSamples; i += 1)
      spiralCenter +
          Offset.fromDirection(
            -math.pi / 2 + turns * 2 * math.pi * i / spiralSamples,
            spiralRadius * i / spiralSamples,
          ),
  ];

  return <List<Offset>>[_resample(zigzag, step), _resample(spiral, step)];
}

/// Resamples a polyline to points spaced [step] px apart along the path,
/// keeping the exact endpoints, so one point per tick yields a constant
/// pen speed.
List<Offset> _resample(List<Offset> points, double step) {
  final List<Offset> resampled = <Offset>[points.first];
  double carry = 0;
  for (int i = 1; i < points.length; i += 1) {
    Offset from = points[i - 1];
    final Offset to = points[i];
    double segment = (to - from).distance;
    while (carry + segment >= step) {
      final Offset sample = Offset.lerp(from, to, (step - carry) / segment)!;
      resampled.add(sample);
      from = sample;
      segment = (to - sample).distance;
      carry = 0;
    }
    carry += segment;
  }
  if (resampled.last != points.last) {
    resampled.add(points.last);
  }
  return resampled;
}

final class _ScribblePainter extends CustomPainter {
  const _ScribblePainter({required this.strokes, required this.revision});

  final List<List<Offset>> strokes;

  /// Monotonic edit counter; the stroke lists are mutated in place, so this
  /// is what invalidates the painter.
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = labPaper);
    final Paint inkStroke = Paint()
      ..color = labInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final List<Offset> stroke in strokes) {
      if (stroke.length == 1) {
        canvas.drawCircle(stroke.first, 1.5, Paint()..color = labInk);
        continue;
      }
      final Path path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (final Offset point in stroke.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, inkStroke);
    }
  }

  @override
  bool shouldRepaint(_ScribblePainter oldDelegate) {
    return oldDelegate.revision != revision;
  }
}
