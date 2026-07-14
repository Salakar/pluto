import 'dart:convert';
import 'dart:typed_data';

/// Minimal 64-bit AArch64 ELF carrying Dart's release snapshot feature marker.
Uint8List releaseAotElf() =>
    _aotElf('product no-code_comments dedup_instructions no-asan arm64 linux');

/// Minimal 64-bit AArch64 ELF carrying Dart's profile snapshot feature marker.
Uint8List profileAotElf() => _aotElf(
  'release no-code_comments no-dedup_instructions no-asan arm64 linux',
);

/// Minimal 32-bit ARM EABI5 hard-float ELF with a release snapshot marker.
Uint8List releaseArmAotElf() => _aotElf(
  'product no-code_comments dedup_instructions no-asan arm linux',
  arm: true,
);

Uint8List _aotElf(String features, {bool arm = false}) {
  final Uint8List bytes = Uint8List(64);
  bytes
    ..[0] = 0x7f
    ..[1] = 0x45
    ..[2] = 0x4c
    ..[3] = 0x46
    ..[4] = arm ? 1 : 2
    ..[5] = 1
    ..[18] = arm ? 0x28 : 0xb7;
  if (arm) {
    bytes
      ..[37] = 0x04
      ..[39] = 0x05;
  }
  return Uint8List.fromList(<int>[
    ...bytes,
    ...latin1.encode('ace654289f5abc240509fc941453ebc5$features\u0000'),
  ]);
}
