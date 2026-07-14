import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document_io.dart';
import 'package:paper_ink/src/document/export.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/model/gallery_model.dart';
import 'package:paper_ink/src/model/settings_model.dart';
import 'package:paper_ink/src/ui/bench/bench.dart';
import 'package:paper_ink/src/ui/dock/contextual_dock.dart';
import 'package:paper_ink/src/ui/gallery_page.dart';
import 'package:paper_ink/src/ui/panels/brush_panel.dart';
import 'package:paper_ink/src/ui/panels/color_panel.dart';
import 'package:paper_ink/src/ui/panels/export_panel.dart';
import 'package:paper_ink/src/ui/panels/layers_panel.dart';
import 'package:paper_ink/src/ui/responsive_layout.dart';
import 'package:paper_ink/src/ui/settings_page.dart';
import 'package:paper_ink/src/ui/status_chips.dart';
import 'package:paper_ink/src/ui/text_input_sheet.dart';
import 'package:pluto_ui/pluto_ui.dart';

const _TestViewport _referenceViewport = _TestViewport(
  name: 'reference',
  physicalSize: Size(954, 1696),
  devicePixelRatio: 1,
);
const _TestViewport _goldenViewport = _TestViewport(
  name: 'golden',
  physicalSize: Size(954, 1696),
  devicePixelRatio: 2,
);
const _TestViewport _moveViewport = _TestViewport(
  name: 'Move',
  physicalSize: Size(954, 1696),
  devicePixelRatio: 264 / 160,
);
const _TestViewport _rmViewport = _TestViewport(
  name: 'RM1/RM2',
  physicalSize: Size(1404, 1872),
  devicePixelRatio: 226 / 160,
);

void main() {
  test(
    'production tokens keep one density and only shrink for small windows',
    () {
      for (final Size viewport in <Size>[
        _referenceViewport.logicalSize,
        _moveViewport.logicalSize,
        _rmViewport.logicalSize,
      ]) {
        expect(
          inkViewportFitScale(viewport),
          closeTo(inkProductionDensityScale, 0.000001),
        );
      }
      expect(
        inkViewportFitScale(const Size(381.6, 678.4)),
        closeTo(0.4, 0.000001),
      );
    },
  );

  for (final ({_TestViewport viewport, double expected}) fixture
      in <({_TestViewport viewport, double expected})>[
        (viewport: _referenceViewport, expected: 1),
        (viewport: _goldenViewport, expected: 0.5),
      ]) {
    testWidgets('${fixture.viewport.name} render fixture remains explicit', (
      WidgetTester tester,
    ) async {
      _setViewport(tester, fixture.viewport);
      double? scale;
      await _pumpRoot(
        tester,
        Builder(
          builder: (BuildContext context) {
            scale = inkViewportFitScaleOf(context);
            return const SizedBox.expand();
          },
        ),
      );

      expect(scale, closeTo(fixture.expected, 0.000001));
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'Move and RM controls have equal physical size and RM has more room',
    () {
      const double authoredControl = 80;
      final double logicalControl = authoredControl * inkProductionDensityScale;
      final double moveControlInches =
          logicalControl * _moveViewport.devicePixelRatio / 264;
      final double rmControlInches =
          logicalControl * _rmViewport.devicePixelRatio / 226;

      expect(moveControlInches, closeTo(rmControlInches, 0.000001));
      expect(
        _rmViewport.logicalSize.width,
        greaterThan(_moveViewport.logicalSize.width),
      );
      expect(
        _rmViewport.logicalSize.height,
        greaterThan(_moveViewport.logicalSize.height),
      );
      final Size moveUsableCanvas = Size(
        _moveViewport.logicalSize.width -
            inkBenchSideDesignWidth * inkProductionDensityScale,
        _moveViewport.logicalSize.height -
            (inkBenchSideDesignHeight + inkStatusBandDesignHeight) *
                inkProductionDensityScale,
      );
      final Size rmUsableCanvas = Size(
        _rmViewport.logicalSize.width -
            inkBenchSideDesignWidth * inkProductionDensityScale,
        _rmViewport.logicalSize.height -
            (inkBenchSideDesignHeight + inkStatusBandDesignHeight) *
                inkProductionDensityScale,
      );
      expect(rmUsableCanvas.width, greaterThan(moveUsableCanvas.width));
      expect(rmUsableCanvas.height, greaterThan(moveUsableCanvas.height));
    },
  );

  testWidgets('reference gallery retains the two-column composition', (
    WidgetTester tester,
  ) async {
    _setViewport(tester, _referenceViewport);
    await _pumpGallery(tester);

    final Offset first = tester.getTopLeft(
      find.byKey(const ValueKey<String>('artwork-a')),
    );
    final Offset second = tester.getTopLeft(
      find.byKey(const ValueKey<String>('artwork-b')),
    );
    expect(second.dy, greaterThan(first.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('RM gallery reflows six cards into three columns', (
    WidgetTester tester,
  ) async {
    _setViewport(tester, _rmViewport);
    var settingsCalls = 0;
    await _pumpGallery(
      tester,
      onSettings: () {
        settingsCalls += 1;
      },
    );

    final Offset first = tester.getTopLeft(
      find.byKey(const ValueKey<String>('artwork-a')),
    );
    final Offset second = tester.getTopLeft(
      find.byKey(const ValueKey<String>('artwork-b')),
    );
    final Offset third = tester.getTopLeft(
      find.byKey(const ValueKey<String>('artwork-c')),
    );
    expect(second.dy, closeTo(first.dy, 0.01));
    expect(second.dx, greaterThan(first.dx));
    expect(third.dy, greaterThan(first.dy));
    _expectWithinViewport(
      tester,
      find.byKey(const ValueKey<String>('gallery-settings')),
      _rmViewport,
    );
    await tester.tap(find.byKey(const ValueKey<String>('gallery-settings')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(settingsCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen artwork preset follows the RM physical surface', (
    WidgetTester tester,
  ) async {
    _setViewport(tester, _rmViewport);
    GalleryArtworkSize? created;
    await _pumpRoot(
      tester,
      Align(
        alignment: Alignment.bottomCenter,
        child: NewArtworkChooser(
          onCancel: () {},
          onCreate: (GalleryArtworkSize size) {
            created = size;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('size-screen')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(PaperButton, 'create'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(created?.width, 1404);
    expect(created?.height, 1872);
    expect(tester.takeException(), isNull);
  });

  for (final _TestViewport viewport in <_TestViewport>[
    _moveViewport,
    _rmViewport,
  ]) {
    testWidgets(
      '${viewport.name} editor chrome fills the viewport and stays tappable',
      (WidgetTester tester) async {
        _setViewport(tester, viewport);
        var zoomCalls = 0;
        var menuCalls = 0;
        await _pumpRoot(
          tester,
          Builder(
            builder: (BuildContext context) {
              final double scale = inkViewportFitScaleOf(context);
              return Stack(
                key: const ValueKey<String>('responsive-editor-surface'),
                fit: StackFit.expand,
                children: <Widget>[
                  const ColoredBox(
                    key: ValueKey<String>('responsive-editor-canvas'),
                    color: Color(0xffeeeeee),
                  ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: InkEditorStatusBand(
                      artworkName: 'responsive study',
                      zoomPercent: 100,
                      activeLayerName: 'ink',
                      savePhase: InkSavePhase.quiet,
                      onBack: () {},
                      onArtworkPressed: () {},
                      onZoomPressed: () {
                        zoomCalls += 1;
                      },
                      onLayerPressed: () {},
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                      top: inkStatusBandDesignHeight * scale,
                    ),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: InkBench(
                        dock: InkBenchDock.left,
                        collapsed: false,
                        activeToolId: 'draw',
                        activeBrush: finelinerBrush,
                        brushSize: finelinerBrush.sizeDefault,
                        brushFlow: 1,
                        currentColor: const Color(0xff000000),
                        activeLayerOrdinal: 1,
                        canUndo: false,
                        canRedo: false,
                        onToggleCollapsed: () {},
                        onToolSelected: (_) {},
                        onBrushPressed: () {},
                        onSizeChanged: (_) {},
                        onFlowChanged: (_) {},
                        onColorPressed: () {},
                        onUndo: () {},
                        onRedo: () {},
                        onLayersPressed: () {},
                        onMenuPressed: () {
                          menuCalls += 1;
                        },
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: ContextualDock(
                      mode: ContextualDockMode.selection,
                      onAction: (_) {},
                    ),
                  ),
                ],
              );
            },
          ),
        );

        final Size canvasSize = tester.getSize(
          find.byKey(const ValueKey<String>('responsive-editor-canvas')),
        );
        expect(canvasSize.width, closeTo(viewport.logicalSize.width, 0.01));
        expect(canvasSize.height, closeTo(viewport.logicalSize.height, 0.01));
        expect(
          tester.getSize(find.byKey(const ValueKey<String>('bench-tool-draw'))),
          _closeToSize(
            Size.square(inkBenchToolCellDesignSize * inkProductionDensityScale),
          ),
        );
        final Size statusSize = tester.getSize(
          find.byKey(const ValueKey<String>('ink-status-band')),
        );
        expect(
          statusSize.height,
          closeTo(inkStatusBandDesignHeight * inkProductionDensityScale, 0.01),
        );
        final Size benchSize = tester.getSize(
          find.byKey(const ValueKey<String>('ink-bench-left')),
        );
        expect(
          benchSize,
          _closeToSize(
            Size(
              inkBenchSideDesignWidth * inkProductionDensityScale,
              inkBenchSideDesignHeight * inkProductionDensityScale,
            ),
          ),
        );
        expect(
          canvasSize.width - benchSize.width,
          closeTo(
            viewport.logicalSize.width -
                inkBenchSideDesignWidth * inkProductionDensityScale,
            0.01,
          ),
        );
        expect(
          canvasSize.height - benchSize.height - statusSize.height,
          closeTo(
            viewport.logicalSize.height -
                (inkBenchSideDesignHeight + inkStatusBandDesignHeight) *
                    inkProductionDensityScale,
            0.01,
          ),
        );
        for (final String key in <String>[
          'ink-status-band',
          'ink-bench-left',
          'bench-menu',
          'status-zoom',
        ]) {
          _expectWithinViewport(
            tester,
            find.byKey(ValueKey<String>(key)),
            viewport,
          );
        }
        await tester.tap(find.byKey(const ValueKey<String>('status-zoom')));
        await tester.tap(find.byKey(const ValueKey<String>('bench-menu')));
        await tester.pump();
        expect(zoomCalls, 1);
        expect(menuCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final _TestViewport viewport in <_TestViewport>[
    _moveViewport,
    _rmViewport,
  ]) {
    testWidgets('${viewport.name} panels fit and retain their close actions', (
      WidgetTester tester,
    ) async {
      _setViewport(tester, viewport);
      var closed = 0;

      await _pumpPanel(
        tester,
        BrushPanel(
          activeBrushId: finelinerBrush.id,
          onClose: () {
            closed += 1;
          },
          onBrushSelected: (_) {},
          onOptionsChanged: (_) {},
        ),
      );
      _expectWithinViewport(tester, find.byType(BrushPanel), viewport);
      expect(
        tester.getSize(find.byType(BrushPanel)),
        _closeToSize(
          const Size(brushPanelDesignWidth, brushPanelDesignHeight) *
              inkProductionDensityScale,
        ),
      );
      await tester.tap(find.bySemanticsLabel('Close brush panel'));
      await tester.pump();

      await _pumpPanel(
        tester,
        ColorPanel(
          selectedColor: const Color(0xff000000),
          recents: const <Color>[],
          onClose: () {
            closed += 1;
          },
          onColorSelected: (_) {},
        ),
      );
      _expectWithinViewport(tester, find.byType(ColorPanel), viewport);
      await tester.tap(find.bySemanticsLabel('Close color panel'));
      await tester.pump();

      await _pumpPanel(
        tester,
        LayersPanel(
          activeLayerId: 'ink',
          layers: const <LayerPanelItem>[
            LayerPanelItem(id: 'ink', name: 'ink'),
          ],
          onClose: () {
            closed += 1;
          },
          onLayerSelected: (_) {},
          onAddLayer: () {},
        ),
      );
      _expectWithinViewport(tester, find.byType(LayersPanel), viewport);
      _expectWithinViewport(
        tester,
        find.byKey(const ValueKey<String>('layers-add')),
        viewport,
      );
      await tester.tap(find.bySemanticsLabel('Close layers panel'));
      await tester.pump();

      await _pumpPanel(
        tester,
        ExportPanel(
          artworkId: 'responsive-artwork',
          onClose: () {
            closed += 1;
          },
          onExport:
              ({
                required String artworkId,
                required InkExportKind kind,
                InkExportProgressCallback? onProgress,
              }) async => InkExportSuccess(kind: kind, path: '/tmp/export'),
        ),
      );
      _expectWithinViewport(tester, find.byType(ExportPanel), viewport);
      _expectWithinViewport(
        tester,
        find.byKey(const ValueKey<String>('export-png-1x')),
        viewport,
      );
      await tester.tap(find.bySemanticsLabel('Close export panel'));
      await tester.pump();

      expect(closed, 4);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('RM settings and text sheets expose reachable controls', (
    WidgetTester tester,
  ) async {
    _setViewport(tester, _rmViewport);
    final InkSettingsModel settings = InkSettingsModel(
      store: _MemorySettingsStore(),
      initial: InkSettings(),
    );
    addTearDown(settings.dispose);
    await _pumpRoot(
      tester,
      SettingsPage(
        model: settings,
        autoLoad: false,
        onBack: () {},
        onDeepClean: () async {},
      ),
    );

    _expectWithinViewport(
      tester,
      find.byKey(const ValueKey<String>('eraser-default-control')),
      _rmViewport,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('eraser-default-control')),
        matching: find.text('lasso'),
      ),
    );
    await tester.pump();
    expect(settings.settings.eraserDefault, EraserDefaultPreference.lasso);

    var committed = '';
    await _pumpRoot(
      tester,
      Align(
        alignment: Alignment.bottomCenter,
        child: TextInputSheet(
          initialText: 'ink',
          font: InkTextFontFamily.inter,
          fontSizeDesignPx: 32,
          fontWeight: FontWeight.w600,
          currentColor: const Color(0xff000000),
          onDone: (String value) {
            committed = value;
          },
        ),
      ),
    );
    _expectWithinViewport(
      tester,
      find.bySemanticsLabel('Text input sheet'),
      _rmViewport,
    );
    await tester.tap(find.text('q'));
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(committed, 'inkq');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpGallery(
  WidgetTester tester, {
  VoidCallback? onSettings,
}) async {
  final GalleryModel model = GalleryModel(
    entries: <GalleryEntry>[
      for (final String id in <String>['a', 'b', 'c', 'd', 'e'])
        GalleryEntry(id: id, name: 'art $id', createdAtMs: 1, modifiedAtMs: 2),
    ],
  );
  addTearDown(model.dispose);
  await _pumpRoot(
    tester,
    GalleryPage(
      model: model,
      autoLoad: false,
      onOpenArtwork: (_) {},
      onSettings: onSettings ?? () {},
    ),
  );
}

Future<void> _pumpPanel(WidgetTester tester, Widget panel) {
  return _pumpRoot(
    tester,
    Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ColoredBox(color: Color(0xffeeeeee)),
        Align(alignment: Alignment.bottomRight, child: panel),
      ],
    ),
  );
}

Future<void> _pumpRoot(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: WidgetsApp(
        color: const Color(0xffffffff),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PaperPageRoute<T>(settings: settings, builder: builder),
        home: child,
      ),
    ),
  );
  await tester.pump();
}

void _setViewport(WidgetTester tester, _TestViewport viewport) {
  tester.view.physicalSize = viewport.physicalSize;
  tester.view.devicePixelRatio = viewport.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _expectWithinViewport(
  WidgetTester tester,
  Finder finder,
  _TestViewport viewport,
) {
  final Rect rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(-0.01));
  expect(rect.top, greaterThanOrEqualTo(-0.01));
  expect(rect.right, lessThanOrEqualTo(viewport.logicalSize.width + 0.01));
  expect(rect.bottom, lessThanOrEqualTo(viewport.logicalSize.height + 0.01));
}

Matcher _closeToSize(Size expected) => isA<Size>()
    .having((Size size) => size.width, 'width', closeTo(expected.width, 0.01))
    .having(
      (Size size) => size.height,
      'height',
      closeTo(expected.height, 0.01),
    );

final class _TestViewport {
  const _TestViewport({
    required this.name,
    required this.physicalSize,
    required this.devicePixelRatio,
  });

  final String name;
  final Size physicalSize;
  final double devicePixelRatio;

  Size get logicalSize => physicalSize / devicePixelRatio;
}

final class _MemorySettingsStore implements InkSettingsStore {
  InkSettings saved = InkSettings();

  @override
  Future<InkSettings> load() async => saved;

  @override
  Future<void> save(InkSettings settings) async {
    saved = settings;
  }
}
