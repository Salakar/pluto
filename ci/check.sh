#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Require the exact SDK installed by tools/setup/setup.sh. Checks must never
# fall through to an unrelated system Flutter/Dart installation.
FLUTTER_VERSION="$(tr -d '[:space:]' < tools/pluto/pins/flutter.version)"
PLUTO_SDK="${PLUTO_SDK:-$HOME/.pluto/sdk/$FLUTTER_VERSION}"
if [[ ! -x "$PLUTO_SDK/bin/flutter" ]]; then
  echo "ci/check: pinned Flutter SDK is missing: $PLUTO_SDK" >&2
  echo "ci/check: run ./tools/setup/setup.sh first" >&2
  exit 1
fi
export PLUTO_SDK
"$ROOT/tools/setup/setup.sh" --verify
export PATH="$PLUTO_SDK/bin:$PLUTO_SDK/bin/cache/dart-sdk/bin:$PATH"
# setup installs Melos into the pub cache; do not depend on an interactive
# shell having already sourced the PATH line printed by setup.
export PATH="${PUB_CACHE:-$HOME/.pub-cache}/bin:$PATH"

bash tools/setup/test/setup_test.sh
dart analyze --fatal-infos tools/codegen
dart tools/codegen/generate_device_profiles_test.dart
dart tools/codegen/generate_device_profiles.dart --check
dart tools/codegen/generate_rm1_rgb565_optical_lut_test.dart
dart tools/codegen/generate_rm1_rgb565_optical_lut.dart --check
bash -n tools/setup/camera/capture.sh
python3 -m unittest discover -s tools/setup/camera/test -p 'test_*.py'
python3 -m unittest discover -s tools/device/diagnostics/test -p 'test_*.py'
bash tools/setup/camera/test/capture_acceptance_stage_test.sh
for script in tools/device/*.sh tools/device/test/*.sh; do
  if [[ "$(head -n 1 "$script")" == *bash* ]]; then
    bash -n "$script"
  else
    sh -n "$script"
  fi
done
bash tools/build/test/embedder-build-workflow-test.sh
bash tools/build/test/codex-armv7-build-recipe-test.sh
bash tools/device/test/pluto-power-key-watch_test.sh
bash tools/device/test/pluto-session-standby_test.sh
bash tools/device/test/pluto-session-debug-authorization_test.sh
bash tools/device/test/pluto-rm2-cpufreq-restore_test.sh
bash tools/device/test/pluto-session-once_test.sh
bash tools/device/test/pluto-session-rm2-cpufreq_test.sh
bash tools/device/test/pluto-session-warm-resume_test.sh
bash tools/device/test/pluto-session-switcher_test.sh
bash tools/device/test/pluto-session-power-menu_test.sh
bash tools/device/test/pluto-release-activate_test.sh
bash tools/device/test/acceptance-metrics_test.sh
bash tools/device/test/release-aot-hardware-smoke_test.sh
bash tools/device/test/release-lifecycle-hardware-smoke_test.sh
bash tools/device/test/pluto-boot-install_test.sh
bash tools/device/test/pluto-uninstall_test.sh
sh tools/device/test/device-profiles_test.sh
sh tools/device/test/pluto-boot-confirm_test.sh
sh tools/device/test/pluto-session-profile_test.sh
dart format --set-exit-if-changed packages apps tools/pluto tools/codegen
melos run analyze
melos run test
melos run goldens
