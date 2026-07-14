import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../../document/export.dart';
import '../glyphs.dart';
import '../responsive_layout.dart';

/// Width of the export sheet in the 954 x 1696 authored coordinate space.
const double exportPanelDesignWidth = 437;

/// Stable compact sheet height: the seven 80 dp rows of the failure state
/// (560 dp) plus headroom for `PaperSurface`'s fixed 4 lp plate-shadow inset.
/// The inset is not scaled with the sheet, so without this slack the reason
/// row overflows in debug and clips at sub-unity panel scales on device.
const double exportPanelDesignHeight = 572;

/// Height of the title, export-action, status, and retry rows.
const double exportPanelRowDesignHeight = 80;

/// Export controls and persistent feedback for one artwork.
///
/// The host owns document I/O through [onExport]. This widget only selects a
/// format and renders the runner's discrete progress and result states.
final class ExportPanel extends StatefulWidget {
  /// Creates an export sheet for [artworkId].
  ExportPanel({
    required this.artworkId,
    required this.onExport,
    required this.onClose,
    super.key,
  }) {
    if (artworkId.isEmpty) {
      throw ArgumentError.value(artworkId, 'artworkId', 'must not be empty');
    }
  }

  /// Stable id of the artwork exported by every format row.
  final String artworkId;

  /// Typed export pipeline supplied by the editor host.
  final InkExportRunner onExport;

  /// Closes this sheet without starting or cancelling an export.
  final VoidCallback onClose;

  @override
  State<ExportPanel> createState() => _ExportPanelState();
}

final class _ExportPanelState extends State<ExportPanel> {
  InkExportKind? _lastKind;
  InkExportPhase? _phase;
  String? _failureReason;
  bool _running = false;
  int _runGeneration = 0;

  @override
  void didUpdateWidget(ExportPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkId != widget.artworkId) {
      _runGeneration += 1;
      _lastKind = null;
      _phase = null;
      _failureReason = null;
      _running = false;
    }
  }

  @override
  void dispose() {
    _runGeneration += 1;
    super.dispose();
  }

  Future<void> _runExport(InkExportKind kind) async {
    if (_running) {
      return;
    }
    final int generation = ++_runGeneration;
    setState(() {
      _lastKind = kind;
      _phase = InkExportPhase.flattening;
      _failureReason = null;
      _running = true;
    });

    late final InkExportResult result;
    try {
      result = await widget.onExport(
        artworkId: widget.artworkId,
        kind: kind,
        onProgress: (InkExportPhase phase) {
          if (!mounted || generation != _runGeneration || !_running) {
            return;
          }
          setState(() {
            _phase = phase;
          });
        },
      );
    } on Object catch (error) {
      if (!mounted || generation != _runGeneration) {
        return;
      }
      _showFailure(_errorReason(error));
      return;
    }

    if (!mounted || generation != _runGeneration) {
      return;
    }
    if (result is InkExportFailure) {
      _showFailure(result.reason);
      return;
    }
    setState(() {
      _phase = InkExportPhase.done;
      _failureReason = null;
      _running = false;
    });
  }

  void _showFailure(String reason) {
    setState(() {
      _phase = null;
      _failureReason = reason.trim().isEmpty ? 'I/O error' : reason.trim();
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final _ExportPanelScale scale = _ExportPanelScale.of(context);
    final String? failureReason = _failureReason;
    return SizedBox(
      width: scale.u(exportPanelDesignWidth),
      height: scale.u(exportPanelDesignHeight),
      child: PaperSurface(
        plateShadow: true,
        radius: 0,
        padding: EdgeInsets.zero,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Export panel',
          child: Column(
            children: <Widget>[
              _ExportPanelHeader(scale: scale, onClose: widget.onClose),
              _ExportActionRow(
                key: const ValueKey<String>('export-png-1x'),
                label: 'PNG 1×',
                badge: '1×',
                scale: scale,
                enabled: !_running,
                onPressed: () => unawaited(_runExport(InkExportKind.png1x)),
              ),
              _ExportActionRow(
                key: const ValueKey<String>('export-png-2x'),
                label: 'PNG 2×',
                badge: '2×',
                scale: scale,
                enabled: !_running,
                onPressed: () => unawaited(_runExport(InkExportKind.png2x)),
              ),
              _ExportActionRow(
                key: const ValueKey<String>('export-inkpack'),
                label: '.inkpack backup',
                badge: 'TAR',
                scale: scale,
                enabled: !_running,
                onPressed: () => unawaited(_runExport(InkExportKind.inkpack)),
              ),
              _DestinationRow(scale: scale),
              if (failureReason == null)
                _ExportStatusRow(kind: _lastKind, phase: _phase, scale: scale)
              else ...<Widget>[
                _ExportActionRow(
                  key: const ValueKey<String>('export-retry'),
                  label: 'failed — retry',
                  badge: '!',
                  scale: scale,
                  enabled: _lastKind != null && !_running,
                  onPressed: () => unawaited(_runExport(_lastKind!)),
                ),
                _FailureReasonRow(reason: failureReason, scale: scale),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ExportPanelHeader extends StatelessWidget {
  const _ExportPanelHeader({required this.scale, required this.onClose});

  final _ExportPanelScale scale;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      width: double.infinity,
      height: scale.u(exportPanelRowDesignHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: scale.u(exportPanelRowDesignHeight),
              child: CustomPaint(
                painter: InkGlyphPainter(
                  glyph: InkGlyph.markImport,
                  color: theme.palette.ink,
                  strokeWidth: scale.rule,
                ),
              ),
            ),
            Expanded(
              child: Text(
                'EXPORT',
                maxLines: 1,
                style: theme.type.heading.copyWith(
                  color: theme.palette.ink,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            _CloseButton(scale: scale, onPressed: onClose),
          ],
        ),
      ),
    );
  }
}

final class _ExportActionRow extends StatefulWidget {
  const _ExportActionRow({
    required this.label,
    required this.badge,
    required this.scale,
    required this.enabled,
    required this.onPressed,
    super.key,
  });

  final String label;
  final String badge;
  final _ExportPanelScale scale;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_ExportActionRow> createState() => _ExportActionRowState();
}

final class _ExportActionRowState extends State<_ExportActionRow> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final bool inverted = widget.enabled && _pressed;
    final Color background = inverted ? theme.palette.ink : theme.palette.paper;
    final Color foreground = !widget.enabled
        ? theme.palette.gray66
        : inverted
        ? theme.palette.paper
        : theme.palette.ink;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      excludeSemantics: true,
      label: widget.label,
      onTap: widget.enabled ? widget.onPressed : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapCancel: widget.enabled ? () => _setPressed(false) : null,
        onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
        onTap: widget.enabled ? widget.onPressed : null,
        child: SizedBox(
          width: double.infinity,
          height: widget.scale.u(exportPanelRowDesignHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                bottom: BorderSide(
                  color: theme.palette.ink,
                  width: widget.scale.rule,
                ),
              ),
            ),
            child: Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: widget.scale.u(exportPanelRowDesignHeight),
                  child: Center(
                    child: Text(
                      widget.badge,
                      style: theme.type.mono.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.label.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(width: widget.scale.u(12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _DestinationRow extends StatelessWidget {
  const _DestinationRow({required this.scale});

  final _ExportPanelScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      key: const ValueKey<String>('export-destination'),
      width: double.infinity,
      height: scale.u(exportPanelRowDesignHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: scale.u(12)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'DESTINATION',
                maxLines: 1,
                style: theme.type.caption.copyWith(
                  color: theme.palette.gray33,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.35,
                ),
              ),
              Text(
                'documents/exports/',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.mono.copyWith(
                  color: theme.palette.ink,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ExportStatusRow extends StatelessWidget {
  const _ExportStatusRow({
    required this.kind,
    required this.phase,
    required this.scale,
  });

  final InkExportKind? kind;
  final InkExportPhase? phase;
  final _ExportPanelScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final String state = switch (phase) {
      InkExportPhase.flattening => 'flattening…',
      InkExportPhase.writing => 'writing…',
      InkExportPhase.done => 'done',
      null => 'none yet',
    };
    return Semantics(
      liveRegion: true,
      label:
          'Last export, ${kind == null ? 'none yet' : '${_kindLabel(kind!)} $state'}',
      child: SizedBox(
        key: const ValueKey<String>('export-status'),
        width: double.infinity,
        height: scale.u(exportPanelRowDesignHeight),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.palette.paper,
            border: Border(
              bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: scale.u(12)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  kind == null
                      ? 'LAST EXPORT'
                      : 'LAST EXPORT  ·  ${_kindLabel(kind!)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.copyWith(
                    color: theme.palette.gray33,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.35,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      state,
                      maxLines: 1,
                      style: theme.type.label.copyWith(
                        color: theme.palette.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (phase == InkExportPhase.done) ...<Widget>[
                      SizedBox(width: scale.u(5)),
                      SizedBox.square(
                        dimension: scale.u(18),
                        child: CustomPaint(
                          painter: InkGlyphPainter(
                            glyph: InkGlyph.markCheck,
                            color: theme.palette.ink,
                            strokeWidth: scale.rule,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _FailureReasonRow extends StatelessWidget {
  const _FailureReasonRow({required this.reason, required this.scale});

  final String reason;
  final _ExportPanelScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      key: const ValueKey<String>('export-failure-reason'),
      width: double.infinity,
      height: scale.u(exportPanelRowDesignHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: scale.u(12)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.type.caption.copyWith(
                color: theme.palette.ink,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.scale, required this.onPressed});

  final _ExportPanelScale scale;
  final VoidCallback onPressed;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

final class _CloseButtonState extends State<_CloseButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperPalette palette = PaperTheme.of(context).palette;
    final Color background = _pressed ? palette.ink : palette.paper;
    final Color foreground = _pressed ? palette.paper : palette.ink;
    return Semantics(
      button: true,
      label: 'Close export panel',
      onTap: widget.onPressed,
      child: GestureDetector(
        key: const ValueKey<String>('export-close'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.onPressed,
        child: SizedBox.square(
          dimension: widget.scale.u(exportPanelRowDesignHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                left: BorderSide(color: palette.ink, width: widget.scale.rule),
              ),
            ),
            child: CustomPaint(
              painter: _CloseGlyphPainter(
                color: foreground,
                strokeWidth: widget.scale.rule,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CloseGlyphPainter extends CustomPainter {
  const _CloseGlyphPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect glyph = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 0.3,
      height: size.height * 0.3,
    );
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    canvas.drawLine(glyph.topLeft, glyph.bottomRight, paint);
    canvas.drawLine(glyph.topRight, glyph.bottomLeft, paint);
  }

  @override
  bool shouldRepaint(_CloseGlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}

final class _ExportPanelScale {
  const _ExportPanelScale(this.value);

  factory _ExportPanelScale.of(BuildContext context) {
    return _ExportPanelScale(inkViewportFitScaleOf(context));
  }

  final double value;

  double u(double designPx) => designPx * value;

  double get rule => math.max(1, u(2));
}

String _kindLabel(InkExportKind kind) => switch (kind) {
  InkExportKind.png1x => 'PNG 1×',
  InkExportKind.png2x => 'PNG 2×',
  InkExportKind.inkpack => '.inkpack',
};

String _errorReason(Object error) {
  final String reason = '$error'.trim();
  return reason.isEmpty ? 'I/O error' : reason;
}
