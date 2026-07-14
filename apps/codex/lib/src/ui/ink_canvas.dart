import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../ink_render.dart';
import '../models.dart';
import '../paper/layout.dart';
import '../paper/theme.dart';

/// Captures pen strokes over the handwriting composer band and paints the
/// draft. Stylus draws on-device; mouse remains available for host preview.
/// Touch never lays ink: that keeps a palm harmless even when it lands just
/// before the digitizer reports pen proximity. Two-finger undo is handled by
/// the surrounding composer rather than this stroke surface.
final class InkCanvas extends StatefulWidget {
  const InkCanvas({
    required this.strokes,
    required this.onStroke,
    this.origin = Offset.zero,
    this.baseWidth = 2.8,
    super.key,
  });

  /// Committed draft strokes, in page design coordinates.
  final List<InkStroke> strokes;
  final ValueChanged<InkStroke> onStroke;

  /// Page-design coordinate of this canvas's top-left, so captured strokes
  /// and painted strokes share the page coordinate space.
  final Offset origin;
  final double baseWidth;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

final class _InkCanvasState extends State<InkCanvas> {
  final List<InkPoint> _wet = [];
  int? _activePointer;

  // Native proximity arbitration rejects palms while the pen is in range.
  // Reject touch here as a second boundary so a palm that lands first cannot
  // start a handwriting stroke during the few milliseconds before hover.
  bool _acceptsKind(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus || kind == PointerDeviceKind.mouse;

  InkPoint _point(PointerEvent event, PageScale metrics) {
    final pressure = event.pressureMax > event.pressureMin
        ? ((event.pressure - event.pressureMin) /
                  (event.pressureMax - event.pressureMin))
              .clamp(0.0, 1.0)
        : 0.6;
    return InkPoint(
      event.localPosition.dx / metrics.scale + widget.origin.dx,
      event.localPosition.dy / metrics.scale + widget.origin.dy,
      pressure,
    );
  }

  void _down(PointerDownEvent event, PageScale metrics) {
    if (!_acceptsKind(event.kind) || _activePointer != null) {
      return;
    }
    _activePointer = event.pointer;
    setState(() {
      _wet
        ..clear()
        ..add(_point(event, metrics));
    });
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.fast,
      reason: 'ink.wet',
    );
  }

  void _move(PointerMoveEvent event, PageScale metrics) {
    if (event.pointer != _activePointer) {
      return;
    }
    setState(() => _wet.add(_point(event, metrics)));
  }

  void _up(PointerEvent event) {
    if (event.pointer != _activePointer) {
      return;
    }
    _activePointer = null;
    if (_wet.isNotEmpty) {
      widget.onStroke(
        InkStroke(points: List.of(_wet), width: widget.baseWidth),
      );
    }
    setState(_wet.clear);
    // Stroke committed; go quiet and let the ink dry (idle settle).
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.text,
      reason: 'ink.dry',
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _down(e, metrics),
      onPointerMove: (e) => _move(e, metrics),
      onPointerUp: _up,
      onPointerCancel: _up,
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _InkPainter(
            strokes: widget.strokes,
            wet: List.of(_wet),
            wetWidth: widget.baseWidth,
            color: ink.userInk,
            scale: metrics.scale,
            origin: widget.origin,
          ),
        ),
      ),
    );
  }
}

final class _InkPainter extends CustomPainter {
  _InkPainter({
    required this.strokes,
    required this.wet,
    required this.wetWidth,
    required this.color,
    required this.scale,
    required this.origin,
  });

  final List<InkStroke> strokes;
  final List<InkPoint> wet;
  final double wetWidth;
  final Color color;
  final double scale;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(-origin.dx * scale, -origin.dy * scale);
    paintStrokes(canvas, strokes, color, scale: scale);
    if (wet.isNotEmpty) {
      paintStrokes(
        canvas,
        [InkStroke(points: wet, width: wetWidth)],
        color,
        scale: scale,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InkPainter old) =>
      old.strokes != strokes ||
      !listEquals(old.wet, wet) ||
      old.color != color ||
      old.scale != scale ||
      old.origin != origin;
}
