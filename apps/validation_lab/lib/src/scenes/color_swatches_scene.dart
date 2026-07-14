import 'dart:async';

import 'package:flutter/widgets.dart';

import '../lab_style.dart';
import '../scene.dart';

const List<(String, Color)> _saturatedSwatches = <(String, Color)>[
  ('RED', Color(0xFFFF0000)),
  ('GREEN', Color(0xFF00FF00)),
  ('BLUE', Color(0xFF0000FF)),
  ('YELLOW', Color(0xFFFFFF00)),
  ('MAGENTA', Color(0xFFFF00FF)),
  ('CYAN', Color(0xFF00FFFF)),
];

const List<(String, Color)> _pastelSwatches = <(String, Color)>[
  ('P-RED', Color(0xFFF6C1C1)),
  ('P-GRN', Color(0xFFC9E8CB)),
  ('P-BLU', Color(0xFFC2DCF5)),
  ('P-YEL', Color(0xFFF7F2C0)),
  ('P-MAG', Color(0xFFEBCBEE)),
  ('P-CYN', Color(0xFFC5EEF2)),
];

const List<(String, Color)> _blinkSwatches = <(String, Color)>[
  ('BLINK-1', Color(0xFFFF8000)),
  ('BLINK-2', Color(0xFF8000FF)),
  ('BLINK-3', Color(0xFF80FF00)),
  ('BLINK-4', Color(0xFFFF0080)),
];

const List<(String, Color)> _colorTextLines = <(String, Color)>[
  ('COLOR TEXT — RED CHANNEL', Color(0xFFCC0000)),
  ('COLOR TEXT — GREEN CHANNEL', Color(0xFF007700)),
  ('COLOR TEXT — BLUE CHANNEL', Color(0xFF0000CC)),
];

/// Saturated and pastel patches that appear and disappear: chroma settles.
final class ColorSwatchesScene extends StatefulWidget {
  /// Creates the color-swatches scene.
  const ColorSwatchesScene({super.key});

  @override
  State<ColorSwatchesScene> createState() => _ColorSwatchesSceneState();
}

final class _ColorSwatchesSceneState extends State<ColorSwatchesScene>
    with SceneRestFreeze {
  static const Duration _stepPeriod = Duration(seconds: 2);

  Timer? _timer;
  int _step = 0;

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
    return Column(
      children: <Widget>[
        const SceneHeader(title: 'COLOR SWATCHES', purpose: 'CHROMA SETTLES'),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Expanded(child: _SwatchRow(swatches: _saturatedSwatches)),
                const SizedBox(height: 8),
                const Expanded(child: _SwatchRow(swatches: _pastelSwatches)),
                const SizedBox(height: 8),
                Expanded(child: _BlinkRow(visible: _step.isEven)),
                const SizedBox(height: 12),
                for (final (String label, Color color) in _colorTextLines)
                  Text(label, style: labHeadingStyle.copyWith(color: color)),
                const SizedBox(height: 8),
                Text(
                  'STEP ${_step.toString().padLeft(3, '0')} — '
                  'BLINK TILES SHOW ON EVEN STEPS',
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

final class _SwatchRow extends StatelessWidget {
  const _SwatchRow({required this.swatches});

  final List<(String, Color)> swatches;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final (String label, Color color) in swatches)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: color,
                        border: labRuleBorder,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: labCaptionStyle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

final class _BlinkRow extends StatelessWidget {
  const _BlinkRow({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final (String label, Color color) in _blinkSwatches)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: visible ? color : labPaper,
                        border: visible
                            ? labRuleBorder
                            : const Border.fromBorderSide(
                                BorderSide(width: 1, color: labGrayMid),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    visible ? label : '—',
                    style: labCaptionStyle,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
