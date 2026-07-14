// Renders a full-resolution (954x1696) marketing screenshot of the Ink editor
// with a crafted illustration on the canvas, and writes it to docs/img/. It is
// not a golden comparison: it is a one-shot capture, skipped unless
// CAPTURE_SHOWCASE=1 is set, so it never runs in ordinary CI.
//
//   CAPTURE_SHOWCASE=1 flutter test test_goldens/showcase_capture_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/ui/bench/bench.dart';
import 'package:paper_ink/src/ui/status_chips.dart';
import 'package:pluto_ui/pluto_ui.dart';

const Size _panel = Size(954, 1696);
const Key _sceneKey = ValueKey<String>('ink-showcase-scene');

void main() {
  final bool capture = Platform.environment['CAPTURE_SHOWCASE'] == '1';

  testWidgets('ink editor showcase', (WidgetTester tester) async {
    await _loadFonts();
    tester.view.physicalSize = _panel;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PaperTheme(
        data: const PaperThemeData(isColorPanel: true),
        child: WidgetsApp(
          color: const Color(0xffffffff),
          debugShowCheckedModeBanner: false,
          builder: (BuildContext context, Widget? _) => Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: _sceneKey,
              child: SizedBox(
                width: _panel.width,
                height: _panel.height,
                child: const ColoredBox(
                  color: Color(0xfffcfbf7),
                  child: _ShowcaseScene(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    if (!capture) {
      return;
    }
    final RenderRepaintBoundary boundary =
        tester.renderObject(find.byKey(_sceneKey)) as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final File out = _repoFile('docs/img/pluto-ink.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(png!.buffer.asUint8List());
    // ignore: avoid_print
    print('wrote ${out.path}');
  }, skip: !capture);

  testWidgets('ink mirror showcase', (WidgetTester tester) async {
    await _loadFonts();
    tester.view.physicalSize = _panel;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PaperTheme(
        data: const PaperThemeData(isColorPanel: true),
        child: WidgetsApp(
          color: const Color(0xffffffff),
          debugShowCheckedModeBanner: false,
          builder: (BuildContext context, Widget? _) => Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: _mirrorKey,
              child: SizedBox(
                width: _panel.width,
                height: _panel.height,
                child: const ColoredBox(
                  color: Color(0xfffcfbf7),
                  child: _MirrorScene(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    if (!capture) {
      return;
    }
    final RenderRepaintBoundary boundary =
        tester.renderObject(find.byKey(_mirrorKey)) as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final File out = _repoFile('docs/img/apps/ink-mirror.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(png!.buffer.asUint8List());
    // ignore: avoid_print
    print('wrote ${out.path}');
  }, skip: !capture);
}

const Key _mirrorKey = ValueKey<String>('ink-mirror-scene');

class _ShowcaseScene extends StatelessWidget {
  const _ShowcaseScene();

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      const CustomPaint(painter: _QuietHarbourPainter()),
      Align(
        alignment: Alignment.topCenter,
        child: InkEditorStatusBand(
          artworkName: 'quiet harbour',
          zoomPercent: 100,
          activeLayerName: 'ink',
          savePhase: InkSavePhase.saved,
          savedAt: DateTime(2026, 7, 13, 9, 41),
          heavyArtwork: false,
          onBack: () {},
          onArtworkPressed: () {},
          onZoomPressed: () {},
          onLayerPressed: () {},
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: inkStatusBandDesignHeight),
        child: Align(
          alignment: Alignment.centerLeft,
          child: InkBench(
            dock: InkBenchDock.left,
            collapsed: false,
            activeToolId: 'draw',
            activeBrush: finelinerBrush,
            brushSize: finelinerBrush.sizeDefault,
            brushFlow: 1,
            currentColor: const Color(0xff1d2733),
            activeLayerOrdinal: 1,
            canUndo: true,
            canRedo: false,
            onToggleCollapsed: () {},
            onToolSelected: (_) {},
            onBrushPressed: () {},
            onSizeChanged: (_) {},
            onFlowChanged: (_) {},
            onColorPressed: () {},
            onUndo: () {},
            onRedo: () {},
            onLayersPressed: () {},
            onMenuPressed: () {},
            onDockChanged: (_) {},
          ),
        ),
      ),
    ],
  );
}

/// A calm harbour at dusk, drawn in confident ink on the page — a lone sailboat,
/// its reflection, a low sun, distant hills, and a drift of birds.
class _QuietHarbourPainter extends CustomPainter {
  const _QuietHarbourPainter();

  static const Color _ink = Color(0xff1d2733);
  static const Color _soft = Color(0xff7d8794);

  @override
  void paint(Canvas canvas, Size size) {
    // The page: a hand-set sheet to the right of the bench, below the band.
    final Rect page = Rect.fromLTRB(232, 150, 906, 1548);
    final Paint pageFill = Paint()..color = const Color(0xffffffff);
    final Paint pageEdge = Paint()
      ..color = _soft
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final RRect pageR = RRect.fromRectAndRadius(page, const Radius.circular(6));
    canvas.drawRRect(pageR, pageFill);
    canvas.drawRRect(pageR, pageEdge);
    canvas.save();
    canvas.clipRRect(pageR);

    Paint stroke(double w, [Color c = _ink]) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path curve(List<Offset> pts) {
      final Path p = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (int i = 1; i < pts.length - 1; i++) {
        final Offset mid = Offset(
          (pts[i].dx + pts[i + 1].dx) / 2,
          (pts[i].dy + pts[i + 1].dy) / 2,
        );
        p.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
      }
      p.lineTo(pts.last.dx, pts.last.dy);
      return p;
    }

    const double cx = 569; // page horizontal centre
    const double horizon = 812;

    // The low sun, high enough to anchor the sky.
    const Offset sun = Offset(cx + 156, horizon - 300);
    canvas.drawCircle(sun, 104, stroke(3));
    for (int i = 0; i < 3; i++) {
      final double y = sun.dy - 36 + i * 36;
      canvas.drawLine(
        Offset(sun.dx - 66, y),
        Offset(sun.dx + 66, y),
        stroke(2.2, _soft),
      );
    }

    // A few drifting cloud strokes to fill the upper sky.
    for (final List<double> c in <List<double>>[
      <double>[300, 250, 150],
      <double>[360, 330, 190],
      <double>[300, 470, 120],
    ]) {
      final double y = c[0], x = c[1], w = c[2];
      canvas.drawPath(
        curve(<Offset>[
          Offset(x, y),
          Offset(x + w * 0.35, y - 14),
          Offset(x + w * 0.7, y),
          Offset(x + w, y - 8),
        ]),
        stroke(2, _soft),
      );
    }

    // Distant hills, layered.
    canvas.drawPath(
      curve(const <Offset>[
        Offset(232, horizon - 40),
        Offset(360, horizon - 118),
        Offset(470, horizon - 70),
        Offset(560, horizon - 132),
        Offset(690, horizon - 60),
        Offset(820, horizon - 110),
        Offset(906, horizon - 66),
      ]),
      stroke(2.6, _soft),
    );
    canvas.drawPath(
      curve(const <Offset>[
        Offset(232, horizon - 8),
        Offset(330, horizon - 54),
        Offset(452, horizon - 22),
        Offset(600, horizon - 74),
        Offset(742, horizon - 26),
        Offset(906, horizon - 52),
      ]),
      stroke(3),
    );

    // The waterline.
    canvas.drawLine(
      const Offset(232, horizon),
      const Offset(906, horizon),
      stroke(3),
    );

    // A drift of birds near the sun.
    void bird(Offset c, double s) {
      canvas.drawPath(
        curve(<Offset>[
          Offset(c.dx - s, c.dy),
          Offset(c.dx - s * 0.4, c.dy - s * 0.5),
          Offset(c.dx, c.dy),
          Offset(c.dx + s * 0.4, c.dy - s * 0.5),
          Offset(c.dx + s, c.dy),
        ]),
        stroke(2.4),
      );
    }

    bird(const Offset(cx - 150, 250), 28);
    bird(const Offset(cx - 88, 296), 22);
    bird(const Offset(cx - 202, 318), 18);
    bird(const Offset(cx + 6, 214), 18);
    bird(const Offset(cx - 250, 262), 14);

    // The sailboat: hull, mast, main and jib sails.
    const Offset keel = Offset(cx - 40, horizon);
    final Path hull = Path()
      ..moveTo(keel.dx - 118, horizon - 6)
      ..quadraticBezierTo(keel.dx, horizon + 64, keel.dx + 118, horizon - 6)
      ..close();
    canvas.drawPath(hull, stroke(3.4));
    canvas.drawLine(
      Offset(keel.dx, horizon - 6),
      Offset(keel.dx, horizon - 250),
      stroke(3),
    );
    // Mainsail.
    canvas.drawPath(
      Path()
        ..moveTo(keel.dx + 6, horizon - 244)
        ..quadraticBezierTo(
          keel.dx + 96,
          horizon - 150,
          keel.dx + 62,
          horizon - 18,
        )
        ..lineTo(keel.dx + 10, horizon - 18)
        ..close(),
      stroke(3),
    );
    // Jib.
    canvas.drawPath(
      Path()
        ..moveTo(keel.dx - 6, horizon - 232)
        ..quadraticBezierTo(
          keel.dx - 78,
          horizon - 120,
          keel.dx - 58,
          horizon - 18,
        )
        ..lineTo(keel.dx - 10, horizon - 18)
        ..close(),
      stroke(2.6),
    );

    // Reflection: broken horizontal dashes under the boat and sun.
    final Paint ripple = stroke(2.2, _soft);
    for (int i = 0; i < 9; i++) {
      final double y = horizon + 18 + i * 26.0;
      final double half = 150 - i * 9.0;
      canvas.drawLine(
        Offset(keel.dx - half, y),
        Offset(keel.dx - half + 60, y),
        ripple,
      );
      canvas.drawLine(
        Offset(keel.dx + 8, y),
        Offset(keel.dx + 8 + half * 0.5, y),
        ripple,
      );
      canvas.drawLine(
        Offset(sun.dx - 40, y + 6),
        Offset(sun.dx + 30, y + 6),
        ripple,
      );
    }

    // A near shoreline with grass tufts anchoring the foreground.
    canvas.drawPath(
      curve(const <Offset>[
        Offset(232, 1360),
        Offset(360, 1340),
        Offset(470, 1372),
        Offset(560, 1352),
      ]),
      stroke(2.6, _soft),
    );
    for (int i = 0; i < 7; i++) {
      final double x = 300 + i * 34.0;
      final double base = 1356 - (i.isEven ? 0 : 6);
      final double h = 92 - (i % 3) * 18;
      // Three blades per tuft, fanning out.
      canvas.drawPath(
        curve(<Offset>[
          Offset(x, base),
          Offset(x - 10, base - h * 0.7),
          Offset(x - 20, base - h),
        ]),
        stroke(2.4),
      );
      canvas.drawPath(
        curve(<Offset>[
          Offset(x, base),
          Offset(x + 2, base - h * 0.8),
          Offset(x + 4, base - h * 1.1),
        ]),
        stroke(2.4),
      );
      canvas.drawPath(
        curve(<Offset>[
          Offset(x, base),
          Offset(x + 12, base - h * 0.6),
          Offset(x + 24, base - h * 0.9),
        ]),
        stroke(2.4),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_QuietHarbourPainter oldDelegate) => false;
}

class _MirrorScene extends StatelessWidget {
  const _MirrorScene();

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      const CustomPaint(painter: _ButterflyPainter()),
      Align(
        alignment: Alignment.topCenter,
        child: InkEditorStatusBand(
          artworkName: 'monarch',
          zoomPercent: 100,
          activeLayerName: 'wings',
          savePhase: InkSavePhase.saved,
          savedAt: DateTime(2026, 7, 13, 10, 18),
          heavyArtwork: false,
          onBack: () {},
          onArtworkPressed: () {},
          onZoomPressed: () {},
          onLayerPressed: () {},
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: inkStatusBandDesignHeight),
        child: Align(
          alignment: Alignment.centerLeft,
          child: InkBench(
            dock: InkBenchDock.left,
            collapsed: false,
            activeToolId: 'guides',
            activeBrush: finelinerBrush,
            brushSize: finelinerBrush.sizeDefault,
            brushFlow: 1,
            currentColor: const Color(0xff1d2733),
            activeLayerOrdinal: 1,
            canUndo: true,
            canRedo: false,
            onToggleCollapsed: () {},
            onToolSelected: (_) {},
            onBrushPressed: () {},
            onSizeChanged: (_) {},
            onFlowChanged: (_) {},
            onColorPressed: () {},
            onUndo: () {},
            onRedo: () {},
            onLayersPressed: () {},
            onMenuPressed: () {},
            onDockChanged: (_) {},
          ),
        ),
      ),
    ],
  );
}

/// A monarch butterfly drawn once on the left and mirrored across the page's
/// vertical guide — a showcase of the symmetry (mirror) tool.
class _ButterflyPainter extends CustomPainter {
  const _ButterflyPainter();

  static const Color _ink = Color(0xff1d2733);
  static const Color _soft = Color(0xff7d8794);
  static const double _cx = 569; // page vertical axis

  @override
  void paint(Canvas canvas, Size size) {
    final Rect page = Rect.fromLTRB(232, 150, 906, 1548);
    final RRect pageR = RRect.fromRectAndRadius(page, const Radius.circular(6));
    canvas.drawRRect(pageR, Paint()..color = const Color(0xffffffff));
    canvas.drawRRect(
      pageR,
      Paint()
        ..color = _soft
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.save();
    canvas.clipRRect(pageR);

    Paint stroke(double w, [Color c = _ink]) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // The dashed vertical mirror guide.
    final Paint guide = stroke(2, _soft);
    for (double y = 190; y < 1500; y += 26) {
      canvas.drawLine(Offset(_cx, y), Offset(_cx, y + 14), guide);
    }
    // Guide handle at the top.
    canvas.drawRect(
      Rect.fromCenter(center: const Offset(_cx, 176), width: 30, height: 30),
      stroke(2, _soft),
    );
    canvas.drawLine(
      const Offset(_cx - 8, 176),
      const Offset(_cx + 8, 176),
      stroke(2, _soft),
    );

    // One half of the butterfly, drawn on the left; the canvas is then
    // mirrored to produce a pixel-exact right half.
    void half(Canvas c) {
      final Paint line = stroke(3.2);
      final Paint thin = stroke(2);
      // Upper wing.
      c.drawPath(
        Path()
          ..moveTo(560, 616)
          ..cubicTo(452, 548, 336, 566, 340, 664)
          ..cubicTo(344, 726, 452, 736, 556, 700)
          ..close(),
        line,
      );
      // Lower wing.
      c.drawPath(
        Path()
          ..moveTo(556, 716)
          ..cubicTo(470, 744, 404, 812, 442, 876)
          ..cubicTo(470, 920, 542, 872, 560, 792)
          ..close(),
        line,
      );
      // Wing veins and spots.
      c.drawPath(
        Path()
          ..moveTo(548, 648)
          ..cubicTo(470, 636, 410, 648, 372, 672),
        thin,
      );
      c.drawCircle(const Offset(408, 636), 20, thin);
      c.drawCircle(const Offset(398, 690), 10, thin);
      c.drawCircle(const Offset(474, 820), 13, thin);
      // Antenna.
      c.drawPath(
        Path()
          ..moveTo(562, 566)
          ..cubicTo(544, 520, 520, 500, 502, 494),
        stroke(2.4),
      );
      c.drawCircle(const Offset(500, 492), 6, line);
    }

    half(canvas);
    canvas.save();
    canvas.translate(2 * _cx, 0);
    canvas.scale(-1, 1);
    half(canvas);
    canvas.restore();

    // Center elements, on the axis, drawn once.
    canvas.drawCircle(const Offset(_cx, 578), 15, stroke(3.2));
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(_cx, 704), width: 26, height: 210),
      stroke(3.2),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ButterflyPainter oldDelegate) => false;
}

Future<void> _loadFonts() async {
  final Directory flutterRoot = _flutterRoot();
  final File testFont = _repoFile(
    'assets/test_fonts/JetBrainsMono-VariableFont_wght.ttf',
  );
  await (FontLoader('Inter')..addFont(
        _bytes(
          '${flutterRoot.path}/bin/cache/artifacts/material_fonts/'
          'Roboto-Regular.ttf',
        ),
      ))
      .load();
  await (FontLoader('Arial')..addFont(_bytes(testFont.path))).load();
  await (FontLoader('JetBrains Mono')..addFont(_bytes(testFont.path))).load();
}

Future<ByteData> _bytes(String path) async {
  final Uint8List data = File(path).readAsBytesSync();
  return ByteData.view(data.buffer);
}

Directory _flutterRoot() {
  Directory current = File(Platform.resolvedExecutable).parent;
  while (current.parent.path != current.path) {
    final File uiFont = File.fromUri(
      current.uri.resolve(
        'bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      ),
    );
    if (uiFont.existsSync()) {
      return current;
    }
    current = current.parent;
  }
  throw StateError('Cannot locate the Flutter SDK.');
}

File _repoFile(String relativePath) {
  Directory current = Directory.current.absolute;
  while (true) {
    final File marker = File.fromUri(
      current.uri.resolve('tools/pluto/pins/engine.version'),
    );
    if (marker.existsSync()) {
      return File.fromUri(current.uri.resolve(relativePath));
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Cannot locate the repository root.');
    }
    current = parent;
  }
}
