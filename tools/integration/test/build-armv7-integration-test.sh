#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RECIPE="$ROOT/tools/integration/build-armv7-integration.sh"
PATCHES="$ROOT/tools/integration/patches"
LOCK="$ROOT/tools/integration/sources.lock"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-integration-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_failure() {
  local expected="$1"
  shift
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    fail "command unexpectedly succeeded: $*"
  fi
  grep -F "$expected" "$TMP/stderr" >/dev/null || {
    cat "$TMP/stderr" >&2
    fail "failure did not contain: $expected"
  }
}

bash -n "$RECIPE"
bash "$RECIPE" --verify-inputs >/dev/null

grep -F \
  'XOVI_COMMIT=0c8d5269b55c851901d4e4a754dc2d7deab40b17' \
  "$LOCK" >/dev/null || fail "XOVI commit is not pinned"
grep -F \
  'EXTENSIONS_COMMIT=7874154dba6793cc68a15fae0fb9dd272c4ed20a' \
  "$LOCK" >/dev/null || fail "extensions commit is not pinned"
grep -F \
  'APPLOAD_327_COMMIT=5bb34a362f09f753f18bd6261558f8e2737aacdb' \
  "$LOCK" >/dev/null || fail "AppLoad 3.27 commit is not pinned"
grep -F \
  'APPLOAD_328_BASE_COMMIT=40506d47427123f07030bb2e83453a43d035b16a' \
  "$LOCK" >/dev/null || fail "AppLoad 3.28 commit is not pinned"
grep -E \
  '^BUILDER_IMAGE=docker\.io/.+@sha256:[0-9a-f]{64}$' \
  "$LOCK" >/dev/null || fail "builder image is not digest-pinned"
grep -E '^RM_SDK_SHA256=[0-9a-f]{64}$' "$LOCK" >/dev/null ||
  fail "official RM SDK installer is not checksum-pinned"
grep -F 'RUST_TOOLCHAIN=1.82.0' "$LOCK" >/dev/null ||
  fail "QRR Rust toolchain does not match the accepted build provenance"
grep -F \
  'REFERENCE_QRR_SHA256=3850e3ceca1a22dd19d0ded854719c45cf553415f909e3cf5aa0e17efab2dbac' \
  "$LOCK" >/dev/null || fail "live-tested QRR is not the locked reference"
grep -F 'verify_reference_elf' "$RECIPE" >/dev/null ||
  fail "reference verification does not enforce the ARMv7 ABI gate"

REFERENCE_SHIM32="$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims/qtfb-shim-32bit.so"
if [[ -f "$REFERENCE_SHIM32" ]] && grep -F \
  'REFERENCE_QTFB_SHIM_32_SHA256=19a9d2c75741113f37f81f7affead40eeb12fa3cc41109b7f41ba154f60799cc' \
  "$LOCK" >/dev/null; then
  expect_failure 'requires GLIBC_2.38' \
    bash "$RECIPE" --verify-reference
fi

for firmware in 3.27 3.28; do
  patch="$PATCHES/appload-$firmware-pluto.patch"
  grep -F '#include <QEventLoop>' "$patch" >/dev/null ||
    fail "AppLoad $firmware launch wait lacks a nested event loop"
  grep -F 'constexpr int kLaunchTimeoutMs = 3000;' "$patch" >/dev/null ||
    fail "AppLoad $firmware launch wait is not bounded"
  grep -F 'constexpr int kLaunchPollIntervalMs = 25;' "$patch" >/dev/null ||
    fail "AppLoad $firmware launch wait does not use bounded PID polling"
  grep -F 'appID, pid, ref->second->isQTFB());' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware does not register the exact PID and QTFB foreground at process creation"
  grep -F 'inline static AppLoadLauncher *_instance = nullptr;' "$patch" >/dev/null ||
    fail "AppLoad $firmware launcher authority is not process-global"
  grep -F 'struct TrackedProcess {' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not keep PID/window state in one generation record"
  grep -F 'QPointer<QObject> window;' "$patch" >/dev/null ||
    fail "AppLoad $firmware generation record does not safely track window lifetime"
  grep -F 'quintptr windowToken = 0;' "$patch" >/dev/null ||
    fail "AppLoad $firmware cannot distinguish stale destruction of a reused PID"
  grep -F 'QSet<QString> _launching;' "$patch" >/dev/null ||
    fail "AppLoad $firmware has no global launch-in-flight guard"
  grep -F '_launching.remove(id);' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not release launch reservations"
  grep -F '_processes.insert(id, TrackedProcess {pid, {}, foreground});' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware new PID generation does not clear an old window"
  grep -F 'Pluto AppLoad process tracked pending window' "$patch" >/dev/null ||
    fail "AppLoad $firmware lacks process/window handshake diagnostics"
  grep -F 'Q_INVOKABLE bool beginLaunch(const QString &id)' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not expose an atomic global launch reservation"
  grep -F 'if(pidFor(id) > 0 || _launching.contains(id)) {' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch reservation accepts a tracked or in-flight duplicate"
  grep -F 'if(it->pid != pid) continue;' "$patch" >/dev/null ||
    fail "AppLoad $firmware stale PID death can clear a newer generation"
  grep -F 'Q_INVOKABLE void reportLaunched(QString id, int pid, QObject *window)' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch callback does not match the QML int PID type"
  grep -F 'const QPointer<QObject> candidate(window);' "$patch" >/dev/null ||
    fail "AppLoad $firmware queued publication does not hold a safe window token"
  grep -F 'QMetaObject::invokeMethod(this, [this, id, pid, candidate] {' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware publishes a window before the caller can maximize it"
  grep -F '}, Qt::QueuedConnection);' "$patch" >/dev/null ||
    fail "AppLoad $firmware publication is not deferred one event-loop turn"
  grep -F 'Pluto AppLoad window publication rejected' "$patch" >/dev/null ||
    fail "AppLoad $firmware silently rejects window publication"
  grep -F 'if(it->pid != pid) {' "$patch" >/dev/null ||
    fail "AppLoad $firmware stale queued publication can replace a newer generation"
  grep -F 'candidateObject->property("appLoadId").toString();' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not validate window ownership"
  grep -F 'candidateObject->property("appPid").toLongLong();' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not validate window PID"
  grep -F 'QQmlEngine::setObjectOwnership(candidateObject,' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not make the dynamic window process-owned"
  grep -F 'QQmlEngine::CppOwnership);' "$patch" >/dev/null ||
    fail "AppLoad $firmware leaves the authoritative window JavaScript-owned"
  grep -F 'candidateObject->setParent(this);' "$patch" >/dev/null ||
    fail "AppLoad $firmware has no strong process-global QObject owner"
  grep -F 'current->windowToken != destroyedToken' "$patch" >/dev/null ||
    fail "AppLoad $firmware stale window destruction can clear a newer generation"
  grep -F 'authoritative window destroyed; terminating exact PID' "$patch" >/dev/null ||
    fail "AppLoad $firmware can leave a PID-only orphan after window destruction"
  grep -F 'appload::library::terminateExternal(pid);' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not terminate an exact orphaned PID"
  grep -F 'if(it->foregroundRequested) _foregroundEntry = id;' "$patch" >/dev/null ||
    fail "AppLoad $firmware marks foreground before a matching live window exists"
  grep -F 'if(pidFor(id) != pid) {' "$patch" >/dev/null ||
    fail "AppLoad $firmware stale close callback can clear a newer generation"
  grep -F 'QObject *windowFor(const QString &id, qint64 expectedPid,' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware cannot resolve a generation-specific window"
  grep -F 'it->pid != expectedPid' "$patch" >/dev/null ||
    fail "AppLoad $firmware window lookup does not enforce the requested PID generation"
  grep -F 'QObject *window = windowFor(id, pid, problem);' "$patch" >/dev/null ||
    fail "AppLoad $firmware activation is not gated by a matching live window"
  grep -F 'Q_INVOKABLE QObject *attachTrackedWindow' "$patch" >/dev/null ||
    fail "AppLoad $firmware cannot attach a global window to a recreated view"
  grep -F 'item->setParentItem(parentItem);' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not restore the visual parent on view recreation"
  grep -F 'window->setParent(this);' "$patch" >/dev/null ||
    fail "AppLoad $firmware reattach loses strong global ownership"

  if grep -F 'plutoWindows' "$patch" >/dev/null; then
    fail "AppLoad $firmware retains per-view Pluto process/window authority"
  fi
  grep -F 'function attachTrackedPlutoWindow(id)' "$patch" >/dev/null ||
    fail "AppLoad $firmware lacks the view recreation adapter"
  grep -F 'AppLoadLauncher.attachTrackedWindow(id, absoluteRoot);' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not reattach global state to the current QML root"
  grep -F 'existing.globalWidth = Qt.binding(function() { return _appLoadView.width; });' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware retains the old view width binding"
  grep -F 'existing.globalHeight = Qt.binding(function() { return _appLoadView.height; });' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware retains the old view height binding"
  grep -F 'existing.virtualKeyboardRef = _appLoadView.virtualKeyboardRef;' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware retains the old view keyboard/input context"
  grep -F '!AppLoadLauncher.beginLaunch(modelData.id)' "$patch" >/dev/null ||
    fail "AppLoad $firmware QML launch path bypasses the global in-flight guard"
  grep -F 'const existing = attachTrackedPlutoWindow(id);' "$patch" >/dev/null ||
    fail "AppLoad $firmware control callback does not reuse the global window"
  grep -F 'const launchedEntryId = modelData.id;' "$patch" >/dev/null ||
    fail "AppLoad $firmware queued callbacks retain a deletable model QObject"
  grep -F 'AppLoadLauncher.reportStopped(launchedEntryId, launchedPid);' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware close callback does not use immutable generation identity"
  grep -F 'if(pid > 0) library.terminateExternal(pid);' "$patch" >/dev/null ||
    fail "AppLoad $firmware cannot stop a tracked PID after its window disappears"

  qml_attach_line="$(grep -nF 'function attachTrackedPlutoWindow(id)' \
    "$patch" | cut -d: -f1)"
  qml_reservation_line="$(grep -nF \
    '!AppLoadLauncher.beginLaunch(modelData.id)' "$patch" | cut -d: -f1)"
  qml_launch_line="$(grep -nF \
    'win.appPid = library.launchExternal(modelData.id, qtfbKey, extraArgs || [], extraEnv || {});' \
    "$patch" | cut -d: -f1)"
  qml_registration_line="$(grep -nF \
    'AppLoadLauncher.reportLaunched(launchedEntryId, launchedPid, win);' \
    "$patch" | cut -d: -f1)"
  qml_connections_line="$(grep -nF 'Connections {' "$patch" | head -n 1 | cut -d: -f1)"
  qml_registration_count="$(grep -Fc \
    'AppLoadLauncher.reportLaunched(launchedEntryId, launchedPid, win);' "$patch")"
  [[ "$qml_registration_count" -eq 1 ]] ||
    fail "AppLoad $firmware emits duplicate QML launch registrations"
  [[ "$qml_attach_line" -lt "$qml_reservation_line" && \
      "$qml_reservation_line" -lt "$qml_launch_line" && \
      "$qml_launch_line" -lt "$qml_registration_line" && \
      "$qml_registration_line" -lt "$qml_connections_line" ]] ||
    fail "AppLoad $firmware does not reserve and queue one exact PID/window generation"

  grep -F \
    'connect(launcher_, &AppLoadLauncher::applicationLaunched, this,' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware does not reconcile late or UI-originated launches"
  grep -F 'if(pid <= 0 || !entryId.startsWith(prefix)) return;' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch reconciliation is not entry-scoped"
  grep -F 'if(!verifyManagedEntry(appId, entryId, &reason)) return;' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch reconciliation does not verify Pluto ownership"
  grep -F 'apps_.insert(appId, ManagedApp {appId, entryId, pid, true});' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware does not track launches reported by AppLoad"
  grep -F 'if(launchedEntryId != entryId || launchedPid <= 0) return;' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch wait accepts a signal for the wrong entry"
  grep -F 'launchTimer.start(kLaunchTimeoutMs);' "$patch" >/dev/null ||
    fail "AppLoad $firmware launch wait does not start its timeout"
  grep -F 'const qint64 trackedPid = launcher_->pidFor(entryId);' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch polling is not scoped to the requested entry"
  grep -F 'launchPollTimer.setInterval(kLaunchPollIntervalMs);' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch PID poll has no controlled interval"
  grep -F 'launchPollTimer.start();' "$patch" >/dev/null ||
    fail "AppLoad $firmware does not poll while waiting for launch"
  grep -F 'launchPollTimer.stop();' "$patch" >/dev/null ||
    fail "AppLoad $firmware leaves launch polling active after the result"
  grep -F 'void PlutoControlServer::reconcileManagedApps()' "$patch" >/dev/null ||
    fail "AppLoad $firmware cannot recover missed launch signals"
  grep -F 'for(const QString &entryId : launcher_->trackedEntries())' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware reconciliation does not inspect tracked entries"
  grep -F 'if(!entryId.startsWith(prefix)) continue;' "$patch" >/dev/null ||
    fail "AppLoad $firmware reconciliation is not Pluto-entry scoped"
  grep -F 'if(!verifyManagedEntry(appId, entryId, &reason)) continue;' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware reconciliation accepts an unverified entry"
  grep -F 'const bool hasLiveWindow = launcher_->windowFor(entryId, pid) != nullptr;' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware status does not prove a matching live window"
  grep -F 'pid, hasLiveWindow && entryId == foregroundEntry' "$patch" >/dev/null ||
    fail "AppLoad $firmware can report a stale PID/window generation visible"
  reconcile_calls="$(grep -Fc 'reconcileManagedApps();' "$patch")"
  [[ "$reconcile_calls" -ge 5 ]] ||
    fail "AppLoad $firmware does not reconcile status/launch/stop/screenshot boundaries"
  grep -F 'const auto awaitExactWindow = [&](qint64 expectedPid)' "$patch" >/dev/null ||
    fail "AppLoad $firmware cannot join an in-flight exact PID generation"
  grep -F 'if(launchedEntryId == entryId && launchedPid == expectedPid)' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware exact-generation join accepts the wrong launch signal"
  grep -F 'joinTimer.start(kLaunchTimeoutMs);' "$patch" >/dev/null ||
    fail "AppLoad $firmware exact-generation join is not bounded"
  grep -F 'if(!awaitExactWindow(existingPid)) {' "$patch" >/dev/null ||
    fail "AppLoad $firmware returns launch-pending instead of joining queued publication"
  grep -F 'tracked PID %1 did not publish its exact window: %2' "$patch" >/dev/null ||
    fail "AppLoad $firmware exact-generation timeout lacks a useful diagnostic"
  grep -F \
    'if(trackedPid <= 0 || !launcher_->windowFor(entryId, trackedPid)) return false;' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch polling accepts a PID without its matching live window"
  grep -F 'if(!launcher_->windowFor(entryId, pid, &windowProblem))' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware launch success accepts a PID without its matching live window"
  grep -F \
    'QObject *window = launcher_->windowFor(it->entryId, it->pid, &windowProblem);' \
    "$patch" >/dev/null ||
    fail "AppLoad $firmware screenshot can target a different PID/window generation"

  snapshot_line="$(grep -nF \
    'reconcileManagedApps(); // Snapshot the prior foreground before replacement.' \
    "$patch" | cut -d: -f1)"
  existing_pid_line="$(grep -nF \
    'const qint64 existingPid = launcher_->pidFor(entryId);' \
    "$patch" | cut -d: -f1)"
  exact_join_line="$(grep -nF 'if(!awaitExactWindow(existingPid)) {' \
    "$patch" | cut -d: -f1)"
  existing_return_line="$(grep -nF 'return commitLaunch(existingPid);' \
    "$patch" | cut -d: -f1)"
  connection_line="$(grep -nF \
    'const QMetaObject::Connection launchedConnection = connect(' \
    "$patch" | cut -d: -f1)"
  request_line="$(grep -nF \
    'launcher_->launchApplication(entryId, {}, {}, false);' \
    "$patch" | cut -d: -f1)"
  failure_line="$(grep -nF \
    'if(!launcher_->windowFor(entryId, pid, &windowProblem))' \
    "$patch" | cut -d: -f1)"
  final_commit_line="$(grep -nF 'return commitLaunch(pid);' "$patch" | cut -d: -f1)"
  replace_line="$(grep -nF 'QStringList closeEntries;' "$patch" | cut -d: -f1)"
  stop_line="$(grep -nF \
    'for(const QString &other : closeEntries) launcher_->stopApplication(other);' \
    "$patch" | cut -d: -f1)"
  replacement_clear_line="$(grep -nF \
    'if(replace) apps_.clear();' "$patch" | head -n 1 | cut -d: -f1)"
  visibility_clear_line="$(grep -nF \
    'for(auto it = apps_.begin(); it != apps_.end(); ++it) it->visible = false;' \
    "$patch" | tail -n 1 | cut -d: -f1)"
  managed_insert_line="$(grep -nF \
    'ManagedApp managed {appId, entryId, committedPid, true};' \
    "$patch" | cut -d: -f1)"
  [[ "$snapshot_line" -lt "$request_line" ]] ||
    fail "AppLoad $firmware does not snapshot the prior foreground before replacement launch"
  [[ "$existing_pid_line" -lt "$exact_join_line" && \
      "$exact_join_line" -lt "$existing_return_line" && \
      "$existing_return_line" -lt "$request_line" ]] ||
    fail "AppLoad $firmware emits a duplicate request instead of joining the tracked PID"
  [[ "$connection_line" -lt "$request_line" ]] ||
    fail "AppLoad $firmware subscribes after requesting launch"
  [[ "$request_line" -lt "$failure_line" && \
      "$failure_line" -lt "$final_commit_line" ]] ||
    fail "AppLoad $firmware commits a new generation before matching window acceptance"
  [[ "$replace_line" -lt "$stop_line" && \
      "$stop_line" -lt "$replacement_clear_line" ]] ||
    fail "AppLoad $firmware does not preserve the prior foreground after a failed launch"
  [[ "$stop_line" -lt "$visibility_clear_line" && \
      "$visibility_clear_line" -lt "$managed_insert_line" ]] ||
    fail "AppLoad $firmware can retain multiple visible managed apps after replacement"
done

cp -R "$PATCHES" "$TMP/patches"
rm "$TMP/patches/appload-3.28-pluto.patch"
expect_failure \
  'missing AppLoad 3.28 Pluto patch' \
  bash "$RECIPE" --verify-inputs --patch-root "$TMP/patches"

rm -rf "$TMP/patches"
cp -R "$PATCHES" "$TMP/patches"
printf '\n# tamper\n' >> "$TMP/patches/appload-3.27-pluto.patch"
expect_failure \
  'AppLoad 3.27 Pluto patch checksum mismatch' \
  bash "$RECIPE" --verify-inputs --patch-root "$TMP/patches"

cp "$LOCK" "$TMP/sources.lock"
printf '\nTAMPERED=1\n' >> "$TMP/sources.lock"
expect_failure \
  'integration lockfile checksum mismatch' \
  env PLUTO_INTEGRATION_LOCK_FILE="$TMP/sources.lock" \
  bash "$RECIPE" --verify-inputs

XOVI_REPO="$ROOT/.pluto-cache/src/xovi-v0.3.3"
EXTENSIONS_REPO="$ROOT/.pluto-cache/src/rm-xovi-extensions-v19"
QMLDIFF_REPO="$EXTENSIONS_REPO/qt-resource-rebuilder/qmldiff"
APPLOAD_REPO="$ROOT/.pluto-cache/src/rm-appload-3.28-minimal"
if [[ -e "$XOVI_REPO/.git" && -e "$EXTENSIONS_REPO/.git" && \
      -e "$QMLDIFF_REPO/.git" && -e "$APPLOAD_REPO/.git" ]]; then
  bash "$RECIPE" \
    --prepare-only \
    --offline \
    --cache "$TMP/cache" \
    --xovi-repo "$XOVI_REPO" \
    --extensions-repo "$EXTENSIONS_REPO" \
    --qmldiff-repo "$QMLDIFF_REPO" \
    --appload-repo "$APPLOAD_REPO" >/dev/null
  PREPARED="$TMP/cache/prepared"
  [[ -f "$PREPARED/PREPARED-SOURCES.txt" ]] ||
    fail "clean source preparation did not write provenance"
  [[ -f "$PREPARED/appload-3.27/src/PlutoControlServer.cpp" ]] ||
    fail "3.27 Pluto control patch was not applied"
  [[ -f "$PREPARED/appload-3.28/src/PlutoControlServer.cpp" ]] ||
    fail "3.28 Pluto control patch was not applied"
  for firmware in 3.27 3.28; do
    control="$PREPARED/appload-$firmware/src/PlutoControlServer.cpp"
    grep -F 'if(launchedEntryId != entryId || launchedPid <= 0) return;' \
      "$control" >/dev/null ||
      fail "$firmware prepared source lost the entry-filtered launch wait"
    grep -F 'apps_.insert(appId, ManagedApp {appId, entryId, pid, true});' \
      "$control" >/dev/null ||
      fail "$firmware prepared source lost AppLoad launch reconciliation"
    grep -F 'const qint64 trackedPid = launcher_->pidFor(entryId);' \
      "$control" >/dev/null ||
      fail "$firmware prepared source lost exact-entry PID polling"
    grep -F 'void PlutoControlServer::reconcileManagedApps()' \
      "$control" >/dev/null ||
      fail "$firmware prepared source lost request-boundary reconciliation"
    grep -F 'const bool hasLiveWindow = launcher_->windowFor(entryId, pid) != nullptr;' \
      "$control" >/dev/null ||
      fail "$firmware prepared source lost matching-window visibility"
    grep -F 'return commitLaunch(existingPid);' "$control" >/dev/null ||
      fail "$firmware prepared source lost same-PID launch idempotency"
    grep -F 'const auto awaitExactWindow = [&](qint64 expectedPid)' "$control" >/dev/null ||
      fail "$firmware prepared source cannot join queued exact-PID publication"
    grep -F 'if(!awaitExactWindow(existingPid)) {' "$control" >/dev/null ||
      fail "$firmware prepared source returns before queued publication completes"
    grep -F \
      'if(trackedPid <= 0 || !launcher_->windowFor(entryId, trackedPid)) return false;' \
      "$control" >/dev/null ||
      fail "$firmware prepared source accepts PID-only launch polling"
    grep -F 'QObject *window = launcher_->windowFor(it->entryId, it->pid, &windowProblem);' \
      "$control" >/dev/null ||
      fail "$firmware prepared source lost generation-safe screenshots"
    library="$PREPARED/appload-$firmware/src/AppLibrary.h"
    grep -F 'appID, pid, ref->second->isQTFB());' \
      "$library" >/dev/null ||
      fail "$firmware prepared source lost process-origin PID/foreground registration"
    launcher="$PREPARED/appload-$firmware/src/Launcher.h"
    grep -F '_processes.insert(id, TrackedProcess {pid, {}, foreground});' \
      "$launcher" >/dev/null ||
      fail "$firmware prepared source does not clear stale window generations"
    grep -F 'Q_INVOKABLE bool beginLaunch(const QString &id)' "$launcher" >/dev/null ||
      fail "$firmware prepared source lost global launch reservation"
    grep -F 'if(it->pid != pid) continue;' "$launcher" >/dev/null ||
      fail "$firmware prepared source accepts stale PID death callbacks"
    grep -F 'if(pidFor(id) != pid) {' "$launcher" >/dev/null ||
      fail "$firmware prepared source accepts stale window close callbacks"
    grep -F 'QObject *windowFor(const QString &id, qint64 expectedPid,' \
      "$launcher" >/dev/null ||
      fail "$firmware prepared source lost PID-specific window lookup"
    grep -F 'QMetaObject::invokeMethod(this, [this, id, pid, candidate] {' \
      "$launcher" >/dev/null ||
      fail "$firmware prepared source lost queued window publication"
    grep -F 'QQmlEngine::setObjectOwnership(candidateObject,' \
      "$launcher" >/dev/null ||
      fail "$firmware prepared source lost strong C++ window ownership"
    grep -F 'Q_INVOKABLE QObject *attachTrackedWindow' "$launcher" >/dev/null ||
      fail "$firmware prepared source cannot reattach a surviving window"
    grep -F 'current->windowToken != destroyedToken' "$launcher" >/dev/null ||
      fail "$firmware prepared source accepts stale window destruction"
    grep -F 'appload::library::terminateExternal(pid);' "$launcher" >/dev/null ||
      fail "$firmware prepared source leaves destroyed-window PID orphans"
    qml="$PREPARED/appload-$firmware/resources/qml/appload.qml"
    if grep -F 'plutoWindows' "$qml" >/dev/null; then
      fail "$firmware prepared source retains per-view Pluto authority"
    fi
    grep -F 'function attachTrackedPlutoWindow(id)' "$qml" >/dev/null ||
      fail "$firmware prepared source lost current-view window reattachment"
    grep -F 'existing.virtualKeyboardRef = _appLoadView.virtualKeyboardRef;' \
      "$qml" >/dev/null ||
      fail "$firmware prepared source retains stale view input context"
    grep -F '!AppLoadLauncher.beginLaunch(modelData.id)' "$qml" >/dev/null ||
      fail "$firmware prepared source lost global launch-in-flight protection"
    grep -F 'const launchedEntryId = modelData.id;' "$qml" >/dev/null ||
      fail "$firmware prepared source captures a deletable model QObject"
    [[ "$(grep -Fc \
      'AppLoadLauncher.reportLaunched(launchedEntryId, launchedPid, win);' "$qml")" -eq 1 ]] ||
      fail "$firmware prepared source duplicates or omits QTFB window registration"
  done
  grep -F 'Multiply BEFORE dividing' \
    "$PREPARED/appload-3.28/src/qtfb/FBController.cpp" >/dev/null ||
    fail "3.28 dirty-rectangle performance patch was not applied"
  grep -F "$APPLOAD_REPO" "$PREPARED/PREPARED-SOURCES.txt" >/dev/null &&
    fail "provenance leaked a machine-local source path"
fi

echo "PASS: locked ARMv7 integration source and patch workflow"
