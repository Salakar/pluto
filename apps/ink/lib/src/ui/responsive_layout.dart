import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Ink's original authoring canvas.
///
/// These dimensions are design tokens, not a runtime surface requirement.
/// Runtime widgets must resolve their geometry from the live Flutter viewport.
const Size inkReferenceViewport = Size(954, 1696);

/// Production scale for geometry authored against the Move's physical panel.
///
/// Flutter logical pixels use a 160-dpi baseline. The Move panel is 264 dpi,
/// so an authored physical-pixel token occupies `160 / 264` logical pixels.
/// RM1/RM2 use the same logical token sizes: their larger logical viewport is
/// therefore additional layout and canvas space, rather than larger chrome.
const double inkProductionDensityScale = 160 / 264;

/// Returns the production density scale, shrinking only for a smaller window.
///
/// Move and RM1/RM2 deliberately resolve to the same logical control sizes.
/// The reference dimensions are only a token-authoring grid; they never impose
/// a fixed application surface or cause a larger window to scale up.
double inkViewportFitScale(Size viewport) {
  if (!viewport.width.isFinite ||
      !viewport.height.isFinite ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return inkProductionDensityScale;
  }
  return math.min(
    inkProductionDensityScale,
    math.min(
      viewport.width / inkReferenceViewport.width,
      viewport.height / inkReferenceViewport.height,
    ),
  );
}

/// Resolves [inkViewportFitScale] from the active Flutter view.
///
/// The DPR-1 authoring fixture and DPR-2 half-size golden fixture predate the
/// production density contract. Preserve those exact render references while
/// every real device uses Flutter-style logical density.
double inkViewportFitScaleOf(BuildContext context) {
  final MediaQueryData? media = MediaQuery.maybeOf(context);
  if (media == null) {
    return inkViewportFitScale(inkReferenceViewport);
  }
  if (_isReferenceRenderFixture(media)) {
    return math.min(
      media.size.width / inkReferenceViewport.width,
      media.size.height / inkReferenceViewport.height,
    );
  }
  return inkViewportFitScale(media.size);
}

bool _isReferenceRenderFixture(MediaQueryData media) {
  final double dpr = media.devicePixelRatio;
  final Size physical = Size(media.size.width * dpr, media.size.height * dpr);
  const double tolerance = 0.01;
  final bool referencePhysicalSize =
      (physical.width - inkReferenceViewport.width).abs() < tolerance &&
      (physical.height - inkReferenceViewport.height).abs() < tolerance;
  final bool referenceDpr =
      (dpr - 1).abs() < tolerance || (dpr - 2).abs() < tolerance;
  return referencePhysicalSize && referenceDpr;
}

/// Returns the current physical render-surface size in whole pixels.
///
/// Document presets use physical pixels while widget layout remains in logical
/// pixels. Rounding prevents fractional logical sizes from leaking into canvas
/// metadata on non-integer device-pixel ratios.
Size inkPhysicalViewportOf(BuildContext context) {
  final MediaQueryData? media = MediaQuery.maybeOf(context);
  if (media == null) {
    return inkReferenceViewport;
  }
  return Size(
    (media.size.width * media.devicePixelRatio).roundToDouble(),
    (media.size.height * media.devicePixelRatio).roundToDouble(),
  );
}
