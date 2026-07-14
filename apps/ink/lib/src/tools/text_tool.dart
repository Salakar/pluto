import 'dart:math' as math;
import 'dart:ui';

import 'tool.dart';

/// Bundled typeface choices for text blocks.
enum TextFontFamily {
  /// Proportional Inter variable font.
  inter('Inter'),

  /// Monospaced JetBrains Mono font.
  jetBrainsMono('JetBrains Mono');

  const TextFontFamily(this.familyName);

  /// Flutter font-family name.
  final String familyName;
}

/// Supported text weights, deliberately excluding light e-ink-hostile forms.
enum InkTextWeight {
  /// Medium, the minimum body weight.
  medium(500),

  /// Semibold.
  semiBold(600),

  /// Bold.
  bold(700),

  /// Extra bold.
  extraBold(800);

  const InkTextWeight(this.value);

  /// Numeric font weight recorded in journal metadata.
  final int value;
}

/// Four pen-resize handles around an editable text block.
enum TextResizeHandle {
  /// Upper-left corner.
  topLeft,

  /// Upper-right corner.
  topRight,

  /// Lower-left corner.
  bottomLeft,

  /// Lower-right corner.
  bottomRight,
}

/// Immutable text formatting captured when a block is placed.
final class TextOptions {
  /// Creates validated text options.
  factory TextOptions({
    TextFontFamily fontFamily = TextFontFamily.inter,
    double size = 32,
    InkTextWeight weight = InkTextWeight.semiBold,
    int colorArgb = 0xff000000,
  }) {
    if (!size.isFinite || size < 16 || size > 96) {
      throw RangeError.range(size, 16, 96, 'size');
    }
    if (colorArgb < 0 || colorArgb > 0xffffffff) {
      throw RangeError.range(colorArgb, 0, 0xffffffff, 'colorArgb');
    }
    return TextOptions._(
      fontFamily: fontFamily,
      size: size,
      weight: weight,
      colorArgb: colorArgb,
    );
  }

  const TextOptions._({
    required this.fontFamily,
    required this.size,
    required this.weight,
    required this.colorArgb,
  });

  /// Inter or JetBrains Mono.
  final TextFontFamily fontFamily;

  /// Text size in the binding 16–96 document-pixel range.
  final double size;

  /// Weight in the binding w500–w800 set.
  final InkTextWeight weight;

  /// Current drawing color captured at placement.
  final int colorArgb;

  /// Returns a validated copy with selected values replaced.
  TextOptions copyWith({
    TextFontFamily? fontFamily,
    double? size,
    InkTextWeight? weight,
    int? colorArgb,
  }) => TextOptions(
    fontFamily: fontFamily ?? this.fontFamily,
    size: size ?? this.size,
    weight: weight ?? this.weight,
    colorArgb: colorArgb ?? this.colorArgb,
  );
}

/// Mutable-session value represented immutably between controller actions.
final class TextBlockDraft {
  /// Creates a validated text draft.
  TextBlockDraft({
    required this.text,
    required this.bounds,
    required this.options,
    this.autoPanOffset = Offset.zero,
  }) {
    _requireUsableRect(bounds, 'bounds');
    _requireFiniteOffset(autoPanOffset, 'autoPanOffset');
  }

  /// Current keyboard text.
  final String text;

  /// Editable block bounds in document space.
  final Rect bounds;

  /// Font, size, weight, and current color.
  final TextOptions options;

  /// Viewport-only translation requested to avoid keyboard occlusion.
  final Offset autoPanOffset;

  /// Returns a validated draft with selected fields replaced.
  TextBlockDraft copyWith({
    String? text,
    Rect? bounds,
    TextOptions? options,
    Offset? autoPanOffset,
  }) => TextBlockDraft(
    text: text ?? this.text,
    bounds: bounds ?? this.bounds,
    options: options ?? this.options,
    autoPanOffset: autoPanOffset ?? this.autoPanOffset,
  );
}

/// Typed vector metadata retained with a rasterized text journal entry.
final class TextJournalMetadata {
  /// Creates metadata from an editable block.
  const TextJournalMetadata({
    required this.text,
    required this.bounds,
    required this.fontFamily,
    required this.size,
    required this.weight,
    required this.colorArgb,
  });

  /// Decodes durable journal metadata for undo-driven re-editing.
  factory TextJournalMetadata.fromJson(Map<String, Object?> json) {
    final Object? rawBounds = json['bounds'];
    if (rawBounds is! List<Object?> ||
        rawBounds.length != 4 ||
        rawBounds.any((Object? value) => value is! num)) {
      throw const FormatException(
        'Text metadata bounds must contain four numbers.',
      );
    }
    final Object? rawText = json['text'];
    final Object? rawFamily = json['fontFamily'];
    final Object? rawSize = json['size'];
    final Object? rawWeight = json['weight'];
    final Object? rawColor = json['colorArgb'];
    if (rawText is! String || rawText.isEmpty) {
      throw const FormatException('Text metadata text must not be empty.');
    }
    final TextFontFamily? family = TextFontFamily.values
        .where((TextFontFamily value) => value.familyName == rawFamily)
        .firstOrNull;
    final InkTextWeight? weight = InkTextWeight.values
        .where((InkTextWeight value) => value.value == rawWeight)
        .firstOrNull;
    if (family == null ||
        weight == null ||
        rawSize is! num ||
        rawColor is! int) {
      throw const FormatException('Text metadata options are invalid.');
    }
    final TextOptions options = TextOptions(
      fontFamily: family,
      size: rawSize.toDouble(),
      weight: weight,
      colorArgb: rawColor,
    );
    final Rect bounds = Rect.fromLTWH(
      (rawBounds[0]! as num).toDouble(),
      (rawBounds[1]! as num).toDouble(),
      (rawBounds[2]! as num).toDouble(),
      (rawBounds[3]! as num).toDouble(),
    );
    _requireUsableRect(bounds, 'bounds');
    return TextJournalMetadata(
      text: rawText,
      bounds: bounds,
      fontFamily: options.fontFamily,
      size: options.size,
      weight: options.weight,
      colorArgb: options.colorArgb,
    );
  }

  /// Committed text.
  final String text;

  /// Document-space block bounds.
  final Rect bounds;

  /// Bundled font family.
  final TextFontFamily fontFamily;

  /// Document-pixel font size.
  final double size;

  /// Numeric w500–w800 weight.
  final InkTextWeight weight;

  /// Captured current ARGB color.
  final int colorArgb;

  /// JSON-shaped value suitable for the journal recipe metadata field.
  Map<String, Object> toJson() => <String, Object>{
    'text': text,
    'bounds': <double>[bounds.left, bounds.top, bounds.width, bounds.height],
    'fontFamily': fontFamily.familyName,
    'size': size,
    'weight': weight.value,
    'colorArgb': colorArgb,
  };
}

/// Final rasterization request for one text block.
final class TextCommitCommand implements JournaledToolCommand {
  /// Creates a layer-local text commit.
  TextCommitCommand({required this.layerId, required TextBlockDraft draft})
    : metadata = TextJournalMetadata(
        text: draft.text,
        bounds: draft.bounds,
        fontFamily: draft.options.fontFamily,
        size: draft.options.size,
        weight: draft.options.weight,
        colorArgb: draft.options.colorArgb,
      ) {
    if (layerId.isEmpty) {
      throw ArgumentError.value(layerId, 'layerId', 'must not be empty');
    }
    if (draft.text.isEmpty) {
      throw ArgumentError.value(draft.text, 'draft.text', 'must not be empty');
    }
  }

  /// Active content layer receiving rasterized glyphs.
  final String layerId;

  /// Re-editable vector metadata retained by the journal.
  final TextJournalMetadata metadata;

  /// Text is rasterized only at commit.
  bool get rasterizeAtCommit => true;

  @override
  JournalKind get journalKind => JournalKind.text;
}

/// Calculates the static canvas pan needed to expose [blockInViewport].
Offset textKeyboardAutoPan({
  required Rect blockInViewport,
  required Rect viewportBounds,
  required double keyboardTop,
  double margin = 16,
}) {
  _requireUsableRect(blockInViewport, 'blockInViewport');
  _requireUsableRect(viewportBounds, 'viewportBounds');
  if (!keyboardTop.isFinite || !margin.isFinite || margin < 0) {
    throw ArgumentError.value(
      (keyboardTop, margin),
      'keyboard geometry',
      'must be finite with a non-negative margin',
    );
  }
  final double visibleBottom = math.min(viewportBounds.bottom, keyboardTop);
  final double overlap = blockInViewport.bottom + margin - visibleBottom;
  if (overlap <= 0) {
    return Offset.zero;
  }
  final double requestedDy = -overlap;
  final double topLimit = viewportBounds.top + margin - blockInViewport.top;
  return Offset(0, math.max(requestedDy, topLimit));
}

/// Synchronous block-placement, editing, and keyboard-auto-pan controller.
final class TextToolController extends ToolController<TextToolKind> {
  /// Creates a text controller.
  TextToolController({TextOptions? options})
    : _options = options ?? TextOptions(),
      super(const TextToolKind());

  TextOptions _options;
  TextBlockDraft? _draft;
  TextCommitCommand? _lastCommit;

  /// Current text dock options.
  TextOptions get options => _options;

  /// Editable block shown above the PaperKeyboard sheet.
  TextBlockDraft? get draft => _draft;

  /// Most recent command, retained so undo can restore editability.
  TextCommitCommand? get lastCommit => _lastCommit;

  @override
  bool get hasLiveState => _draft != null;

  /// Replaces options used by the next placement or current draft.
  void setOptions(TextOptions value, {bool applyToDraft = true}) {
    _options = value;
    if (applyToDraft && _draft != null) {
      _draft = _draft!.copyWith(options: value);
    }
  }

  /// Places an empty text block and opens the keyboard-driven edit state.
  TextBlockDraft place({
    required Offset point,
    double width = 240,
    double? height,
  }) {
    _requireFiniteOffset(point, 'point');
    final double resolvedHeight = height ?? _options.size * 1.5;
    if (!width.isFinite ||
        width <= 0 ||
        !resolvedHeight.isFinite ||
        resolvedHeight <= 0) {
      throw ArgumentError.value(
        (width, resolvedHeight),
        'block size',
        'must be finite and positive',
      );
    }
    final TextBlockDraft result = TextBlockDraft(
      text: '',
      bounds: Rect.fromLTWH(point.dx, point.dy, width, resolvedHeight),
      options: _options,
    );
    _draft = result;
    return result;
  }

  /// Replaces preview text from the synchronous PaperKeyboard callback.
  TextBlockDraft updateText(String text) {
    final TextBlockDraft current = _requireDraft();
    final TextBlockDraft next = current.copyWith(text: text);
    _draft = next;
    return next;
  }

  /// Drags the editable block in document space.
  TextBlockDraft dragBy(Offset delta) {
    _requireFiniteOffset(delta, 'delta');
    final TextBlockDraft current = _requireDraft();
    final TextBlockDraft next = current.copyWith(
      bounds: current.bounds.shift(delta),
    );
    _draft = next;
    return next;
  }

  /// Resizes from one corner while enforcing usable minimum dimensions.
  TextBlockDraft resize(TextResizeHandle handle, Offset pointer) {
    _requireFiniteOffset(pointer, 'pointer');
    final TextBlockDraft current = _requireDraft();
    final Rect source = current.bounds;
    final double minimumWidth = math.max(64, current.options.size * 2);
    final double minimumHeight = math.max(32, current.options.size * 1.25);
    var left = source.left;
    var top = source.top;
    var right = source.right;
    var bottom = source.bottom;
    switch (handle) {
      case TextResizeHandle.topLeft:
        left = math.min(pointer.dx, right - minimumWidth);
        top = math.min(pointer.dy, bottom - minimumHeight);
      case TextResizeHandle.topRight:
        right = math.max(pointer.dx, left + minimumWidth);
        top = math.min(pointer.dy, bottom - minimumHeight);
      case TextResizeHandle.bottomLeft:
        left = math.min(pointer.dx, right - minimumWidth);
        bottom = math.max(pointer.dy, top + minimumHeight);
      case TextResizeHandle.bottomRight:
        right = math.max(pointer.dx, left + minimumWidth);
        bottom = math.max(pointer.dy, top + minimumHeight);
    }
    final TextBlockDraft next = current.copyWith(
      bounds: Rect.fromLTRB(left, top, right, bottom),
    );
    _draft = next;
    return next;
  }

  /// Records the viewport pan required to keep the block above the keyboard.
  Offset autoPanForKeyboard({
    required Rect blockInViewport,
    required Rect viewportBounds,
    required double keyboardTop,
    double margin = 16,
  }) {
    final Offset pan = textKeyboardAutoPan(
      blockInViewport: blockInViewport,
      viewportBounds: viewportBounds,
      keyboardTop: keyboardTop,
      margin: margin,
    );
    _draft = _requireDraft().copyWith(autoPanOffset: pan);
    return pan;
  }

  /// Commits rasterization and retains metadata for one-step undo editing.
  TextCommitCommand commit({required String activeLayerId}) {
    final TextCommitCommand command = TextCommitCommand(
      layerId: activeLayerId,
      draft: _requireDraft(),
    );
    _lastCommit = command;
    _draft = null;
    return command;
  }

  /// Restores the most recent committed block after undo.
  bool restoreLastCommitForEditing() {
    final TextCommitCommand? command = _lastCommit;
    if (command == null) {
      return false;
    }
    restoreMetadataForEditing(command.metadata);
    return true;
  }

  /// Restores one durable journal block as the current editable draft.
  void restoreMetadataForEditing(TextJournalMetadata metadata) {
    _draft = TextBlockDraft(
      text: metadata.text,
      bounds: metadata.bounds,
      options: TextOptions(
        fontFamily: metadata.fontFamily,
        size: metadata.size,
        weight: metadata.weight,
        colorArgb: metadata.colorArgb,
      ),
    );
    _options = _draft!.options;
  }

  /// Canonical feedback when tapping text that has already dried.
  String get dryBlockTapMessage => 'text is dry — undo to edit last block';

  TextBlockDraft _requireDraft() {
    final TextBlockDraft? current = _draft;
    if (current == null) {
      throw StateError('No text block is being edited.');
    }
    return current;
  }

  @override
  void cancel() {
    _draft = null;
  }
}

void _requireFiniteOffset(Offset value, String name) {
  if (!value.dx.isFinite || !value.dy.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}

void _requireUsableRect(Rect value, String name) {
  if (!value.left.isFinite ||
      !value.top.isFinite ||
      !value.right.isFinite ||
      !value.bottom.isFinite ||
      value.isEmpty) {
    throw ArgumentError.value(value, name, 'must be finite and non-empty');
  }
}
