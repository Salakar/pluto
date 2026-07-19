// GENERATED FILE. Edit config/device_profiles.json, then run
// dart tools/codegen/generate_device_profiles.dart.

/// reMarkable models accepted by this exact Pluto release.
enum RemarkableModel {
  /// reMarkable 1.
  remarkable1(wireName: 'remarkable1', codename: 'zero-gravitas'),

  /// reMarkable 2.
  remarkable2(wireName: 'remarkable2', codename: 'zero-sugar'),

  /// reMarkable Paper Pro Move.
  paperProMove(wireName: 'paperProMove', codename: 'chiappa');

  const RemarkableModel({required this.wireName, required this.codename});

  /// Exact protocol model name.
  final String wireName;

  /// Exact board codename.
  final String codename;

  /// Resolves only an exact generated model/codename pair.
  static RemarkableModel parse(String name, String codename) {
    return switch ((name, codename)) {
      ('remarkable1', 'zero-gravitas') => RemarkableModel.remarkable1,
      ('remarkable2', 'zero-sugar') => RemarkableModel.remarkable2,
      ('paperProMove', 'chiappa') => RemarkableModel.paperProMove,
      _ => throw FormatException(
        'Unsupported exact device identity: $name / $codename',
      ),
    };
  }
}
