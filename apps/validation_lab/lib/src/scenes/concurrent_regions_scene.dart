import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../lab_style.dart';
import '../scene.dart';

const TextStyle _fastTickStyle = TextStyle(
  fontFamily: 'JetBrains Mono',
  fontFamilyFallback: <String>['Menlo', 'Courier', 'monospace'],
  fontSize: 56,
  height: 1.1,
  fontWeight: FontWeight.w700,
  color: labInk,
);

/// A fast ticking region and a slow high-quality image region updating
/// independently: the engine's concurrent-update headline.
final class ConcurrentRegionsScene extends StatelessWidget {
  /// Creates the concurrent-regions scene.
  const ConcurrentRegionsScene({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: <Widget>[
        SceneHeader(title: 'CONCURRENT REGIONS', purpose: 'FAST + HQ'),
        Expanded(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: _FastRegion()),
                SizedBox(width: 12),
                Expanded(child: _SlowRegion()),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _FastRegion extends StatefulWidget {
  const _FastRegion();

  @override
  State<_FastRegion> createState() => _FastRegionState();
}

final class _FastRegionState extends State<_FastRegion> with SceneRestFreeze {
  static const Duration _tickPeriod = Duration(milliseconds: 250);

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
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(border: labBorder),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('FAST — 4 HZ TICKS', style: labCaptionStyle),
            const SizedBox(height: 12),
            Text(
              'T=${_tick.toString().padLeft(4, '0')}',
              style: _fastTickStyle,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              width: double.infinity,
              child: CustomPaint(
                painter: _SlidingBlockPainter(slot: _tick % 12),
              ),
            ),
            const Spacer(),
            const Text(
              'EVERY 250 MS THIS REGION MUTATES; THE HQ REGION MUST NOT '
              'STALL IT, NOR BE DRAGGED DOWN BY IT.',
              style: labCaptionStyle,
            ),
          ],
        ),
      ),
    );
  }
}

final class _SlowRegion extends StatefulWidget {
  const _SlowRegion();

  @override
  State<_SlowRegion> createState() => _SlowRegionState();
}

final class _SlowRegionState extends State<_SlowRegion> with SceneRestFreeze {
  static const Duration _imagePeriod = Duration(seconds: 5);

  Timer? _timer;
  int _imageIndex = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_imagePeriod, (Timer timer) {
      setState(() {
        _imageIndex += 1;
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
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(border: labBorder),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('SLOW — HQ IMAGE EVERY 5 S', style: labCaptionStyle),
            const SizedBox(height: 12),
            Expanded(
              child: ClipRect(
                child: CustomPaint(
                  painter: _PseudoPhotoPainter(variant: _imageIndex),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'IMG ${_imageIndex.toString().padLeft(3, '0')}',
              style: labMonoStyle,
            ),
          ],
        ),
      ),
    );
  }
}

final class _SlidingBlockPainter extends CustomPainter {
  const _SlidingBlockPainter({required this.slot});

  final int slot;

  static const int _slots = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final double slotWidth = size.width / _slots;
    final Paint outline = Paint()
      ..color = labInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final Paint fill = Paint()..color = labInk;
    for (int index = 0; index < _slots; index += 1) {
      final Rect cell = Rect.fromLTWH(
        index * slotWidth,
        0,
        slotWidth,
        size.height,
      ).deflate(2);
      canvas.drawRect(cell, index == slot ? fill : outline);
    }
  }

  @override
  bool shouldRepaint(_SlidingBlockPainter oldDelegate) {
    return oldDelegate.slot != slot;
  }
}

/// Deterministic "photo": layered dusk landscape whose composition is a
/// pure function of [variant]. No randomness, no wall clock.
final class _PseudoPhotoPainter extends CustomPainter {
  const _PseudoPhotoPainter({required this.variant});

  final int variant;

  static const List<(Color, Color, Color)> _skyPalettes =
      <(Color, Color, Color)>[
        (Color(0xFFFFE0B2), Color(0xFF90CAF9), Color(0xFFFF8F00)),
        (Color(0xFFF8BBD0), Color(0xFFB39DDB), Color(0xFFD84315)),
        (Color(0xFFB2DFDB), Color(0xFF80CBC4), Color(0xFFFFB300)),
        (Color(0xFFCFD8DC), Color(0xFF90A4AE), Color(0xFFEF6C00)),
      ];

  static const List<double> _farPeaks = <double>[
    0.55,
    0.30,
    0.48,
    0.22,
    0.42,
    0.35,
    0.52,
  ];

  static const List<double> _nearPeaks = <double>[0.75, 0.52, 0.68, 0.46, 0.7];

  @override
  void paint(Canvas canvas, Size size) {
    final int v = variant % _skyPalettes.length;
    final (Color skyTop, Color skyBottom, Color sun) = _skyPalettes[v];
    final double horizon = size.height * 0.62;

    // Sky.
    final Rect skyRect = Rect.fromLTWH(0, 0, size.width, horizon);
    canvas.drawRect(
      skyRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[skyTop, skyBottom],
        ).createShader(skyRect),
    );

    // Sun placement varies per variant.
    canvas.drawCircle(
      Offset(size.width * (0.22 + v * 0.18), size.height * 0.2),
      size.shortestSide * 0.09,
      Paint()..color = sun,
    );

    // Mountain ranges (vertical scale varies per variant).
    _drawRange(
      canvas,
      size,
      peaks: _farPeaks,
      baseline: horizon,
      scale: 0.55 + v * 0.06,
      paint: Paint()..color = const Color(0xFF607D8B),
    );
    _drawRange(
      canvas,
      size,
      peaks: _nearPeaks,
      baseline: horizon,
      scale: 0.34 + v * 0.04,
      paint: Paint()..color = const Color(0xFF37474F),
    );

    // Water with deterministic dither lines.
    canvas.drawRect(
      Rect.fromLTWH(0, horizon, size.width, size.height - horizon),
      Paint()..color = const Color(0xFF78909C),
    );
    final Paint ripple = Paint()
      ..color = const Color(0xFF455A64)
      ..strokeWidth = 2;
    int rowIndex = 0;
    for (double y = horizon + 6; y < size.height; y += 8) {
      if ((rowIndex + v) % 3 != 0) {
        final double inset = 4 + (rowIndex % 5) * (size.width * 0.04);
        canvas.drawLine(
          Offset(inset, y),
          Offset(size.width - inset, y),
          ripple,
        );
      }
      rowIndex += 1;
    }
  }

  void _drawRange(
    Canvas canvas,
    Size size, {
    required List<double> peaks,
    required double baseline,
    required double scale,
    required Paint paint,
  }) {
    final Path path = Path()..moveTo(0, baseline);
    for (int index = 0; index < peaks.length; index += 1) {
      final double x = size.width * (index + 0.5) / peaks.length;
      final double y = baseline - baseline * peaks[index] * scale;
      path.lineTo(x, math.max(y, 0));
    }
    path
      ..lineTo(size.width, baseline)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_PseudoPhotoPainter oldDelegate) {
    return oldDelegate.variant != variant;
  }
}
