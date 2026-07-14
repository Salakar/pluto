import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_validation_lab/main.dart';

ValidationLabConfig _parse(
  List<String> args, {
  String modeDefine = '',
  String sceneDefine = '',
  String hudDefine = '',
}) {
  return ValidationLabConfig.parse(
    args,
    modeDefine: modeDefine,
    sceneDefine: sceneDefine,
    hudDefine: hudDefine,
  );
}

void main() {
  group('ValidationLabConfig.parse', () {
    test('defaults to auto mode with the full loop and HUD on', () {
      final ValidationLabConfig config = _parse(const <String>[]);
      expect(config.mode, SceneRunnerMode.auto);
      expect(config.initialSceneId, isNull);
      expect(config.showHud, isTrue);
    });

    test('a scene without a mode implies single-scene mode', () {
      final ValidationLabConfig config = _parse(const <String>[
        '--scene=ghost-torture',
      ]);
      expect(config.mode, SceneRunnerMode.single);
      expect(config.initialSceneId, 'ghost-torture');
    });

    test('mode and scene can be combined', () {
      final ValidationLabConfig config = _parse(const <String>[
        '--mode=auto',
        '--scene=pen-scribble',
      ]);
      expect(config.mode, SceneRunnerMode.auto);
      expect(config.initialSceneId, 'pen-scribble');
    });

    test('manual mode parses', () {
      final ValidationLabConfig config = _parse(const <String>[
        '--mode=manual',
      ]);
      expect(config.mode, SceneRunnerMode.manual);
      expect(config.initialSceneId, isNull);
    });

    test('dart-define values act as defaults', () {
      final ValidationLabConfig config = _parse(
        const <String>[],
        modeDefine: 'manual',
        sceneDefine: 'counter-tick',
        hudDefine: 'off',
      );
      expect(config.mode, SceneRunnerMode.manual);
      expect(config.initialSceneId, 'counter-tick');
      expect(config.showHud, isFalse);
    });

    test('entrypoint args override dart-define values', () {
      final ValidationLabConfig config = _parse(
        const <String>['--mode=single', '--scene=page-turn', '--hud=on'],
        modeDefine: 'manual',
        sceneDefine: 'counter-tick',
        hudDefine: 'off',
      );
      expect(config.mode, SceneRunnerMode.single);
      expect(config.initialSceneId, 'page-turn');
      expect(config.showHud, isTrue);
    });

    test('the last occurrence of a repeated option wins', () {
      final ValidationLabConfig config = _parse(const <String>[
        '--scene=static-text',
        '--scene=scroll-list',
      ]);
      expect(config.initialSceneId, 'scroll-list');
    });

    test('unknown mode throws a FormatException', () {
      expect(
        () => _parse(const <String>['--mode=warp']),
        throwsFormatException,
      );
    });

    test('unknown hud value throws a FormatException', () {
      expect(
        () => _parse(const <String>['--hud=maybe']),
        throwsFormatException,
      );
    });

    test('unrelated arguments are ignored', () {
      final ValidationLabConfig config = _parse(const <String>[
        '--verbose',
        'positional',
      ]);
      expect(config, const ValidationLabConfig());
    });
  });

  group('SceneRunnerMode.tryParse', () {
    test('parses all modes and rejects unknown names', () {
      expect(SceneRunnerMode.tryParse('auto'), SceneRunnerMode.auto);
      expect(SceneRunnerMode.tryParse('manual'), SceneRunnerMode.manual);
      expect(SceneRunnerMode.tryParse('single'), SceneRunnerMode.single);
      expect(SceneRunnerMode.tryParse('AUTO'), isNull);
      expect(SceneRunnerMode.tryParse(''), isNull);
    });
  });

  group('buildValidationScenes', () {
    test('scene ids are unique and kebab-case', () {
      final List<SceneSpec> scenes = buildValidationScenes();
      final Set<String> ids = scenes.map((SceneSpec s) => s.id).toSet();
      expect(ids, hasLength(scenes.length));
      for (final String id in ids) {
        expect(
          RegExp(r'^[a-z]+(-[a-z]+)*$').hasMatch(id),
          isTrue,
          reason: '"$id" is not kebab-case',
        );
      }
    });

    test('the full loop dwells for at least three minutes', () {
      final List<SceneSpec> scenes = buildValidationScenes();
      final Duration total = scenes.fold(
        Duration.zero,
        (Duration sum, SceneSpec scene) => sum + scene.duration,
      );
      expect(total, greaterThanOrEqualTo(const Duration(minutes: 3)));
    });

    test('covers the renderer capability list', () {
      final List<String> ids = buildValidationScenes()
          .map((SceneSpec s) => s.id)
          .toList();
      expect(ids, <String>[
        'static-text',
        'counter-tick',
        'scroll-list',
        'page-turn',
        'color-swatches',
        'gradient-ramps',
        'animation-stress',
        'ghost-torture',
        'pen-scribble',
        'concurrent-regions',
      ]);
    });
  });
}
