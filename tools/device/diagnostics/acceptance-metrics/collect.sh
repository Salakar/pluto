#!/bin/bash -p
# Host-side, atomic wrapper for the read-only device evidence collector.
set -euo pipefail
[[ "$-" == *p* ]] || {
  echo 'acceptance metrics: execute this entrypoint directly or with /bin/bash -p' >&2
  exit 64
}

# Production acceptance must not inherit host PATH shims. Test seams retain the
# caller's PATH so fixture transports can provide target-userland tools; their
# output is permanently marked test-only.
ALLOW_TEST_HOOKS="${PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS:-0}"
[[ "$ALLOW_TEST_HOOKS" == 0 || "$ALLOW_TEST_HOOKS" == 1 ]] || {
  echo 'acceptance metrics: PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS must be 0 or 1' >&2
  exit 64
}
LOADER_ENV_NAMES=()
while IFS= read -r loader_name; do
  case "$loader_name" in
    LD_* | DYLD_* | GLIBC_TUNABLES) LOADER_ENV_NAMES+=("$loader_name") ;;
  esac
done < <(compgen -e)
if [[ "$ALLOW_TEST_HOOKS" != 1 ]] && ((${#LOADER_ENV_NAMES[@]} > 0)); then
  for loader_name in "${LOADER_ENV_NAMES[@]}"; do
    [[ -z "${!loader_name:-}" ]] || {
      echo "acceptance metrics: $loader_name is forbidden for production collection" >&2
      exit 64
    }
  done
fi
unset BASH_ENV ENV CDPATH GLOBIGNORE
if ((${#LOADER_ENV_NAMES[@]} > 0)); then
  for loader_name in "${LOADER_ENV_NAMES[@]}"; do
    unset "$loader_name"
  done
fi
if [[ "$ALLOW_TEST_HOOKS" != 1 ]]; then
  PATH=/usr/bin:/bin
  export PATH
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REMOTE_COLLECTOR="$SCRIPT_DIR/remote-collector.sh"
MANIFEST_VERIFIER="$SCRIPT_DIR/verify_manifest.dart"
ACCEPTANCE_IDENTITY="$SCRIPT_DIR/../acceptance_identity.py"
DEVICE=""
PORT=""
OUTPUT=""
SAMPLE_COUNT=5
SAMPLE_INTERVAL=1
RELEASE_MANIFEST=""
SSH_BIN_OVERRIDE="${PLUTO_ACCEPTANCE_SSH_BIN:-}"
PUBLISH_HOOK_OVERRIDE="${PLUTO_ACCEPTANCE_BEFORE_PUBLISH_HOOK:-}"
SDK_OVERRIDE="${PLUTO_SDK:-}"
PYTHON_BIN=/usr/bin/python3
REMOTE_SHELL=/bin/sh

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

sha256_file() {
  if [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  elif [[ -x /bin/sha256sum ]]; then
    /bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  elif [[ -x /usr/bin/shasum ]]; then
    LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  else
    echo 'acceptance metrics: pinned SHA-256 tool is unavailable' >&2
    return 1
  fi
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

[[ -n "$OUTPUT" ]] || usage
[[ "$ALLOW_TEST_HOOKS" == 0 || "$ALLOW_TEST_HOOKS" == 1 ]] || usage
METRICS_OVERRIDE_NAMES=()
while IFS= read -r override_name; do
  [[ -z "$override_name" ]] || METRICS_OVERRIDE_NAMES+=("$override_name")
done < <(compgen -v PLUTO_METRICS_ || true)
if ((${#METRICS_OVERRIDE_NAMES[@]} > 0)) && [[ "$ALLOW_TEST_HOOKS" != 1 ]]; then
  echo 'acceptance metrics: PLUTO_METRICS_* overrides require PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' >&2
  exit 64
fi
if [[ -n "${PLUTO_ACCEPTANCE_TRANSPORT:-}" && "$ALLOW_TEST_HOOKS" != 1 ]]; then
  echo 'acceptance metrics: custom transport requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' >&2
  exit 64
fi
if [[ -n "$SSH_BIN_OVERRIDE" && "$ALLOW_TEST_HOOKS" != 1 ]]; then
  echo 'acceptance metrics: SSH binary override requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' >&2
  exit 64
fi
if [[ -n "$PUBLISH_HOOK_OVERRIDE" && "$ALLOW_TEST_HOOKS" != 1 ]]; then
  echo 'acceptance metrics: publication hook requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' >&2
  exit 64
fi
if [[ -n "$SDK_OVERRIDE" && "$ALLOW_TEST_HOOKS" != 1 ]]; then
  echo 'acceptance metrics: PLUTO_SDK override requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' >&2
  exit 64
fi
if [[ -n "${PLUTO_ACCEPTANCE_TRANSPORT:-}" && -n "$SSH_BIN_OVERRIDE" ]]; then
  echo 'acceptance metrics: custom transport and SSH binary override are mutually exclusive' >&2
  exit 64
fi
if [[ -n "${PLUTO_ACCEPTANCE_TRANSPORT:-}" ]]; then
  [[ "$PLUTO_ACCEPTANCE_TRANSPORT" == /* &&
    "$PLUTO_ACCEPTANCE_TRANSPORT" != *$'\n'* &&
    "$PLUTO_ACCEPTANCE_TRANSPORT" != *$'\t'* &&
    -f "$PLUTO_ACCEPTANCE_TRANSPORT" &&
    ! -L "$PLUTO_ACCEPTANCE_TRANSPORT" &&
    -x "$PLUTO_ACCEPTANCE_TRANSPORT" ]] || {
    echo 'acceptance metrics: custom transport must be an absolute executable regular file' >&2
    exit 66
  }
fi
if [[ -n "$PUBLISH_HOOK_OVERRIDE" ]]; then
  [[ "$PUBLISH_HOOK_OVERRIDE" == /* &&
    "$PUBLISH_HOOK_OVERRIDE" != *$'\n'* &&
    "$PUBLISH_HOOK_OVERRIDE" != *$'\t'* &&
    -f "$PUBLISH_HOOK_OVERRIDE" &&
    ! -L "$PUBLISH_HOOK_OVERRIDE" &&
    -x "$PUBLISH_HOOK_OVERRIDE" ]] || {
    echo 'acceptance metrics: publication hook must be an absolute executable regular file' >&2
    exit 66
  }
fi
[[ "$SAMPLE_COUNT" =~ ^[0-9]+$ ]] && ((SAMPLE_COUNT >= 2 && SAMPLE_COUNT <= 60)) || usage
[[ "$SAMPLE_INTERVAL" =~ ^[0-9]+$ ]] && ((SAMPLE_INTERVAL >= 1 && SAMPLE_INTERVAL <= 30)) || usage
if [[ -n "$PORT" ]]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || usage
fi
[[ -x "$PYTHON_BIN" && -f "$PYTHON_BIN" ]] || {
  echo 'acceptance metrics: pinned Python interpreter is unavailable: /usr/bin/python3' >&2
  exit 66
}
[[ -x "$REMOTE_SHELL" && -f "$REMOTE_SHELL" ]] || {
  echo 'acceptance metrics: expected remote shell path is unavailable: /bin/sh' >&2
  exit 66
}
[[ -f "$ACCEPTANCE_IDENTITY" && ! -L "$ACCEPTANCE_IDENTITY" ]] || {
  echo "acceptance metrics: identity validator missing: $ACCEPTANCE_IDENTITY" >&2
  exit 66
}
IDENTITY_HELPER_SHA256="$(sha256_file "$ACCEPTANCE_IDENTITY")" || exit 66
PYTHON_SHA256="$(sha256_file "$PYTHON_BIN")" || exit 66
ACCOUNT_HOME="$("$PYTHON_BIN" -I -c \
  'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')" || exit 66
[[ "$ACCOUNT_HOME" == /* && "$ACCOUNT_HOME" != *$'\n'* &&
  "$ACCOUNT_HOME" != *$'\t'* && -d "$ACCOUNT_HOME" ]] || exit 66
IDENTITY_ROWS="$("$PYTHON_BIN" -I "$ACCEPTANCE_IDENTITY" validate-ssh-target \
  --target "$DEVICE" --port "$PORT")" || usage
[[ "$(printf '%s\n' "$IDENTITY_ROWS" | wc -l | tr -d '[:space:]')" == 2 ]] || usage
DEVICE="$(printf '%s\n' "$IDENTITY_ROWS" | awk -F '\t' \
  '$1 == "ssh_invocation_target" {print $2}')"
VALIDATED_PORT="$(printf '%s\n' "$IDENTITY_ROWS" | awk -F '\t' \
  '$1 == "ssh_port" {print $2}')"
[[ -n "$DEVICE" && "$VALIDATED_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || usage
if [[ -n "$PORT" && "$PORT" != "$VALIDATED_PORT" ]]; then
  usage
fi
PORT="$VALIDATED_PORT"
[[ -f "$REMOTE_COLLECTOR" && ! -L "$REMOTE_COLLECTOR" ]] || {
  echo "acceptance metrics: remote collector missing: $REMOTE_COLLECTOR" >&2
  exit 66
}
REMOTE_COLLECTOR_SHA256="$(sha256_file "$REMOTE_COLLECTOR")" || exit 66
[[ -f "$MANIFEST_VERIFIER" && ! -L "$MANIFEST_VERIFIER" ]] || {
  echo "acceptance metrics: manifest verifier missing: $MANIFEST_VERIFIER" >&2
  exit 66
}
MANIFEST_VERIFIER_SHA256="$(sha256_file "$MANIFEST_VERIFIER")" || exit 66
SSH_BIN=/usr/bin/ssh
TRANSPORT_MODE=ssh
SSH_BINARY_RECORD=/usr/bin/ssh
if [[ -n "${PLUTO_ACCEPTANCE_TRANSPORT:-}" ]]; then
  TRANSPORT_MODE=test-hook
  SSH_BINARY_RECORD=not-used
elif [[ -n "$SSH_BIN_OVERRIDE" ]]; then
  [[ "$SSH_BIN_OVERRIDE" == /* && "$SSH_BIN_OVERRIDE" != *$'\n'* &&
    "$SSH_BIN_OVERRIDE" != *$'\t'* && -f "$SSH_BIN_OVERRIDE" &&
    ! -L "$SSH_BIN_OVERRIDE" && -x "$SSH_BIN_OVERRIDE" ]] || {
    echo 'acceptance metrics: SSH binary override must be an absolute executable regular file' >&2
    exit 66
  }
  SSH_BIN="$SSH_BIN_OVERRIDE"
  SSH_BINARY_RECORD="$SSH_BIN_OVERRIDE"
  TRANSPORT_MODE=test-hook
else
  [[ -f "$SSH_BIN" && ! -L "$SSH_BIN" && -x "$SSH_BIN" ]] || {
    echo 'acceptance metrics: pinned production SSH binary is unavailable: /usr/bin/ssh' >&2
    exit 66
  }
fi
DART_BINARY_RECORD=not-used
DART_SHA256_RECORD=not-used
if [[ -n "$RELEASE_MANIFEST" ]]; then
  [[ -f "$RELEASE_MANIFEST" && ! -L "$RELEASE_MANIFEST" ]] || {
    echo "acceptance metrics: release manifest is not a regular file: $RELEASE_MANIFEST" >&2
    exit 66
  }
  FLUTTER_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/tools/pluto/pins/flutter.version")"
  DART="${SDK_OVERRIDE:-$ACCOUNT_HOME/.pluto/sdk/$FLUTTER_VERSION}/bin/cache/dart-sdk/bin/dart"
  PACKAGES="$REPO_ROOT/tools/pluto/.dart_tool/package_config.json"
  [[ "$DART" == /* && -x "$DART" && -f "$DART" && ! -L "$DART" &&
    -f "$PACKAGES" ]] || {
    echo 'acceptance metrics: pinned Dart/manifest verifier is unavailable; run tools/setup/setup.sh' >&2
    exit 66
  }
  DART_BINARY_RECORD="$DART"
  DART_SHA256_RECORD="$(sha256_file "$DART")" || exit 66
fi
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || {
  echo "acceptance metrics: output already exists: $OUTPUT" >&2
  exit 73
}

file_identity() {
  local path="$1"
  local identity
  if identity="$(/usr/bin/stat -Lc '%d:%i:%s:%Y:%Z' "$path" 2>/dev/null)"; then
    printf '%s\n' "$identity"
  elif identity="$(/usr/bin/stat -Lf '%d:%i:%z:%m:%c' "$path" 2>/dev/null)"; then
    printf '%s\n' "$identity"
  else
    return 1
  fi
}

inode_identity() {
  local path="$1"
  local identity
  if identity="$(/usr/bin/stat -Lc '%d:%i' "$path" 2>/dev/null)"; then
    printf '%s\n' "$identity"
  elif identity="$(/usr/bin/stat -Lf '%d:%i' "$path" 2>/dev/null)"; then
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
  /usr/bin/awk -v key="$key" '
    BEGIN { prefix = key "="; count = 0; value = "" }
    index($0, prefix) == 1 {
      count += 1
      value = substr($0, length(prefix) + 1)
    }
    END {
      if (count != 1 || value == "") exit 1
      print value
    }
  ' "$file"
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

transcript "BEGIN read-only remote collector device=$DEVICE port=$PORT samples=$SAMPLE_COUNT interval_seconds=$SAMPLE_INTERVAL"
set +e
if [[ -n "${PLUTO_ACCEPTANCE_TRANSPORT:-}" ]]; then
  transcript "transport=${PLUTO_ACCEPTANCE_TRANSPORT} mode=fixture-or-custom"
  "$PLUTO_ACCEPTANCE_TRANSPORT" "$DEVICE" "$PORT" "$SAMPLE_COUNT" \
    "$SAMPLE_INTERVAL" "$REMOTE_COLLECTOR" > "$EVIDENCE" 2>> "$TRANSCRIPT"
  RC=$?
else
  SSH_OPTIONS=(
    -F /dev/null
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=yes
    -o ProxyCommand=none
    -o CanonicalizeHostname=no
    -o ControlMaster=no
    -o ControlPath=none
    -o ControlPersist=no
  )
  SSH_OPTIONS+=(-p "$PORT")
  REMOTE_COMMAND='unset PLUTO_METRICS_ROOT PLUTO_METRICS_RUN_DIR '
  REMOTE_COMMAND+='PLUTO_METRICS_TEST_ROOT PLUTO_METRICS_SYSTEMCTL '
  REMOTE_COMMAND+='PLUTO_METRICS_JOURNALCTL PLUTO_METRICS_UNAME '
  REMOTE_COMMAND+='PLUTO_METRICS_SLEEP PLUTO_METRICS_DATE PLUTO_METRICS_STAT '
  REMOTE_COMMAND+='PLUTO_METRICS_SHA256SUM; '
  REMOTE_COMMAND+="PLUTO_METRICS_SAMPLE_COUNT=$SAMPLE_COUNT "
  REMOTE_COMMAND+="PLUTO_METRICS_SAMPLE_INTERVAL=$SAMPLE_INTERVAL "
  REMOTE_COMMAND+="$REMOTE_SHELL -s"
  transcript "transport=$TRANSPORT_MODE ssh_binary=$SSH_BINARY_RECORD remote_command='$REMOTE_COMMAND'"
  "$SSH_BIN" "${SSH_OPTIONS[@]}" "$DEVICE" \
    "$REMOTE_COMMAND" \
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

[[ "$(sha256_file "$ACCEPTANCE_IDENTITY")" == "$IDENTITY_HELPER_SHA256" &&
  "$(sha256_file "$REMOTE_COLLECTOR")" == "$REMOTE_COLLECTOR_SHA256" &&
  "$(sha256_file "$MANIFEST_VERIFIER")" == "$MANIFEST_VERIFIER_SHA256" &&
  "$(sha256_file "$PYTHON_BIN")" == "$PYTHON_SHA256" ]] || {
  echo 'acceptance metrics: acceptance tooling changed during collection' >&2
  exit 74
}
if [[ -n "$RELEASE_MANIFEST" ]]; then
  [[ "$(sha256_file "$DART")" == "$DART_SHA256_RECORD" ]] || {
    echo 'acceptance metrics: Dart runtime changed during collection' >&2
    exit 74
  }
fi

{
  printf 'format=pluto-acceptance-bundle\n'
  printf 'device=%s\n' "$DEVICE"
  printf 'port=%s\n' "$PORT"
  printf 'transport=%s\n' "$TRANSPORT_MODE"
  printf 'ssh_binary=%s\n' "$SSH_BINARY_RECORD"
  printf 'test_seam=%s\n' "$ALLOW_TEST_HOOKS"
  printf 'identity_helper_sha256=%s\n' "$IDENTITY_HELPER_SHA256"
  printf 'remote_collector_sha256=%s\n' "$REMOTE_COLLECTOR_SHA256"
  printf 'manifest_verifier_sha256=%s\n' "$MANIFEST_VERIFIER_SHA256"
  printf 'python_binary=%s\n' "$PYTHON_BIN"
  printf 'python_sha256=%s\n' "$PYTHON_SHA256"
  printf 'dart_binary=%s\n' "$DART_BINARY_RECORD"
  printf 'dart_sha256=%s\n' "$DART_SHA256_RECORD"
  printf 'remote_shell=%s\n' "$REMOTE_SHELL"
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

STAGING_ID="$(inode_identity "$TMP")" || {
  echo 'acceptance metrics: cannot identify completed staging directory' >&2
  exit 74
}
if [[ -n "$PUBLISH_HOOK_OVERRIDE" ]]; then
  "$PUBLISH_HOOK_OVERRIDE" "$OUTPUT"
fi
set +e
/bin/mv "$TMP" "$OUTPUT"
MV_RC=$?
set -e
PUBLISHED_ID="$(inode_identity "$OUTPUT" 2>/dev/null || true)"
if [[ $MV_RC -ne 0 || -e "$TMP" || -L "$TMP" ||
  ! -d "$OUTPUT" || -L "$OUTPUT" ||
  "$PUBLISHED_ID" != "$STAGING_ID" ]]; then
  # If mv treated a substituted destination as a container, remove only the
  # nested directory whose device/inode still proves it is our staging tree.
  NESTED_STAGING="$OUTPUT/$(basename "$TMP")"
  NESTED_ID="$(inode_identity "$NESTED_STAGING" 2>/dev/null || true)"
  if [[ -n "$NESTED_ID" && "$NESTED_ID" == "$STAGING_ID" &&
    -d "$NESTED_STAGING" && ! -L "$NESTED_STAGING" ]]; then
    /bin/rm -rf "$NESTED_STAGING"
  fi
  echo 'acceptance metrics: output destination was substituted during publication' >&2
  exit 73
fi
trap - EXIT INT TERM HUP
echo "acceptance metrics: PASS $OUTPUT"
