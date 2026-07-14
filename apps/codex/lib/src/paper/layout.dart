import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Normative paper-codex reference geometry in *design pixels*. The 954×1696
/// grid is an authoring baseline, not a required viewport; [PageScale] adapts
/// it to the live Flutter constraints. Values are copied from paper-codex
/// `crates/paper-render/src/layout.rs`.
///
/// Widgets never use these raw: [PageScale] scales design px into logical
/// px for whatever viewport the app actually has.
abstract final class PageDesign {
  static const double pageW = 954;
  static const double pageH = 1696;

  /// Density of the reference artwork. It converts authored pixels to
  /// Flutter's device-independent 160-dpi logical coordinate system.
  static const double authoredDpi = 264;
  static const double logicalDpi = 160;

  static const double margin = 44;
  static const double contentX0 = 44;
  static const double contentX1 = 910;
  static const double contentW = 866;

  static const double ruleStep = 56;
  static const double firstRuleY = 150;
  static const double headerBaselineY = 96;

  static const Rect settingsMarkRect = Rect.fromLTWH(886, 28, 44, 44);
  static const Rect shelfTabRect = Rect.fromLTWH(938, 300, 16, 260);

  static const double hwSepY = 1332;
  static const List<double> hwRulesY = [1388, 1444, 1500, 1556, 1612, 1668];

  static const double kbSepY = 1212;
  static const List<double> kbEntryRulesY = [1268, 1324];
  static const double kbTopY = 1352;
  static const double keyPitch = 64;
  static const double keyH = 56;
  static const int kbCols = 13;
  static const double kbX0 = 61;

  static const Rect modeMarkNibRectHw = Rect.fromLTWH(44, 1312, 40, 40);
  static const Rect modeMarkKeysRectHw = Rect.fromLTWH(96, 1312, 40, 40);
  static const Rect modeMarkNibRectKb = Rect.fromLTWH(44, 1192, 40, 40);
  static const Rect modeMarkKeysRectKb = Rect.fromLTWH(96, 1192, 40, 40);
  static const double modeMarkHitInflate = 4;

  static const Rect sendMarkRectHw = Rect.fromLTWH(830, 1596, 80, 72);
  static const Rect sendMarkRectKb = Rect.fromLTWH(838, 1244, 64, 64);
  static const double kbEntryW = 776;

  static const double speakerMarkX0 = 8;
  static const double speakerMarkX1 = 40;
  static const double thinkingMarkW = 48;
  static const double thinkingMarkH = 48;

  static const double touchTargetMin = 44;
  static const double shelfW = 572;
  static const double shelfCardH = 120;

  static const Rect busyNoteHw = Rect.fromLTWH(44, 1276, 866, 40);
  static const Rect busyNoteKb = Rect.fromLTWH(44, 1156, 866, 40);

  /// Retry mark size (40×40 in the right margin).
  static const double retryMark = 40;

  // Type sizes (design px). Larger than the original paper-codex sizes on
  // purpose: at the 264 dpi authored density, hand lettering
  // below ~28 px is physically under 3 mm — hard reading on e-ink. The
  // 56 px ruling comfortably seats these.
  static const double serifBody = 31;
  static const double handBody = 34;
  static const double handComposer = 34;
  static const double wordmark = 25;
  static const double keyLabel = 26;
  static const double todoLabel = 36;
  static const double noteLabel = 28;
  static const double monoBody = 24;
}

/// Adapts the [PageDesign] lattice to the live Flutter viewport.
///
/// The authored page is the minimum usable design area. One density conversion
/// keeps lettering, ruling, and touch targets physically coherent; all live
/// width and height beyond that baseline become additional design space rather
/// than a letterbox. Wide tablets therefore gain a wider content column while
/// the composer remains attached to the real bottom edge.
@immutable
final class PageScale {
  const PageScale({
    required this.size,
    required this.scale,
    this.devicePixelRatio = 1,
  });

  /// Metrics for a viewport of logical [size] at [devicePixelRatio].
  ///
  /// Design units describe pixels at [PageDesign.authoredDpi], so normal
  /// devices share one logical scale. The fit bound only protects genuinely
  /// smaller windows (for example a host preview); it never enlarges a fixed
  /// page to consume a tablet.
  factory PageScale.forViewport(Size size, {required double devicePixelRatio}) {
    final widthScale = size.width / PageDesign.pageW;
    final heightScale = size.height / PageDesign.pageH;
    final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;
    const densityScale = PageDesign.logicalDpi / PageDesign.authoredDpi;
    final scale = math.min(densityScale, math.min(widthScale, heightScale));
    return PageScale(
      size: size,
      scale: scale.isFinite && scale > 0 ? scale : 1,
      devicePixelRatio: dpr,
    );
  }

  /// Convenience for a DPR-1 host surface, still capped at authored density.
  factory PageScale.forSize(Size size) =>
      PageScale.forViewport(size, devicePixelRatio: 1);

  static PageScale of(BuildContext context) {
    final scoped = _PageScaleScope.maybeOf(context);
    if (scoped != null) {
      return scoped;
    }
    final media = MediaQuery.of(context);
    return PageScale.forViewport(
      media.size,
      devicePixelRatio: media.devicePixelRatio,
    );
  }

  final Size size;
  final double scale;
  final double devicePixelRatio;

  Size get physicalSize =>
      Size(size.width * devicePixelRatio, size.height * devicePixelRatio);

  /// Live viewport expressed in the same design units as [PageDesign].
  Size get designSize => Size(size.width / scale, size.height / scale);
  double get designWidth => designSize.width;
  double get designHeight => designSize.height;

  /// Non-negative room beyond the reference page on each axis.
  double get extraWidth => math.max(0, designWidth - PageDesign.pageW);
  double get extraHeight => math.max(0, designHeight - PageDesign.pageH);

  /// Keeps reference geometry attached to the live right or bottom edge.
  double rightX(double referenceX) => referenceX + extraWidth;
  double bottomY(double referenceY) => referenceY + extraHeight;

  Rect rightRect(Rect reference) => reference.shift(Offset(extraWidth, 0));
  Rect bottomRect(Rect reference) => reference.shift(Offset(0, extraHeight));
  Rect bottomRightRect(Rect reference) =>
      reference.shift(Offset(extraWidth, extraHeight));

  double get designContentX0 => PageDesign.contentX0;
  double get designContentX1 => rightX(PageDesign.contentX1);
  double get designContentW => designContentX1 - designContentX0;

  Rect get designSettingsMarkRect => rightRect(PageDesign.settingsMarkRect);
  Rect get designShelfTabRect => rightRect(PageDesign.shelfTabRect);
  Rect get designSendMarkRectHw => bottomRightRect(PageDesign.sendMarkRectHw);
  Rect get designSendMarkRectKb => bottomRightRect(PageDesign.sendMarkRectKb);

  List<double> get designHwRulesY => [
    for (final y in PageDesign.hwRulesY) bottomY(y),
  ];
  List<double> get designKbEntryRulesY => [
    for (final y in PageDesign.kbEntryRulesY) bottomY(y),
  ];
  double get designKbTopY => bottomY(PageDesign.kbTopY);
  double get designKeyboardPitch =>
      (designWidth - PageDesign.kbX0 * 2) / PageDesign.kbCols;
  double get designKbEntryW => designContentW - 90;

  /// Design px → logical px.
  double u(double designPx) => designPx * scale;

  Rect ur(Rect r) =>
      Rect.fromLTWH(u(r.left), u(r.top), u(r.width), u(r.height));

  Offset uo(Offset o) => Offset(u(o.dx), u(o.dy));

  double get ruleStep => u(PageDesign.ruleStep);
  double get contentX0 => u(PageDesign.contentX0);
  double get contentX1 => u(designContentX1);
  double get contentW => u(designContentW);
  double get firstRuleY => u(PageDesign.firstRuleY);

  /// The y of ruling [index] (0-based) in logical px.
  double ruleY(int index) => firstRuleY + index * ruleStep;

  /// Nearest ruling index at or below logical [y].
  int ruleIndexFor(double y) =>
      ((y - firstRuleY) / ruleStep).floor().clamp(0, 1 << 20);

  @override
  bool operator ==(Object other) =>
      other is PageScale &&
      other.size == size &&
      other.scale == scale &&
      other.devicePixelRatio == devicePixelRatio;

  @override
  int get hashCode => Object.hash(size, scale, devicePixelRatio);
}

/// Supplies [PageScale] from the widget's actual layout constraints.
///
/// Full-screen device apps normally match [MediaQueryData.size], but using the
/// constraints makes desktop previews, split views, and test harnesses behave
/// like ordinary responsive Flutter widgets as well.
final class PageScaleViewport extends StatelessWidget {
  const PageScaleViewport({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : media.size.width;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : media.size.height;
        final metrics = PageScale.forViewport(
          Size(width, height),
          devicePixelRatio: media.devicePixelRatio,
        );
        return _PageScaleScope(metrics: metrics, child: child);
      },
    );
  }
}

final class _PageScaleScope extends InheritedWidget {
  const _PageScaleScope({required this.metrics, required super.child});

  final PageScale metrics;

  static PageScale? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PageScaleScope>()?.metrics;

  @override
  bool updateShouldNotify(_PageScaleScope oldWidget) =>
      metrics != oldWidget.metrics;
}
