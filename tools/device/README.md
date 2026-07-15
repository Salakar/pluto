# Device runtime

This directory contains Pluto's device-side runtime, provisioning,
boot/recovery, diagnostics, and focused shell-contract tests. Users do not run
these scripts or select one of their implementations. The public contract is
the same on every supported tablet:

```sh
pluto provision --device "$DEVICE"
pluto run --device "$DEVICE" --release <app-id>
pluto logs --device "$DEVICE"
pluto screenshot --device "$DEVICE" -o shot.png
pluto provision --device "$DEVICE" --restore-remarkable
pluto provision --device "$DEVICE" --uninstall
```

The CLI probes immutable hardware and firmware identity, selects the matching
target payload, and provisions the same native supervisor/embedder lifecycle on
every supported tablet. Only the panel driver and exact hardware parameters
branch behind the generated device profile.

## Canonical on-device runtime layout

All device scripts and the `pluto` CLI target the same layout under
`/home/root/pluto` (override with `PLUTO_ROOT`):

```
/home/root/pluto/
  bin/       pluto-embedder, pluto-session.sh, and the device scripts
  engine/    release/libflutter_engine.so (normal launcher/apps)
             profile/libflutter_engine.so (profile AOT only)
             debug/libflutter_engine.so   (explicit hot reload only)
  launcher/  bundle/ + manifest.json (app id dev.pluto.launcher)
  apps/      <app-id>/{bundle/, manifest.json, install.json}
  appdata/   per-app data
  logs/      current.log and rotated supervisor/app logs
  state/     boot-mode, boot-confirmed, default-app, apps.rev, apps-changed
  staging/   install transaction scratch space
```

Both native targets promote payloads into this canonical root. Release
packages contain `bundle/lib/app.so` and never enter the VM-service or JIT
path. Debug/profile engines are optional capabilities of targets that advertise
them; unsupported targets reject those modes before writing. Supplying debug
payload content also requires explicit authorization, the Home launcher is
always release AOT, and ordinary Home taps never authorize JIT.

For CLI handoffs, the supervisor publishes the exact current child PID
in `/run/pluto/embedder.pid`. After writing the release/profile launch marker
or the one-shot debug marker, the CLI validates that PID against
`/proc/<pid>/exe`, requests a graceful stop, and uses a one-second hard-stop
fallback only if native shutdown wedges. This avoids process-name matching,
stale-PID signals, and launch requests waiting indefinitely behind an old app.
The foreground embedder also publishes the root-local
`/run/pluto/embedder-control.sock` endpoint documented in
[`embedder-control-protocol.md`](embedder-control-protocol.md).

## Move power button and standby

The supervisor pairs every normal embedder process with
`pluto-power-key-watch.sh`, which uses `evtest --grab` on the validated
power-key node (`platform-44440000.bbnsm:pwrkey-event`). A fresh
`KEY_POWER` down edge arms two mutually exclusive outcomes. Releasing before
two seconds follows the original standby path: only that matching release
writes `/run/pluto/standby`, atomically records the exact raw brightness in
`/run/pluto/standby-frontlight`, and asks that exact embedder pid to hibernate.
The physical key is therefore definitely up before suspend begins. Kernel
value-2 autorepeats are ignored and never reset the timer or select an action.

Holding continuously through two seconds instead atomically writes the current
app id to `/run/pluto/power-menu` and hibernates the same foreground embedder;
it neither snapshots the frontlight nor requests standby. The supervisor
publishes the cancel origin in `/run/pluto/power-menu-active` and temporarily
uses the warm launcher as a full-screen system host. A cold launcher host gets
the `--power-menu` Dart argument. Cancel is an ordinary `/run/pluto/launch`
request containing the saved origin, so the exact warm release/profile process
resumes. A non-warm or debug/JIT origin is terminated promptly instead of
waiting for the hibernate timeout; its safe cancel origin is Home because JIT
may not be resumed without a fresh explicit authorization. If the temporary
host crashes, the supervisor performs the same origin recovery it uses for the
switcher and status shade.

Confirming shutdown writes `/run/pluto/poweroff`. The supervisor consumes it,
drains every warm embedder, and invokes `systemctl poweroff`; tests may override
that command with `PLUTO_POWER_OFF_COMMAND`. It exits after a successful command
receipt. If the command fails, it logs the failure and cold-recovers the
launcher rather than leaving the panel without a UI. A bare or stale marker is
discarded unless the foreground is the launcher, its system-host role is the
power menu, and `/run/pluto/power-menu-active` still contains an origin.

The supervisor then launches the release-AOT launcher with the `--standby`
Dart argument and deliberately does not arm another watcher. The launcher
paints the static e-ink standby illustration, requests a full-class refresh,
then waits a conservative 1.9 seconds because SWTCON does not yet expose a
refresh-completion handshake. It sets the frontlight to zero, prepares the EPD
regulator for immediate power-off, writes the one-shot
`/run/pluto/suspend` marker, and exits. Preparation sets `vpdd_length` to
zero while the CRTC is still active: otherwise normal display teardown starts
the firmware's deliberate 30-second delayed-VPDD timer, during which the
kernel rejects suspend with `EAGAIN`. The next normal presenter open reapplies
the standard 30,000 ms interactive hold.

Only after `run_app` has waited for and closed that standby child does the
supervisor consume the marker. It asserts that the frontlight remains zero,
requires the driver's read-only `vpdd_timeout_ms` value to reach zero, waits an
additional quiesce interval (`PLUTO_SUSPEND_QUIESCE_DELAY`, default `0.5`
seconds), and runs `systemctl start --wait suspend.target`. The ordinary
`systemctl suspend` verb is asynchronous and returns after merely queueing the
job; `start --wait` does not return until the target terminates after wake or a
failed suspend. `PLUTO_SUSPEND_COMMAND` may override this in tests, but its
command must preserve that blocking contract. No embedder or power-key watcher
remains alive across the call, so the second power press belongs to the kernel
wake path instead of recursively requesting standby. Using the firmware target
rather than writing `/sys/power/state` directly preserves its Wi-Fi, regulator,
wake-source, hibernation, slumber-telemetry, and OP-TEE hooks.

After the suspend command returns on wake, or reports failure, the supervisor
restores the exact raw value saved by the power watcher and starts the normal
launcher with a fresh one-shot watcher. A standby child that crashes or exits
without the fresh suspend marker never invokes suspend; the supervisor still
restores the persisted light as failure recovery. Stale suspend markers are
cleared at supervisor startup and before each standby child, and the saved
frontlight marker is deleted only after the sysfs restore succeeds.

## Native boot-first mechanism

`pluto-boot-install.sh install` writes a persistent drop-in at
`/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf` (rootfs remounted
rw) that replaces `xochitl.service`'s `ExecStart` with
`$ROOT/bin/pluto-session.sh start`. The display service then boots the
Pluto supervisor + launcher instead of reMarkable's UI; stock `xochitl` is
never started. The drop-in orders startup on the persistent Pluto home mount,
clears `OnFailure`, disables xochitl's inherited 60-second watchdog and service
restart policy, and overrides the process. The supervisor owns recovery, so a
missing `sd_notify` heartbeat cannot create a watchdog/start-limit loop.

Both install and uninstall remove the exact obsolete Pluto-owned standalone
`pluto.service` and `pluto-fallback.service` units and enablement links from
the live and peer OTA A/B roots. Install applies the xochitl drop-in only to the
currently selected root and removes any older Pluto override from the peer,
leaving that peer as a known-stock U-Boot rescue path. Unrelated systemd units
are untouched. `uninstall` removes the live drop-in too and restarts stock
xochitl.
The supervisor detects the hijack (`hijacked()`) so "exit to stock" execs
`/usr/bin/xochitl` directly instead of restarting the service it runs as.

The tested Move firmware's `rm-reset-boot-count.service` resets the selected
root's error counter during graceful shutdown and remains enabled. Pluto adds an earlier,
readiness-gated confirmation: the embedder atomically publishes
`/run/pluto/boot-ready` only after the presenter accepts its first real
frame; the supervisor then waits for a 30-second stable window, invokes the
firmware-owned `/usr/sbin/rm-reset-boot-count.sh`, and reads the active root's
sysfs counter back as zero. A missing frame, missing OEM helper, emergency-mode
guard, or failed readback withholds confirmation so U-Boot can fall back to the
stock peer root. No boot partition attributes are written by Pluto.

Selected internally by the CLI: `pluto provision` (boot-first by default,
`--no-boot-default` to stage only), `pluto provision --restore-remarkable`
(stock boots again, runtime kept), `pluto provision --uninstall` (full
removal via `pluto-uninstall.sh`, which also removes the drop-in), and
`pluto cleanup [--apply]` (stale logs, orphaned apps, probe files, backup
binaries, staging leftovers).

Full removal delegates boot restoration to `pluto-boot-install.sh` before
deleting `/home/root/pluto`. If inactive-slot cleanup cannot be verified, it
restores stock on the live slot but exits nonzero and preserves the runtime;
this prevents a later A/B flip from booting an override whose supervisor was
deleted.

`PLUTO_ROOT=<staged-root> pluto-boot-install.sh validate` performs the
release-AOT launcher/runtime gate without remounting the root filesystem or
changing boot state. Provisioning runs the same requirements before installing
the persistent override.

After a real provision, run
`tools/device/test/release-aot-hardware-smoke.sh <user@device>`. It drives all
standard apps through the public CLI, requires each new embedder to atomically
publish a fresh successful-present marker, validates its exact release/AOT
command line, and finishes back on the launcher. The opt-in device-lab workflow
runs the same check automatically.
