import 'package:flutter/widgets.dart';

import '../paper/glyphs.dart';
import '../paper/layout.dart';
import '../paper/sketch.dart';
import '../paper/theme.dart';
import '../services.dart';

/// Shared painting + hit geometry for choosing the mind (model) and how long
/// it thinks (effort). Settings paints these as house defaults; the per-page
/// sheet paints the same rows scoped to one page. Selection is drawn the way
/// a pen chooses: a snug circle around the picked option.
abstract final class MindRows {
  static const List<String> mindLabels = ['sol', 'luna', 'terra', 'default'];

  /// Option wells (design px, y-local to the row top, two rules tall).
  static List<Rect> mindWells(double x0, double width) => [
    for (var i = 0; i < 4; i++)
      Rect.fromLTWH(
        x0 + i * (width / 4),
        0,
        width / 4,
        PageDesign.ruleStep * 2,
      ),
  ];

  /// Effort options: the six levels plus a trailing 'default' cell, so the
  /// unset state has a visible, circled home just like the mind row.
  static int get effortCells => MindSettings.efforts.length + 1;

  static List<Rect> effortWells(double x0, double width) => [
    for (var i = 0; i < effortCells; i++)
      Rect.fromLTWH(
        x0 + i * (width / effortCells),
        0,
        width / effortCells,
        PageDesign.ruleStep * 2,
      ),
  ];

  /// Paints the four mind options with [selected] (null = default) circled.
  /// [rowTop] is the design-y of the wells' top edge.
  static void paintMindRow(
    Canvas canvas,
    Sketch sketch,
    PaperInk ink, {
    required double x0,
    required double width,
    required double rowTop,
    required String? selected,
  }) {
    final wells = mindWells(x0, width);
    final baseline = rowTop + PageDesign.ruleStep * 1.5;
    for (var i = 0; i < wells.length; i++) {
      final well = wells[i];
      final isSelected = i < 3
          ? selected == MindSettings.models[i]
          : selected == null;
      final color = isSelected ? ink.ink : ink.softInk;
      final label = mindLabels[i];
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: PaperType.note(ink, size: 30, color: color).toTextStyle(),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      const markW = 40.0;
      final unitW = markW + 10 + painter.width;
      final unitLeft = well.left + (well.width - unitW) / 2;
      final cy = baseline - 12;
      switch (i) {
        case 0:
          Glyphs.solMark(sketch, unitLeft + 20, cy, color);
        case 1:
          Glyphs.lunaMark(sketch, unitLeft + 20, cy, color);
        case 2:
          Glyphs.terraMark(sketch, unitLeft + 20, cy, color);
        case 3:
          Glyphs.houseMark(sketch, unitLeft + 20, cy, color);
      }
      painter.paint(
        canvas,
        Offset(
          unitLeft + markW + 10,
          baseline -
              painter.computeDistanceToActualBaseline(TextBaseline.alphabetic) +
              2,
        ),
      );
      if (isSelected) {
        sketch.scribbleEllipse(
          unitLeft + unitW / 2,
          cy,
          unitW / 2 + 18,
          32,
          ink.ink,
        );
      }
    }
  }

  /// Paints the effort ladder with [selected] circled; strokes grow with
  /// the level — how long the pen lingers.
  static void paintEffortRow(
    Canvas canvas,
    Sketch sketch,
    PaperInk ink, {
    required double x0,
    required double width,
    required double rowTop,
    required String? selected,
  }) {
    final wells = effortWells(x0, width);
    final baseline = rowTop + PageDesign.ruleStep * 1.5;
    for (var i = 0; i < wells.length; i++) {
      final well = wells[i];
      final isDefault = i == MindSettings.efforts.length;
      final label = isDefault ? 'default' : MindSettings.efforts[i];
      final isSelected = isDefault
          ? selected == null
          : selected == MindSettings.efforts[i];
      final color = isSelected ? ink.ink : ink.softInk;
      final cx = well.left + well.width / 2;
      if (isDefault) {
        Glyphs.houseMark(sketch, cx, baseline - 40, color);
      } else {
        sketch.strokePath(
          [
            Offset(cx - 9 - i * 2.5, baseline - 44),
            Offset(cx + 9 + i * 2.5, baseline - 40 - i * 3.0),
          ],
          1.2 + i * 0.35,
          color,
        );
      }
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: PaperType.note(ink, size: 25, color: color).toTextStyle(),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          cx - painter.width / 2,
          baseline -
              painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
        ),
      );
      if (isSelected) {
        sketch.scribbleEllipse(
          cx,
          baseline - 12,
          painter.width / 2 + 16,
          26,
          ink.ink,
        );
      }
    }
  }
}
