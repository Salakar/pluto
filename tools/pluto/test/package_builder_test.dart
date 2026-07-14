import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_cli/pluto.dart';
import 'package:pluto_cli/src/build/plap_reader.dart';
import 'package:pluto_cli/src/build/tar_writer.dart';
import 'package:test/test.dart';

import 'support/aot_fixture.dart';

void main() {
  test(
    'package builder validates layout and writes integrity metadata',
    () async {
      final PlapPackage package =
          await const PlapPackageBuilder(compressor: NoopCompressor()).build(
            source: MemoryPackageSource(<PackageEntry>[
              PackageEntry(
                path: 'manifest.json',
                bytes: Uint8List.fromList(
                  utf8.encode(
                    '{"schema":1,"runtime":{"type":"flutter-aot",'
                    '"appElf":"lib/app.so","assets":"flutter_assets"}}',
                  ),
                ),
              ),
              PackageEntry(
                path: 'bundle/lib/app.so',
                bytes: releaseAotElf(),
                executable: true,
              ),
              PackageEntry(
                path: 'bundle/flutter_assets/AssetManifest.bin',
                bytes: Uint8List.fromList(<int>[4, 5, 6]),
              ),
              PackageEntry(
                path: 'icon/icon.png',
                bytes: Uint8List.fromList(<int>[7, 8, 9]),
              ),
            ]),
            metadata: const PackageMetadata(
              flutterVersion: '3.44.4',
              engineCommit: 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
              plutoVersion: '0.1.0',
            ),
          );

      expect(package.integrity['schema'], 1);
      expect(package.integrity['compression'], 'none');
      expect(package.bytes.length % 512, 0);
      expect(package.bytes.length, greaterThan(1024));
    },
  );

  test('package builder validates and records linux-arm target', () async {
    final PlapPackage package =
        await const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: MemoryPackageSource(<PackageEntry>[
            PackageEntry(
              path: 'manifest.json',
              bytes: Uint8List.fromList(
                utf8.encode(
                  '{"schema":1,"id":"dev.example.arm",'
                  '"runtime":{"type":"flutter-aot",'
                  '"appElf":"lib/app.so","assets":"flutter_assets"}}',
                ),
              ),
            ),
            PackageEntry(path: 'bundle/lib/app.so', bytes: releaseArmAotElf()),
            PackageEntry(
              path: 'bundle/flutter_assets/AssetManifest.bin',
              bytes: Uint8List.fromList(<int>[1]),
            ),
          ]),
          metadata: const PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
            plutoVersion: '0.1.0',
            target: 'linux-arm',
          ),
        );

    expect(package.integrity['target'], 'linux-arm');
    final File output = File(
      '${Directory.systemTemp.createTempSync('pluto-arm-package-').path}/app.plap',
    )..writeAsBytesSync(package.bytes);
    addTearDown(() => output.parent.deleteSync(recursive: true));
    expect((await PlapArchive.read(output.path)).target, 'linux-arm');
  });

  test('package builder rejects non-release linux-arm metadata', () async {
    for (final String mode in <String>['debug', 'profile']) {
      await expectLater(
        const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: const MemoryPackageSource(<PackageEntry>[]),
          metadata: PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
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
  });

  test(
    'package reader rejects crafted non-release linux-arm metadata',
    () async {
      final PlapPackage releasePackage =
          await const PlapPackageBuilder(compressor: NoopCompressor()).build(
            source: MemoryPackageSource(<PackageEntry>[
              PackageEntry(
                path: 'manifest.json',
                bytes: Uint8List.fromList(
                  utf8.encode(
                    '{"schema":1,"id":"dev.example.arm",'
                    '"runtime":{"type":"flutter-aot",'
                    '"appElf":"lib/app.so","assets":"flutter_assets"}}',
                  ),
                ),
              ),
              PackageEntry(
                path: 'bundle/lib/app.so',
                bytes: releaseArmAotElf(),
              ),
              PackageEntry(
                path: 'bundle/flutter_assets/AssetManifest.bin',
                bytes: Uint8List.fromList(<int>[1]),
              ),
            ]),
            metadata: const PackageMetadata(
              flutterVersion: '3.44.4',
              engineCommit: 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
              plutoVersion: '0.1.0',
              target: 'linux-arm',
            ),
          );
      final List<PlapEntry> releaseEntries = readTarEntries(
        releasePackage.bytes,
      );

      for (final String mode in <String>['debug', 'profile']) {
        final List<TarFileEntry> craftedEntries = <TarFileEntry>[
          for (final PlapEntry entry in releaseEntries)
            if (entry.path == 'INTEGRITY.json')
              TarFileEntry(
                path: entry.path,
                bytes: Uint8List.fromList(
                  utf8.encode(
                    const JsonEncoder.withIndent(
                      '  ',
                    ).convert(<String, Object?>{
                      ...(jsonDecode(utf8.decode(entry.bytes))
                          as Map<String, Object?>),
                      'buildMode': mode,
                      'engineFlavor': mode,
                    }),
                  ),
                ),
              )
            else
              TarFileEntry(path: entry.path, bytes: entry.bytes),
        ];
        final File output = File(
          '${Directory.systemTemp.createTempSync('pluto-crafted-arm-').path}/'
          '$mode.plap',
        )..writeAsBytesSync(const TarArchiveWriter().write(craftedEntries));
        addTearDown(() => output.parent.deleteSync(recursive: true));

        await expectLater(
          PlapArchive.read(output.path),
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
    },
  );

  test('package builder rejects incomplete layouts', () async {
    expect(
      () => const PlapPackageBuilder(compressor: NoopCompressor()).build(
        source: MemoryPackageSource(<PackageEntry>[
          PackageEntry(
            path: 'manifest.json',
            bytes: Uint8List.fromList(<int>[1]),
          ),
        ]),
        metadata: const PackageMetadata(
          flutterVersion: '3.44.4',
          engineCommit: 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
          plutoVersion: '0.1.0',
        ),
      ),
      throwsA(isA<ArtifactVerificationException>()),
    );
  });

  test('debug package requires a kernel and rejects app.so', () async {
    final PlapPackage package =
        await const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: MemoryPackageSource(<PackageEntry>[
            PackageEntry(
              path: 'manifest.json',
              bytes: Uint8List.fromList(
                utf8.encode(
                  '{"schema":1,"runtime":{"type":"flutter-kernel",'
                  '"assets":"flutter_assets"}}',
                ),
              ),
            ),
            PackageEntry(
              path: 'bundle/flutter_assets/kernel_blob.bin',
              bytes: Uint8List.fromList(<int>[1]),
            ),
          ]),
          metadata: const PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
            plutoVersion: '0.1.0',
            buildMode: 'debug',
            engineFlavor: 'debug',
          ),
        );

    expect(package.integrity['buildMode'], 'debug');
    expect(package.integrity['engineFlavor'], 'debug');
  });
}
