import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/export.dart';
import 'package:paper_ink/src/document/document_io.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/model/gallery_model.dart';
import 'package:paper_ink/src/model/settings_model.dart';
import 'package:paper_ink/src/ui/bench/bench.dart';
import 'package:paper_ink/src/ui/dock/contextual_dock.dart';
import 'package:paper_ink/src/ui/dock/tool_overlays.dart';
import 'package:paper_ink/src/ui/gallery_page.dart';
import 'package:paper_ink/src/ui/panels/brush_panel.dart';
import 'package:paper_ink/src/ui/panels/color_panel.dart';
import 'package:paper_ink/src/ui/panels/export_panel.dart';
import 'package:paper_ink/src/ui/panels/layers_panel.dart';
import 'package:paper_ink/src/ui/proof_sheet.dart';
import 'package:paper_ink/src/ui/settings_page.dart';
import 'package:paper_ink/src/ui/status_chips.dart';
import 'package:paper_ink/src/ui/text_input_sheet.dart';
import 'package:pluto_ui/pluto_ui.dart';

const double _goldenViewportWidth = 954;
const double _goldenViewportHeight = 1696;
const Size _goldenViewport = Size(_goldenViewportWidth, _goldenViewportHeight);
const Size _goldenSceneSize = Size(
  _goldenViewportWidth / 2,
  _goldenViewportHeight / 2,
);
const double _goldenSceneScale = 0.5;
const Key _sceneKey = ValueKey<String>('ink-golden-scene');

void main() {
  setUpAll(_loadGoldenFonts);

  group('Ink WP7 synchronous integration goldens', () {
    testWidgets('g01 gallery with three artworks', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      final GalleryModel model = GalleryModel(entries: _goldenArtworks());
      addTearDown(model.dispose);
      await tester.pumpWidget(_goldenRoot(child: _galleryScene(model: model)));
      await tester.pump();

      await _expectGolden(tester, 'g01_gallery_three_artworks');
    });

    testWidgets('g02 empty gallery', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      final GalleryModel model = GalleryModel()..finishLoading(const []);
      addTearDown(model.dispose);
      await tester.pumpWidget(_goldenRoot(child: _galleryScene(model: model)));
      await tester.pump();

      await _expectGolden(tester, 'g02_gallery_empty');
    });

    testWidgets('g03 new-artwork chooser', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _newArtworkChooserScene()));
      await tester.pump();

      await _expectGolden(tester, 'g03_new_artwork_chooser');
    });

    testWidgets('g04 editor default chrome', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _editorDefaultScene()));
      await tester.pump();

      await _expectGolden(tester, 'g04_editor_default');
    });

    testWidgets('g05 editor top-docked collapsed bench', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _editorTopCollapsedScene()));
      await tester.pump();

      await _expectGolden(tester, 'g05_editor_top_collapsed');
    });

    testWidgets('g15 settings', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      final InkSettingsModel model = InkSettingsModel(
        store: const _GoldenSettingsStore(),
        initial: InkSettings(
          fingerDrawing: true,
          benchDock: BenchDockPreference.right,
          eraserDefault: EraserDefaultPreference.stroke,
          gridEnabled: true,
          gridStyle: GridStylePreference.dot,
          gridSpacing: 32,
          pressureCurve: PressureCurvePreference.soft,
        ),
      );
      addTearDown(model.dispose);
      await tester.pumpWidget(_goldenRoot(child: _settingsScene(model: model)));
      await tester.pump();

      await _expectGolden(tester, 'g15_settings');
    });

    testWidgets('g16 undo toast and drying chip', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _editorUndoDryingScene()));
      await tester.pump();

      await _expectGolden(tester, 'g16_undo_drying');
    });

    testWidgets('g19 heavy-artwork state', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _editorHeavyArtworkScene()));
      await tester.pump();

      await _expectGolden(tester, 'g19_heavy_artwork');
    });

    testWidgets('g20 marker-missing banner', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _editorMarkerMissingScene()));
      await tester.pump();

      await _expectGolden(tester, 'g20_marker_missing');
    });

    testWidgets('g21 expanded trash', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      final GalleryModel model = GalleryModel(
        operations: _GoldenGalleryOperations(
          entries: _goldenArtworks().take(2).toList(),
          trash: _goldenTrash(),
        ),
      );
      addTearDown(model.dispose);
      await model.openGallery();
      model.setTrashExpanded(true);
      await tester.pumpWidget(_goldenRoot(child: _galleryScene(model: model)));
      await tester.pump();

      await _expectGolden(tester, 'g21_trash_expanded');
    });

    test('writes deterministic WP7 /30 lattice twins', () {
      for (final String name in <String>[
        'g01_gallery_three_artworks',
        'g02_gallery_empty',
        'g03_new_artwork_chooser',
        'g04_editor_default',
        'g05_editor_top_collapsed',
        'g15_settings',
        'g16_undo_drying',
        'g19_heavy_artwork',
        'g20_marker_missing',
        'g21_trash_expanded',
      ]) {
        writeLatticeTwin(name);
      }
    });
  });

  group('Ink WP4 goldens', () {
    testWidgets('g06 brush panel', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _brushPanelScene()));
      await tester.pump();

      await _expectGolden(tester, 'g06_brush_panel');
    });

    testWidgets('g17 all-sixteen brush proof sheet', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      final ProofSheetPlan plan = buildFullProofSheetPlan();
      await tester.pumpWidget(_goldenRoot(child: InkProofSheet(plan: plan)));
      await tester.pump();

      await _expectGolden(tester, 'g17_brush_proof_sheet');
    });

    test('writes deterministic /30 lattice twins', () {
      writeLatticeTwin('g06_brush_panel');
      writeLatticeTwin('g17_brush_proof_sheet');
    });

    test('lattice PNG post-process uses /30 rails and preserves alpha', () {
      final Uint8List source = _encodeRgbaPng(
        3,
        1,
        Uint8List.fromList(<int>[
          0,
          0,
          0,
          255,
          128,
          128,
          128,
          200,
          255,
          255,
          255,
          255,
        ]),
      );

      expect(
        _decodePng(quantizeGoldenPng(source)).rgba,
        orderedEquals(<int>[0, 0, 0, 255, 85, 85, 85, 200, 255, 255, 255, 255]),
      );
    });
  });

  group('Ink WP8 export golden', () {
    testWidgets('g14 export panel', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _exportPanelScene()));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('export-png-1x')));
      await tester.pump();

      await _expectGolden(tester, 'g14_export_panel');
    });

    test('writes deterministic WP8 /30 lattice twin', () {
      writeLatticeTwin('g14_export_panel');
    });
  });

  group('Ink WP5 synchronous tool goldens', () {
    testWidgets('g10 selection active and contextual dock', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _selectionDockScene()));
      await tester.pump();

      await _expectGolden(tester, 'g10_selection_active_dock');
    });

    testWidgets('g11 transform handles and rotation lug', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _transformScene()));
      await tester.pump();

      await _expectGolden(tester, 'g11_transform_handles');
    });

    testWidgets('g12 live shape drag', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _shapeScene()));
      await tester.pump();

      await _expectGolden(tester, 'g12_shape_live_drag');
    });

    testWidgets('g13 text input sheet and PaperKeyboard', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _textSheetScene()));
      await tester.pump();

      await _expectGolden(tester, 'g13_text_sheet_keyboard');
    });

    testWidgets('g18 persistent guides and quad symmetry', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _guidesScene()));
      await tester.pump();

      await _expectGolden(tester, 'g18_guides_symmetry');
    });

    testWidgets('g22 radius-averaged eyedropper loupe', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _eyedropperScene()));
      await tester.pump();

      await _expectGolden(tester, 'g22_eyedropper_loupe');
    });

    testWidgets('g23 active crop rectangle', (WidgetTester tester) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _cropScene()));
      await tester.pump();

      await _expectGolden(tester, 'g23_crop_active');
    });

    test('writes deterministic WP5 /30 lattice twins', () {
      for (final String name in <String>[
        'g10_selection_active_dock',
        'g11_transform_handles',
        'g12_shape_live_drag',
        'g13_text_sheet_keyboard',
        'g18_guides_symmetry',
        'g22_eyedropper_loupe',
        'g23_crop_active',
      ]) {
        writeLatticeTwin(name);
      }
    });
  });

  group('Ink WP6 synchronous panel goldens', () {
    testWidgets('g07 color panel, color presenter', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _colorPanelScene()));
      await tester.pump();

      await _expectGolden(tester, 'g07_color_panel_color');
    });

    testWidgets('g08 color panel, monochrome presenter', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(
        _goldenRoot(child: _colorPanelScene(presenterDrivesColor: false)),
      );
      await tester.pump();

      await _expectGolden(tester, 'g08_color_panel_mono');
    });

    testWidgets('g09 five content layers and one reference', (
      WidgetTester tester,
    ) async {
      _setGoldenViewport(tester);
      await tester.pumpWidget(_goldenRoot(child: _layersPanelScene()));
      await tester.pump();

      await _expectGolden(tester, 'g09_layers_panel');
    });

    test('writes deterministic WP6 /30 lattice twins', () {
      for (final String name in <String>[
        'g07_color_panel_color',
        'g08_color_panel_mono',
        'g09_layers_panel',
      ]) {
        writeLatticeTwin(name);
      }
    });
  });
}

List<GalleryEntry> _goldenArtworks() => <GalleryEntry>[
  _goldenGalleryEntry(
    id: 'start-here',
    name: 'start here',
    created: DateTime.utc(2026, 6, 2, 12),
    modified: DateTime.utc(2026, 7, 10, 12),
  ),
  _goldenGalleryEntry(
    id: 'quiet-harbor',
    name: 'quiet harbor',
    created: DateTime.utc(2026, 6, 14, 12),
    modified: DateTime.utc(2026, 7, 8, 12),
  ),
  _goldenGalleryEntry(
    id: 'window-plants',
    name: 'window plants',
    created: DateTime.utc(2026, 5, 18, 12),
    modified: DateTime.utc(2026, 7, 4, 12),
  ),
];

List<GalleryTrashEntry> _goldenTrash() => <GalleryTrashEntry>[
  GalleryTrashEntry(
    entry: _goldenGalleryEntry(
      id: 'folded-map',
      name: 'folded map',
      created: DateTime.utc(2026, 5, 7, 12),
      modified: DateTime.utc(2026, 6, 28, 12),
    ),
    trashedAtMs: DateTime.utc(2026, 7, 9, 12).millisecondsSinceEpoch,
  ),
  GalleryTrashEntry(
    entry: _goldenGalleryEntry(
      id: 'rain-notes',
      name: 'rain notes',
      created: DateTime.utc(2026, 4, 21, 12),
      modified: DateTime.utc(2026, 6, 19, 12),
    ),
    trashedAtMs: DateTime.utc(2026, 7, 7, 12).millisecondsSinceEpoch,
  ),
  GalleryTrashEntry(
    entry: _goldenGalleryEntry(
      id: 'old-grid',
      name: 'old grid',
      created: DateTime.utc(2026, 3, 12, 12),
      modified: DateTime.utc(2026, 6, 11, 12),
    ),
    trashedAtMs: DateTime.utc(2026, 7, 5, 12).millisecondsSinceEpoch,
  ),
];

GalleryEntry _goldenGalleryEntry({
  required String id,
  required String name,
  required DateTime created,
  required DateTime modified,
}) => GalleryEntry(
  id: id,
  name: name,
  createdAtMs: created.millisecondsSinceEpoch,
  modifiedAtMs: modified.millisecondsSinceEpoch,
);

Widget _galleryScene({required GalleryModel model}) => GalleryPage(
  model: model,
  autoLoad: false,
  onOpenArtwork: (_) {},
  onSettings: () {},
  onExit: () {},
);

Widget _newArtworkChooserScene() => Stack(
  fit: StackFit.expand,
  children: <Widget>[
    const CustomPaint(painter: _GoldenCanvasPainter()),
    Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: double.infinity,
        child: NewArtworkChooser(onCancel: () {}, onCreate: (_) {}),
      ),
    ),
  ],
);

Widget _settingsScene({required InkSettingsModel model}) => SettingsPage(
  model: model,
  autoLoad: false,
  onBack: () {},
  onDeepClean: () => Future<void>.value(),
  onShowLicenses: () {},
);

Widget _editorDefaultScene() =>
    _editorChromeScene(artworkName: 'start here', activeLayerName: 'sketch');

Widget _editorTopCollapsedScene() => _editorChromeScene(
  artworkName: 'shape studies',
  activeLayerName: 'linework',
  dock: InkBenchDock.top,
  collapsed: true,
  activeToolId: InkBenchTool.guides.id,
  zoomPercent: 84,
  savePhase: InkSavePhase.saved,
  savedAt: DateTime(2026, 7, 11, 10, 42),
);

Widget _editorUndoDryingScene() => _editorChromeScene(
  artworkName: 'morning study',
  activeLayerName: 'ink',
  savePhase: InkSavePhase.drying,
  feedback: InkUndoToast(message: 'undid stroke', onDismiss: () {}),
);

Widget _editorHeavyArtworkScene() => _editorChromeScene(
  artworkName: 'city layers',
  activeLayerName: 'highlights',
  activeLayerOrdinal: 12,
  heavyArtwork: true,
  feedback: InkHeavyArtworkChip(onDismiss: () {}),
);

Widget _editorMarkerMissingScene() => _editorChromeScene(
  artworkName: 'start here',
  activeLayerName: 'sketch',
  markerMissing: true,
);

Widget _editorChromeScene({
  required String artworkName,
  required String activeLayerName,
  InkBenchDock dock = InkBenchDock.left,
  bool collapsed = false,
  String activeToolId = 'draw',
  int activeLayerOrdinal = 1,
  int zoomPercent = 100,
  InkSavePhase savePhase = InkSavePhase.quiet,
  DateTime? savedAt,
  bool heavyArtwork = false,
  Widget? feedback,
  bool markerMissing = false,
}) => Stack(
  fit: StackFit.expand,
  children: <Widget>[
    const CustomPaint(painter: _GoldenToolCanvasPainter()),
    Align(
      alignment: Alignment.topCenter,
      child: InkEditorStatusBand(
        artworkName: artworkName,
        zoomPercent: zoomPercent,
        activeLayerName: activeLayerName,
        savePhase: savePhase,
        savedAt: savedAt,
        heavyArtwork: heavyArtwork,
        onBack: () {},
        onArtworkPressed: () {},
        onZoomPressed: () {},
        onLayerPressed: () {},
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(top: inkStatusBandDesignHeight / 2),
      child: Align(
        alignment: dock.alignment,
        child: InkBench(
          dock: dock,
          collapsed: collapsed,
          activeToolId: activeToolId,
          activeBrush: finelinerBrush,
          brushSize: finelinerBrush.sizeDefault,
          brushFlow: 1,
          currentColor: const Color(0xff000000),
          activeLayerOrdinal: activeLayerOrdinal,
          canUndo: true,
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
          onMenuPressed: () {},
          onDockChanged: (_) {},
        ),
      ),
    ),
    if (feedback != null)
      Positioned(
        top: (inkStatusBandDesignHeight + 12) / 2,
        left: 88,
        child: feedback,
      ),
    if (markerMissing)
      Positioned(
        top: inkStatusBandDesignHeight / 2,
        left: 0,
        right: 0,
        child: InkMarkerMissingBanner(onDismiss: () {}),
      ),
  ],
);

Widget _brushPanelScene() => Stack(
  fit: StackFit.expand,
  children: <Widget>[
    const CustomPaint(painter: _GoldenCanvasPainter()),
    Align(
      alignment: Alignment.bottomRight,
      child: BrushPanel(
        activeBrushId: 'toneshader',
        onClose: () {},
        onBrushSelected: (_) {},
        onOptionsChanged: (_) {},
        inkTune: true,
        onOpenProofSheet: () {},
      ),
    ),
  ],
);

Widget _exportPanelScene() => SizedBox(
  width: _goldenViewport.width / 2,
  height: _goldenViewport.height / 2,
  child: ColoredBox(
    color: const Color(0xffffffff),
    child: Align(
      alignment: Alignment.bottomRight,
      child: ExportPanel(
        artworkId: 'quiet-harbor',
        onExport:
            ({
              required String artworkId,
              required InkExportKind kind,
              InkExportProgressCallback? onProgress,
            }) async => InkExportSuccess(
              kind: kind,
              path: 'documents/exports/quiet-harbor.png',
            ),
        onClose: () {},
      ),
    ),
  ),
);

Widget _colorPanelScene({bool presenterDrivesColor = true}) => Stack(
  fit: StackFit.expand,
  children: <Widget>[
    const CustomPaint(painter: _GoldenCanvasPainter()),
    Align(
      alignment: Alignment.bottomRight,
      child: ColorPanel(
        selectedColor: const Color(0xffb3261e),
        recents: const <Color>[
          Color(0xffb3261e),
          Color(0xff1d3e74),
          Color(0xffffef78),
          Color(0xff2e5d34),
          Color(0xff5c2a5e),
          Color(0xff1a8fa8),
          Color(0xffa9895f),
          Color(0xff2b3540),
        ],
        presenterDrivesColor: presenterDrivesColor,
        hsvHue: 4,
        hsvSaturation: 0.83,
        hsvValue: 0.70,
        onClose: () {},
        onColorSelected: (_) {},
      ),
    ),
  ],
);

Widget _layersPanelScene() => Stack(
  fit: StackFit.expand,
  children: <Widget>[
    const CustomPaint(painter: _GoldenCanvasPainter()),
    Align(
      alignment: Alignment.bottomRight,
      child: LayersPanel(
        activeLayerId: 'linework',
        referenceLayers: const <LayerPanelItem>[
          LayerPanelItem(
            id: 'reference-pose',
            name: 'pose ref',
            opacityPercent: 53,
            isLocked: true,
            thumbnailSeed: 19,
          ),
        ],
        layers: const <LayerPanelItem>[
          LayerPanelItem(
            id: 'highlights',
            name: 'light',
            opacityPercent: 67,
            thumbnailSeed: 2,
          ),
          LayerPanelItem(
            id: 'linework',
            name: 'linework',
            opacityPercent: 87,
            thumbnailSeed: 7,
          ),
          LayerPanelItem(
            id: 'wash',
            name: 'wash',
            opacityPercent: 47,
            isLocked: true,
            thumbnailSeed: 11,
          ),
          LayerPanelItem(
            id: 'rough',
            name: 'rough',
            opacityPercent: 33,
            isVisible: false,
            thumbnailSeed: 13,
          ),
          LayerPanelItem(
            id: 'paper-tone',
            name: 'paper',
            opacityPercent: 100,
            thumbnailSeed: 17,
          ),
        ],
        onClose: () {},
        onLayerSelected: (_) {},
        onAddLayer: () {},
        onVisibilityChanged: (_, _) {},
        onLockChanged: (_, _) {},
        onOpacityChanged: (_, _) {},
        onLayerReordered: (_, _) {},
        onReferenceReordered: (_, _) {},
        onRenameLayer: (_) {},
        onDuplicateLayer: (_) {},
        onMergeLayerDown: (_) {},
        onClearLayer: (_) {},
        onDeleteLayer: (_) {},
        onDeleteReference: (_) {},
      ),
    ),
  ],
);

Widget _selectionDockScene() => _boundedToolScene(
  overlayPainter: SelectionOutlinePainter(
    outline: Path()
      ..addRect(
        const Rect.fromLTWH(
          228 * _goldenSceneScale,
          394 * _goldenSceneScale,
          526 * _goldenSceneScale,
          482 * _goldenSceneScale,
        ),
      ),
    strokeWidth: math.max(1, 2 * _goldenSceneScale),
    dashLength: 18 * _goldenSceneScale,
    gapLength: 12 * _goldenSceneScale,
  ),
  dockMode: ContextualDockMode.selection,
  selectedActions: const <ContextualDockAction>{
    ContextualDockAction.selectLasso,
    ContextualDockAction.selectAdd,
  },
  disabledActions: const <ContextualDockAction>{ContextualDockAction.paste},
);

Widget _transformScene() => _boundedToolScene(
  overlayPainter: TransformHandlesPainter(
    bounds: const Rect.fromLTWH(
      240 * _goldenSceneScale,
      420 * _goldenSceneScale,
      510 * _goldenSceneScale,
      520 * _goldenSceneScale,
    ),
    handleVisualSize: 24 * _goldenSceneScale,
    rotationLugDistance: 86 * _goldenSceneScale,
    strokeWidth: math.max(1, 3 * _goldenSceneScale),
  ),
  dockMode: ContextualDockMode.transform,
  selectedActions: const <ContextualDockAction>{ContextualDockAction.aspect},
);

Widget _shapeScene() => _boundedToolScene(
  overlayPainter: LiveShapePainter(
    kind: LiveShapeKind.arrow,
    start: const Offset(214, 868) * _goldenSceneScale,
    end: const Offset(756, 432) * _goldenSceneScale,
    strokeWidth: math.max(2, 6 * _goldenSceneScale),
    perfected: true,
  ),
  dockMode: ContextualDockMode.shape,
  selectedActions: const <ContextualDockAction>{
    ContextualDockAction.shapeArrow,
    ContextualDockAction.perfect,
  },
);

Widget _textSheetScene() => LayoutBuilder(
  builder: (BuildContext context, BoxConstraints constraints) {
    final double scale = constraints.maxWidth / _goldenViewport.width;
    final Rect textBounds = Rect.fromLTWH(
      196 * scale,
      284 * scale,
      590 * scale,
      154 * scale,
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const CustomPaint(painter: _GoldenToolCanvasPainter()),
        CustomPaint(
          painter: _GoldenTextBlockPainter(
            bounds: textBounds,
            text: 'A quiet line of ink',
            scale: scale,
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: TextInputSheet(
            initialText: 'A quiet line of ink',
            font: InkTextFontFamily.inter,
            fontSizeDesignPx: 44,
            fontWeight: FontWeight.w600,
            currentColor: const Color(0xff1d3e74),
            onDone: (_) {},
          ),
        ),
      ],
    );
  },
);

Widget _guidesScene() => _boundedToolScene(
  overlayPainter: const GuidesSymmetryPainter(
    gridSpacing: 64 * _goldenSceneScale,
    gridOrigin: Offset(18 * _goldenSceneScale, 28 * _goldenSceneScale),
    straightedgeStart: Offset(
      132 * _goldenSceneScale,
      1110 * _goldenSceneScale,
    ),
    straightedgeEnd: Offset(818 * _goldenSceneScale, 760 * _goldenSceneScale),
    symmetry: GuideSymmetryMode.quad,
    verticalAxis: 522 * _goldenSceneScale,
    horizontalAxis: 632 * _goldenSceneScale,
  ),
  dockMode: ContextualDockMode.guides,
  selectedActions: const <ContextualDockAction>{
    ContextualDockAction.straightedge,
    ContextualDockAction.gridLines,
    ContextualDockAction.grid64,
    ContextualDockAction.symmetryQuad,
  },
);

Widget _eyedropperScene() => _boundedToolScene(
  overlayPainter: const EyedropperLoupePainter(
    sampleCenter: Offset(530 * _goldenSceneScale, 786 * _goldenSceneScale),
    loupeCenter: Offset(674 * _goldenSceneScale, 558 * _goldenSceneScale),
    sampledColor: Color(0xff1d3e74),
    todayGray: Color(0xff555555),
    sampleRadius: 10 * _goldenSceneScale,
    loupeRadius: 76 * _goldenSceneScale,
  ),
);

Widget _cropScene() => _boundedToolScene(
  overlayPainter: CropActivePainter(
    artworkBounds: const Rect.fromLTWH(
      92 * _goldenSceneScale,
      154 * _goldenSceneScale,
      770 * _goldenSceneScale,
      1280 * _goldenSceneScale,
    ),
    cropRect: const Rect.fromLTWH(
      188 * _goldenSceneScale,
      324 * _goldenSceneScale,
      580 * _goldenSceneScale,
      862 * _goldenSceneScale,
    ),
    label: '1160 × 1724',
    handleVisualSize: 24 * _goldenSceneScale,
  ),
  dockMode: ContextualDockMode.crop,
);

Widget _boundedToolScene({
  required CustomPainter overlayPainter,
  ContextualDockMode? dockMode,
  Set<ContextualDockAction> selectedActions = const <ContextualDockAction>{},
  Set<ContextualDockAction> disabledActions = const <ContextualDockAction>{},
}) => SizedBox(
  width: _goldenSceneSize.width,
  height: _goldenSceneSize.height,
  child: CustomPaint(
    size: _goldenSceneSize,
    painter: _GoldenBoundedToolScenePainter(
      overlayPainter: overlayPainter,
      dockMode: dockMode,
      selectedActions: selectedActions,
      disabledActions: disabledActions,
    ),
  ),
);

final class _GoldenBoundedToolScenePainter extends CustomPainter {
  const _GoldenBoundedToolScenePainter({
    required this.overlayPainter,
    required this.dockMode,
    required this.selectedActions,
    required this.disabledActions,
  });

  final CustomPainter overlayPainter;
  final ContextualDockMode? dockMode;
  final Set<ContextualDockAction> selectedActions;
  final Set<ContextualDockAction> disabledActions;

  @override
  void paint(Canvas canvas, Size size) {
    const _GoldenToolCanvasPainter().paint(canvas, size);
    overlayPainter.paint(canvas, size);
    final ContextualDockMode? mode = dockMode;
    if (mode != null) {
      _paintDock(canvas, size, mode);
    }
  }

  void _paintDock(Canvas canvas, Size size, ContextualDockMode mode) {
    final double height = contextualDockDesignHeight * _goldenSceneScale;
    final double top = size.height - height;
    final double ruleWidth = math.max(1, 2 * _goldenSceneScale);
    final Paint inkFill = Paint()
      ..color = const Color(0xff000000)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    final Paint paperFill = Paint()
      ..color = const Color(0xffffffff)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    final Paint rule = Paint()
      ..color = const Color(0xff000000)
      ..strokeWidth = ruleWidth
      ..isAntiAlias = false;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, top, size.width, height));
    canvas.drawRect(Rect.fromLTWH(0, top, size.width, height), paperFill);
    canvas.drawLine(Offset(0, top), Offset(size.width, top), rule);

    final double modeWidth = 128 * _goldenSceneScale;
    canvas.drawRect(Rect.fromLTWH(0, top, modeWidth, height), inkFill);
    _paintDockLabel(
      canvas,
      label: _goldenDockModeLabel(mode),
      bounds: Rect.fromLTWH(0, top, modeWidth, height),
      color: const Color(0xffffffff),
      weight: FontWeight.w700,
    );

    double left = modeWidth;
    for (final ContextualDockAction action in contextualDockActionsFor(mode)) {
      final double width = action.designWidth * _goldenSceneScale;
      final Rect cell = Rect.fromLTWH(left, top, width, height);
      final bool selected = selectedActions.contains(action);
      canvas.drawRect(cell, selected ? inkFill : paperFill);
      canvas.drawLine(cell.topLeft, cell.bottomLeft, rule);
      _paintDockLabel(
        canvas,
        label: action.label,
        bounds: cell,
        color: selected
            ? const Color(0xffffffff)
            : disabledActions.contains(action)
            ? const Color(0xff666666)
            : const Color(0xff000000),
        weight: FontWeight.w600,
      );
      left += width;
      if (left >= size.width) {
        break;
      }
    }
    canvas.restore();
  }

  void _paintDockLabel(
    Canvas canvas, {
    required String label,
    required Rect bounds,
    required Color color,
    required FontWeight weight,
  }) {
    final TextPainter text = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontFamily: 'Inter',
          fontFamilyFallback: const <String>['Arial', 'sans-serif'],
          fontSize: 12,
          fontWeight: weight,
          height: 16 / 12,
          letterSpacing: 0.6,
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, bounds.width - 8));
    text.paint(
      canvas,
      Offset(
        bounds.left + (bounds.width - text.width) / 2,
        bounds.top + (bounds.height - text.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(_GoldenBoundedToolScenePainter oldDelegate) => true;
}

String _goldenDockModeLabel(ContextualDockMode mode) => switch (mode) {
  ContextualDockMode.erase => 'ERASER',
  ContextualDockMode.selection => 'SELECT\nMASK',
  ContextualDockMode.transform => 'TRANSFORM',
  ContextualDockMode.fill => 'FILL',
  ContextualDockMode.shape => 'SHAPE',
  ContextualDockMode.text => 'TEXT',
  ContextualDockMode.crop => 'CROP',
  ContextualDockMode.guides => 'GUIDES',
};

final class _GoldenCanvasPainter extends CustomPainter {
  const _GoldenCanvasPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xfff7f6f2), BlendMode.src);
    canvas.save();
    canvas.scale(size.width / _goldenViewport.width);
    final Paint rule = Paint()
      ..color = const Color(0xffdddddd)
      ..strokeWidth = 2
      ..isAntiAlias = false;
    for (double y = 112; y < _goldenViewport.height; y += 96) {
      canvas.drawLine(
        Offset(32, y),
        Offset(_goldenViewport.width - 32, y),
        rule,
      );
    }
    final Paint sketch = Paint()
      ..color = const Color(0xff999999)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke;
    final Path path = Path()..moveTo(78, 380);
    for (var index = 0; index <= 28; index += 1) {
      final double t = index / 28;
      path.lineTo(
        78 + t * 640,
        380 + math.sin(t * math.pi * 5) * (36 + 52 * t),
      );
    }
    canvas.drawPath(path, sketch);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoldenCanvasPainter oldDelegate) => false;
}

final class _GoldenToolCanvasPainter extends CustomPainter {
  const _GoldenToolCanvasPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xfff7f6f2), BlendMode.src);
    canvas.save();
    final double scale = size.width / _goldenViewport.width;
    canvas.scale(scale);

    final Rect artwork = const Rect.fromLTWH(92, 154, 770, 1280);
    canvas.drawRect(
      artwork,
      Paint()
        ..color = const Color(0xffffffff)
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      artwork,
      Paint()
        ..color = const Color(0xff333333)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..isAntiAlias = false,
    );

    final Paint paleRule = Paint()
      ..color = const Color(0xffdddddd)
      ..strokeWidth = 2
      ..isAntiAlias = false;
    for (double y = 226; y < 1390; y += 96) {
      canvas.drawLine(
        const Offset(118, 0) + Offset(0, y),
        Offset(836, y),
        paleRule,
      );
    }

    final Paint blue = Paint()
      ..color = const Color(0xff1d3e74)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.square;
    final Path firstStroke = Path()
      ..moveTo(162, 604)
      ..cubicTo(286, 396, 408, 896, 548, 610)
      ..cubicTo(630, 444, 708, 532, 792, 384);
    canvas.drawPath(firstStroke, blue);

    final Paint charcoal = Paint()
      ..color = const Color(0xff555555)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.square;
    final Path secondStroke = Path()
      ..moveTo(184, 954)
      ..quadraticBezierTo(378, 756, 584, 1006)
      ..quadraticBezierTo(690, 1128, 782, 930);
    canvas.drawPath(secondStroke, charcoal);

    canvas.drawRect(
      const Rect.fromLTWH(160, 1148, 184, 112),
      Paint()
        ..color = const Color(0xffdddddd)
        ..isAntiAlias = false,
    );
    canvas.drawOval(
      const Rect.fromLTWH(590, 1090, 148, 148),
      Paint()
        ..color = const Color(0xff999999)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoldenToolCanvasPainter oldDelegate) => false;
}

final class _GoldenTextBlockPainter extends CustomPainter {
  const _GoldenTextBlockPainter({
    required this.bounds,
    required this.text,
    required this.scale,
  });

  final Rect bounds;
  final String text;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final Path outline = Path()..addRect(bounds);
    SelectionOutlinePainter(
      outline: outline,
      strokeWidth: math.max(1, 2 * scale),
      dashLength: 16 * scale,
      gapLength: 10 * scale,
    ).paint(canvas, size);
    final Paint paper = Paint()
      ..color = const Color(0xffffffff)
      ..isAntiAlias = false;
    final Paint ink = Paint()
      ..color = const Color(0xff000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, 2 * scale)
      ..isAntiAlias = false;
    for (final Offset corner in <Offset>[
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ]) {
      final Rect handle = Rect.fromCenter(
        center: corner,
        width: 22 * scale,
        height: 22 * scale,
      );
      canvas.drawRect(handle, paper);
      canvas.drawRect(handle, ink);
    }
    final TextPainter preview = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xff1d3e74),
          fontFamily: 'Inter',
          fontSize: 44 * scale,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: bounds.width - 32 * scale);
    preview.paint(
      canvas,
      bounds.topLeft + Offset(16 * scale, (bounds.height - preview.height) / 2),
    );
  }

  @override
  bool shouldRepaint(_GoldenTextBlockPainter oldDelegate) {
    return oldDelegate.bounds != bounds ||
        oldDelegate.text != text ||
        oldDelegate.scale != scale;
  }
}

final class _GoldenGalleryOperations implements GalleryOperations {
  _GoldenGalleryOperations({
    required List<GalleryEntry> entries,
    required List<GalleryTrashEntry> trash,
  }) : _entries = List<GalleryEntry>.unmodifiable(entries),
       _trash = List<GalleryTrashEntry>.unmodifiable(trash);

  final List<GalleryEntry> _entries;
  final List<GalleryTrashEntry> _trash;

  @override
  Future<int> collectExpiredTrash(Duration maximumAge) => Future<int>.value(0);

  @override
  Future<void> ensureFirstRunSeed() => Future<void>.value();

  @override
  Future<List<GalleryEntry>> loadEntries() =>
      Future<List<GalleryEntry>>.value(_entries);

  @override
  Future<List<GalleryTrashEntry>> loadTrash() =>
      Future<List<GalleryTrashEntry>>.value(_trash);

  @override
  Future<List<GalleryImportCandidate>> scanImports() =>
      Future<List<GalleryImportCandidate>>.value(
        const <GalleryImportCandidate>[],
      );

  @override
  Future<GalleryEntry?> importArtwork(GalleryImportCandidate candidate) =>
      Future<GalleryEntry?>.value();

  @override
  Future<void> exportArtwork(String artworkId) => Future<void>.value();

  @override
  Future<void> moveToTrash(String artworkId) => Future<void>.value();

  @override
  Future<GalleryEntry> restoreArtwork(String artworkId) =>
      Future<GalleryEntry>.value(
        _trash
            .firstWhere((GalleryTrashEntry item) => item.entry.id == artworkId)
            .entry,
      );

  @override
  Future<GalleryEntry> createArtwork(GalleryArtworkSize size) =>
      throw UnsupportedError('The golden gallery is read-only.');

  @override
  Future<GalleryEntry> duplicateArtwork(String artworkId) =>
      throw UnsupportedError('The golden gallery is read-only.');

  @override
  Future<GalleryEntry> renameArtwork(String artworkId, String name) =>
      throw UnsupportedError('The golden gallery is read-only.');
}

final class _GoldenSettingsStore implements InkSettingsStore {
  const _GoldenSettingsStore();

  @override
  Future<InkSettings> load() => Future<InkSettings>.value(InkSettings());

  @override
  Future<void> save(InkSettings settings) => Future<void>.value();
}

Widget _goldenRoot({required Widget child}) => PaperTheme(
  data: const PaperThemeData(isColorPanel: true),
  child: WidgetsApp(
    color: const Color(0xffffffff),
    debugShowCheckedModeBanner: false,
    pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
        PageRouteBuilder<T>(
          settings: settings,
          pageBuilder:
              (
                BuildContext context,
                Animation<double> primary,
                Animation<double> secondary,
              ) => builder(context),
        ),
    home: Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: _sceneKey,
        // Bounded, fixed logical viewport (physical size / DPR).
        child: SizedBox(
          width: _goldenSceneSize.width,
          height: _goldenSceneSize.height,
          child: ColoredBox(color: const Color(0xffffffff), child: child),
        ),
      ),
    ),
  ),
);

Future<void> _expectGolden(WidgetTester tester, String name) async {
  await expectLater(
    find.byKey(_sceneKey),
    matchesGoldenFile('goldens/$name.png'),
  );
}

/// Reads a rendered golden, quantizes it through the /30 glass proxy, and
/// writes the deterministic review twin under `goldens/lattice/`.
void writeLatticeTwin(String name) {
  final File source = File('test_goldens/goldens/$name.png');
  if (!source.existsSync()) {
    throw StateError('Rendered golden does not exist: ${source.path}.');
  }
  final File destination = File('test_goldens/goldens/lattice/$name.png');
  final Uint8List next = quantizeGoldenPng(source.readAsBytesSync());
  if (autoUpdateGoldenFiles) {
    destination.parent.createSync(recursive: true);
    destination.writeAsBytesSync(next, flush: true);
    return;
  }
  if (!destination.existsSync()) {
    throw StateError(
      'Missing lattice twin ${destination.path}; regenerate with '
      '--update-goldens.',
    );
  }
  expect(
    destination.readAsBytesSync(),
    orderedEquals(next),
    reason: 'lattice twin differs; regenerate $name with --update-goldens',
  );
}

/// Applies `sRGB luma -> luma^1.8 -> nearest /30 lattice level` to a PNG.
Uint8List quantizeGoldenPng(Uint8List encoded) {
  final _DecodedPng source = _decodePng(encoded);
  final Uint8List pixels = Uint8List.fromList(source.rgba);
  const List<int> lattice = <int>[0, 6, 10, 14, 18, 22, 26, 30];
  for (var offset = 0; offset < pixels.length; offset += 4) {
    final double luma =
        (pixels[offset] * 0.2126 +
            pixels[offset + 1] * 0.7152 +
            pixels[offset + 2] * 0.0722) /
        255;
    final double developed = math.pow(luma, 1.8).toDouble() * 30;
    var nearest = lattice.first;
    var nearestDistance = (developed - nearest).abs();
    for (final int candidate in lattice.skip(1)) {
      final double distance = (developed - candidate).abs();
      if (distance < nearestDistance) {
        nearest = candidate;
        nearestDistance = distance;
      }
    }
    final int gray = (nearest * 255 / 30).round();
    pixels[offset] = gray;
    pixels[offset + 1] = gray;
    pixels[offset + 2] = gray;
  }
  return _encodeRgbaPng(source.width, source.height, pixels);
}

void _setGoldenViewport(WidgetTester tester) {
  tester.view.physicalSize = _goldenViewport;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _loadGoldenFonts() async {
  final Directory flutterRoot = _findFlutterRoot();
  final File testFont = _findRepositoryFile(
    'assets/test_fonts/JetBrainsMono-VariableFont_wght.ttf',
  );
  final FontLoader uiLoader = FontLoader('Inter')
    ..addFont(
      _fontData(
        '${flutterRoot.path}/bin/cache/artifacts/material_fonts/'
        'Roboto-Regular.ttf',
      ),
    );
  final FontLoader symbolLoader = FontLoader('Arial')
    ..addFont(_fontData(testFont.path));
  final FontLoader monoLoader = FontLoader('JetBrains Mono')
    ..addFont(_fontData(testFont.path));
  await uiLoader.load();
  await symbolLoader.load();
  await monoLoader.load();
}

File _findRepositoryFile(String relativePath) {
  Directory current = Directory.current.absolute;
  while (true) {
    final File marker = File.fromUri(
      current.uri.resolve('tools/pluto/pins/engine.version'),
    );
    if (marker.existsSync()) {
      final File file = File.fromUri(current.uri.resolve(relativePath));
      if (!file.existsSync()) {
        throw StateError('Repository fixture does not exist: ${file.path}.');
      }
      return file;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }
  throw StateError('Cannot locate the repository from ${Directory.current}.');
}

Directory _findFlutterRoot() {
  Directory current = File(Platform.resolvedExecutable).parent;
  while (current.parent.path != current.path) {
    final File uiFont = File.fromUri(
      current.uri.resolve(
        'bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      ),
    );
    if (uiFont.existsSync()) {
      return current;
    }
    current = current.parent;
  }
  throw StateError(
    'Cannot locate the Flutter SDK from ${Platform.resolvedExecutable}.',
  );
}

Future<ByteData> _fontData(String path) async {
  final Uint8List bytes = await File(path).readAsBytes();
  return ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
}

final class _DecodedPng {
  const _DecodedPng({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

_DecodedPng _decodePng(Uint8List encoded) {
  const List<int> signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  if (encoded.length < signature.length ||
      !_equalBytes(encoded, 0, signature)) {
    throw const FormatException('Invalid PNG signature.');
  }
  var cursor = signature.length;
  var width = 0;
  var height = 0;
  var bitDepth = 0;
  var colorType = -1;
  var interlace = -1;
  Uint8List? palette;
  Uint8List? transparency;
  final BytesBuilder compressed = BytesBuilder(copy: false);
  while (cursor + 12 <= encoded.length) {
    final int length = _readUint32(encoded, cursor);
    final int typeOffset = cursor + 4;
    final int dataOffset = cursor + 8;
    final int next = dataOffset + length + 4;
    if (length < 0 || next > encoded.length) {
      throw const FormatException('Truncated PNG chunk.');
    }
    final String type = String.fromCharCodes(
      encoded.sublist(typeOffset, typeOffset + 4),
    );
    switch (type) {
      case 'IHDR':
        if (length != 13) {
          throw const FormatException('Invalid PNG IHDR length.');
        }
        width = _readUint32(encoded, dataOffset);
        height = _readUint32(encoded, dataOffset + 4);
        bitDepth = encoded[dataOffset + 8];
        colorType = encoded[dataOffset + 9];
        interlace = encoded[dataOffset + 12];
      case 'PLTE':
        palette = Uint8List.fromList(
          encoded.sublist(dataOffset, dataOffset + length),
        );
      case 'tRNS':
        transparency = Uint8List.fromList(
          encoded.sublist(dataOffset, dataOffset + length),
        );
      case 'IDAT':
        compressed.add(encoded.sublist(dataOffset, dataOffset + length));
      case 'IEND':
        cursor = next;
        break;
    }
    cursor = next;
    if (type == 'IEND') {
      break;
    }
  }
  if (width <= 0 || height <= 0) {
    throw const FormatException('PNG has no valid IHDR.');
  }
  if (bitDepth != 8 || interlace != 0) {
    throw FormatException(
      'Only non-interlaced 8-bit PNGs are supported '
      '(depth=$bitDepth, interlace=$interlace).',
    );
  }
  final int bytesPerPixel = switch (colorType) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    _ => throw FormatException('Unsupported PNG color type $colorType.'),
  };
  final Uint8List inflated = Uint8List.fromList(
    ZLibDecoder().convert(compressed.takeBytes()),
  );
  final int stride = width * bytesPerPixel;
  if (inflated.length != height * (stride + 1)) {
    throw const FormatException('PNG scanline payload has an invalid size.');
  }
  final Uint8List samples = _unfilterPng(
    inflated,
    width: width,
    height: height,
    bytesPerPixel: bytesPerPixel,
  );
  final Uint8List rgba = Uint8List(width * height * 4);
  for (var pixel = 0; pixel < width * height; pixel += 1) {
    final int source = pixel * bytesPerPixel;
    final int target = pixel * 4;
    switch (colorType) {
      case 0:
        final int gray = samples[source];
        rgba.setRange(target, target + 3, <int>[gray, gray, gray]);
        rgba[target + 3] = 255;
      case 2:
        rgba.setRange(target, target + 3, samples, source);
        rgba[target + 3] = 255;
      case 3:
        final int index = samples[source];
        if (palette == null || index * 3 + 2 >= palette.length) {
          throw const FormatException('PNG palette index is invalid.');
        }
        rgba.setRange(target, target + 3, palette, index * 3);
        rgba[target + 3] = transparency != null && index < transparency.length
            ? transparency[index]
            : 255;
      case 4:
        final int gray = samples[source];
        rgba.setRange(target, target + 3, <int>[gray, gray, gray]);
        rgba[target + 3] = samples[source + 1];
      case 6:
        rgba.setRange(target, target + 4, samples, source);
    }
  }
  return _DecodedPng(width: width, height: height, rgba: rgba);
}

Uint8List _unfilterPng(
  Uint8List source, {
  required int width,
  required int height,
  required int bytesPerPixel,
}) {
  final int stride = width * bytesPerPixel;
  final Uint8List output = Uint8List(height * stride);
  var sourceOffset = 0;
  for (var y = 0; y < height; y += 1) {
    final int filter = source[sourceOffset];
    sourceOffset += 1;
    final int rowOffset = y * stride;
    final int previousOffset = rowOffset - stride;
    for (var x = 0; x < stride; x += 1) {
      final int raw = source[sourceOffset + x];
      final int left = x >= bytesPerPixel
          ? output[rowOffset + x - bytesPerPixel]
          : 0;
      final int above = y > 0 ? output[previousOffset + x] : 0;
      final int upperLeft = y > 0 && x >= bytesPerPixel
          ? output[previousOffset + x - bytesPerPixel]
          : 0;
      final int predictor = switch (filter) {
        0 => 0,
        1 => left,
        2 => above,
        3 => (left + above) ~/ 2,
        4 => _paeth(left, above, upperLeft),
        _ => throw FormatException('Unsupported PNG filter $filter.'),
      };
      output[rowOffset + x] = (raw + predictor) & 0xff;
    }
    sourceOffset += stride;
  }
  return output;
}

Uint8List _encodeRgbaPng(int width, int height, Uint8List rgba) {
  if (rgba.length != width * height * 4) {
    throw ArgumentError('RGBA payload does not match PNG dimensions.');
  }
  final Uint8List scanlines = Uint8List(height * (width * 4 + 1));
  for (var y = 0; y < height; y += 1) {
    final int target = y * (width * 4 + 1);
    scanlines[target] = 0;
    scanlines.setRange(target + 1, target + 1 + width * 4, rgba, y * width * 4);
  }
  final ByteData header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final BytesBuilder output = BytesBuilder(copy: false)
    ..add(const <int>[137, 80, 78, 71, 13, 10, 26, 10])
    ..add(_pngChunk('IHDR', header.buffer.asUint8List()))
    ..add(_pngChunk('IDAT', ZLibEncoder().convert(scanlines)))
    ..add(_pngChunk('IEND', const <int>[]));
  return output.takeBytes();
}

Uint8List _pngChunk(String type, List<int> data) {
  final Uint8List typeBytes = Uint8List.fromList(type.codeUnits);
  final ByteData length = ByteData(4)..setUint32(0, data.length);
  final BytesBuilder crcInput = BytesBuilder(copy: false)
    ..add(typeBytes)
    ..add(data);
  final ByteData crc = ByteData(4)..setUint32(0, _crc32(crcInput.takeBytes()));
  return (BytesBuilder(copy: false)
        ..add(length.buffer.asUint8List())
        ..add(typeBytes)
        ..add(data)
        ..add(crc.buffer.asUint8List()))
      .takeBytes();
}

int _readUint32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);

bool _equalBytes(Uint8List bytes, int offset, List<int> expected) {
  for (var index = 0; index < expected.length; index += 1) {
    if (bytes[offset + index] != expected[index]) {
      return false;
    }
  }
  return true;
}

int _paeth(int left, int above, int upperLeft) {
  final int estimate = left + above - upperLeft;
  final int leftDistance = (estimate - left).abs();
  final int aboveDistance = (estimate - above).abs();
  final int upperLeftDistance = (estimate - upperLeft).abs();
  if (leftDistance <= aboveDistance && leftDistance <= upperLeftDistance) {
    return left;
  }
  return aboveDistance <= upperLeftDistance ? above : upperLeft;
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final int byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc.isOdd ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
