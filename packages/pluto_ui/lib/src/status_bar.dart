import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'paper_theme.dart';

/// Device battery snapshot used by [StatusBar].
@immutable
final class StatusBattery {
  /// Creates a status battery value.
  const StatusBattery({required this.levelPercent, this.isCharging = false});

  /// Battery level from 0 to 100.
  final int levelPercent;

  /// Whether external power is charging the device.
  final bool isCharging;
}

/// Marker battery snapshot used by [StatusBar].
@immutable
final class StatusPenBattery {
  /// Creates a pen battery value.
  const StatusPenBattery({required this.levelPercent});

  /// Battery level from 0 to 100.
  final int levelPercent;
}

/// Wi-Fi snapshot used by [StatusBar].
@immutable
final class StatusWifi {
  /// Creates a Wi-Fi status value.
  const StatusWifi({required this.ssid, required this.signalPercent});

  /// Connected SSID.
  final String ssid;

  /// Signal strength from 0 to 100.
  final int signalPercent;
}

/// Immutable status bar data.
@immutable
final class StatusSnapshot {
  /// Creates a status snapshot.
  const StatusSnapshot({
    required this.time,
    required this.battery,
    this.penBattery,
    this.wifi,
    this.isWifiEnabled = true,
    this.frontlightRaw,
    this.frontlightMaxRaw = 2047,
    this.isUsbTethered = false,
  });

  /// Clock time.
  final DateTime time;

  /// Device battery.
  final StatusBattery battery;

  /// Optional marker battery.
  final StatusPenBattery? penBattery;

  /// Optional connected Wi-Fi.
  final StatusWifi? wifi;

  /// Whether the Wi-Fi radio is enabled when no connection is active.
  final bool isWifiEnabled;

  /// Optional raw frontlight level.
  final int? frontlightRaw;

  /// Maximum raw frontlight value.
  final int frontlightMaxRaw;

  /// Whether USB tethering is active.
  final bool isUsbTethered;

  /// Stable test snapshot.
  static final StatusSnapshot fixed = DateTime.utc(2026, 7, 7, 14, 32).let(
    (DateTime time) => StatusSnapshot(
      time: time,
      battery: const StatusBattery(levelPercent: 99, isCharging: true),
      penBattery: const StatusPenBattery(levelPercent: 68),
      wifi: const StatusWifi(ssid: "Anna's Wifi", signalPercent: 82),
      frontlightRaw: 1250,
      isUsbTethered: true,
    ),
  );
}

/// Persistent 40 lp launcher status bar with drawn state glyphs.
final class StatusBar extends StatelessWidget {
  /// Creates a status bar.
  const StatusBar({required this.snapshot, this.onTapCluster, super.key});

  /// Data rendered in fixed status slots.
  final StatusSnapshot snapshot;

  /// Called when the bar is tapped.
  final VoidCallback? onTapCluster;

  /// Status band height in logical pixels.
  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final PaperPalette palette = theme.palette;
    final StatusBattery battery = snapshot.battery;
    final bool batteryLow = battery.levelPercent <= 10 && !battery.isCharging;
    final Color batteryColor = batteryLow ? palette.accentRed : palette.ink;
    final TextStyle valueStyle = theme.type.caption;
    return Semantics(
      container: true,
      button: onTapCluster != null,
      label: onTapCluster == null ? 'Device status' : 'Open settings',
      explicitChildNodes: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTapCluster,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PaperSpacing.pageMargin,
            ),
            child: Row(
              children: <Widget>[
                Text(_formatTime(snapshot.time), style: valueStyle),
                const SizedBox(width: PaperSpacing.space8),
                Expanded(
                  // Scales the whole cluster down rather than clipping a
                  // glyph when fonts run wide; a no-op when everything fits.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        if (snapshot.isUsbTethered) ...<Widget>[
                          _UsbTag(palette: palette, style: valueStyle),
                          const SizedBox(width: 16),
                        ],
                        Semantics(
                          label: _wifiSemantics(snapshot),
                          child: _Glyph(
                            size: const Size(21, 16),
                            painter: _SignalGlyphPainter(
                              bars: snapshot.wifi == null
                                  ? 0
                                  : _signalBars(snapshot.wifi!.signalPercent),
                              off: !snapshot.isWifiEnabled,
                              ink: palette.ink,
                            ),
                          ),
                        ),
                        if (snapshot.penBattery != null) ...<Widget>[
                          const SizedBox(width: 14),
                          _Glyph(
                            size: const Size(16, 16),
                            painter: _PenGlyphPainter(ink: palette.ink),
                          ),
                          const SizedBox(width: 4),
                          _StatusValue(
                            '${snapshot.penBattery!.levelPercent}%',
                            style: valueStyle,
                          ),
                        ],
                        if (snapshot.frontlightRaw != null) ...<Widget>[
                          const SizedBox(width: 14),
                          _Glyph(
                            size: const Size(17, 17),
                            painter: _SunGlyphPainter(ink: palette.ink),
                          ),
                          const SizedBox(width: 5),
                          _StatusValue(
                            '${_frontlightPercent(snapshot.frontlightRaw!, snapshot.frontlightMaxRaw)}%',
                            style: valueStyle,
                          ),
                        ],
                        const SizedBox(width: 14),
                        _Glyph(
                          size: const Size(24, 13),
                          painter: _BatteryGlyphPainter(
                            level: battery.levelPercent / 100,
                            color: batteryColor,
                          ),
                        ),
                        if (battery.isCharging) ...<Widget>[
                          const SizedBox(width: 3),
                          Semantics(
                            label: 'Battery charging',
                            child: _Glyph(
                              size: const Size(8, 13),
                              painter: _BoltGlyphPainter(ink: palette.ink),
                            ),
                          ),
                        ],
                        const SizedBox(width: 5),
                        _StatusValue(
                          '${battery.levelPercent}%',
                          style: valueStyle.copyWith(color: batteryColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _UsbTag extends StatelessWidget {
  const _UsbTag({required this.palette, required this.style});

  final PaperPalette palette;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        // Matches the battery outline weight so the two stroked containers
        // on the bar read as one family.
        border: Border.all(color: palette.ink, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          'USB',
          style: style.copyWith(fontSize: 10, height: 12 / 10),
        ),
      ),
    );
  }
}

/// Numeral nudged up half a pixel so digits share the glyphs' optical
/// centerline instead of hanging on the caption line box.
final class _StatusValue extends StatelessWidget {
  const _StatusValue(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, -0.75),
      child: Text(text, style: style),
    );
  }
}

final class _Glyph extends StatelessWidget {
  const _Glyph({required this.size, required this.painter});

  final Size size;
  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    return SizedBox.fromSize(
      size: size,
      child: CustomPaint(painter: painter),
    );
  }
}

int _signalBars(int signalPercent) {
  if (signalPercent >= 70) {
    return 3;
  }
  if (signalPercent >= 40) {
    return 2;
  }
  return 1;
}

String _wifiSemantics(StatusSnapshot snapshot) {
  final StatusWifi? wifi = snapshot.wifi;
  if (wifi != null) {
    return 'Wi-Fi connected to ${wifi.ssid}, ${wifi.signalPercent}% signal';
  }
  return snapshot.isWifiEnabled ? 'Wi-Fi disconnected' : 'Wi-Fi off';
}

final class _SignalGlyphPainter extends CustomPainter {
  const _SignalGlyphPainter({
    required this.bars,
    required this.off,
    required this.ink,
  });

  final int bars;
  final bool off;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint fill = Paint()
      ..color = ink
      ..style = PaintingStyle.fill;
    final Paint outline = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    // Whole-pixel bar geometry (5 wide, 3 gaps) so all three bars threshold
    // to identical widths with symmetric edges on the panel.
    const double barWidth = 5;
    const double gap = 3;
    const List<double> heights = <double>[6, 11, 16];
    for (int i = 0; i < 3; i++) {
      final Rect bar = Rect.fromLTWH(
        i * (barWidth + gap),
        size.height - heights[i],
        barWidth,
        heights[i],
      );
      if (i < bars) {
        canvas.drawRect(bar, fill);
      } else {
        canvas.drawRect(bar.deflate(0.75), outline);
      }
    }
    if (off) {
      final Paint slash = Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawLine(Offset(0, size.height), Offset(size.width - 1, 1), slash);
    }
  }

  @override
  bool shouldRepaint(_SignalGlyphPainter oldDelegate) =>
      bars != oldDelegate.bars ||
      off != oldDelegate.off ||
      ink != oldDelegate.ink;
}

final class _PenGlyphPainter extends CustomPainter {
  const _PenGlyphPainter({required this.ink});

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final double unit = size.width / 16;
    final double shaftHalfWidth = 1.5 * unit;
    // Shaft axis runs lower-left to upper-right.
    final Offset tipEnd = Offset(5 * unit, 11 * unit);
    final Offset capEnd = Offset(12 * unit, 4 * unit);
    final Offset axis = (capEnd - tipEnd) / (capEnd - tipEnd).distance;
    final Offset side = Offset(-axis.dy, axis.dx) * shaftHalfWidth;
    final Paint stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = shaftHalfWidth * 2
      ..strokeCap = StrokeCap.butt;
    canvas.drawLine(tipEnd, capEnd, stroke);
    // Sharpened point exactly as wide as the shaft — no arrowhead barbs.
    final Paint fill = Paint()
      ..color = ink
      ..style = PaintingStyle.fill;
    final Path point = Path()
      ..moveTo((tipEnd + side).dx, (tipEnd + side).dy)
      ..lineTo((tipEnd - side).dx, (tipEnd - side).dy)
      ..lineTo((tipEnd - axis * 3.6 * unit).dx, (tipEnd - axis * 3.6 * unit).dy)
      ..close();
    canvas.drawPath(point, fill);
    // Detached ferrule cap marks the pencil's other end.
    final Offset capCenter = capEnd + axis * 1.8 * unit;
    canvas.drawLine(
      capCenter - side * 1.4,
      capCenter + side * 1.4,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 * unit
        ..strokeCap = StrokeCap.butt,
    );
  }

  @override
  bool shouldRepaint(_PenGlyphPainter oldDelegate) => ink != oldDelegate.ink;
}

final class _SunGlyphPainter extends CustomPainter {
  const _SunGlyphPainter({required this.ink});

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double unit = size.width / 17;
    final Paint stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * unit
      ..strokeCap = StrokeCap.butt;
    canvas.drawCircle(center, 3.2 * unit, stroke);
    for (int i = 0; i < 8; i++) {
      final double angle = i * math.pi / 4;
      final Offset direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * 5.4 * unit,
        center + direction * 8 * unit,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_SunGlyphPainter oldDelegate) => ink != oldDelegate.ink;
}

final class _BatteryGlyphPainter extends CustomPainter {
  const _BatteryGlyphPainter({required this.level, required this.color});

  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 1.5;
    const double nubWidth = 2.4;
    final Paint outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final Paint fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    // Stroke-centered body whose outer right edge the nub welds onto.
    final Rect body = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - nubWidth - stroke,
      size.height - stroke,
    );
    canvas.drawRect(body, outline);
    canvas.drawRect(
      Rect.fromLTWH(
        body.right + stroke / 2,
        size.height / 2 - 2.2,
        nubWidth,
        4.4,
      ),
      fill,
    );
    final Rect charge = Rect.fromLTWH(
      body.left + 2.6,
      body.top + 2.6,
      (body.width - 5.2) * level.clamp(0, 1),
      body.height - 5.2,
    );
    canvas.drawRect(charge, fill);
  }

  @override
  bool shouldRepaint(_BatteryGlyphPainter oldDelegate) =>
      level != oldDelegate.level || color != oldDelegate.color;
}

final class _BoltGlyphPainter extends CustomPainter {
  const _BoltGlyphPainter({required this.ink});

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final Paint fill = Paint()
      ..color = ink
      ..style = PaintingStyle.fill;
    final Path bolt = Path()
      ..moveTo(0.62 * w, 0)
      ..lineTo(0, 0.58 * h)
      ..lineTo(0.4 * w, 0.58 * h)
      ..lineTo(0.3 * w, h)
      ..lineTo(w, 0.4 * h)
      ..lineTo(0.55 * w, 0.4 * h)
      ..close();
    canvas.drawPath(bolt, fill);
  }

  @override
  bool shouldRepaint(_BoltGlyphPainter oldDelegate) => ink != oldDelegate.ink;
}

String _formatTime(DateTime time) {
  final String hour = time.hour.toString().padLeft(2, '0');
  final String minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

int _frontlightPercent(int raw, int maxRaw) {
  if (maxRaw <= 0) {
    return 0;
  }
  return ((raw / maxRaw) * 100).round().clamp(0, 100);
}

extension<T> on T {
  R let<R>(R Function(T value) callback) => callback(this);
}
