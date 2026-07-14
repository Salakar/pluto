import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../document/export.dart';
import '../document/document_io.dart';
import '../model/app_model.dart';
import '../model/gallery_model.dart';
import '../model/settings_model.dart';
import '../model/tool_state.dart';
import '../services.dart';
import '../tools/reference_tool.dart';
import 'bench/bench.dart';
import 'editor_page.dart';
import 'gallery_page.dart';
import 'settings_page.dart';

/// Loads Ink's external service bundle at process start.
typedef InkAppServicesLoader = Future<InkServices> Function();

/// Runtime application root that loads gallery/settings before first settle.
final class InkApp extends StatefulWidget {
  /// Creates Ink with optional deterministic service injection.
  const InkApp({this.services, this.servicesLoader, super.key});

  /// Already-created services for tests and host previews.
  final InkServices? services;

  /// Asynchronous production service seam.
  final InkAppServicesLoader? servicesLoader;

  @override
  State<InkApp> createState() => _InkAppState();
}

final class _InkAppState extends State<InkApp> {
  late Future<_InkRuntime> _runtime;
  _InkRuntime? _resolved;

  @override
  void initState() {
    super.initState();
    _runtime = _openRuntime();
  }

  @override
  void didUpdateWidget(InkApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.services != widget.services ||
        oldWidget.servicesLoader != widget.servicesLoader) {
      _resolved?.dispose();
      _resolved = null;
      _runtime = _openRuntime();
    }
  }

  Future<_InkRuntime> _openRuntime() async {
    final InkServices services =
        widget.services ??
        await (widget.servicesLoader ?? InkServices.createReal)();
    var idSequence = 0;
    String nextId() =>
        'ink-${services.clock.nowMilliseconds()}-${idSequence++}';
    final InkDocumentTransferService transfers = InkDocumentTransferService(
      store: services.store,
      exportsDirectory: services.paths.exports,
      nowMilliseconds: services.clock.nowMilliseconds,
      idGenerator: nextId,
    );
    String? importFailureReason;
    final DocumentGalleryOperations operations = DocumentGalleryOperations(
      store: services.store,
      documentsRoot: services.paths.root,
      nowMilliseconds: services.clock.nowMilliseconds,
      idGenerator: nextId,
      importer: (GalleryImportCandidate candidate) async {
        if (candidate.kind == GalleryImportKind.image) {
          importFailureReason =
              'open an artwork to place ${candidate.name} as a reference';
          return null;
        }
        importFailureReason = null;
        final GalleryEntry? entry = await transfers.importInkpack(
          File(candidate.path),
        );
        importFailureReason = transfers.lastImportFailureReason;
        return entry;
      },
      importFailureReason: () =>
          importFailureReason ?? transfers.lastImportFailureReason,
      exporter: (String artworkId) async {
        await transfers.exportOrThrow(
          artworkId: artworkId,
          kind: InkExportKind.png1x,
        );
      },
    );
    final GalleryModel gallery = GalleryModel(operations: operations);
    final InkSettingsModel settings = InkSettingsModel(
      store: JsonFileInkSettingsStore(documentsRoot: services.paths.root),
    );
    final InkAppModel model = InkAppModel(gallery: gallery);
    final _InkRuntime runtime = _InkRuntime(
      services: services,
      model: model,
      settings: settings,
      transfers: transfers,
    );
    await (gallery.openGallery(), settings.load()).wait;
    if (!mounted) {
      runtime.dispose();
      throw StateError('Ink runtime was disposed while opening.');
    }
    _resolved = runtime;
    if (!services.isFake) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted || !identical(_resolved, runtime)) {
          return;
        }
        unawaited(
          transfers.regenerateStaleThumbnails(
            gallery.entries,
            onRegenerated: (GalleryEntry entry) {
              if (mounted &&
                  identical(_resolved, runtime) &&
                  gallery.entries.any(
                    (GalleryEntry current) => current.id == entry.id,
                  )) {
                gallery.upsertEntry(entry);
              }
            },
          ),
        );
      });
    }
    return runtime;
  }

  @override
  void dispose() {
    _resolved?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_InkRuntime>(
      future: _runtime,
      builder: (BuildContext context, AsyncSnapshot<_InkRuntime> snapshot) {
        final _InkRuntime? runtime = snapshot.data;
        if (runtime == null) {
          return _InkBootstrapApp(error: snapshot.error);
        }
        return InkAppForModel(
          services: runtime.services,
          model: runtime.model,
          settings: runtime.settings,
          transfers: runtime.transfers,
        );
      },
    );
  }
}

/// Bare WidgetsApp around externally owned models for tests and goldens.
final class InkAppForModel extends StatefulWidget {
  /// Creates an application shell around prepared state.
  const InkAppForModel({
    required this.services,
    required this.model,
    required this.settings,
    this.transfers,
    this.showBootSweep = true,
    super.key,
  });

  /// Injected device, persistence, pen, and system services.
  final InkServices services;

  /// Session page and editor owner.
  final InkAppModel model;

  /// Global persisted settings owner.
  final InkSettingsModel settings;

  /// Shared import/export and thumbnail service.
  final InkDocumentTransferService? transfers;

  /// Whether this cold root performs the one-shot low-delta sweep.
  final bool showBootSweep;

  @override
  State<InkAppForModel> createState() => _InkAppForModelState();
}

final class _InkAppForModelState extends State<InkAppForModel> {
  InkEditorSession? _editorSession;
  Timer? _bootSweepTimer;
  bool _bootSweep = false;
  bool _openingArtwork = false;
  late InkDocumentTransferService _transfers;
  GalleryImportCandidate? _pendingReferenceImport;
  final Map<String, ReferenceToolController> _referenceControllers =
      <String, ReferenceToolController>{};

  @override
  void initState() {
    super.initState();
    _transfers = _resolveTransfers();
    _startBootSweep();
  }

  @override
  void didUpdateWidget(InkAppForModel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, widget.model)) {
      unawaited(_editorSession?.dispose());
      _editorSession = null;
      _referenceControllers.clear();
    }
    if (oldWidget.transfers != widget.transfers ||
        !identical(oldWidget.services, widget.services)) {
      _transfers = _resolveTransfers();
      if (!identical(oldWidget.services, widget.services)) {
        _referenceControllers.clear();
      }
    }
  }

  void _startBootSweep() {
    if (!widget.showBootSweep) {
      return;
    }
    _bootSweep = true;
    _bootSweepTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) {
        return;
      }
      setState(() => _bootSweep = false);
      EinkRefreshRegion.request(
        context,
        refreshClass: RefreshClass.text,
        reason: 'boot.sweep',
      );
    });
  }

  @override
  void dispose() {
    _bootSweepTimer?.cancel();
    unawaited(_editorSession?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PaperTheme(
      data: PaperThemeData(
        isColorPanel: widget.services.display.presenterDrivesColor,
      ),
      child: WidgetsApp(
        color: const Color(0xffffffff),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PaperPageRoute<T>(builder: builder, settings: settings),
        home: ListenableBuilder(
          listenable: widget.model,
          builder: (BuildContext context, Widget? child) {
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _page(),
                if (_openingArtwork)
                  const ColoredBox(
                    color: Color(0xe6ffffff),
                    child: Center(
                      child: PaperLoadingState(label: 'opening artwork'),
                    ),
                  ),
                if (_bootSweep)
                  const IgnorePointer(
                    child: ColoredBox(color: Color(0x1e000000)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _page() => switch (widget.model.page) {
    InkPage.gallery => GalleryPage(
      model: widget.model.gallery,
      autoLoad: false,
      onOpenArtwork: (String id) => unawaited(_openArtwork(id)),
      onSettings: widget.model.showSettings,
      onImportReference: (GalleryImportCandidate candidate) =>
          unawaited(_openReferenceImport(candidate)),
      onExit: () => unawaited(widget.services.system.exitToLauncher()),
      thumbnailBuilder: buildFileGalleryThumbnail(
        artworksDirectory: widget.services.paths.artworks,
      ),
    ),
    InkPage.editor =>
      _editorSession == null
          ? const ColoredBox(
              color: Color(0xffffffff),
              child: Center(child: PaperLoadingState(label: 'opening artwork')),
            )
          : EditorPage(
              session: _editorSession,
              benchDock: _benchDock(widget.settings.settings.benchDock),
              onBenchDockChanged: (InkBenchDock dock) {
                unawaited(widget.settings.setBenchDock(_dockPreference(dock)));
              },
              onBack: _closeArtwork,
              onOpenSettings: widget.model.showSettings,
              transfers: _transfers,
              initialReferenceImport: _pendingReferenceImport,
              referenceController: _referenceControllers.putIfAbsent(
                _editorSession!.model.document.id,
                ReferenceToolController.new,
              ),
            ),
    InkPage.settings => SettingsPage(
      model: widget.settings,
      autoLoad: false,
      onBack: _closeSettings,
      onDeepClean: widget.services.system.requestFullRefresh,
    ),
  };

  void _closeSettings() {
    final InkEditorSession? session = _editorSession;
    if (session != null) {
      _applySettings(session.model.toolState);
    }
    widget.model.closeSettings();
  }

  Future<void> _openArtwork(String id) async {
    if (_openingArtwork) {
      return;
    }
    setState(() => _openingArtwork = true);
    try {
      final InkEditorSession session = await openInkEditorSession(
        widget.services,
        artworkId: id,
      );
      _applySettings(session.model.toolState);
      final InkEditorSession? previous = _editorSession;
      _editorSession = session;
      widget.model.openEditor(session.model);
      if (previous != null) {
        await previous.dispose();
      }
    } finally {
      if (mounted) {
        setState(() => _openingArtwork = false);
      }
    }
  }

  Future<void> _openReferenceImport(GalleryImportCandidate candidate) async {
    GalleryEntry? target = widget.model.gallery.entries.isEmpty
        ? null
        : widget.model.gallery.entries.first;
    target ??= await widget.model.gallery.createArtwork(
      GalleryArtworkSize(preset: GalleryCanvasPreset.screen),
    );
    if (target == null || !mounted) {
      return;
    }
    _pendingReferenceImport = candidate;
    await _openArtwork(target.id);
  }

  Future<void> _closeArtwork() async {
    final InkEditorSession? session = _editorSession;
    final String? artworkId = session?.model.document.id;
    _editorSession = null;
    _pendingReferenceImport = null;
    widget.model.closeEditor();
    if (session != null) {
      await session.dispose();
    }
    if (artworkId != null) {
      try {
        await _transfers.regenerateThumbnail(artworkId);
      } on Object {
        // A thumbnail failure must not strand navigation in the editor.
      }
    }
    await widget.model.gallery.openGallery();
  }

  void _applySettings(ToolState tools) {
    final InkSettings settings = widget.settings.settings;
    tools.setFingerDrawEnabled(settings.fingerDrawing);
    final Wp5ToolOptions options = tools.wp5Options.copyWith(
      gridStyle: !settings.gridEnabled
          ? GuideGridStyle.off
          : switch (settings.gridStyle) {
              GridStylePreference.dot => GuideGridStyle.dots,
              GridStylePreference.line => GuideGridStyle.lines,
            },
      gridSpacingDpx: settings.gridSpacing,
    );
    tools.setWp5Options(options);
    tools.setBrushPreset('wp7PressureCurve', settings.pressureCurve.name);
    tools.setBrushPreset('wp7EraserDefault', settings.eraserDefault.name);
  }

  InkDocumentTransferService _resolveTransfers() =>
      widget.transfers ??
      InkDocumentTransferService(
        store: widget.services.store,
        exportsDirectory: widget.services.paths.exports,
        nowMilliseconds: widget.services.clock.nowMilliseconds,
      );
}

final class _InkRuntime {
  _InkRuntime({
    required this.services,
    required this.model,
    required this.settings,
    required this.transfers,
  });

  final InkServices services;
  final InkAppModel model;
  final InkSettingsModel settings;
  final InkDocumentTransferService transfers;

  void dispose() {
    model.dispose();
    model.gallery.dispose();
    settings.dispose();
  }
}

final class _InkBootstrapApp extends StatelessWidget {
  const _InkBootstrapApp({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: WidgetsApp(
        color: const Color(0xffffffff),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PaperPageRoute<T>(builder: builder, settings: settings),
        home: ColoredBox(
          color: const Color(0xffffffff),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Ink',
                  style: const PaperThemeData(isColorPanel: true).type.display,
                ),
                const SizedBox(height: PaperSpacing.space12),
                Text(
                  error == null ? 'opening gallery…' : 'gallery unavailable',
                  style: const PaperThemeData(isColorPanel: true).type.body,
                ),
                const SizedBox(height: PaperSpacing.space12),
                PaperButton.ghost(
                  label: 'exit',
                  onPressed: () => unawaited(SystemNavigator.pop()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

InkBenchDock _benchDock(BenchDockPreference preference) => switch (preference) {
  BenchDockPreference.left => InkBenchDock.left,
  BenchDockPreference.right => InkBenchDock.right,
  BenchDockPreference.top => InkBenchDock.top,
};

BenchDockPreference _dockPreference(InkBenchDock dock) => switch (dock) {
  InkBenchDock.left => BenchDockPreference.left,
  InkBenchDock.right => BenchDockPreference.right,
  InkBenchDock.top => BenchDockPreference.top,
};
