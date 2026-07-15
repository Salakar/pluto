import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_cli/pluto.dart';
import 'package:pluto_cli/src/build/plap_reader.dart';
import 'package:pluto_cli/src/build/tar_writer.dart';
import 'package:test/test.dart';

import 'support/aot_fixture.dart';

const String _engine = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

void main() {
  test(
    'single-slice package uses only canonical target-prefixed paths',
    () async {
      final PlapPackage package = await _buildRelease(
        target: PlutoTargetPlatform.linuxArm64,
      );
      final List<PlapEntry> entries = readTarEntries(package.bytes);
      final List<String> paths = entries
          .map((PlapEntry entry) => entry.path)
          .toList(growable: false);

      expect(
        paths.where((String path) => path == 'manifest.json'),
        hasLength(1),
      );
      expect(paths, contains('targets/linux-arm64/build-metadata.json'));
      expect(paths, contains('targets/linux-arm64/bundle/lib/app.so'));
      expect(
        paths,
        contains('targets/linux-arm64/bundle/flutter_assets/AssetManifest.bin'),
      );
      expect(paths, contains('targets/linux-arm64/assets/pluto/icon.png'));
      expect(paths, isNot(contains('bundle/lib/app.so')));
      expect(paths, isNot(contains('build-metadata.json')));
      expect(package.integrity.keys, <String>[
        'compression',
        'createdBy',
        'files',
        'treeSha256',
      ]);
      expect(package.integrity, isNot(contains('schema')));
      expect(package.integrity, isNot(contains('format')));
      expect(package.integrity, isNot(contains('version')));
    },
  );

  test(
    'multi-slice package shares one manifest and selects flat slices',
    () async {
      const PackageMetadata arm64 = PackageMetadata(
        flutterVersion: '3.44.4',
        engineCommit: _engine,
        plutoVersion: '0.1.0',
      );
      const PackageMetadata arm = PackageMetadata(
        flutterVersion: '3.44.4',
        engineCommit: _engine,
        plutoVersion: '0.1.0',
        target: 'linux-arm',
      );
      final PlapPackage package =
          await const PlapPackageBuilder(
            compressor: NoopCompressor(),
          ).buildSlices(
            slices: <PackageSliceSource>[
              PackageSliceSource(
                source: _releaseSource(PlutoTargetPlatform.linuxArm64),
                metadata: arm64,
              ),
              PackageSliceSource(
                source: _releaseSource(PlutoTargetPlatform.linuxArm),
                metadata: arm,
              ),
            ],
          );
      final File output = _writePackage(package, 'multi');
      final PlapArchive archive = await PlapArchive.read(output.path);

      expect(archive.slices.keys, <String>{'linux-arm', 'linux-arm64'});
      expect(() => archive.target, throwsStateError);
      for (final String target in archive.slices.keys) {
        final PlapTargetSlice slice = archive.sliceForTarget(target);
        final Set<String> flatPaths = readTarEntries(
          slice.installTarBytes,
        ).map((PlapEntry entry) => entry.path).toSet();
        expect(flatPaths, contains('manifest.json'));
        expect(flatPaths, contains('build-metadata.json'));
        expect(flatPaths, contains('bundle/lib/app.so'));
        expect(flatPaths, contains('assets/pluto/icon.png'));
        expect(
          flatPaths.any((String path) => path.startsWith('targets/')),
          false,
        );
        expect(slice.payloadHashes.keys.toSet(), flatPaths);
      }
    },
  );

  test('multi-slice builder rejects duplicate targets', () async {
    const PackageMetadata metadata = PackageMetadata(
      flutterVersion: '3.44.4',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
    );
    await expectLater(
      const PlapPackageBuilder(compressor: NoopCompressor()).buildSlices(
        slices: <PackageSliceSource>[
          PackageSliceSource(
            source: _releaseSource(PlutoTargetPlatform.linuxArm64),
            metadata: metadata,
          ),
          PackageSliceSource(
            source: _releaseSource(PlutoTargetPlatform.linuxArm64),
            metadata: metadata,
          ),
        ],
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('duplicate linux-arm64'),
        ),
      ),
    );
  });

  test('multi-slice builder rejects different app identities', () async {
    const PackageMetadata arm64 = PackageMetadata(
      flutterVersion: '3.44.4',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
    );
    const PackageMetadata arm = PackageMetadata(
      flutterVersion: '3.44.4',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
      target: 'linux-arm',
    );
    await expectLater(
      const PlapPackageBuilder(compressor: NoopCompressor()).buildSlices(
        slices: <PackageSliceSource>[
          PackageSliceSource(
            source: _releaseSource(PlutoTargetPlatform.linuxArm64),
            metadata: arm64,
          ),
          PackageSliceSource(
            source: _releaseSource(
              PlutoTargetPlatform.linuxArm,
              appId: 'dev.example.other',
            ),
            metadata: arm,
          ),
        ],
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('different app manifest'),
        ),
      ),
    );
  });

  test('multi-slice builder rejects different toolchain identities', () async {
    const PackageMetadata arm64 = PackageMetadata(
      flutterVersion: '3.44.4',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
    );
    const PackageMetadata arm = PackageMetadata(
      flutterVersion: '3.44.5',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
      target: 'linux-arm',
    );
    await expectLater(
      const PlapPackageBuilder(compressor: NoopCompressor()).buildSlices(
        slices: <PackageSliceSource>[
          PackageSliceSource(
            source: _releaseSource(PlutoTargetPlatform.linuxArm64),
            metadata: arm64,
          ),
          PackageSliceSource(
            source: _releaseSource(PlutoTargetPlatform.linuxArm),
            metadata: arm,
          ),
        ],
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('different build/toolchain identity'),
        ),
      ),
    );
  });

  test('reader rejects a crafted cross-slice toolchain mismatch', () async {
    const PackageMetadata arm64 = PackageMetadata(
      flutterVersion: '3.44.4',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
    );
    const PackageMetadata arm = PackageMetadata(
      flutterVersion: '3.44.5',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
      target: 'linux-arm',
    );
    final Uint8List crafted = _canonicalTar(<PackageEntry>[
      PackageEntry(path: 'manifest.json', bytes: _manifest()),
      ..._canonicalSliceEntries(PlutoTargetPlatform.linuxArm64, arm64),
      ..._canonicalSliceEntries(PlutoTargetPlatform.linuxArm, arm),
    ]);
    final File output = _writeBytes(crafted, 'mismatched-toolchain');

    await expectLater(
      PlapArchive.read(output.path),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('different build/toolchain identity'),
        ),
      ),
    );
  });

  test('package builder and reader enforce release-only linux-arm', () async {
    for (final String mode in <String>['debug', 'profile']) {
      await expectLater(
        const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: const MemoryPackageSource(<PackageEntry>[]),
          metadata: PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: _engine,
            plutoVersion: '0.1.0',
            buildMode: mode,
            engineFlavor: mode,
            target: 'linux-arm',
          ),
        ),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            contains('release-only'),
          ),
        ),
        reason: mode,
      );
    }

    final Uint8List crafted = _canonicalTar(<PackageEntry>[
      PackageEntry(path: 'manifest.json', bytes: _manifest(debug: true)),
      PackageEntry(
        path: 'targets/linux-arm/build-metadata.json',
        bytes: _buildMetadata(
          const PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: _engine,
            plutoVersion: '0.1.0',
            buildMode: 'debug',
            engineFlavor: 'debug',
            target: 'linux-arm',
          ),
        ),
      ),
      PackageEntry(
        path: 'targets/linux-arm/bundle/flutter_assets/kernel_blob.bin',
        bytes: Uint8List.fromList(<int>[1]),
      ),
      PackageEntry(
        path: 'targets/linux-arm/assets/pluto/icon.png',
        bytes: Uint8List.fromList(<int>[2]),
      ),
    ]);
    final File output = _writeBytes(crafted, 'crafted-debug-arm');
    await expectLater(
      PlapArchive.read(output.path),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('release-only'),
        ),
      ),
    );
  });

  test(
    'reader rejects schema or version fields in package integrity',
    () async {
      final PlapPackage package = await _buildRelease(
        target: PlutoTargetPlatform.linuxArm64,
      );
      final List<PlapEntry> entries = readTarEntries(package.bytes);
      for (final String field in <String>['schema', 'version', 'format']) {
        final Uint8List crafted = const TarArchiveWriter().write(<TarFileEntry>[
          for (final PlapEntry entry in entries)
            if (entry.path == 'INTEGRITY.json')
              TarFileEntry(
                path: entry.path,
                bytes: Uint8List.fromList(
                  utf8.encode(
                    jsonEncode(<String, Object?>{
                      ...(jsonDecode(utf8.decode(entry.bytes))
                          as Map<String, Object?>),
                      field: 1,
                    }),
                  ),
                ),
              )
            else
              TarFileEntry(path: entry.path, bytes: entry.bytes),
        ]);
        final File output = _writeBytes(crafted, 'integrity-$field');
        await expectLater(
          PlapArchive.read(output.path),
          throwsA(
            isA<ArtifactVerificationException>().having(
              (ArtifactVerificationException error) => error.message,
              'message',
              contains('schema/version fields are not supported'),
            ),
          ),
          reason: field,
        );
      }
    },
  );

  test('reader hard-rejects gzip', () async {
    final PlapPackage package = await _buildRelease(
      target: PlutoTargetPlatform.linuxArm64,
    );
    final File gzipPackage = _writeBytes(
      Uint8List.fromList(gzip.encode(package.bytes)),
      'gzip',
    );
    await expectLater(
      PlapArchive.read(gzipPackage.path),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('Gzip .plap packages are not supported'),
        ),
      ),
    );
  });

  test('builder rejects files outside exact slice payload paths', () async {
    for (final String path in <String>[
      'unexpected.txt',
      'bundle/unexpected.bin',
    ]) {
      await expectLater(
        const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: MemoryPackageSource(<PackageEntry>[
            ..._releaseEntries(PlutoTargetPlatform.linuxArm64),
            PackageEntry(path: path, bytes: Uint8List.fromList(<int>[1])),
          ]),
          metadata: const PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: _engine,
            plutoVersion: '0.1.0',
          ),
        ),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            contains('unsupported path $path'),
          ),
        ),
        reason: path,
      );
    }
  });

  test('builder rejects host metadata anywhere in a slice', () async {
    for (final String path in <String>[
      'bundle/flutter_assets/.DS_Store',
      'bundle/flutter_assets/.AppleDouble/resource',
      'bundle/flutter_assets/._AssetManifest.bin',
    ]) {
      await expectLater(
        const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: MemoryPackageSource(<PackageEntry>[
            ..._releaseEntries(PlutoTargetPlatform.linuxArm64),
            PackageEntry(path: path, bytes: Uint8List.fromList(<int>[1])),
          ]),
          metadata: const PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: _engine,
            plutoVersion: '0.1.0',
          ),
        ),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            allOf(contains('forbidden host metadata'), contains(path)),
          ),
        ),
        reason: path,
      );
    }
  });

  test('reader rejects host metadata from a crafted package', () async {
    const String path =
        'targets/linux-arm64/bundle/flutter_assets/._AssetManifest.bin';
    final Uint8List crafted = _canonicalTar(<PackageEntry>[
      PackageEntry(path: 'manifest.json', bytes: _manifest()),
      ..._canonicalSliceEntries(
        PlutoTargetPlatform.linuxArm64,
        const PackageMetadata(
          flutterVersion: '3.44.4',
          engineCommit: _engine,
          plutoVersion: '0.1.0',
        ),
      ),
      PackageEntry(path: path, bytes: Uint8List.fromList(<int>[1])),
    ]);

    await expectLater(
      PlapArchive.read(_writeBytes(crafted, 'host-metadata').path),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          allOf(contains('forbidden host metadata'), contains(path)),
        ),
      ),
    );
  });

  test('arm64 debug package is canonical and install-ready', () async {
    const PackageMetadata metadata = PackageMetadata(
      flutterVersion: '3.44.4',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
      buildMode: 'debug',
      engineFlavor: 'debug',
    );
    final PlapPackage package =
        await const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: MemoryPackageSource(<PackageEntry>[
            PackageEntry(path: 'manifest.json', bytes: _manifest(debug: true)),
            PackageEntry(
              path: 'bundle/flutter_assets/kernel_blob.bin',
              bytes: Uint8List.fromList(<int>[1]),
            ),
            PackageEntry(
              path: 'assets/pluto/icon.png',
              bytes: Uint8List.fromList(<int>[2]),
            ),
          ]),
          metadata: metadata,
        );
    final PlapArchive archive = await PlapArchive.read(
      _writePackage(package, 'debug-arm64').path,
    );
    expect(archive.buildMode, 'debug');
    expect(archive.target, 'linux-arm64');
    expect(
      readTarEntries(
        archive.sliceForTarget('linux-arm64').installTarBytes,
      ).map((PlapEntry entry) => entry.path),
      contains('bundle/flutter_assets/kernel_blob.bin'),
    );
  });
}

Future<PlapPackage> _buildRelease({required PlutoTargetPlatform target}) {
  return const PlapPackageBuilder(compressor: NoopCompressor()).build(
    source: _releaseSource(target),
    metadata: PackageMetadata(
      flutterVersion: '3.44.4',
      engineCommit: _engine,
      plutoVersion: '0.1.0',
      target: target.cliName,
    ),
  );
}

MemoryPackageSource _releaseSource(
  PlutoTargetPlatform target, {
  String appId = 'dev.example.notes',
}) {
  return MemoryPackageSource(_releaseEntries(target, appId: appId));
}

List<PackageEntry> _releaseEntries(
  PlutoTargetPlatform target, {
  String appId = 'dev.example.notes',
}) {
  return <PackageEntry>[
    PackageEntry(
      path: 'manifest.json',
      bytes: _manifest(appId: appId),
    ),
    PackageEntry(
      path: 'bundle/lib/app.so',
      bytes: target == PlutoTargetPlatform.linuxArm
          ? releaseArmAotElf()
          : releaseAotElf(),
      executable: true,
    ),
    PackageEntry(
      path: 'bundle/flutter_assets/AssetManifest.bin',
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
    ),
    PackageEntry(
      path: 'assets/pluto/icon.png',
      bytes: Uint8List.fromList(<int>[7, 8, 9]),
    ),
  ];
}

List<PackageEntry> _canonicalSliceEntries(
  PlutoTargetPlatform target,
  PackageMetadata metadata,
) {
  final String prefix = 'targets/${target.cliName}/';
  return <PackageEntry>[
    PackageEntry(
      path: '${prefix}build-metadata.json',
      bytes: _buildMetadata(metadata),
    ),
    PackageEntry(
      path: '${prefix}bundle/lib/app.so',
      bytes: target == PlutoTargetPlatform.linuxArm
          ? releaseArmAotElf()
          : releaseAotElf(),
    ),
    PackageEntry(
      path: '${prefix}bundle/flutter_assets/AssetManifest.bin',
      bytes: Uint8List.fromList(<int>[1]),
    ),
    PackageEntry(
      path: '${prefix}assets/pluto/icon.png',
      bytes: Uint8List.fromList(<int>[2]),
    ),
  ];
}

Uint8List _manifest({String appId = 'dev.example.notes', bool debug = false}) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'id': appId,
        'icon': 'assets/pluto/icon.png',
        'runtime': debug
            ? <String, Object?>{
                'type': 'flutter-kernel',
                'assets': 'flutter_assets',
              }
            : <String, Object?>{
                'type': 'flutter-aot',
                'appElf': 'lib/app.so',
                'assets': 'flutter_assets',
              },
      }),
    ),
  );
}

Uint8List _buildMetadata(PackageMetadata metadata) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'schema': BuildLayoutMetadata.schema,
        'buildMode': metadata.buildMode,
        'engineFlavor': metadata.engineFlavor,
        'flutterVersion': metadata.flutterVersion,
        'engineCommit': metadata.engineCommit,
        'target': metadata.target,
      }),
    ),
  );
}

Uint8List _canonicalTar(List<PackageEntry> payload) {
  final Map<String, String> hashes = <String, String>{
    for (final PackageEntry entry in payload)
      entry.path: sha256Bytes(entry.bytes),
  };
  final Map<String, Object?> integrity = <String, Object?>{
    'compression': 'none',
    'createdBy': 'pluto 0.1.0',
    'files': hashes,
    'treeSha256': sha256Tree(hashes),
  };
  return const TarArchiveWriter().write(<TarFileEntry>[
    for (final PackageEntry entry in payload)
      TarFileEntry(path: entry.path, bytes: entry.bytes),
    TarFileEntry(
      path: 'INTEGRITY.json',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(integrity))),
    ),
  ]);
}

File _writePackage(PlapPackage package, String name) {
  return _writeBytes(package.bytes, name);
}

File _writeBytes(Uint8List bytes, String name) {
  final Directory directory = Directory.systemTemp.createTempSync(
    'pluto-package-$name-',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  return File('${directory.path}/app.plap')..writeAsBytesSync(bytes);
}
