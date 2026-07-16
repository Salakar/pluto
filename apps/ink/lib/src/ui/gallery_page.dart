import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../document/document_io.dart';
import '../model/gallery_model.dart';
import 'responsive_layout.dart';

/// Optional thumbnail seam supplied by WP8 or a deterministic golden scene.
typedef GalleryThumbnailBuilder =
    Widget Function(BuildContext context, GalleryEntry entry);

/// Builds real artwork thumbnails rooted at [artworksDirectory].
///
/// Missing, pending, or corrupt PNGs retain the deterministic decode-free
/// card drawing so gallery layout never shifts while image work completes.
GalleryThumbnailBuilder buildFileGalleryThumbnail({
  required Directory artworksDirectory,
}) =>
    (BuildContext context, GalleryEntry entry) => _FileArtworkThumbnail(
      entry: entry,
      file: File('${artworksDirectory.path}/${entry.id}/thumb.png'),
    );

/// Paged paper-brutalist artwork gallery.
final class GalleryPage extends StatefulWidget {
  /// Creates a gallery connected to [model].
  const GalleryPage({
    required this.model,
    required this.onOpenArtwork,
    required this.onSettings,
    this.onImportReference,
    this.onExit,
    this.thumbnailBuilder,
    this.autoLoad = true,
    this.deleteHoldDuration = const Duration(seconds: 3),
    super.key,
  });

  /// Gallery state and persistence actions.
  final GalleryModel model;

  /// Opens an existing or newly created artwork in the editor.
  final ValueChanged<String> onOpenArtwork;

  /// Routes to global settings.
  final VoidCallback onSettings;

  /// Opens a scanned image in an artwork's reference placement flow.
  final ValueChanged<GalleryImportCandidate>? onImportReference;

  /// Optional gallery-only exit-to-launcher action.
  final VoidCallback? onExit;

  /// Optional real thumbnail builder. The default is a decode-free drawing.
  final GalleryThumbnailBuilder? thumbnailBuilder;

  /// Whether an uninitialized model should open itself during init.
  final bool autoLoad;

  /// Production is three seconds; tests may inject a shorter deterministic hold.
  final Duration deleteHoldDuration;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

final class _GalleryPageState extends State<GalleryPage> {
  @override
  void initState() {
    super.initState();
    _loadIfNeeded();
  }

  @override
  void didUpdateWidget(GalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.model, oldWidget.model)) {
      _loadIfNeeded();
    }
  }

  void _loadIfNeeded() {
    if (widget.autoLoad && widget.model.phase == GalleryPhase.uninitialized) {
      unawaited(widget.model.openGallery());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (BuildContext context, Widget? child) {
        return PaperScaffold(
          showStatusBar: false,
          header: _GalleryHeader(
            onSettings: widget.onSettings,
            onImport: widget.model.actionInProgress ? null : _showImport,
            onExit: widget.onExit,
          ),
          body: Column(
            children: <Widget>[
              if (widget.model.actionMessage != null)
                _GalleryNote(
                  message: widget.model.actionMessage!,
                  onDismiss: widget.model.dismissActionMessage,
                ),
              Expanded(child: _buildBody()),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    return switch (widget.model.phase) {
      GalleryPhase.uninitialized ||
      GalleryPhase.loading => const PaperLoadingState(label: 'opening gallery'),
      GalleryPhase.failed => PaperErrorState(
        title: 'gallery unavailable',
        message: widget.model.errorMessage ?? 'gallery could not be loaded',
        action: PaperButton(
          label: 'try again',
          onPressed: () => unawaited(widget.model.openGallery()),
        ),
      ),
      GalleryPhase.ready => _GalleryReadyBody(
        model: widget.model,
        thumbnailBuilder: widget.thumbnailBuilder,
        onNewArtwork: _showNewArtwork,
        onOpenArtwork: widget.onOpenArtwork,
        onArtworkActions: _showArtworkActions,
      ),
    };
  }

  Future<void> _showNewArtwork() async {
    widget.model.openDialog(GalleryDialog.newArtwork);
    final GalleryArtworkSize? size =
        await PaperDialogs.showSheet<GalleryArtworkSize>(
          context,
          builder: (BuildContext sheetContext) => NewArtworkChooser(
            onCancel: () => Navigator.of(sheetContext).pop(),
            onCreate: (GalleryArtworkSize choice) =>
                Navigator.of(sheetContext).pop(choice),
          ),
        );
    widget.model.closeDialog();
    if (size == null || !mounted) {
      return;
    }
    final GalleryEntry? created = await widget.model.createArtwork(size);
    if (created != null && mounted) {
      widget.onOpenArtwork(created.id);
    }
  }

  Future<void> _showArtworkActions(GalleryEntry entry) async {
    widget.model.openDialog(GalleryDialog.artworkActions, artworkId: entry.id);
    final _ArtworkAction? action = await PaperDialogs.showSheet<_ArtworkAction>(
      context,
      builder: (BuildContext sheetContext) => _ArtworkActionsSheet(
        entry: entry,
        deleteHoldDuration: widget.deleteHoldDuration,
        onSelected: (_ArtworkAction selected) =>
            Navigator.of(sheetContext).pop(selected),
        onCancel: () => Navigator.of(sheetContext).pop(),
      ),
    );
    widget.model.closeDialog();
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case _ArtworkAction.rename:
        await _showRename(entry);
      case _ArtworkAction.duplicate:
        await widget.model.duplicateArtwork(entry.id);
      case _ArtworkAction.export:
        await widget.model.exportArtwork(entry.id);
      case _ArtworkAction.delete:
        await widget.model.trashArtwork(entry.id);
    }
  }

  Future<void> _showRename(GalleryEntry entry) async {
    final String? nextName = await PaperDialogs.showSheet<String>(
      context,
      builder: (BuildContext sheetContext) => _RenameArtworkSheet(
        initialName: entry.name,
        onCancel: () => Navigator.of(sheetContext).pop(),
        onSubmit: (String name) => Navigator.of(sheetContext).pop(name),
      ),
    );
    if (nextName != null && mounted) {
      await widget.model.renameArtwork(entry.id, nextName);
    }
  }

  Future<void> _showImport() async {
    widget.model.openDialog(GalleryDialog.importArtwork);
    await widget.model.scanImports();
    if (!mounted) {
      return;
    }
    final GalleryImportCandidate? candidate =
        await PaperDialogs.showSheet<GalleryImportCandidate>(
          context,
          builder: (BuildContext sheetContext) => _ImportArtworkSheet(
            candidates: widget.model.importCandidates,
            onCancel: () => Navigator.of(sheetContext).pop(),
            onSelected: (GalleryImportCandidate selected) =>
                Navigator.of(sheetContext).pop(selected),
          ),
        );
    widget.model.closeDialog();
    if (candidate != null && mounted) {
      final ValueChanged<GalleryImportCandidate>? referenceImport =
          widget.onImportReference;
      if (candidate.kind == GalleryImportKind.image &&
          referenceImport != null) {
        referenceImport(candidate);
      } else {
        await widget.model.importArtwork(candidate);
      }
    }
  }
}

final class _GalleryHeader extends StatelessWidget {
  const _GalleryHeader({
    required this.onSettings,
    required this.onImport,
    required this.onExit,
  });

  final VoidCallback onSettings;
  final VoidCallback? onImport;
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final _GalleryScale scale = _GalleryScale.of(context);
    return SizedBox(
      height: math.max(PaperSpacing.touchTargetMin, scale.u(88)),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: scale.u(32)),
        child: Row(
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: theme.palette.ink,
                  width: PaperSpacing.heavyRule,
                ),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: scale.u(16),
                  vertical: scale.u(4),
                ),
                child: Text('Ink', style: theme.type.title),
              ),
            ),
            const Spacer(),
            if (onExit != null)
              PaperButton.ghost(
                key: const ValueKey<String>('gallery-exit'),
                label: 'exit',
                onPressed: onExit,
              ),
            PaperButton.ghost(
              key: const ValueKey<String>('gallery-import'),
              label: 'import',
              onPressed: onImport,
            ),
            PaperButton.ghost(
              key: const ValueKey<String>('gallery-settings'),
              label: 'settings',
              onPressed: onSettings,
            ),
          ],
        ),
      ),
    );
  }
}

final class _GalleryReadyBody extends StatelessWidget {
  const _GalleryReadyBody({
    required this.model,
    required this.thumbnailBuilder,
    required this.onNewArtwork,
    required this.onOpenArtwork,
    required this.onArtworkActions,
  });

  final GalleryModel model;
  final GalleryThumbnailBuilder? thumbnailBuilder;
  final VoidCallback onNewArtwork;
  final ValueChanged<String> onOpenArtwork;
  final ValueChanged<GalleryEntry> onArtworkActions;

  @override
  Widget build(BuildContext context) {
    if (model.entries.isEmpty) {
      return Column(
        children: <Widget>[
          Expanded(
            child: PaperEmptyState(
              title: 'the easel is empty',
              message: 'make a new artwork or import one from USB',
              icon: const SizedBox.square(
                dimension: 88,
                child: CustomPaint(painter: _EmptyEaselPainter()),
              ),
              extra: PaperButton.primary(
                label: 'new artwork',
                onPressed: onNewArtwork,
              ),
            ),
          ),
          _TrashSection(model: model),
        ],
      );
    }

    final _GalleryScale scale = _GalleryScale.of(context);
    final int first = model.pageIndex * model.cardsPerPage;
    final int last = math.min(
      model.entries.length + 1,
      first + model.cardsPerPage,
    );
    return Column(
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final int columns = _galleryColumnCount(
                constraints.biggest,
                scale: scale.value,
              );
              return GridView.builder(
                key: ValueKey<String>('gallery-page-${model.pageIndex}'),
                padding: EdgeInsets.all(scale.u(32)),
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: scale.u(16),
                  crossAxisSpacing: scale.u(16),
                  childAspectRatio: columns >= 3 ? 1.35 : 437 / 300,
                ),
                itemCount: last - first,
                itemBuilder: (BuildContext context, int localIndex) {
                  final int combinedIndex = first + localIndex;
                  if (combinedIndex == 0) {
                    return _NewArtworkCard(onTap: onNewArtwork);
                  }
                  final GalleryEntry entry = model.entries[combinedIndex - 1];
                  return _ArtworkCard(
                    key: ValueKey<String>('artwork-${entry.id}'),
                    entry: entry,
                    thumbnailBuilder: thumbnailBuilder,
                    onTap: () => onOpenArtwork(entry.id),
                    onLongPress: () => onArtworkActions(entry),
                  );
                },
              );
            },
          ),
        ),
        if (model.pageCount > 1)
          _GalleryPager(
            pageIndex: model.pageIndex,
            pageCount: model.pageCount,
            onPage: model.setPageIndex,
          ),
        _TrashSection(model: model),
      ],
    );
  }
}

final class _NewArtworkCard extends StatelessWidget {
  const _NewArtworkCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      button: true,
      label: 'new artwork',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: CustomPaint(
          painter: _DashedFramePainter(color: theme.palette.ink),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('+', style: theme.type.display),
                const SizedBox(height: PaperSpacing.space8),
                Text('new artwork', style: theme.type.label),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ArtworkCard extends StatefulWidget {
  const _ArtworkCard({
    required this.entry,
    required this.thumbnailBuilder,
    required this.onTap,
    required this.onLongPress,
    super.key,
  });

  final GalleryEntry entry;
  final GalleryThumbnailBuilder? thumbnailBuilder;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_ArtworkCard> createState() => _ArtworkCardState();
}

final class _ArtworkCardState extends State<_ArtworkCard> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) {
      return;
    }
    setState(() {
      _pressed = pressed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Color background = _pressed ? theme.palette.ink : theme.palette.paper;
    final Color foreground = _pressed ? theme.palette.paper : theme.palette.ink;
    final Color secondary = _pressed
        ? theme.palette.paper
        : theme.palette.gray33;
    return Semantics(
      button: true,
      label:
          '${widget.entry.name}, ${formatGalleryModifiedDate(widget.entry.modifiedAtMs)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) {
          _setPressed(false);
          widget.onTap();
        },
        onLongPress: () {
          _setPressed(false);
          widget.onLongPress();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            border: Border.all(
              color: theme.palette.ink,
              width: PaperSpacing.rule,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.all(PaperSpacing.space8),
                  child:
                      widget.thumbnailBuilder?.call(context, widget.entry) ??
                      _DefaultArtworkThumbnail(entry: widget.entry),
                ),
              ),
              ColoredBox(
                color: foreground,
                child: const SizedBox(height: PaperSpacing.rule),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PaperSpacing.space12,
                    vertical: PaperSpacing.space4,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          widget.entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.label.copyWith(color: foreground),
                        ),
                      ),
                      const SizedBox(width: PaperSpacing.space8),
                      Text(
                        formatGalleryModifiedDate(widget.entry.modifiedAtMs),
                        style: theme.type.caption.copyWith(color: secondary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _DefaultArtworkThumbnail extends StatelessWidget {
  const _DefaultArtworkThumbnail({required this.entry});

  final GalleryEntry entry;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.grayDD,
      child: CustomPaint(
        painter: _DefaultThumbnailPainter(
          seed: entry.id.hashCode,
          ink: theme.palette.ink,
          paper: theme.palette.paper,
        ),
      ),
    );
  }
}

final class _FileArtworkThumbnail extends StatefulWidget {
  const _FileArtworkThumbnail({required this.entry, required this.file});

  final GalleryEntry entry;
  final File file;

  @override
  State<_FileArtworkThumbnail> createState() => _FileArtworkThumbnailState();
}

final class _FileArtworkThumbnailState extends State<_FileArtworkThumbnail> {
  String? _imageRevision;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Widget fallback = _DefaultArtworkThumbnail(entry: widget.entry);
    final FileStat stat;
    try {
      stat = widget.file.statSync();
    } on FileSystemException {
      _evictReplacedImage(null);
      return fallback;
    }
    if (stat.type != FileSystemEntityType.file) {
      _evictReplacedImage(null);
      return fallback;
    }
    final String revision =
        '${widget.entry.modifiedAtMs}:${stat.modified.microsecondsSinceEpoch}:'
        '${stat.changed.microsecondsSinceEpoch}:${stat.size}';
    _evictReplacedImage(revision);
    return ColoredBox(
      color: theme.palette.paper,
      child: Center(
        child: Image.file(
          widget.file,
          key: ValueKey<String>(
            'gallery-thumbnail-${widget.entry.id}-$revision',
          ),
          fit: BoxFit.contain,
          alignment: Alignment.center,
          filterQuality: FilterQuality.none,
          gaplessPlayback: true,
          frameBuilder:
              (
                BuildContext context,
                Widget child,
                int? frame,
                bool wasSynchronouslyLoaded,
              ) => frame == null ? fallback : child,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stackTrace) =>
                  fallback,
        ),
      ),
    );
  }

  void _evictReplacedImage(String? revision) {
    if (_imageRevision != revision && revision != null) {
      PaintingBinding.instance.imageCache.evict(FileImage(widget.file));
    }
    _imageRevision = revision;
  }
}

/// Formats gallery metadata without a locale package dependency.
String formatGalleryModifiedDate(int millisecondsSinceEpoch) {
  final DateTime date = DateTime.fromMillisecondsSinceEpoch(
    millisecondsSinceEpoch,
  );
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

final class _GalleryPager extends StatelessWidget {
  const _GalleryPager({
    required this.pageIndex,
    required this.pageCount,
    required this.onPage,
  });

  final int pageIndex;
  final int pageCount;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PaperSpacing.space8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (var index = 0; index < pageCount; index += 1) ...<Widget>[
            if (index > 0) const SizedBox(width: PaperSpacing.space8),
            PaperButton(
              key: ValueKey<String>('gallery-page-${index + 1}-button'),
              label: '${index + 1}',
              onPressed: index == pageIndex ? null : () => onPage(index),
              variant: index == pageIndex
                  ? PaperButtonVariant.primary
                  : PaperButtonVariant.secondary,
              minWidth: PaperSpacing.touchTargetMin,
            ),
          ],
        ],
      ),
    );
  }
}

final class _TrashSection extends StatelessWidget {
  const _TrashSection({required this.model});

  final GalleryModel model;

  @override
  Widget build(BuildContext context) {
    if (model.trash.isEmpty) {
      return const SizedBox.shrink();
    }
    final PaperThemeData theme = PaperTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.palette.paper,
        border: Border(
          top: BorderSide(color: theme.palette.ink, width: PaperSpacing.rule),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          PaperListItem(
            key: const ValueKey<String>('trash-toggle'),
            title:
                'trash (${model.trash.length}) ${model.trashExpanded ? '▾' : '▸'}',
            subtitle: 'empties after 7 days',
            onTap: () => model.setTrashExpanded(!model.trashExpanded),
          ),
          if (model.trashExpanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: Column(
                  children: <Widget>[
                    for (final GalleryTrashEntry item in model.trash)
                      PaperListItem(
                        key: ValueKey<String>('trash-${item.entry.id}'),
                        title: item.entry.name,
                        subtitle:
                            'trashed ${formatGalleryModifiedDate(item.trashedAtMs)}',
                        trailing: PaperButton(
                          label: 'restore',
                          onPressed: model.actionInProgress
                              ? null
                              : () => unawaited(
                                  model.restoreArtwork(item.entry.id),
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Size chooser for the gallery's new-artwork card.
final class NewArtworkChooser extends StatefulWidget {
  /// Creates the chooser.
  const NewArtworkChooser({
    required this.onCancel,
    required this.onCreate,
    super.key,
  });

  /// Dismisses without creating.
  final VoidCallback onCancel;

  /// Commits one validated size.
  final ValueChanged<GalleryArtworkSize> onCreate;

  @override
  State<NewArtworkChooser> createState() => _NewArtworkChooserState();
}

final class _NewArtworkChooserState extends State<NewArtworkChooser> {
  GalleryCanvasPreset _preset = GalleryCanvasPreset.screen2x;
  int _customWidth = 2048;
  int _customHeight = 2048;

  void _stepWidth(int delta) {
    setState(() {
      _customWidth = (_customWidth + delta).clamp(256, 4096);
    });
  }

  void _stepHeight(int delta) {
    setState(() {
      _customHeight = (_customHeight + delta).clamp(256, 4096);
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Size physicalViewport = inkPhysicalViewportOf(context);
    final int screenWidth = physicalViewport.width.round();
    final int screenHeight = physicalViewport.height.round();
    return ColoredBox(
      color: theme.palette.paper,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(PaperSpacing.space20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('new artwork', style: theme.type.heading),
              const SizedBox(height: PaperSpacing.space12),
              Wrap(
                spacing: PaperSpacing.space8,
                runSpacing: PaperSpacing.space8,
                children: <Widget>[
                  for (final GalleryCanvasPreset preset
                      in GalleryCanvasPreset.values)
                    _SizePresetButton(
                      preset: preset,
                      selected: preset == _preset,
                      screenWidth: screenWidth,
                      screenHeight: screenHeight,
                      onTap: () => setState(() {
                        _preset = preset;
                      }),
                    ),
                ],
              ),
              if (_preset == GalleryCanvasPreset.custom) ...<Widget>[
                const SizedBox(height: PaperSpacing.space12),
                _DimensionStepper(
                  label: 'width',
                  value: _customWidth,
                  onDecrease: () => _stepWidth(-256),
                  onIncrease: () => _stepWidth(256),
                ),
                const SizedBox(height: PaperSpacing.space8),
                _DimensionStepper(
                  label: 'height',
                  value: _customHeight,
                  onDecrease: () => _stepHeight(-256),
                  onIncrease: () => _stepHeight(256),
                ),
              ],
              const SizedBox(height: PaperSpacing.space20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: PaperButton(
                      label: 'cancel',
                      onPressed: widget.onCancel,
                    ),
                  ),
                  const SizedBox(width: PaperSpacing.space12),
                  Expanded(
                    child: PaperButton.primary(
                      label: 'create',
                      onPressed: () => widget.onCreate(
                        GalleryArtworkSize(
                          preset: _preset,
                          customWidth: _customWidth,
                          customHeight: _customHeight,
                          screenWidth: screenWidth,
                          screenHeight: screenHeight,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SizePresetButton extends StatelessWidget {
  const _SizePresetButton({
    required this.preset,
    required this.selected,
    required this.screenWidth,
    required this.screenHeight,
    required this.onTap,
  });

  final GalleryCanvasPreset preset;
  final bool selected;
  final int screenWidth;
  final int screenHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final GalleryArtworkSize? size = preset == GalleryCanvasPreset.custom
        ? null
        : GalleryArtworkSize(
            preset: preset,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
          );
    final String label = switch (preset) {
      GalleryCanvasPreset.screen => 'screen',
      GalleryCanvasPreset.screen2x => 'screen ×2',
      GalleryCanvasPreset.square => 'square',
      GalleryCanvasPreset.a5 => 'A5',
      GalleryCanvasPreset.custom => 'custom',
    };
    return PaperButton(
      key: ValueKey<String>('size-${preset.name}'),
      label: size == null ? label : '$label\n${size.width}×${size.height}',
      onPressed: onTap,
      variant: selected
          ? PaperButtonVariant.primary
          : PaperButtonVariant.secondary,
      minWidth: 140,
    );
  }
}

final class _DimensionStepper extends StatelessWidget {
  const _DimensionStepper({
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
  });

  final String label;
  final int value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Row(
      children: <Widget>[
        SizedBox(width: 80, child: Text(label, style: theme.type.body)),
        PaperButton(
          key: ValueKey<String>('$label-decrease'),
          label: '−',
          onPressed: value <= 256 ? null : onDecrease,
          minWidth: PaperSpacing.touchTargetMin,
        ),
        Expanded(
          child: Text(
            '$value px',
            textAlign: TextAlign.center,
            style: theme.type.mono,
          ),
        ),
        PaperButton(
          key: ValueKey<String>('$label-increase'),
          label: '+',
          onPressed: value >= 4096 ? null : onIncrease,
          minWidth: PaperSpacing.touchTargetMin,
        ),
      ],
    );
  }
}

enum _ArtworkAction { rename, duplicate, export, delete }

final class _ArtworkActionsSheet extends StatelessWidget {
  const _ArtworkActionsSheet({
    required this.entry,
    required this.deleteHoldDuration,
    required this.onSelected,
    required this.onCancel,
  });

  final GalleryEntry entry;
  final Duration deleteHoldDuration;
  final ValueChanged<_ArtworkAction> onSelected;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.paper,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(PaperSpacing.space20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(entry.name, style: theme.type.heading),
              const SizedBox(height: PaperSpacing.space12),
              PaperButton(
                label: 'rename',
                onPressed: () => onSelected(_ArtworkAction.rename),
              ),
              const SizedBox(height: PaperSpacing.space8),
              PaperButton(
                label: 'duplicate',
                onPressed: () => onSelected(_ArtworkAction.duplicate),
              ),
              const SizedBox(height: PaperSpacing.space8),
              PaperButton(
                label: 'export',
                onPressed: () => onSelected(_ArtworkAction.export),
              ),
              const SizedBox(height: PaperSpacing.space12),
              _GalleryDeleteHoldButton(
                key: const ValueKey<String>('delete-hold'),
                label: 'hold to move to trash',
                holdDuration: deleteHoldDuration,
                onConfirmed: () => onSelected(_ArtworkAction.delete),
              ),
              const SizedBox(height: PaperSpacing.space8),
              PaperButton.ghost(label: 'cancel', onPressed: onCancel),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gallery-local destructive hold that measures from physical contact.
///
/// The shared button deliberately routes through tap recognition. Deletion is
/// stricter: its three-second interval starts at pointer down and is cancelled
/// as soon as that same pointer leaves or lifts.
final class _GalleryDeleteHoldButton extends StatefulWidget {
  const _GalleryDeleteHoldButton({
    required this.label,
    required this.holdDuration,
    required this.onConfirmed,
    super.key,
  });

  final String label;
  final Duration holdDuration;
  final VoidCallback onConfirmed;

  @override
  State<_GalleryDeleteHoldButton> createState() =>
      _GalleryDeleteHoldButtonState();
}

final class _GalleryDeleteHoldButtonState
    extends State<_GalleryDeleteHoldButton> {
  static const int _segmentCount = 6;

  Timer? _timer;
  int? _activePointer;
  int _filledSegments = 0;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start(PointerDownEvent event) {
    if (_activePointer != null) {
      return;
    }
    _activePointer = event.pointer;
    _timer?.cancel();
    setState(() => _filledSegments = 0);
    final int stepMicroseconds = math.max(
      1,
      widget.holdDuration.inMicroseconds ~/ _segmentCount,
    );
    _timer = Timer.periodic(Duration(microseconds: stepMicroseconds), (
      Timer timer,
    ) {
      if (!mounted || _activePointer == null) {
        timer.cancel();
        return;
      }
      setState(() {
        _filledSegments = math.min(_segmentCount, _filledSegments + 1);
      });
      EinkRefreshRegion.request(
        context,
        refreshClass: RefreshClass.fast,
        reason: 'gallery.delete.hold',
      );
      if (_filledSegments == _segmentCount) {
        timer.cancel();
        _activePointer = null;
        widget.onConfirmed();
      }
    });
  }

  void _move(PointerMoveEvent event) {
    final Size? size = context.size;
    if (_activePointer == event.pointer &&
        size != null &&
        !(Offset.zero & size).contains(event.localPosition)) {
      _stop(event);
    }
  }

  void _stop(PointerEvent event) {
    if (_activePointer != event.pointer) {
      return;
    }
    _activePointer = null;
    _timer?.cancel();
    if (_filledSegments == 0) {
      return;
    }
    setState(() => _filledSegments = 0);
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final TextStyle labelStyle = theme.type.label.copyWith(
      color: theme.palette.accentRed,
    );
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _start,
        onPointerMove: _move,
        onPointerUp: _stop,
        onPointerCancel: _stop,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.palette.paper,
            border: Border.all(
              color: theme.palette.ink,
              width: PaperSpacing.rule,
            ),
          ),
          child: SizedBox(
            height: 64,
            child: Column(
              children: <Widget>[
                Expanded(
                  child: Center(child: Text(widget.label, style: labelStyle)),
                ),
                SizedBox(
                  height: PaperSpacing.space8,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (var index = 0; index < _segmentCount; index += 1)
                        Expanded(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: index < _filledSegments
                                  ? theme.palette.ink
                                  : theme.palette.paper,
                              border: index == 0
                                  ? null
                                  : Border(
                                      left: BorderSide(
                                        color: theme.palette.ink,
                                        width: PaperSpacing.hairline,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _RenameArtworkSheet extends StatefulWidget {
  const _RenameArtworkSheet({
    required this.initialName,
    required this.onCancel,
    required this.onSubmit,
  });

  final String initialName;
  final VoidCallback onCancel;
  final ValueChanged<String> onSubmit;

  @override
  State<_RenameArtworkSheet> createState() => _RenameArtworkSheetState();
}

final class _RenameArtworkSheetState extends State<_RenameArtworkSheet> {
  late String _name = widget.initialName;

  void _insert(String text) {
    if (_name.length >= 80) {
      return;
    }
    setState(() {
      _name = '$_name$text';
    });
  }

  void _backspace() {
    if (_name.isEmpty) {
      return;
    }
    setState(() {
      _name = _name.substring(0, _name.length - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.paper,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(PaperSpacing.space16),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _name.isEmpty ? 'name your artwork' : _name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.heading.copyWith(
                        color: _name.isEmpty
                            ? theme.palette.gray66
                            : theme.palette.ink,
                      ),
                    ),
                  ),
                  PaperButton.ghost(
                    label: 'cancel',
                    onPressed: widget.onCancel,
                  ),
                ],
              ),
            ),
            PaperKeyboard(
              onText: _insert,
              onBackspace: _backspace,
              onSubmit: _name.trim().isEmpty
                  ? () {}
                  : () => widget.onSubmit(_name.trim()),
              submitLabel: 'Done',
            ),
          ],
        ),
      ),
    );
  }
}

final class _ImportArtworkSheet extends StatelessWidget {
  const _ImportArtworkSheet({
    required this.candidates,
    required this.onCancel,
    required this.onSelected,
  });

  final List<GalleryImportCandidate> candidates;
  final VoidCallback onCancel;
  final ValueChanged<GalleryImportCandidate> onSelected;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.paper,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(PaperSpacing.space20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Text('import', style: theme.type.heading)),
                  PaperButton.ghost(label: 'cancel', onPressed: onCancel),
                ],
              ),
              const SizedBox(height: PaperSpacing.space12),
              if (candidates.isEmpty)
                Text(
                  'drop images or .inkpack files into documents/imports over USB',
                  style: theme.type.body,
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: SingleChildScrollView(
                    child: Column(
                      children: <Widget>[
                        for (final GalleryImportCandidate candidate
                            in candidates)
                          PaperListItem(
                            key: ValueKey<String>('import-${candidate.name}'),
                            title: candidate.name,
                            subtitle:
                                candidate.kind == GalleryImportKind.inkpack
                                ? 'Ink artwork archive'
                                : 'reference image',
                            onTap: () => onSelected(candidate),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _GalleryNote extends StatelessWidget {
  const _GalleryNote({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(
              color: theme.palette.ink,
              width: PaperSpacing.rule,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PaperSpacing.pageMargin,
            vertical: PaperSpacing.space8,
          ),
          child: Text('$message · tap to dismiss', style: theme.type.caption),
        ),
      ),
    );
  }
}

final class _DashedFramePainter extends CustomPainter {
  const _DashedFramePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule;
    const double dash = 10;
    const double gap = 7;
    for (double x = 0; x < size.width; x += dash + gap) {
      canvas.drawLine(
        Offset(x, 1),
        Offset(math.min(x + dash, size.width), 1),
        paint,
      );
      canvas.drawLine(
        Offset(x, size.height - 1),
        Offset(math.min(x + dash, size.width), size.height - 1),
        paint,
      );
    }
    for (double y = 0; y < size.height; y += dash + gap) {
      canvas.drawLine(
        Offset(1, y),
        Offset(1, math.min(y + dash, size.height)),
        paint,
      );
      canvas.drawLine(
        Offset(size.width - 1, y),
        Offset(size.width - 1, math.min(y + dash, size.height)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedFramePainter oldDelegate) =>
      color != oldDelegate.color;
}

final class _DefaultThumbnailPainter extends CustomPainter {
  const _DefaultThumbnailPainter({
    required this.seed,
    required this.ink,
    required this.paper,
  });

  final int seed;
  final Color ink;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final double paperHeight = size.height * 0.88;
    final double paperWidth = math.min(size.width * 0.72, paperHeight * 0.5625);
    final Rect sheet = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: paperWidth,
      height: paperHeight,
    );
    canvas.drawRect(sheet, Paint()..color = paper);
    final Paint stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, size.shortestSide / 90)
      ..strokeCap = StrokeCap.square;
    final double wobble = ((seed & 0xff) / 255 - 0.5) * sheet.width * 0.12;
    final Path path = Path()
      ..moveTo(
        sheet.left + sheet.width * 0.16,
        sheet.bottom - sheet.height * 0.2,
      )
      ..cubicTo(
        sheet.left + sheet.width * 0.3,
        sheet.top + sheet.height * 0.3,
        sheet.left + sheet.width * 0.58 + wobble,
        sheet.bottom - sheet.height * 0.26,
        sheet.right - sheet.width * 0.12,
        sheet.top + sheet.height * 0.22,
      );
    canvas.drawPath(path, stroke);
    canvas.drawRect(
      Rect.fromLTWH(
        sheet.left + sheet.width * 0.16,
        sheet.top + sheet.height * 0.15,
        sheet.width * 0.36,
        sheet.height * 0.08,
      ),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_DefaultThumbnailPainter oldDelegate) =>
      seed != oldDelegate.seed ||
      ink != oldDelegate.ink ||
      paper != oldDelegate.paper;
}

final class _EmptyEaselPainter extends CustomPainter {
  const _EmptyEaselPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = const Color(0xff000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.miter;
    final Rect frame = Rect.fromLTWH(
      size.width * 0.2,
      size.height * 0.12,
      size.width * 0.6,
      size.height * 0.52,
    );
    canvas.drawRect(frame, paint);
    canvas.drawLine(
      Offset(size.width * 0.5, frame.bottom),
      Offset(size.width * 0.28, size.height * 0.92),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.5, frame.bottom),
      Offset(size.width * 0.72, size.height * 0.92),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.18, size.height * 0.72),
      Offset(size.width * 0.82, size.height * 0.72),
      paint,
    );
  }

  @override
  bool shouldRepaint(_EmptyEaselPainter oldDelegate) => false;
}

final class _GalleryScale {
  const _GalleryScale(this.value);

  factory _GalleryScale.of(BuildContext context) {
    return _GalleryScale(inkViewportFitScaleOf(context));
  }

  final double value;

  double u(double designPixels) => designPixels * value;
}

int _galleryColumnCount(Size available, {required double scale}) {
  if (!available.width.isFinite || !available.height.isFinite) {
    return 2;
  }
  final double safeScale = scale > 0 && scale.isFinite ? scale : 1;
  final double authoredWidth = available.width / safeScale;
  if (authoredWidth < 800) {
    return 1;
  }
  final double aspect = available.height <= 0
      ? 0
      : available.width / available.height;
  return authoredWidth >= 1150 && aspect >= 0.7 ? 3 : 2;
}
