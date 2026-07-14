import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';

void main() {
  group('InkDocument', () {
    test('blank creates a complete one-layer schema-1 artwork', () {
      final document = InkDocument.blank(id: 'opaque/id', nowMs: 42);

      expect(document.schema, inkDocumentSchema);
      expect(document.id, 'opaque/id');
      expect(document.name, 'Untitled');
      expect(document.createdAtMs, 42);
      expect(document.modifiedAtMs, 42);
      expect(document.canvas.width, 1908);
      expect(document.canvas.height, 3392);
      expect(document.layers, hasLength(1));
      expect(document.layers.single.id, 'L1');
      expect(document.activeLayerId, 'L1');
      expect(document.tool.brushId, 'fineliner');
      expect(document.journalHeadSeq, 0);
    });

    test('binding manifest round-trips through JSON without type drift', () {
      final source = _manifest();
      final document = InkDocument.fromJson(_jsonRoundTrip(source));
      final encoded = _jsonRoundTrip(document.toJson());

      expect(encoded, source);
      expect(document.layers.map((layer) => layer.id), ['base', 'top']);
      expect(document.layers.last.tiles, [const TileKey(2, 3)]);
      expect(document.view.scale, 1.25);
      expect(document.tool.size, 4.5);
    });

    test('unknown keys survive at every manifest object level', () {
      final source = _manifest()
        ..['futureRoot'] = {
          'enabled': true,
          'values': [1, 2, 3],
        };
      (source['canvas']! as Map<String, Object?>)['futureCanvas'] = 'grid';
      ((source['layers']! as List<Object?>).first!
              as Map<String, Object?>)['futureLayer'] =
          9;
      (source['view']! as Map<String, Object?>)['futureView'] = {'snap': 15};
      (source['tool']! as Map<String, Object?>)['futureTool'] = ['alpha'];

      final encoded = InkDocument.fromJson(source).toJson();

      expect(encoded['futureRoot'], source['futureRoot']);
      expect(
        (encoded['canvas']! as Map<String, Object?>)['futureCanvas'],
        'grid',
      );
      expect(
        ((encoded['layers']! as List<Object?>).first!
            as Map<String, Object?>)['futureLayer'],
        9,
      );
      expect((encoded['view']! as Map<String, Object?>)['futureView'], {
        'snap': 15,
      });
      expect((encoded['tool']! as Map<String, Object?>)['futureTool'], [
        'alpha',
      ]);
    });

    test('unknown JSON is deeply defensive and exposed as immutable', () {
      final nested = <Object?>[1, 2];
      final source = <String, Object?>{
        'future': <String, Object?>{'nested': nested},
      };
      final canvas = CanvasSpec(width: 10, height: 20, unknownFields: source);
      nested.add(3);
      (source['future']! as Map<String, Object?>)['changed'] = true;

      final frozenFuture =
          canvas.unknownFields['future']! as Map<String, Object?>;
      expect(frozenFuture, {
        'nested': [1, 2],
      });
      expect(
        () => (frozenFuture['nested']! as List<Object?>).add(4),
        throwsUnsupportedError,
      );
      expect(() => canvas.unknownFields['new'] = 1, throwsUnsupportedError);

      final encoded = canvas.toJson();
      ((encoded['future']! as Map<String, Object?>)['nested']! as List<Object?>)
          .add(99);
      expect((canvas.toJson()['future']! as Map<String, Object?>)['nested'], [
        1,
        2,
      ]);
    });

    test('layer order remains bottom-to-top z-order', () {
      final source = _manifest();
      final layers = source['layers']! as List<Object?>;
      layers
        ..clear()
        ..addAll([_layer('bottom'), _layer('middle'), _layer('top')]);
      source['activeLayerId'] = 'middle';

      final document = InkDocument.fromJson(source);

      expect(document.layers.map((layer) => layer.id), [
        'bottom',
        'middle',
        'top',
      ]);
      expect(
        (document.toJson()['layers']! as List<Object?>).map(
          (layer) => (layer! as Map<String, Object?>)['id'],
        ),
        ['bottom', 'middle', 'top'],
      );
    });

    test('copyWith preserves unknown keys and immutable child lists', () {
      final source = _manifest()..['futureRoot'] = 'kept';
      final document = InkDocument.fromJson(source);

      final changed = document.copyWith(name: 'changed', modifiedAtMs: 999);

      expect(changed.name, 'changed');
      expect(changed.modifiedAtMs, 999);
      expect(changed.toJson()['futureRoot'], 'kept');
      expect(identical(changed.layers, document.layers), isFalse);
      expect(
        () => changed.layers.add(InkLayer(id: 'x', name: 'x')),
        throwsUnsupportedError,
      );
      expect(
        () => changed.layers.first.tiles.add(const TileKey(9, 9)),
        throwsUnsupportedError,
      );
    });

    test('known typed values override colliding unknown fields', () {
      final layer = InkLayer(
        id: 'typed',
        name: 'Typed name',
        unknownFields: const {'id': 'stale', 'name': 'stale', 'future': true},
      );

      expect(layer.unknownFields, {'future': true});
      expect(layer.toJson()['id'], 'typed');
      expect(layer.toJson()['name'], 'Typed name');
    });

    test('future or legacy schema is rejected rather than misread as v1', () {
      final future = _manifest()..['schema'] = 2;
      final legacy = _manifest()..['schema'] = 0;

      expect(
        () => InkDocument.fromJson(future),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => InkDocument.fromJson(legacy),
        throwsA(isA<FormatException>()),
      );
    });

    test('malformed tile coordinate arrays are rejected', () {
      final wrongLength = _manifest();
      (((wrongLength['layers']! as List<Object?>).first!
                  as Map<String, Object?>)['tiles']!
              as List<Object?>)
          .add([1]);
      final nonInteger = _manifest();
      (((nonInteger['layers']! as List<Object?>).first!
                  as Map<String, Object?>)['tiles']!
              as List<Object?>)
          .add([1.5, 2]);

      expect(
        () => InkDocument.fromJson(wrongLength),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => InkDocument.fromJson(nonInteger),
        throwsA(isA<FormatException>()),
      );
    });

    test('canvas enforces positive 4096-pixel bounds', () {
      expect(() => CanvasSpec(width: 1, height: 4096), returnsNormally);
      expect(() => CanvasSpec(width: 0, height: 10), throwsArgumentError);
      expect(() => CanvasSpec(width: 10, height: 4097), throwsArgumentError);
    });

    test('document rejects duplicate layer IDs', () {
      final source = _manifest();
      source['layers'] = [_layer('same'), _layer('same')];
      source['activeLayerId'] = 'same';

      expect(
        () => InkDocument.fromJson(source),
        throwsA(isA<FormatException>()),
      );
    });

    test('document rejects an active layer absent from its layer list', () {
      final source = _manifest()..['activeLayerId'] = 'missing';

      expect(
        () => InkDocument.fromJson(source),
        throwsA(isA<FormatException>()),
      );
    });

    test('document rejects an empty layer list with a dangling active ID', () {
      final source = _manifest()..['layers'] = <Object?>[];

      expect(
        () => InkDocument.fromJson(source),
        throwsA(isA<FormatException>()),
      );
    });

    test('numeric JSON integers decode into double view and tool fields', () {
      final source = _manifest();
      (source['view']! as Map<String, Object?>)
        ..['tx'] = 3
        ..['ty'] = -4
        ..['scale'] = 2
        ..['rotationDeg'] = 90;
      (source['tool']! as Map<String, Object?>)['size'] = 7;

      final document = InkDocument.fromJson(source);

      expect(document.view.tx, 3.0);
      expect(document.view.ty, -4.0);
      expect(document.view.scale, 2.0);
      expect(document.view.rotationDeg, 90.0);
      expect(document.tool.size, 7.0);
    });
  });
}

Map<String, Object?> _manifest() => {
  'schema': 1,
  'id': 'opaque-artwork-id',
  'name': 'harbor study',
  'createdAtMs': 10,
  'modifiedAtMs': 20,
  'canvas': <String, Object?>{
    'width': 1908,
    'height': 3392,
    'background': 'paper',
  },
  'layers': <Object?>[
    _layer('base'),
    _layer('top', tiles: const [TileKey(2, 3)]),
  ],
  'activeLayerId': 'top',
  'view': <String, Object?>{
    'tx': 12.0,
    'ty': -8.0,
    'scale': 1.25,
    'rotationDeg': 15.0,
  },
  'tool': <String, Object?>{
    'toolId': 'draw',
    'brushId': 'fineliner',
    'color': '#1D3E74',
    'size': 4.5,
    'presets': <String, Object?>{
      'fineliner': <String, Object?>{'size': 4.5},
    },
  },
  'journalHeadSeq': 4213,
};

Map<String, Object?> _layer(String id, {List<TileKey> tiles = const []}) => {
  'id': id,
  'name': '$id layer',
  'visible': true,
  'locked': false,
  'opacity': 100,
  'blend': 'normal',
  'tiles': <Object?>[
    for (final tile in tiles) <Object?>[tile.x, tile.y],
  ],
};

Map<String, Object?> _jsonRoundTrip(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value))! as Map<String, Object?>;
