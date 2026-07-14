import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../../engine/brush_engine.dart';
import '../../engine/brush_presets.dart';
import '../responsive_layout.dart';

/// Width of the brush sheet in the 954 x 1696 authored coordinate space.
const double brushPanelDesignWidth = 437;

/// Full brush-sheet height below the authored 88-dpx status band.
const double brushPanelDesignHeight = 1608;

/// Height of the title and close-control row.
const double brushPanelHeaderDesignHeight = 80;

/// Height of every brush choice in the authored coordinate space.
const double brushPanelRowDesignHeight = 80;

/// Number of drawing brushes shown by [BrushPanel].
const int brushPanelBrushCount = 16;

/// Whether the hidden tuning surface was enabled for this build.
const bool inkTuneBuild =
    bool.fromEnvironment('INK_TUNE') ||
    String.fromEnvironment('INK_TUNE') == '1';

const double _designOptionHeight = 112;
const double _designFooterHeight = 80;
const Size _miniProofSize = Size(152, 56);

/// Hatching behavior selected in the hatcher brush option row.
enum HatcherStrokeMode {
  /// Lay a single family of 45-degree hatch lines.
  hatch,

  /// Add the snapshot-based second pass over existing hatch.
  crosshatch,
}

/// Immutable values owned by the host of [BrushPanel].
///
/// Four-notch values are zero based. Keeping the values here, instead of in
/// the panel widget, makes option changes journal-friendly and deterministic.
final class BrushPanelOptions {
  /// Creates the current brush option values.
  const BrushPanelOptions({
    this.toneShaderDirection = ShadeDirection.darker,
    this.hatcherMode = HatcherStrokeMode.hatch,
    this.sprayDensity = 2,
    this.stippleDensity = 2,
    this.pencilHbGrain = 1,
    this.pencil6bGrain = 2,
    this.charcoalGrain = 3,
  }) : assert(sprayDensity >= 0 && sprayDensity < 4),
       assert(stippleDensity >= 0 && stippleDensity < 4),
       assert(pencilHbGrain >= 0 && pencilHbGrain < 4),
       assert(pencil6bGrain >= 0 && pencil6bGrain < 4),
       assert(charcoalGrain >= 0 && charcoalGrain < 4);

  /// Darker or lighter absolute-lattice tone-shader pass.
  final ShadeDirection toneShaderDirection;

  /// Single-hatch or snapshot-based crosshatch behavior.
  final HatcherStrokeMode hatcherMode;

  /// Four-step spray particle density.
  final int sprayDensity;

  /// Four-step stipple particle density.
  final int stippleDensity;

  /// Four-step HB pencil grain depth.
  final int pencilHbGrain;

  /// Four-step 6B pencil grain depth.
  final int pencil6bGrain;

  /// Four-step charcoal grain depth.
  final int charcoalGrain;

  /// Returns the density notch for a particle brush id.
  int particleDensityFor(String brushId) {
    return switch (brushId) {
      'spray' => sprayDensity,
      'stipple' => stippleDensity,
      _ => throw ArgumentError.value(
        brushId,
        'brushId',
        'does not have a particle-density option',
      ),
    };
  }

  /// Returns the grain notch for a graphite or charcoal brush id.
  int grainFor(String brushId) {
    return switch (brushId) {
      'pencilhb' => pencilHbGrain,
      'pencil6b' => pencil6bGrain,
      'charcoal' => charcoalGrain,
      _ => throw ArgumentError.value(
        brushId,
        'brushId',
        'does not have a grain option',
      ),
    };
  }

  /// Returns a copy with the supplied option values replaced.
  BrushPanelOptions copyWith({
    ShadeDirection? toneShaderDirection,
    HatcherStrokeMode? hatcherMode,
    int? sprayDensity,
    int? stippleDensity,
    int? pencilHbGrain,
    int? pencil6bGrain,
    int? charcoalGrain,
  }) {
    return BrushPanelOptions(
      toneShaderDirection: toneShaderDirection ?? this.toneShaderDirection,
      hatcherMode: hatcherMode ?? this.hatcherMode,
      sprayDensity: sprayDensity ?? this.sprayDensity,
      stippleDensity: stippleDensity ?? this.stippleDensity,
      pencilHbGrain: pencilHbGrain ?? this.pencilHbGrain,
      pencil6bGrain: pencil6bGrain ?? this.pencil6bGrain,
      charcoalGrain: charcoalGrain ?? this.charcoalGrain,
    );
  }
}

/// One synchronously recorded mini proof rendered by [BrushMiniProofPainter].
final class BrushMiniProofPlan {
  /// Creates an immutable mini-proof plan.
  BrushMiniProofPlan({
    required this.brush,
    required this.selectedSize,
    required this.seed,
    required Iterable<ResolvedBrushStamp> stamps,
  }) : stamps = List<ResolvedBrushStamp>.unmodifiable(stamps) {
    if (!selectedSize.isFinite || selectedSize <= 0) {
      throw ArgumentError.value(
        selectedSize,
        'selectedSize',
        'must be finite and positive',
      );
    }
    if (this.stamps.isEmpty) {
      throw ArgumentError.value(stamps, 'stamps', 'must not be empty');
    }
  }

  /// Brush data used by the production stamper.
  final BrushSpec brush;

  /// Selected brush diameter supplied to the stamper.
  final double selectedSize;

  /// Stable seed derived from the brush id.
  final int seed;

  /// Target-independent impressions recorded from [BrushEngine].
  final List<ResolvedBrushStamp> stamps;

  /// Authored coordinate space occupied by [stamps].
  Size get size => _miniProofSize;
}

final Map<(BrushSpec, int), BrushMiniProofPlan> _miniProofCache =
    <(BrushSpec, int), BrushMiniProofPlan>{};

/// Primitive used to paint a resolved mini-proof stamp.
enum BrushMiniProofShape {
  /// Disc, ellipse, texture, and particle impressions retain oval coverage.
  oval,

  /// Calligraphy, marker, and highlighter impressions use a crisp rectangle.
  chiselRectangle,
}

/// Resolves the proof geometry from the nib metadata emitted by the engine.
BrushMiniProofShape brushMiniProofShapeFor(ResolvedBrushStamp stamp) {
  return stamp.nibKind == NibKind.chisel
      ? BrushMiniProofShape.chiselRectangle
      : BrushMiniProofShape.oval;
}

/// Axis-aligned bounds of [stamp]'s proof geometry after nib rotation.
Rect brushMiniProofStampBounds(ResolvedBrushStamp stamp) {
  if (brushMiniProofShapeFor(stamp) == BrushMiniProofShape.oval) {
    return stamp.bounds;
  }
  final double radiusX = stamp.diameterX / 2;
  final double radiusY = stamp.diameterY / 2;
  final double cosine = math.cos(stamp.angleRadians).abs();
  final double sine = math.sin(stamp.angleRadians).abs();
  final double extentX = radiusX * cosine + radiusY * sine;
  final double extentY = radiusX * sine + radiusY * cosine;
  return Rect.fromCenter(
    center: stamp.center,
    width: extentX * 2,
    height: extentY * 2,
  );
}

/// Whether [point] is covered by [stamp]'s resolved proof geometry.
///
/// The inverse rotation is shared by the capped marker/highlighter coverage
/// path. Grained stamps apply their grain after the same oval footprint test.
bool brushMiniProofStampContains(ResolvedBrushStamp stamp, Offset point) {
  final Offset delta = point - stamp.center;
  final double cosine = math.cos(stamp.angleRadians);
  final double sine = math.sin(stamp.angleRadians);
  final double localX = delta.dx * cosine + delta.dy * sine;
  final double localY = -delta.dx * sine + delta.dy * cosine;
  final double radiusX = stamp.diameterX / 2;
  final double radiusY = stamp.diameterY / 2;
  return switch (brushMiniProofShapeFor(stamp)) {
    BrushMiniProofShape.chiselRectangle =>
      localX.abs() <= radiusX && localY.abs() <= radiusY,
    BrushMiniProofShape.oval =>
      localX * localX / (radiusX * radiusX) +
              localY * localY / (radiusY * radiusY) <=
          1,
  };
}

/// Records a deterministic mini proof through the production brush stamper.
///
/// The result is cached by brush identity and thousandth-of-a-dpx size. This
/// function performs no image decoding, file access, isolate work, or futures.
BrushMiniProofPlan buildBrushMiniProofPlan(BrushSpec brush, {double? size}) {
  final double selectedSize = _resolvedBrushSize(brush, size);
  final (BrushSpec, int) key = (brush, (selectedSize * 1000).round());
  return _miniProofCache.putIfAbsent(key, () {
    final RecordingBrushStampTarget target = RecordingBrushStampTarget();
    final int seed = _proofSeed(brush.id);
    final BrushEngine engine = BrushEngine(
      spec: brush,
      target: target,
      seed: seed,
      colorArgb: 0xff000000,
      size: selectedSize,
    );
    engine.stampAlong(_miniProofPoints());
    engine.finalize();
    return BrushMiniProofPlan(
      brush: brush,
      selectedSize: selectedSize,
      seed: seed,
      stamps: target.stamps,
    );
  });
}

/// Formats a current brush size for the mono metadata column.
String brushPanelSizeLabel(double size) {
  if (!size.isFinite || size <= 0) {
    throw ArgumentError.value(size, 'size', 'must be finite and positive');
  }
  final bool integral = (size - size.roundToDouble()).abs() < 0.000001;
  return '${integral ? size.round() : size.toStringAsFixed(1)} dpx';
}

/// Full-height, non-scrolling catalog of the sixteen Ink drawing brushes.
///
/// Geometry uses the 954 x 1696 authoring grid as a reference and resolves
/// against the current Flutter viewport. A 477-lp DPR-2 golden therefore
/// produces the same 437-pixel sheet and 80-pixel rows as the reference
/// presentation.
final class BrushPanel extends StatelessWidget {
  /// Creates the brush catalog and its current-brush option row.
  const BrushPanel({
    required this.activeBrushId,
    required this.onClose,
    required this.onBrushSelected,
    required this.onOptionsChanged,
    this.brushes = drawingBrushes,
    this.brushSizes = const <String, double>{},
    this.options = const BrushPanelOptions(),
    this.inkTune = inkTuneBuild,
    this.onOpenProofSheet,
    super.key,
  }) : assert(brushes.length == brushPanelBrushCount);

  /// Stable id of the currently selected drawing brush.
  final String activeBrushId;

  /// Closes this sheet without changing the selected brush.
  final VoidCallback onClose;

  /// Called with the selected catalog identity.
  final ValueChanged<BrushSpec> onBrushSelected;

  /// Called with a complete replacement option value.
  final ValueChanged<BrushPanelOptions> onOptionsChanged;

  /// Drawing-only catalog in proof-sheet order.
  final List<BrushSpec> brushes;

  /// Current size by brush id; omitted entries use each preset default.
  final Map<String, double> brushSizes;

  /// Current brush-specific option values.
  final BrushPanelOptions options;

  /// Whether to include the hidden proof-sheet footer.
  final bool inkTune;

  /// Opens the full proof sheet when [inkTune] is true.
  final VoidCallback? onOpenProofSheet;

  @override
  Widget build(BuildContext context) {
    final _BrushPanelScale scale = _BrushPanelScale.of(context);
    _validateBrushCatalog(brushes, activeBrushId: activeBrushId);
    final BrushSpec activeBrush = brushes.singleWhere(
      (BrushSpec brush) => brush.id == activeBrushId,
    );

    return SizedBox(
      width: scale.u(brushPanelDesignWidth),
      height: scale.u(brushPanelDesignHeight),
      child: PaperSurface(
        plateShadow: true,
        radius: 0,
        padding: EdgeInsets.zero,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Brush catalog, sixteen brushes',
          child: Column(
            children: <Widget>[
              _BrushPanelHeader(scale: scale, onClose: onClose),
              for (final BrushSpec brush in brushes)
                _BrushCatalogRow(
                  brush: brush,
                  selectedSize: _resolvedBrushSize(brush, brushSizes[brush.id]),
                  active: brush.id == activeBrushId,
                  scale: scale,
                  onSelected: () => onBrushSelected(brush),
                ),
              SizedBox(
                height: scale.u(_designOptionHeight),
                child: _BrushOptionRow(
                  brush: activeBrush,
                  options: options,
                  scale: scale,
                  onChanged: onOptionsChanged,
                ),
              ),
              const Spacer(),
              if (inkTune)
                SizedBox(
                  height: scale.u(_designFooterHeight),
                  width: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: PaperTheme.of(context).palette.ink,
                          width: scale.rule,
                        ),
                      ),
                    ),
                    child: PaperButton.ghost(
                      label: 'proof sheet',
                      onPressed: onOpenProofSheet,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _BrushPanelHeader extends StatelessWidget {
  const _BrushPanelHeader({required this.scale, required this.onClose});

  final _BrushPanelScale scale;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      height: scale.u(brushPanelHeaderDesignHeight),
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: scale.u(16)),
                child: Text(
                  'BRUSHES',
                  maxLines: 1,
                  style: theme.type.heading.copyWith(
                    color: theme.palette.ink,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            _BrushPanelCloseButton(scale: scale, onPressed: onClose),
          ],
        ),
      ),
    );
  }
}

final class _BrushPanelCloseButton extends StatefulWidget {
  const _BrushPanelCloseButton({required this.scale, required this.onPressed});

  final _BrushPanelScale scale;
  final VoidCallback onPressed;

  @override
  State<_BrushPanelCloseButton> createState() => _BrushPanelCloseButtonState();
}

final class _BrushPanelCloseButtonState extends State<_BrushPanelCloseButton> {
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
      label: 'Close brush panel',
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.onPressed,
        child: SizedBox.square(
          dimension: widget.scale.u(brushPanelHeaderDesignHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                left: BorderSide(color: palette.ink, width: widget.scale.rule),
              ),
            ),
            child: CustomPaint(
              painter: _BrushPanelCloseGlyphPainter(
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

final class _BrushPanelCloseGlyphPainter extends CustomPainter {
  const _BrushPanelCloseGlyphPainter({
    required this.color,
    required this.strokeWidth,
  });

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    final Rect glyph = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 0.3,
      height: size.height * 0.3,
    );
    canvas.drawLine(glyph.topLeft, glyph.bottomRight, paint);
    canvas.drawLine(glyph.topRight, glyph.bottomLeft, paint);
  }

  @override
  bool shouldRepaint(_BrushPanelCloseGlyphPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}

final class _BrushCatalogRow extends StatefulWidget {
  const _BrushCatalogRow({
    required this.brush,
    required this.selectedSize,
    required this.active,
    required this.scale,
    required this.onSelected,
  });

  final BrushSpec brush;
  final double selectedSize;
  final bool active;
  final _BrushPanelScale scale;
  final VoidCallback onSelected;

  @override
  State<_BrushCatalogRow> createState() => _BrushCatalogRowState();
}

final class _BrushCatalogRowState extends State<_BrushCatalogRow> {
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
    final bool inverted = widget.active || _pressed;
    final Color background = inverted ? theme.palette.ink : theme.palette.paper;
    final Color foreground = inverted ? theme.palette.paper : theme.palette.ink;
    final BrushMiniProofPlan proof = buildBrushMiniProofPlan(
      widget.brush,
      size: widget.selectedSize,
    );
    final String sizeLabel = brushPanelSizeLabel(widget.selectedSize);

    return Semantics(
      button: true,
      selected: widget.active,
      label: '${widget.brush.name}, $sizeLabel',
      onTap: widget.onSelected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.onSelected,
        child: SizedBox(
          height: widget.scale.u(brushPanelRowDesignHeight),
          width: double.infinity,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                bottom: BorderSide(color: foreground, width: widget.scale.rule),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.scale.u(12)),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: widget.scale.u(160),
                    height: widget.scale.u(56),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: BrushMiniProofPainter(
                          plan: proof,
                          color: foreground,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: widget.scale.u(12)),
                  Expanded(
                    child: Text(
                      widget.brush.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.label.copyWith(color: foreground),
                    ),
                  ),
                  SizedBox(width: widget.scale.u(8)),
                  SizedBox(
                    width: widget.scale.u(80),
                    child: Text(
                      sizeLabel,
                      maxLines: 1,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.clip,
                      style: theme.type.mono.copyWith(
                        color: foreground,
                        fontSize: 12,
                      ),
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

final class _BrushOptionRow extends StatelessWidget {
  const _BrushOptionRow({
    required this.brush,
    required this.options,
    required this.scale,
    required this.onChanged,
  });

  final BrushSpec brush;
  final BrushPanelOptions options;
  final _BrushPanelScale scale;
  final ValueChanged<BrushPanelOptions> onChanged;

  @override
  Widget build(BuildContext context) {
    return switch (brush.id) {
      'toneshader' => _OptionShell(
        label: 'DIRECTION',
        semanticsLabel:
            'Tone shader direction, ${options.toneShaderDirection.name}',
        scale: scale,
        child: SegmentedControl<ShadeDirection>(
          segments: const <PaperSegment<ShadeDirection>>[
            PaperSegment<ShadeDirection>(
              value: ShadeDirection.darker,
              label: 'darker',
            ),
            PaperSegment<ShadeDirection>(
              value: ShadeDirection.lighter,
              label: 'lighter',
            ),
          ],
          selected: options.toneShaderDirection,
          onChanged: (ShadeDirection value) {
            onChanged(options.copyWith(toneShaderDirection: value));
          },
        ),
      ),
      'hatcher' => _OptionShell(
        label: 'PATTERN',
        semanticsLabel: 'Hatcher pattern, ${options.hatcherMode.name}',
        scale: scale,
        child: SegmentedControl<HatcherStrokeMode>(
          segments: const <PaperSegment<HatcherStrokeMode>>[
            PaperSegment<HatcherStrokeMode>(
              value: HatcherStrokeMode.hatch,
              label: 'hatch',
            ),
            PaperSegment<HatcherStrokeMode>(
              value: HatcherStrokeMode.crosshatch,
              label: 'cross',
            ),
          ],
          selected: options.hatcherMode,
          onChanged: (HatcherStrokeMode value) {
            onChanged(options.copyWith(hatcherMode: value));
          },
        ),
      ),
      'spray' || 'stipple' => _OptionShell(
        label: 'DENSITY',
        semanticsLabel:
            '${brush.name} density, ${options.particleDensityFor(brush.id) + 1} of 4',
        scale: scale,
        child: DiscreteSlider(
          notchCount: 4,
          notchIndex: options.particleDensityFor(brush.id),
          trailingLabel: '${options.particleDensityFor(brush.id) + 1} / 4',
          onNotchChanged: (int value) {
            onChanged(
              brush.id == 'spray'
                  ? options.copyWith(sprayDensity: value)
                  : options.copyWith(stippleDensity: value),
            );
          },
        ),
      ),
      'pencilhb' || 'pencil6b' || 'charcoal' => _OptionShell(
        label: 'GRAIN',
        semanticsLabel:
            '${brush.name} grain, ${options.grainFor(brush.id) + 1} of 4',
        scale: scale,
        child: DiscreteSlider(
          notchCount: 4,
          notchIndex: options.grainFor(brush.id),
          trailingLabel: '${options.grainFor(brush.id) + 1} / 4',
          onNotchChanged: (int value) {
            onChanged(switch (brush.id) {
              'pencilhb' => options.copyWith(pencilHbGrain: value),
              'pencil6b' => options.copyWith(pencil6bGrain: value),
              _ => options.copyWith(charcoalGrain: value),
            });
          },
        ),
      ),
      'marker' => _OptionReadout(
        label: 'OVERLAP',
        value: 'cap · 2 passes',
        semanticsLabel: 'Marker overlap capped at two passes per stroke',
        scale: scale,
      ),
      'highlighter' => _OptionReadout(
        label: 'OVERLAP',
        value: '1 pass · luma 12+',
        semanticsLabel:
            'Highlighter overlap capped at one pass and luma level twelve',
        scale: scale,
      ),
      _ => _OptionReadout(
        label: 'PRESET',
        value: _presetReadout(brush),
        semanticsLabel: '${brush.name}, ${_presetReadout(brush)}',
        scale: scale,
      ),
    };
  }
}

final class _OptionShell extends StatelessWidget {
  const _OptionShell({
    required this.label,
    required this.semanticsLabel,
    required this.scale,
    required this.child,
  });

  final String label;
  final String semanticsLabel;
  final _BrushPanelScale scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: scale.u(12)),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: scale.u(96),
                child: Text(label, style: theme.type.caption),
              ),
              SizedBox(width: scale.u(8)),
              Expanded(
                child: SizedBox(
                  height: scale.u(80),
                  child: Center(child: child),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _OptionReadout extends StatelessWidget {
  const _OptionReadout({
    required this.label,
    required this.value,
    required this.semanticsLabel,
    required this.scale,
  });

  final String label;
  final String value;
  final String semanticsLabel;
  final _BrushPanelScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      container: true,
      readOnly: true,
      label: semanticsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: scale.u(12)),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: scale.u(104),
                child: Text(label, style: theme.type.caption),
              ),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.mono,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Synchronous painter for one cached [BrushMiniProofPlan].
final class BrushMiniProofPainter extends CustomPainter {
  /// Creates a direct-stamp mini painter.
  const BrushMiniProofPainter({
    required this.plan,
    this.color = const Color(0xff000000),
  });

  /// Cached target-independent stamps.
  final BrushMiniProofPlan plan;

  /// Foreground used for normal and active-inverted rows.
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / plan.size.width, size.height / plan.size.height);
    final List<ResolvedBrushStamp> capped = <ResolvedBrushStamp>[
      for (final ResolvedBrushStamp stamp in plan.stamps)
        if (stamp.maxOverlapSteps > 0) stamp,
    ];
    if (capped.isNotEmpty) {
      _paintCappedStamps(canvas, capped);
    }
    for (final ResolvedBrushStamp stamp in plan.stamps) {
      if (stamp.maxOverlapSteps == 0) {
        _paintStamp(canvas, stamp);
      }
    }
    canvas.restore();
  }

  void _paintCappedStamps(Canvas canvas, List<ResolvedBrushStamp> stamps) {
    final int width = plan.size.width.ceil();
    final int height = plan.size.height.ceil();
    final StrokeCoverageMask coverageMask = StrokeCoverageMask.forBrush(
      plan.brush,
      width: width,
      height: height,
    );
    final List<double> outputAlpha = List<double>.filled(width * height, 0);
    for (final ResolvedBrushStamp stamp in stamps) {
      final Rect stampBounds = brushMiniProofStampBounds(stamp);
      final int top = math.max(0, stampBounds.top.floor());
      final int bottom = math.min(height, stampBounds.bottom.ceil());
      final int left = math.max(0, stampBounds.left.floor());
      final int right = math.min(width, stampBounds.right.ceil());
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          if (!brushMiniProofStampContains(stamp, Offset(x + 0.5, y + 0.5))) {
            continue;
          }
          final double accepted = coverageMask.takeCoverage(x, y, 1);
          if (accepted == 0) {
            continue;
          }
          final int index = y * width + x;
          final double source = (stamp.flow * accepted).clamp(0.0, 1.0);
          outputAlpha[index] = source + outputAlpha[index] * (1 - source);
        }
      }
    }

    final int argb = color.toARGB32();
    final int sourceAlpha = (argb >>> 24) & 0xff;
    final Paint pixel = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final int alpha = (sourceAlpha * outputAlpha[y * width + x])
            .round()
            .clamp(0, 255);
        if (alpha == 0) {
          continue;
        }
        pixel.color = Color.fromARGB(
          alpha,
          (argb >>> 16) & 0xff,
          (argb >>> 8) & 0xff,
          argb & 0xff,
        );
        canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), pixel);
      }
    }
  }

  void _paintStamp(Canvas canvas, ResolvedBrushStamp stamp) {
    final ResolvedBrushGrain? grain = stamp.grain;
    if (grain != null) {
      _paintGrainedStamp(canvas, stamp, grain);
      return;
    }
    final int argb = color.toARGB32();
    final int alpha = (((argb >>> 24) & 0xff) * stamp.flow).round().clamp(
      0,
      255,
    );
    if (alpha == 0) {
      return;
    }
    canvas.save();
    canvas.translate(stamp.center.dx, stamp.center.dy);
    canvas.rotate(stamp.angleRadians);
    final Rect bounds = Rect.fromCenter(
      center: Offset.zero,
      width: stamp.diameterX,
      height: stamp.diameterY,
    );
    final Paint paint = Paint()
      ..color = Color.fromARGB(
        alpha,
        (argb >>> 16) & 0xff,
        (argb >>> 8) & 0xff,
        argb & 0xff,
      )
      ..style = PaintingStyle.fill;
    switch (brushMiniProofShapeFor(stamp)) {
      case BrushMiniProofShape.oval:
        paint.isAntiAlias = true;
        canvas.drawOval(bounds, paint);
      case BrushMiniProofShape.chiselRectangle:
        paint.isAntiAlias = false;
        canvas.drawRect(bounds, paint);
    }
    canvas.restore();
  }

  void _paintGrainedStamp(
    Canvas canvas,
    ResolvedBrushStamp stamp,
    ResolvedBrushGrain grain,
  ) {
    final int argb = color.toARGB32();
    final double cosine = math.cos(stamp.angleRadians);
    final double sine = math.sin(stamp.angleRadians);
    final double radiusX = stamp.diameterX / 2;
    final double radiusY = stamp.diameterY / 2;
    final Paint pixel = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    for (
      var y = stamp.bounds.top.floor();
      y < stamp.bounds.bottom.ceil();
      y++
    ) {
      for (
        var x = stamp.bounds.left.floor();
        x < stamp.bounds.right.ceil();
        x++
      ) {
        final Offset point = Offset(x + 0.5, y + 0.5);
        final Offset delta = point - stamp.center;
        final double localX = delta.dx * cosine + delta.dy * sine;
        final double localY = -delta.dx * sine + delta.dy * cosine;
        final double normalized =
            localX * localX / (radiusX * radiusX) +
            localY * localY / (radiusY * radiusY);
        if (normalized > 1) {
          continue;
        }
        final double coverage =
            stamp.flow * grain.coverageAt(point, stampCenter: stamp.center);
        final int alpha = (((argb >>> 24) & 0xff) * coverage).round().clamp(
          0,
          255,
        );
        if (alpha == 0) {
          continue;
        }
        pixel.color = Color.fromARGB(
          alpha,
          (argb >>> 16) & 0xff,
          (argb >>> 8) & 0xff,
          argb & 0xff,
        );
        canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), pixel);
      }
    }
  }

  @override
  bool shouldRepaint(BrushMiniProofPainter oldDelegate) {
    return !identical(oldDelegate.plan, plan) || oldDelegate.color != color;
  }
}

final class _BrushPanelScale {
  const _BrushPanelScale(this.value);

  factory _BrushPanelScale.of(BuildContext context) {
    return _BrushPanelScale(inkViewportFitScaleOf(context));
  }

  final double value;

  double u(double designPx) => designPx * value;

  double get rule => math.max(1, u(2));
}

Iterable<BrushPoint> _miniProofPoints() sync* {
  const int pointCount = 25;
  for (var index = 0; index < pointCount; index++) {
    final double t = index / (pointCount - 1);
    yield BrushPoint(
      point: Offset(
        8 + 136 * t,
        _miniProofSize.height / 2 + math.sin(t * math.pi * 2) * 9,
      ),
      pressure: 0.2 + t * 0.75,
      tilt: 0.1 + t * 0.7,
      timestamp: Duration(microseconds: index * 5000),
    );
  }
}

double _resolvedBrushSize(BrushSpec brush, double? requested) {
  final double value = requested ?? brush.sizeDefault;
  if (!value.isFinite || value <= 0) {
    return brush.sizeDefault;
  }
  return value.clamp(brush.sizeMin, brush.sizeMax).toDouble();
}

int _proofSeed(String brushId) {
  var hash = 0x811c9dc5;
  for (final int unit in brushId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

String _presetReadout(BrushSpec brush) {
  return switch (brush.nib.kind) {
    NibKind.disc => 'round · fixed',
    NibKind.ellipse => 'ellipse · fixed',
    NibKind.chisel => 'chisel · ${brush.nib.angleDegrees.round()} deg',
    NibKind.texture => 'texture · seeded',
  };
}

void _validateBrushCatalog(
  List<BrushSpec> brushes, {
  required String activeBrushId,
}) {
  if (brushes.length != brushPanelBrushCount) {
    throw ArgumentError.value(
      brushes.length,
      'brushes',
      'must contain exactly $brushPanelBrushCount drawing brushes',
    );
  }
  final Set<String> ids = <String>{};
  for (final BrushSpec brush in brushes) {
    if (!ids.add(brush.id)) {
      throw ArgumentError.value(
        brush.id,
        'brushes',
        'contains a duplicate brush id',
      );
    }
  }
  if (!ids.contains(activeBrushId)) {
    throw ArgumentError.value(
      activeBrushId,
      'activeBrushId',
      'is not in the drawing brush catalog',
    );
  }
}
