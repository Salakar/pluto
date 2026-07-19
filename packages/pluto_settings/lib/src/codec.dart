import 'package:pluto_core/pluto_core.dart';

/// Converts a protocol value into a string-keyed map.
Map<String, Object?> stringMap(Object? value, String path) {
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        throw FormatException('Expected every $path key to be a string.');
      }
      result[key] = entry.value;
    }
    return result;
  }
  throw FormatException('Expected $path to be a map.');
}

/// Requires exactly [required] plus any present keys from [optional].
void requireExactKeys(
  Map<String, Object?> map,
  String path, {
  required Set<String> required,
  Set<String> optional = const <String>{},
}) {
  final Set<String> actual = map.keys.toSet();
  final Set<String> allowed = <String>{...required, ...optional};
  if (!actual.containsAll(required) || !allowed.containsAll(actual)) {
    throw FormatException(
      'Expected exact $path keys; required '
      '${required.toList()..sort()}, optional ${optional.toList()..sort()}, '
      'got ${actual.toList()..sort()}.',
    );
  }
}

/// Converts a protocol value into an object list.
List<Object?> objectList(Object? value, String path) {
  if (value is List<Object?>) {
    return value;
  }
  throw FormatException('Expected $path to be a list.');
}

/// Reads a required string field.
String stringAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected $key to be a string.');
}

/// Reads an optional string field.
String? optionalStringAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  throw FormatException('Expected $key to be a string.');
}

/// Reads a required integer field.
int intAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Expected $key to be an int.');
}

/// Reads an optional integer field.
int? optionalIntAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  throw FormatException('Expected $key to be an int.');
}

/// Reads a required numeric field as a double.
double doubleAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value.toDouble();
  }
  if (value is double) {
    return value;
  }
  throw FormatException('Expected $key to be a number.');
}

/// Reads an optional numeric field as a double.
double? optionalDoubleAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value.toDouble();
  }
  if (value is double) {
    return value;
  }
  throw FormatException('Expected $key to be a number.');
}

/// Reads a required boolean field.
bool boolAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('Expected $key to be a bool.');
}

/// Invokes a settings method and discards the response.
Future<void> invokeVoid(
  PlutoTransport transport,
  String method, {
  Object? arguments,
}) async {
  await transport.invoke<Object?>(
    channel: plutoSettingsChannel,
    method: method,
    arguments: arguments,
  );
}
