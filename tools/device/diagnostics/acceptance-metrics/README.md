# Exact-device acceptance metrics

`collect.sh` creates the read-only metrics bundle used beside camera captures
in the final all-device release acceptance run. It never uploads a helper,
changes a service, signals a process, or writes to the tablet. The POSIX shell
collector is streamed to `sh -s`; all files it creates are on the host.

For a tunneled RM1 or RM2 connection:

```bash
tools/device/diagnostics/acceptance-metrics/collect.sh \
  --device root@127.0.0.1 \
  --port 22202 \
  --samples 8 \
  --interval-seconds 1 \
  --release-manifest build/pluto-release/release-manifest.json \
  --output analysis/native-cutover/final-acceptance/rm1/metrics
```

Use the same command without `--port` for a direct USB/Wi-Fi endpoint. The
optional local manifest is read and hashed on the host; its Git revision and
target slice tree digest must match the connected device's installed release
revision and detected target.

The output directory is atomic and must not already exist. A failed remote
receipt, transport interruption, or malformed local manifest leaves no output
directory that could be mistaken for a passing bundle.

## Bundle schema

- `device-evidence.txt`: `format=pluto-acceptance-evidence`, ending with the exact
  terminal line `collection.status=PASS`. It includes immutable profile,
  firmware, kernel and boot identity; installed revision and critical payload
  hashes; exact supervisor/foreground/warm process cmdlines; bounded raw Linux
  CPU tick and RSS/HWM/thread/FD samples; completion-health progression; the
  profile-selected panel temperature; backend timing/fault telemetry; and
  activation-scoped service/kernel journal digests and fault counts.
- `commands.log`: UTC-stamped host and remote read-operation transcript.
- `summary.txt`: one-record `format=pluto-acceptance-bundle` index.
- `manifest-proof.json`: optional exact pinned-Dart proof that the complete
  immutable installed file set equals the selected, locally verified release
  slice, including runtime tools, engines, Codex when shipped in-slice,
  build metadata, manifests, assets, and complete AOT bundles.
- `SHA256SUMS`: digest of every other bundle member.

The collector accepts the common `pluto-session.sh start` supervisor only when
its exact process is the healthy main PID of either boot-first
`xochitl.service` or device-profile-gated current-boot
`pluto-session-once.service` with stock `xochitl` inactive. The same check
applies to every profile whose `bootDefaultEnabled` recovery gate is closed;
unit names alone are never process evidence. It also requires at least one
non-foreground warm release/AOT process to remain `SIGSTOP`ped throughout
sampling.

Profile telemetry is fail-closed:

- RM1 requires the final `mxcfb: damage telemetry` update/damage amplification
  receipt and records warm-handoff rejection count.
- RM2 requires the final `lcdif_tcon: telemetry` receipt with encoder
  percentiles, phase/job counts, safe holds, and zero missed deadlines,
  underflows, or hardware faults.
- Move requires final `swtcon stats` timing/completion evidence with zero
  dropped pieces and color faults.

Run the host/fixture contract without a device:

```bash
/bin/bash -p tools/device/test/acceptance-metrics_test.sh
```
