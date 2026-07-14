import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/export.dart';
import 'package:paper_ink/src/ui/glyphs.dart';
import 'package:paper_ink/src/ui/panels/export_panel.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  test('export panel rejects an empty artwork id', () {
    expect(
      () => ExportPanel(
        artworkId: '',
        onExport: _successfulExport,
        onClose: () {},
      ),
      throwsArgumentError,
    );
  });

  testWidgets('renders authored rows, destination, and import mark', (
    WidgetTester tester,
  ) async {
    await _pumpPanel(tester, onExport: _successfulExport);

    expect(tester.getSize(find.byType(ExportPanel)), const Size(437, 572));
    for (final String key in <String>[
      'export-png-1x',
      'export-png-2x',
      'export-inkpack',
      'export-destination',
      'export-status',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey<String>(key))).height,
        exportPanelRowDesignHeight,
      );
    }
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('export-close'))),
      const Size(80, 80),
    );
    expect(find.text('PNG 1×'), findsOneWidget);
    expect(find.text('PNG 2×'), findsOneWidget);
    expect(find.text('.inkpack backup'), findsOneWidget);
    expect(find.text('documents/exports/'), findsOneWidget);
    expect(find.text('none yet'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is CustomPaint &&
            widget.painter is InkGlyphPainter &&
            (widget.painter! as InkGlyphPainter).glyph == InkGlyph.markImport,
      ),
      findsOneWidget,
    );
  });

  testWidgets('forwards the selected kind and renders discrete progress', (
    WidgetTester tester,
  ) async {
    final Completer<InkExportResult> pending = Completer<InkExportResult>();
    InkExportProgressCallback? progress;
    final List<(String, InkExportKind)> calls = <(String, InkExportKind)>[];
    await _pumpPanel(
      tester,
      onExport:
          ({
            required String artworkId,
            required InkExportKind kind,
            InkExportProgressCallback? onProgress,
          }) {
            calls.add((artworkId, kind));
            progress = onProgress;
            return pending.future;
          },
    );

    await tester.tap(find.byKey(const ValueKey<String>('export-png-2x')));
    await tester.pump();

    expect(calls, <(String, InkExportKind)>[
      ('artwork-a', InkExportKind.png2x),
    ]);
    expect(find.text('flattening…'), findsOneWidget);

    progress!(InkExportPhase.writing);
    await tester.pump();
    expect(find.text('writing…'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('export-png-1x')));
    await tester.pump();
    expect(calls, hasLength(1), reason: 'only one export may run at a time');

    pending.complete(
      InkExportSuccess(
        kind: InkExportKind.png2x,
        path: '/documents/exports/artwork-a-2x.png',
      ),
    );
    // One pump drains the completion microtask (which schedules the rebuild);
    // a second pump renders the done state. The real pipeline also delivers
    // InkExportPhase.done via onProgress, so on device the frame is not late.
    await tester.pump();
    await tester.pump();

    expect(find.text('done'), findsOneWidget);
    expect(find.textContaining('LAST EXPORT  ·  PNG 2×'), findsOneWidget);
  });

  testWidgets('inkpack begins in the required flattening phase', (
    WidgetTester tester,
  ) async {
    final Completer<InkExportResult> pending = Completer<InkExportResult>();
    await _pumpPanel(
      tester,
      onExport:
          ({
            required String artworkId,
            required InkExportKind kind,
            InkExportProgressCallback? onProgress,
          }) => pending.future,
    );

    await tester.tap(find.byKey(const ValueKey<String>('export-inkpack')));
    await tester.pump();

    expect(find.text('flattening…'), findsOneWidget);
    expect(find.text('writing…'), findsNothing);

    pending.complete(
      InkExportSuccess(
        kind: InkExportKind.inkpack,
        path: '/documents/exports/artwork-a.inkpack',
      ),
    );
    await tester.pump();
  });

  testWidgets('typed failure persists with its reason and retries same kind', (
    WidgetTester tester,
  ) async {
    final List<InkExportKind> calls = <InkExportKind>[];
    await _pumpPanel(
      tester,
      onExport:
          ({
            required String artworkId,
            required InkExportKind kind,
            InkExportProgressCallback? onProgress,
          }) async {
            calls.add(kind);
            if (calls.length == 1) {
              return InkExportFailure(kind: kind, reason: 'disk full');
            }
            return InkExportSuccess(
              kind: kind,
              path: '/documents/exports/retry.png',
            );
          },
    );

    await tester.tap(find.byKey(const ValueKey<String>('export-png-1x')));
    await tester.pump();

    expect(find.text('failed — retry'), findsOneWidget);
    expect(find.text('disk full'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('export-retry')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('export-retry'))).height,
      exportPanelRowDesignHeight,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('export-failure-reason')))
          .height,
      exportPanelRowDesignHeight,
    );

    await tester.tap(find.byKey(const ValueKey<String>('export-retry')));
    // The retry's async success resolves and transitions to done across two
    // frames (microtask drain, then rebuild), same as the first-run path.
    await tester.pump();
    await tester.pump();

    expect(calls, <InkExportKind>[InkExportKind.png1x, InkExportKind.png1x]);
    expect(find.text('failed — retry'), findsNothing);
    expect(find.text('disk full'), findsNothing);
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('close callback remains available while an export runs', (
    WidgetTester tester,
  ) async {
    final Completer<InkExportResult> pending = Completer<InkExportResult>();
    var closeCalls = 0;
    await _pumpPanel(
      tester,
      onExport:
          ({
            required String artworkId,
            required InkExportKind kind,
            InkExportProgressCallback? onProgress,
          }) => pending.future,
      onClose: () => closeCalls += 1,
    );

    await tester.tap(find.byKey(const ValueKey<String>('export-png-1x')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('export-close')));
    await tester.pump();

    expect(closeCalls, 1);

    pending.complete(
      InkExportSuccess(
        kind: InkExportKind.png1x,
        path: '/documents/exports/artwork-a-1x.png',
      ),
    );
    await tester.pump();
  });

  testWidgets('export semantics expose actions and dispose in-body', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pumpPanel(tester, onExport: _successfulExport);

    expect(find.bySemanticsLabel('Export panel'), findsOneWidget);
    expect(find.bySemanticsLabel('PNG 1×'), findsOneWidget);
    expect(find.bySemanticsLabel('Close export panel'), findsOneWidget);
    semantics.dispose();
  });
}

Future<InkExportResult> _successfulExport({
  required String artworkId,
  required InkExportKind kind,
  InkExportProgressCallback? onProgress,
}) async {
  onProgress?.call(InkExportPhase.done);
  return InkExportSuccess(kind: kind, path: '/documents/exports/$artworkId');
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  required InkExportRunner onExport,
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: WidgetsApp(
        color: const Color(0xffffffff),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PaperPageRoute<T>(settings: settings, builder: builder),
        home: Align(
          alignment: Alignment.bottomRight,
          child: ExportPanel(
            artworkId: 'artwork-a',
            onExport: onExport,
            onClose: onClose ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
