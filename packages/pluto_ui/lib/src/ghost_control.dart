import 'package:flutter/services.dart';

/// Stock-compatible e-ink ghost-control operations.
enum GhostControlMode {
  /// Run one immediate Fast blink, then BleachNow, then restore content.
  blinkNow,

  /// Coalesce the blink-plus-bleach sequence until the renderer is active.
  blinkLater,

  /// Run two Fast rail cycles before restoring content.
  bleachNow,

  /// Run five Fast rail cycles before restoring content.
  factoryReset,
}

/// Native renderer ghost-control API.
///
/// All modes use Pluto's short rail waveform. The slow INIT waveform is
/// reserved for the native waveform laboratory and is never selected here.
abstract final class EinkGhostControl {
  static const MethodChannel _channel = MethodChannel('pluto/refresh');

  /// Requests [mode] and completes with whether the renderer accepted it.
  static Future<bool> request(GhostControlMode mode) async {
    final Map<Object?, Object?>? result = await _channel
        .invokeMapMethod<Object?, Object?>('requestGhostControl', mode.name);
    return result?['accepted'] == true;
  }
}
