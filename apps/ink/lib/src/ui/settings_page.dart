import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../engine/brush_engine.dart';
import '../engine/brush_presets.dart';
import '../model/settings_model.dart';
import 'responsive_layout.dart';

/// Ink's deliberately small global-settings surface.
final class SettingsPage extends StatefulWidget {
  /// Creates settings backed by [model].
  const SettingsPage({
    required this.model,
    required this.onBack,
    required this.onDeepClean,
    this.onShowLicenses,
    this.autoLoad = true,
    super.key,
  });

  /// Persistent settings owner.
  final InkSettingsModel model;

  /// Returns to the gallery or editor that presented settings.
  final VoidCallback onBack;

  /// Requests a full display refresh through the injected system bridge.
  final Future<void> Function() onDeepClean;

  /// Optional host-owned licenses route.
  final VoidCallback? onShowLicenses;

  /// Whether an uninitialized model should load during [State.initState].
  final bool autoLoad;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  String? _deepCleanMessage;

  @override
  void initState() {
    super.initState();
    if (widget.autoLoad &&
        widget.model.phase == InkSettingsPhase.uninitialized) {
      unawaited(widget.model.load());
    }
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, widget.model) &&
        widget.autoLoad &&
        widget.model.phase == InkSettingsPhase.uninitialized) {
      unawaited(widget.model.load());
    }
  }

  Future<void> _deepClean() async {
    setState(() {
      _deepCleanMessage = 'refreshing display';
    });
    try {
      await widget.onDeepClean();
      if (mounted) {
        setState(() {
          _deepCleanMessage = 'display refreshed';
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _deepCleanMessage = 'refresh unavailable';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (BuildContext context, Widget? child) {
        return PaperScaffold(
          showStatusBar: false,
          header: PageHeader(
            title: 'settings',
            leading: PaperButton.ghost(
              key: const ValueKey<String>('settings-back'),
              label: '← back',
              onPressed: widget.onBack,
            ),
          ),
          body: switch (widget.model.phase) {
            InkSettingsPhase.uninitialized || InkSettingsPhase.loading =>
              const PaperLoadingState(label: 'loading settings'),
            InkSettingsPhase.ready => _buildSettings(context),
          },
        );
      },
    );
  }

  Widget _buildSettings(BuildContext context) {
    final InkSettings settings = widget.model.settings;
    final String? feedback =
        widget.model.persistenceMessage ?? _deepCleanMessage;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        PaperSpacing.pageMargin,
        PaperSpacing.space16,
        PaperSpacing.pageMargin,
        PaperSpacing.space48,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (feedback != null) ...<Widget>[
            _SettingsNote(
              message: feedback,
              onDismiss: () {
                widget.model.dismissPersistenceMessage();
                setState(() {
                  _deepCleanMessage = null;
                });
              },
            ),
            const SizedBox(height: PaperSpacing.space16),
          ],
          _SettingsSection(
            title: 'input',
            children: <Widget>[
              _SettingsRow(
                title: 'finger drawing',
                subtitle: 'draw with touch when the marker is away',
                trailing: PaperToggle(
                  key: const ValueKey<String>('finger-draw-toggle'),
                  value: settings.fingerDrawing,
                  onChanged: (bool value) =>
                      unawaited(widget.model.setFingerDrawing(value)),
                ),
              ),
              _SettingsRow(
                title: 'eraser default',
                subtitle: 'used by the eraser tool and flipped marker',
                trailing: SegmentedControl<EraserDefaultPreference>(
                  key: const ValueKey<String>('eraser-default-control'),
                  selected: settings.eraserDefault,
                  onChanged: (EraserDefaultPreference value) =>
                      unawaited(widget.model.setEraserDefault(value)),
                  segments: const <PaperSegment<EraserDefaultPreference>>[
                    PaperSegment<EraserDefaultPreference>(
                      value: EraserDefaultPreference.pixel,
                      label: 'pixel',
                    ),
                    PaperSegment<EraserDefaultPreference>(
                      value: EraserDefaultPreference.stroke,
                      label: 'stroke',
                    ),
                    PaperSegment<EraserDefaultPreference>(
                      value: EraserDefaultPreference.lasso,
                      label: 'lasso',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PaperSpacing.space20),
          _SettingsSection(
            title: 'bench',
            children: <Widget>[
              _SettingsRow(
                title: 'dock edge',
                subtitle: 'global default for every artwork',
                trailing: SegmentedControl<BenchDockPreference>(
                  key: const ValueKey<String>('bench-dock-control'),
                  selected: settings.benchDock,
                  onChanged: (BenchDockPreference value) =>
                      unawaited(widget.model.setBenchDock(value)),
                  segments: const <PaperSegment<BenchDockPreference>>[
                    PaperSegment<BenchDockPreference>(
                      value: BenchDockPreference.left,
                      label: 'left',
                    ),
                    PaperSegment<BenchDockPreference>(
                      value: BenchDockPreference.right,
                      label: 'right',
                    ),
                    PaperSegment<BenchDockPreference>(
                      value: BenchDockPreference.top,
                      label: 'top',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PaperSpacing.space20),
          _SettingsSection(
            title: 'grid defaults',
            children: <Widget>[
              _SettingsRow(
                title: 'show grid',
                subtitle: 'non-exporting guide on newly opened canvases',
                trailing: PaperToggle(
                  key: const ValueKey<String>('grid-enabled-toggle'),
                  value: settings.gridEnabled,
                  onChanged: (bool value) =>
                      unawaited(widget.model.setGridEnabled(value)),
                ),
              ),
              _SettingsRow(
                title: 'mark',
                trailing: SegmentedControl<GridStylePreference>(
                  key: const ValueKey<String>('grid-style-control'),
                  selected: settings.gridStyle,
                  onChanged: (GridStylePreference value) =>
                      unawaited(widget.model.setGridStyle(value)),
                  segments: const <PaperSegment<GridStylePreference>>[
                    PaperSegment<GridStylePreference>(
                      value: GridStylePreference.line,
                      label: 'line',
                    ),
                    PaperSegment<GridStylePreference>(
                      value: GridStylePreference.dot,
                      label: 'dot',
                    ),
                  ],
                ),
              ),
              _SettingsRow(
                title: 'spacing',
                trailing: SegmentedControl<int>(
                  key: const ValueKey<String>('grid-spacing-control'),
                  selected: settings.gridSpacing,
                  onChanged: (int value) =>
                      unawaited(widget.model.setGridSpacing(value)),
                  segments: const <PaperSegment<int>>[
                    PaperSegment<int>(value: 8, label: '8'),
                    PaperSegment<int>(value: 16, label: '16'),
                    PaperSegment<int>(value: 32, label: '32'),
                    PaperSegment<int>(value: 64, label: '64'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PaperSpacing.space20),
          _SettingsSection(
            title: 'pressure curve',
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(PaperSpacing.space16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SegmentedControl<PressureCurvePreference>(
                      key: const ValueKey<String>('pressure-curve-control'),
                      selected: settings.pressureCurve,
                      onChanged: (PressureCurvePreference value) =>
                          unawaited(widget.model.setPressureCurve(value)),
                      segments: const <PaperSegment<PressureCurvePreference>>[
                        PaperSegment<PressureCurvePreference>(
                          value: PressureCurvePreference.soft,
                          label: 'soft',
                        ),
                        PaperSegment<PressureCurvePreference>(
                          value: PressureCurvePreference.normal,
                          label: 'normal',
                        ),
                        PaperSegment<PressureCurvePreference>(
                          value: PressureCurvePreference.firm,
                          label: 'firm',
                        ),
                      ],
                    ),
                    const SizedBox(height: PaperSpacing.space12),
                    InkPressurePreview(curve: settings.pressureCurve),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: PaperSpacing.space20),
          _SettingsSection(
            title: 'display & app',
            children: <Widget>[
              _SettingsRow(
                title: 'deep clean',
                subtitle: 'request one full display refresh',
                trailing: PaperButton(
                  key: const ValueKey<String>('deep-clean-button'),
                  label: 'refresh',
                  onPressed: () => unawaited(_deepClean()),
                ),
              ),
              _SettingsRow(
                title: 'about & licenses',
                subtitle: 'Ink 0.1.0 · bundled font licenses',
                trailing: PaperButton.ghost(
                  key: const ValueKey<String>('about-button'),
                  label: 'open',
                  onPressed: () => _showAbout(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
    unawaited(
      PaperDialogs.show<void>(
        context,
        builder: (BuildContext dialogContext) => PaperDialog(
          title: 'about Ink',
          actions: <Widget>[
            PaperButton(
              label: 'licenses',
              onPressed: () {
                Navigator.of(dialogContext).pop();
                final VoidCallback? callback = widget.onShowLicenses;
                if (callback != null) {
                  callback();
                } else {
                  _showLicenses(context);
                }
              },
            ),
            PaperButton.primary(
              label: 'done',
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
          child: Text(
            'Ink 0.1.0\nA drawing studio made for paper displays.',
            style: PaperTheme.of(dialogContext).type.body,
          ),
        ),
      ),
    );
  }

  void _showLicenses(BuildContext context) {
    unawaited(
      PaperDialogs.show<void>(
        context,
        builder: (BuildContext dialogContext) => PaperDialog(
          title: 'licenses',
          actions: <Widget>[
            PaperButton.primary(
              label: 'done',
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
          child: Text(
            'Inter — SIL Open Font License 1.1\n'
            'JetBrains Mono — SIL Open Font License 1.1\n'
            'Flutter and Dart — BSD-style licenses',
            style: PaperTheme.of(dialogContext).type.body,
          ),
        ),
      ),
    );
  }
}

/// Synchronous brush-engine pressure sample; no image decode is involved.
final class InkPressurePreview extends StatelessWidget {
  /// Creates a preview for one global pressure response.
  const InkPressurePreview({required this.curve, super.key});

  /// Response applied before the brush-local map.
  final PressureCurvePreference curve;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      label: '${curve.name} pressure sample stroke',
      image: true,
      child: SizedBox(
        height: 88,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.palette.paper,
            border: Border.all(
              color: theme.palette.ink,
              width: PaperSpacing.hairline,
            ),
          ),
          child: CustomPaint(
            painter: _PressurePreviewPainter(
              stamps: _pressurePreviewStamps(curve),
              color: theme.palette.ink,
            ),
          ),
        ),
      ),
    );
  }
}

final Map<PressureCurvePreference, List<ResolvedBrushStamp>>
_pressurePreviewCache = <PressureCurvePreference, List<ResolvedBrushStamp>>{};

List<ResolvedBrushStamp> _pressurePreviewStamps(PressureCurvePreference curve) {
  return _pressurePreviewCache.putIfAbsent(curve, () {
    final RecordingBrushStampTarget target = RecordingBrushStampTarget();
    final BrushEngine engine = BrushEngine(
      spec: brushpenBrush,
      target: target,
      seed: 0x1a2b3c,
      colorArgb: 0xff000000,
      size: 15,
    );
    engine.stampAlong(<BrushPoint>[
      for (var index = 0; index <= 28; index += 1)
        BrushPoint(
          point: Offset(12 + index * 10.5, 45 + math.sin(index / 4) * 4),
          pressure: curve.mapPressure(0.08 + index / 31),
          timestamp: Duration(milliseconds: index * 12),
        ),
    ]);
    engine.finalize();
    return List<ResolvedBrushStamp>.unmodifiable(target.stamps);
  });
}

final class _PressurePreviewPainter extends CustomPainter {
  const _PressurePreviewPainter({required this.stamps, required this.color});

  final List<ResolvedBrushStamp> stamps;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    canvas.save();
    canvas.scale(size.width / 320, size.height / 88);
    for (final ResolvedBrushStamp stamp in stamps) {
      final int alpha = (stamp.flow * 255).round().clamp(0, 255);
      final Paint paint = Paint()
        ..color = color.withAlpha(alpha)
        ..style = PaintingStyle.fill;
      canvas.save();
      canvas.translate(stamp.center.dx, stamp.center.dy);
      canvas.rotate(stamp.angleRadians);
      final Rect bounds = Rect.fromCenter(
        center: Offset.zero,
        width: stamp.diameterX,
        height: stamp.diameterY,
      );
      if (stamp.nibKind == NibKind.chisel) {
        canvas.drawRect(bounds, paint..isAntiAlias = false);
      } else {
        canvas.drawOval(bounds, paint..isAntiAlias = true);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PressurePreviewPainter oldDelegate) =>
      !identical(stamps, oldDelegate.stamps) || color != oldDelegate.color;
}

final class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(title, style: theme.type.heading),
        const SizedBox(height: PaperSpacing.space8),
        PaperSurface(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (
                var index = 0;
                index < children.length;
                index += 1
              ) ...<Widget>[
                if (index > 0)
                  ColoredBox(
                    color: theme.palette.ink,
                    child: const SizedBox(height: PaperSpacing.hairline),
                  ),
                children[index],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

final class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.title,
    required this.trailing,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 80),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Widget label = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: theme.type.body),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: theme.type.caption.copyWith(
                    color: theme.palette.gray33,
                  ),
                ),
            ],
          );
          final double scale = inkViewportFitScaleOf(context);
          final bool stackControls = constraints.maxWidth / scale < 680;
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PaperSpacing.space16,
              vertical: PaperSpacing.space8,
            ),
            child: stackControls
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      label,
                      const SizedBox(height: PaperSpacing.space8),
                      Align(alignment: Alignment.centerRight, child: trailing),
                    ],
                  )
                : Row(
                    children: <Widget>[
                      Expanded(child: label),
                      const SizedBox(width: PaperSpacing.space16),
                      trailing,
                    ],
                  ),
          );
        },
      ),
    );
  }
}

final class _SettingsNote extends StatelessWidget {
  const _SettingsNote({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border.all(
            color: theme.palette.ink,
            width: PaperSpacing.rule,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PaperSpacing.space16,
            vertical: PaperSpacing.space12,
          ),
          child: Text('$message · tap to dismiss', style: theme.type.caption),
        ),
      ),
    );
  }
}
