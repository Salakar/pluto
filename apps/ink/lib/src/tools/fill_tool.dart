import 'dart:ui';

import 'selection_tool.dart';
import 'tool.dart';

/// Pixel source used to determine a flood-fill boundary.
enum FillSampleSource {
  /// Only pixels from the active content layer.
  activeLayer,

  /// The visible composite, while writing only to the active layer.
  composite,
}

/// Dot-screen threshold matrix exposed by the fill dock.
enum FillDotScreenDensity {
  /// Coarser four-by-four ordered pattern.
  bayer4,

  /// Finer eight-by-eight ordered pattern.
  bayer8,
}

/// Closed union of fill materials.
sealed class FillMaterial {
  const FillMaterial(this.colorArgb);

  /// Opaque or alpha-bearing ARGB color used by the pattern.
  final int colorArgb;
}

/// Flat solid-color fill.
final class SolidFillStyle extends FillMaterial {
  /// Creates a solid fill color.
  SolidFillStyle(int colorArgb) : super(_requireArgb(colorArgb));
}

/// Fixed document-space hatch fill.
final class HatchFillStyle extends FillMaterial {
  /// Creates a validated hatch material.
  HatchFillStyle({
    required int colorArgb,
    this.spacing = 8,
    this.angleDegrees = 45,
  }) : super(_requireArgb(colorArgb)) {
    if (!spacing.isFinite || spacing <= 0) {
      throw ArgumentError.value(spacing, 'spacing', 'must be positive');
    }
    if (!angleDegrees.isFinite) {
      throw ArgumentError.value(angleDegrees, 'angleDegrees', 'must be finite');
    }
  }

  /// Distance between hatch rules in document pixels.
  final double spacing;

  /// Clockwise hatch angle in degrees.
  final double angleDegrees;
}

/// Ordered dot-screen fill, nominally 60 lpi on the target panel.
final class DotScreenFillStyle extends FillMaterial {
  /// Creates a dot-screen material.
  DotScreenFillStyle({
    required int colorArgb,
    this.density = FillDotScreenDensity.bayer4,
    this.linesPerInch = 60,
  }) : super(_requireArgb(colorArgb)) {
    if (!linesPerInch.isFinite || linesPerInch <= 0) {
      throw ArgumentError.value(
        linesPerInch,
        'linesPerInch',
        'must be positive',
      );
    }
  }

  /// Ordered threshold matrix.
  final FillDotScreenDensity density;

  /// Nominal physical screen frequency.
  final double linesPerInch;
}

/// Immutable, range-checked flood-fill options.
final class FillOptions {
  /// Creates binding-compliant fill options.
  factory FillOptions({
    int tolerance = 16,
    int gapClose = 0,
    int grow = 0,
    FillSampleSource sampleSource = FillSampleSource.activeLayer,
    FillMaterial? style,
  }) {
    if (tolerance < 0 || tolerance > 64) {
      throw RangeError.range(tolerance, 0, 64, 'tolerance');
    }
    if (gapClose < 0 || gapClose > 4) {
      throw RangeError.range(gapClose, 0, 4, 'gapClose');
    }
    if (grow < -4 || grow > 4) {
      throw RangeError.range(grow, -4, 4, 'grow');
    }
    return FillOptions._(
      tolerance: tolerance,
      gapClose: gapClose,
      grow: grow,
      sampleSource: sampleSource,
      style: style ?? SolidFillStyle(0xff000000),
    );
  }

  const FillOptions._({
    required this.tolerance,
    required this.gapClose,
    required this.grow,
    required this.sampleSource,
    required this.style,
  });

  /// ΔE-ish boundary tolerance in the binding 0–64 range.
  final int tolerance;

  /// Bounded morphological boundary-close radius, 0–4 pixels.
  final int gapClose;

  /// Post-region grow (positive) or contract (negative), −4 through +4.
  final int grow;

  /// Layer or composite source used by the flood-region calculation.
  final FillSampleSource sampleSource;

  /// Solid, hatch, or dot-screen material.
  final FillMaterial style;

  /// Returns a validated copy with selected fields replaced.
  FillOptions copyWith({
    int? tolerance,
    int? gapClose,
    int? grow,
    FillSampleSource? sampleSource,
    FillMaterial? style,
  }) => FillOptions(
    tolerance: tolerance ?? this.tolerance,
    gapClose: gapClose ?? this.gapClose,
    grow: grow ?? this.grow,
    sampleSource: sampleSource ?? this.sampleSource,
    style: style ?? this.style,
  );
}

/// Immutable worker command for one flood fill.
final class FillCommand implements JournaledToolCommand {
  /// Creates a layer-local fill request.
  FillCommand({
    required this.seed,
    required this.activeLayerId,
    required this.options,
    this.selectionClip,
  }) {
    if (!seed.dx.isFinite || !seed.dy.isFinite) {
      throw ArgumentError.value(seed, 'seed', 'must be finite');
    }
    if (activeLayerId.isEmpty) {
      throw ArgumentError.value(
        activeLayerId,
        'activeLayerId',
        'must not be empty',
      );
    }
  }

  /// Document-space flood seed.
  final Offset seed;

  /// Content layer receiving changed pixels.
  final String activeLayerId;

  /// Fully resolved immutable fill options.
  final FillOptions options;

  /// Static selection-as-mask clip, if one is active.
  final SelectionMask? selectionClip;

  /// Fill previews are thresholded before the settled raster is published.
  bool get usesThresholdedPreview => true;

  @override
  JournalKind get journalKind => JournalKind.fill;
}

/// Synchronous fill-option and tap-command controller.
final class FillToolController extends ToolController<FillToolKind> {
  /// Creates a fill controller.
  FillToolController({FillOptions? options})
    : _options = options ?? FillOptions(),
      super(const FillToolKind());

  FillOptions _options;

  /// Current contextual-dock options.
  FillOptions get options => _options;

  @override
  bool get hasLiveState => false;

  /// Replaces current fill options.
  void setOptions(FillOptions value) {
    _options = value;
  }

  /// Resolves one canvas tap into an immutable flood-fill command.
  FillCommand tap({
    required Offset seed,
    required String activeLayerId,
    SelectionMask? selectionClip,
  }) => FillCommand(
    seed: seed,
    activeLayerId: activeLayerId,
    options: _options,
    selectionClip: selectionClip,
  );

  @override
  void cancel() {}
}

int _requireArgb(int value) {
  if (value < 0 || value > 0xffffffff) {
    throw RangeError.range(value, 0, 0xffffffff, 'colorArgb');
  }
  return value;
}
