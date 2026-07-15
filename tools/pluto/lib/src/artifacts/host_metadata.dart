/// Returns whether [path] contains a host-only metadata component.
///
/// Pluto artifacts are portable Linux payloads. Finder metadata and macOS
/// AppleDouble resource forks are never application content.
bool isHostMetadataPath(String path) => path
    .replaceAll('\\', '/')
    .split('/')
    .any(
      (String segment) =>
          segment == '.DS_Store' ||
          segment == '.AppleDouble' ||
          segment.startsWith('._'),
    );
