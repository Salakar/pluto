import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../app_model.dart';
import '../models.dart';
import '../paper/glyphs.dart';
import '../paper/layout.dart';
import '../paper/ruled_text.dart';
import '../paper/sketch.dart';
import '../paper/theme.dart';
import '../services.dart';
import 'composer.dart';
import 'mind_rows.dart';
import 'settings_page.dart';
import 'shelf_overlay.dart';
import 'transcript_view.dart';

/// The page: header wordmark + title, ruled transcript, composer band,
/// settings sun, shelf tab, thinking spiral while Codex writes.
final class ChatPage extends StatefulWidget {
  const ChatPage({required this.model, super.key});

  final CodexAppModel model;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

final class _ChatPageState extends State<ChatPage> {
  Timer? _breath;
  bool _settingsOpen = false;

  /// One-shot low-delta sweep at boot: nudges every panel tile once so the
  /// previous app's ghosts (bistable residue) get driven out without a flash.
  bool _bootSweep = true;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModel);
    _syncBreath();
    Timer(const Duration(milliseconds: 450), () {
      if (mounted) {
        setState(() => _bootSweep = false);
        EinkRefreshRegion.request(
          context,
          refreshClass: RefreshClass.text,
          reason: 'boot.sweep',
        );
      }
    });
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    _breath?.cancel();
    super.dispose();
  }

  void _onModel() {
    if (mounted) {
      setState(_syncBreath);
    }
  }

  /// The thinking spiral breathes once a second while Codex works
  /// (ghost-budget-exempt small mark, per REF-001).
  void _syncBreath() {
    final busy = widget.model.phase == TurnPhase.busy;
    if (busy && _breath == null) {
      _breath = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) {
          return;
        }
        widget.model.breathe();
        EinkRefreshRegion.request(
          context,
          refreshClass: RefreshClass.fast,
          reason: 'thinking.breathe',
        );
      });
    } else if (!busy && _breath != null) {
      _breath?.cancel();
      _breath = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final model = widget.model;
    final sepY = Composer.sepYFor(model.inputMode, metrics);
    final settingsRect = metrics.designSettingsMarkRect;
    final shelfTabRect = metrics.designShelfTabRect;

    if (_settingsOpen) {
      return SettingsPage(
        model: model,
        onClose: () => setState(() => _settingsOpen = false),
      );
    }

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: ink.paper)),
        // Page chrome: rules + header + furniture.
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _PageChromePainter(
                metrics: metrics,
                ink: ink,
                title: model.active.isEmpty
                    ? 'a fresh page'
                    : model.active.title,
                sepY: sepY,
                busyNudge: model.busyNudge,
                inputMode: model.inputMode,
              ),
            ),
          ),
        ),
        // Transcript viewport between header (and goal band) and composer.
        Positioned(
          left: 0,
          right: metrics.u(28),
          top: metrics.u(
            PageDesign.firstRuleY -
                PageDesign.ruleStep +
                (model.active.hasGoal || model.goalEditing
                    ? PageDesign.ruleStep * 2
                    : 0),
          ),
          height: metrics.u(
            sepY -
                24 -
                (PageDesign.firstRuleY - PageDesign.ruleStep) -
                (model.active.hasGoal || model.goalEditing
                    ? PageDesign.ruleStep * 2
                    : 0),
          ),
          child: ClipRect(child: TranscriptView(model: model)),
        ),
        // The page's goal, pinned under the header as a hand-flagged line.
        // While editing, this very line is where the words land.
        if (model.active.hasGoal || model.goalEditing)
          Positioned(
            left: 0,
            right: 0,
            top: metrics.u(PageDesign.firstRuleY - PageDesign.ruleStep),
            height: metrics.u(PageDesign.ruleStep * 2),
            child: _GoalBand(model: model),
          ),
        // Composer band.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Composer(key: const ValueKey('composer'), model: model),
        ),
        // Settings sun.
        Positioned(
          left: metrics.u(settingsRect.left - 8),
          top: metrics.u(settingsRect.top - 8),
          width: metrics.u(settingsRect.width + 16),
          height: metrics.u(settingsRect.height + 16),
          child: GestureDetector(
            key: const ValueKey('settings-button'),
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _settingsOpen = true),
          ),
        ),
        // Shelf tab (wide hit strip along the right edge).
        Positioned(
          left: metrics.u(shelfTabRect.left - 26),
          top: metrics.u(shelfTabRect.top - 20),
          width: metrics.u(shelfTabRect.width + 42),
          height: metrics.u(shelfTabRect.height + 40),
          child: GestureDetector(
            key: const ValueKey('shelf-tab'),
            behavior: HitTestBehavior.opaque,
            onTap: model.openShelf,
          ),
        ),
        // The page title doubles as the way to all pages.
        Positioned(
          left: metrics.u(PageDesign.contentX0 + 130),
          top: 0,
          width: metrics.u(500),
          height: metrics.u(120),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: model.openShelf,
          ),
        ),
        // Swipe in from the right edge opens the shelf too.
        Positioned(
          right: 0,
          top: metrics.u(140),
          width: metrics.u(36),
          bottom: metrics.u(400),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) < -80) {
                model.openShelf();
              }
            },
          ),
        ),
        // The page's mind, worn in the header like a small seal; tap to
        // choose a different pen for this page.
        Positioned(
          left: metrics.u(settingsRect.left - 110),
          top: 0,
          width: metrics.u(96),
          height: metrics.u(110),
          child: GestureDetector(
            key: const ValueKey('page-mind-button'),
            behavior: HitTestBehavior.opaque,
            onTap: model.openPageMind,
            child: CustomPaint(
              painter: _MindSealPainter(
                metrics: metrics,
                ink: ink,
                model: model.effectiveModel(model.active),
                effort: model.effectiveEffort(model.active),
                overridden:
                    model.active.mindModel != null ||
                    model.active.mindEffort != null,
              ),
            ),
          ),
        ),
        if (model.pageMindOpen)
          Positioned.fill(child: _PageMindSheet(model: model)),
        if (_bootSweep)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: ink.softInk.withAlpha(30)),
            ),
          ),
        if (model.shelfOpen) Positioned.fill(child: ShelfOverlay(model: model)),
      ],
    );
  }
}

final class _PageChromePainter extends CustomPainter {
  _PageChromePainter({
    required this.metrics,
    required this.ink,
    required this.title,
    required this.sepY,
    required this.busyNudge,
    required this.inputMode,
  });

  final PageScale metrics;
  final PaperInk ink;
  final String title;
  final double sepY;
  final bool busyNudge;
  final AuthorMode inputMode;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));

    // Transcript rules from the first rule to just above the separator.
    for (
      var y = PageDesign.firstRuleY;
      y <= sepY - PageDesign.ruleStep;
      y += PageDesign.ruleStep
    ) {
      sketch.line(
        PageDesign.contentX0,
        y,
        metrics.designContentX1,
        y,
        1,
        ink.faintRule,
      );
    }

    // Header.
    _line(
      canvas,
      'paper codex',
      x: PageDesign.contentX0,
      baseline: PageDesign.headerBaselineY.toDouble(),
      style: PaperType.wordmark(ink),
    );
    _line(
      canvas,
      title,
      x: PageDesign.contentX0 + 144,
      baseline: PageDesign.headerBaselineY.toDouble(),
      style: PaperType.note(ink, size: 30, color: ink.ink),
      maxWidth: metrics.designContentW - 280,
    );
    // A small underline chevron marks the title as the door to all pages.
    sketch.strokePath(
      [
        Offset(PageDesign.contentX0 + 148, PageDesign.headerBaselineY + 12),
        Offset(PageDesign.contentX0 + 170, PageDesign.headerBaselineY + 14),
      ],
      1.2,
      ink.softInk,
    );

    Glyphs.settingsMark(sketch, ink, at: metrics.designSettingsMarkRect);
    Glyphs.shelfTab(sketch, ink, at: metrics.designShelfTabRect);

    if (busyNudge) {
      final referenceRect = inputMode == AuthorMode.keyboard
          ? PageDesign.busyNoteKb
          : PageDesign.busyNoteHw;
      final noteRect = Rect.fromLTWH(
        referenceRect.left,
        metrics.bottomY(referenceRect.top),
        metrics.designContentW,
        referenceRect.height,
      );
      _line(
        canvas,
        'Codex is still writing this page.',
        x: noteRect.left + 8,
        baseline: noteRect.bottom - 6,
        style: PaperType.note(ink, color: ink.ink),
      );
    }
    canvas.restore();
  }

  void _line(
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
  bool shouldRepaint(_PageChromePainter old) =>
      old.title != title ||
      old.sepY != sepY ||
      old.busyNudge != busyNudge ||
      old.inputMode != inputMode ||
      old.ink != ink ||
      old.metrics != metrics;
}

/// The pinned goal: flag + hand-lettered goal on the first ruling, status
/// told the way paper tells it — solid underline while active, pause bars
/// while resting, a strike and a check when done. Three small wells on the
/// right pause/resume, edit, and mark it done.
final class _GoalBand extends StatelessWidget {
  const _GoalBand({required this.model});

  final CodexAppModel model;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final session = model.active;
    final status = session.goalStatus ?? GoalStatus.active;
    final editing = model.goalEditing;
    double wellLeft(int slot) =>
        metrics.u(metrics.designContentX1 - 168 + slot * 60.0);
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _GoalBandPainter(
              metrics: metrics,
              ink: ink,
              text: editing ? model.keyboardDraft : (session.goalText ?? ''),
              status: status,
              editing: editing,
              caret: editing ? model.caret : null,
            ),
          ),
        ),
        if (!editing)
          for (final (slot, action) in [
            (0, model.toggleGoalPaused),
            (1, model.beginGoalEdit),
            (2, model.toggleGoalDone),
          ])
            Positioned(
              left: wellLeft(slot),
              top: 0,
              width: metrics.u(56),
              height: metrics.u(PageDesign.ruleStep * 2),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => unawaited(Future<void>.sync(action)),
              ),
            ),
      ],
    );
  }
}

final class _GoalBandPainter extends CustomPainter {
  _GoalBandPainter({
    required this.metrics,
    required this.ink,
    required this.text,
    required this.status,
    this.editing = false,
    this.caret,
  });

  final PageScale metrics;
  final PaperInk ink;
  final String text;
  final GoalStatus status;

  /// While true the line is being written: caret shown, wells hidden.
  final bool editing;
  final int? caret;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));
    final baseline = PageDesign.ruleStep * 1.5;
    final dimmed = status == GoalStatus.paused && !editing;
    final inkColor = dimmed ? ink.softInk : ink.ink;

    Glyphs.flagMark(sketch, PageDesign.contentX0 - 34, baseline - 2, inkColor);

    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: PaperType.hand(ink, color: inkColor).toTextStyle(),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: metrics.designContentW - 240);
    painter.paint(
      canvas,
      Offset(
        PageDesign.contentX0 + 8,
        baseline -
            painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      ),
    );
    final textRight = PageDesign.contentX0 + 8 + painter.width;

    if (editing) {
      // A steady caret where the next word lands; a light guide rule keeps
      // the writing surface visible even when the line is empty.
      final prefix = text.substring(
        0,
        (caret ?? text.length).clamp(0, text.length),
      );
      final prefixPainter = TextPainter(
        text: TextSpan(
          text: prefix,
          style: PaperType.hand(ink, color: inkColor).toTextStyle(),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final caretX = PageDesign.contentX0 + 8 + prefixPainter.width + 9;
      sketch.line(caretX, baseline - 34, caretX, baseline + 4, 3, ink.ink);
      sketch.line(
        PageDesign.contentX0 + 4,
        baseline + 8,
        metrics.designContentX1 - 4,
        baseline + 9,
        1.2,
        ink.softInk,
      );
      canvas.restore();
      return;
    }

    switch (status) {
      case GoalStatus.active:
        // A firm underline: the pen is holding this thought.
        sketch.strokePath(
          [
            Offset(PageDesign.contentX0 + 6, baseline + 10),
            Offset(textRight + 6, baseline + 12),
          ],
          1.8,
          inkColor,
        );
      case GoalStatus.paused:
        // Resting: a dashed underline, breath held.
        var x = PageDesign.contentX0 + 6.0;
        while (x < textRight) {
          sketch.strokePath(
            [Offset(x, baseline + 11), Offset(x + 18, baseline + 12)],
            1.5,
            ink.softInk,
          );
          x += 34;
        }
      case GoalStatus.done:
        // Struck through with a satisfied check.
        sketch.strokePath(
          [
            Offset(PageDesign.contentX0 + 2, baseline - 12),
            Offset(textRight + 8, baseline - 16),
          ],
          2.0,
          ink.softInk,
        );
    }

    // The three wells: pause/resume, edit, done.
    final wellsY = baseline - 18;
    final w0 = Rect.fromLTWH(
      metrics.designContentX1 - 168,
      wellsY - 12,
      40,
      40,
    );
    final w1 = Rect.fromLTWH(
      metrics.designContentX1 - 108,
      wellsY - 12,
      40,
      40,
    );
    final w2 = Rect.fromLTWH(metrics.designContentX1 - 48, wellsY - 12, 40, 40);
    if (status == GoalStatus.paused) {
      Glyphs.playMark(sketch, w0, ink.ink);
    } else if (status != GoalStatus.done) {
      // A finished goal cannot pause; the slot stays quiet.
      Glyphs.pauseMark(sketch, w0, ink.softInk);
    }
    Glyphs.pencilMark(sketch, w1, ink.softInk);
    Glyphs.checkMark(
      sketch,
      w2,
      status == GoalStatus.done ? ink.ink : ink.softInk,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoalBandPainter old) =>
      old.text != text ||
      old.status != status ||
      old.editing != editing ||
      old.caret != caret ||
      old.ink != ink ||
      old.metrics != metrics;
}

/// The small seal in the header telling which mind this page writes with:
/// the celestial mark plus one linger-stroke per effort level. A dotted
/// underline whispers that this page overrides the house default.
final class _MindSealPainter extends CustomPainter {
  _MindSealPainter({
    required this.metrics,
    required this.ink,
    required this.model,
    required this.effort,
    required this.overridden,
  });

  final PageScale metrics;
  final PaperInk ink;
  final String? model;
  final String? effort;
  final bool overridden;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));
    final color = ink.softInk;
    const cx = 30.0;
    const cy = 52.0;
    switch (model) {
      case 'gpt-5.6-sol':
        Glyphs.solMark(sketch, cx, cy, color);
      case 'gpt-5.6-luna':
        Glyphs.lunaMark(sketch, cx, cy, color);
      case 'gpt-5.6-terra':
        Glyphs.terraMark(sketch, cx, cy, color);
      default:
        Glyphs.houseMark(sketch, cx, cy, color);
    }
    final level = effort == null ? -1 : MindSettings.efforts.indexOf(effort!);
    for (var i = 0; i <= level; i++) {
      sketch.strokePath(
        [
          Offset(52 + i * 7.0, cy + 10 - i * 3.0),
          Offset(56 + i * 7.0, cy + 8 - i * 3.0),
        ],
        1.5,
        color,
      );
    }
    if (overridden) {
      var x = cx - 16.0;
      while (x < cx + 40) {
        sketch.strokePath(
          [Offset(x, cy + 26), Offset(x + 7, cy + 27)],
          1.1,
          color,
        );
        x += 13;
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MindSealPainter old) =>
      old.model != model ||
      old.effort != effort ||
      old.overridden != overridden ||
      old.ink != ink ||
      old.metrics != metrics;
}

/// A margin card for choosing this page's mind, veiled over the page.
final class _PageMindSheet extends StatelessWidget {
  const _PageMindSheet({required this.model});

  final CodexAppModel model;

  static const double _cardX = 60;
  static const double _cardTop = 170;
  static const double _cardH = 470;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final session = model.active;
    final cardW = metrics.designWidth - _cardX * 2;
    final mindTop = _cardTop + 120.0;
    final effortTop = _cardTop + 300.0;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: model.closePageMind,
            child: ColoredBox(color: ink.veil),
          ),
        ),
        Positioned(
          left: metrics.u(_cardX),
          top: metrics.u(_cardTop),
          width: metrics.u(cardW),
          height: metrics.u(_cardH),
          child: GestureDetector(
            key: const ValueKey('page-mind-sheet'),
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: CustomPaint(
              painter: _PageMindSheetPainter(
                metrics: metrics,
                ink: ink,
                selectedModel: session.mindModel,
                selectedEffort: session.mindEffort,
                houseModel: model.mind.model,
                houseEffort: model.mind.effort,
              ),
            ),
          ),
        ),
        for (final (i, well) in MindRows.mindWells(
          _cardX + 24,
          cardW - 48,
        ).indexed)
          Positioned(
            left: metrics.u(well.left),
            top: metrics.u(mindTop),
            width: metrics.u(well.width),
            height: metrics.u(well.height),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(
                model.setPageMindModel(i < 3 ? MindSettings.models[i] : null),
              ),
            ),
          ),
        for (final (i, well) in MindRows.effortWells(
          _cardX + 24,
          cardW - 48,
        ).indexed)
          Positioned(
            left: metrics.u(well.left),
            top: metrics.u(effortTop),
            width: metrics.u(well.width),
            height: metrics.u(well.height),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(
                model.setPageMindEffort(
                  i >= MindSettings.efforts.length
                      ? null
                      : MindSettings.efforts[i],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

final class _PageMindSheetPainter extends CustomPainter {
  _PageMindSheetPainter({
    required this.metrics,
    required this.ink,
    required this.selectedModel,
    required this.selectedEffort,
    required this.houseModel,
    required this.houseEffort,
  });

  final PageScale metrics;
  final PaperInk ink;
  final String? selectedModel;
  final String? selectedEffort;
  final String? houseModel;
  final String? houseEffort;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));
    final w = size.width / metrics.scale;
    final h = size.height / metrics.scale;

    // An index card: paper, wobbled outline, shadow line.
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = ink.paper);
    sketch.line(8, h + 4, w, h + 4, 2, ink.rule);
    sketch.strokePath(
      [
        const Offset(4, 2),
        Offset(w - 3, 0),
        Offset(w, h - 3),
        Offset(1, h),
        const Offset(4, 2),
      ],
      1.5,
      ink.softInk,
    );

    void line(String text, double x, double baseline, RuledStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style.toTextStyle()),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: w - 48);
      painter.paint(
        canvas,
        Offset(
          x,
          baseline -
              painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
        ),
      );
    }

    line('this page’s mind', 28, 64, PaperType.hand(ink, color: ink.ink));
    line(
      'default follows the house: '
      '${houseModel?.replaceFirst('gpt-5.6-', '') ?? 'as configured'}'
      '${houseEffort == null ? '' : ' · $houseEffort'}',
      28,
      110,
      PaperType.note(ink, size: 24),
    );

    MindRows.paintMindRow(
      canvas,
      sketch,
      ink,
      x0: 24,
      width: w - 48,
      rowTop: 120,
      selected: selectedModel,
    );
    line('thinking', 28, 290, PaperType.hand(ink, color: ink.ink, size: 30));
    MindRows.paintEffortRow(
      canvas,
      sketch,
      ink,
      x0: 24,
      width: w - 48,
      rowTop: 300,
      selected: selectedEffort,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PageMindSheetPainter old) =>
      old.selectedModel != selectedModel ||
      old.selectedEffort != selectedEffort ||
      old.houseModel != houseModel ||
      old.houseEffort != houseEffort ||
      old.ink != ink ||
      old.metrics != metrics;
}
