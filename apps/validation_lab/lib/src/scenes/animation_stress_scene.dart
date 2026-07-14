import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../lab_style.dart';
import '../scene.dart';

/// Bouncing ball, rotating square, and progress bar running concurrently
/// for eight seconds, then four seconds of rest: refresh-class behavior
/// under sustained motion, then sharpen.
final class AnimationStressScene extends StatefulWidget {
  /// Creates the animation-stress scene.
  const AnimationStressScene({super.key});

  @override
  State<AnimationStressScene> createState() => _AnimationStressSceneState();
}

final class _AnimationStressSceneState extends State<AnimationStressScene>
    with SingleTickerProviderStateMixin, SceneRestFreeze {
  static const Duration _motionDuration = Duration(seconds: 8);
  static const Duration _restDuration = Duration(seconds: 4);

  late final AnimationController _controller;
  Timer? _restTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _motionDuration)
      ..addStatusListener(_handleStatus);
    _controller.forward();
  }

  @override
  void freezeForRest() {
    _restTimer?.cancel();
    _restTimer = null;
    _controller.stop();
  }

  @override
  void dispose() {
    _restTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _handleStatus(AnimationStatus status) {
    if (!mounted || status != AnimationStatus.completed) {
      return;
    }
    setState(() {});
    _restTimer = Timer(_restDuration, () {
      if (!mounted) {
        return;
      }
      _controller.forward(from: 0);
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isMoving = _controller.isAnimating;
    return Column(
      children: <Widget>[
        const SceneHeader(title: 'ANIMATION STRESS', purpose: 'MOTION + REST'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              isMoving
                  ? 'PHASE MOTION — BALL + SPIN + BAR (8 S)'
                  : 'PHASE REST — SHARPEN (4 S)',
              style: labCaptionStyle,
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: DecoratedBox(
              decoration: const BoxDecoration(border: labRuleBorder),
              child: ClipRect(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _StressPainter(animation: _controller),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Triangle wave in [0, 1] with period 1.
double _triangleWave(double x) {
  final double fraction = x - x.floorToDouble();
  return fraction < 0.5 ? fraction * 2 : (1 - fraction) * 2;
}

final class _StressPainter extends CustomPainter {
  _StressPainter({required this.animation}) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = animation.value;
    canvas.drawRect(Offset.zero & size, Paint()..color = labPaper);

    // Bouncing ball in the top half.
    final double ballX = 48 + _triangleWave(t * 3) * (size.width - 96);
    final double ballY = 48 + _triangleWave(t * 5) * (size.height * 0.5 - 96);
    canvas.drawCircle(Offset(ballX, ballY), 28, Paint()..color = labInk);

    // Rotating square below center.
    final Offset squareCenter = Offset(size.width * 0.5, size.height * 0.7);
    final double side = size.shortestSide * 0.18;
    canvas.save();
    canvas.translate(squareCenter.dx, squareCenter.dy);
    canvas.rotate(t * 2 * math.pi * 4);
    canvas.drawRect(
      Rect.fromCenter(center: Offset.zero, width: side, height: side),
      Paint()..color = labInk,
    );
    canvas.restore();

    // Progress bar along the bottom.
    final Rect track = Rect.fromLTWH(24, size.height - 64, size.width - 48, 32);
    canvas.drawRect(
      track,
      Paint()
        ..color = labInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        track.left + 4,
        track.top + 4,
        (track.width - 8) * t,
        track.height - 8,
      ),
      Paint()..color = labInk,
    );
  }

  @override
  bool shouldRepaint(_StressPainter oldDelegate) => false;
}
