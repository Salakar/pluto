#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
INSTALLER="$HERE/../pluto-boot-install.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
DROPIN_FIXTURE="$HERE/fixtures/zz-pluto.conf.expected"
TMP=${TMPDIR:-/tmp}/pluto-boot-install-test.$$
BIN="$TMP/bin"
CASE="$TMP/case"
CASE_NUMBER=0

cleanup() { rm -rf "$TMP"; }
trap cleanup 0

fail() {
  printf 'boot install test: %s\n' "$*" >&2
  exit 1
}

assert_eq() { # expected actual message
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

[ -x "$INSTALLER" ] || fail "boot installer is not executable"

assert_file_absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2 exists: $1"
}

assert_exact_keys() { # file key...
  aek_file=$1
  shift
  aek_lines=$(wc -l < "$aek_file" | tr -d '[:space:]')
  assert_eq "$#" "$aek_lines" "$aek_file has the wrong key count"
  for aek_key in "$@"; do
    [ "$(grep -c "^$aek_key='" "$aek_file")" -eq 1 ] ||
      fail "$aek_file does not contain exactly one $aek_key"
  done
}

assignment_value() { # file key
  sed -n "s|^$2='\([^']*\)'$|\1|p" "$1"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

line_number() { # anchored pattern file
  grep -n "$1" "$2" | sed -n '1s/:.*//p'
}

assert_before() { # first pattern second pattern file message
  ab_first=$(line_number "$1" "$3")
  ab_second=$(line_number "$2" "$3")
  [ -n "$ab_first" ] && [ -n "$ab_second" ] &&
    [ "$ab_first" -lt "$ab_second" ] || fail "$4"
}

mkdir -p "$BIN"

# macOS has no /proc. Shadow only Linux process-stat reads with a fixture that
# first proves that the pid is live, then emits a Linux-shaped field 22.
cat > "$BIN/cat" <<'CAT'
#!/bin/sh
case "${1:-}" in
  /proc/[0-9]*/stat)
    [ "$#" -eq 1 ] || exit 64
    pid=${1#/proc/}
    pid=${pid%/stat}
    kill -0 "$pid" 2>/dev/null || exit 1
    printf '%s (pluto-test) S' "$pid"
    i=1
    while [ "$i" -le 18 ]; do
      printf ' 0'
      i=$((i + 1))
    done
    printf ' %s\n' "$pid"
    ;;
  *) exec /bin/cat "$@" ;;
esac
CAT

cat > "$BIN/fw_printenv" <<'FW_PRINTENV'
#!/bin/sh
[ "$1" = -n ] && [ "$#" -eq 2 ] || exit 64
printf 'fw-read %s\n' "$2" >> "$PLUTO_TEST_EVENT_LOG"
if [ "${PLUTO_TEST_FW_READ_FAIL:-}" = "$2" ]; then
  exit 1
fi
/bin/cat "$PLUTO_TEST_BOOT_ENV_DIR/$2"
FW_PRINTENV

cat > "$BIN/fw_setenv" <<'FW_SETENV'
#!/bin/sh
[ "$#" -eq 2 ] || exit 64
case "$1:$2" in
  bootcount:0|bootcount:1|upgrade_available:0|upgrade_available:1) ;;
  *) exit 64 ;;
esac
printf 'fw %s %s\n' "$1" "$2" >> "$PLUTO_TEST_EVENT_LOG"
printf '%s\n' "$2" > "$PLUTO_TEST_BOOT_ENV_DIR/$1"
FW_SETENV

cat > "$BIN/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$PLUTO_TEST_EVENT_LOG"
if [ -n "${PLUTO_TEST_SYSTEMCTL_FAIL:-}" ] &&
   [ "$*" = "$PLUTO_TEST_SYSTEMCTL_FAIL" ]; then
  if [ ! -e "$PLUTO_TEST_SYSTEMCTL_FAIL_MARKER" ]; then
    : > "$PLUTO_TEST_SYSTEMCTL_FAIL_MARKER"
    exit 1
  fi
fi
exit 0
SYSTEMCTL

cat > "$BIN/sync" <<'SYNC'
#!/bin/sh
printf 'sync\n' >> "$PLUTO_TEST_EVENT_LOG"
exit 0
SYNC

cat > "$BIN/mount" <<'MOUNT'
#!/bin/sh
printf 'mount %s\n' "$*" >> "$PLUTO_TEST_EVENT_LOG"
exit 1
MOUNT

cat > "$BIN/umount" <<'UMOUNT'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$PLUTO_TEST_EVENT_LOG"
exit 1
UMOUNT

chmod +x "$BIN/cat" "$BIN/fw_printenv" "$BIN/fw_setenv" \
  "$BIN/systemctl" "$BIN/sync" "$BIN/mount" "$BIN/umount"

seed_payload() {
  mkdir -p "$ROOT/bin" "$ROOT/engine/release" \
    "$ROOT/launcher/bundle/lib" "$ROOT/launcher/bundle/flutter_assets"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/pluto-embedder"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/pluto-session.sh"
  cp "$HERE/../pluto-boot-confirm.sh" "$ROOT/bin/pluto-boot-confirm.sh"
  chmod 0755 "$ROOT/bin/pluto-embedder" "$ROOT/bin/pluto-session.sh" \
    "$ROOT/bin/pluto-boot-confirm.sh"
  : > "$ROOT/engine/release/libflutter_engine.so"
  : > "$ROOT/launcher/bundle/lib/app.so"
  cat > "$ROOT/launcher/install.json" <<'JSON'
{
  "buildMode": "release",
  "engineFlavor": "release"
}
JSON
}

seed_stock() { # root identity
  ss_root=$1
  ss_identity=$2
  mkdir -p "$ss_root/usr/bin" "$ss_root/usr/lib/systemd/system"
  {
    printf '#!/bin/sh\n'
    printf '# stock identity: %s\n' "$ss_identity"
    printf 'exit 0\n'
  } > "$ss_root/usr/bin/xochitl"
  chmod 0755 "$ss_root/usr/bin/xochitl"
  cat > "$ss_root/usr/lib/systemd/system/xochitl.service" <<'UNIT'
[Unit]
Description=Stock reMarkable UI

[Service]
ExecStart=/usr/bin/xochitl --system
UNIT
  chmod 0644 "$ss_root/usr/lib/systemd/system/xochitl.service"
}

seed_peer_pluto_artifacts() {
  mkdir -p "$PEER/usr/lib/systemd/system/xochitl.service.d" \
    "$PEER/usr/lib/pluto" "$PEER/usr/libexec"
  printf 'peer override\n' > \
    "$PEER/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf"
  printf 'peer recovery\n' > \
    "$PEER/usr/lib/systemd/system/pluto-boot-failure.service"
  printf 'peer rescue\n' > \
    "$PEER/usr/lib/systemd/system/pluto-stock-rescue.service"
  printf 'peer config\n' > "$PEER/usr/lib/pluto/boot-recovery.conf"
  printf 'peer owner\n' > "$PEER/usr/lib/pluto/boot-owner"
  printf 'peer handler\n' > "$PEER/usr/libexec/pluto-boot-recovery"
}

reset_case() { # profile active fallback
  PROFILE=$1
  ACTIVE=$2
  FALLBACK=$3
  CASE_NUMBER=$((CASE_NUMBER + 1))
  rm -rf "$CASE"
  ROOT="$CASE/root"
  LIVE="$CASE/live"
  PEER="$CASE/peer"
  RUN="$CASE/run"
  ENV_DIR="$CASE/boot-env"
  EVENT_LOG="$CASE/events.log"
  CMDLINE="$CASE/cmdline"
  NONCE_FILE="$CASE/nonce"
  BOOT_ID_FILE="$CASE/boot-id"
  INSTALL_LOCK="$RUN/boot-install.lock"
  RECOVERY_LOCK="$RUN/boot-recovery.lock"
  DROPIN="$LIVE/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf"
  CONFIG="$LIVE/usr/lib/pluto/boot-recovery.conf"
  OWNER="$LIVE/usr/lib/pluto/boot-owner"
  HANDLER="$LIVE/usr/libexec/pluto-boot-recovery"
  FAILURE_UNIT="$LIVE/usr/lib/systemd/system/pluto-boot-failure.service"
  RESCUE_UNIT="$LIVE/usr/lib/systemd/system/pluto-stock-rescue.service"
  ATTEMPT="$RUN/boot-attempt"

  mkdir -p "$ENV_DIR" "$RUN"
  : > "$EVENT_LOG"
  printf 'owner-nonce-%s\n' "$CASE_NUMBER" > "$NONCE_FILE"
  printf 'boot-id-%s\n' "$CASE_NUMBER" > "$BOOT_ID_FILE"
  printf '%s\n' "$ACTIVE" > "$ENV_DIR/active_partition"
  printf '%s\n' "$FALLBACK" > "$ENV_DIR/fallback_partition"
  printf '1\n' > "$ENV_DIR/bootlimit"
  printf '0\n' > "$ENV_DIR/bootcount"
  printf '0\n' > "$ENV_DIR/upgrade_available"

  case "$PROFILE" in
    rm1) MMC=/dev/mmcblk1 ;;
    rm2) MMC=/dev/mmcblk2 ;;
    move) MMC= ;;
    *) fail "unsupported test profile $PROFILE" ;;
  esac
  if [ "$PROFILE" = move ]; then
    printf 'console=tty root=/dev/pluto-root-a rootwait\n' > "$CMDLINE"
  else
    printf 'console=tty root=%sp%s rootwait\n' "$MMC" "$ACTIVE" > "$CMDLINE"
  fi
  seed_payload
  seed_stock "$LIVE" "active-$PROFILE-$ACTIVE"
  seed_stock "$PEER" "peer-$PROFILE-$FALLBACK"
}

run_installer() {
  env \
    PATH="$BIN:$PATH" \
    PLUTO_ROOT="$ROOT" \
    PLUTO_SYSTEM_ROOT="$LIVE" \
    PLUTO_PEER_ROOT="$PEER" \
    PLUTO_SYSTEMCTL="$BIN/systemctl" \
    PLUTO_MOUNT="$BIN/mount" \
    PLUTO_UMOUNT="$BIN/umount" \
    PLUTO_SYNC="$BIN/sync" \
    PLUTO_PROFILE_FILE="$PROFILE_FILE" \
    PLUTO_TESTING=1 \
    PLUTO_TEST_PROFILE_ID="$PROFILE" \
    PLUTO_TEST_ROOT_A=/dev/pluto-root-a \
    PLUTO_TEST_ROOT_B=/dev/pluto-root-b \
    PLUTO_FW_PRINTENV="$BIN/fw_printenv" \
    PLUTO_FW_SETENV="$BIN/fw_setenv" \
    PLUTO_CMDLINE_FILE="$CMDLINE" \
    PLUTO_NONCE_FILE="$NONCE_FILE" \
    PLUTO_BOOT_ID_FILE="$BOOT_ID_FILE" \
    PLUTO_RUN_DIR="$RUN" \
    PLUTO_BOOT_ATTEMPT_FILE="$ATTEMPT" \
    PLUTO_BOOT_INSTALL_LOCK_DIR="$INSTALL_LOCK" \
    PLUTO_BOOT_LOCK_DIR="$RECOVERY_LOCK" \
    PLUTO_TEST_BOOT_ENV_DIR="$ENV_DIR" \
    PLUTO_TEST_EVENT_LOG="$EVENT_LOG" \
    PLUTO_TEST_FAILURE_AT="${PLUTO_TEST_FAILURE_AT:-}" \
    PLUTO_TEST_SYSTEMCTL_FAIL="${PLUTO_TEST_SYSTEMCTL_FAIL:-}" \
    PLUTO_TEST_SYSTEMCTL_FAIL_MARKER="$CASE/systemctl-failed-once" \
    PLUTO_TEST_FW_READ_FAIL="${PLUTO_TEST_FW_READ_FAIL:-}" \
    PLUTO_TEST_POWER_LOSS_AT="${PLUTO_TEST_POWER_LOSS_AT:-}" \
    "$@"
}

expect_install_failure() { # label
  eif_label=$1
  if run_installer sh "$INSTALLER" install > "$CASE/failure.out" 2>&1; then
    fail "$eif_label was accepted"
  fi
}

expect_uninstall_failure() { # label
  euf_label=$1
  if run_installer sh "$INSTALLER" uninstall > "$CASE/failure.out" 2>&1; then
    fail "$euf_label was accepted"
  fi
}

expect_power_loss() { # action boundary
  epl_action=$1
  epl_boundary=$2
  set +e
  PLUTO_TEST_POWER_LOSS_AT=$epl_boundary \
    run_installer sh "$INSTALLER" "$epl_action" > "$CASE/power-loss.out" 2>&1
  epl_status=$?
  set -e
  unset PLUTO_TEST_POWER_LOSS_AT
  assert_eq 97 "$epl_status" \
    "$epl_action/$epl_boundary did not stop at its durable boundary"
}

assert_no_live_recovery() {
  assert_file_absent "$DROPIN" "failed install left the live override"
  assert_file_absent "$HANDLER" "failed install left the recovery handler"
  assert_file_absent "$CONFIG" "failed install left the recovery config"
  assert_file_absent "$OWNER" "failed install left the recovery owner"
  assert_file_absent "$FAILURE_UNIT" "failed install left the failure unit"
  assert_file_absent "$RESCUE_UNIT" "failed install left the rescue unit"
}

assert_stock_present() { # root label
  [ -x "$1/usr/bin/xochitl" ] || fail "$2 stock xochitl is missing"
  grep -q '^ExecStart=/usr/bin/xochitl --system$' \
    "$1/usr/lib/systemd/system/xochitl.service" ||
    fail "$2 stock xochitl unit is invalid"
}

assert_contract() {
  assert_exact_keys "$CONFIG" \
    PLUTO_RECOVERY_PROFILE_ID \
    PLUTO_RECOVERY_CONFIRMATION_STRATEGY \
    PLUTO_RECOVERY_FAILURE_STRATEGY \
    PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED \
    PLUTO_RECOVERY_OWNER_NONCE \
    PLUTO_RECOVERY_MMC_DEVICE \
    PLUTO_RECOVERY_ROOT_PARTITIONS \
    PLUTO_RECOVERY_BOOT_LIMIT \
    PLUTO_RECOVERY_HELPER \
    PLUTO_RECOVERY_COUNTER_DIR \
    PLUTO_RECOVERY_STOCK_RESCUE_UNIT \
    PLUTO_RECOVERY_PEER_DEVICE \
    PLUTO_RECOVERY_STOCK_XOCHITL_SHA256 \
    PLUTO_RECOVERY_STOCK_UNIT_SHA256 \
    PLUTO_RECOVERY_PEER_XOCHITL_SHA256 \
    PLUTO_RECOVERY_PEER_UNIT_SHA256
  assert_exact_keys "$OWNER" PLUTO_OWNER_NONCE PLUTO_OWNER_PROFILE \
    PLUTO_OWNER_STATE
  if grep -qi 'schema\|version\|migration' "$CONFIG" "$OWNER"; then
    fail "unpublished recovery state contains a compatibility/version field"
  fi
}

assert_dropin_fixture() {
  sed \
    -e "s|@ROOT@|$ROOT|g" \
    -e "s|@SUPERVISOR@|$ROOT/bin/pluto-session.sh|g" \
    "$DROPIN_FIXTURE" > "$CASE/expected-dropin"
  cmp -s "$CASE/expected-dropin" "$DROPIN" ||
    fail "live drop-in does not match its exact fixture"
}

assert_peer_pluto_absent() {
  assert_file_absent \
    "$PEER/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf" \
    "peer override survived"
  assert_file_absent \
    "$PEER/usr/lib/systemd/system/pluto-boot-failure.service" \
    "peer failure unit survived"
  assert_file_absent \
    "$PEER/usr/lib/systemd/system/pluto-stock-rescue.service" \
    "peer rescue unit survived"
  assert_file_absent "$PEER/usr/lib/pluto/boot-recovery.conf" \
    "peer recovery config survived"
  assert_file_absent "$PEER/usr/lib/pluto/boot-owner" \
    "peer owner survived"
  assert_file_absent "$PEER/usr/libexec/pluto-boot-recovery" \
    "peer handler survived"
}

# Payload validation remains target-independent and rejects debug/profile
# content from the release boot path.
reset_case rm1 2 3
run_installer sh "$INSTALLER" validate >/dev/null ||
  fail "valid release payload was rejected"
: > "$ROOT/launcher/bundle/flutter_assets/kernel_blob.bin"
if run_installer sh "$INSTALLER" validate >/dev/null 2>&1; then
  fail "release validation accepted a debug kernel"
fi
rm -f "$ROOT/launcher/bundle/flutter_assets/kernel_blob.bin"
sed 's/"buildMode": "release"/"buildMode": "profile"/' \
  "$ROOT/launcher/install.json" > "$ROOT/launcher/install.json.tmp"
mv "$ROOT/launcher/install.json.tmp" "$ROOT/launcher/install.json"
if run_installer sh "$INSTALLER" validate >/dev/null 2>&1; then
  fail "release validation accepted a profile install record"
fi

# Exact install contract: immutable stock identities, rootfs-only recovery,
# peer cleanup, unversioned records, file modes, and flag-last arming.
reset_case rm1 2 3
seed_peer_pluto_artifacts
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "RM1 p2/p3 exact install failed"
[ -f "$DROPIN" ] && [ -x "$HANDLER" ] && [ -f "$FAILURE_UNIT" ] &&
  [ -f "$RESCUE_UNIT" ] || fail "install omitted a recovery artifact"
assert_contract
assert_dropin_fixture
assert_peer_pluto_absent
assert_stock_present "$LIVE" active
assert_stock_present "$PEER" peer
assert_eq rm1 "$(assignment_value "$CONFIG" PLUTO_RECOVERY_PROFILE_ID)" \
  "contract has the wrong profile"
assert_eq /dev/mmcblk1p3 \
  "$(assignment_value "$CONFIG" PLUTO_RECOVERY_PEER_DEVICE)" \
  "contract has the wrong peer partition"
assert_eq "$(sha256sum "$LIVE/usr/bin/xochitl" | sed 's/[[:space:]].*//')" \
  "$(assignment_value "$CONFIG" PLUTO_RECOVERY_STOCK_XOCHITL_SHA256)" \
  "active stock binary hash is not pinned"
assert_eq "$(sha256sum "$LIVE/usr/lib/systemd/system/xochitl.service" | sed 's/[[:space:]].*//')" \
  "$(assignment_value "$CONFIG" PLUTO_RECOVERY_STOCK_UNIT_SHA256)" \
  "active stock unit hash is not pinned"
assert_eq "$(sha256sum "$PEER/usr/bin/xochitl" | sed 's/[[:space:]].*//')" \
  "$(assignment_value "$CONFIG" PLUTO_RECOVERY_PEER_XOCHITL_SHA256)" \
  "peer stock binary hash is not pinned"
assert_eq "$(sha256sum "$PEER/usr/lib/systemd/system/xochitl.service" | sed 's/[[:space:]].*//')" \
  "$(assignment_value "$CONFIG" PLUTO_RECOVERY_PEER_UNIT_SHA256)" \
  "peer stock unit hash is not pinned"
assert_eq armed "$(assignment_value "$OWNER" PLUTO_OWNER_STATE)" \
  "U-Boot install did not persist armed ownership"
assert_eq 755 "$(file_mode "$HANDLER")" "handler mode is not executable"
assert_eq 600 "$(file_mode "$CONFIG")" "config mode is not private"
assert_eq 600 "$(file_mode "$OWNER")" "owner mode is not private"
assert_eq 644 "$(file_mode "$FAILURE_UNIT")" "failure unit mode is wrong"
assert_eq 644 "$(file_mode "$RESCUE_UNIT")" "rescue unit mode is wrong"
assert_eq 644 "$(file_mode "$DROPIN")" "drop-in mode is wrong"
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "install did not arm U-Boot recovery"
tail -n 2 "$EVENT_LOG" > "$CASE/arm-tail"
grep -q '^fw bootcount 0$' "$EVENT_LOG" ||
  fail "install did not reset bootcount"
assert_before '^fw bootcount 0$' '^fw upgrade_available 1$' "$EVENT_LOG" \
  "install did not publish upgrade_available last"

# Stock-first uninstall makes the stock definition effective, stops the owned
# supervisor, protects the UI-less handoff with owned fallback, and proves stock
# active before flag-last disarm and recovery cleanup.
: > "$EVENT_LOG"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "exact uninstall failed"
assert_no_live_recovery
assert_peer_pluto_absent
assert_stock_present "$LIVE" active
assert_stock_present "$PEER" peer
assert_eq 0 "$(cat "$ENV_DIR/upgrade_available")" \
  "uninstall did not disarm U-Boot recovery"
assert_before '^systemctl daemon-reload$' '^systemctl stop xochitl.service$' \
  "$EVENT_LOG" "uninstall stopped the supervisor before restoring stock units"
assert_before '^systemctl stop xochitl.service$' '^fw upgrade_available 0$' \
  "$EVENT_LOG" "uninstall disarmed before stopping the owned supervisor"
assert_before '^systemctl stop xochitl.service$' \
  '^systemctl start xochitl.service$' "$EVENT_LOG" \
  "uninstall started stock before stopping the owned supervisor"
assert_before '^systemctl start xochitl.service$' \
  '^fw upgrade_available 0$' "$EVENT_LOG" \
  "uninstall disarmed recovery before stock was active"

# Both supported U-Boot profiles accept either exact root-pair orientation and
# pin the corresponding peer. This exercises p2/p3 and p3/p2 on RM1 and RM2.
for topology in 'rm1 2 3' 'rm1 3 2' 'rm2 2 3' 'rm2 3 2'; do
  set -- $topology
  reset_case "$1" "$2" "$3"
  run_installer sh "$INSTALLER" install >/dev/null ||
    fail "$1 p$2/p$3 topology was rejected"
  assert_eq "${MMC}p${3}" \
    "$(assignment_value "$CONFIG" PLUTO_RECOVERY_PEER_DEVICE)" \
    "$1 p$2/p$3 chose the wrong peer"
  run_installer sh "$INSTALLER" uninstall >/dev/null ||
    fail "$1 p$2/p$3 uninstall failed"
done

# A root outside the generated pair and a cmdline/root mismatch fail before
# any live override is published.
reset_case rm2 2 4
expect_install_failure "RM2 fallback outside p2/p3"
assert_no_live_recovery
reset_case rm1 2 3
printf 'console=tty root=/dev/mmcblk1p3 rootwait\n' > "$CMDLINE"
expect_install_failure "RM1 active/cmdline mismatch"
assert_no_live_recovery

# A foreign upgrade transaction is never adopted. Rejection happens before
# peer cleanup, live root writes, U-Boot writes, or systemd mutation.
reset_case rm1 2 3
seed_peer_pluto_artifacts
printf '1\n' > "$ENV_DIR/upgrade_available"
: > "$EVENT_LOG"
expect_install_failure "foreign upgrade_available=1"
assert_no_live_recovery
[ -f "$PEER/usr/lib/pluto/boot-owner" ] ||
  fail "foreign transaction rejection modified the peer"
[ ! -s "$EVENT_LOG" ] || {
  if grep -q '^fw \|^systemctl \|^sync$' "$EVENT_LOG"; then
    fail "foreign transaction rejection wrote recovery, systemd, or rootfs state"
  fi
}
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "foreign upgrade transaction was cleared"

# A same-boot attempt blocks reinstall without retiring its arm. With no live
# attempt, an owned stale arm is disarmed and replaced by a fresh owner.
reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "install before owned-arm retirement failed"
mkdir -p "$(dirname "$ATTEMPT")"
printf 'owned live attempt\n' > "$ATTEMPT"
: > "$EVENT_LOG"
expect_install_failure "live owned boot attempt"
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "live attempt rejection retired the active arm"
if grep -q '^fw ' "$EVENT_LOG"; then
  fail "live attempt rejection wrote U-Boot state"
fi
rm -f "$ATTEMPT"
printf 'replacement-owner-nonce\n' > "$NONCE_FILE"
: > "$EVENT_LOG"
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "owned stale arm was not retired"
assert_eq replacement-owner-nonce \
  "$(assignment_value "$CONFIG" PLUTO_RECOVERY_OWNER_NONCE)" \
  "reinstall did not publish a fresh owner"
assert_before '^fw upgrade_available 0$' '^fw upgrade_available 1$' \
  "$EVENT_LOG" "owned stale arm was not retired before replacement"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "cleanup after owned-arm retirement failed"

# Existing contracts pin both binary and unit on both roots. Any drift is a
# hard rejection; there is no migration or baseline update path.
for drift in active-binary active-unit peer-binary peer-unit; do
  reset_case rm1 2 3
  run_installer sh "$INSTALLER" install >/dev/null ||
    fail "baseline install for $drift failed"
  case "$drift" in
    active-binary)
      printf '# active binary drift\n' >> "$LIVE/usr/bin/xochitl"
      chmod 0755 "$LIVE/usr/bin/xochitl"
      ;;
    active-unit)
      printf '# active unit drift\n' >> \
        "$LIVE/usr/lib/systemd/system/xochitl.service"
      ;;
    peer-binary)
      printf '# peer binary drift\n' >> "$PEER/usr/bin/xochitl"
      chmod 0755 "$PEER/usr/bin/xochitl"
      ;;
    peer-unit)
      printf '# peer unit drift\n' >> \
        "$PEER/usr/lib/systemd/system/xochitl.service"
      ;;
  esac
  expect_install_failure "$drift hash drift"
  assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
    "$drift drift retired the proven fallback before identity proof"
done

reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "baseline install for uninstall active-drift proof failed"
printf '# active binary drift before uninstall\n' >> "$LIVE/usr/bin/xochitl"
chmod 0755 "$LIVE/usr/bin/xochitl"
: > "$EVENT_LOG"
expect_uninstall_failure "uninstall active stock hash drift"
if grep -q '^systemctl stop xochitl.service$\|^fw ' "$EVENT_LOG"; then
  fail "uninstall mutated live ownership before proving active stock"
fi
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "active stock drift disarmed the proven peer fallback"
seed_stock "$LIVE" active-rm1-2
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "active stock drift was not retryable after exact repair"

# Compatibility-shaped state is rejected, not migrated or re-versioned.
reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "baseline install for schema rejection failed"
printf "PLUTO_RECOVERY_SCHEMA='legacy'\n" >> "$CONFIG"
: > "$EVENT_LOG"
expect_install_failure "legacy/schema recovery record"
if grep -q '^fw ' "$EVENT_LOG"; then
  fail "unrecognized recovery record mutated U-Boot state"
fi

reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "baseline install for truncated owner rejection failed"
cat > "$OWNER" <<EOF
PLUTO_OWNER_NONCE='$(assignment_value "$CONFIG" PLUTO_RECOVERY_OWNER_NONCE)'
PLUTO_OWNER_PROFILE='rm1'
PLUTO_OWNER_STATE='armed
EOF
chmod 0600 "$OWNER"
: > "$EVENT_LOG"
expect_install_failure "truncated recovery owner"
if grep -q '^fw ' "$EVENT_LOG"; then
  fail "truncated recovery owner mutated U-Boot state"
fi

# Every install durability boundary and U-Boot environment failure leaves the
# live stock definition selected. Faults that occur before a U-Boot arm also
# leave upgrade_available clear. Repeated handler faults may deliberately keep
# inert rootfs diagnostics, but can never publish the Pluto override.
for install_fault in \
  stage.remount_rw stage.sync stage.remount_ro \
  owner.remount_rw owner.before_publish owner.remount_ro \
  fw_read.active_partition fw_read.fallback_partition fw_read.bootlimit \
  fw_read.upgrade_available fw_set.bootcount fw_read.bootcount \
  fw_set.upgrade_available arm.sync \
  activate.remount_rw activate.publish activate.sync activate.remount_ro
do
  reset_case rm1 2 3
  PLUTO_TEST_FAILURE_AT=$install_fault expect_install_failure \
    "injected install fault $install_fault"
  assert_file_absent "$DROPIN" \
    "install fault $install_fault exposed the Pluto override"
  assert_eq 0 "$(cat "$ENV_DIR/upgrade_available")" \
    "install fault $install_fault left recovery armed"
  assert_stock_present "$LIVE" "active after $install_fault"
  assert_stock_present "$PEER" "peer after $install_fault"
done
unset PLUTO_TEST_FAILURE_AT

# Peer cleanup/identity failures are pre-activation failures: they can never
# write the live root or arm U-Boot recovery.
for peer_fault in peer.remove peer.sync peer.identity; do
  reset_case rm1 2 3
  PLUTO_TEST_FAILURE_AT=$peer_fault expect_install_failure \
    "injected peer fault $peer_fault"
  assert_no_live_recovery
  assert_eq 0 "$(cat "$ENV_DIR/upgrade_available")" \
    "peer fault $peer_fault armed recovery"
  assert_stock_present "$LIVE" "active after $peer_fault"
  assert_stock_present "$PEER" "peer after $peer_fault"
done
unset PLUTO_TEST_FAILURE_AT

# A failed systemd reload is part of the activation transaction and rolls back
# the override and owned arm.
reset_case rm1 2 3
PLUTO_TEST_SYSTEMCTL_FAIL=daemon-reload expect_install_failure \
  "systemd activation failure"
assert_no_live_recovery
assert_eq 0 "$(cat "$ENV_DIR/upgrade_available")" \
  "systemd activation failure left recovery armed"
unset PLUTO_TEST_SYSTEMCTL_FAIL

# A preflight fw_printenv failure cannot be confused with upgrade_available=0.
reset_case rm1 2 3
PLUTO_TEST_FW_READ_FAIL=upgrade_available expect_install_failure \
  "upgrade_available read failure"
assert_no_live_recovery
unset PLUTO_TEST_FW_READ_FAIL

# Power-loss boundaries expose only one of three durable safe states: staged
# recovery without an override, armed fallback without an override, or an
# armed fallback plus the durable override. Re-running uninstall must retire
# each state. Uninstall itself keeps assets until after stock and disarm are
# independently durable.
reset_case rm1 2 3
expect_power_loss install recovery_handler_durable
assert_file_absent "$DROPIN" "staging boundary published the override"
[ -x "$HANDLER" ] && [ -f "$CONFIG" ] && [ -f "$OWNER" ] ||
  fail "staging boundary did not preserve durable recovery"
assert_eq 0 "$(cat "$ENV_DIR/upgrade_available")" \
  "staging boundary armed U-Boot early"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "staging boundary was not recoverable"

reset_case rm1 2 3
expect_power_loss install recovery_armed
assert_file_absent "$DROPIN" "armed boundary published the override"
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "armed boundary lost its fallback"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "armed boundary was not recoverable"

reset_case rm1 2 3
expect_power_loss install boot_override_durable
[ -f "$DROPIN" ] || fail "override boundary lost the durable override"
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "override boundary lost its fallback"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "override boundary was not recoverable"

reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "install before stock uninstall boundary failed"
expect_power_loss uninstall stock_override_durable
assert_file_absent "$DROPIN" "stock boundary retained the override"
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "stock boundary disarmed before stock was durable"
[ -f "$CONFIG" ] && [ -f "$OWNER" ] ||
  fail "stock boundary removed recovery ownership early"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "stock uninstall boundary was not recoverable"

reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "install before disarm boundary failed"
expect_power_loss uninstall recovery_disarmed
assert_file_absent "$DROPIN" "disarm boundary retained the override"
assert_eq 0 "$(cat "$ENV_DIR/upgrade_available")" \
  "disarm boundary did not persist the clear flag"
[ -f "$CONFIG" ] && [ -f "$OWNER" ] ||
  fail "disarm boundary removed ownership before cleanup"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "disarm uninstall boundary was not recoverable"

# Uninstall never disarms before the stock unit is durable and the owned
# supervisor is stopped. Once stopped, every later failure makes a best-effort
# stock start while retaining whichever recovery assets are still needed for
# a safe retry.
for pre_stop_fault in uninstall_stock.sync uninstall_stock.remount_ro; do
  reset_case rm1 2 3
  run_installer sh "$INSTALLER" install >/dev/null ||
    fail "install before $pre_stop_fault failed"
  : > "$EVENT_LOG"
  PLUTO_TEST_FAILURE_AT=$pre_stop_fault expect_uninstall_failure \
    "uninstall pre-stop fault $pre_stop_fault"
  assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
    "$pre_stop_fault disarmed recovery"
  if grep -q '^systemctl stop xochitl.service$' "$EVENT_LOG"; then
    fail "$pre_stop_fault stopped the live supervisor"
  fi
  unset PLUTO_TEST_FAILURE_AT
  run_installer sh "$INSTALLER" uninstall >/dev/null ||
    fail "$pre_stop_fault was not safely retryable"
done

reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "install before daemon-reload uninstall fault failed"
: > "$EVENT_LOG"
rm -f "$CASE/systemctl-failed"
PLUTO_TEST_SYSTEMCTL_FAIL=daemon-reload expect_uninstall_failure \
  "uninstall stock daemon-reload failure"
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "daemon-reload failure disarmed recovery"
if grep -q '^systemctl stop xochitl.service$' "$EVENT_LOG"; then
  fail "daemon-reload failure stopped the live supervisor"
fi
unset PLUTO_TEST_SYSTEMCTL_FAIL
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "daemon-reload uninstall failure was not retryable"

reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "install before supervisor-stop fault failed"
: > "$EVENT_LOG"
rm -f "$CASE/systemctl-failed"
PLUTO_TEST_SYSTEMCTL_FAIL='stop xochitl.service' expect_uninstall_failure \
  "uninstall supervisor stop failure"
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "supervisor stop failure disarmed recovery"
if grep -q '^fw upgrade_available 0$' "$EVENT_LOG"; then
  fail "supervisor stop failure reached the disarm commit"
fi
grep -q '^systemctl start xochitl.service$' "$EVENT_LOG" ||
  fail "supervisor stop failure did not recover a possibly stopped UI"
unset PLUTO_TEST_SYSTEMCTL_FAIL
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "supervisor-stop uninstall failure was not retryable"

reset_case rm1 2 3
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "install before stock-start fault failed"
: > "$EVENT_LOG"
rm -f "$CASE/systemctl-failed-once"
PLUTO_TEST_SYSTEMCTL_FAIL='start xochitl.service' expect_uninstall_failure \
  "uninstall stock start failure"
[ -f "$DROPIN" ] && [ -f "$CONFIG" ] && [ -f "$OWNER" ] ||
  fail "stock start failure did not restore the Pluto boot transaction"
assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
  "stock start failure lost the owned peer fallback"
[ "$(grep -c '^systemctl start xochitl.service$' "$EVENT_LOG")" -ge 2 ] ||
  fail "stock start failure did not retry through the Pluto rollback"
unset PLUTO_TEST_SYSTEMCTL_FAIL
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "stock-start uninstall failure was not retryable"

for post_stop_fault in fw_set.upgrade_available uninstall_cleanup.remount_rw \
  uninstall_cleanup.sync uninstall_cleanup.remount_ro
do
  reset_case rm1 2 3
  run_installer sh "$INSTALLER" install >/dev/null ||
    fail "install before $post_stop_fault failed"
  : > "$EVENT_LOG"
  PLUTO_TEST_FAILURE_AT=$post_stop_fault expect_uninstall_failure \
    "uninstall post-stop fault $post_stop_fault"
  grep -q '^systemctl start xochitl.service$' "$EVENT_LOG" ||
    fail "$post_stop_fault left the device UI-less"
  case "$post_stop_fault" in
    fw_set.upgrade_available)
      assert_eq 1 "$(cat "$ENV_DIR/upgrade_available")" \
        "$post_stop_fault lost the still-owned fallback"
      [ -f "$CONFIG" ] && [ -f "$OWNER" ] ||
        fail "$post_stop_fault removed recovery ownership"
      ;;
    *)
      assert_eq 0 "$(cat "$ENV_DIR/upgrade_available")" \
        "$post_stop_fault failed before disarm was durable"
      ;;
  esac
  unset PLUTO_TEST_FAILURE_AT
  run_installer sh "$INSTALLER" uninstall >/dev/null ||
    fail "$post_stop_fault was not safely retryable"
done

# Move uses the same install/uninstall and drop-in flow, but performs no U-Boot
# writes. Its bounded stock-rescue unit remains the failure mechanism until the
# profile's LPGPR contract is verified on hardware.
reset_case move 0 0
: > "$EVENT_LOG"
if ! run_installer sh "$INSTALLER" install > "$CASE/move-install.out" 2>&1; then
  sed -n '1,120p' "$CASE/move-install.out" >&2
  fail "Move common boot-default install failed"
fi
assert_contract
assert_dropin_fixture
assert_eq move "$(assignment_value "$CONFIG" PLUTO_RECOVERY_PROFILE_ID)" \
  "Move install wrote the wrong profile"
assert_eq lpgpr_counter \
  "$(assignment_value "$CONFIG" PLUTO_RECOVERY_CONFIRMATION_STRATEGY)" \
  "Move install wrote the wrong recovery strategy"
assert_eq 0 \
  "$(assignment_value "$CONFIG" PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED)" \
  "Move install changed the generated recovery gate"
grep -q '^ExecStart=/usr/bin/xochitl --system$' "$RESCUE_UNIT" ||
  fail "Move bounded rescue does not launch exact stock xochitl"
grep -q '^Restart=on-failure$' "$RESCUE_UNIT" ||
  fail "Move bounded rescue is not restart-bounded"
grep -q '^StartLimitBurst=3$' "$RESCUE_UNIT" ||
  fail "Move bounded rescue has no start limit"
if grep -q '^fw ' "$EVENT_LOG"; then
  fail "Move install mutated U-Boot state"
fi
: > "$EVENT_LOG"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "Move common uninstall failed"
assert_no_live_recovery
if grep -q '^fw ' "$EVENT_LOG"; then
  fail "Move uninstall mutated U-Boot state"
fi
grep -q '^systemctl start xochitl.service$' "$EVENT_LOG" ||
  fail "Move uninstall did not start stock xochitl"

# A stale mkdir lock is reclaimed only after its recorded pid/start identity is
# proven dead. Successful completion removes the lock again.
reset_case rm1 2 3
mkdir -p "$INSTALL_LOCK"
printf '999999 999999\n' > "$INSTALL_LOCK/owner"
run_installer sh "$INSTALLER" install >/dev/null ||
  fail "stale installer lock was not reclaimed"
assert_file_absent "$INSTALL_LOCK" "installer lock survived process exit"
run_installer sh "$INSTALLER" uninstall >/dev/null ||
  fail "cleanup after stale-lock test failed"

printf 'boot install test: PASS\n'
