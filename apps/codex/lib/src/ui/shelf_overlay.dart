import 'package:flutter/widgets.dart';

import '../app_model.dart';
import '../paper/glyphs.dart';
import '../paper/layout.dart';
import '../paper/ruled_text.dart';
import '../paper/sketch.dart';
import '../paper/theme.dart';

/// The chat shelf (SHELF spec): a right-edge stack of paper index cards,
/// newest first, topped by a "new page" card. The current page is dog-eared.
/// The rest of the page sits under a pale veil — tap it to close.
final class ShelfOverlay extends StatelessWidget {
  const ShelfOverlay({required this.model, super.key});

  final CodexAppModel model;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final shelfLeft = metrics.u(metrics.designWidth - PageDesign.shelfW);
    return Stack(
      children: [
        // Veil over the page; tapping it closes the shelf.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: model.closeShelf,
            child: ColoredBox(color: ink.veil),
          ),
        ),
        Positioned(
          left: shelfLeft,
          top: 0,
          right: 0,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: CustomPaint(
              painter: _ShelfPainter(metrics: metrics, ink: ink, model: model),
              child: _ShelfHitLayer(model: model, metrics: metrics),
            ),
          ),
        ),
      ],
    );
  }
}

final class _ShelfHitLayer extends StatelessWidget {
  const _ShelfHitLayer({required this.model, required this.metrics});

  final CodexAppModel model;
  final PageScale metrics;

  @override
  Widget build(BuildContext context) {
    final cardH = metrics.u(PageDesign.shelfCardH + 16);
    final children = <Widget>[
      SizedBox(
        height: cardH,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: model.newPage,
        ),
      ),
      for (final session in model.sessions)
        SizedBox(
          height: cardH,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => model.selectSession(session.id),
          ),
        ),
    ];
    return Padding(
      padding: EdgeInsets.only(top: metrics.u(96)),
      child: Column(children: children),
    );
  }
}

final class _ShelfPainter extends CustomPainter {
  _ShelfPainter({
    required this.metrics,
    required this.ink,
    required this.model,
  });

  final PageScale metrics;
  final PaperInk ink;
  final CodexAppModel model;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));
    final w = PageDesign.shelfW.toDouble();
    final pageH = size.height / metrics.scale;

    // Shelf paper + spine.
    canvas.drawRect(Rect.fromLTWH(0, 0, w, pageH), Paint()..color = ink.paper);
    sketch.line(1, 0, 1, pageH, 2.4, ink.softInk);

    // Title.
    _text(
      canvas,
      'pages',
      x: 36,
      baseline: 64,
      style: RuledStyle(
        fontFamily: PaperFonts.serif,
        size: PageDesign.wordmark,
        color: ink.softInk,
      ),
    );

    var top = 96.0;
    const cardPad = 16.0;
    final cardH = PageDesign.shelfCardH.toDouble();

    // "New page" card.
    _card(sketch, canvas, top: top, height: cardH, dogEar: false);
    _text(
      canvas,
      'a fresh page',
      x: 72,
      baseline: top + 72,
      style: RuledStyle(
        fontFamily: PaperFonts.hand,
        size: PageDesign.handBody,
        color: ink.softInk,
      ),
    );
    sketch.strokePath(
      [Offset(44, top + 55), Offset(44, top + 77)],
      1.6,
      ink.softInk,
    );
    sketch.strokePath(
      [Offset(33, top + 66), Offset(55, top + 66)],
      1.6,
      ink.softInk,
    );
    top += cardH + cardPad;

    for (final session in model.sessions) {
      final isActive = session.id == model.active.id;
      _card(sketch, canvas, top: top, height: cardH, dogEar: isActive);
      _text(
        canvas,
        session.title,
        x: 40,
        baseline: top + 52,
        style: RuledStyle(
          fontFamily: PaperFonts.hand,
          size: PageDesign.handBody,
          color: ink.ink,
        ),
        maxWidth: w - 88,
      );
      final turns = session.messages.length;
      _text(
        canvas,
        switch (turns) {
          0 => 'blank',
          1 => '1 note',
          _ => '$turns notes',
        },
        x: 40,
        baseline: top + 92,
        style: RuledStyle(
          fontFamily: PaperFonts.serif,
          size: 24,
          color: ink.softInk,
        ),
      );
      top += cardH + cardPad;
      if (top > pageH) {
        break;
      }
    }
    canvas.restore();
  }

  void _card(
    Sketch sketch,
    Canvas canvas, {
    required double top,
    required double height,
    required bool dogEar,
  }) {
    const x = 24.0;
    final w = PageDesign.shelfW - 48.0;
    // Card shadow line then wobbled outline.
    sketch.line(
      x + 6,
      top + height + 3,
      x + w,
      top + height + 3,
      1.6,
      ink.rule,
    );
    sketch.strokePath(
      [
        Offset(x + 3, top + 1),
        Offset(x + w - 2, top),
        Offset(x + w, top + height - 2),
        Offset(x + 1, top + height),
        Offset(x + 3, top + 1),
      ],
      1.3,
      ink.softInk,
    );
    if (dogEar) {
      Glyphs.dogEar(sketch, x + w - 26, top + 2, ink.softInk);
    }
  }

  void _text(
    Canvas canvas,
    String text, {
    required double x,
    required double baseline,
    required RuledStyle style,
    double? maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style.toTextStyle()),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? double.infinity);
    painter.paint(
      canvas,
      Offset(
        x,
        baseline -
            painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      ),
    );
  }

  @override
  bool shouldRepaint(_ShelfPainter old) =>
      old.ink != ink || old.metrics != metrics;
}
