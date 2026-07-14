import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../document/document.dart';
import '../document/document_io.dart';
import '../document/tile_store.dart';

/// Number of cards shown on one static gallery page.
const int galleryCardsPerPage = 6;

/// Trash retention required by the gallery contract.
const Duration galleryTrashRetention = Duration(days: 7);

/// Name of the metadata-only tutorial artwork created on first run.
const String galleryStartHereName = 'start here';

/// Gallery-loading state shown by the gallery chrome.
enum GalleryPhase {
  /// No gallery read has been attempted yet.
  uninitialized,

  /// Gallery metadata is currently being loaded or rebuilt.
  loading,

  /// Gallery metadata, including a valid empty gallery, is ready.
  ready,

  /// The latest gallery read failed.
  failed,
}

/// The mutually exclusive dialog or sheet presented over the gallery.
enum GalleryDialog {
  /// Artwork size and creation controls.
  newArtwork,

  /// Rename, duplicate, export, and trash actions for one artwork.
  artworkActions,

  /// Import choices rooted at the documents import folder.
  importArtwork,

  /// Restore and empty-trash actions.
  trash,
}

/// Canonical canvas presets exposed by the new-artwork chooser.
enum GalleryCanvasPreset {
  /// One native portrait screen.
  screen,

  /// Two-times native portrait screen.
  screen2x,

  /// Square 2048-pixel canvas.
  square,

  /// Portrait A5 canvas at approximately 300 dpi.
  a5,

  /// User-stepped dimensions, capped at 4096 square.
  custom,
}

/// Validated canvas size selected in the new-artwork chooser.
final class GalleryArtworkSize {
  /// Creates a preset size or a custom size with explicit dimensions.
  GalleryArtworkSize({
    required this.preset,
    int customWidth = 2048,
    int customHeight = 2048,
    int screenWidth = 954,
    int screenHeight = 1696,
  }) : width = switch (preset) {
         GalleryCanvasPreset.screen => screenWidth,
         GalleryCanvasPreset.screen2x => screenWidth * 2,
         GalleryCanvasPreset.square => 2048,
         GalleryCanvasPreset.a5 => 1748,
         GalleryCanvasPreset.custom => customWidth,
       },
       height = switch (preset) {
         GalleryCanvasPreset.screen => screenHeight,
         GalleryCanvasPreset.screen2x => screenHeight * 2,
         GalleryCanvasPreset.square => 2048,
         GalleryCanvasPreset.a5 => 2480,
         GalleryCanvasPreset.custom => customHeight,
       } {
    if (width <= 0 || width > maxInkCanvasDimension) {
      throw RangeError.range(width, 1, maxInkCanvasDimension, 'width');
    }
    if (height <= 0 || height > maxInkCanvasDimension) {
      throw RangeError.range(height, 1, maxInkCanvasDimension, 'height');
    }
  }

  /// Selected chooser preset.
  final GalleryCanvasPreset preset;

  /// Canvas width in document pixels.
  final int width;

  /// Canvas height in document pixels.
  final int height;

  /// Document canvas metadata represented by this choice.
  CanvasSpec get canvas => CanvasSpec(width: width, height: height);
}

/// One artwork currently in soft-delete storage.
final class GalleryTrashEntry {
  /// Creates restorable trash metadata.
  const GalleryTrashEntry({required this.entry, required this.trashedAtMs});

  /// Artwork metadata recovered from its manifest.
  final GalleryEntry entry;

  /// Time the artwork was moved to trash.
  final int trashedAtMs;
}

/// File category shown by the gallery import chooser.
enum GalleryImportKind {
  /// Portable Ink artwork archive handled by WP8.
  inkpack,

  /// Raster reference or artwork image handled by WP8.
  image,
}

/// One file waiting in `documents/imports/`.
final class GalleryImportCandidate {
  /// Creates an import-row description.
  const GalleryImportCandidate({
    required this.path,
    required this.name,
    required this.kind,
  });

  /// Absolute source path supplied to the injected importer.
  final String path;

  /// User-visible basename.
  final String name;

  /// Archive or image pipeline selection.
  final GalleryImportKind kind;
}

/// Persistence and filesystem actions driven by [GalleryModel].
abstract interface class GalleryOperations {
  /// Runs first-run seeding exactly once.
  Future<void> ensureFirstRunSeed();

  /// Loads artwork cards in persisted order.
  Future<List<GalleryEntry>> loadEntries();

  /// Creates one blank artwork with [size].
  Future<GalleryEntry> createArtwork(GalleryArtworkSize size);

  /// Renames one artwork and returns refreshed metadata.
  Future<GalleryEntry> renameArtwork(String artworkId, String name);

  /// Duplicates one artwork with a fresh id.
  Future<GalleryEntry> duplicateArtwork(String artworkId);

  /// Moves one artwork into soft-delete storage.
  Future<void> moveToTrash(String artworkId);

  /// Loads restorable trash metadata.
  Future<List<GalleryTrashEntry>> loadTrash();

  /// Restores one soft-deleted artwork.
  Future<GalleryEntry> restoreArtwork(String artworkId);

  /// Permanently removes trash at least [maximumAge] old.
  Future<int> collectExpiredTrash(Duration maximumAge);

  /// Lists supported files in `documents/imports/` and exported references.
  Future<List<GalleryImportCandidate>> scanImports();

  /// Sends one candidate through the injected WP8 pipeline.
  Future<GalleryEntry?> importArtwork(GalleryImportCandidate candidate);

  /// Sends one artwork through the injected WP8 export pipeline.
  Future<void> exportArtwork(String artworkId);
}

/// Chrome-facing gallery listing and action state.
///
/// Filesystem behavior is constructor-injected through [GalleryOperations],
/// keeping widgets and tests independent of real file and image work.
final class GalleryModel extends ChangeNotifier {
  /// Creates an unloaded gallery, optionally seeded for fake or test hosts.
  GalleryModel({
    Iterable<GalleryEntry> entries = const <GalleryEntry>[],
    this.operations,
    this.cardsPerPage = galleryCardsPerPage,
  }) : _entries = _validatedEntries(entries) {
    if (cardsPerPage <= 0) {
      throw RangeError.value(cardsPerPage, 'cardsPerPage', 'must be positive');
    }
    if (_entries.isNotEmpty) {
      _phase = GalleryPhase.ready;
    }
  }

  /// Injected persistence actions, absent only for static previews.
  final GalleryOperations? operations;
  List<GalleryEntry> _entries;
  List<GalleryTrashEntry> _trash = const <GalleryTrashEntry>[];
  List<GalleryImportCandidate> _importCandidates =
      const <GalleryImportCandidate>[];
  GalleryPhase _phase = GalleryPhase.uninitialized;
  GalleryDialog? _dialog;
  String? _dialogArtworkId;
  String? _errorMessage;
  String? _actionMessage;
  int _pageIndex = 0;
  bool _trashExpanded = false;
  bool _actionInProgress = false;

  /// Maximum number of new/artwork cards on a page.
  final int cardsPerPage;

  /// Artwork cards in persisted gallery order.
  List<GalleryEntry> get entries => _entries;

  /// Restorable trash rows.
  List<GalleryTrashEntry> get trash => _trash;

  /// Files shown by the current import chooser.
  List<GalleryImportCandidate> get importCandidates => _importCandidates;

  /// Current gallery-loading state.
  GalleryPhase get phase => _phase;

  /// Whether gallery metadata is being read.
  bool get loading => _phase == GalleryPhase.loading;

  /// The currently presented gallery dialog, or null.
  GalleryDialog? get dialog => _dialog;

  /// The artwork targeted by [GalleryDialog.artworkActions], when applicable.
  String? get dialogArtworkId => _dialogArtworkId;

  /// A user-presentable gallery failure, or null outside the failed phase.
  String? get errorMessage => _errorMessage;

  /// Recoverable feedback from the latest CRUD/import/export action.
  String? get actionMessage => _actionMessage;

  /// Whether a gallery action is awaiting its injected operation.
  bool get actionInProgress => _actionInProgress;

  /// Zero-based page selected in the paged artwork grid.
  int get pageIndex => _pageIndex;

  /// Total static pages, including the new-artwork card at index zero.
  int get pageCount => ((_entries.length + 1) / cardsPerPage).ceil();

  /// Whether the gallery trash row is expanded.
  bool get trashExpanded => _trashExpanded;

  /// Loads a complete gallery, seeds first run, and performs seven-day GC.
  Future<void> openGallery() async {
    final GalleryOperations? actions = operations;
    if (actions == null) {
      if (_phase == GalleryPhase.uninitialized) {
        finishLoading(_entries);
      }
      return;
    }
    beginLoading();
    String? maintenanceMessage;
    try {
      await actions.collectExpiredTrash(galleryTrashRetention);
    } on Object {
      maintenanceMessage = 'trash cleanup will retry next time';
    }
    try {
      await actions.ensureFirstRunSeed();
    } on Object {
      maintenanceMessage = 'start-here artwork could not be prepared';
    }
    try {
      final (List<GalleryEntry> entries, List<GalleryTrashEntry> trash) =
          await (actions.loadEntries(), actions.loadTrash()).wait;
      _entries = _validatedEntries(entries);
      _trash = List<GalleryTrashEntry>.unmodifiable(trash);
      _phase = GalleryPhase.ready;
      _errorMessage = null;
      _actionMessage = maintenanceMessage;
      _pageIndex = 0;
      notifyListeners();
    } on Object {
      failLoading('gallery could not be loaded — try again');
    }
  }

  /// Enters the gallery-loading phase.
  void beginLoading() {
    if (_phase == GalleryPhase.loading) {
      return;
    }
    _phase = GalleryPhase.loading;
    _errorMessage = null;
    notifyListeners();
  }

  /// Publishes a successful gallery read, including an empty result.
  void finishLoading(Iterable<GalleryEntry> entries) {
    _entries = _validatedEntries(entries);
    _phase = GalleryPhase.ready;
    _errorMessage = null;
    _pageIndex = 0;
    notifyListeners();
  }

  /// Publishes a recoverable gallery-loading failure.
  void failLoading(String message) {
    if (message.isEmpty) {
      throw ArgumentError.value(message, 'message', 'must not be empty');
    }
    _phase = GalleryPhase.failed;
    _errorMessage = message;
    notifyListeners();
  }

  /// Creates a blank artwork and inserts it at the front of the gallery.
  Future<GalleryEntry?> createArtwork(GalleryArtworkSize size) async {
    final GalleryOperations operations = _requireOperations();
    return _runEntryAction(
      action: () => operations.createArtwork(size),
      successMessage: 'new artwork ready',
      insertAtFront: true,
    );
  }

  /// Renames an artwork after trimming and validating its display name.
  Future<GalleryEntry?> renameArtwork(String artworkId, String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      _actionMessage = 'artwork name cannot be empty';
      notifyListeners();
      return null;
    }
    _requireEntry(artworkId);
    final GalleryOperations operations = _requireOperations();
    return _runEntryAction(
      action: () => operations.renameArtwork(artworkId, trimmed),
      successMessage: 'artwork renamed',
    );
  }

  /// Duplicates an artwork and inserts the copy at the front.
  Future<GalleryEntry?> duplicateArtwork(String artworkId) async {
    _requireEntry(artworkId);
    final GalleryOperations operations = _requireOperations();
    return _runEntryAction(
      action: () => operations.duplicateArtwork(artworkId),
      successMessage: 'artwork duplicated',
      insertAtFront: true,
    );
  }

  /// Moves an artwork to trash after the UI's hold-to-confirm completes.
  Future<bool> trashArtwork(String artworkId) async {
    _requireEntry(artworkId);
    final GalleryOperations operations = _requireOperations();
    _beginAction();
    try {
      await operations.moveToTrash(artworkId);
      _removeEntryWithoutNotification(artworkId);
      _trash = List<GalleryTrashEntry>.unmodifiable(
        await operations.loadTrash(),
      );
      _dialog = null;
      _dialogArtworkId = null;
      _actionMessage = 'moved to trash';
      _finishAction();
      return true;
    } on Object {
      _failAction('could not move artwork to trash');
      return false;
    }
  }

  /// Restores one artwork from trash and inserts it at the front.
  Future<GalleryEntry?> restoreArtwork(String artworkId) async {
    if (!_trash.any((GalleryTrashEntry item) => item.entry.id == artworkId)) {
      throw ArgumentError.value(
        artworkId,
        'artworkId',
        'must identify a trash entry',
      );
    }
    final GalleryOperations operations = _requireOperations();
    _beginAction();
    try {
      final GalleryEntry restored = await operations.restoreArtwork(artworkId);
      _upsertEntryWithoutNotification(restored, insertAtFront: true);
      _trash = List<GalleryTrashEntry>.unmodifiable(
        await operations.loadTrash(),
      );
      _actionMessage = 'artwork restored';
      _finishAction();
      return restored;
    } on Object {
      _failAction('could not restore artwork');
      return null;
    }
  }

  /// Refreshes the import chooser from imports and artwork exports.
  Future<void> scanImports() async {
    final GalleryOperations operations = _requireOperations();
    _beginAction();
    try {
      _importCandidates = List<GalleryImportCandidate>.unmodifiable(
        await operations.scanImports(),
      );
      _actionMessage = null;
      _finishAction();
    } on Object {
      _failAction('could not scan imports and exports');
    }
  }

  /// Imports one scanned file through the injected WP8 pipeline.
  Future<GalleryEntry?> importArtwork(GalleryImportCandidate candidate) async {
    if (!_importCandidates.any(
      (GalleryImportCandidate item) => item.path == candidate.path,
    )) {
      throw ArgumentError.value(
        candidate.path,
        'candidate',
        'must come from the latest import scan',
      );
    }
    final GalleryOperations operations = _requireOperations();
    _beginAction();
    try {
      final GalleryEntry? imported = await operations.importArtwork(candidate);
      if (imported != null) {
        _upsertEntryWithoutNotification(imported, insertAtFront: true);
        _actionMessage = 'imported ${candidate.name}';
      } else {
        _actionMessage = operations is DocumentGalleryOperations
            ? operations.importFailureReason?.call() ??
                  'skipped invalid ${candidate.name}'
            : 'skipped invalid ${candidate.name}';
      }
      _finishAction();
      return imported;
    } on Object {
      _failAction('could not import ${candidate.name}');
      return null;
    }
  }

  /// Exports an artwork through the injected WP8 pipeline.
  Future<bool> exportArtwork(String artworkId) async {
    _requireEntry(artworkId);
    final GalleryOperations operations = _requireOperations();
    _beginAction();
    try {
      await operations.exportArtwork(artworkId);
      _actionMessage = 'export staged in documents/exports';
      _finishAction();
      return true;
    } on Object {
      _failAction('export failed — retry');
      return false;
    }
  }

  Future<GalleryEntry?> _runEntryAction({
    required Future<GalleryEntry> Function() action,
    required String successMessage,
    bool insertAtFront = false,
  }) async {
    _beginAction();
    try {
      final GalleryEntry entry = await action();
      _upsertEntryWithoutNotification(entry, insertAtFront: insertAtFront);
      _dialog = null;
      _dialogArtworkId = null;
      _actionMessage = successMessage;
      _finishAction();
      return entry;
    } on Object {
      _failAction('gallery action failed — retry');
      return null;
    }
  }

  /// Inserts or replaces one gallery cache entry.
  void upsertEntry(GalleryEntry entry, {bool insertAtFront = false}) {
    _upsertEntryWithoutNotification(entry, insertAtFront: insertAtFront);
    _phase = GalleryPhase.ready;
    _errorMessage = null;
    notifyListeners();
  }

  void _upsertEntryWithoutNotification(
    GalleryEntry entry, {
    required bool insertAtFront,
  }) {
    final List<GalleryEntry> next = _entries.toList();
    final int index = next.indexWhere(
      (GalleryEntry candidate) => candidate.id == entry.id,
    );
    if (index >= 0) {
      next.removeAt(index);
    }
    if (insertAtFront || index < 0) {
      next.insert(0, entry);
    } else {
      next.insert(index, entry);
    }
    _entries = _validatedEntries(next);
    _phase = GalleryPhase.ready;
    _errorMessage = null;
    _normalizePage();
  }

  /// Removes one gallery cache entry after a trash or delete action.
  void removeEntry(String artworkId) {
    if (_removeEntryWithoutNotification(artworkId)) {
      notifyListeners();
    }
  }

  bool _removeEntryWithoutNotification(String artworkId) {
    final int index = _entries.indexWhere(
      (GalleryEntry entry) => entry.id == artworkId,
    );
    if (index < 0) {
      return false;
    }
    final List<GalleryEntry> next = _entries.toList()..removeAt(index);
    _entries = List<GalleryEntry>.unmodifiable(next);
    if (_dialogArtworkId == artworkId) {
      _dialog = null;
      _dialogArtworkId = null;
    }
    _normalizePage();
    return true;
  }

  /// Presents one gallery dialog, replacing any previously open dialog.
  void openDialog(GalleryDialog dialog, {String? artworkId}) {
    if (dialog == GalleryDialog.artworkActions) {
      if (artworkId == null ||
          !_entries.any((GalleryEntry entry) => entry.id == artworkId)) {
        throw ArgumentError.value(
          artworkId,
          'artworkId',
          'must identify a gallery entry',
        );
      }
    } else if (artworkId != null) {
      throw ArgumentError.value(
        artworkId,
        'artworkId',
        'is only valid for artwork actions',
      );
    }
    if (_dialog == dialog && _dialogArtworkId == artworkId) {
      return;
    }
    _dialog = dialog;
    _dialogArtworkId = artworkId;
    notifyListeners();
  }

  /// Dismisses the current gallery dialog.
  void closeDialog() {
    if (_dialog == null) {
      return;
    }
    _dialog = null;
    _dialogArtworkId = null;
    notifyListeners();
  }

  /// Selects a zero-based artwork-grid page.
  void setPageIndex(int index) {
    if (index < 0 || index >= pageCount) {
      throw RangeError.range(index, 0, pageCount - 1, 'index');
    }
    if (_pageIndex == index) {
      return;
    }
    _pageIndex = index;
    notifyListeners();
  }

  /// Expands or collapses the trash listing.
  void setTrashExpanded(bool expanded) {
    if (_trashExpanded == expanded) {
      return;
    }
    _trashExpanded = expanded;
    notifyListeners();
  }

  /// Dismisses the latest gallery action feedback.
  void dismissActionMessage() {
    if (_actionMessage == null) {
      return;
    }
    _actionMessage = null;
    notifyListeners();
  }

  GalleryOperations _requireOperations() {
    final GalleryOperations? actions = operations;
    if (actions == null) {
      throw StateError('This GalleryModel has no GalleryOperations.');
    }
    return actions;
  }

  GalleryEntry _requireEntry(String artworkId) {
    return _entries.firstWhere(
      (GalleryEntry entry) => entry.id == artworkId,
      orElse: () => throw ArgumentError.value(
        artworkId,
        'artworkId',
        'must identify a gallery entry',
      ),
    );
  }

  void _beginAction() {
    if (_actionInProgress) {
      throw StateError('A gallery action is already in progress.');
    }
    _actionInProgress = true;
    _actionMessage = null;
    notifyListeners();
  }

  void _finishAction() {
    _actionInProgress = false;
    notifyListeners();
  }

  void _failAction(String message) {
    _actionInProgress = false;
    _actionMessage = message;
    notifyListeners();
  }

  void _normalizePage() {
    if (_pageIndex >= pageCount) {
      _pageIndex = pageCount - 1;
    }
  }
}

/// Real gallery operations built on the landed [DocumentStore].
///
/// Import and export payload work remains constructor-injected because WP8
/// owns archive/image codecs. This adapter still scans the required folders
/// and provides the complete CRUD, trash, first-run, and GC behavior.
final class DocumentGalleryOperations implements GalleryOperations {
  /// Creates production gallery operations.
  DocumentGalleryOperations({
    required this.store,
    required this.documentsRoot,
    required this.nowMilliseconds,
    this.idGenerator,
    this.importer,
    this.importFailureReason,
    this.exporter,
  });

  /// Landed crash-safe document store.
  final DocumentStore store;

  /// Ink documents directory containing state/imports/trash.
  final Directory documentsRoot;

  /// Injectable wall clock.
  final int Function() nowMilliseconds;

  /// Optional deterministic id seam used by tests and fake hosts.
  final String Function()? idGenerator;

  /// Optional WP8 archive/image pipeline.
  final Future<GalleryEntry?> Function(GalleryImportCandidate candidate)?
  importer;

  /// Optional detail from the latest null import result.
  final String? Function()? importFailureReason;

  /// Optional WP8 export pipeline.
  final Future<void> Function(String artworkId)? exporter;
  int _idSequence = 0;

  Directory get _importsDirectory => Directory('${documentsRoot.path}/imports');
  Directory get _exportsDirectory => Directory('${documentsRoot.path}/exports');
  Directory get _trashDirectory => Directory('${documentsRoot.path}/trash');
  File get _firstRunMarker =>
      File('${documentsRoot.path}/state/gallery-initialized');

  @override
  Future<void> ensureFirstRunSeed() async {
    if (_firstRunMarker.existsSync()) {
      return;
    }
    final List<GalleryEntry> entries = await store.loadGallery();
    if (entries.isEmpty) {
      final String id = await _availableStartHereId();
      final int now = nowMilliseconds();
      final InkDocument document =
          InkDocument.blank(
            id: id,
            nowMs: now,
            name: galleryStartHereName,
          ).copyWith(
            canvas: GalleryArtworkSize(
              preset: GalleryCanvasPreset.screen,
            ).canvas,
          );
      await store.saveDocument(document, TileStore());
    }
    await _writeTextAtomically(_firstRunMarker, '1');
  }

  @override
  Future<List<GalleryEntry>> loadEntries() => store.loadGallery();

  @override
  Future<GalleryEntry> createArtwork(GalleryArtworkSize size) async {
    final int now = nowMilliseconds();
    final InkDocument document = InkDocument.blank(
      id: _nextId(),
      nowMs: now,
    ).copyWith(canvas: size.canvas);
    final InkDocument persisted = await store.saveDocument(
      document,
      TileStore(),
    );
    return GalleryEntry.fromDocument(persisted);
  }

  @override
  Future<GalleryEntry> renameArtwork(String artworkId, String name) async {
    final LoadedInkDocument loaded = await _loadRequired(artworkId);
    final InkDocument renamed = loaded.document.copyWith(
      name: name,
      modifiedAtMs: nowMilliseconds(),
    );
    final InkDocument persisted = await store.saveDocument(
      renamed,
      loaded.tiles,
      dirtyTiles: const <TileLocation>[],
    );
    return GalleryEntry.fromDocument(persisted);
  }

  @override
  Future<GalleryEntry> duplicateArtwork(String artworkId) async {
    final LoadedInkDocument loaded = await _loadRequired(artworkId);
    final int now = nowMilliseconds();
    final InkDocument duplicate = loaded.document.copyWith(
      id: _nextId(),
      name: '${loaded.document.name} copy',
      createdAtMs: now,
      modifiedAtMs: now,
      journalHeadSeq: 0,
    );
    final InkDocument persisted = await store.saveDocument(
      duplicate,
      loaded.tiles,
    );
    return GalleryEntry.fromDocument(persisted);
  }

  @override
  Future<void> moveToTrash(String artworkId) async {
    final Directory source = store.artworkDirectory(artworkId);
    if (!source.existsSync()) {
      throw StateError('Artwork $artworkId does not exist.');
    }
    await _trashDirectory.create(recursive: true);
    final Directory destination = Directory(
      '${_trashDirectory.path}/$artworkId',
    );
    if (destination.existsSync()) {
      throw StateError('Trash already contains $artworkId.');
    }
    await source.rename(destination.path);
    await _writeTextAtomically(
      File('${destination.path}/.trashed-at-ms'),
      '${nowMilliseconds()}',
    );
    final List<GalleryEntry> remaining = <GalleryEntry>[
      for (final GalleryEntry entry in await store.loadGallery())
        if (entry.id != artworkId) entry,
    ];
    await store.saveGallery(remaining);
  }

  @override
  Future<List<GalleryTrashEntry>> loadTrash() async {
    if (!_trashDirectory.existsSync()) {
      return const <GalleryTrashEntry>[];
    }
    final List<GalleryTrashEntry> result = <GalleryTrashEntry>[];
    await for (final FileSystemEntity entity in _trashDirectory.list(
      followLinks: false,
    )) {
      if (entity is! Directory) {
        continue;
      }
      final File manifest = File('${entity.path}/manifest.json');
      try {
        final Object? decoded = jsonDecode(await manifest.readAsString());
        if (decoded is! Map<String, Object?>) {
          continue;
        }
        final InkDocument document = InkDocument.fromJson(decoded);
        final String directoryId = entity.uri.pathSegments
            .where((String segment) => segment.isNotEmpty)
            .last;
        if (document.id != directoryId) {
          continue;
        }
        result.add(
          GalleryTrashEntry(
            entry: GalleryEntry.fromDocument(document),
            trashedAtMs: await _trashedAtMilliseconds(entity),
          ),
        );
      } on Object {
        // One broken trash item never prevents the gallery from opening.
      }
    }
    result.sort(
      (GalleryTrashEntry left, GalleryTrashEntry right) =>
          right.trashedAtMs.compareTo(left.trashedAtMs),
    );
    return List<GalleryTrashEntry>.unmodifiable(result);
  }

  @override
  Future<GalleryEntry> restoreArtwork(String artworkId) async {
    final Directory source = Directory('${_trashDirectory.path}/$artworkId');
    final Directory destination = store.artworkDirectory(artworkId);
    if (!source.existsSync()) {
      throw StateError('Trash artwork $artworkId does not exist.');
    }
    if (destination.existsSync()) {
      throw StateError('Artwork $artworkId already exists.');
    }
    await destination.parent.create(recursive: true);
    await source.rename(destination.path);
    final File marker = File('${destination.path}/.trashed-at-ms');
    if (marker.existsSync()) {
      await marker.delete();
    }
    final List<GalleryEntry> entries = await store.loadGallery(
      forceRebuild: true,
    );
    return entries.firstWhere(
      (GalleryEntry entry) => entry.id == artworkId,
      orElse: () => throw StateError('Restored manifest could not be loaded.'),
    );
  }

  @override
  Future<int> collectExpiredTrash(Duration maximumAge) async {
    if (maximumAge <= Duration.zero) {
      throw ArgumentError.value(maximumAge, 'maximumAge', 'must be positive');
    }
    var removed = 0;
    for (final GalleryTrashEntry item in await loadTrash()) {
      if (nowMilliseconds() - item.trashedAtMs < maximumAge.inMilliseconds) {
        continue;
      }
      final Directory directory = Directory(
        '${_trashDirectory.path}/${item.entry.id}',
      );
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
        removed += 1;
      }
    }
    return removed;
  }

  @override
  Future<List<GalleryImportCandidate>> scanImports() async {
    await _importsDirectory.create(recursive: true);
    await _exportsDirectory.create(recursive: true);
    final List<GalleryImportCandidate> result = <GalleryImportCandidate>[];
    for (final Directory directory in <Directory>[
      _importsDirectory,
      _exportsDirectory,
    ]) {
      await for (final FileSystemEntity entity in directory.list(
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        final String name = entity.uri.pathSegments.last;
        final String lower = name.toLowerCase();
        final GalleryImportKind? kind = lower.endsWith('.inkpack')
            ? GalleryImportKind.inkpack
            : lower.endsWith('.png') ||
                  lower.endsWith('.jpg') ||
                  lower.endsWith('.jpeg')
            ? GalleryImportKind.image
            : null;
        if (kind != null) {
          result.add(
            GalleryImportCandidate(path: entity.path, name: name, kind: kind),
          );
        }
      }
    }
    result.sort((GalleryImportCandidate left, GalleryImportCandidate right) {
      final int byName = left.name.toLowerCase().compareTo(
        right.name.toLowerCase(),
      );
      return byName != 0 ? byName : left.path.compareTo(right.path);
    });
    return List<GalleryImportCandidate>.unmodifiable(result);
  }

  @override
  Future<GalleryEntry?> importArtwork(GalleryImportCandidate candidate) async {
    final Future<GalleryEntry?> Function(GalleryImportCandidate candidate)?
    importer = this.importer;
    if (importer == null) {
      throw StateError('The WP8 import pipeline is not connected.');
    }
    return importer(candidate);
  }

  @override
  Future<void> exportArtwork(String artworkId) async {
    final Future<void> Function(String artworkId)? exporter = this.exporter;
    if (exporter == null) {
      throw StateError('The WP8 export pipeline is not connected.');
    }
    await exporter(artworkId);
  }

  Future<LoadedInkDocument> _loadRequired(String artworkId) async {
    final LoadedInkDocument? loaded = await store.openDocument(artworkId);
    if (loaded == null) {
      throw StateError('Artwork $artworkId could not be loaded.');
    }
    await loaded.loadRemaining();
    return loaded;
  }

  String _nextId() =>
      idGenerator?.call() ?? 'ink-${nowMilliseconds()}-${_idSequence++}';

  Future<String> _availableStartHereId() async {
    const String preferred = 'start-here';
    if (!store.artworkDirectory(preferred).existsSync()) {
      return preferred;
    }
    return _nextId();
  }

  Future<int> _trashedAtMilliseconds(Directory directory) async {
    final File marker = File('${directory.path}/.trashed-at-ms');
    if (marker.existsSync()) {
      final int? parsed = int.tryParse((await marker.readAsString()).trim());
      if (parsed != null && parsed >= 0) {
        return parsed;
      }
    }
    return directory.statSync().modified.millisecondsSinceEpoch;
  }
}

Future<void> _writeTextAtomically(File target, String value) async {
  await target.parent.create(recursive: true);
  final File temporary = File('${target.path}.tmp');
  final RandomAccessFile handle = await temporary.open(mode: FileMode.write);
  try {
    await handle.writeString(value);
    await handle.flush();
  } finally {
    await handle.close();
  }
  await temporary.rename(target.path);
}

List<GalleryEntry> _validatedEntries(Iterable<GalleryEntry> entries) {
  final List<GalleryEntry> result = List<GalleryEntry>.of(entries);
  final Set<String> ids = <String>{};
  for (final GalleryEntry entry in result) {
    if (!ids.add(entry.id)) {
      throw ArgumentError.value(entry.id, 'entries', 'contains a duplicate id');
    }
  }
  return List<GalleryEntry>.unmodifiable(result);
}
