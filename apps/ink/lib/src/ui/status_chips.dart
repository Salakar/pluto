import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'glyphs.dart';
import 'responsive_layout.dart';

/// Authored height of the editor's top status band.
const double inkStatusBandDesignHeight = 88;

/// Static lifetime of undo, redo, locked, and hidden feedback.
const Duration inkUndoToastDuration = Duration(milliseconds: 800);

/// Delay before an in-flight save changes from quiet to drying.
const Duration inkDryingIndicatorDelay = Duration(milliseconds: 300);

/// Lifetime of the saved timestamp before its chip becomes blank.
const Duration inkSavedIndicatorDuration = Duration(seconds: 2);

/// Authored minimum status-chip target in both axes.
const double inkStatusChipMinimumDesignSize = 80;

const double _backChipDesignWidth = 144;
const double _saveChipDesignWidth = 160;
const double _zoomChipDesignWidth = 96;
const double _rotationChipDesignWidth = 80;
const double _layerChipDesignWidth = 144;
const double _feedbackChipDesignHeight = 80;

/// Visible save state supplied by the editor's save coordinator.
enum InkSavePhase {
  /// No save feedback is currently visible.
  quiet,

  /// A save has exceeded the 300-ms visibility threshold.
  drying,

  /// A completed save is showing its two-second timestamp.
  saved,
}

/// Formats the canonical saved-chip clock value.
String inkSavedTimeLabel(DateTime savedAt) {
  final String hours = savedAt.hour.toString().padLeft(2, '0');
  final String minutes = savedAt.minute.toString().padLeft(2, '0');
  return '$hours:$minutes';
}

/// The editor's complete 88-dpx top band.
///
/// Save timing remains host-owned so fake-async widget tests and e-ink frames
/// never depend on a timer inside the chrome. All actionable cells meet the
/// authored 80-dpx target and invert immediately on pointer down.
final class InkEditorStatusBand extends StatelessWidget {
  /// Creates the complete status row.
  const InkEditorStatusBand({
    required this.artworkName,
    required this.zoomPercent,
    required this.activeLayerName,
    required this.savePhase,
    required this.onBack,
    required this.onArtworkPressed,
    required this.onZoomPressed,
    required this.onLayerPressed,
    this.savedAt,
    this.rotationDegrees = 0,
    this.onRotationReset,
    this.heavyArtwork = false,
    super.key,
  }) : assert(artworkName != ''),
       assert(zoomPercent >= 10 && zoomPercent <= 1600),
       assert(activeLayerName != ''),
       assert(savePhase != InkSavePhase.saved || savedAt != null),
       assert(
         rotationDegrees >= -double.maxFinite &&
             rotationDegrees <= double.maxFinite,
       ),
       assert(rotationDegrees == 0 || onRotationReset != null);

  /// Current artwork title; tapping starts the rename flow.
  final String artworkName;

  /// Rounded viewport zoom from ten through sixteen-hundred percent.
  final int zoomPercent;

  /// Active content-layer name.
  final String activeLayerName;

  /// Host-resolved save presentation.
  final InkSavePhase savePhase;

  /// Time used by [InkSavePhase.saved].
  final DateTime? savedAt;

  /// Current canvas rotation; nonzero values add a reset target.
  final double rotationDegrees;

  /// Whether the memory guard is under pressure.
  final bool heavyArtwork;

  /// Flushes and returns to the gallery.
  final VoidCallback onBack;

  /// Starts artwork rename.
  final VoidCallback onArtworkPressed;

  /// Cycles fit, one-hundred percent, and last manual zoom.
  final VoidCallback onZoomPressed;

  /// Resets rotation without changing zoom.
  final VoidCallback? onRotationReset;

  /// Opens the layers panel.
  final VoidCallback onLayerPressed;

  @override
  Widget build(BuildContext context) {
    final _StatusScale scale = _StatusScale.of(context);
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      key: const ValueKey<String>('ink-status-band'),
      width: double.infinity,
      height: scale.u(inkStatusBandDesignHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: scale.u(inkStatusChipMinimumDesignSize),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _StatusButtonCell(
                  key: const ValueKey<String>('status-back'),
                  width: scale.u(_backChipDesignWidth),
                  label: 'Back to gallery',
                  onPressed: onBack,
                  child: Text(
                    '← gallery',
                    maxLines: 1,
                    style: theme.type.label,
                  ),
                ),
                _SaveCell(
                  phase: savePhase,
                  savedAt: savedAt,
                  width: scale.u(_saveChipDesignWidth),
                ),
                Expanded(
                  child: _StatusButtonCell(
                    key: const ValueKey<String>('status-artwork'),
                    width: double.infinity,
                    label: 'Rename artwork $artworkName',
                    onPressed: onArtworkPressed,
                    child: Text(
                      artworkName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.type.label.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                _StatusButtonCell(
                  key: const ValueKey<String>('status-zoom'),
                  width: scale.u(_zoomChipDesignWidth),
                  label: 'Zoom $zoomPercent percent',
                  onPressed: onZoomPressed,
                  child: Text(
                    '$zoomPercent%',
                    maxLines: 1,
                    style: theme.type.mono,
                  ),
                ),
                if (rotationDegrees != 0)
                  _StatusButtonCell(
                    key: const ValueKey<String>('status-rotation-reset'),
                    width: scale.u(_rotationChipDesignWidth),
                    label: 'Reset rotation',
                    onPressed: onRotationReset!,
                    child: _RotationTick(
                      rotationDegrees: rotationDegrees,
                      color: theme.palette.ink,
                    ),
                  ),
                _StatusButtonCell(
                  key: const ValueKey<String>('status-layer'),
                  width: scale.u(_layerChipDesignWidth),
                  label: heavyArtwork
                      ? 'Layers, $activeLayerName, heavy artwork'
                      : 'Layers, $activeLayerName',
                  onPressed: onLayerPressed,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (heavyArtwork)
                        SizedBox(
                          width: scale.u(28),
                          height: scale.u(28),
                          child: CustomPaint(
                            painter: InkGlyphPainter(
                              glyph: InkGlyph.markHeavy,
                              color: theme.palette.ink,
                            ),
                          ),
                        ),
                      Flexible(
                        child: Text(
                          '$activeLayerName ▸',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption,
                        ),
                      ),
                    ],
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

final class _SaveCell extends StatelessWidget {
  const _SaveCell({
    required this.phase,
    required this.savedAt,
    required this.width,
  });

  final InkSavePhase phase;
  final DateTime? savedAt;
  final double width;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Widget child = switch (phase) {
      InkSavePhase.quiet => const SizedBox.shrink(),
      InkSavePhase.drying => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 30,
            height: 30,
            child: CustomPaint(
              painter: InkGlyphPainter(
                glyph: InkGlyph.markDrying,
                color: theme.palette.ink,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text('drying', style: theme.type.caption),
        ],
      ),
      InkSavePhase.saved => Text(
        'saved ·${inkSavedTimeLabel(savedAt!)}',
        maxLines: 1,
        style: theme.type.caption,
      ),
    };
    final String label = switch (phase) {
      InkSavePhase.quiet => 'Save status quiet',
      InkSavePhase.drying => 'Artwork drying',
      InkSavePhase.saved => 'Artwork saved at ${inkSavedTimeLabel(savedAt!)}',
    };
    return Semantics(
      container: true,
      liveRegion: phase != InkSavePhase.quiet,
      excludeSemantics: true,
      label: label,
      child: SizedBox(
        key: const ValueKey<String>('status-save'),
        width: width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.palette.paper,
            border: Border(
              right: BorderSide(
                color: theme.palette.ink,
                width: _StatusScale.of(context).rule,
              ),
            ),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// A static 800-ms undo/redo result chip.
///
/// Visibility timing is owned by the editor model. [onDismiss] is optional
/// because the canonical state disappears without requiring user input.
final class InkUndoToast extends StatelessWidget {
  /// Creates an undo or redo result chip.
  const InkUndoToast({required this.message, this.onDismiss, super.key})
    : assert(message != '');

  /// Canonical copy such as `undid stroke` or `redid fill`.
  final String message;

  /// Optional early dismissal.
  final VoidCallback? onDismiss;

  /// Required visible lifetime.
  Duration get duration => inkUndoToastDuration;

  @override
  Widget build(BuildContext context) {
    return InkStatusNoticeChip(
      key: const ValueKey<String>('ink-undo-toast'),
      message: message,
      semanticsLabel: message,
      onDismiss: onDismiss,
    );
  }
}

/// One-line document-recovery or quarantine margin note.
final class InkMarginNoteChip extends StatelessWidget {
  /// Creates a tappable warning note.
  const InkMarginNoteChip({
    required this.message,
    required this.onDismiss,
    this.heavy = false,
    super.key,
  }) : assert(message != '');

  /// Single-line recovery copy.
  final String message;

  /// Dismisses the note.
  final VoidCallback onDismiss;

  /// Uses the heavy-artwork weight mark instead of the warning rule.
  final bool heavy;

  @override
  Widget build(BuildContext context) {
    return InkStatusNoticeChip(
      key: const ValueKey<String>('ink-margin-note'),
      message: message,
      semanticsLabel: 'Notice, $message',
      glyph: heavy ? InkGlyph.markHeavy : null,
      warning: !heavy,
      onDismiss: onDismiss,
    );
  }
}

/// Memory-guard feedback shared by the layers panel and status area.
final class InkHeavyArtworkChip extends StatelessWidget {
  /// Creates the heavy-artwork chip.
  const InkHeavyArtworkChip({this.onDismiss, super.key});

  /// Optional acknowledgement callback.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return InkStatusNoticeChip(
      key: const ValueKey<String>('ink-heavy-artwork'),
      message: 'heavy artwork',
      semanticsLabel: 'Heavy artwork, memory guard active',
      glyph: InkGlyph.markHeavy,
      onDismiss: onDismiss,
    );
  }
}

/// Locked/hidden-layer no-op feedback in the shared 800-ms toast slot.
final class InkLayerStatusChip extends StatelessWidget {
  /// Creates a canonical `layer locked` or `layer hidden` chip.
  const InkLayerStatusChip({required this.message, this.onDismiss, super.key})
    : assert(message == 'layer locked' || message == 'layer hidden');

  /// Canonical non-silent no-op copy.
  final String message;

  /// Optional early dismissal callback.
  final VoidCallback? onDismiss;

  /// Required visible lifetime.
  Duration get duration => inkUndoToastDuration;

  @override
  Widget build(BuildContext context) {
    return InkStatusNoticeChip(
      key: const ValueKey<String>('ink-layer-status'),
      message: message,
      semanticsLabel: message,
      onDismiss: onDismiss,
      warning: true,
    );
  }
}

/// Solid first-editor-focus marker heuristic banner.
final class InkMarkerMissingBanner extends StatelessWidget {
  /// Creates the marker-missing banner.
  const InkMarkerMissingBanner({this.onDismiss, super.key});

  /// Optional acknowledgement callback.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final _StatusScale scale = _StatusScale.of(context);
    final PaperThemeData theme = PaperTheme.of(context);
    final Widget content = SizedBox(
      key: const ValueKey<String>('ink-marker-missing-banner'),
      width: double.infinity,
      height: scale.u(_feedbackChipDesignHeight),
      child: ColoredBox(
        color: theme.palette.ink,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: scale.u(24)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'marker not detected — finger drawing enabled',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.label.copyWith(color: theme.palette.paper),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      liveRegion: true,
      button: onDismiss != null,
      excludeSemantics: true,
      label: 'Marker not detected, finger drawing enabled',
      child: onDismiss == null
          ? content
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: content,
            ),
    );
  }
}

/// Shared outlined status / feedback chip.
///
/// Warning presentation uses an ink-drawn rule mark; accent red is restricted
/// to its label and never used as a fill.
final class InkStatusNoticeChip extends StatefulWidget {
  /// Creates an outlined, one-line status chip.
  const InkStatusNoticeChip({
    required this.message,
    this.semanticsLabel,
    this.glyph,
    this.warning = false,
    this.onDismiss,
    super.key,
  }) : assert(message != '');

  /// One-line visible copy.
  final String message;

  /// Optional more descriptive accessibility copy.
  final String? semanticsLabel;

  /// Optional drawn leading mark.
  final InkGlyph? glyph;

  /// Whether the label uses the theme's destructive accent.
  final bool warning;

  /// When present, tapping dismisses the chip.
  final VoidCallback? onDismiss;

  @override
  State<InkStatusNoticeChip> createState() => _InkStatusNoticeChipState();
}

final class _InkStatusNoticeChipState extends State<InkStatusNoticeChip> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || widget.onDismiss == null) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final _StatusScale scale = _StatusScale.of(context);
    final PaperThemeData theme = PaperTheme.of(context);
    final bool inverted = _pressed;
    final Color foreground = inverted
        ? theme.palette.paper
        : widget.warning
        ? theme.palette.accentRed
        : theme.palette.ink;
    final Color glyphColor = inverted ? theme.palette.paper : theme.palette.ink;
    final Color background = inverted ? theme.palette.ink : theme.palette.paper;
    return Semantics(
      liveRegion: true,
      button: widget.onDismiss != null,
      excludeSemantics: true,
      label: widget.semanticsLabel ?? widget.message,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onDismiss == null ? null : (_) => _setPressed(true),
        onTapCancel: widget.onDismiss == null ? null : () => _setPressed(false),
        onTapUp: widget.onDismiss == null ? null : (_) => _setPressed(false),
        onTap: widget.onDismiss,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: scale.u(inkStatusChipMinimumDesignSize),
            minHeight: scale.u(_feedbackChipDesignHeight),
            maxWidth: scale.u(620),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border.all(color: theme.palette.ink, width: scale.rule),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: scale.u(16)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: scale.u(36),
                    height: scale.u(36),
                    child: widget.glyph == null
                        ? CustomPaint(
                            painter: _WarningRulePainter(
                              color: glyphColor,
                              ruleWidth: scale.rule,
                            ),
                          )
                        : CustomPaint(
                            painter: InkGlyphPainter(
                              glyph: widget.glyph!,
                              color: glyphColor,
                            ),
                          ),
                  ),
                  SizedBox(width: scale.u(12)),
                  Flexible(
                    child: Text(
                      widget.message,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.label.copyWith(color: foreground),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _StatusButtonCell extends StatefulWidget {
  const _StatusButtonCell({
    required this.width,
    required this.label,
    required this.onPressed,
    required this.child,
    super.key,
  });

  final double width;
  final String label;
  final VoidCallback onPressed;
  final Widget child;

  @override
  State<_StatusButtonCell> createState() => _StatusButtonCellState();
}

final class _StatusButtonCellState extends State<_StatusButtonCell> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final _StatusScale scale = _StatusScale.of(context);
    final Color foreground = _pressed ? theme.palette.paper : theme.palette.ink;
    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label: widget.label,
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.onPressed,
        child: SizedBox(
          width: widget.width,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _pressed ? theme.palette.ink : theme.palette.paper,
              border: Border(
                right: BorderSide(color: theme.palette.ink, width: scale.rule),
              ),
            ),
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(foreground, BlendMode.srcIn),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

final class _RotationTick extends StatelessWidget {
  const _RotationTick({required this.rotationDegrees, required this.color});

  final double rotationDegrees;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 34,
          height: 22,
          child: CustomPaint(painter: _RotationTickPainter(color: color)),
        ),
        Text(
          '${rotationDegrees.round()}°',
          style: PaperTheme.of(context).type.caption,
        ),
      ],
    );
  }
}

final class _RotationTickPainter extends CustomPainter {
  const _RotationTickPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    final Rect arc = Rect.fromLTWH(4, 2, size.width - 8, size.height - 4);
    canvas.drawArc(arc, math.pi * 0.12, math.pi * 1.25, false, paint);
    canvas.drawLine(
      Offset(5, size.height * 0.55),
      Offset(1, size.height * 0.25),
      paint,
    );
    canvas.drawLine(
      Offset(5, size.height * 0.55),
      Offset(10, size.height * 0.42),
      paint,
    );
  }

  @override
  bool shouldRepaint(_RotationTickPainter oldDelegate) =>
      oldDelegate.color != color;
}

final class _WarningRulePainter extends CustomPainter {
  const _WarningRulePainter({required this.color, required this.ruleWidth});

  final Color color;
  final double ruleWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = math.max(2, ruleWidth)
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    canvas.drawLine(
      Offset(size.width / 2, size.height * 0.12),
      Offset(size.width / 2, size.height * 0.67),
      paint,
    );
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height * 0.86),
        width: math.max(3, ruleWidth),
        height: math.max(3, ruleWidth),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_WarningRulePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.ruleWidth != ruleWidth;
}

final class _StatusScale {
  const _StatusScale(this.value);

  factory _StatusScale.of(BuildContext context) {
    return _StatusScale(inkViewportFitScaleOf(context));
  }

  final double value;

  double u(double designPx) => designPx * value;

  double get rule => math.max(1, u(2));
}
