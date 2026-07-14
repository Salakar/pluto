import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/model/editor_model.dart';
import 'package:paper_ink/src/model/tool_state.dart';
import 'package:paper_ink/src/tools/tool.dart';

void main() {
  group('WP6 typed color state', () {
    test('hex colors parse case-insensitively and encode canonically', () {
      final InkColor color = InkColor.fromHex('#1d3e74');

      expect(color.argb, 0xff1d3e74);
      expect(color.hex, '#1D3E74');
      expect(color, const InkColor.fromArgb(0xff1d3e74));
    });

    test('malformed and future color ids remain forward compatible', () {
      expect(InkColor.tryParse('deep-blue'), isNull);
      expect(() => InkColor.fromHex('#12345'), throwsFormatException);

      final ToolState state = ToolState(color: 'future-color-space:blue');
      expect(state.inkColor, isNull);
      expect(state.toPersisted().color, 'future-color-space:blue');
    });

    test('typed selection updates current color and recents atomically', () {
      final ToolState state = ToolState();
      var notifications = 0;
      state.addListener(() => notifications += 1);

      state.selectInkColor(const InkColor.fromArgb(0xffb3261e));

      expect(state.color, '#B3261E');
      expect(state.inkColor, const InkColor.fromArgb(0xffb3261e));
      expect(state.recentColors, <InkColor>[
        const InkColor.fromArgb(0xffb3261e),
      ]);
      expect(state.persistentRevision, 1);
      expect(notifications, 1);
    });

    test('recent colors deduplicate, move to front, and cap at eight', () {
      final ToolState state = ToolState();
      for (var index = 0; index < 10; index += 1) {
        state.selectInkColor(InkColor.fromArgb(0xff000000 | index));
      }
      state.selectInkColor(const InkColor.fromArgb(0xff000005));

      expect(state.recentColors, hasLength(maxInkRecentColors));
      expect(state.recentColors.first.argb, 0xff000005);
      expect(
        state.recentColors.map((InkColor color) => color.argb).toSet(),
        hasLength(maxInkRecentColors),
      );
      expect(
        state.recentColors,
        isNot(contains(const InkColor.fromArgb(0xff000001))),
      );
    });

    test('typed selection may opt out of recent-color policy', () {
      final ToolState state = ToolState();

      state.selectInkColor(
        const InkColor.fromArgb(0xff1a8fa8),
        remember: false,
      );

      expect(state.color, '#1A8FA8');
      expect(state.recentColors, isEmpty);
    });

    test('legacy setColor retains WP0-WP5 history behavior', () {
      final ToolState state = ToolState();

      state.setColor('#B03A7E');

      expect(state.inkColor, const InkColor.fromArgb(0xffb03a7e));
      expect(state.recentColors, isEmpty);
      expect(state.toPersisted().unknownFields, isNot(contains('wp6Color')));
    });

    test('typed recent row round trips through the unknown manifest field', () {
      final ToolState source = ToolState(
        recentColors: const <InkColor>[
          InkColor.fromArgb(0xff1d3e74),
          InkColor.fromArgb(0xffb3261e),
        ],
      );

      final ToolState restored = ToolState.fromPersisted(source.toPersisted());

      expect(restored.recentColors, source.recentColors);
      expect(restored.color, source.color);
    });

    test('load clear persist reload cannot resurrect stale recents', () {
      final ToolState state = ToolState.fromPersisted(
        InkToolState(
          toolId: 'draw',
          brushId: 'fineliner',
          color: '#1D3E74',
          size: 4,
          unknownFields: const <String, Object?>{
            'wp6Color': <String, Object?>{
              'recents': <String>['#B3261E', '#1A8FA8'],
            },
          },
        ),
      );
      expect(state.recentColors, hasLength(2));

      state.clearRecentColors();
      final InkToolState persisted = state.toPersisted();
      final ToolState reloaded = ToolState.fromPersisted(persisted);

      expect(
        (persisted.unknownFields['wp6Color']!
            as Map<String, Object?>)['recents'],
        isEmpty,
      );
      expect(reloaded.recentColors, isEmpty);
    });

    test('malformed recents are skipped and unknown siblings survive', () {
      final ToolState state = ToolState.fromPersisted(
        InkToolState(
          toolId: 'draw',
          brushId: 'fineliner',
          color: '#1D3E74',
          size: 4,
          unknownFields: const <String, Object?>{
            'wp6Color': <String, Object?>{
              'recents': <Object?>['bad', 7, '#112233', '#112233'],
              'futureMode': <String, Object?>{'space': 'display-p3'},
            },
          },
        ),
      );
      expect(state.recentColors, const <InkColor>[
        InkColor.fromArgb(0xff112233),
      ]);

      state.selectInkColor(const InkColor.fromArgb(0xff445566));
      final Map<String, Object?> encoded =
          state.toPersisted().unknownFields['wp6Color']!
              as Map<String, Object?>;

      expect(encoded['recents'], <String>['#445566', '#112233']);
      expect(encoded['futureMode'], <String, Object?>{'space': 'display-p3'});
    });

    test('unrecognized nested color payload survives when untouched', () {
      final ToolState state = ToolState.fromPersisted(
        InkToolState(
          toolId: 'draw',
          brushId: 'fineliner',
          color: '#1D3E74',
          size: 4,
          unknownFields: const <String, Object?>{'wp6Color': 'future-format'},
        ),
      );

      expect(state.recentColors, isEmpty);
      expect(state.toPersisted().unknownFields['wp6Color'], 'future-format');
    });
  });

  group('WP6 editor layer state and feedback', () {
    test('typed active-layer getters preserve bottom-to-top order', () {
      final EditorModel model = _editor(<InkLayer>[
        InkLayer(id: 'base', name: 'Base'),
        InkLayer(id: 'ink', name: 'Ink', blend: 'multiply'),
      ], activeLayerId: 'ink');
      addTearDown(model.dispose);

      expect(model.contentLayers.map((InkLayer layer) => layer.id), <String>[
        'base',
        'ink',
      ]);
      expect(model.activeLayer.id, 'ink');
      expect(model.activeLayerIndex, 1);
      expect(model.activeLayerOrdinal, 2);
      expect(model.activeLayerBlendMode, InkLayerBlendMode.multiply);
    });

    test('future blend ids remain representable through a null typed view', () {
      final EditorModel model = _editor(<InkLayer>[
        InkLayer(id: 'ink', name: 'Ink', blend: 'future-blend'),
      ]);
      addTearDown(model.dispose);

      expect(model.activeLayerBlendMode, isNull);
    });

    test('content layer cap is twelve and excludes no implicit slot', () {
      final EditorModel belowCap = _editor(<InkLayer>[
        for (var index = 0; index < 11; index += 1)
          InkLayer(id: 'L$index', name: 'Layer $index'),
      ]);
      final EditorModel atCap = _editor(<InkLayer>[
        for (var index = 0; index < maxInkContentLayers; index += 1)
          InkLayer(id: 'L$index', name: 'Layer $index'),
      ]);
      addTearDown(belowCap.dispose);
      addTearDown(atCap.dispose);

      expect(belowCap.canAddContentLayer, isTrue);
      expect(atCap.canAddContentLayer, isFalse);
    });

    test('hidden active layer is a no-op with canonical feedback', () {
      final EditorModel model = _editor(<InkLayer>[
        InkLayer(id: 'ink', name: 'Ink', visible: false),
      ], nowMilliseconds: () => 1200);
      addTearDown(model.dispose);
      var calls = 0;

      final bool ran = model.runLayerAction(action: () => calls += 1);

      expect(ran, isFalse);
      expect(calls, 0);
      expect(model.layerActionChip!.reason, ToolActionBlockReason.layerHidden);
      expect(model.layerActionChip!.message, 'layer hidden');
      expect(
        model.layerActionChip!.duration,
        const Duration(milliseconds: 800),
      );
    });

    test('hidden feedback takes precedence when layer is also locked', () {
      final EditorModel model = _editor(<InkLayer>[
        InkLayer(id: 'ink', name: 'Ink', visible: false, locked: true),
      ]);
      addTearDown(model.dispose);

      model.runLayerAction(action: () => fail('hidden action must be a no-op'));

      expect(model.layerActionChip!.reason, ToolActionBlockReason.layerHidden);
    });

    test('locked active layer is a no-op and expires at 800 ms', () {
      var now = 4000;
      final EditorModel model = _editor(<InkLayer>[
        InkLayer(id: 'ink', name: 'Ink', locked: true),
      ], nowMilliseconds: () => now);
      addTearDown(model.dispose);
      var calls = 0;

      expect(model.runLayerAction(action: () => calls += 1), isFalse);
      expect(calls, 0);
      expect(model.layerActionChip!.message, 'layer locked');
      expect(model.layerActionChip!.expiresAtMilliseconds, 4800);

      now = 4799;
      expect(model.layerActionChip, isNotNull);
      now = 4800;
      expect(model.layerActionChip, isNull);
      expect(model.lastLayerActionChip, isNotNull);
    });

    test('unlocked visible action runs exactly once without feedback', () {
      final EditorModel model = _editor(<InkLayer>[
        InkLayer(id: 'ink', name: 'Ink'),
      ]);
      addTearDown(model.dispose);
      var calls = 0;

      expect(model.runLayerAction(action: () => calls += 1), isTrue);

      expect(calls, 1);
      expect(model.lastLayerActionChip, isNull);
    });

    test('lock bypass permits placement but never bypasses hidden', () {
      final EditorModel locked = _editor(<InkLayer>[
        InkLayer(id: 'ink', name: 'Ink', locked: true),
      ]);
      final EditorModel hidden = _editor(<InkLayer>[
        InkLayer(id: 'ink', name: 'Ink', visible: false, locked: true),
      ]);
      addTearDown(locked.dispose);
      addTearDown(hidden.dispose);
      var calls = 0;

      expect(
        locked.runLayerAction(action: () => calls += 1, bypassLock: true),
        isTrue,
      );
      expect(
        hidden.runLayerAction(action: () => calls += 1, bypassLock: true),
        isFalse,
      );
      expect(calls, 1);
    });

    test('specific non-active layer is gated and unknown ids are rejected', () {
      final EditorModel model = _editor(<InkLayer>[
        InkLayer(id: 'base', name: 'Base', locked: true),
        InkLayer(id: 'ink', name: 'Ink'),
      ], activeLayerId: 'ink');
      addTearDown(model.dispose);

      expect(
        model.runLayerAction(layerId: 'base', action: () => fail('locked')),
        isFalse,
      );
      expect(
        () => model.runLayerAction(layerId: 'missing', action: () {}),
        throwsArgumentError,
      );
    });

    test('feedback can be dismissed synchronously', () {
      final EditorModel model = _editor(<InkLayer>[
        InkLayer(id: 'ink', name: 'Ink', locked: true),
      ]);
      addTearDown(model.dispose);
      var notifications = 0;
      model.addListener(() => notifications += 1);

      model.runLayerAction(action: () {});
      model.dismissLayerActionChip();
      model.dismissLayerActionChip();

      expect(model.lastLayerActionChip, isNull);
      expect(notifications, 2);
    });
  });
}

EditorModel _editor(
  List<InkLayer> layers, {
  String? activeLayerId,
  int Function()? nowMilliseconds,
}) {
  final InkDocument document = InkDocument.blank(
    id: 'wp6-model-test',
    nowMs: 1000,
  ).copyWith(layers: layers, activeLayerId: activeLayerId ?? layers.first.id);
  return EditorModel(
    document: document,
    tiles: TileStore(),
    journal: UndoJournal(storage: InMemoryJournalStorage()),
    nowMilliseconds: nowMilliseconds,
  );
}
