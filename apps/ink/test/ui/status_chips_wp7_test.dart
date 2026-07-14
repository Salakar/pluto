import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/ui/glyphs.dart';
import 'package:paper_ink/src/ui/status_chips.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  group('WP7 status timing and formatting', () {
    test('binding durations and authored geometry stay canonical', () {
      expect(inkStatusBandDesignHeight, 88);
      expect(inkStatusChipMinimumDesignSize, 80);
      expect(inkDryingIndicatorDelay, const Duration(milliseconds: 300));
      expect(inkSavedIndicatorDuration, const Duration(seconds: 2));
      expect(inkUndoToastDuration, const Duration(milliseconds: 800));
    });

    test('saved timestamp is stable zero-padded local time', () {
      expect(inkSavedTimeLabel(DateTime(2026, 7, 11, 6, 4)), '06:04');
      expect(inkSavedTimeLabel(DateTime(2026, 7, 11, 23, 59)), '23:59');
    });

    test('saved phase requires a timestamp', () {
      expect(
        () => InkEditorStatusBand(
          artworkName: 'study',
          zoomPercent: 100,
          activeLayerName: 'ink',
          savePhase: InkSavePhase.saved,
          onBack: _noop,
          onArtworkPressed: _noop,
          onZoomPressed: _noop,
          onLayerPressed: _noop,
        ),
        throwsAssertionError,
      );
    });

    test('nonzero rotation requires its independent reset callback', () {
      expect(
        () => InkEditorStatusBand(
          artworkName: 'study',
          zoomPercent: 100,
          activeLayerName: 'ink',
          savePhase: InkSavePhase.quiet,
          rotationDegrees: 12,
          onBack: _noop,
          onArtworkPressed: _noop,
          onZoomPressed: _noop,
          onLayerPressed: _noop,
        ),
        throwsAssertionError,
      );
    });
  });

  group('WP7 editor status band', () {
    testWidgets('renders the complete exact-height band in canonical order', (
      WidgetTester tester,
    ) async {
      await _pumpStatus(tester, _statusBand());

      expect(
        tester.getSize(find.byKey(const ValueKey<String>('ink-status-band'))),
        const Size(954, 88),
      );
      expect(find.text('← gallery'), findsOneWidget);
      expect(find.text('saved ·06:04'), findsOneWidget);
      expect(find.text('start here'), findsOneWidget);
      expect(find.text('132%'), findsOneWidget);
      expect(find.text('sketch ▸'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<String>('status-back'))).dx,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey<String>('status-artwork')))
              .dx,
        ),
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey<String>('status-artwork')))
            .dx,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey<String>('status-zoom')))
              .dx,
        ),
      );
    });

    testWidgets('all actionable status cells emit separate callbacks', (
      WidgetTester tester,
    ) async {
      final List<String> actions = <String>[];
      await _pumpStatus(
        tester,
        _statusBand(
          onBack: () => actions.add('back'),
          onArtworkPressed: () => actions.add('rename'),
          onZoomPressed: () => actions.add('zoom'),
          onLayerPressed: () => actions.add('layers'),
        ),
      );

      for (final String key in <String>[
        'status-back',
        'status-artwork',
        'status-zoom',
        'status-layer',
      ]) {
        await tester.tap(find.byKey(ValueKey<String>(key)));
        await tester.pump();
      }

      expect(actions, <String>['back', 'rename', 'zoom', 'layers']);
    });

    testWidgets('drying phase paints the drawn drying mark and live label', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _pumpStatus(
        tester,
        _statusBand(savePhase: InkSavePhase.drying, savedAt: null),
      );

      expect(find.text('drying'), findsOneWidget);
      expect(find.bySemanticsLabel('Artwork drying'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is CustomPaint &&
              widget.painter is InkGlyphPainter &&
              (widget.painter! as InkGlyphPainter).glyph == InkGlyph.markDrying,
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('quiet phase keeps the save slot blank', (
      WidgetTester tester,
    ) async {
      await _pumpStatus(
        tester,
        _statusBand(savePhase: InkSavePhase.quiet, savedAt: null),
      );

      expect(find.text('drying'), findsNothing);
      expect(find.textContaining('saved ·'), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('status-save'))),
        const Size(160, 80),
      );
    });

    testWidgets('rotation tick is absent at zero and independent when shown', (
      WidgetTester tester,
    ) async {
      var resets = 0;
      await _pumpStatus(tester, _statusBand(rotationDegrees: 0));
      expect(
        find.byKey(const ValueKey<String>('status-rotation-reset')),
        findsNothing,
      );

      await _pumpStatus(
        tester,
        _statusBand(rotationDegrees: -17.5, onRotationReset: () => resets += 1),
      );
      expect(find.text('-18°'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('status-rotation-reset')),
      );
      await tester.pump();

      expect(resets, 1);
    });

    testWidgets('heavy artwork state augments the active-layer chip', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _pumpStatus(tester, _statusBand(heavyArtwork: true));

      expect(
        find.bySemanticsLabel('Layers, sketch, heavy artwork'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is CustomPaint &&
              widget.painter is InkGlyphPainter &&
              (widget.painter! as InkGlyphPainter).glyph == InkGlyph.markHeavy,
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('80 dpx status cells resolve to at least 48 lp on device', (
      WidgetTester tester,
    ) async {
      await _pumpStatus(
        tester,
        _statusBand(savePhase: InkSavePhase.quiet, savedAt: null),
        mediaSize: const Size(572.4, 1017.6),
      );

      expect(
        tester
            .getSize(find.byKey(const ValueKey<String>('status-zoom')))
            .height,
        48,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('status-zoom'))).width,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('WP7 transient and warning chips', () {
    testWidgets('undo toast is static, live, and optionally dismissible', (
      WidgetTester tester,
    ) async {
      var dismissals = 0;
      const String message = 'undid stroke';
      final InkUndoToast toast = InkUndoToast(
        message: message,
        onDismiss: () => dismissals += 1,
      );
      expect(toast.duration, inkUndoToastDuration);
      await _pumpStatus(tester, toast);

      expect(find.text(message), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('ink-undo-toast')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('ink-undo-toast')));
      await tester.pump();

      expect(dismissals, 1);
    });

    testWidgets('redo wording is passed through without hidden timers', (
      WidgetTester tester,
    ) async {
      const InkUndoToast toast = InkUndoToast(message: 'redid fill');
      await _pumpStatus(tester, toast);

      expect(find.text('redid fill'), findsOneWidget);
      expect(toast.duration, const Duration(milliseconds: 800));
    });

    testWidgets('margin note is one line and taps to dismiss', (
      WidgetTester tester,
    ) async {
      var dismissals = 0;
      await _pumpStatus(
        tester,
        InkMarginNoteChip(
          message: 'one damaged tile was quarantined',
          onDismiss: () => dismissals += 1,
        ),
      );

      final Text message = tester.widget<Text>(
        find.text('one damaged tile was quarantined'),
      );
      expect(message.maxLines, 1);
      await tester.tap(find.byKey(const ValueKey<String>('ink-margin-note')));
      await tester.pump();

      expect(dismissals, 1);
    });

    testWidgets('heavy margin note uses the weight glyph', (
      WidgetTester tester,
    ) async {
      await _pumpStatus(
        tester,
        InkMarginNoteChip(
          message: 'memory guard active',
          heavy: true,
          onDismiss: _noop,
        ),
      );

      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is CustomPaint &&
              widget.painter is InkGlyphPainter &&
              (widget.painter! as InkGlyphPainter).glyph == InkGlyph.markHeavy,
        ),
        findsOneWidget,
      );
    });

    testWidgets('heavy artwork chip exposes canonical copy and callback', (
      WidgetTester tester,
    ) async {
      var dismissals = 0;
      await _pumpStatus(
        tester,
        InkHeavyArtworkChip(onDismiss: () => dismissals += 1),
      );

      expect(find.text('heavy artwork'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('ink-heavy-artwork')));
      await tester.pump();
      expect(dismissals, 1);
    });

    testWidgets('locked and hidden chips share canonical 800-ms slot', (
      WidgetTester tester,
    ) async {
      const InkLayerStatusChip locked = InkLayerStatusChip(
        message: 'layer locked',
      );
      expect(locked.duration, inkUndoToastDuration);
      await _pumpStatus(tester, locked);
      expect(find.text('layer locked'), findsOneWidget);

      const InkLayerStatusChip hidden = InkLayerStatusChip(
        message: 'layer hidden',
      );
      expect(hidden.duration, inkUndoToastDuration);
      await _pumpStatus(tester, hidden);
      expect(find.text('layer hidden'), findsOneWidget);
    });

    test('layer status rejects silent or noncanonical messages', () {
      expect(
        () => InkLayerStatusChip(message: 'cannot draw'),
        throwsAssertionError,
      );
    });

    testWidgets('marker-missing banner is solid, full width, and exact copy', (
      WidgetTester tester,
    ) async {
      await _pumpStatus(tester, const InkMarkerMissingBanner());

      expect(
        find.text('marker not detected — finger drawing enabled'),
        findsOneWidget,
      );
      expect(
        tester.getSize(
          find.byKey(const ValueKey<String>('ink-marker-missing-banner')),
        ),
        const Size(954, 80),
      );
    });

    testWidgets('marker banner acknowledgement is callback-driven', (
      WidgetTester tester,
    ) async {
      var dismissals = 0;
      await _pumpStatus(
        tester,
        InkMarkerMissingBanner(onDismiss: () => dismissals += 1),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('ink-marker-missing-banner')),
      );
      await tester.pump();
      expect(dismissals, 1);
    });

    testWidgets('generic notice target scales to the 48-lp law', (
      WidgetTester tester,
    ) async {
      await _pumpStatus(
        tester,
        const InkStatusNoticeChip(message: 'saved locally'),
        mediaSize: const Size(572.4, 1017.6),
      );

      expect(
        tester.getSize(find.byType(InkStatusNoticeChip)).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byType(InkStatusNoticeChip)).width,
        greaterThanOrEqualTo(48),
      );
    });
  });
}

InkEditorStatusBand _statusBand({
  InkSavePhase savePhase = InkSavePhase.saved,
  DateTime? savedAt,
  double rotationDegrees = 0,
  bool heavyArtwork = false,
  VoidCallback? onBack,
  VoidCallback? onArtworkPressed,
  VoidCallback? onZoomPressed,
  VoidCallback? onRotationReset,
  VoidCallback? onLayerPressed,
}) {
  return InkEditorStatusBand(
    artworkName: 'start here',
    zoomPercent: 132,
    activeLayerName: 'sketch',
    savePhase: savePhase,
    savedAt: savePhase == InkSavePhase.saved
        ? savedAt ?? DateTime(2026, 7, 11, 6, 4)
        : savedAt,
    rotationDegrees: rotationDegrees,
    heavyArtwork: heavyArtwork,
    onBack: onBack ?? _noop,
    onArtworkPressed: onArtworkPressed ?? _noop,
    onZoomPressed: onZoomPressed ?? _noop,
    onRotationReset: rotationDegrees == 0
        ? onRotationReset
        : onRotationReset ?? _noop,
    onLayerPressed: onLayerPressed ?? _noop,
  );
}

Future<void> _pumpStatus(
  WidgetTester tester,
  Widget child, {
  Size mediaSize = const Size(954, 1696),
}) async {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: mediaSize, devicePixelRatio: 1),
      child: PaperTheme(
        data: const PaperThemeData(isColorPanel: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    ),
  );
}

void _noop() {}
