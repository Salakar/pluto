import 'dart:convert';
import 'dart:typed_data';

import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_provision/pluto_provision.dart';
import 'package:test/test.dart';

void main() {
  test(
    'installs a plap tar transaction and writes install marker last',
    () async {
      final MemoryProvisionFileSystem fs = MemoryProvisionFileSystem();
      final PlutoInstallTransaction transaction = PlutoInstallTransaction(
        fs: fs,
        clock: () => DateTime.utc(2026, 7, 6, 14, 22, 41),
        nonceFactory: () => 'n1',
      );

      final InstallTransactionResult result = await transaction.installPlap(
        _plapArchive(appVersion: '1.2.0'),
      );

      expect(result.appId.value, 'dev.example.sketchpad');
      expect(result.revision, 1);
      expect(result.changed, isTrue);
      expect(
        await fs.exists(
          '/home/root/pluto/apps/dev.example.sketchpad/install.json',
        ),
        isTrue,
      );
      expect(
        utf8.decode(await fs.readFile('/home/root/pluto/state/apps.rev')),
        '1\n',
      );
      expect(
        await fs.isDirectory('/home/root/pluto/appdata/dev.example.sketchpad'),
        isTrue,
      );
      expect(await fs.listDirectory('/home/root/pluto/staging'), isEmpty);

      final String recordText = utf8.decode(
        await fs.readFile(
          '/home/root/pluto/apps/dev.example.sketchpad/install.json',
        ),
      );
      final InstallRecord record = InstallRecord.decode(
        recordText,
      ).valueOrNull!;
      expect(record.installedAt, DateTime.utc(2026, 7, 6, 14, 22, 41));
      expect(record.buildMode, BuildMode.release);
      expect(record.payload['manifest.json'], startsWith('sha256:'));
      expect(record.payload['flutter_assets/'], startsWith('sha256:tree:'));
    },
  );

  test(
    'repairs an interrupted swap by restoring the old committed app',
    () async {
      final MemoryProvisionFileSystem fs = MemoryProvisionFileSystem();
      final PlutoInstallTransaction transaction = PlutoInstallTransaction(
        fs: fs,
      );
      await transaction.installPlap(_plapArchive(appVersion: '1.0.0'));
      await fs.rename(
        '/home/root/pluto/apps/dev.example.sketchpad',
        '/home/root/pluto/staging/.old-dev.example.sketchpad.n2',
      );
      await fs.createDirectory('/home/root/pluto/apps/dev.example.sketchpad');
      await fs.writeFile(
        '/home/root/pluto/apps/dev.example.sketchpad/manifest.json',
        utf8.encode('{"schema":1}'),
      );

      await transaction.repair();

      final String manifestText = utf8.decode(
        await fs.readFile(
          '/home/root/pluto/apps/dev.example.sketchpad/manifest.json',
        ),
      );
      final AppManifest manifest = AppManifest.decode(
        manifestText,
      ).valueOrNull!;
      expect(manifest.version.toString(), '1.0.0');
      expect(
        await fs.exists(
          '/home/root/pluto/staging/.old-dev.example.sketchpad.n2',
        ),
        isFalse,
      );
    },
  );

  test(
    'derives profile identity from authenticated archive metadata',
    () async {
      final MemoryProvisionFileSystem fs = MemoryProvisionFileSystem();
      final PlutoInstallTransaction transaction = PlutoInstallTransaction(
        fs: fs,
      );

      await transaction.installPlap(
        _plapArchive(appVersion: '1.2.0', buildMode: 'profile'),
      );

      final InstallRecord record = InstallRecord.decode(
        utf8.decode(
          await fs.readFile(
            '/home/root/pluto/apps/dev.example.sketchpad/install.json',
          ),
        ),
      ).valueOrNull!;
      expect(record.buildMode, BuildMode.profile);
      expect(record.engineFlavor, 'profile');
    },
  );

  test(
    'accepts debug only when the authenticated payload is kernel-shaped',
    () async {
      final MemoryProvisionFileSystem fs = MemoryProvisionFileSystem();
      final PlutoInstallTransaction transaction = PlutoInstallTransaction(
        fs: fs,
      );

      await transaction.installPlap(
        _plapArchive(
          appVersion: '1.2.0',
          buildMode: 'debug',
          runtimeType: 'flutter-kernel',
          includeAotElf: false,
          includeKernel: true,
        ),
      );

      final InstallRecord record = InstallRecord.decode(
        utf8.decode(
          await fs.readFile(
            '/home/root/pluto/apps/dev.example.sketchpad/install.json',
          ),
        ),
      ).valueOrNull!;
      expect(record.buildMode, BuildMode.debug);
      expect(record.engineFlavor, 'debug');
    },
  );

  test('rejects an archive without authenticated build identity', () async {
    final MemoryProvisionFileSystem fs = MemoryProvisionFileSystem();
    final PlutoInstallTransaction transaction = PlutoInstallTransaction(fs: fs);

    await expectLater(
      transaction.installPlap(
        _plapArchive(appVersion: '1.2.0', includeBuildIdentity: false),
      ),
      throwsA(
        isA<ProvisionTransactionException>().having(
          (ProvisionTransactionException error) => error.message,
          'message',
          contains('authenticated buildMode/engineFlavor'),
        ),
      ),
    );

    expect(
      await fs.exists('/home/root/pluto/apps/dev.example.sketchpad'),
      isFalse,
    );
    expect(await fs.exists('/home/root/pluto/state/apps.rev'), isFalse);
  });

  test('rejects mismatched build mode and engine flavor', () async {
    final PlutoInstallTransaction transaction = PlutoInstallTransaction(
      fs: MemoryProvisionFileSystem(),
    );

    await expectLater(
      transaction.installPlap(
        _plapArchive(
          appVersion: '1.2.0',
          buildMode: 'release',
          engineFlavor: 'debug',
        ),
      ),
      throwsA(
        isA<ProvisionTransactionException>().having(
          (ProvisionTransactionException error) => error.message,
          'message',
          contains('release/debug'),
        ),
      ),
    );
  });

  test('rejects release metadata over a kernel payload', () async {
    final PlutoInstallTransaction transaction = PlutoInstallTransaction(
      fs: MemoryProvisionFileSystem(),
    );

    await expectLater(
      transaction.installPlap(
        _plapArchive(
          appVersion: '1.2.0',
          runtimeType: 'flutter-kernel',
          includeAotElf: false,
          includeKernel: true,
        ),
      ),
      throwsA(
        isA<ProvisionTransactionException>().having(
          (ProvisionTransactionException error) => error.message,
          'message',
          contains('release package must use flutter-aot'),
        ),
      ),
    );
  });

  test('rejects an archive file omitted from the authenticated tree', () async {
    final PlutoInstallTransaction transaction = PlutoInstallTransaction(
      fs: MemoryProvisionFileSystem(),
    );

    await expectLater(
      transaction.installPlap(
        _plapArchive(appVersion: '1.2.0', omitAotElfFromIntegrity: true),
      ),
      throwsA(
        isA<ProvisionTransactionException>().having(
          (ProvisionTransactionException error) => error.message,
          'message',
          contains('payload set does not match'),
        ),
      ),
    );
  });

  test('uninstall atomically removes the app and is idempotent', () async {
    final MemoryProvisionFileSystem fs = MemoryProvisionFileSystem();
    final PlutoInstallTransaction transaction = PlutoInstallTransaction(
      fs: fs,
      clock: () =>
          DateTime.fromMillisecondsSinceEpoch(1783368000000, isUtc: true),
    );
    await transaction.installPlap(_plapArchive(appVersion: '1.2.0'));

    final UninstallTransactionResult removed = await transaction.uninstall(
      'dev.example.sketchpad',
      nonce: 'rm1',
    );

    expect(removed.changed, isTrue);
    expect(removed.revision, 2);
    expect(
      await fs.exists('/home/root/pluto/apps/dev.example.sketchpad'),
      isFalse,
    );
    expect(
      await fs.exists(
        '/home/root/pluto/appdata/dev.example.sketchpad/.uninstalled-1783368000',
      ),
      isTrue,
    );
    final UninstallTransactionResult repeated = await transaction.uninstall(
      'dev.example.sketchpad',
      nonce: 'rm2',
    );
    expect(repeated.changed, isFalse);
    expect(repeated.revision, 2);
  });
}

Uint8List _plapArchive({
  required String appVersion,
  String buildMode = 'release',
  String? engineFlavor,
  String runtimeType = 'flutter-aot',
  bool includeAotElf = true,
  bool includeKernel = false,
  bool includeBuildIdentity = true,
  bool omitAotElfFromIntegrity = false,
}) {
  final Map<String, Uint8List> files = <String, Uint8List>{
    'manifest.json': Uint8List.fromList(
      utf8.encode(_manifestJson(appVersion, runtimeType: runtimeType)),
    ),
    if (includeAotElf) 'bundle/lib/app.so': Uint8List.fromList(<int>[1, 2, 3]),
    if (includeKernel)
      'bundle/flutter_assets/kernel_blob.bin': Uint8List.fromList(<int>[8, 9]),
    'bundle/flutter_assets/AssetManifest.bin': Uint8List.fromList(<int>[4, 5]),
    'icon/icon.png': Uint8List.fromList(<int>[6, 7]),
  };
  final Map<String, String> hashes = <String, String>{};
  for (final MapEntry<String, Uint8List> entry in files.entries) {
    if (omitAotElfFromIntegrity && entry.key == 'bundle/lib/app.so') {
      continue;
    }
    hashes[entry.key] = sha256Hex(entry.value);
  }
  files['INTEGRITY.json'] = Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'schema': 1,
        if (includeBuildIdentity) 'buildMode': buildMode,
        if (includeBuildIdentity) 'engineFlavor': engineFlavor ?? buildMode,
        'files': hashes,
        'treeSha256': _treeHash(hashes),
      }),
    ),
  );
  return _tar(files);
}

String _manifestJson(String version, {required String runtimeType}) =>
    jsonEncode(<String, Object?>{
      'schema': 1,
      'id': 'dev.example.sketchpad',
      'name': 'Sketchpad',
      'version': version,
      'runtime': <String, Object?>{
        'type': runtimeType,
        if (runtimeType == 'flutter-aot') 'appElf': 'lib/app.so',
        'assets': 'flutter_assets',
      },
      'engine': <String, Object?>{
        'flutterVersion': '3.44.4',
        'engineCommit': 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
        'plutoAbi': 1,
      },
    });

String _treeHash(Map<String, String> fileHashes) {
  final StringBuffer buffer = StringBuffer();
  final List<String> paths = fileHashes.keys.toList()..sort();
  for (final String path in paths) {
    buffer
      ..write(path)
      ..writeCharCode(0)
      ..write(fileHashes[path])
      ..write('\n');
  }
  return sha256Hex(utf8.encode(buffer.toString()));
}

Uint8List _tar(Map<String, Uint8List> files) {
  final BytesBuilder builder = BytesBuilder();
  for (final MapEntry<String, Uint8List> entry in files.entries) {
    final Uint8List header = Uint8List(512);
    _writeAscii(header, 0, 100, entry.key);
    _writeAscii(header, 100, 8, '0000644');
    _writeAscii(header, 108, 8, '0000000');
    _writeAscii(header, 116, 8, '0000000');
    _writeAscii(header, 124, 12, _octal(entry.value.length, 11));
    _writeAscii(header, 136, 12, _octal(0, 11));
    for (var index = 148; index < 156; index++) {
      header[index] = 32;
    }
    header[156] = 48;
    _writeAscii(header, 257, 6, 'ustar');
    _writeAscii(header, 263, 2, '00');
    final int checksum = header.fold<int>(
      0,
      (int total, int byte) => total + byte,
    );
    _writeAscii(header, 148, 8, '${_octal(checksum, 6)}\u0000 ');
    builder.add(header);
    builder.add(entry.value);
    final int padding = (512 - entry.value.length % 512) % 512;
    if (padding > 0) {
      builder.add(Uint8List(padding));
    }
  }
  builder
    ..add(Uint8List(512))
    ..add(Uint8List(512));
  return builder.toBytes();
}

String _octal(int value, int width) =>
    value.toRadixString(8).padLeft(width, '0');

void _writeAscii(Uint8List target, int offset, int length, String value) {
  final List<int> bytes = ascii.encode(value);
  for (var index = 0; index < bytes.length && index < length; index++) {
    target[offset + index] = bytes[index];
  }
}
