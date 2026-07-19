import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_core/testing.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_pen/pluto_pen_testing.dart';

void main() {
  test('fake pen events emit typed events', () async {
    const PenSample sample = PenSample(
      timestamp: Duration(milliseconds: 12),
      position: Offset(10, 20),
      rawPosition: Offset(100, 200),
      pressure: 0.5,
      rawPressure: 2048,
      tilt: Offset(0.1, -0.1),
      rawTilt: Offset(572, -572),
      distance: 0,
      rawDistance: 0,
      tool: PenTool.pen,
      buttons: PenButtons.none,
    );

    final PenEvent event = await FakePenEvents.single(sample).events.single;

    expect(event, isA<PenMoveEvent>());
    expect(event.sample.position, const Offset(10, 20));
    expect(event.sample.tool, PenTool.pen);
  });

  test('sample cursor drains doc-04 ring records', () {
    final PenRingWriter writer = PenRingWriter(capacity: 4)
      ..write(
        timestampUs: 1000,
        flags: 0x8,
        rawX: 676,
        rawY: 1196,
        rawPressure: 2048,
        rawDistance: 32768,
        tiltXCentiDegrees: 900,
        tiltYCentiDegrees: -900,
        orientationTag: 0,
        xLogical: 95.4,
        yLogical: 169.6,
      );
    FakePenRingSource(writer).install();

    final PenSampleCursor cursor = PlutoPen.withTransport(
      FakePlutoTransport(),
    ).openSampleCursor();
    final PenSampleBatch batch = cursor.drain();
    final PenSample sample = batch.sampleAt(0);

    expect(batch.length, 1);
    expect(batch.timestampsUs[0], 1000);
    expect(batch.buttons[0], PenButtons.primaryBit);
    expect(sample.rawPressure, 2048);
    expect(sample.buttons.hasPrimary, isTrue);
    expect(sample.position.dx, closeTo(95.4, 0.01));
    cursor.close();
    PlutoPen.debugSetRingSource(null);
  });

  test('pen facade decodes channel state and capabilities', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(
        plutoPenChannel,
        penCurrentStateMethod,
        (Object? arguments) => <String, Object?>{
          'isInProximity': true,
          'isInContact': false,
          'tool': 1,
          'buttons': 0,
        },
      )
      ..onInvoke(
        plutoPenChannel,
        penCapabilitiesMethod,
        (Object? arguments) => <String, Object?>{
          'axes': <String, Object?>{
            'rawXMax': 6760,
            'rawYMax': 11960,
            'rawPressureMax': 4096,
            'rawDistanceMax': 65535,
            'rawTiltMaxCentiDegrees': 9000,
          },
          'estimatedSampleRateHz': 200.0,
        },
      );

    final PlutoPen pen = PlutoPen.withTransport(transport);

    expect((await pen.currentState()).isInProximity, isTrue);
    expect((await pen.capabilities()).rawPressureMax, 4096);
  });

  test('capabilities reject retired wire aliases', () {
    const Map<String, Object?> axes = <String, Object?>{
      'rawXMax': 6760,
      'rawYMax': 11960,
      'rawPressureMax': 4096,
      'rawDistanceMax': 65535,
      'rawTiltMaxCentiDegrees': 9000,
    };

    expect(
      () => PenCapabilities.fromMap(<String, Object?>{
        ...axes,
        'estimatedSampleRateHz': 200.0,
      }),
      throwsFormatException,
    );
    expect(
      () => PenCapabilities.fromMap(<String, Object?>{
        'axes': axes,
        'sampleRateHzEstimate': 200.0,
      }),
      throwsFormatException,
    );
  });

  test('pen event stream decodes lifecycle variants', () async {
    final FakePlutoTransport transport = FakePlutoTransport();
    final PlutoPen pen = PlutoPen.withTransport(transport);
    final Future<List<PenEvent>> events = pen.events.take(4).toList();

    for (final String event in <String>['enter', 'down', 'buttons', 'leave']) {
      transport.emitEvent(plutoPenEventsChannel, _penPayload(event));
    }

    final List<PenEvent> decoded = await events;

    expect(decoded[0], isA<PenEnteredProximityEvent>());
    expect(decoded[1], isA<PenDownEvent>());
    expect(decoded[2], isA<PenButtonsChangedEvent>());
    expect(decoded[3], isA<PenLeftProximityEvent>());
    expect(decoded[1].sample.rawPosition, const Offset(100, 200));
  });

  test('pen event stream decodes hover, move, and up variants', () async {
    final FakePlutoTransport transport = FakePlutoTransport();
    final PlutoPen pen = PlutoPen.withTransport(transport);
    final Future<List<PenEvent>> events = pen.events.take(3).toList();

    for (final String event in <String>['hover', 'move', 'up']) {
      transport.emitEvent(plutoPenEventsChannel, _penPayload(event));
    }

    final List<PenEvent> decoded = await events;
    expect(decoded[0], isA<PenHoverEvent>());
    expect(decoded[1], isA<PenMoveEvent>());
    expect(decoded[2], isA<PenUpEvent>());
    expect(decoded[0].sample.distance, 0);
  });

  test('pen event stream rejects non-current lifecycle names', () async {
    for (final String event in <String>[
      'enteredProximity',
      'leftProximity',
      'buttonsChanged',
    ]) {
      final FakePlutoTransport transport = FakePlutoTransport();
      final Future<PenEvent> decoded = PlutoPen.withTransport(
        transport,
      ).events.first;

      transport.emitEvent(plutoPenEventsChannel, _penPayload(event));

      await expectLater(decoded, throwsFormatException);
    }
  });

  test('buttons event requires previous button state', () async {
    final FakePlutoTransport transport = FakePlutoTransport();
    final Future<PenEvent> decoded = PlutoPen.withTransport(
      transport,
    ).events.first;
    final Map<String, Object?> payload = _penPayload('buttons')
      ..remove('previousButtons');

    transport.emitEvent(plutoPenEventsChannel, payload);

    await expectLater(decoded, throwsFormatException);
  });

  test('pen tool wire values are exact integers', () {
    expect(
      PenSample.fromMap(<String, Object?>{
        ..._penPayload('move'),
        'tool': 1,
      }).tool,
      PenTool.pen,
    );
    expect(
      PenSample.fromMap(<String, Object?>{
        ..._penPayload('move'),
        'tool': 2,
      }).tool,
      PenTool.eraser,
    );

    for (final Object? tool in <Object?>['pen', 'eraser', 0, 3, null]) {
      expect(
        () => PenSample.fromMap(<String, Object?>{
          ..._penPayload('move'),
          'tool': tool,
        }),
        throwsFormatException,
      );
    }
    final Map<String, Object?> missing = _penPayload('move')..remove('tool');
    expect(() => PenSample.fromMap(missing), throwsFormatException);
  });

  test('cursor enforces single open and reports overwrite drops', () {
    final PenRingWriter writer = PenRingWriter(capacity: 2)
      ..write(
        timestampUs: 1,
        flags: 0,
        rawX: 1,
        rawY: 1,
        rawPressure: 0,
        rawDistance: 0,
        tiltXCentiDegrees: 0,
        tiltYCentiDegrees: 0,
        orientationTag: 0,
        xLogical: 1,
        yLogical: 1,
      )
      ..write(
        timestampUs: 2,
        flags: 0x4,
        rawX: 2,
        rawY: 2,
        rawPressure: 0,
        rawDistance: 0,
        tiltXCentiDegrees: 0,
        tiltYCentiDegrees: 0,
        orientationTag: 0,
        xLogical: 2,
        yLogical: 2,
      )
      ..write(
        timestampUs: 3,
        flags: 0x10,
        rawX: 3,
        rawY: 3,
        rawPressure: 0,
        rawDistance: 0,
        tiltXCentiDegrees: 0,
        tiltYCentiDegrees: 0,
        orientationTag: 0,
        xLogical: 3,
        yLogical: 3,
      );
    FakePenRingSource(writer).install();
    final PlutoPen pen = PlutoPen.withTransport(FakePlutoTransport());
    final PenSampleCursor cursor = pen.openSampleCursor();

    expect(() => pen.openSampleCursor(), throwsStateError);
    final PenSampleBatch batch = cursor.drain();

    expect(batch.length, 2);
    expect(cursor.droppedSampleCount, 1);
    expect(batch.sampleAt(0).tool, PenTool.eraser);
    expect(batch.sampleAt(1).buttons.hasSecondary, isTrue);
    cursor.close();
    PlutoPen.debugSetRingSource(null);
  });

  test('cursor rejects invalid ring memory and closed drains', () {
    final ByteData invalid = ByteData(64);
    PlutoPen.debugSetRingSource(ByteDataPenRingSource(invalid));
    expect(
      () => PlutoPen.withTransport(FakePlutoTransport()).openSampleCursor(),
      throwsFormatException,
    );

    final PenRingWriter versioned = PenRingWriter(capacity: 2);
    versioned.data.setUint32(4, 1, Endian.little);
    PlutoPen.debugSetRingSource(FakePenRingSource(versioned));
    expect(
      () => PlutoPen.withTransport(FakePlutoTransport()).openSampleCursor(),
      throwsFormatException,
    );

    final PenRingWriter writer = PenRingWriter(capacity: 2);
    FakePenRingSource(writer).install();
    final PenSampleCursor cursor = PlutoPen.withTransport(
      FakePlutoTransport(),
    ).openSampleCursor();
    cursor.close();
    expect(cursor.drain, throwsStateError);
    PlutoPen.debugSetRingSource(null);
  });
}

Map<String, Object?> _penPayload(String event) {
  return <String, Object?>{
    'event': event,
    'tUs': 1000,
    'xPx': 10.0,
    'yPx': 20.0,
    'rawX': 100,
    'rawY': 200,
    'pressureRaw': 2048,
    'distanceRaw': 0,
    'tiltXRaw': 900,
    'tiltYRaw': -900,
    'tool': 1,
    'buttons': 1,
    'previousButtons': 0,
  };
}
