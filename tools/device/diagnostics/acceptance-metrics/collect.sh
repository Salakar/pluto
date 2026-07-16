#!/usr/bin/env bash
# Host-side, atomic wrapper for the read-only device evidence collector.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REMOTE_COLLECTOR="$SCRIPT_DIR/remote-collector.sh"
MANIFEST_VERIFIER="$SCRIPT_DIR/verify_manifest.dart"
DEVICE=""
PORT=""
OUTPUT=""
SAMPLE_COUNT=5
SAMPLE_INTERVAL=1
RELEASE_MANIFEST=""

usage() {
  cat >&2 <<'EOF'
usage: collect.sh --device USER@HOST [--port PORT] --output DIR
                  [--samples N] [--interval-seconds N]
                  [--release-manifest FILE]

Collects read-only release acceptance evidence over SSH. The output directory
must not already exist. A failed or partial collection leaves no output bundle.
EOF
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) [[ $# -ge 2 ]] || usage; DEVICE="$2"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || usage; PORT="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || usage; OUTPUT="$2"; shift 2 ;;
    --samples) [[ $# -ge 2 ]] || usage; SAMPLE_COUNT="$2"; shift 2 ;;
    --interval-seconds) [[ $# -ge 2 ]] || usage; SAMPLE_INTERVAL="$2"; shift 2 ;;
    --release-manifest) [[ $# -ge 2 ]] || usage; RELEASE_MANIFEST="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ "$DEVICE" =~ ^[A-Za-z0-9_.@:-]+$ ]] || usage
[[ -n "$OUTPUT" ]] || usage
[[ "$SAMPLE_COUNT" =~ ^[0-9]+$ ]] && ((SAMPLE_COUNT >= 2 && SAMPLE_COUNT <= 60)) || usage
[[ "$SAMPLE_INTERVAL" =~ ^[0-9]+$ ]] && ((SAMPLE_INTERVAL >= 1 && SAMPLE_INTERVAL <= 30)) || usage
if [[ -n "$PORT" ]]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || usage
fi
[[ -f "$REMOTE_COLLECTOR" && ! -L "$REMOTE_COLLECTOR" ]] || {
  echo "acceptance metrics: remote collector missing: $REMOTE_COLLECTOR" >&2
  exit 66
}
if [[ -n "$RELEASE_MANIFEST" ]]; then
  [[ -f "$RELEASE_MANIFEST" && ! -L "$RELEASE_MANIFEST" ]] || {
    echo "acceptance metrics: release manifest is not a regular file: $RELEASE_MANIFEST" >&2
    exit 66
  }
  FLUTTER_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/tools/pluto/pins/flutter.version")"
  DART="${PLUTO_SDK:-$HOME/.pluto/sdk/$FLUTTER_VERSION}/bin/cache/dart-sdk/bin/dart"
  PACKAGES="$REPO_ROOT/tools/pluto/.dart_tool/package_config.json"
  [[ -x "$DART" && -f "$PACKAGES" && -f "$MANIFEST_VERIFIER" && ! -L "$MANIFEST_VERIFIER" ]] || {
    echo 'acceptance metrics: pinned Dart/manifest verifier is unavailable; run tools/setup/setup.sh' >&2
    exit 66
  }
fi
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || {
  echo "acceptance metrics: output already exists: $OUTPUT" >&2
  exit 73
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_identity() {
  local path="$1"
  local identity
  if identity="$(stat -Lc '%d:%i:%s:%Y:%Z' "$path" 2>/dev/null)"; then
    printf '%s\n' "$identity"
  elif identity="$(stat -Lf '%d:%i:%z:%m:%c' "$path" 2>/dev/null)"; then
    printf '%s\n' "$identity"
  else
    return 1
  fi
}

proof_manifest_sha256() {
  local file="$1"
  local values
  values="$(sed -n \
    's/^[[:space:]]*"manifestSha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' \
    "$file")"
  [[ "$values" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$values"
}

one_value() {
  local key="$1"
  local file="$2"
  local values
  values="$(sed -n "s/^${key}=//p" "$file")"
  [[ -n "$values" && "$values" != *$'\n'* ]] || return 1
  printf '%s\n' "$values"
}

transcript() {
  printf '[host %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$TRANSCRIPT"
}

PARENT="$(dirname "$OUTPUT")"
mkdir -p "$PARENT"
NAME="$(basename "$OUTPUT")"
TMP="$(mktemp -d "$PARENT/.${NAME}.partial.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM HUP
EVIDENCE="$TMP/device-evidence.txt"
TRANSCRIPT="$TMP/commands.log"
: > "$TRANSCRIPT"

transcript "BEGIN read-only remote collector device=$DEVICE port=${PORT:-default} samples=$SAMPLE_COUNT interval_seconds=$SAMPLE_INTERVAL"
set +e
if [[ -n "${PLUTO_ACCEPTANCE_TRANSPORT:-}" ]]; then
  transcript "transport=${PLUTO_ACCEPTANCE_TRANSPORT} mode=fixture-or-custom"
  "$PLUTO_ACCEPTANCE_TRANSPORT" "$DEVICE" "$PORT" "$SAMPLE_COUNT" \
    "$SAMPLE_INTERVAL" "$REMOTE_COLLECTOR" > "$EVIDENCE" 2>> "$TRANSCRIPT"
  RC=$?
else
  SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
  [[ -z "$PORT" ]] || SSH_OPTIONS+=(-p "$PORT")
  transcript "transport=ssh remote_command='PLUTO_METRICS_SAMPLE_COUNT=$SAMPLE_COUNT PLUTO_METRICS_SAMPLE_INTERVAL=$SAMPLE_INTERVAL sh -s'"
  ssh "${SSH_OPTIONS[@]}" "$DEVICE" \
    "PLUTO_METRICS_SAMPLE_COUNT=$SAMPLE_COUNT PLUTO_METRICS_SAMPLE_INTERVAL=$SAMPLE_INTERVAL sh -s" \
    < "$REMOTE_COLLECTOR" > "$EVIDENCE" 2>> "$TRANSCRIPT"
  RC=$?
fi
set -e
transcript "END remote collector rc=$RC"
if [[ $RC -ne 0 ]]; then
  echo "acceptance metrics: remote collection failed for $DEVICE (rc=$RC)" >&2
  exit "$RC"
fi

[[ "$(head -n 1 "$EVIDENCE")" == format=pluto-acceptance-evidence ]] || {
  echo "acceptance metrics: evidence format marker is missing" >&2
  exit 74
}
[[ "$(tail -n 1 "$EVIDENCE")" == collection.status=PASS ]] || {
  echo "acceptance metrics: evidence has no terminal PASS marker" >&2
  exit 74
}

PROFILE="$(one_value identity.profile_id "$EVIDENCE")" || exit 74
TARGET="$(one_value identity.target "$EVIDENCE")" || exit 74
REVISION="$(one_value release.git_revision "$EVIDENCE")" || exit 74
BOOT_ID="$(one_value identity.boot_id "$EVIDENCE")" || exit 74
SUPERVISOR_UNIT="$(one_value service.supervisor.unit "$EVIDENCE")" || exit 74
FOREGROUND_APP="$(one_value process.foreground.app_id "$EVIDENCE")" || exit 74
HASH_COUNT="$(one_value installed.hash_count "$EVIDENCE")" || exit 74
WARM_STOPPED="$(one_value warm.stopped_count "$EVIDENCE")" || exit 74
HEALTH_DELTA="$(one_value health.seq_delta "$EVIDENCE")" || exit 74
[[ "$PROFILE" =~ ^(rm1|rm2|move)$ ]] || exit 74
[[ "$TARGET" =~ ^linux-arm(64)?$ ]] || exit 74
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || exit 74
[[ "$BOOT_ID" =~ ^[0-9a-f-]{36}$ ]] || exit 74
[[ "$SUPERVISOR_UNIT" == xochitl.service || "$SUPERVISOR_UNIT" == pluto-session-once.service ]] || exit 74
[[ "$FOREGROUND_APP" =~ ^[A-Za-z0-9._-]+$ ]] || exit 74
[[ "$HASH_COUNT" =~ ^[0-9]+$ ]] && ((HASH_COUNT >= 30)) || exit 74
[[ "$WARM_STOPPED" =~ ^[0-9]+$ ]] && ((WARM_STOPPED >= 1)) || exit 74
[[ "$HEALTH_DELTA" =~ ^[0-9]+$ ]] && ((HEALTH_DELTA >= 1)) || exit 74
[[ "$(grep -c '^sample.index=' "$EVIDENCE")" -eq "$SAMPLE_COUNT" ]] || exit 74
[[ "$(grep -c '^sample.process .* role=supervisor ' "$EVIDENCE")" -eq "$SAMPLE_COUNT" ]] || exit 74
[[ "$(grep -c '^sample.process .* role=foreground ' "$EVIDENCE")" -eq "$SAMPLE_COUNT" ]] || exit 74
[[ "$(grep -c '^sample.process .* role=warm-stopped ' "$EVIDENCE")" -ge "$SAMPLE_COUNT" ]] || exit 74

LOCAL_MANIFEST_RECORD="none"
if [[ -n "$RELEASE_MANIFEST" ]]; then
  MANIFEST_ID_BEFORE="$(file_identity "$RELEASE_MANIFEST")" || {
    echo 'acceptance metrics: cannot identify release manifest' >&2
    exit 66
  }
  MANIFEST_SHA="$(sha256_file "$RELEASE_MANIFEST")"
  MANIFEST_ID_AFTER_PREHASH="$(file_identity "$RELEASE_MANIFEST")" || {
    echo 'acceptance metrics: release manifest disappeared while hashing' >&2
    exit 74
  }
  [[ "$MANIFEST_ID_AFTER_PREHASH" == "$MANIFEST_ID_BEFORE" ]] || {
    echo 'acceptance metrics: release manifest changed while hashing' >&2
    exit 74
  }
  transcript "run exact pinned-Dart manifest/device hash verifier manifest_sha256=$MANIFEST_SHA target=$TARGET"
  "$DART" --packages="$PACKAGES" "$MANIFEST_VERIFIER" \
    --manifest "$RELEASE_MANIFEST" \
    --pins "$REPO_ROOT/tools/pluto/pins" \
    --target "$TARGET" \
    --expected-revision "$REVISION" \
    --evidence "$EVIDENCE" \
    --output "$TMP/manifest-proof.json" 2>> "$TRANSCRIPT"
  PROOF_MANIFEST_SHA="$(proof_manifest_sha256 "$TMP/manifest-proof.json")" || {
    echo 'acceptance metrics: manifest proof has no unique digest' >&2
    exit 74
  }
  [[ "$PROOF_MANIFEST_SHA" == "$MANIFEST_SHA" ]] || {
    echo 'acceptance metrics: manifest proof digest does not match the fenced manifest' >&2
    exit 74
  }
  MANIFEST_ID_AFTER="$(file_identity "$RELEASE_MANIFEST")" || {
    echo 'acceptance metrics: release manifest disappeared during verification' >&2
    exit 74
  }
  MANIFEST_SHA_AFTER="$(sha256_file "$RELEASE_MANIFEST")"
  MANIFEST_ID_AFTER_POSTHASH="$(file_identity "$RELEASE_MANIFEST")" || {
    echo 'acceptance metrics: release manifest disappeared after verification' >&2
    exit 74
  }
  [[ "$MANIFEST_ID_AFTER" == "$MANIFEST_ID_BEFORE" &&
    "$MANIFEST_ID_AFTER_POSTHASH" == "$MANIFEST_ID_BEFORE" &&
    "$MANIFEST_SHA_AFTER" == "$MANIFEST_SHA" ]] || {
    echo 'acceptance metrics: release manifest changed during verification' >&2
    exit 74
  }
  LOCAL_MANIFEST_RECORD="$MANIFEST_SHA"
  transcript "validated every immutable installed file against selected release slice manifest_sha256=$MANIFEST_SHA"
fi

{
  printf 'format=pluto-acceptance-bundle\n'
  printf 'device=%s\n' "$DEVICE"
  printf 'port=%s\n' "${PORT:-default}"
  printf 'profile=%s\n' "$PROFILE"
  printf 'target=%s\n' "$TARGET"
  printf 'boot_id=%s\n' "$BOOT_ID"
  printf 'git_revision=%s\n' "$REVISION"
  printf 'supervisor_unit=%s\n' "$SUPERVISOR_UNIT"
  printf 'foreground_app=%s\n' "$FOREGROUND_APP"
  printf 'installed_hash_count=%s\n' "$HASH_COUNT"
  printf 'warm_stopped_count=%s\n' "$WARM_STOPPED"
  printf 'health_seq_delta=%s\n' "$HEALTH_DELTA"
  printf 'sample_count=%s\n' "$SAMPLE_COUNT"
  printf 'sample_interval_seconds=%s\n' "$SAMPLE_INTERVAL"
  printf 'local_manifest=%s\n' "$LOCAL_MANIFEST_RECORD"
  printf 'status=PASS\n'
} > "$TMP/summary.txt"

transcript 'create host bundle digest manifest'
FILES=(commands.log device-evidence.txt summary.txt)
[[ -z "$RELEASE_MANIFEST" ]] || FILES+=(manifest-proof.json)
: > "$TMP/SHA256SUMS"
for file in "${FILES[@]}"; do
  printf '%s  %s\n' "$(sha256_file "$TMP/$file")" "$file" >> "$TMP/SHA256SUMS"
done
transcript 'PASS bundle is complete and atomically publishable'
# commands.log changed after its digest was first calculated. Rebuild the
# digest manifest exactly once after the terminal transcript line.
: > "$TMP/SHA256SUMS"
for file in "${FILES[@]}"; do
  printf '%s  %s\n' "$(sha256_file "$TMP/$file")" "$file" >> "$TMP/SHA256SUMS"
done

mv "$TMP" "$OUTPUT"
trap - EXIT INT TERM HUP
echo "acceptance metrics: PASS $OUTPUT"
