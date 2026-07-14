import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'tool.dart';

/// Default opacity for a newly imported reference layer.
const double referenceLayerOpacity = 0.5;

/// Maximum number of layers in the separate reference stack.
const int maximumReferenceLayers = 2;

/// Largest decoded reference-image edge accepted by Ink.
const int maximumReferenceDecodeDimension = 4096;

/// Integer pixel dimensions selected for a bounded reference decode.
final class ReferenceDecodeSize {
  /// Creates validated decoded-image dimensions.
  ReferenceDecodeSize({required this.width, required this.height}) {
    _requireReferenceDimension(width, 'width');
    _requireReferenceDimension(height, 'height');
  }

  /// Decoded pixel width.
  final int width;

  /// Decoded pixel height.
  final int height;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReferenceDecodeSize &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'ReferenceDecodeSize($width, $height)';
}

/// Fits encoded-image dimensions inside the current canvas without upscaling.
///
/// Both maximum dimensions must be between one and
/// [maximumReferenceDecodeDimension]. The returned integer dimensions preserve
/// the source aspect ratio subject to downward pixel rounding.
ReferenceDecodeSize cappedReferenceDecodeSize({
  required int intrinsicWidth,
  required int intrinsicHeight,
  required int maxWidth,
  required int maxHeight,
}) {
  if (intrinsicWidth <= 0) {
    throw ArgumentError.value(
      intrinsicWidth,
      'intrinsicWidth',
      'must be positive',
    );
  }
  if (intrinsicHeight <= 0) {
    throw ArgumentError.value(
      intrinsicHeight,
      'intrinsicHeight',
      'must be positive',
    );
  }
  _requireReferenceDimension(maxWidth, 'maxWidth');
  _requireReferenceDimension(maxHeight, 'maxHeight');
  if (intrinsicWidth <= maxWidth && intrinsicHeight <= maxHeight) {
    return ReferenceDecodeSize(width: intrinsicWidth, height: intrinsicHeight);
  }
  final double scale = math.min(
    maxWidth / intrinsicWidth,
    maxHeight / intrinsicHeight,
  );
  return ReferenceDecodeSize(
    width: math.max(1, (intrinsicWidth * scale).floor()),
    height: math.max(1, (intrinsicHeight * scale).floor()),
  );
}

/// Successfully decoded, bounded reference pixels and their placement metadata.
final class ReferenceDecode {
  /// Creates a validated immutable RGBA8888 reference payload by copying it.
  ReferenceDecode({required this.descriptor, required Uint8List rgbaBytes})
    : rgbaBytes = Uint8List.fromList(rgbaBytes).asUnmodifiableView() {
    _validateRgbaBytes();
  }

  /// Creates a payload without copying [rgbaBytes] and takes its ownership.
  ///
  /// The caller must relinquish every mutable alias to [rgbaBytes] after this
  /// call. The exposed view is unmodifiable, but Dart cannot revoke aliases
  /// retained by the caller. Prefer the default constructor at API boundaries.
  ReferenceDecode.takeOwnership({
    required this.descriptor,
    required Uint8List rgbaBytes,
  }) : rgbaBytes = rgbaBytes.asUnmodifiableView() {
    _validateRgbaBytes();
  }

  void _validateRgbaBytes() {
    _requireReferenceDimension(descriptor.pixelWidth, 'descriptor.pixelWidth');
    _requireReferenceDimension(
      descriptor.pixelHeight,
      'descriptor.pixelHeight',
    );
    final int expectedLength =
        descriptor.pixelWidth * descriptor.pixelHeight * 4;
    if (rgbaBytes.lengthInBytes != expectedLength) {
      throw ArgumentError.value(
        rgbaBytes.lengthInBytes,
        'rgbaBytes.lengthInBytes',
        'must contain $expectedLength RGBA8888 bytes',
      );
    }
  }

  /// Metadata consumed by [ReferenceToolController.addReference].
  final ReferenceImageDescriptor descriptor;

  /// Immutable row-major RGBA8888 pixels.
  final Uint8List rgbaBytes;
}

/// Why a requested reference image could not be decoded.
enum ReferenceDecodeFailureKind {
  /// The file name or encoded signature is not PNG or JPEG syntax.
  unsupportedFormat,

  /// Encoded bytes, image metadata, or decoded pixels were invalid.
  corruptImage,
}

/// Typed result returned by [ReferenceImageDecoder.decode].
sealed class ReferenceDecodeResult {
  const ReferenceDecodeResult();
}

/// Successful bounded reference decode.
final class ReferenceDecodeSuccess extends ReferenceDecodeResult {
  /// Creates a successful result.
  const ReferenceDecodeSuccess(this.decode);

  /// Immutable decoded reference payload.
  final ReferenceDecode decode;
}

/// Non-throwing unsupported or corrupt reference result.
final class ReferenceDecodeFailure extends ReferenceDecodeResult {
  /// Creates a presentable decode failure.
  ReferenceDecodeFailure({required this.kind, required this.reason}) {
    if (reason.isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'must not be empty');
    }
  }

  /// Stable failure category.
  final ReferenceDecodeFailureKind kind;

  /// User-presentable skip reason.
  final String reason;
}

/// Open encoded image whose intrinsic dimensions are known before decoding.
abstract interface class ReferenceDecodeSource {
  /// Encoded image width without a full pixel decode.
  int get intrinsicWidth;

  /// Encoded image height without a full pixel decode.
  int get intrinsicHeight;

  /// Decodes exactly the requested bounded size to row-major RGBA8888.
  Future<Uint8List> decodeRgba({
    required int targetWidth,
    required int targetHeight,
  });

  /// Releases encoded-image and codec resources.
  void dispose();
}

/// Injectable encoded-image backend used by [ReferenceImageDecoder].
abstract interface class ReferenceDecodeBackend {
  /// Opens encoded bytes and reads intrinsic metadata without decoding pixels.
  Future<ReferenceDecodeSource> open(Uint8List encodedBytes);
}

/// `dart:ui` reference backend used by the production import pipeline.
final class DartUiReferenceDecodeBackend implements ReferenceDecodeBackend {
  /// Creates the stateless production backend.
  const DartUiReferenceDecodeBackend();

  @override
  Future<ReferenceDecodeSource> open(Uint8List encodedBytes) async {
    final ImmutableBuffer buffer = await ImmutableBuffer.fromUint8List(
      encodedBytes,
    );
    try {
      final ImageDescriptor descriptor = await ImageDescriptor.encoded(buffer);
      return _DartUiReferenceDecodeSource(
        buffer: buffer,
        descriptor: descriptor,
      );
    } on Object {
      buffer.dispose();
      rethrow;
    }
  }
}

/// Validates, bounds, and decodes PNG/JPEG reference images.
final class ReferenceImageDecoder {
  /// Creates a decoder with an injectable codec backend.
  const ReferenceImageDecoder({
    ReferenceDecodeBackend backend = const DartUiReferenceDecodeBackend(),
  }) : // The public parameter intentionally omits the private field prefix.
       // ignore: prefer_initializing_formals
       _backend = backend;

  final ReferenceDecodeBackend _backend;

  /// Decodes [encodedBytes] within the current canvas dimensions.
  ///
  /// Unsupported extensions and corrupt image data return typed failures. Bad
  /// API bounds remain programmer errors and throw [ArgumentError].
  Future<ReferenceDecodeResult> decode({
    required String sourceId,
    required String fileName,
    required Uint8List encodedBytes,
    required int maxWidth,
    required int maxHeight,
  }) async {
    if (sourceId.isEmpty) {
      throw ArgumentError.value(sourceId, 'sourceId', 'must not be empty');
    }
    _requireReferenceDimension(maxWidth, 'maxWidth');
    _requireReferenceDimension(maxHeight, 'maxHeight');
    if (!_hasSupportedReferenceExtension(fileName)) {
      return ReferenceDecodeFailure(
        kind: ReferenceDecodeFailureKind.unsupportedFormat,
        reason: 'only PNG and JPEG reference images are supported',
      );
    }
    if (encodedBytes.isEmpty) {
      return ReferenceDecodeFailure(
        kind: ReferenceDecodeFailureKind.corruptImage,
        reason: 'the reference image is empty or corrupt',
      );
    }
    if (!_hasSupportedReferenceMagic(encodedBytes)) {
      return ReferenceDecodeFailure(
        kind: ReferenceDecodeFailureKind.unsupportedFormat,
        reason: 'only PNG and JPEG reference images are supported',
      );
    }

    ReferenceDecodeSource? source;
    try {
      source = await _backend.open(encodedBytes);
      final ReferenceDecodeSize size = cappedReferenceDecodeSize(
        intrinsicWidth: source.intrinsicWidth,
        intrinsicHeight: source.intrinsicHeight,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );
      final Uint8List rgbaBytes = await source.decodeRgba(
        targetWidth: size.width,
        targetHeight: size.height,
      );
      return ReferenceDecodeSuccess(
        ReferenceDecode.takeOwnership(
          descriptor: ReferenceImageDescriptor(
            sourceId: sourceId,
            pixelWidth: size.width,
            pixelHeight: size.height,
          ),
          rgbaBytes: rgbaBytes,
        ),
      );
    } on Object {
      return ReferenceDecodeFailure(
        kind: ReferenceDecodeFailureKind.corruptImage,
        reason: 'the reference image could not be decoded',
      );
    } finally {
      try {
        source?.dispose();
      } on Object {
        // A decoded result remains valid even if native cleanup reports late.
      }
    }
  }
}

final class _DartUiReferenceDecodeSource implements ReferenceDecodeSource {
  _DartUiReferenceDecodeSource({
    required ImmutableBuffer buffer,
    required ImageDescriptor descriptor,
  }) : // Public-looking local names keep the native ownership call readable.
       // ignore: prefer_initializing_formals
       _buffer = buffer,
       // ignore: prefer_initializing_formals
       _descriptor = descriptor;

  final ImmutableBuffer _buffer;
  final ImageDescriptor _descriptor;
  bool _disposed = false;

  @override
  int get intrinsicWidth => _descriptor.width;

  @override
  int get intrinsicHeight => _descriptor.height;

  @override
  Future<Uint8List> decodeRgba({
    required int targetWidth,
    required int targetHeight,
  }) async {
    _requireReferenceDimension(targetWidth, 'targetWidth');
    _requireReferenceDimension(targetHeight, 'targetHeight');
    Codec? codec;
    Image? image;
    try {
      codec = await _descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
      if (image.width != targetWidth || image.height != targetHeight) {
        throw StateError('The image codec returned unexpected dimensions.');
      }
      final ByteData? data = await image.toByteData(
        format: ImageByteFormat.rawRgba,
      );
      if (data == null) {
        throw StateError('The image codec returned no RGBA pixels.');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _descriptor.dispose();
    _buffer.dispose();
  }
}

/// Decode-pipeline result accepted by the WP5 placement controller.
final class ReferenceImageDescriptor {
  /// Creates a validated reference-image descriptor.
  ReferenceImageDescriptor({
    required this.sourceId,
    required this.pixelWidth,
    required this.pixelHeight,
  }) {
    if (sourceId.isEmpty) {
      throw ArgumentError.value(sourceId, 'sourceId', 'must not be empty');
    }
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      throw ArgumentError.value(
        (pixelWidth, pixelHeight),
        'pixelSize',
        'must be positive',
      );
    }
  }

  /// Stable import/decode asset identifier.
  final String sourceId;

  /// Decoded raster width.
  final int pixelWidth;

  /// Decoded raster height.
  final int pixelHeight;

  /// Native placement size in document pixels.
  Size get size => Size(pixelWidth.toDouble(), pixelHeight.toDouble());
}

/// Immutable reference placement transform.
final class ReferencePlacement {
  /// Creates a validated placement.
  ReferencePlacement({
    required this.topLeft,
    this.scale = 1,
    this.rotationRadians = 0,
    this.isFlippedHorizontally = false,
    this.isFlippedVertically = false,
  }) {
    _requireFiniteOffset(topLeft, 'topLeft');
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and positive');
    }
    if (!rotationRadians.isFinite) {
      throw ArgumentError.value(
        rotationRadians,
        'rotationRadians',
        'must be finite',
      );
    }
  }

  /// Unrotated document-space top-left.
  final Offset topLeft;

  /// Uniform placement scale.
  final double scale;

  /// Rotation around the placed image center.
  final double rotationRadians;

  /// Whether the placed image is mirrored around its vertical center axis.
  final bool isFlippedHorizontally;

  /// Whether the placed image is mirrored around its horizontal center axis.
  final bool isFlippedVertically;

  /// Returns a placement with selected fields replaced.
  ReferencePlacement copyWith({
    Offset? topLeft,
    double? scale,
    double? rotationRadians,
    bool? isFlippedHorizontally,
    bool? isFlippedVertically,
  }) => ReferencePlacement(
    topLeft: topLeft ?? this.topLeft,
    scale: scale ?? this.scale,
    rotationRadians: rotationRadians ?? this.rotationRadians,
    isFlippedHorizontally: isFlippedHorizontally ?? this.isFlippedHorizontally,
    isFlippedVertically: isFlippedVertically ?? this.isFlippedVertically,
  );
}

/// Immutable locked member of the separate two-slot reference stack.
final class ReferenceLayer {
  /// Creates a reference layer.
  ReferenceLayer({
    required this.id,
    required this.image,
    required this.placement,
    this.isVisible = true,
    this.opacity = referenceLayerOpacity,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    _requireReferenceOpacity(opacity);
  }

  /// Stack-local stable layer identifier.
  final String id;

  /// Imported image metadata; decoding remains WP8-owned.
  final ReferenceImageDescriptor image;

  /// Placement transform, the only operation that bypasses [isLocked].
  final ReferencePlacement placement;

  /// Whether the overlay is currently shown.
  final bool isVisible;

  /// Compositor opacity in the inclusive zero-to-one range.
  final double opacity;

  /// Reference layers are always locked.
  bool get isLocked => true;

  /// References never contribute to artwork export.
  bool get excludedFromExport => true;

  /// Placed, unrotated size.
  Size get placedSize => image.size * placement.scale;

  /// Returns a layer with selected presentation properties replaced.
  ReferenceLayer copyWith({
    ReferencePlacement? placement,
    bool? isVisible,
    double? opacity,
  }) => ReferenceLayer(
    id: id,
    image: image,
    placement: placement ?? this.placement,
    isVisible: isVisible ?? this.isVisible,
    opacity: opacity ?? this.opacity,
  );
}

/// Journal command adding a member to the separate reference stack.
final class ReferenceAddCommand implements JournaledToolCommand {
  /// Creates an add command.
  const ReferenceAddCommand(this.layer);

  /// Newly created locked reference layer.
  final ReferenceLayer layer;

  @override
  JournalKind get journalKind => JournalKind.layerAdd;
}

/// Non-journaled live reference placement preview.
final class ReferencePlacementPreview implements ToolCommand {
  /// Creates a placement preview.
  const ReferencePlacementPreview(this.layer);

  /// Updated layer snapshot.
  final ReferenceLayer layer;

  /// Placement is the sole action allowed to bypass the layer lock.
  bool get bypassesLock => true;
}

/// Final reference placement journal command.
final class ReferencePlacementCommit implements JournaledToolCommand {
  /// Creates a placement commit.
  const ReferencePlacementCommit(this.layer);

  /// Updated layer snapshot.
  final ReferenceLayer layer;

  /// Placement is the sole action allowed to bypass the layer lock.
  bool get bypassesLock => true;

  @override
  JournalKind get journalKind => JournalKind.layerProps;
}

/// Owns the independent two-slot reference stack and placement edit state.
final class ReferenceToolController extends ToolController<ReferenceToolKind> {
  /// Creates an empty reference stack.
  ReferenceToolController() : super(const ReferenceToolKind());

  final List<ReferenceLayer> _layers = <ReferenceLayer>[];
  String? _placingLayerId;
  ReferenceLayer? _placementBefore;

  /// Immutable bottom-to-top reference stack.
  List<ReferenceLayer> get layers => List<ReferenceLayer>.unmodifiable(_layers);

  /// References do not consume any of the twelve content-layer slots.
  int get contentLayerSlotsConsumed => 0;

  /// Whether another reference may be imported.
  bool get canAddReference => _layers.length < maximumReferenceLayers;

  /// Layer currently in the lock-bypassing placement gesture.
  String? get placingLayerId => _placingLayerId;

  @override
  bool get hasLiveState => _placingLayerId != null;

  /// Adds an imported image centered in the current document viewport.
  ReferenceAddCommand addReference({
    required String layerId,
    required ReferenceImageDescriptor image,
    required Offset viewportCenter,
    double opacity = referenceLayerOpacity,
  }) {
    if (!canAddReference) {
      throw StateError('The two-slot reference stack is full.');
    }
    if (_layers.any((ReferenceLayer layer) => layer.id == layerId)) {
      throw ArgumentError.value(layerId, 'layerId', 'must be unique');
    }
    _requireFiniteOffset(viewportCenter, 'viewportCenter');
    final ReferenceLayer layer = ReferenceLayer(
      id: layerId,
      image: image,
      placement: ReferencePlacement(
        topLeft:
            viewportCenter -
            Offset(image.pixelWidth / 2, image.pixelHeight / 2),
      ),
      opacity: opacity,
    );
    _layers.add(layer);
    _placingLayerId = layer.id;
    _placementBefore = layer;
    return ReferenceAddCommand(layer);
  }

  /// Begins the only lock-bypassing edit allowed on a reference layer.
  void beginPlacement(String layerId) {
    if (_placingLayerId != null) {
      cancel();
    }
    final int index = _indexOf(layerId);
    _placingLayerId = layerId;
    _placementBefore = _layers[index];
  }

  /// Updates a live placement despite the reference layer's lock.
  ReferencePlacementPreview updatePlacement(ReferencePlacement placement) {
    final String? layerId = _placingLayerId;
    if (layerId == null) {
      throw StateError('No reference placement is active.');
    }
    final int index = _indexOf(layerId);
    final ReferenceLayer next = _layers[index].copyWith(placement: placement);
    _layers[index] = next;
    return ReferencePlacementPreview(next);
  }

  /// Commits the placement as layer properties and ends the bypass.
  ReferencePlacementCommit commitPlacement() {
    final String? layerId = _placingLayerId;
    if (layerId == null) {
      throw StateError('No reference placement is active.');
    }
    final ReferenceLayer layer = _layers[_indexOf(layerId)];
    _placingLayerId = null;
    _placementBefore = null;
    return ReferencePlacementCommit(layer);
  }

  /// Shows or hides a reference without changing its locked pixel content.
  void setVisible(String layerId, bool visible) {
    final int index = _indexOf(layerId);
    _layers[index] = _layers[index].copyWith(isVisible: visible);
  }

  /// Changes one reference layer's render opacity without unlocking pixels.
  void setOpacity(String layerId, double opacity) {
    final int index = _indexOf(layerId);
    _layers[index] = _layers[index].copyWith(opacity: opacity);
  }

  /// Reorders one layer inside the reference stack only.
  void reorder(String layerId, int newIndex) {
    final int oldIndex = _indexOf(layerId);
    if (newIndex < 0 || newIndex >= _layers.length) {
      throw RangeError.range(newIndex, 0, _layers.length - 1, 'newIndex');
    }
    final ReferenceLayer layer = _layers.removeAt(oldIndex);
    _layers.insert(newIndex, layer);
  }

  /// Deletes one reference-layer stack member.
  ReferenceLayer remove(String layerId) {
    final int index = _indexOf(layerId);
    if (_placingLayerId == layerId) {
      _placingLayerId = null;
      _placementBefore = null;
    }
    return _layers.removeAt(index);
  }

  /// Pixel edits never bypass the reference lock.
  bool canModifyPixels(String layerId) {
    _indexOf(layerId);
    return false;
  }

  int _indexOf(String layerId) {
    final int index = _layers.indexWhere(
      (ReferenceLayer layer) => layer.id == layerId,
    );
    if (index < 0) {
      throw ArgumentError.value(layerId, 'layerId', 'does not exist');
    }
    return index;
  }

  @override
  void cancel() {
    final String? layerId = _placingLayerId;
    final ReferenceLayer? before = _placementBefore;
    if (layerId != null && before != null) {
      final int index = _indexOf(layerId);
      _layers[index] = before;
    }
    _placingLayerId = null;
    _placementBefore = null;
  }
}

void _requireFiniteOffset(Offset value, String name) {
  if (!value.dx.isFinite || !value.dy.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}

void _requireReferenceOpacity(double value) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw ArgumentError.value(
      value,
      'opacity',
      'must be finite and between zero and one',
    );
  }
}

void _requireReferenceDimension(int value, String name) {
  if (value <= 0 || value > maximumReferenceDecodeDimension) {
    throw ArgumentError.value(
      value,
      name,
      'must be between 1 and $maximumReferenceDecodeDimension',
    );
  }
}

bool _hasSupportedReferenceExtension(String fileName) {
  final String lower = fileName.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg');
}

bool _hasSupportedReferenceMagic(Uint8List bytes) {
  final bool isPng =
      bytes.lengthInBytes >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a;
  final bool isJpeg =
      bytes.lengthInBytes >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff;
  return isPng || isJpeg;
}
