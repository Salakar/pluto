import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../app_model.dart';
import '../codex/codex_bridge.dart';
import '../paper/layout.dart';
import '../paper/ruled_text.dart';
import '../paper/sketch.dart';
import '../paper/theme.dart';
import '../services.dart';
import 'mind_rows.dart';

/// Settings, paper-style: hand-lettered lines on the ruling — return to the
/// launcher, wi-fi, the reading light as a sun whose rays grow with
/// brightness, house defaults for the mind and its thinking (each page can
/// override these from its own header), and a codex health line.
final class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.model, required this.onClose, super.key});

  final CodexAppModel model;
  final VoidCallback onClose;

  CodexServices get services => model.services;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// Content rows on the ruling lattice (1-based rule the baseline sits on).
abstract final class _Rows {
  static const int exit = 3;
  static const int wifi = 5;
  static const int light = 7;
  static const int mindLabel = 10;

  /// Wells top = rule 10; options baseline on rule 11-12.
  static const int mindOptions = 10;
  static const int effortLabel = 14;
  static const int effortOptions = 14;
  static const int codex = 18;
  static const int workspace = 19;
  static const int hint = 21;
}

double _ruleYd(int rule) =>
    PageDesign.firstRuleY + rule * PageDesign.ruleStep.toDouble();

final class _SettingsPageState extends State<SettingsPage> {
  WifiSummary _wifi = const WifiSummary(line: 'wi-fi: …', connected: false);
  double? _frontlight;
  CodexProbe? _probe;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final wifi = await widget.services.system.wifiSummary();
    final light = await widget.services.system.frontlightFraction();
    final probe = await widget.services.bridge.probe();
    if (!mounted) {
      return;
    }
    setState(() {
      _wifi = wifi;
      _frontlight = light;
      _probe = probe;
    });
  }

  Future<void> _bumpLight(int step) async {
    final current = _frontlight ?? 0;
    final next = math.min(1, math.max(0, current + step * 0.2)).toDouble();
    await widget.services.system.setFrontlightFraction(next);
    if (mounted) {
      setState(() => _frontlight = next);
    }
  }

  void _bump() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final model = widget.model;
    final probe = _probe;
    final codexLine = probe == null
        ? 'codex: checking…'
        : probe.binaryPath == null
        ? 'codex: not installed'
        : '${probe.version ?? 'codex'} — '
              '${probe.loggedIn ? 'signed in' : 'signed out'}';
    final lightRays = _frontlight == null
        ? null
        : (2 + (_frontlight! * 9)).round();

    final mindTop = metrics.u(_ruleYd(_Rows.mindOptions));
    final effortTop = metrics.u(_ruleYd(_Rows.effortOptions));

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: ink.paper)),
        Positioned.fill(
          child: CustomPaint(
            painter: _SettingsPainter(
              metrics: metrics,
              ink: ink,
              wifiLine: _wifi.line,
              codexLine: codexLine,
              workspaceLine:
                  'workspace: ${_shortPath(widget.services.paths.workspace.path)}',
              lightRays: lightRays,
              mind: model.mind,
            ),
          ),
        ),
        _tapRow(
          metrics,
          rule: _Rows.exit,
          onTap: () => unawaited(widget.services.system.exitToLauncher()),
        ),
        if (lightRays != null) ...[
          _tapRow(
            metrics,
            rule: _Rows.light,
            onTap: () => unawaited(_bumpLight(-1)),
            half: _TapHalf.left,
          ),
          _tapRow(
            metrics,
            rule: _Rows.light,
            onTap: () => unawaited(_bumpLight(1)),
            half: _TapHalf.right,
          ),
        ],
        for (final (i, well) in MindRows.mindWells(
          metrics.designContentX0,
          metrics.designContentW,
        ).indexed)
          Positioned(
            left: metrics.u(well.left),
            top: mindTop,
            width: metrics.u(well.width),
            height: metrics.u(well.height),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(
                model
                    .setMindModel(i < 3 ? MindSettings.models[i] : null)
                    .then((_) => _bump()),
              ),
            ),
          ),
        for (final (i, well) in MindRows.effortWells(
          metrics.designContentX0,
          metrics.designContentW,
        ).indexed)
          Positioned(
            left: metrics.u(well.left),
            top: effortTop,
            width: metrics.u(well.width),
            height: metrics.u(well.height),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(
                model
                    .setMindEffort(
                      i >= MindSettings.efforts.length
                          ? null
                          : MindSettings.efforts[i],
                    )
                    .then((_) => _bump()),
              ),
            ),
          ),
        Positioned(
          left: 0,
          top: 0,
          width: metrics.u(160),
          height: metrics.u(120),
          child: GestureDetector(
            key: const ValueKey('settings-back'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
          ),
        ),
      ],
    );
  }

  Widget _tapRow(
    PageScale metrics, {
    required int rule,
    required VoidCallback onTap,
    _TapHalf half = _TapHalf.full,
  }) {
    final y = metrics.u(_ruleYd(rule) - PageDesign.ruleStep);
    final contentW = metrics.contentW;
    final left = half == _TapHalf.right
        ? metrics.contentX0 + contentW / 2
        : metrics.contentX0;
    final width = half == _TapHalf.full ? contentW : contentW / 2;
    return Positioned(
      left: left,
      top: y,
      width: width,
      height: metrics.ruleStep * 1.2,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap),
    );
  }
}

enum _TapHalf { full, left, right }

/// Last two path segments — enough to orient, stable across machines.
String _shortPath(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.length <= 2) {
    return path;
  }
  return '…/${parts[parts.length - 2]}/${parts.last}';
}

final class _SettingsPainter extends CustomPainter {
  _SettingsPainter({
    required this.metrics,
    required this.ink,
    required this.wifiLine,
    required this.codexLine,
    required this.workspaceLine,
    required this.lightRays,
    required this.mind,
  });

  final PageScale metrics;
  final PaperInk ink;
  final String wifiLine;
  final String codexLine;
  final String workspaceLine;
  final int? lightRays;
  final MindSettings mind;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));

    final pageH = size.height / metrics.scale;
    for (
      var y = PageDesign.firstRuleY;
      y < pageH - 20;
      y += PageDesign.ruleStep
    ) {
      sketch.line(
        PageDesign.contentX0,
        y,
        metrics.designContentX1,
        y,
        1,
        ink.faintRule,
      );
    }

    // Header: back chevron + wordmark.
    sketch.strokePath(
      [const Offset(64, 74), const Offset(46, 90), const Offset(64, 106)],
      1.8,
      ink.ink,
    );
    _line(
      canvas,
      'paper codex',
      x: 92,
      baseline: PageDesign.headerBaselineY.toDouble(),
      style: PaperType.wordmark(ink),
    );
    _line(
      canvas,
      'settings',
      x: 248,
      baseline: PageDesign.headerBaselineY.toDouble(),
      style: PaperType.note(ink, size: 30, color: ink.ink),
    );
    // The same accent tick every page title wears.
    sketch.strokePath(
      [const Offset(250, 108), const Offset(274, 110)],
      1.4,
      ink.softInk,
    );

    _entry(canvas, _Rows.exit, 'return to the launcher', ink.ink);
    _entry(canvas, _Rows.wifi, wifiLine, ink.ink);

    if (lightRays != null) {
      _entry(canvas, _Rows.light, 'reading light', ink.ink);
      // Five notches on the rule; the current level is inked in. (No sun
      // here — the header sun means settings, and one page needs one sun.)
      final level = ((lightRays! - 2) / 9 * 4).round().clamp(0, 4);
      for (var i = 0; i < 5; i++) {
        final nx =
            PageDesign.contentX0 + 420.0 + i * (88.0 + metrics.extraWidth / 4);
        final ny = _ruleYd(_Rows.light);
        sketch.strokePath(
          [Offset(nx, ny - 20), Offset(nx + 2, ny - 4)],
          1.4,
          ink.softInk,
        );
        if (i <= level) {
          sketch.dot(nx + 1, ny - 12, 5.5, ink.ink);
        }
      }
      _line(
        canvas,
        'dimmer',
        x: PageDesign.contentX0 + 24,
        baseline: _ruleYd(_Rows.light) + PageDesign.ruleStep * 0.8,
        style: PaperType.note(ink, size: 24),
      );
      _line(
        canvas,
        'brighter',
        x: PageDesign.contentX0 + metrics.designContentW / 2 + 24,
        baseline: _ruleYd(_Rows.light) + PageDesign.ruleStep * 0.8,
        style: PaperType.note(ink, size: 24),
      );
    }

    _entry(canvas, _Rows.mindLabel, 'the mind', ink.ink);
    _line(
      canvas,
      'default for new pages — each page can choose its own',
      x: PageDesign.contentX0 + 210,
      baseline: _ruleYd(_Rows.mindLabel),
      style: PaperType.note(ink, size: 24),
    );
    MindRows.paintMindRow(
      canvas,
      sketch,
      ink,
      x0: PageDesign.contentX0.toDouble(),
      width: metrics.designContentW,
      rowTop: _ruleYd(_Rows.mindOptions),
      selected: mind.model,
    );

    _entry(canvas, _Rows.effortLabel, 'thinking', ink.ink);
    _line(
      canvas,
      'how long it lingers before answering',
      x: PageDesign.contentX0 + 210,
      baseline: _ruleYd(_Rows.effortLabel),
      style: PaperType.note(ink, size: 24),
    );
    MindRows.paintEffortRow(
      canvas,
      sketch,
      ink,
      x0: PageDesign.contentX0.toDouble(),
      width: metrics.designContentW,
      rowTop: _ruleYd(_Rows.effortOptions),
      selected: mind.effort,
    );

    _entry(canvas, _Rows.codex, codexLine, ink.softInk);
    _entry(canvas, _Rows.workspace, workspaceLine, ink.softInk, size: 24);
    _entry(
      canvas,
      _Rows.hint,
      'double-tap the bezel any time to go home',
      ink.softInk,
      size: 26,
    );
    canvas.restore();
  }

  void _entry(
    Canvas canvas,
    int rule,
    String text,
    Color color, {
    double size = PageDesign.handBody,
  }) {
    _line(
      canvas,
      text,
      x: PageDesign.contentX0 + 12,
      baseline: _ruleYd(rule),
      style: RuledStyle(
        fontFamily: PaperFonts.hand,
        size: size,
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  void _line(
    Canvas canvas,
    String text, {
    required double x,
    required double baseline,
    required RuledStyle style,
    double? maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style.toTextStyle()),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? metrics.designContentW - 24);
    painter.paint(
      canvas,
      Offset(
        x,
        baseline -
            painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      ),
    );
  }

  @override
  bool shouldRepaint(_SettingsPainter old) =>
      old.wifiLine != wifiLine ||
      old.codexLine != codexLine ||
      old.workspaceLine != workspaceLine ||
      old.lightRays != lightRays ||
      old.mind.model != mind.model ||
      old.mind.effort != mind.effort ||
      old.ink != ink ||
      old.metrics != metrics;
}
