import 'dart:math' as math;
import 'dart:ui';

import 'tool.dart';

/// Exact settle-form gray lattice displayed by the eyedropper loupe.
const List<int> eyedropperGrayLatticeLevels = <int>[
  0,
  6,
  10,
  14,
  18,
  22,
  26,
  30,
];

/// Synchronous canvas pixel lookup; `null` means outside available pixels.
typedef ArgbPixelSampler = int? Function(int x, int y);

/// Gesture source that activated the eyedropper.
enum EyedropperActivation {
  /// Primary finger long-press.
  fingerLongPress,

  /// Optional marker barrel-button hold.
  barrelHold,
}

/// Immutable averaged pick and palette-snap result used by the loupe.
final class EyedropperSample {
  /// Creates a validated sample.
  EyedropperSample({
    required this.documentPoint,
    required this.averagedArgb,
    required this.selectedArgb,
    required this.sampleCount,
    required this.latticeGrayLevel,
    this.snappedPaletteArgb,
  }) {
    if (!documentPoint.dx.isFinite || !documentPoint.dy.isFinite) {
      throw ArgumentError.value(
        documentPoint,
        'documentPoint',
        'must be finite',
      );
    }
    _requireArgb(averagedArgb, 'averagedArgb');
    _requireArgb(selectedArgb, 'selectedArgb');
    if (snappedPaletteArgb != null) {
      _requireArgb(snappedPaletteArgb!, 'snappedPaletteArgb');
    }
    if (sampleCount <= 0) {
      throw ArgumentError.value(sampleCount, 'sampleCount', 'must be positive');
    }
    if (latticeGrayLevel < 0 || latticeGrayLevel > 30) {
      throw RangeError.range(latticeGrayLevel, 0, 30, 'latticeGrayLevel');
    }
  }

  /// Center of the 5 dpx averaging disc.
  final Offset documentPoint;

  /// Mean-linear-RGB result before optional palette snapping.
  final int averagedArgb;

  /// Final color applied to the current-color state.
  final int selectedArgb;

  /// Palette color within the threshold, if snapping occurred.
  final int? snappedPaletteArgb;

  /// Number of nontransparent pixels included in the mean.
  final int sampleCount;

  /// Selected color's current-panel `/30` gray-lattice level.
  final int latticeGrayLevel;

  /// Whether [selectedArgb] came from the palette.
  bool get snappedToPalette => snappedPaletteArgb != null;
}

/// Returns an approximate CIE76 color distance between two ARGB colors.
double colorDeltaE(int firstArgb, int secondArgb) {
  _requireArgb(firstArgb, 'firstArgb');
  _requireArgb(secondArgb, 'secondArgb');
  final (double, double, double) first = _argbToLab(firstArgb);
  final (double, double, double) second = _argbToLab(secondArgb);
  final double deltaL = first.$1 - second.$1;
  final double deltaA = first.$2 - second.$2;
  final double deltaB = first.$3 - second.$3;
  return math.sqrt(deltaL * deltaL + deltaA * deltaA + deltaB * deltaB);
}

/// Averages a circular pixel neighborhood in linear RGB and snaps a palette.
EyedropperSample sampleEyedropper({
  required Offset documentPoint,
  required double radius,
  required ArgbPixelSampler samplePixel,
  Iterable<int> palette = const <int>[],
  double paletteSnapDeltaE = 10,
}) {
  if (!documentPoint.dx.isFinite || !documentPoint.dy.isFinite) {
    throw ArgumentError.value(documentPoint, 'documentPoint', 'must be finite');
  }
  if (!radius.isFinite || radius <= 0) {
    throw ArgumentError.value(radius, 'radius', 'must be finite and positive');
  }
  if (!paletteSnapDeltaE.isFinite || paletteSnapDeltaE < 0) {
    throw ArgumentError.value(
      paletteSnapDeltaE,
      'paletteSnapDeltaE',
      'must be finite and non-negative',
    );
  }
  final List<int> colors = List<int>.unmodifiable(palette);
  for (final int color in colors) {
    _requireArgb(color, 'palette color');
  }

  var weightedRed = 0.0;
  var weightedGreen = 0.0;
  var weightedBlue = 0.0;
  var totalAlphaWeight = 0.0;
  var alphaSum = 0.0;
  var sampleCount = 0;
  final int firstX = (documentPoint.dx - radius).floor();
  final int lastX = (documentPoint.dx + radius).ceil();
  final int firstY = (documentPoint.dy - radius).floor();
  final int lastY = (documentPoint.dy + radius).ceil();
  final double radiusSquared = radius * radius;
  for (var y = firstY; y <= lastY; y += 1) {
    for (var x = firstX; x <= lastX; x += 1) {
      final double dx = x + 0.5 - documentPoint.dx;
      final double dy = y + 0.5 - documentPoint.dy;
      if (dx * dx + dy * dy > radiusSquared) {
        continue;
      }
      final int? argb = samplePixel(x, y);
      if (argb == null) {
        continue;
      }
      _requireArgb(argb, 'sampled pixel');
      final double alpha = ((argb >>> 24) & 0xff) / 255;
      if (alpha == 0) {
        continue;
      }
      weightedRed += _srgbToLinear((argb >>> 16) & 0xff) * alpha;
      weightedGreen += _srgbToLinear((argb >>> 8) & 0xff) * alpha;
      weightedBlue += _srgbToLinear(argb & 0xff) * alpha;
      totalAlphaWeight += alpha;
      alphaSum += alpha;
      sampleCount += 1;
    }
  }
  if (sampleCount == 0 || totalAlphaWeight == 0) {
    throw StateError('The eyedropper radius contains no sampleable pixels.');
  }
  final int alpha = (alphaSum / sampleCount * 255).round().clamp(0, 255);
  final int red = _linearToSrgb(weightedRed / totalAlphaWeight);
  final int green = _linearToSrgb(weightedGreen / totalAlphaWeight);
  final int blue = _linearToSrgb(weightedBlue / totalAlphaWeight);
  final int averagedArgb = alpha << 24 | red << 16 | green << 8 | blue;

  int selectedArgb = averagedArgb;
  int? snappedPaletteArgb;
  var nearestDistance = double.infinity;
  for (final int paletteArgb in colors) {
    final double distance = colorDeltaE(averagedArgb, paletteArgb);
    if (distance < nearestDistance) {
      nearestDistance = distance;
      snappedPaletteArgb = paletteArgb;
    }
  }
  if (snappedPaletteArgb != null && nearestDistance <= paletteSnapDeltaE) {
    selectedArgb = snappedPaletteArgb;
  } else {
    snappedPaletteArgb = null;
  }
  return EyedropperSample(
    documentPoint: documentPoint,
    averagedArgb: averagedArgb,
    selectedArgb: selectedArgb,
    snappedPaletteArgb: snappedPaletteArgb,
    sampleCount: sampleCount,
    latticeGrayLevel: eyedropperLatticeGrayLevel(selectedArgb),
  );
}

/// Quantizes an ARGB color with Ink's binding `luma^1.8` `/30` law.
int eyedropperLatticeGrayLevel(int argb) {
  _requireArgb(argb, 'argb');
  final int red = (argb >>> 16) & 0xff;
  final int green = (argb >>> 8) & 0xff;
  final int blue = argb & 0xff;
  final double luma = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255;
  final int rawLevel = (math.pow(luma, 1.8) * 30).round().clamp(0, 30);
  var nearest = eyedropperGrayLatticeLevels.first;
  var distance = (rawLevel - nearest).abs();
  for (final int candidate in eyedropperGrayLatticeLevels.skip(1)) {
    final int candidateDistance = (rawLevel - candidate).abs();
    if (candidateDistance < distance) {
      nearest = candidate;
      distance = candidateDistance;
    }
  }
  return nearest;
}

/// Synchronous long-press/barrel-hold sampling controller.
final class EyedropperToolController
    extends ToolController<EyedropperToolKind> {
  /// Creates a radius-averaged controller.
  EyedropperToolController({
    this.radius = 5,
    this.paletteSnapDeltaE = 10,
    Iterable<int> palette = const <int>[],
  }) : palette = List<int>.unmodifiable(palette),
       super(const EyedropperToolKind()) {
    if (!radius.isFinite || radius <= 0) {
      throw ArgumentError.value(
        radius,
        'radius',
        'must be finite and positive',
      );
    }
    if (!paletteSnapDeltaE.isFinite || paletteSnapDeltaE < 0) {
      throw ArgumentError.value(
        paletteSnapDeltaE,
        'paletteSnapDeltaE',
        'must be finite and non-negative',
      );
    }
    for (final int color in this.palette) {
      _requireArgb(color, 'palette color');
    }
  }

  /// Averaging-disc radius in document pixels; binding default is 5.
  final double radius;

  /// Approximate CIE76 palette capture threshold; binding default is 10.
  final double paletteSnapDeltaE;

  /// Immutable palette considered for snapping.
  final List<int> palette;

  EyedropperActivation? _activation;
  EyedropperSample? _loupeSample;

  /// Active finger or barrel source.
  EyedropperActivation? get activation => _activation;

  /// Current split-color/lattice loupe value.
  EyedropperSample? get loupeSample => _loupeSample;

  @override
  bool get hasLiveState => _activation != null;

  /// Begins a hold and immediately publishes its averaged loupe sample.
  EyedropperSample beginHold({
    required EyedropperActivation activation,
    required Offset documentPoint,
    required ArgbPixelSampler samplePixel,
  }) {
    _activation = activation;
    return _sample(documentPoint, samplePixel);
  }

  /// Updates the loupe while a hold remains active.
  EyedropperSample updateHold({
    required Offset documentPoint,
    required ArgbPixelSampler samplePixel,
  }) {
    if (_activation == null) {
      throw StateError('No eyedropper hold is active.');
    }
    return _sample(documentPoint, samplePixel);
  }

  /// Ends a hold, returning the color to install as the current color.
  int endHold() {
    final EyedropperSample? sample = _loupeSample;
    if (_activation == null || sample == null) {
      throw StateError('No eyedropper hold is active.');
    }
    _activation = null;
    _loupeSample = null;
    return sample.selectedArgb;
  }

  EyedropperSample _sample(Offset documentPoint, ArgbPixelSampler samplePixel) {
    final EyedropperSample result = sampleEyedropper(
      documentPoint: documentPoint,
      radius: radius,
      samplePixel: samplePixel,
      palette: palette,
      paletteSnapDeltaE: paletteSnapDeltaE,
    );
    _loupeSample = result;
    return result;
  }

  @override
  void cancel() {
    _activation = null;
    _loupeSample = null;
  }
}

double _srgbToLinear(int channel) {
  final double value = channel / 255;
  return value <= 0.04045
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
}

int _linearToSrgb(double value) {
  final double encoded = value <= 0.0031308
      ? value * 12.92
      : 1.055 * math.pow(value, 1 / 2.4) - 0.055;
  return (encoded * 255).round().clamp(0, 255);
}

(double, double, double) _argbToLab(int argb) {
  final double red = _srgbToLinear((argb >>> 16) & 0xff);
  final double green = _srgbToLinear((argb >>> 8) & 0xff);
  final double blue = _srgbToLinear(argb & 0xff);
  final double x =
      (0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / 0.95047;
  final double y = 0.2126729 * red + 0.7151522 * green + 0.0721750 * blue;
  final double z =
      (0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / 1.08883;
  final double fx = _labPivot(x);
  final double fy = _labPivot(y);
  final double fz = _labPivot(z);
  return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}

double _labPivot(double value) {
  const double epsilon = 216 / 24389;
  const double kappa = 24389 / 27;
  return value > epsilon
      ? math.pow(value, 1 / 3).toDouble()
      : (kappa * value + 16) / 116;
}

void _requireArgb(int value, String name) {
  if (value < 0 || value > 0xffffffff) {
    throw RangeError.range(value, 0, 0xffffffff, name);
  }
}
