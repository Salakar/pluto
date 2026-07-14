import 'package:flutter/foundation.dart';

import 'editor_model.dart';
import 'gallery_model.dart';

/// Top-level pages in Ink's deliberately shallow navigation model.
enum InkPage {
  /// The paged artwork gallery.
  gallery,

  /// The full-bleed editor for one open artwork.
  editor,

  /// Application settings.
  settings,
}

/// Session-level page routing and ownership links for Ink.
///
/// Nested models notify their targeted chrome directly. Their notifications
/// are intentionally not forwarded through this model, and canvas repainting
/// never travels through any application model.
final class InkAppModel extends ChangeNotifier {
  /// Creates an Ink session rooted at the gallery.
  InkAppModel({GalleryModel? gallery})
    : gallery = gallery ?? GalleryModel(),
      _ownsGallery = gallery == null;

  /// Gallery listing and dialog state.
  final GalleryModel gallery;

  final bool _ownsGallery;
  InkPage _page = InkPage.gallery;
  InkPage _settingsReturnPage = InkPage.gallery;
  EditorModel? _editor;

  /// The page currently presented by the app shell.
  InkPage get page => _page;

  /// State for the open artwork, or null when no artwork is open.
  EditorModel? get editor => _editor;

  /// Whether an artwork remains open in this session.
  bool get hasOpenArtwork => _editor != null;

  /// Opens an artwork and routes directly to its editor.
  ///
  /// The caller retains disposal responsibility for injected editor models.
  void openEditor(EditorModel editor) {
    if (identical(_editor, editor) && _page == InkPage.editor) {
      return;
    }
    _editor = editor;
    _page = InkPage.editor;
    notifyListeners();
  }

  /// Routes to the gallery while retaining any open editor state.
  void showGallery() {
    if (_page == InkPage.gallery) {
      return;
    }
    _page = InkPage.gallery;
    notifyListeners();
  }

  /// Closes the current artwork and routes to the gallery.
  ///
  /// The detached model is returned so its owner may dispose it after any
  /// outstanding save or worker shutdown has completed.
  EditorModel? closeEditor() {
    if (_editor == null && _page == InkPage.gallery) {
      return null;
    }
    final detached = _editor;
    _editor = null;
    _page = InkPage.gallery;
    if (_settingsReturnPage == InkPage.editor) {
      _settingsReturnPage = InkPage.gallery;
    }
    notifyListeners();
    return detached;
  }

  /// Presents settings and remembers the page that should receive Back.
  void showSettings() {
    if (_page == InkPage.settings) {
      return;
    }
    _settingsReturnPage = _page;
    _page = InkPage.settings;
    notifyListeners();
  }

  /// Returns from settings to the previous valid page.
  void closeSettings() {
    if (_page != InkPage.settings) {
      return;
    }
    _page = _settingsReturnPage == InkPage.editor && _editor == null
        ? InkPage.gallery
        : _settingsReturnPage;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_ownsGallery) {
      gallery.dispose();
    }
    super.dispose();
  }
}
