/// A GLIBC symbol version such as `2.39`.
final class GlibcVersion implements Comparable<GlibcVersion> {
  /// Creates a GLIBC version.
  const GlibcVersion(this.major, this.minor);

  /// Major version component.
  final int major;

  /// Minor version component.
  final int minor;

  /// Parses `GLIBC_2.39` or `2.39`.
  static GlibcVersion? tryParse(String value) {
    final RegExpMatch? match = RegExp(
      r'(?:GLIBC_)?(\d+)\.(\d+)',
    ).firstMatch(value);
    if (match == null) {
      return null;
    }
    return GlibcVersion(int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  @override
  int compareTo(GlibcVersion other) {
    final int majorCompare = major.compareTo(other.major);
    if (majorCompare != 0) {
      return majorCompare;
    }
    return minor.compareTo(other.minor);
  }

  @override
  bool operator ==(Object other) {
    return other is GlibcVersion &&
        other.major == major &&
        other.minor == minor;
  }

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => '$major.$minor';
}

/// Highest GLIBC version supported by the current target firmware.
const GlibcVersion deviceGlibcCeiling = GlibcVersion(2, 39);

/// Extracts every GLIBC symbol version mentioned in objdump-like [text].
List<GlibcVersion> parseGlibcVersions(String text) {
  final RegExp pattern = RegExp(r'GLIBC_(\d+)\.(\d+)');
  return pattern
      .allMatches(text)
      .map(
        (RegExpMatch match) => GlibcVersion(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
        ),
      )
      .toList(growable: false);
}

/// Returns the highest GLIBC version mentioned in [text], if any.
GlibcVersion? maxGlibcVersion(String text) {
  final List<GlibcVersion> versions = parseGlibcVersions(text);
  if (versions.isEmpty) {
    return null;
  }
  versions.sort();
  return versions.last;
}

/// Returns true when [version] can run on the target device.
bool isGlibcVersionSupported(
  GlibcVersion version, {
  GlibcVersion ceiling = deviceGlibcCeiling,
}) {
  return version.compareTo(ceiling) <= 0;
}
