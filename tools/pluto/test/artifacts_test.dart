import 'package:pluto_cli/pluto.dart';
import 'package:test/test.dart';

void main() {
  test('engine artifact resolver returns cache paths for the hash', () {
    const PlutoPaths paths = PlutoPaths(
      packageRoot: '/repo/tools/pluto',
      homeDirectory: '/home/tester',
    );
    const String hash = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

    final EngineCacheLayout layout = const EngineArtifactResolver(
      paths: paths,
      hostPlatform: HostPlatform.darwinX64,
    ).layoutFor(hash);

    expect(
      layout.engineLibrary(EngineFlavor.jit),
      '/home/tester/.pluto/cache/engine/$hash/linux-arm64-jit/'
      'libflutter_engine.so',
    );
    expect(
      layout.genSnapshot(EngineFlavor.release),
      '/home/tester/.pluto/cache/engine/$hash/gen_snapshot/darwin-x64/'
      'gen_snapshot_release',
    );
  });

  test('glibc audit helpers find the highest symbol version', () {
    const String objdump = '''
00000000      DF *UND*  00000000 (GLIBC_2.17) memcpy
00000000      DF *UND*  00000000 (GLIBC_2.39) pthread_create
00000000      DF *UND*  00000000 (GLIBC_2.40) future_symbol
''';

    expect(maxGlibcVersion(objdump), const GlibcVersion(2, 40));
    expect(isGlibcVersionSupported(const GlibcVersion(2, 39)), isTrue);
    expect(isGlibcVersionSupported(const GlibcVersion(2, 40)), isFalse);
  });

  test('tree hash is deterministic regardless of map insertion order', () {
    final String first = sha256Tree(<String, String>{
      'b.txt': '2',
      'a.txt': '1',
    });
    final String second = sha256Tree(<String, String>{
      'a.txt': '1',
      'b.txt': '2',
    });

    expect(first, second);
  });
}
