/// Current major protocol version spoken by these Dart packages.
const int plutoProtocolVersion = 1;

/// Current package-family version used in the handshake payload.
const String plutoPackageVersion = '0.1.0';

/// Core method channel name.
const String plutoCoreChannel = 'pluto/core';

/// Device method channel name.
const String plutoDeviceChannel = 'pluto/device';

/// Settings method channel name.
const String plutoSettingsChannel = 'pluto/settings';

/// Settings event channel name.
const String plutoSettingsEventsChannel = 'pluto/settings/events';

/// Pen method channel name.
const String plutoPenChannel = 'pluto/pen';

/// Pen event channel name.
const String plutoPenEventsChannel = 'pluto/pen/events';

/// Touch method channel name.
const String plutoTouchChannel = 'pluto/touch';

/// Touch event channel name.
const String plutoTouchEventsChannel = 'pluto/touch/events';

/// Core handshake method.
const String coreHandshakeMethod = 'handshake';

/// Core capability query method.
const String coreCapabilitiesMethod = 'capabilities';

/// Device info query method.
const String deviceInfoMethod = 'deviceInfo';

/// Device capability query method.
const String deviceCapabilitiesMethod = 'capabilities';

/// Frontlight read method.
const String frontlightReadMethod = 'frontlight.read';

/// Frontlight write method.
const String frontlightWriteMethod = 'frontlight.write';

/// Wi-Fi enabled-state read method.
const String wifiIsEnabledMethod = 'wifi.isEnabled';

/// Wi-Fi enabled-state write method.
const String wifiSetEnabledMethod = 'wifi.setEnabled';

/// Wi-Fi scan method.
const String wifiScanMethod = 'wifi.scan';

/// Wi-Fi active-connection method.
const String wifiActiveMethod = 'wifi.active';

/// Wi-Fi connect method.
const String wifiConnectMethod = 'wifi.connect';

/// Wi-Fi disconnect method.
const String wifiDisconnectMethod = 'wifi.disconnect';

/// Wi-Fi forget-saved-network method.
const String wifiForgetMethod = 'wifi.forget';

/// Wi-Fi known-network list method.
const String wifiKnownMethod = 'wifi.known';

/// Power policy read method.
const String powerPolicyMethod = 'power.policy';

/// Power idle-suspend write method.
const String powerSetIdleSuspendDelayMethod = 'power.setIdleSuspendDelay';

/// Power suspend-to-power-off write method.
const String powerSetSuspendPowerOffDelayMethod =
    'power.setSuspendPowerOffDelay';

/// Immediate suspend method.
const String powerSuspendNowMethod = 'power.suspendNow';

/// Device PIN state read method.
const String securityIsPinSetMethod = 'security.isPinSet';

/// Device PIN write method.
const String securitySetPinMethod = 'security.setPin';

/// Device PIN remove method.
const String securityRemovePinMethod = 'security.removePin';

/// Device battery read method.
const String batteryDeviceMethod = 'battery.device';

/// Marker battery read method.
const String batteryMarkerMethod = 'battery.marker';

/// Pen state read method.
const String penCurrentStateMethod = 'pen.currentState';

/// Pen capability query method.
const String penCapabilitiesMethod = 'pen.capabilities';

/// Touch palm-rejection config read method.
const String touchPalmRejectionMethod = 'touch.palmRejection';

/// Touch palm-rejection config write method.
const String touchSetPalmRejectionMethod = 'touch.setPalmRejection';

/// Touch capability query method.
const String touchCapabilitiesMethod = 'touch.capabilities';
