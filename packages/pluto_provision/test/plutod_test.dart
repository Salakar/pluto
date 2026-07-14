import 'dart:convert';

import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_provision/pluto_provision.dart';
import 'package:pluto_provision/pluto_provision_testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'launch/list/foreground/home/exitToStock follow the JSON protocol',
    () async {
      final _FakeRegistry registry = _FakeRegistry(<PlutodRegisteredApp>[
        _app('dev.example.sketchpad', 'Sketchpad'),
      ]);
      final FakePlutodDevice device = FakePlutodDevice();
      final PlutodServer server = PlutodServer(
        registry: registry,
        device: device,
      );
      final PlutodClient client = PlutodClient(DirectPlutodTransport(server));
      final AppId appId = AppId.tryParse('dev.example.sketchpad')!;

      final PlutodLaunchResult firstLaunch = await client.launch(appId);
      expect(firstLaunch, isA<PlutodLaunchSuccess>());
      expect((firstLaunch as PlutodLaunchSuccess).pid, 1000);
      final PlutodLaunchResult secondLaunch = await client.launch(appId);
      expect((secondLaunch as PlutodLaunchSuccess).pid, 1000);

      final List<PlutodListApp> apps = await client.list();
      expect(apps.single.running, isTrue);
      await client.foreground(appId);
      await client.home();
      await client.exitToStock();
      final PlutodStatus status = await client.status();
      expect(status.foreground, 'stock');
      expect(status.running.single.pid, 1000);
      expect(device.calls, <String>[
        'launch:dev.example.sketchpad:1000',
        'foreground:dev.example.sketchpad',
        'foreground:dev.example.sketchpad',
        'home',
        'exitToStock',
      ]);
    },
  );

  test('uninstall terminates a running app and refreshes registry', () async {
    final _FakeRegistry registry = _FakeRegistry(<PlutodRegisteredApp>[
      _app('dev.example.sketchpad', 'Sketchpad'),
    ]);
    final FakePlutodDevice device = FakePlutodDevice();
    final _FakeUninstaller uninstaller = _FakeUninstaller();
    final PlutodServer server = PlutodServer(
      registry: registry,
      device: device,
      uninstaller: uninstaller,
    );
    final PlutodClient client = PlutodClient(DirectPlutodTransport(server));
    final AppId appId = AppId.tryParse('dev.example.sketchpad')!;
    await client.launch(appId);

    await client.uninstall(appId, purgeData: true);

    expect(device.calls, contains('terminate:1000'));
    expect(uninstaller.calls, <String>['dev.example.sketchpad:true']);
    expect(registry.refreshCount, 1);
    expect((await client.status()).running, isEmpty);
  });

  test('wire errors are stable JSON responses', () async {
    final PlutodServer server = PlutodServer(
      registry: _FakeRegistry(const <PlutodRegisteredApp>[]),
      device: FakePlutodDevice(),
    );

    final String line = await server.handleJsonLine(
      jsonEncode(<String, Object?>{'v': 2, 'op': 'status'}),
    );
    final Object? decoded = jsonDecode(line);

    expect(decoded, isA<Map<String, Object?>>());
    final Map<String, Object?> response = decoded! as Map<String, Object?>;
    expect(response['ok'], isFalse);
    expect(response['code'], 'unsupportedVersion');
  });
}

PlutodRegisteredApp _app(String id, String name) => PlutodRegisteredApp(
  id: AppId.tryParse(id)!,
  name: name,
  version: '1.0.0',
  appDir: '/home/root/pluto/apps/$id',
  dataDir: '/home/root/pluto/appdata/$id',
);

final class _FakeRegistry implements PlutodRegistry {
  _FakeRegistry(this.apps);

  final List<PlutodRegisteredApp> apps;
  int refreshCount = 0;

  @override
  Future<PlutodRegisteredApp?> getApp(AppId id) async {
    for (final PlutodRegisteredApp app in apps) {
      if (app.id.value == id.value) {
        return app;
      }
    }
    return null;
  }

  @override
  Future<List<PlutodRegisteredApp>> listApps() async => apps;

  @override
  Future<void> refresh() async {
    refreshCount += 1;
  }
}

final class _FakeUninstaller implements PlutodAppUninstaller {
  final List<String> calls = <String>[];

  @override
  Future<void> uninstall(AppId appId, {required bool purgeData}) async {
    calls.add('${appId.value}:$purgeData');
  }
}
