import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../lab_style.dart';
import '../scene.dart';

const TextStyle _counterStyle = TextStyle(
  fontFamily: 'JetBrains Mono',
  fontFamilyFallback: <String>['Menlo', 'Courier', 'monospace'],
  fontSize: 140,
  height: 1.1,
  fontWeight: FontWeight.w700,
  color: labInk,
);

/// Large counter incrementing at 2 Hz with a small spinner: partial updates.
final class CounterTickScene extends StatefulWidget {
  /// Creates the counter-tick scene.
  const CounterTickScene({super.key});

  @override
  State<CounterTickScene> createState() => _CounterTickSceneState();
}

final class _CounterTickSceneState extends State<CounterTickScene>
    with SceneRestFreeze {
  static const Duration _tickPeriod = Duration(milliseconds: 500);

  Timer? _timer;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_tickPeriod, (Timer timer) {
      setState(() {
        _tick += 1;
      });
    });
  }

  @override
  void freezeForRest() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const SceneHeader(title: 'COUNTER TICK', purpose: '2 HZ PARTIAL'),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                RepaintBoundary(
                  child: Text(
                    _tick.toString().padLeft(4, '0'),
                    style: _counterStyle,
                  ),
                ),
                const SizedBox(height: 24),
                RepaintBoundary(
                  child: CustomPaint(
                    size: const Size(72, 72),
                    painter: _TickSpinnerPainter(step: _tick),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'TICKS ${_tick.toString().padLeft(4, '0')} @ 2 HZ',
                  style: labCaptionStyle,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _TickSpinnerPainter extends CustomPainter {
  const _TickSpinnerPainter({required this.step});

  final int step;

  static const int _spokes = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = size.shortestSide / 2;
    final Paint inactive = Paint()
      ..color = labGrayMid
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square;
    final Paint active = Paint()
      ..color = labInk
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.square;
    for (int spoke = 0; spoke < _spokes; spoke += 1) {
      final double angle = -math.pi / 2 + spoke * 2 * math.pi / _spokes;
      final Offset inner = center + Offset.fromDirection(angle, radius * 0.55);
      final Offset outer = center + Offset.fromDirection(angle, radius);
      canvas.drawLine(
        inner,
        outer,
        spoke == step % _spokes ? active : inactive,
      );
    }
  }

  @override
  bool shouldRepaint(_TickSpinnerPainter oldDelegate) {
    return oldDelegate.step != step;
  }
}
