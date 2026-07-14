import 'dart:ui' show Offset, Rect;

import 'brush_engine.dart';
import 'compositor.dart';
import 'selection_mask.dart';
import 'symmetry.dart';

/// Brush-target decorator that emits every symmetry copy into one target.
///
/// One [stamp] call still represents one source stamp, so every mirrored copy
/// naturally remains in the same stroke recipe and journal entry. Downstream
/// damage is unioned and returned to the existing live-preview pipeline.
final class SymmetryBrushStampTarget implements BrushStampTarget {
  SymmetryBrushStampTarget({
    required this.target,
    required SymmetryConfiguration configuration,
  }) : _hook = SymmetryMirrorHook<ResolvedBrushStamp>(
         configuration: configuration,
         xOf: (stamp) => stamp.center.dx,
         yOf: (stamp) => stamp.center.dy,
         reflectedCopy: _reflectStamp,
       );

  final BrushStampTarget target;
  final SymmetryMirrorHook<ResolvedBrushStamp> _hook;

  @override
  Rect stamp(ResolvedBrushStamp stamp) {
    Rect? damage;
    for (final copy in _hook.expand(stamp)) {
      final copyDamage = target.stamp(copy);
      if (copyDamage.isEmpty) {
        continue;
      }
      damage = damage == null ? copyDamage : damage.expandToInclude(copyDamage);
    }
    return damage ?? Rect.zero;
  }
}

/// Public StrokeBuffer adapter for resolved brush stamps.
///
/// [selection] is document-aligned at ([selectionOriginX],
/// [selectionOriginY]). Nib coverage is multiplied by grain, selection, then
/// [modifyCoverage], making the same mask seam reusable by draw and erase
/// scratch buffers. This adapter intentionally keeps blend dispatch outside;
/// callers use it for the generic ellipse/coverage path just like the original
/// canvas-local adapter.
final class StrokeBufferBrushTarget implements BrushStampTarget {
  const StrokeBufferBrushTarget({
    required this.buffer,
    this.flowMultiplier = 1,
    this.selection,
    this.selectionOriginX = 0,
    this.selectionOriginY = 0,
    this.modifyCoverage,
  });

  final StrokeBuffer buffer;

  /// Per-stroke flow captured alongside the deterministic journal recipe.
  final double flowMultiplier;
  final SelectionMask? selection;
  final int selectionOriginX;
  final int selectionOriginY;
  final StrokeCoverageModifier? modifyCoverage;

  @override
  Rect stamp(ResolvedBrushStamp stamp) {
    final grain = stamp.grain;
    final mask = selection;
    final maskCoverage = mask?.coverage;
    return buffer.stampEllipse(
      center: stamp.center,
      diameterX: stamp.diameterX,
      diameterY: stamp.diameterY,
      angleRadians: stamp.angleRadians,
      colorArgb: stamp.colorArgb,
      flow: (stamp.flow * flowMultiplier).clamp(0.0, 1.0),
      modifyCoverage: grain == null && mask == null && modifyCoverage == null
          ? null
          : (int x, int y, double coverage) {
              var resolved = coverage;
              if (grain != null) {
                resolved *= grain.coverageAt(
                  Offset(x + 0.5, y + 0.5),
                  stampCenter: stamp.center,
                );
              }
              if (mask != null && maskCoverage != null) {
                final localX = x - selectionOriginX;
                final localY = y - selectionOriginY;
                if (localX < 0 ||
                    localX >= mask.width ||
                    localY < 0 ||
                    localY >= mask.height) {
                  return 0;
                }
                resolved *= maskCoverage[localY * mask.width + localX] / 255;
              }
              return modifyCoverage?.call(x, y, resolved) ?? resolved;
            },
    );
  }
}

ResolvedBrushStamp _reflectStamp(
  ResolvedBrushStamp stamp,
  SymmetryReflection reflection,
) {
  final center = reflection.applyToPoint(
    SymmetryPoint(stamp.center.dx, stamp.center.dy),
  );
  final grain = stamp.grain;
  return ResolvedBrushStamp(
    center: Offset(center.x, center.y),
    diameterX: stamp.diameterX,
    diameterY: stamp.diameterY,
    angleRadians: reflection.applyToAngle(stamp.angleRadians),
    colorArgb: stamp.colorArgb,
    flow: stamp.flow,
    blend: stamp.blend,
    grain: grain == null
        ? null
        : ResolvedBrushGrain(
            patternId: grain.patternId,
            scale: grain.scale,
            movement: grain.movement,
            depth: grain.depth,
            seed: grain.seed,
            densityLevel: grain.densityLevel,
            angleRadians: reflection.applyToAngle(grain.angleRadians),
          ),
    nibKind: stamp.nibKind,
    textureMaskId: stamp.textureMaskId,
    maxOverlapSteps: stamp.maxOverlapSteps,
    minimumLumaLevel: stamp.minimumLumaLevel,
  );
}
