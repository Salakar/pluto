import 'dart:async';

import 'package:flutter/widgets.dart';

import '../lab_style.dart';
import '../scene.dart';

const TextStyle _tortureTextStyle = TextStyle(
  fontFamily: 'JetBrains Mono',
  fontFamilyFallback: <String>['Menlo', 'Courier', 'monospace'],
  fontSize: 18,
  height: 1.3,
  fontWeight: FontWeight.w600,
);

/// Alternating checkerboard and inverse text blocks that then clear to
/// white: ghost visibility and debt-driven clears.
final class GhostTortureScene extends StatefulWidget {
  /// Creates the ghost-torture scene.
  const GhostTortureScene({super.key});

  @override
  State<GhostTortureScene> createState() => _GhostTortureSceneState();
}

final class _GhostTortureSceneState extends State<GhostTortureScene>
    with SceneRestFreeze {
  static const Duration _stepPeriod = Duration(milliseconds: 800);
  static const int _tortureSteps = 10;
  static const int _cycleSteps = 15;

  Timer? _timer;
  int _step = 0;

  int get _cycleStep => _step % _cycleSteps;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_stepPeriod, (Timer timer) {
      setState(() {
        _step += 1;
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
    final bool isClearPhase = _cycleStep >= _tortureSteps;
    return Column(
      children: <Widget>[
        const SceneHeader(title: 'GHOST TORTURE', purpose: 'DEBT CLEARS'),
        Expanded(
          child: isClearPhase
              ? _WhiteHold(second: _cycleStep - _tortureSteps + 1)
              : _TortureBoard(step: _step),
        ),
      ],
    );
  }
}

final class _TortureBoard extends StatelessWidget {
  const _TortureBoard({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          flex: 3,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _CheckerboardPainter(inverted: step.isOdd),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Column(
            children: <Widget>[
              for (int row = 0; row < 4; row += 1)
                Expanded(child: _TortureTextRow(inverted: (step + row).isOdd)),
            ],
          ),
        ),
      ],
    );
  }
}

final class _TortureTextRow extends StatelessWidget {
  const _TortureTextRow({required this.inverted});

  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      color: inverted ? labInk : labPaper,
      child: Text(
        'GHOST TORTURE 0123456789 ABCDEF',
        style: _tortureTextStyle.copyWith(color: inverted ? labPaper : labInk),
      ),
    );
  }
}

final class _WhiteHold extends StatelessWidget {
  const _WhiteHold({required this.second});

  final int second;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: labPaper,
      child: SizedBox.expand(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('WHITE HOLD $second/5', style: labCaptionStyle),
          ),
        ),
      ),
    );
  }
}

final class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter({required this.inverted});

  final bool inverted;

  static const double _cell = 40;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint ink = Paint()..color = labInk;
    final Paint paper = Paint()..color = labPaper;
    final int columns = (size.width / _cell).ceil();
    final int rows = (size.height / _cell).ceil();
    for (int row = 0; row < rows; row += 1) {
      for (int column = 0; column < columns; column += 1) {
        final bool isInk = (row + column).isEven != inverted;
        canvas.drawRect(
          Rect.fromLTWH(column * _cell, row * _cell, _cell, _cell),
          isInk ? ink : paper,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerboardPainter oldDelegate) {
    return oldDelegate.inverted != inverted;
  }
}
