#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SELF="tools/build/test/native-cutover-residue-test.sh"
PLAN="docs/remove-appload.md"
PATTERN='appload|qtfb|xovi|pluto-arm|pluto-apploadctl|codex-armv7|build-codex-armv7|materialize-codex-armv7'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-native-residue-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cd "$ROOT"

# The user-requested cutover plan is the sole historical inventory. Active
# source, tools, tests, docs, and path names must not preserve the removed
# implementation or an alias for it.
git ls-files -co --exclude-standard -z > "$TMP/files.z"

while IFS= read -r -d '' path; do
  case "$path" in
    "$PLAN" | "$SELF") continue ;;
  esac
  # `git ls-files -c` includes tracked paths deleted by this hard cut until the
  # deletion is committed. A path that no longer exists is the desired state,
  # not repository residue.
  [[ -e "$path" || -L "$path" ]] || continue
  if [[ "$path" =~ [Aa][Pp][Pp][Ll][Oo][Aa][Dd] ||
    "$path" =~ [Qq][Tt][Ff][Bb] ||
    "$path" =~ [Xx][Oo][Vv][Ii] ||
    "$path" =~ [Pp][Ll][Uu][Tt][Oo]-[Aa][Rr][Mm] ||
    "$path" =~ [Pp][Ll][Uu][Tt][Oo]-[Aa][Pp][Pp][Ll][Oo][Aa][Dd][Cc][Tt][Ll] ||
    "$path" =~ [Cc][Oo][Dd][Ee][Xx]-[Aa][Rr][Mm][Vv]7 ||
    "$path" =~ [Bb][Uu][Ii][Ll][Dd]-[Cc][Oo][Dd][Ee][Xx]-[Aa][Rr][Mm][Vv]7 ||
    "$path" =~ [Mm][Aa][Tt][Ee][Rr][Ii][Aa][Ll][Ii][Zz][Ee]-[Cc][Oo][Dd][Ee][Xx]-[Aa][Rr][Mm][Vv]7 ]]; then
    printf '%s\n' "$path" >> "$TMP/path-violations"
    continue
  fi
  [[ -f "$path" && ! -L "$path" ]] || continue
  if LC_ALL=C grep -IEni "$PATTERN" "$path" > "$TMP/matches"; then
    printf '%s\n' "$path" >> "$TMP/content-violations"
    sed "s|^|$path:|" "$TMP/matches" >> "$TMP/content-details"
  fi
done < "$TMP/files.z"

if [[ -s "$TMP/path-violations" ]]; then
  cat "$TMP/path-violations" >&2
  fail "removed display-integration names remain in repository paths"
fi
if [[ -s "$TMP/content-violations" ]]; then
  cat "$TMP/content-details" >&2
  fail "removed display-integration names remain outside the cutover plan"
fi

echo "PASS: native cutover repository has no removed display-integration residue"
