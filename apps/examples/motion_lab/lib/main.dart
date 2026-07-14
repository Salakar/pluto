import 'dart:math' as math;

import 'package:flutter/widgets.dart';

void main() {
  runApp(const MotionLabApp());
}

const Key motionFrameReadoutKey = Key('motion-frame-readout');

class MotionLabApp extends StatelessWidget {
  const MotionLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: const Color(0xFFFFFFFF),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: _pageRouteBuilder,
      title: 'Motion Lab',
      home: const _MotionLabScreen(),
    );
  }
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

class _MotionLabScreen extends StatefulWidget {
  const _MotionLabScreen();

  @override
  State<_MotionLabScreen> createState() => _MotionLabScreenState();
}

class _MotionLabScreenState extends State<_MotionLabScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _loopDuration = Duration(milliseconds: 2400);
  static const Duration _rateWindow = Duration(milliseconds: 500);

  late final AnimationController _controller;
  int _frameCount = 0;
  int _lastRateFrame = 0;
  double _updatesPerSecond = 0;
  Duration _lastRateSample = Duration.zero;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _loopDuration)
      ..addListener(_handleTick)
      ..repeat();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleTick)
      ..dispose();
    super.dispose();
  }

  void _handleTick() {
    final Duration elapsed = _controller.lastElapsedDuration ?? Duration.zero;
    _frameCount += 1;
    final Duration sampleDelta = elapsed - _lastRateSample;
    if (sampleDelta >= _rateWindow) {
      final int frameDelta = _frameCount - _lastRateFrame;
      _updatesPerSecond = frameDelta * 1000 / sampleDelta.inMilliseconds;
      _lastRateFrame = _frameCount;
      _lastRateSample = elapsed;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final int phase = (_controller.value * 24).floor() % 24;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Column(
          children: <Widget>[
            _MotionHud(
              phase: phase,
              frameCount: _frameCount,
              updatesPerSecond: _updatesPerSecond,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    border: Border.fromBorderSide(BorderSide(width: 2)),
                  ),
                  child: CustomPaint(
                    painter: _MotionPainter(
                      phase: phase,
                      frameCount: _frameCount,
                    ),
                    child: const SizedBox.expand(),
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

class _MotionHud extends StatelessWidget {
  const _MotionHud({
    required this.phase,
    required this.frameCount,
    required this.updatesPerSecond,
  });

  final int phase;
  final int frameCount;
  final double updatesPerSecond;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Row(
        children: <Widget>[
          const Expanded(child: Text('Motion Lab', style: _titleStyle)),
          Text(
            'Phase $phase  Frames $frameCount  Rate '
            '${updatesPerSecond.toStringAsFixed(1)} Hz',
            key: motionFrameReadoutKey,
            textAlign: TextAlign.right,
            style: _readoutStyle,
          ),
        ],
      ),
    );
  }
}

class _MotionPainter extends CustomPainter {
  const _MotionPainter({required this.phase, required this.frameCount});

  final int phase;
  final int frameCount;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );

    _drawMovingStripeField(canvas, size);
    _drawBouncer(canvas, size);
    _drawProgressDial(canvas, size);
    _drawDiscretePages(canvas, size);
  }

  void _drawMovingStripeField(Canvas canvas, Size size) {
    final double stripeWidth = math.max(10, size.width / 34);
    final double offset = (phase % 8) * stripeWidth;
    final Paint light = Paint()..color = const Color(0xFFE8E8E8);
    final Paint dark = Paint()..color = const Color(0xFFBABABA);
    for (
      double x = -offset;
      x < size.width + stripeWidth;
      x += stripeWidth * 2
    ) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, stripeWidth, size.height),
        phase.isEven ? light : dark,
      );
    }
  }

  void _drawBouncer(Canvas canvas, Size size) {
    final double trackY = size.height * 0.34;
    final double trackLeft = size.width * 0.10;
    final double trackRight = size.width * 0.90;
    final int bounceStep = phase <= 12 ? phase : 24 - phase;
    final double t = bounceStep / 12;
    final double x = trackLeft + (trackRight - trackLeft) * t;
    final double side = math.max(42, math.min(size.width, size.height) * 0.10);
    final Paint trackPaint = Paint()
      ..color = const Color(0xFF111111)
      ..strokeWidth = 3;
    canvas.drawLine(
      Offset(trackLeft, trackY + side),
      Offset(trackRight, trackY + side),
      trackPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, trackY), width: side, height: side),
        const Radius.circular(6),
      ),
      Paint()..color = const Color(0xFF000000),
    );
  }

  void _drawProgressDial(Canvas canvas, Size size) {
    final Offset center = Offset(size.width * 0.22, size.height * 0.72);
    final double radius = math.min(size.width, size.height) * 0.15;
    final Paint inactive = Paint()
      ..color = const Color(0xFFD0D0D0)
      ..strokeCap = StrokeCap.square
      ..strokeWidth = math.max(4, radius * 0.10);
    final Paint active = Paint()
      ..color = const Color(0xFF000000)
      ..strokeCap = StrokeCap.square
      ..strokeWidth = inactive.strokeWidth;
    for (int index = 0; index < 16; index += 1) {
      final double angle = -math.pi / 2 + index * math.pi * 2 / 16;
      final Offset inner = center + Offset.fromDirection(angle, radius * 0.72);
      final Offset outer = center + Offset.fromDirection(angle, radius);
      canvas.drawLine(inner, outer, index <= phase % 16 ? active : inactive);
    }
  }

  void _drawDiscretePages(Canvas canvas, Size size) {
    final double left = size.width * 0.45;
    final double top = size.height * 0.58;
    final double width = size.width * 0.40;
    final double height = size.height * 0.26;
    final Paint border = Paint()
      ..color = const Color(0xFF111111)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final Rect page = Rect.fromLTWH(left, top, width, height);
    canvas.drawRect(page, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawRect(page, border);

    final int pagePhase = phase % 3;
    final Paint ink = Paint()..color = const Color(0xFF000000);
    final Paint gray = Paint()..color = const Color(0xFF8F8F8F);
    for (int line = 0; line < 6; line += 1) {
      final double y = top + 24 + line * (height - 42) / 5;
      final double lineWidth = width * (0.35 + ((line + pagePhase) % 3) * 0.18);
      canvas.drawRect(
        Rect.fromLTWH(left + 22, y, lineWidth, 5),
        line.isEven ? ink : gray,
      );
    }

    final double shutterWidth = width * (pagePhase + 1) / 3;
    canvas.drawRect(
      Rect.fromLTWH(left, top, shutterWidth, height),
      Paint()..color = const Color(0xFFE2E2E2),
    );
    canvas.drawRect(page, border);
  }

  @override
  bool shouldRepaint(_MotionPainter oldDelegate) {
    return oldDelegate.phase != phase || oldDelegate.frameCount != frameCount;
  }
}

const TextStyle _titleStyle = TextStyle(
  color: Color(0xFF000000),
  fontSize: 34,
  fontWeight: FontWeight.w700,
  height: 1.1,
);

const TextStyle _readoutStyle = TextStyle(
  color: Color(0xFF111111),
  fontSize: 17,
  fontWeight: FontWeight.w500,
  height: 1.2,
);
