import 'dart:math' as math;

/// Rasterization family selected by a brush preset.
enum BrushClass {
  /// A crisp path whose polyline and widths remain recipe metadata.
  vectorPen,

  /// Repeated nib impressions placed along the fitted path.
  stamp,

  /// Seeded particles distributed around the fitted path.
  particle,

  /// A repeating pattern clipped to the stroke ribbon.
  pattern,
}

/// Live e-ink presentation used before a stroke commits.
enum PreviewStyle {
  /// The alpha-thresholded core alone.
  solid,

  /// A one-pixel stroke-AABB contour plus the thresholded core.
  outline,
}

/// Geometric family of a brush nib.
enum NibKind {
  /// Circular hard-edged nib.
  disc,

  /// Elliptical nib with a fixed angle and aspect ratio.
  ellipse,

  /// Crisp chisel nib at a fixed angle.
  chisel,

  /// Baked mask, optionally carrying particle count and spread.
  texture,
}

/// Whether a grain is anchored to the document or follows each stamp.
enum GrainMovement {
  /// The grain samples fixed document coordinates.
  fixed,

  /// The grain origin moves with the stamp.
  moving,
}

/// Brush-level compositing operation.
enum BrushBlend {
  /// Normal premultiplied source-over paint.
  opaque,

  /// Repeated coverage darkens only up to a configured cap.
  buildup,

  /// Multiplicative paint used by translucent media.
  multiply,

  /// Destination-out coverage used by the pixel eraser.
  clear,

  /// Snapshot-based gray-lattice adjustment reserved for WP4.
  shade,
}

/// Direction carried by the reserved shade blend.
enum ShadeDirection {
  /// Move covered pixels one lattice step darker.
  darker,

  /// Move covered pixels one lattice step lighter.
  lighter,
}

/// Gamma pressure curve shared by size, flow, and tuning presets.
final class PressureMap {
  /// Creates `lo + (hi - lo) * pow(p, gamma)` for normalized pressure `p`.
  const PressureMap({required this.gamma, required this.lo, required this.hi})
    : assert(gamma > 0),
      assert(lo >= 0),
      assert(hi >= lo);

  /// Constant full-scale response used by pressure-invariant parameters.
  static const PressureMap constant = PressureMap(gamma: 1, lo: 1, hi: 1);

  /// Gamma applied to normalized input pressure.
  final double gamma;

  /// Output at zero pressure.
  final double lo;

  /// Output at full pressure.
  final double hi;

  /// Evaluates the curve after constraining [pressure] to zero through one.
  double map(double pressure) {
    if (!pressure.isFinite) {
      throw ArgumentError.value(pressure, 'pressure', 'must be finite');
    }
    final double normalized = pressure.clamp(0.0, 1.0);
    return lo + (hi - lo) * math.pow(normalized, gamma).toDouble();
  }
}

/// Optional normalized-tilt mapping for size, grain depth, and nib squash.
final class TiltMap {
  /// Creates independently ranged tilt responses with a shared gamma.
  const TiltMap({
    required this.gamma,
    required this.sizeLo,
    required this.sizeHi,
    required this.grainDepthLo,
    required this.grainDepthHi,
    required this.squashLo,
    required this.squashHi,
  }) : assert(gamma > 0),
       assert(sizeLo >= 0),
       assert(sizeHi >= sizeLo),
       assert(grainDepthLo >= 0),
       assert(grainDepthHi >= grainDepthLo),
       assert(squashLo > 0),
       assert(squashHi >= squashLo);

  /// Gamma applied to normalized tilt magnitude.
  final double gamma;

  /// Size multiplier at upright tilt.
  final double sizeLo;

  /// Size multiplier at maximum tilt.
  final double sizeHi;

  /// Grain-depth multiplier at upright tilt.
  final double grainDepthLo;

  /// Grain-depth multiplier at maximum tilt.
  final double grainDepthHi;

  /// Nib aspect multiplier at upright tilt.
  final double squashLo;

  /// Nib aspect multiplier at maximum tilt.
  final double squashHi;

  /// Maps [tilt] into the configured size-multiplier range.
  double sizeMultiplier(double tilt) => _map(tilt, sizeLo, sizeHi);

  /// Maps [tilt] into the configured grain-depth range.
  double grainDepth(double tilt) => _map(tilt, grainDepthLo, grainDepthHi);

  /// Maps [tilt] into the configured nib-squash range.
  double squash(double tilt) => _map(tilt, squashLo, squashHi);

  double _map(double tilt, double lo, double hi) {
    if (!tilt.isFinite) {
      throw ArgumentError.value(tilt, 'tilt', 'must be finite');
    }
    final double normalized = tilt.clamp(0.0, 1.0);
    return lo + (hi - lo) * math.pow(normalized, gamma).toDouble();
  }
}

/// Pure nib geometry, including future particle texture metadata.
final class NibShape {
  /// Creates a circular nib.
  const NibShape.disc()
    : kind = NibKind.disc,
      angleDegrees = 0,
      ratio = 1,
      maskId = null,
      particleCount = 0,
      particleSpread = 0,
      particleSizeMin = 0,
      particleSizeMax = 0;

  /// Creates an ellipse whose [ratio] is minor-axis over major-axis.
  const NibShape.ellipse({required this.angleDegrees, required this.ratio})
    : assert(ratio > 0 && ratio <= 1),
      kind = NibKind.ellipse,
      maskId = null,
      particleCount = 0,
      particleSpread = 0,
      particleSizeMin = 0,
      particleSizeMax = 0;

  /// Creates a crisp chisel nib at [angleDegrees].
  const NibShape.chisel({required this.angleDegrees})
    : kind = NibKind.chisel,
      ratio = 1,
      maskId = null,
      particleCount = 0,
      particleSpread = 0,
      particleSizeMin = 0,
      particleSizeMax = 0;

  /// Creates a baked texture nib with optional particle metadata.
  const NibShape.texture({
    required String this.maskId,
    this.particleCount = 0,
    this.particleSpread = 0,
    this.particleSizeMin = 1,
    this.particleSizeMax = 1,
  }) : assert(maskId != ''),
       assert(particleCount >= 0),
       assert(particleSpread >= 0),
       assert(particleSizeMin > 0),
       assert(particleSizeMax >= particleSizeMin),
       kind = NibKind.texture,
       angleDegrees = 0,
       ratio = 1;

  /// Geometric nib family.
  final NibKind kind;

  /// Fixed nib angle in degrees.
  final double angleDegrees;

  /// Minor-axis over major-axis ratio for an ellipse.
  final double ratio;

  /// Stable baked-mask identifier for a texture nib.
  final String? maskId;

  /// Base particle count carried by a particle texture nib.
  final int particleCount;

  /// Particle spread as a fraction of selected brush size.
  final double particleSpread;

  /// Smallest emitted particle diameter in document pixels.
  final double particleSizeMin;

  /// Largest emitted particle diameter in document pixels.
  final double particleSizeMax;
}

/// Grain pattern applied inside stamp coverage.
final class GrainSpec {
  /// Creates a deterministic procedural or baked grain description.
  const GrainSpec({
    required this.patternId,
    required this.scale,
    required this.movement,
    required this.depth,
    required this.depthPressure,
  }) : assert(patternId != ''),
       assert(scale > 0),
       assert(depth >= 0 && depth <= 1),
       assert(depthPressure >= 0 && depthPressure <= 1);

  /// Stable procedural or baked pattern identifier.
  final String patternId;

  /// Pattern scale in document pixels per source-pattern pixel.
  final double scale;

  /// Fixed or stamp-moving grain anchoring.
  final GrainMovement movement;

  /// Base grain modulation depth from zero through one.
  final double depth;

  /// Extra depth contribution from pressure, from zero through one.
  final double depthPressure;
}

/// Head, tail, and speed-dependent stroke taper data.
final class TaperSpec {
  /// Creates a taper whose lengths are measured in selected-size multiples.
  const TaperSpec({
    required this.headLength,
    required this.tailLength,
    required this.velocityTail,
  }) : assert(headLength >= 0),
       assert(tailLength >= 0),
       assert(velocityTail >= 0 && velocityTail <= 1);

  /// Pressure- and velocity-invariant stroke with no taper.
  static const TaperSpec none = TaperSpec(
    headLength: 0,
    tailLength: 0,
    velocityTail: 0,
  );

  /// Distance over which the head reaches full size.
  final double headLength;

  /// Distance over which the tail falls from full size.
  final double tailLength;

  /// Additional normalized tail thinning caused by velocity.
  final double velocityTail;
}

/// Parameterized brush compositing behavior.
final class BlendBehavior {
  /// Creates normal source-over paint.
  const BlendBehavior.opaque()
    : kind = BrushBlend.opaque,
      maxDarken = null,
      shadeDirection = null;

  /// Creates capped darkening for repeated stamp coverage.
  const BlendBehavior.buildup({required double this.maxDarken})
    : assert(maxDarken >= 0 && maxDarken <= 1),
      kind = BrushBlend.buildup,
      shadeDirection = null;

  /// Creates multiplicative paint.
  const BlendBehavior.multiply()
    : kind = BrushBlend.multiply,
      maxDarken = null,
      shadeDirection = null;

  /// Creates destination-out paint.
  const BlendBehavior.clear()
    : kind = BrushBlend.clear,
      maxDarken = null,
      shadeDirection = null;

  /// Describes the WP4 snapshot-based shade operation without implementing it.
  const BlendBehavior.shade(ShadeDirection this.shadeDirection)
    : kind = BrushBlend.shade,
      maxDarken = null;

  /// Blend operation selected for the brush.
  final BrushBlend kind;

  /// Maximum normalized darkening for [BrushBlend.buildup].
  final double? maxDarken;

  /// Direction for [BrushBlend.shade].
  final ShadeDirection? shadeDirection;

  /// Whether this behavior removes destination coverage.
  bool get isClear => kind == BrushBlend.clear;
}

/// Complete JSON-shaped tuning data for one brush.
final class BrushSpec {
  /// Creates an immutable brush specification.
  const BrushSpec({
    required this.id,
    required this.name,
    required this.kind,
    required this.sizeMin,
    required this.sizeMax,
    required this.sizeDefault,
    required this.pressureSize,
    required this.pressureFlow,
    required this.tilt,
    required this.spacing,
    required this.jitter,
    required this.nib,
    required this.grain,
    required this.taper,
    required this.blend,
    required this.smoothing,
    required this.preview,
    required this.previewAlphaCutoff,
    required this.velocityThins,
    required this.quantizeLevels,
    this.fixedLatticeLevel,
    this.maxOverlapSteps = 0,
    this.minimumLumaLevel = 0,
    this.patternDensitySteps = 0,
  }) : assert(id != ''),
       assert(name != ''),
       assert(sizeMin > 0),
       assert(sizeMax >= sizeMin),
       assert(sizeDefault >= sizeMin && sizeDefault <= sizeMax),
       assert(spacing > 0),
       assert(jitter >= 0),
       assert(smoothing >= 0),
       assert(previewAlphaCutoff > 0 && previewAlphaCutoff <= 1),
       assert(quantizeLevels >= 0),
       assert(fixedLatticeLevel == null || fixedLatticeLevel <= 30),
       assert(fixedLatticeLevel == null || fixedLatticeLevel >= 0),
       assert(maxOverlapSteps >= 0),
       assert(minimumLumaLevel >= 0 && minimumLumaLevel <= 30),
       assert(patternDensitySteps >= 0);

  /// Stable lowercase identifier persisted in stroke recipes.
  final String id;

  /// Human-readable preset name.
  final String name;

  /// Rasterization family.
  final BrushClass kind;

  /// Minimum selectable diameter in document pixels.
  final double sizeMin;

  /// Maximum selectable diameter in document pixels.
  final double sizeMax;

  /// Initial diameter in document pixels.
  final double sizeDefault;

  /// Pressure-to-diameter multiplier curve.
  final PressureMap pressureSize;

  /// Pressure-to-flow multiplier curve.
  final PressureMap pressureFlow;

  /// Optional tilt response.
  final TiltMap? tilt;

  /// Stamp interval as a fraction of current diameter.
  final double spacing;

  /// Lateral scatter as a fraction of current diameter.
  final double jitter;

  /// Nib geometry or baked mask.
  final NibShape nib;

  /// Optional grain pattern.
  final GrainSpec? grain;

  /// Head, tail, and velocity taper.
  final TaperSpec taper;

  /// Brush compositing behavior.
  final BlendBehavior blend;

  /// One-Euro beta override.
  final double smoothing;

  /// Live threshold-preview style.
  final PreviewStyle preview;

  /// Minimum normalized alpha painted in the live preview.
  final double previewAlphaCutoff;

  /// Whether velocity reduces diameter or flow.
  final bool velocityThins;

  /// Settled gray-step count, or zero for continuous output.
  final int quantizeLevels;

  /// Fixed /30 gray-lattice source level, or null to honor the chosen color.
  final int? fixedLatticeLevel;

  /// Maximum within-stroke coverage passes, or zero for uncapped coverage.
  final int maxOverlapSteps;

  /// Lowest permitted output luma on the /30 display lattice.
  final int minimumLumaLevel;

  /// Number of pressure-selected pattern-density steps, or zero if unused.
  final int patternDensitySteps;

  /// Returns a copy whose snapshot shade direction is [direction].
  BrushSpec withShadeDirection(ShadeDirection direction) {
    if (blend.kind != BrushBlend.shade) {
      throw StateError('Only a shade brush has a shade direction.');
    }
    return BrushSpec(
      id: id,
      name: name,
      kind: kind,
      sizeMin: sizeMin,
      sizeMax: sizeMax,
      sizeDefault: sizeDefault,
      pressureSize: pressureSize,
      pressureFlow: pressureFlow,
      tilt: tilt,
      spacing: spacing,
      jitter: jitter,
      nib: nib,
      grain: grain,
      taper: taper,
      blend: BlendBehavior.shade(direction),
      smoothing: smoothing,
      preview: preview,
      previewAlphaCutoff: previewAlphaCutoff,
      velocityThins: velocityThins,
      quantizeLevels: quantizeLevels,
      fixedLatticeLevel: fixedLatticeLevel,
      maxOverlapSteps: maxOverlapSteps,
      minimumLumaLevel: minimumLumaLevel,
      patternDensitySteps: patternDensitySteps,
    );
  }
}

/// Default threshold shared by the starter brush classes pending device tuning.
const double starterPreviewAlphaCutoff = 0.5;

/// Default Ink brush: a crisp, constant-width vector pen.
const BrushSpec finelinerBrush = BrushSpec(
  id: 'fineliner',
  name: 'Fineliner',
  kind: BrushClass.vectorPen,
  sizeMin: 1.5,
  sizeMax: 8,
  sizeDefault: 3,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.2,
  jitter: 0,
  nib: NibShape.disc(),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.7,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: false,
  quantizeLevels: 0,
);

/// Stabilized constant-width technical pen with no taper.
const BrushSpec technicalBrush = BrushSpec(
  id: 'technical',
  name: 'Technical',
  kind: BrushClass.vectorPen,
  sizeMin: 1,
  sizeMax: 4,
  sizeDefault: 2,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.18,
  jitter: 0,
  nib: NibShape.disc(),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.85,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: false,
  quantizeLevels: 0,
);

/// Pressure-sensitive vector ballpoint with seeded skip flecks.
const BrushSpec ballpointBrush = BrushSpec(
  id: 'ballpoint',
  name: 'Ballpoint',
  kind: BrushClass.vectorPen,
  sizeMin: 2,
  sizeMax: 6,
  sizeDefault: 3,
  pressureSize: PressureMap(gamma: 2.2, lo: 0.75, hi: 1),
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.2,
  jitter: 0,
  nib: NibShape.disc(),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.55,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: true,
  quantizeLevels: 0,
);

/// Expressive pressure- and velocity-sensitive disc-stamp brush pen.
const BrushSpec brushpenBrush = BrushSpec(
  id: 'brushpen',
  name: 'Brush Pen',
  kind: BrushClass.stamp,
  sizeMin: 4,
  sizeMax: 28,
  sizeDefault: 10,
  pressureSize: PressureMap(gamma: 1.4, lo: 0.25, hi: 1),
  pressureFlow: PressureMap(gamma: 1.2, lo: 0.35, hi: 1),
  tilt: null,
  spacing: 0.12,
  jitter: 0,
  nib: NibShape.disc(),
  grain: null,
  taper: TaperSpec(headLength: 0.35, tailLength: 1.5, velocityTail: 0.75),
  blend: BlendBehavior.opaque(),
  smoothing: 0.45,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: true,
  quantizeLevels: 0,
);

/// Four-level HB pencil using fixed paper-tooth grain.
const BrushSpec pencilHbBrush = BrushSpec(
  id: 'pencilhb',
  name: 'HB Pencil',
  kind: BrushClass.stamp,
  sizeMin: 2,
  sizeMax: 10,
  sizeDefault: 4,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap(gamma: 1.8, lo: 0.15, hi: 1),
  tilt: null,
  spacing: 0.15,
  jitter: 0,
  nib: NibShape.disc(),
  grain: GrainSpec(
    patternId: 'paperTooth',
    scale: 1,
    movement: GrainMovement.fixed,
    depth: 0.5,
    depthPressure: 0,
  ),
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.35,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: false,
  quantizeLevels: 4,
);

/// Pressure-sensitive fountain pen whose tilt adds up to twenty-percent width.
const BrushSpec fountainBrush = BrushSpec(
  id: 'fountain',
  name: 'Fountain',
  kind: BrushClass.vectorPen,
  sizeMin: 2,
  sizeMax: 10,
  sizeDefault: 5,
  pressureSize: PressureMap(gamma: 1.6, lo: 0.5, hi: 1.4),
  pressureFlow: PressureMap.constant,
  tilt: TiltMap(
    gamma: 1,
    sizeLo: 1,
    sizeHi: 1.2,
    grainDepthLo: 1,
    grainDepthHi: 1,
    squashLo: 1,
    squashHi: 1,
  ),
  spacing: 0.16,
  jitter: 0,
  nib: NibShape.disc(),
  grain: null,
  taper: TaperSpec(headLength: 0, tailLength: 0.7, velocityTail: 0.2),
  blend: BlendBehavior.opaque(),
  smoothing: 0.62,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: false,
  quantizeLevels: 0,
);

/// Direction-sensitive forty-degree crisp chisel.
const BrushSpec calligraphyBrush = BrushSpec(
  id: 'calligraphy',
  name: 'Calligraphy',
  kind: BrushClass.vectorPen,
  sizeMin: 4,
  sizeMax: 24,
  sizeDefault: 12,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.1,
  jitter: 0,
  nib: NibShape.chisel(angleDegrees: 40),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.42,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: false,
  quantizeLevels: 0,
);

/// Broad six-B pencil with tilt-driven lead squash and tooth depth.
const BrushSpec pencil6bBrush = BrushSpec(
  id: 'pencil6b',
  name: '6B Pencil',
  kind: BrushClass.stamp,
  sizeMin: 3,
  sizeMax: 24,
  sizeDefault: 8,
  pressureSize: PressureMap(gamma: 1.5, lo: 0.45, hi: 1),
  pressureFlow: PressureMap(gamma: 1.55, lo: 0.18, hi: 1),
  tilt: TiltMap(
    gamma: 1,
    sizeLo: 1,
    sizeHi: 1,
    grainDepthLo: 0.6,
    grainDepthHi: 1,
    squashLo: 1,
    squashHi: 3.5,
  ),
  spacing: 0.12,
  jitter: 0.025,
  nib: NibShape.ellipse(angleDegrees: 0, ratio: 1),
  grain: GrainSpec(
    patternId: 'paperTooth',
    scale: 1,
    movement: GrainMovement.fixed,
    depth: 0.8,
    depthPressure: 0,
  ),
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.3,
  preview: PreviewStyle.outline,
  previewAlphaCutoff: 0.42,
  velocityThins: false,
  quantizeLevels: 4,
);

/// Crisp constant-width mechanical pencil fixed to display level eighteen.
const BrushSpec mechanicalBrush = BrushSpec(
  id: 'mechanical',
  name: 'Mechanical',
  kind: BrushClass.vectorPen,
  sizeMin: 1.5,
  sizeMax: 3,
  sizeDefault: 2,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.16,
  jitter: 0,
  nib: NibShape.disc(),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.7,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: false,
  quantizeLevels: 1,
  fixedLatticeLevel: 18,
);

/// Torn fixed-strata charcoal with pressure-sensitive size and flow.
const BrushSpec charcoalBrush = BrushSpec(
  id: 'charcoal',
  name: 'Charcoal',
  kind: BrushClass.stamp,
  sizeMin: 6,
  sizeMax: 36,
  sizeDefault: 16,
  pressureSize: PressureMap(gamma: 1.35, lo: 0.35, hi: 1),
  pressureFlow: PressureMap(gamma: 1.25, lo: 0.2, hi: 1),
  tilt: null,
  spacing: 0.14,
  jitter: 0.07,
  nib: NibShape.texture(maskId: 'charcoalStrata'),
  grain: GrainSpec(
    patternId: 'charcoalStrata',
    scale: 1,
    movement: GrainMovement.fixed,
    depth: 1,
    depthPressure: 0,
  ),
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.28,
  preview: PreviewStyle.outline,
  previewAlphaCutoff: 0.4,
  velocityThins: false,
  quantizeLevels: 6,
);

/// Flat multiply marker capped at two within-stroke overlap passes.
const BrushSpec markerBrush = BrushSpec(
  id: 'marker',
  name: 'Marker',
  kind: BrushClass.stamp,
  sizeMin: 8,
  sizeMax: 48,
  sizeDefault: 20,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap(gamma: 1, lo: 0.34, hi: 0.34),
  tilt: null,
  spacing: 0.1,
  jitter: 0,
  nib: NibShape.chisel(angleDegrees: 90),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.multiply(),
  smoothing: 0.48,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: 0.3,
  velocityThins: false,
  quantizeLevels: 3,
  maxOverlapSteps: 2,
);

/// Pale multiply highlighter capped at one pass and lattice level twelve.
const BrushSpec highlighterBrush = BrushSpec(
  id: 'highlighter',
  name: 'Highlighter',
  kind: BrushClass.stamp,
  sizeMin: 12,
  sizeMax: 48,
  sizeDefault: 24,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap(gamma: 1, lo: 0.28, hi: 0.28),
  tilt: null,
  spacing: 0.1,
  jitter: 0,
  nib: NibShape.chisel(angleDegrees: 90),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.multiply(),
  smoothing: 0.5,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: 0.24,
  velocityThins: false,
  quantizeLevels: 3,
  maxOverlapSteps: 1,
  minimumLumaLevel: 12,
);

/// Gaussian seeded spray whose particle count scales with footprint area.
const BrushSpec sprayBrush = BrushSpec(
  id: 'spray',
  name: 'Spray',
  kind: BrushClass.particle,
  sizeMin: 12,
  sizeMax: 64,
  sizeDefault: 28,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap(gamma: 1.3, lo: 0.15, hi: 1),
  tilt: null,
  spacing: 0.42,
  jitter: 0,
  nib: NibShape.texture(
    maskId: 'sprayDots',
    particleCount: 20,
    particleSpread: 0.48,
    particleSizeMin: 1,
    particleSizeMax: 2,
  ),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.22,
  preview: PreviewStyle.outline,
  previewAlphaCutoff: 0.38,
  velocityThins: false,
  quantizeLevels: 4,
);

/// Seeded Poisson-spaced dotwork with pressure-controlled dot diameter.
const BrushSpec stippleBrush = BrushSpec(
  id: 'stipple',
  name: 'Stipple',
  kind: BrushClass.particle,
  sizeMin: 6,
  sizeMax: 32,
  sizeDefault: 14,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.48,
  jitter: 0,
  nib: NibShape.texture(
    maskId: 'dotScreen60lpi',
    particleCount: 9,
    particleSpread: 0.45,
    particleSizeMin: 1,
    particleSizeMax: 3,
  ),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.18,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: 0.45,
  velocityThins: false,
  quantizeLevels: 4,
);

/// Stroke-following forty-five-degree hatch with shade crosshatch passes.
const BrushSpec hatcherBrush = BrushSpec(
  id: 'hatcher',
  name: 'Hatcher',
  kind: BrushClass.pattern,
  sizeMin: 8,
  sizeMax: 40,
  sizeDefault: 18,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap(gamma: 1, lo: 0.25, hi: 1),
  tilt: null,
  spacing: 0.12,
  jitter: 0,
  nib: NibShape.texture(maskId: 'hatch45'),
  grain: GrainSpec(
    patternId: 'hatch45',
    scale: 1,
    movement: GrainMovement.fixed,
    depth: 1,
    depthPressure: 0,
  ),
  taper: TaperSpec.none,
  blend: BlendBehavior.opaque(),
  smoothing: 0.32,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: 0.45,
  velocityThins: false,
  quantizeLevels: 4,
  patternDensitySteps: 4,
);

/// Snapshot-only one-lattice-step tone adjustment brush.
const BrushSpec toneshaderBrush = BrushSpec(
  id: 'toneshader',
  name: 'Tone Shader',
  kind: BrushClass.pattern,
  sizeMin: 10,
  sizeMax: 48,
  sizeDefault: 22,
  pressureSize: PressureMap.constant,
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.12,
  jitter: 0,
  nib: NibShape.disc(),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.shade(ShadeDirection.darker),
  smoothing: 0.42,
  preview: PreviewStyle.outline,
  previewAlphaCutoff: 0.5,
  velocityThins: false,
  quantizeLevels: 8,
);

/// Hard-edged pixel eraser represented as a clear-blend disc brush.
const BrushSpec eraserPixelBrush = BrushSpec(
  id: 'eraserpixel',
  name: 'Pixel Eraser',
  kind: BrushClass.stamp,
  sizeMin: 4,
  sizeMax: 64,
  sizeDefault: 16,
  pressureSize: PressureMap(gamma: 1, lo: 0.6, hi: 1),
  pressureFlow: PressureMap.constant,
  tilt: null,
  spacing: 0.12,
  jitter: 0,
  nib: NibShape.disc(),
  grain: null,
  taper: TaperSpec.none,
  blend: BlendBehavior.clear(),
  smoothing: 0.2,
  preview: PreviewStyle.solid,
  previewAlphaCutoff: starterPreviewAlphaCutoff,
  velocityThins: false,
  quantizeLevels: 0,
);

/// Four pale choices exposed only while the highlighter is active.
const List<int> highlighterColorsArgb = <int>[
  0xffffef78,
  0xff91e7ee,
  0xfff1a6c1,
  0xffa9e4a1,
];

/// Default color used when a non-highlight swatch reaches the highlighter.
const int defaultHighlighterColorArgb = 0xffffef78;

/// Baked brush patterns and the drawing presets that consume each one.
///
/// `grainCanvas` and the Bayer fill matrices intentionally remain absent:
/// no WP4 brush consumes them. `crosshatch` is sampled by the hatcher's
/// snapshot shade pass rather than stored directly in its primary grain.
const Map<String, List<String>> bakedBrushPatternConsumers =
    <String, List<String>>{
      'paperTooth': <String>['pencilhb', 'pencil6b'],
      'charcoalStrata': <String>['charcoal'],
      'hatch45': <String>['hatcher'],
      'crosshatch': <String>['hatcher'],
      'dotScreen60lpi': <String>['stipple'],
    };

/// Exact sixteen-brush catalog in the binding proof-sheet/panel order.
const List<BrushSpec> drawingBrushes = <BrushSpec>[
  finelinerBrush,
  technicalBrush,
  ballpointBrush,
  fountainBrush,
  calligraphyBrush,
  brushpenBrush,
  pencilHbBrush,
  pencil6bBrush,
  mechanicalBrush,
  charcoalBrush,
  markerBrush,
  highlighterBrush,
  sprayBrush,
  stippleBrush,
  hatcherBrush,
  toneshaderBrush,
];

/// Drawing catalog keyed by stable recipe identifier.
const Map<String, BrushSpec> drawingBrushesById = <String, BrushSpec>{
  'fineliner': finelinerBrush,
  'technical': technicalBrush,
  'ballpoint': ballpointBrush,
  'fountain': fountainBrush,
  'calligraphy': calligraphyBrush,
  'brushpen': brushpenBrush,
  'pencilhb': pencilHbBrush,
  'pencil6b': pencil6bBrush,
  'mechanical': mechanicalBrush,
  'charcoal': charcoalBrush,
  'marker': markerBrush,
  'highlighter': highlighterBrush,
  'spray': sprayBrush,
  'stipple': stippleBrush,
  'hatcher': hatcherBrush,
  'toneshader': toneshaderBrush,
};

/// Complete recipe lookup including the separately exposed pixel eraser.
const Map<String, BrushSpec> brushesById = <String, BrushSpec>{
  ...drawingBrushesById,
  'eraserpixel': eraserPixelBrush,
};

/// Returns a drawing brush or the pixel eraser with [id].
BrushSpec brushById(String id) {
  final BrushSpec? spec = brushesById[id];
  if (spec == null) {
    throw ArgumentError.value(id, 'id', 'is not an Ink brush');
  }
  return spec;
}

/// Starter catalog in deterministic proof-sheet order.
const List<BrushSpec> starterBrushes = <BrushSpec>[
  finelinerBrush,
  technicalBrush,
  ballpointBrush,
  brushpenBrush,
  pencilHbBrush,
  eraserPixelBrush,
];

/// Starter catalog keyed by stable recipe identifier.
const Map<String, BrushSpec> starterBrushesById = <String, BrushSpec>{
  'fineliner': finelinerBrush,
  'technical': technicalBrush,
  'ballpoint': ballpointBrush,
  'brushpen': brushpenBrush,
  'pencilhb': pencilHbBrush,
  'eraserpixel': eraserPixelBrush,
};

/// Returns the starter preset with [id].
BrushSpec starterBrushById(String id) {
  final BrushSpec? spec = starterBrushesById[id];
  if (spec == null) {
    throw ArgumentError.value(id, 'id', 'is not a starter brush');
  }
  return spec;
}
