/// Refresh quality classes shared by apps, packages, and the embedder.
enum RefreshClass {
  /// Lowest-latency monochrome updates for ink and tiny rects.
  fast,

  /// General interface updates such as chrome and menus.
  ui,

  /// Settled regional updates for readable text.
  text,

  /// Whole-region cleanup updates that may visibly flash.
  full,
}
