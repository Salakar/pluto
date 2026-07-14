# Dart & Flutter API Design Best Practices

A comprehensive guide for designing clean, intuitive, and type-safe APIs in Dart and Flutter.

**Target Audience**: Junior and senior developers building packages, widget libraries, and applications.

---

## Table of Contents

1. [Philosophy: Core Principles](#1-philosophy-core-principles)
2. [Naming Conventions](#2-naming-conventions)
3. [API Design Patterns](#3-api-design-patterns)
   - 3.10 [Stream & Async Patterns](#310-stream--async-patterns)
   - 3.11 [Throttle & Debounce Patterns](#311-throttle--debounce-patterns)
4. [Type Safety](#4-type-safety)
5. [Widget Library Design](#5-widget-library-design)
6. [Modern Dart Features (Dart 3.x)](#6-modern-dart-features-dart-3x)
   - 6.6 [Enhanced Enums](#66-enhanced-enums)
7. [Common Anti-Patterns](#7-common-anti-patterns)
   - 7.9 [Widget Lifecycle Misuse](#79-widget-lifecycle-misuse)
   - 7.10 [Mutable Default Arguments](#710-mutable-default-arguments)
8. [Checklist](#8-checklist)

---

## 1. Philosophy: Core Principles

### 1.1 Principle of Least Surprise

Operations should produce results that are obvious, consistent, and predictable based on the operation's name and context.

```dart
// BAD - Surprising side effects
void loadUser() {
  fetchFromServer();  // Expected
  clearCache();       // Unexpected side effect
  logEvent();         // Unexpected side effect
}

// GOOD - Clear about what happens
Future<User> fetchUser(String id) async {
  return await _api.getUser(id);
}

// If you need multiple operations, name them clearly
Future<User> refreshUserWithCacheClear(String id) async {
  _cache.clear();
  return await _api.getUser(id);
}
```

### 1.2 Pit of Success Design

Design APIs so the easiest path is also the correct path. Make it hard to use incorrectly.

```dart
// BAD - Easy to misuse
void sendEmail(String to, String from, String subject, String body) {
  // Easy to mix up parameter order
}

// GOOD - Named parameters prevent misuse
void sendEmail({
  required String to,
  required String from,
  required String subject,
  required String body,
}) {
  // Can't accidentally swap parameters
}
```

### 1.3 Progressive Disclosure

Simple use cases should be simple. Advanced use cases can be more complex.

```dart
// Level 1: Simple - just works with defaults
final button = PrimaryButton(
  onPressed: submit,
  child: Text('Submit'),
);

// Level 2: Styling options available
final styledButton = PrimaryButton(
  onPressed: submit,
  child: Text('Submit'),
  color: Colors.blue,
  padding: EdgeInsets.all(16),
);

// Level 3: Full customization when needed
final customButton = PrimaryButton(
  onPressed: submit,
  child: Text('Submit'),
  style: ButtonStyle(
    backgroundColor: MaterialStateProperty.all(Colors.blue),
    elevation: MaterialStateProperty.all(8),
    shape: MaterialStateProperty.all(RoundedRectangleBorder(...)),
  ),
);
```

### 1.4 Consistency

Use the same name for the same thing throughout your API.

```dart
// BAD - Inconsistent terminology
class UserService {
  Future<User> getUser(String userId) => ...;
  Future<List<User>> fetchAllUsers() => ...;  // Different verb
  Future<void> removeUser(String userId) => ...;  // Different verb
}

// GOOD - Consistent terminology
class UserService {
  Future<User> getUser(String id) => ...;
  Future<List<User>> getUsers() => ...;
  Future<void> deleteUser(String id) => ...;
}
```

### 1.5 Make Invalid States Unrepresentable

Use the type system to prevent impossible states at compile time.

```dart
// BAD - Invalid states possible
class LoadingState {
  final bool isLoading;
  final String? data;
  final String? error;
  // Can have both data AND error, or neither
}

// GOOD - Only valid states possible
sealed class LoadingState<T> {}

final class Loading<T> extends LoadingState<T> {}

final class Success<T> extends LoadingState<T> {
  final T data;
  Success(this.data);
}

final class Failure<T> extends LoadingState<T> {
  final String error;
  Failure(this.error);
}
```

---

## 2. Naming Conventions

### 2.1 Type Names

Use `UpperCamelCase` for classes, enums, typedefs, extensions, and type parameters.

```dart
// Classes
class UserRepository {}
class HttpClient {}

// Enums
enum UserStatus { active, inactive, pending }

// Typedefs
typedef StringCallback = void Function(String);

// Extensions
extension DateTimeFormatting on DateTime {}

// Type parameters
class Cache<K, V> {}
```

### 2.2 Identifiers

Use `lowerCamelCase` for variables, functions, methods, and parameters.

```dart
// Variables
final userName = 'Alice';
var currentCount = 0;

// Functions and methods
void fetchUserData() {}
String formatPhoneNumber(String number) {}

// Parameters
void sendMessage(String messageText, User recipient) {}
```

### 2.3 Constants

Prefer `lowerCamelCase` for constants (modern Dart convention).

```dart
// PREFERRED - Modern style
const maxRetries = 3;
const defaultTimeout = Duration(seconds: 30);
const appVersion = '1.0.0';

// ACCEPTABLE - Legacy style (use for consistency with existing code)
const MAX_RETRIES = 3;
```

### 2.4 Files and Packages

Use `lowercase_with_underscores` for file and package names.

```
lib/
  user_repository.dart
  auth_service.dart
  models/
    user_model.dart
    order_model.dart
```

### 2.5 Acronyms

Capitalize acronyms longer than two letters like regular words.

```dart
// GOOD
class HttpClient {}
class JsonParser {}
class XmlDocument {}
class ApiService {}

// BAD
class HTTPClient {}
class JSONParser {}
class XMLDocument {}
class APIService {}

// Exception: Two-letter acronyms keep both capitals
final id = userId;
final ui = userInterface;
```

### 2.6 Boolean Properties

Use non-imperative verb phrases that read naturally in conditionals.

```dart
// GOOD - Reads naturally: if (isEmpty)
bool isEmpty = false;
bool hasElements = true;
bool canClose = true;
bool isLoading = false;
bool shouldRefresh = false;

// BAD - Imperative or awkward
bool close() {}  // Ambiguous - action or status?
bool empty = false;  // Doesn't read well: if (empty)
```

### 2.7 Methods with Side Effects

Use imperative verbs for methods that perform actions.

```dart
// GOOD - Clear actions
void add(T element) {}
void remove(T element) {}
void clear() {}
void refresh() {}
void dispose() {}
```

### 2.8 Methods Returning Values

Use noun or non-imperative verb phrases for query methods.

```dart
// GOOD
String substring(int start, [int? end]) {}
List<String> split(Pattern pattern) {}
int indexOf(String value) {}

// Avoid generic "get" prefix
String get email => _email;  // Use getter
String fetchUserName() {}    // More specific than "get"
```

### 2.9 Conversion Methods

Use consistent patterns for type conversion.

```dart
// toXxx() - Creates a NEW object with copied state
String toJson() => jsonEncode(this);
Map<String, dynamic> toMap() => {...};
String toString() => 'User($name)';

// asXxx() - Returns a VIEW backed by original
List<int> get asBytes => _data;  // View, not copy
```

### 2.10 Private Identifiers

Use a leading underscore for private members.

```dart
class UserService {
  late String _apiKey;  // Private field

  void _validateCredentials() {}  // Private method

  void authenticate() {}  // Public method
}

// Private top-level
void _initializeServices() {}
class _InternalHelper {}
```

---

## 3. API Design Patterns

### 3.1 Make Declarations Private by Default

Only expose what consumers need. Hide implementation details.

```dart
class UserService {
  // PUBLIC - The actual API
  Future<User> getUser(String id) async {
    _validateId(id);
    final data = await _fetchUserData(id);
    await _cacheUser(data);
    return User.fromJson(data);
  }

  // PRIVATE - Implementation details
  Future<Map<String, dynamic>> _fetchUserData(String id) async => ...;
  void _validateId(String id) => ...;
  Future<void> _cacheUser(User user) async => ...;
}
```

### 3.2 Prefer Required Named Parameters

Named parameters make call sites self-documenting and prevent argument order mistakes.

```dart
// BAD - Positional parameters are easy to mix up
void createUser(String email, String name, String? phone, bool active) {}

// GOOD - Named parameters are self-documenting
void createUser({
  required String email,
  required String name,
  String? phone,
  bool active = true,
}) {}

// Call site is clear
createUser(
  email: 'alice@example.com',
  name: 'Alice',
  active: true,
);
```

### 3.3 Provide Sensible Defaults

Reduce boilerplate by defaulting common cases.

```dart
class HttpClient {
  final String baseUrl;
  final Duration timeout;
  final int maxRetries;
  final Map<String, String> headers;

  HttpClient({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 30),  // Sensible default
    this.maxRetries = 3,                          // Sensible default
    this.headers = const {},                      // Sensible default
  });
}

// Simple usage
final client = HttpClient(baseUrl: 'https://api.example.com');

// Full customization available
final customClient = HttpClient(
  baseUrl: 'https://api.example.com',
  timeout: Duration(seconds: 60),
  maxRetries: 5,
  headers: {'Authorization': 'Bearer token'},
);
```

### 3.4 Use Factory Constructors for Named Variants

Provide semantic constructors for common configurations.

```dart
class Button extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final ButtonStyle style;

  const Button({
    required this.child,
    this.onPressed,
    required this.style,
  });

  // Named constructors for common variants
  factory Button.primary({
    required Widget child,
    VoidCallback? onPressed,
  }) => Button(
    child: child,
    onPressed: onPressed,
    style: _primaryStyle,
  );

  factory Button.secondary({
    required Widget child,
    VoidCallback? onPressed,
  }) => Button(
    child: child,
    onPressed: onPressed,
    style: _secondaryStyle,
  );

  factory Button.destructive({
    required Widget child,
    VoidCallback? onPressed,
  }) => Button(
    child: child,
    onPressed: onPressed,
    style: _destructiveStyle,
  );
}

// Clean, semantic usage
Button.primary(child: Text('Save'), onPressed: save);
Button.destructive(child: Text('Delete'), onPressed: delete);
```

### 3.5 Result Pattern for Error Handling

Make error handling explicit in the type system.

```dart
sealed class Result<T> {
  const Result();
}

final class Ok<T> extends Result<T> {
  final T value;
  const Ok(this.value);
}

final class Err<T> extends Result<T> {
  final AppException error;
  const Err(this.error);
}

// API returns Result - caller must handle both cases
class UserRepository {
  Future<Result<User>> getUser(String id) async {
    try {
      final response = await _api.get('/users/$id');
      return Ok(User.fromJson(response));
    } on NetworkException catch (e) {
      return Err(e);
    }
  }
}

// Caller code is explicit about error handling
final result = await userRepo.getUser('123');
switch (result) {
  case Ok(:final value):
    displayUser(value);
  case Err(:final error):
    showError(error.message);
}
```

### 3.6 Builder Pattern for Complex Configuration

For objects with many optional parameters, consider a builder.

```dart
class QueryBuilder {
  String? _table;
  final List<String> _columns = [];
  final List<String> _conditions = [];
  int? _limit;
  int? _offset;

  QueryBuilder from(String table) {
    _table = table;
    return this;
  }

  QueryBuilder select(List<String> columns) {
    _columns.addAll(columns);
    return this;
  }

  QueryBuilder where(String condition) {
    _conditions.add(condition);
    return this;
  }

  QueryBuilder limit(int count) {
    _limit = count;
    return this;
  }

  QueryBuilder offset(int count) {
    _offset = count;
    return this;
  }

  String build() {
    assert(_table != null, 'Table is required');
    final cols = _columns.isEmpty ? '*' : _columns.join(', ');
    var sql = 'SELECT $cols FROM $_table';
    if (_conditions.isNotEmpty) {
      sql += ' WHERE ${_conditions.join(' AND ')}';
    }
    if (_limit != null) sql += ' LIMIT $_limit';
    if (_offset != null) sql += ' OFFSET $_offset';
    return sql;
  }
}

// Fluent usage
final query = QueryBuilder()
  .from('users')
  .select(['id', 'name', 'email'])
  .where('active = true')
  .where('created_at > "2024-01-01"')
  .limit(10)
  .build();
```

### 3.7 Extension Methods for API Enhancement

Add functionality without modifying original classes.

```dart
extension StringValidation on String {
  bool get isValidEmail => contains('@') && contains('.');
  bool get isNotBlank => trim().isNotEmpty;
  String get capitalized => isEmpty ? '' : '${this[0].toUpperCase()}${substring(1)}';
}

extension DateTimeFormatting on DateTime {
  String get iso8601Date => toIso8601String().split('T').first;
  String get friendlyDate => '$day/$month/$year';
  bool get isToday {
    final now = DateTime.now();
    return year == now.year && month == now.month && day == now.day;
  }
}

extension ListSafety<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? get lastOrNull => isEmpty ? null : last;
  T? elementAtOrNull(int index) =>
    index >= 0 && index < length ? this[index] : null;
}

// Usage
if (email.isValidEmail) { ... }
print(createdAt.friendlyDate);
final first = items.firstOrNull;
```

### 3.8 Avoid One-Member Abstract Classes

Use function types instead.

```dart
// BAD - Unnecessary abstraction
abstract class UserValidator {
  bool validate(String email);
}

// GOOD - Function type
typedef UserValidator = bool Function(String email);

// Usage
bool validateEmail(String email) => email.contains('@');
UserValidator validator = validateEmail;
```

### 3.9 Avoid Static-Only Classes

Use top-level functions and libraries instead.

```dart
// BAD - Static-only class
class DateUtils {
  static String formatDate(DateTime date) => ...;
  static DateTime parseDate(String dateStr) => ...;
}

// GOOD - Top-level functions in a library
// lib/utils/date_utils.dart
String formatDate(DateTime date) => ...;
DateTime parseDate(String dateStr) => ...;

// Import and use
import 'package:my_app/utils/date_utils.dart';
formatDate(DateTime.now());
```

### 3.10 Stream & Async Patterns

Streams are fundamental to Dart's reactive programming model. Use them correctly to avoid memory leaks and unexpected behavior.

#### 3.10.1 Single-Subscription vs Broadcast Streams

```dart
// BAD: Broadcast when single listener expected
final controller = StreamController<Data>.broadcast(); // Unnecessary complexity

// GOOD: Default single-subscription for one listener
final controller = StreamController<Data>();

// GOOD: Broadcast only when multiple listeners needed
class DataProvider {
  final _controller = StreamController<Data>.broadcast();
  Stream<Data> get dataStream => _controller.stream;
}
```

#### 3.10.2 StreamController Lifecycle

```dart
// BAD: Forgetting to close controller
class DataService {
  final _controller = StreamController<Data>();
  Stream<Data> get stream => _controller.stream;
  // Memory leak: controller never closed!
}

// GOOD: Always close in dispose
class DataService {
  final _controller = StreamController<Data>();
  Stream<Data> get stream => _controller.stream;

  void dispose() {
    _controller.close();
  }
}
```

#### 3.10.3 Stream Subscription Cleanup

```dart
// BAD: Subscription never cancelled
class _MyWidgetState extends State<MyWidget> {
  @override
  void initState() {
    super.initState();
    dataStream.listen((data) => setState(() {}));
    // LEAK: subscription never cancelled
  }
}

// GOOD: Store and cancel subscription
class _MyWidgetState extends State<MyWidget> {
  late StreamSubscription<Data> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = dataStream.listen((data) => setState(() {}));
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
```

#### 3.10.4 Stream Error Handling

```dart
// BAD: Unhandled stream errors crash the app
stream.listen((data) => process(data));

// GOOD: Handle errors explicitly
stream.listen(
  (data) => process(data),
  onError: (error, stackTrace) => handleError(error),
  onDone: () => cleanup(),
);
```

### 3.11 Throttle & Debounce Patterns

Control the frequency of event handling for UI events like search input or scroll.

```dart
// Debounce - wait for pause in events (e.g., search input)
class Debouncer {
  final Duration delay;
  Timer? _timer;

  Debouncer({required this.delay});

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() => _timer?.cancel();
}

// Throttle - limit frequency (e.g., scroll events)
class Throttler {
  final Duration interval;
  DateTime? _lastRun;

  Throttler({required this.interval});

  void run(VoidCallback action) {
    final now = DateTime.now();
    if (_lastRun == null || now.difference(_lastRun!) >= interval) {
      _lastRun = now;
      action();
    }
  }
}

// Usage
final searchDebouncer = Debouncer(delay: Duration(milliseconds: 300));

void onSearchChanged(String query) {
  searchDebouncer.run(() => performSearch(query));
}

@override
void dispose() {
  searchDebouncer.dispose();
  super.dispose();
}
```

---

## 4. Type Safety

### 4.1 Null Safety Fundamentals

Use null safety to make optional values explicit.

```dart
class User {
  // Non-nullable - must always have a value
  final String id;
  final String email;

  // Nullable - explicitly optional
  final String? phone;
  final String? bio;

  User({
    required this.id,
    required this.email,
    this.phone,
    this.bio,
  });
}
```

### 4.2 Avoid Nullable Collections

Return empty collections instead of null.

```dart
// BAD - Forces null checks everywhere
Future<List<User>?> getUsers() async => ...;

// GOOD - Empty list means no results
Future<List<User>> getUsers() async {
  final results = await _api.fetch('/users');
  return results.map((json) => User.fromJson(json)).toList();
}

// Similarly for Maps
Map<String, String> getHeaders() => _headers ?? {};  // Never null
```

### 4.3 Use `late` Carefully

Only use `late` when initialization is guaranteed before access.

```dart
// GOOD - Guaranteed initialization
class DatabaseService {
  late final Database _database;

  Future<void> initialize() async {
    _database = await Database.open('app.db');
  }

  // Only called after initialize()
  Future<void> query(String sql) async {
    await _database.execute(sql);
  }
}

// BAD - Risk of LateInitializationError
class RiskyService {
  late String config;  // Who sets this? When?

  void process() {
    print(config);  // May crash!
  }
}
```

### 4.4 Generics for Type Safety

Use generics to maintain type information.

```dart
// Generic container
class Cache<T> {
  final Map<String, T> _items = {};

  void set(String key, T value) => _items[key] = value;
  T? get(String key) => _items[key];
  void clear() => _items.clear();
}

// Type-safe usage
final userCache = Cache<User>();
userCache.set('current', currentUser);
final user = userCache.get('current');  // User?, not dynamic

// Generic functions
T firstWhere<T>(List<T> items, bool Function(T) test, {T? orElse}) {
  for (final item in items) {
    if (test(item)) return item;
  }
  if (orElse != null) return orElse;
  throw StateError('No element');
}
```

### 4.5 Bounded Generics

Constrain type parameters when needed.

```dart
// Only accept numeric types
class Statistics<T extends num> {
  final List<T> values;

  Statistics(this.values);

  double get average => values.isEmpty
    ? 0
    : values.reduce((a, b) => (a + b) as T) / values.length;

  T get max => values.reduce((a, b) => a > b ? a : b);
  T get min => values.reduce((a, b) => a < b ? a : b);
}

// Only accept Comparable types
int compareAll<T extends Comparable<T>>(T a, T b) => a.compareTo(b);
```

### 4.6 Avoid `dynamic`

Use proper types or generics instead.

```dart
// BAD - Loses type safety
dynamic getValue() => 42;
void process(dynamic data) { ... }

// GOOD - Use generics
T getValue<T>(T defaultValue) => defaultValue;
void process<T>(T data) { ... }

// GOOD - Use Object? if truly any type
void log(Object? value) => print(value);
```

### 4.7 Custom Exception Hierarchies

Create domain-specific exceptions for better error handling.

```dart
// Base exception
abstract class AppException implements Exception {
  final String message;
  final Object? cause;

  AppException(this.message, [this.cause]);

  @override
  String toString() => message;
}

// Domain-specific exceptions
class ValidationException extends AppException {
  final Map<String, String> fieldErrors;

  ValidationException(this.fieldErrors)
    : super('Validation failed: ${fieldErrors.values.join(", ")}');
}

class NetworkException extends AppException {
  final int? statusCode;

  NetworkException(super.message, {this.statusCode, super.cause});
}

class AuthException extends AppException {
  AuthException(super.message);
}

// Usage - catch specific exceptions
try {
  await userRepo.createUser(user);
} on ValidationException catch (e) {
  showValidationErrors(e.fieldErrors);
} on NetworkException catch (e) {
  showNetworkError(e.message);
} on AuthException catch (e) {
  redirectToLogin();
}
```

### 4.8 Immutability Patterns

Prefer immutable data structures.

```dart
class User {
  final String id;
  final String name;
  final String email;
  final DateTime createdAt;
  final List<String> _roles;  // Private, make defensive copy

  User({
    required this.id,
    required this.name,
    required this.email,
    required this.createdAt,
    List<String>? roles,
  }) : _roles = List.unmodifiable(roles ?? []);

  // Defensive copy for getters
  List<String> get roles => List.of(_roles);

  // Return new instances for modifications
  User copyWith({
    String? id,
    String? name,
    String? email,
    DateTime? createdAt,
    List<String>? roles,
  }) => User(
    id: id ?? this.id,
    name: name ?? this.name,
    email: email ?? this.email,
    createdAt: createdAt ?? this.createdAt,
    roles: roles ?? _roles,
  );

  @override
  bool operator ==(Object other) =>
    identical(this, other) ||
    other is User &&
    id == other.id &&
    name == other.name &&
    email == other.email;

  @override
  int get hashCode => Object.hash(id, name, email);
}
```

---

## 5. Widget Library Design

### 5.1 Composition Over Inheritance

Build complex widgets from simple, focused components.

```dart
// BAD - Monolithic widget with too many options
class ComplexCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool showBorder;
  final bool showShadow;
  final VoidCallback? onTap;
  // ... many more parameters
}

// GOOD - Composable widgets
class Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final BoxDecoration? decoration;

  const Card({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.decoration,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: decoration ?? _defaultDecoration,
      child: child,
    );
  }
}

class CardHeader extends StatelessWidget {
  final Widget? leading;
  final Widget title;
  final Widget? trailing;

  const CardHeader({
    this.leading,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (leading != null) ...[leading!, SizedBox(width: 12)],
        Expanded(child: title),
        if (trailing != null) trailing!,
      ],
    );
  }
}

// Usage - Compose freely
Card(
  child: Column(
    children: [
      CardHeader(
        leading: Icon(Icons.person),
        title: Text('John Doe'),
        trailing: IconButton(icon: Icon(Icons.edit), onPressed: edit),
      ),
      Text('Card content here'),
    ],
  ),
)
```

### 5.2 Use `const` Constructors

Enable compile-time optimization with const constructors.

```dart
class InfoCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;

  const InfoCard({  // const constructor
    required this.title,
    required this.description,
    required this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(description),
      ),
    );
  }
}

// Usage - const where possible
const InfoCard(
  title: 'Welcome',
  description: 'Thanks for joining us',
  icon: Icons.celebration,
)
```

### 5.3 Design Token Pattern

Centralize design values for consistency.

```dart
abstract class AppTokens {
  // Spacing
  static const spacing4 = 4.0;
  static const spacing8 = 8.0;
  static const spacing12 = 12.0;
  static const spacing16 = 16.0;
  static const spacing24 = 24.0;
  static const spacing32 = 32.0;

  // Border radius
  static const radiusSmall = 4.0;
  static const radiusMedium = 8.0;
  static const radiusLarge = 16.0;
  static const radiusFull = 999.0;

  // Animation durations
  static const durationFast = Duration(milliseconds: 150);
  static const durationNormal = Duration(milliseconds: 300);
  static const durationSlow = Duration(milliseconds: 500);

  // Elevation
  static const elevationNone = 0.0;
  static const elevationLow = 2.0;
  static const elevationMedium = 4.0;
  static const elevationHigh = 8.0;
}

// Usage in widgets
Container(
  padding: EdgeInsets.all(AppTokens.spacing16),
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
  ),
)
```

### 5.4 Support Theming

Integrate with Flutter's theming system.

```dart
class AppButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;

  const AppButton({
    required this.child,
    this.onPressed,
    this.variant = AppButtonVariant.primary,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _getColors(theme, variant);

    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: colors.background,
        foregroundColor: colors.foreground,
      ),
      child: child,
    );
  }

  _ButtonColors _getColors(ThemeData theme, AppButtonVariant variant) {
    return switch (variant) {
      AppButtonVariant.primary => _ButtonColors(
        background: theme.colorScheme.primary,
        foreground: theme.colorScheme.onPrimary,
      ),
      AppButtonVariant.secondary => _ButtonColors(
        background: theme.colorScheme.secondary,
        foreground: theme.colorScheme.onSecondary,
      ),
      AppButtonVariant.destructive => _ButtonColors(
        background: theme.colorScheme.error,
        foreground: theme.colorScheme.onError,
      ),
    };
  }
}

enum AppButtonVariant { primary, secondary, destructive }

class _ButtonColors {
  final Color background;
  final Color foreground;
  _ButtonColors({required this.background, required this.foreground});
}
```

### 5.5 Accessibility Support

Build accessibility into your widgets from the start.

```dart
class TappableCard extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final String semanticLabel;
  final bool enabled;

  const TappableCard({
    required this.child,
    required this.onTap,
    required this.semanticLabel,
    this.enabled = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: enabled,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 48,   // Minimum touch target
            minHeight: 48,  // Minimum touch target
          ),
          child: child,
        ),
      ),
    );
  }
}
```

### 5.6 Split Large Widgets

Decompose large `build` methods for better performance and maintainability.

```dart
// BAD - Large monolithic widget
class ProfilePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Profile')),
      body: Column(
        children: [
          // 50+ lines of avatar code
          // 30+ lines of info code
          // 40+ lines of stats code
          // 20+ lines of actions code
        ],
      ),
    );
  }
}

// GOOD - Decomposed into focused widgets
class ProfilePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Profile')),
      body: Column(
        children: [
          const _ProfileAvatar(),
          const _ProfileInfo(),
          const _ProfileStats(),
          const _ProfileActions(),
        ],
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar();

  @override
  Widget build(BuildContext context) {
    // Focused avatar implementation
  }
}

class _ProfileInfo extends StatelessWidget {
  const _ProfileInfo();

  @override
  Widget build(BuildContext context) {
    // Focused info implementation
  }
}
// ... etc
```

---

## 6. Modern Dart Features (Dart 3.x)

### 6.1 Records

Lightweight, immutable data structures for bundling values.

```dart
// Basic record
(String, int) getNameAndAge() {
  return ('Alice', 30);
}

// Named fields for clarity
({String name, int age, String email}) getUserInfo() {
  return (name: 'Alice', age: 30, email: 'alice@example.com');
}

// Destructuring
void main() {
  final (name, age) = getNameAndAge();
  print('$name is $age years old');

  final (:name, :age, :email) = getUserInfo();
  print('$name ($email)');
}

// Use records for multiple return values instead of tuples/lists
(bool success, String? error) validate(String input) {
  if (input.isEmpty) return (false, 'Input required');
  if (input.length < 3) return (false, 'Too short');
  return (true, null);
}
```

**When to use Records vs Classes:**

| Records | Classes |
|---------|---------|
| Simple data bundling | Domain entities |
| Multiple return values | Behavior + data |
| Temporary/local data | Public API types |
| Structural typing | Nominal typing |

### 6.2 Pattern Matching

Powerful destructuring and control flow.

```dart
// Switch expressions
String describe(Object obj) => switch (obj) {
  int n when n < 0 => 'negative',
  int n when n == 0 => 'zero',
  int n => 'positive: $n',
  String s when s.isEmpty => 'empty string',
  String s => 'string: $s',
  List l when l.isEmpty => 'empty list',
  List l => 'list with ${l.length} items',
  _ => 'unknown',
};

// Pattern matching in if statements
void process(Object? value) {
  if (value case String s when s.isNotEmpty) {
    print('Non-empty string: $s');
  }

  if (value case [int first, int second, ...]) {
    print('List starting with $first, $second');
  }
}

// Destructuring in variable declarations
void parsePoint(Map<String, dynamic> json) {
  if (json case {'x': int x, 'y': int y}) {
    print('Point($x, $y)');
  }
}

// List patterns
void processItems(List<int> items) {
  switch (items) {
    case []:
      print('Empty');
    case [int single]:
      print('Single: $single');
    case [int first, int second]:
      print('Pair: $first, $second');
    case [int first, ...List<int> rest]:
      print('First: $first, rest: $rest');
  }
}
```

### 6.3 Sealed Classes

Create closed type hierarchies with exhaustive pattern matching.

```dart
sealed class NetworkResult<T> {}

final class Success<T> extends NetworkResult<T> {
  final T data;
  Success(this.data);
}

final class Loading<T> extends NetworkResult<T> {}

final class Error<T> extends NetworkResult<T> {
  final String message;
  final int? statusCode;
  Error(this.message, {this.statusCode});
}

// Compiler enforces exhaustive handling
Widget buildContent(NetworkResult<User> result) {
  return switch (result) {
    Success(:final data) => UserCard(user: data),
    Loading() => CircularProgressIndicator(),
    Error(:final message) => ErrorWidget(message: message),
    // If you miss a case, compiler error!
  };
}

// Event handling with sealed classes
sealed class UserEvent {}
final class UserCreated extends UserEvent { final String id; UserCreated(this.id); }
final class UserUpdated extends UserEvent { final User user; UserUpdated(this.user); }
final class UserDeleted extends UserEvent { final String id; UserDeleted(this.id); }

void handleEvent(UserEvent event) {
  switch (event) {
    case UserCreated(:final id):
      print('Created: $id');
    case UserUpdated(:final user):
      print('Updated: ${user.name}');
    case UserDeleted(:final id):
      print('Deleted: $id');
  }
}
```

#### Nested Sealed Class Hierarchies

Use nested sealed classes for multi-level exhaustiveness checking.

```dart
// Nested sealed classes for multi-level exhaustiveness
sealed class UIEvent {}

sealed class GestureEvent extends UIEvent {}
final class TapEvent extends GestureEvent {
  final Offset position;
  TapEvent(this.position);
}
final class DragEvent extends GestureEvent {
  final Offset start;
  final Offset current;
  DragEvent(this.start, this.current);
}

sealed class KeyboardEvent extends UIEvent {}
final class KeyDownEvent extends KeyboardEvent {
  final String key;
  KeyDownEvent(this.key);
}
final class KeyUpEvent extends KeyboardEvent {
  final String key;
  KeyUpEvent(this.key);
}

// Exhaustive at top level
String describeEvent(UIEvent event) => switch (event) {
  GestureEvent() => 'Gesture: ${describeGesture(event)}',
  KeyboardEvent() => 'Keyboard: ${event.key}',
};

// Exhaustive at nested level
String describeGesture(GestureEvent event) => switch (event) {
  TapEvent(:final position) => 'Tap at $position',
  DragEvent(:final start, :final current) => 'Drag from $start to $current',
};
```

**Note:** When switching on a sealed type, the compiler knows all possible subtypes and enforces exhaustiveness. This works transitively through nested sealed hierarchies.

### 6.4 Class Modifiers

Control how classes can be extended and implemented.

```dart
// sealed - Known subtypes, exhaustive matching
sealed class Shape {}
class Circle extends Shape { final double radius; Circle(this.radius); }
class Rectangle extends Shape { final double width, height; Rectangle(this.width, this.height); }

// final - Cannot be extended or implemented outside library
final class ImmutablePoint {
  final double x, y;
  const ImmutablePoint(this.x, this.y);
}

// base - Can be extended but not implemented
base class Entity {
  final String id;
  Entity(this.id);

  @override
  bool operator ==(Object other) => other is Entity && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

// interface - Can be implemented but not extended
interface class DataSource {
  Future<Map<String, dynamic>> fetch(String id);
  Future<void> save(String id, Map<String, dynamic> data);
}

// mixin - Can only be mixed in
mixin Logging {
  void log(String message) => print('[LOG] $message');
}

class MyService extends Entity with Logging {
  MyService(super.id);
}
```

**Modifier Guide:**

| Modifier | Extend? | Implement? | Use Case |
|----------|---------|------------|----------|
| `sealed` | Same library only | No | Exhaustive types |
| `final` | No | No | Stable implementations |
| `base` | Yes (must be base/final) | No | Require inheritance |
| `interface` | No | Yes | Pure contracts |
| `mixin` | N/A | Mixed in | Reusable behavior |

### 6.5 Extension Types

Zero-cost type wrappers for type safety.

```dart
// Type-safe IDs without runtime overhead
extension type UserId(String id) {
  bool get isValid => id.isNotEmpty;
  String display() => 'User#$id';
}

extension type OrderId(String id) {
  bool get isValid => id.startsWith('ORD-');
}

// Now these can't be mixed up
void processOrder(OrderId orderId, UserId userId) {
  // Type-safe at compile time, zero overhead at runtime
}

// Usage
final userId = UserId('123');
final orderId = OrderId('ORD-456');

// processOrder(userId, orderId);  // COMPILE ERROR - types swapped!
processOrder(orderId, userId);     // Correct

// Validated wrapper
extension type Email._(String _value) {
  static Email? tryParse(String input) {
    if (!input.contains('@')) return null;
    return Email._(input);
  }

  String get domain => _value.split('@').last;

  @override
  String toString() => _value;
}

// Forces validation at creation
final email = Email.tryParse(userInput);
if (email != null) {
  sendEmail(to: email);  // Guaranteed valid
}
```

### 6.6 Enhanced Enums

Dart 3.x enums can have fields, methods, and implement interfaces. Use them to replace stringly-typed patterns.

```dart
// Enhanced enum with fields and methods
enum HttpMethod {
  get('GET', false),
  post('POST', true),
  put('PUT', true),
  patch('PATCH', true),
  delete('DELETE', false);

  final String value;
  final bool hasBody;

  const HttpMethod(this.value, this.hasBody);

  bool get isReadOnly => this == get;
  bool get isModifying => this != get;
}

// Usage - type-safe with IDE support
void request(HttpMethod method) {
  if (method.hasBody) {
    // Prepare request body
  }
}

// Enum implementing interface
enum JsonType implements Comparable<JsonType> {
  string(1),
  number(2),
  boolean(3),
  array(4),
  object(5),
  null_(0);

  final int sortOrder;
  const JsonType(this.sortOrder);

  @override
  int compareTo(JsonType other) => sortOrder.compareTo(other.sortOrder);
}
```

**When to use Enum vs Sealed Class:**

| Use Enum | Use Sealed Class |
|----------|------------------|
| Fixed set of values known at compile time | Need different data per variant |
| All variants have same shape/fields | Variants have different fields |
| Simple behavior variations | Complex hierarchies |
| Value-based identity | Reference-based identity |

---

## 7. Common Anti-Patterns

### 7.1 Boolean Blindness

Using booleans where enums would be clearer.

```dart
// BAD - What does true mean?
Future<bool> deleteUser(String id) async { ... }

if (await deleteUser('123')) {
  // Success? Found? Deleted? Who knows!
}

// GOOD - Explicit result
enum DeleteResult { deleted, notFound, unauthorized }

Future<DeleteResult> deleteUser(String id) async { ... }

switch (await deleteUser('123')) {
  case DeleteResult.deleted:
    showSuccess('User deleted');
  case DeleteResult.notFound:
    showError('User not found');
  case DeleteResult.unauthorized:
    showError('Permission denied');
}
```

### 7.2 Stringly-Typed APIs

Using strings where dedicated types should exist.

```dart
// BAD - Easy to pass wrong values
void setUserStatus(String userId, String status) {
  // What are valid statuses? "active"? "Active"? "ACTIVE"?
}

setUserStatus('123', 'actve');  // Typo goes unnoticed!

// GOOD - Type-safe
enum UserStatus { active, inactive, suspended, deleted }

void setUserStatus(String userId, UserStatus status) { ... }

setUserStatus('123', UserStatus.active);  // Type-safe
```

### 7.3 God Objects

Classes that do too much.

```dart
// BAD - Does everything
class UserManager {
  // Authentication
  Future<bool> login(String email, String password) { ... }
  Future<void> logout() { ... }

  // User data
  Future<User> getUser(String id) { ... }
  Future<void> updateUser(User user) { ... }

  // Permissions
  Future<bool> hasPermission(String permission) { ... }

  // Settings
  Future<void> updateSettings(Settings s) { ... }

  // Notifications
  Future<void> subscribe() { ... }

  // ... and more
}

// GOOD - Single responsibility
class AuthService {
  Future<bool> login(String email, String password) { ... }
  Future<void> logout() { ... }
}

class UserRepository {
  Future<User> getUser(String id) { ... }
  Future<void> updateUser(User user) { ... }
}

class PermissionService {
  Future<bool> hasPermission(String permission) { ... }
}

// Compose when needed
class UserController {
  final AuthService auth;
  final UserRepository users;

  UserController({required this.auth, required this.users});
}
```

### 7.4 Leaky Abstractions

Exposing implementation details through the API.

```dart
// BAD - Leaks database details
class UserRepository {
  Future<User> getUserWithSqlQuery(String sql) { ... }
  Future<void> updateUserInTransaction(User user) { ... }
  void clearDatabaseCache() { ... }
}

// GOOD - Implementation-agnostic
class UserRepository {
  Future<User?> getUser(String id) { ... }
  Future<void> updateUser(User user) { ... }
  Future<void> deleteUser(String id) { ... }
}
```

### 7.5 Optional Parameter Overload

Too many optional parameters make APIs confusing.

```dart
// BAD - Too many booleans
Widget buildCard({
  bool showHeader = true,
  bool showFooter = false,
  bool showBorder = true,
  bool showShadow = true,
  bool isExpanded = false,
  bool isSelectable = false,
  bool showDivider = false,
}) { ... }

// GOOD - Configuration object or composition
class CardConfig {
  final bool showBorder;
  final bool showShadow;
  final CardHeaderConfig? header;
  final CardFooterConfig? footer;

  const CardConfig({
    this.showBorder = true,
    this.showShadow = true,
    this.header,
    this.footer,
  });
}

Widget buildCard(CardConfig config) { ... }

// Or use composition
Column(
  children: [
    if (showHeader) CardHeader(...),
    CardContent(...),
    if (showFooter) CardFooter(...),
  ],
)
```

### 7.6 Callback Hell

Deeply nested callbacks make code unreadable.

```dart
// BAD - Callback pyramid
void loadUserData() {
  fetchUser((user) {
    fetchOrders(user.id, (orders) {
      fetchPayments(orders, (payments) {
        updateUI(user, orders, payments);
      });
    });
  });
}

// GOOD - Async/await
Future<void> loadUserData() async {
  final user = await fetchUser();
  final orders = await fetchOrders(user.id);
  final payments = await fetchPayments(orders);
  updateUI(user, orders, payments);
}

// Even better - parallel when possible
Future<void> loadUserData() async {
  final user = await fetchUser();
  final (orders, payments) = await (
    fetchOrders(user.id),
    fetchPayments(user.id),
  ).wait;
  updateUI(user, orders, payments);
}
```

### 7.7 Ignoring Null Safety

Fighting against null safety instead of embracing it.

```dart
// BAD - Excessive null assertions
String? name;
print(name!.toUpperCase());  // Crashes if null

// BAD - Overuse of late
late String config;  // Risk of LateInitializationError

// GOOD - Embrace null safety
String? name;
print(name?.toUpperCase() ?? 'Unknown');

// GOOD - Use required for mandatory values
void createUser({required String name}) { ... }
```

### 7.8 String-Based Event Systems

Using strings to identify event types loses type safety and IDE support.

```dart
// BAD - String-based event types
class EventSystem {
  final Map<String, List<EventListener>> _listeners = {};

  /// Adds an event listener for the specified [eventType].
  ///
  /// Common event types: 'tap', 'tapDown', 'tapUp', 'longPress',
  /// 'longPressStart', 'doubleTap', 'panStart', 'panUpdate', 'panEnd', 'hover'.
  void addEventListener(String eventType, EventListener listener) {
    _listeners.putIfAbsent(eventType, () => []).add(listener);
  }
}

// Problems:
// - Typos compile but fail at runtime: addEventListener('tapp', ...)
// - No IDE autocomplete for event types
// - Event data is untyped (dynamic or Object?)
// - No compile-time verification of handler signatures

// GOOD - Explicitly named streams with fully typed events
class InteractiveElement {
  final _tapController = StreamController<TapEvent>.broadcast();
  final _dragController = StreamController<DragEvent>.broadcast();
  final _hoverController = StreamController<HoverEvent>.broadcast();
  final _pointerController = StreamController<PointerEvent>.broadcast();

  Stream<TapEvent> get onTap => _tapController.stream;
  Stream<DragEvent> get onDrag => _dragController.stream;
  Stream<HoverEvent> get onHover => _hoverController.stream;
  Stream<PointerEvent> get onPointer => _pointerController.stream;

  void dispose() {
    _tapController.close();
    _dragController.close();
    _hoverController.close();
    _pointerController.close();
  }
}

// Typed event classes
class TapEvent {
  final Offset position;
  final int tapCount;
  TapEvent({required this.position, this.tapCount = 1});
}

class DragEvent {
  final Offset start;
  final Offset current;
  final Offset delta;
  DragEvent({required this.start, required this.current, required this.delta});
}

// Usage - fully type-safe with IDE support
element.onTap.listen((event) {
  print('Tapped at ${event.position}');  // event is TapEvent
});

element.onDrag.listen((event) {
  print('Dragged ${event.delta}');  // event is DragEvent
});
```

**Benefits of typed streams:**
- Compile-time verification of event names
- Full IDE autocomplete and documentation
- Type-safe event data with known properties
- Consistent with Dart's Stream-based APIs (e.g., `Stream<T>.listen()`)

### 7.9 Widget Lifecycle Misuse

Flutter widget lifecycle issues cause memory leaks and crashes. Handle async operations and timers carefully.

#### 7.9.1 Async Context Access

```dart
// BAD: Context may be invalid after await
Future<void> _submit() async {
  await api.submit(data);
  Navigator.of(context).pop(); // Context may be stale!
}

// GOOD: Check mounted or capture navigator
Future<void> _submit() async {
  final navigator = Navigator.of(context);
  await api.submit(data);
  if (mounted) navigator.pop();
}
```

#### 7.9.2 Timer Leaks

```dart
// BAD: Timer never cancelled
@override
void initState() {
  super.initState();
  Timer.periodic(Duration(seconds: 1), (_) => refresh());
}

// GOOD: Store and cancel timer
late Timer _timer;

@override
void initState() {
  super.initState();
  _timer = Timer.periodic(Duration(seconds: 1), (_) {
    if (mounted) refresh();
  });
}

@override
void dispose() {
  _timer.cancel();
  super.dispose();
}
```

### 7.10 Mutable Default Arguments

Default values in Dart are evaluated once, not per-call. Mutable defaults can cause subtle bugs.

```dart
// BAD: Mutable default shared across instances
class Config {
  final List<String> tags;
  Config({List<String>? tags}) : tags = tags ?? [];
  // Empty list may be shared!
}

// GOOD: Create new instance each time
class Config {
  final List<String> tags;
  Config({List<String>? tags}) : tags = List.of(tags ?? const []);
}

// Also applies to Maps and other mutable types
// BAD
class Settings {
  final Map<String, dynamic> options;
  Settings({Map<String, dynamic>? options}) : options = options ?? {};
}

// GOOD
class Settings {
  final Map<String, dynamic> options;
  Settings({Map<String, dynamic>? options}) : options = Map.of(options ?? const {});
}
```

---

## 8. Checklist

### API Design Checklist

Use this checklist when reviewing your API design:

#### Naming
- [ ] Class names are `UpperCamelCase` and use nouns
- [ ] Method names are `lowerCamelCase` and use verbs for actions
- [ ] Boolean properties start with `is`, `has`, `can`, `should`
- [ ] Acronyms > 2 letters are capitalized like words (`HttpClient`)
- [ ] No abbreviations unless universally known (`id`, `url`)
- [ ] Consistent terminology throughout (`get`/`set` OR `fetch`/`save`, not mixed)

#### Type Safety
- [ ] No `dynamic` unless absolutely necessary
- [ ] Generics used for type-safe collections and functions
- [ ] Null safety embraced (nullable only when truly optional)
- [ ] Sealed classes for exhaustive type hierarchies
- [ ] Extension types for type-safe wrappers
- [ ] No stringly-typed APIs (use enums/classes)

#### API Usability
- [ ] Simple use cases are simple (progressive disclosure)
- [ ] Named parameters for optional configuration
- [ ] Sensible defaults provided
- [ ] Factory constructors for common variants
- [ ] `const` constructors where possible
- [ ] Private by default, explicit public API

#### Error Handling
- [ ] Consistent error handling approach
- [ ] Result types for expected failures
- [ ] Custom exceptions for domain errors
- [ ] Clear error messages with actionable information
- [ ] No silent failures

#### Documentation
- [ ] `///` doc comments on all public members
- [ ] First sentence is a summary
- [ ] `[identifier]` references for auto-linking
- [ ] Code examples for non-obvious APIs
- [ ] Documented exceptions/errors

#### Widget Design
- [ ] Composition over inheritance
- [ ] Small, focused widgets
- [ ] `const` constructors used
- [ ] Theme integration
- [ ] Accessibility support (Semantics)
- [ ] Minimum 48x48 touch targets

#### Modern Dart
- [ ] Records for simple data bundling
- [ ] Pattern matching for control flow
- [ ] Sealed classes for closed hierarchies
- [ ] Appropriate class modifiers (`final`, `sealed`, `base`)
- [ ] Extension types for zero-cost wrappers

#### Avoiding Anti-Patterns
- [ ] No boolean blindness (use enums)
- [ ] No god objects (single responsibility)
- [ ] No leaky abstractions
- [ ] No callback hell (use async/await)
- [ ] No optional parameter overload

#### Async/Streams
- [ ] StreamControllers closed in dispose
- [ ] StreamSubscriptions cancelled in dispose
- [ ] Timers cancelled in dispose
- [ ] Context checked with `mounted` after async gaps
- [ ] Stream errors handled explicitly

#### Modern Dart
- [ ] Enhanced enums used instead of string constants
- [ ] Sealed class hierarchies for exhaustive matching
- [ ] Pattern matching with guards where appropriate

---

## Quick Reference

### Do This

```dart
// Type-safe sealed class hierarchy
sealed class ApiResult<T> {}
final class Success<T> extends ApiResult<T> { final T data; Success(this.data); }
final class Failure<T> extends ApiResult<T> { final String error; Failure(this.error); }

// Named parameters with defaults
void createUser({
  required String email,
  required String name,
  UserRole role = UserRole.member,
}) { ... }

// Extension types for domain safety
extension type UserId(String _) {}
extension type OrderId(String _) {}

// Records for multiple returns
(User user, List<Order> orders) fetchUserWithOrders(String id) { ... }

// Pattern matching
Widget build(ApiResult<User> result) => switch (result) {
  Success(:final data) => UserCard(data),
  Failure(:final error) => ErrorView(error),
};
```

### Don't Do This

```dart
// Stringly-typed
void setStatus(String status) { ... }

// Boolean blindness
Future<bool> process() { ... }

// God object
class AppManager {
  // Auth + Users + Settings + Cache + ...
}

// Fighting null safety
String? value;
print(value!);  // Crashes

// Dynamic everywhere
dynamic data = fetchData();
```

---

## Additional Resources

- [Effective Dart](https://dart.dev/effective-dart) - Official Dart style guide
- [Flutter API Design Guidelines](https://docs.flutter.dev/development/ui/widgets/design) - Flutter widget design
- [Dart Language Tour](https://dart.dev/language) - Complete Dart 3.x features
- [pub.dev](https://pub.dev) - Study popular package APIs (riverpod, dio, freezed)

---