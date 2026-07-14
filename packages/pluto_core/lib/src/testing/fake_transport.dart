import 'dart:async';

import '../transport.dart';

/// A single fake transport invocation captured for assertions.
final class RecordedInvocation {
  /// Creates a captured invocation record.
  const RecordedInvocation({
    required this.channel,
    required this.method,
    this.arguments,
  });

  /// The channel invoked.
  final String channel;

  /// The method invoked.
  final String method;

  /// Structured arguments passed to the invocation.
  final Object? arguments;
}

/// Scripted in-memory [PlutoTransport] for unit tests.
final class FakePlutoTransport implements PlutoTransport {
  final Map<String, FutureOr<Object?> Function(Object? arguments)> _handlers =
      <String, FutureOr<Object?> Function(Object? arguments)>{};
  final Map<String, StreamController<Object?>> _controllers =
      <String, StreamController<Object?>>{};
  final List<RecordedInvocation> _invocations = <RecordedInvocation>[];

  /// Registers [handler] for a channel/method pair.
  void onInvoke(
    String channel,
    String method,
    FutureOr<Object?> Function(Object? arguments) handler,
  ) {
    _handlers[_key(channel, method)] = handler;
  }

  /// Pushes [event] or [error] to listeners on [channel].
  void emitEvent(String channel, Object? event, {Object? error}) {
    // ignore: close_sinks, controllers are owned by the fake and closed by close().
    final StreamController<Object?> controller = _controllerFor(channel);
    if (error == null) {
      controller.add(event);
    } else {
      controller.addError(error);
    }
  }

  /// Every invocation made through this fake, in order.
  List<RecordedInvocation> get invocations =>
      List<RecordedInvocation>.unmodifiable(_invocations);

  @override
  Stream<Object?> events({required String channel, Object? arguments}) {
    return _controllerFor(channel).stream;
  }

  @override
  Future<T?> invoke<T>({
    required String channel,
    required String method,
    Object? arguments,
  }) async {
    _invocations.add(
      RecordedInvocation(
        channel: channel,
        method: method,
        arguments: arguments,
      ),
    );
    final FutureOr<Object?> Function(Object? arguments)? handler =
        _handlers[_key(channel, method)];
    if (handler == null) {
      throw StateError('No fake handler registered for $channel/$method.');
    }
    final Object? value = await handler(arguments);
    if (value == null) {
      return null;
    }
    if (value is T) {
      return value as T;
    }
    throw StateError(
      'Fake handler for $channel/$method returned ${value.runtimeType}.',
    );
  }

  /// Closes all event controllers.
  Future<void> close() async {
    for (final StreamController<Object?> controller in _controllers.values) {
      await controller.close();
    }
  }

  StreamController<Object?> _controllerFor(String channel) {
    return _controllers.putIfAbsent(
      channel,
      // ignore: close_sinks, controllers are closed by close().
      () => StreamController<Object?>.broadcast(),
    );
  }

  static String _key(String channel, String method) => '$channel::$method';
}
