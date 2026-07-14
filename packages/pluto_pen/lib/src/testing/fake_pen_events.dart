import 'dart:async';
import 'dart:typed_data';

import 'package:pluto_core/testing.dart';

import '../pen_events.dart';
import '../pen_sample.dart';

/// Fake pen event source for host unit tests.
final class FakePenEvents implements PenEvents {
  /// Creates a fake event source for [events].
  const FakePenEvents(this.events);

  @override
  final Stream<PenEvent> events;

  /// Creates a fake source that emits [sample] as a move event.
  factory FakePenEvents.single(PenSample sample) {
    return FakePenEvents(Stream<PenEvent>.value(PenMoveEvent(sample: sample)));
  }
}

/// Fake ring source backed by [PenRingWriter].
final class FakePenRingSource implements PenRingSource {
  /// Creates a fake ring source from [writer].
  const FakePenRingSource(this.writer);

  /// Writer that owns the backing memory.
  final PenRingWriter writer;

  @override
  ByteData get data => writer.data;

  /// Installs this source as the cursor source for [PlutoPen.openSampleCursor].
  void install() {
    PlutoPen.debugSetRingSource(this);
  }
}
