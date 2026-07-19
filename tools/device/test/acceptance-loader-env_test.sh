#!/bin/bash -p
set -euo pipefail
[[ "$-" == *p* ]] || {
  echo "acceptance-loader-env_test: execute with /bin/bash -p" >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-loader-env-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
AUDIT_SOURCE="$ROOT/tools/device/test/fixtures/acceptance_loader_audit.c"
ENTRYPOINTS=(
  tools/setup/camera/capture.sh
  tools/setup/camera/capture-acceptance-stage.sh
  tools/device/diagnostics/acceptance-metrics/collect.sh
  tools/device/diagnostics/verify-visual-acceptance.sh
  tools/device/diagnostics/record-visual-review.sh
  tools/device/test/release-aot-hardware-smoke.sh
  tools/device/test/release-lifecycle-hardware-smoke.sh
)

fail() {
  echo "acceptance-loader-env_test: FAIL: $*" >&2
  exit 1
}

run_namespace_checks() {
  local relative entry output variable
  for relative in "${ENTRYPOINTS[@]}"; do
    entry="$ROOT/$relative"
    [[ "$(head -n 1 "$entry")" == '#!/bin/bash -p' ]] ||
      fail "entrypoint lacks privileged absolute Bash: $relative"
    for variable in LD_PLUTO_TEST GLIBC_TUNABLES; do
      output="$TMP/namespace-${relative//\//_}-$variable.out"
      if /usr/bin/env "$variable=pluto-loader-contamination" \
        "$entry" >"$output" 2>&1; then
        fail "$relative accepted non-empty $variable"
      fi
      grep -q "$variable is forbidden" "$output" ||
        fail "$relative did not reject the broad loader namespace $variable"
    done

    # Apple system binaries may remove DYLD_* before a new process starts.
    # Source under an already-clean privileged Bash to exercise the namespace
    # scanner itself without claiming that this is a dynamic-loader injection.
    output="$TMP/namespace-${relative//\//_}-DYLD_PLUTO_TEST.out"
    if ENTRYPOINT="$entry" /bin/bash -p -c \
      'export DYLD_PLUTO_TEST=pluto-loader-contamination; source "$ENTRYPOINT"' \
      >"$output" 2>&1; then
      fail "$relative accepted non-empty DYLD_PLUTO_TEST"
    fi
    grep -q 'DYLD_PLUTO_TEST is forbidden' "$output" ||
      fail "$relative did not reject the broad DYLD loader namespace"
  done
}

run_effective_linux_audit_checks() {
  local cc_bin="$1"
  local audit_dso="$TMP/acceptance-loader-audit.so"
  local relative entry marker output evidence rc
  "$cc_bin" -shared -fPIC -Wall -Wextra -Werror \
    "$AUDIT_SOURCE" -o "$audit_dso"
  [[ -s "$audit_dso" ]] || fail "could not build the Linux audit DSO"

  for relative in "${ENTRYPOINTS[@]}"; do
    entry="$ROOT/$relative"
    marker="$TMP/audit-${relative//\//_}.marker"
    output="$TMP/audit-${relative//\//_}.out"
    evidence="$TMP/audit-${relative//\//_}.evidence"
    set +e
    PLUTO_LOADER_AUDIT_MARKER="$marker" \
      LD_AUDIT="$audit_dso" \
      "$entry" --output "$evidence" >"$output" 2>&1
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] || fail "$relative accepted an effective LD_AUDIT DSO"
    [[ -s "$marker" ]] ||
      fail "$relative test did not load the effective LD_AUDIT DSO"
    grep -q 'LD_AUDIT is forbidden' "$output" ||
      fail "$relative did not diagnose effective LD_AUDIT contamination"
    [[ ! -e "$evidence" ]] ||
      fail "$relative created production evidence under effective LD_AUDIT"
  done
}

run_namespace_checks

if [[ "$(uname -s)" == Linux ]]; then
  CC_BIN="${CC:-cc}"
  command -v "$CC_BIN" >/dev/null 2>&1 ||
    fail "a native C compiler is required for the effective LD_AUDIT test"
  run_effective_linux_audit_checks "$CC_BIN"
elif [[ "${PLUTO_LOADER_AUDIT_IN_CONTAINER:-0}" == 1 ]]; then
  fail "container audit mode did not start on Linux"
else
  DOCKER_BIN="$(command -v docker || true)"
  if [[ -z "$DOCKER_BIN" ]]; then
    echo "acceptance-loader-env_test: SKIP effective LD_AUDIT check (Linux or Docker required)"
    exit 0
  fi
  docker_arch="$($DOCKER_BIN version --format '{{.Server.Arch}}' 2>/dev/null || true)"
  case "$docker_arch" in
    arm64 | aarch64) docker_image=pluto/embedder-builder:ubuntu24.04-arm64 ;;
    amd64 | x86_64) docker_image=pluto/embedder-builder:ubuntu24.04-amd64-rm-sdk ;;
    *)
      echo "acceptance-loader-env_test: SKIP effective LD_AUDIT check (unsupported Docker architecture: $docker_arch)"
      exit 0
      ;;
  esac
  if ! "$DOCKER_BIN" image inspect "$docker_image" >/dev/null 2>&1; then
    echo "acceptance-loader-env_test: SKIP effective LD_AUDIT check (missing $docker_image)"
    exit 0
  fi
  "$DOCKER_BIN" run --rm \
    -e PLUTO_LOADER_AUDIT_IN_CONTAINER=1 \
    -v "$ROOT:/workspace:ro" \
    --entrypoint /bin/bash \
    "$docker_image" -p /workspace/tools/device/test/acceptance-loader-env_test.sh
fi

echo "acceptance-loader-env_test: PASS"
