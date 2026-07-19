# Native runtime cutover implementation report

Date: 2026-07-19

Runtime revision:
`ed349d0b845412d77e9e83092472dffe39b60663`

Status: complete. The frozen release, all three optical runs, the serialized
lifecycle/crash gates, the final installed-state audit, and the host quality
gate are accepted.

## Outcome

Pluto now has one native product runtime for reMarkable 1, reMarkable 2, and
Paper Pro Move. The three devices share the CLI, generated hardware discovery,
release assembler, package contract, transactional provisioner, runtime root,
supervisor, Flutter host, compositor, frame ledger, scheduler, input pipeline,
application lifecycle, switcher, screenshots, logs, recovery, restore, and
uninstall. Exact hardware identity selects only the panel driver and real
device capabilities.

There is one on-device presenter name, `native`, and one common session
supervisor. No compatibility reader, backend selector, migration route, second
provisioner, or dormant alternate display flow remains. ARMv7 stays a
first-class release-AOT target; Paper Codex remains available only in the
native `linux-arm64` slice.

## Frozen release

The universal release was assembled from a clean implementation revision and
passed the target ABI, engine-pin, product-AOT, and release-manifest gates.

| Artifact | SHA-256 |
| --- | --- |
| universal release manifest | `74b2b7223a2c388395a92539fc06aa40d9e7d14ac8d4186e6e34bb19eb5956fa` |
| AArch64 embedder | `ee52ddec49eb66f4e3750cee64e59a3e1e5e4735deafa04d574b4b29ac7eef4e` |
| ARMv7 hard-float embedder | `0a300e01a248018df506600abd7365bb9dc9328220c47c0f973f968dce6915c9` |
| common supervisor, both slices | `8f3ff898784ebe7083f4093938cb450bd08136c859116a3b3e030d0435e24e63` |

The exact hash list is preserved in
`analysis/native-cutover/final-release/ed349d0b845412d77e9e83092472dffe39b60663/artifact-hashes.txt`.

## Architecture delivered

| Profile | Target | Native driver | Real completion boundary |
| --- | --- | --- | --- |
| `rm1` | `linux-arm` | kernel MXCFB/EPDC | matching update-marker completion |
| `rm2` | `linux-arm` | device WBF plus LCDIF scanout | final phase latch followed by canonical safe hold |
| `move` | `linux-arm64` | Gallery 3 program plus DRM | DRM/panel job completion |

The source of routing truth is `config/device_profiles.json`. Deterministic
generation produces matching C++, Dart, and BusyBox-shell tables. Selection is
conjunctive: machine, compatible, ABI, firmware, kernel, geometry, input
identity, panel signature, and waveform digest must agree. Both the host probe
and the embedder independently fail closed before a panel write.

Every device installs under `/home/root/pluto` and runs
`pluto-session-once.service`. The common supervisor owns:

- release app launch and health;
- Home, the running-app switcher, standby, and power handling;
- bounded warm hibernation with a profile-owned resident-process limit;
- exact glass handoff between renderer processes;
- screenshot and action-bound physical Ink acceptance controls;
- boot confirmation, stock rescue, restore, and uninstall.

RM1 retains at most two resident release processes. RM2 and Move retain at
most four. A stopped process must first detach native resources; otherwise it
is killed and later cold-launched.

## Display correctness and lifecycle fixes

### RM1

RM1 writes exact RGB565 damage to the mapped EPDC framebuffer, submits one
kernel request, and waits for its marker. A full settled mirror is retained
because framebuffer bytes must be written before submission and therefore
need exact rollback authority if the kernel rejects the request.

Physical high-contrast transitions rejected an ordinary partial replay, one
full GC16 replay, and one conditioning pair. The retained first substantive
handoff job uses the already-rendered complete target, drives two bounded
black/white conditioning pairs, restores the target with GC16/FULL, and
publishes one completion only after the final marker. Same-surface liveness
proofs and ordinary regional/pen work keep their non-flashing paths.

### RM2

RM2 validates and decodes the exact device-owned WBF, builds immutable
transition tables, writes phase slots directly into the kernel-reported LCDIF
mapping, and never mutates a latched slot. Every powered operation is bracketed
by stable `power_good` samples; waveform state commits only after final
content and safe hold.

The finite warm-handoff chain deliberately ends without a successor bundle.
On that cold rollover the common supervisor now discovers the unique readable
SY7636A `power_good` attribute and requires two consecutive `OFF` samples,
20 ms apart, within a fail-closed five-second envelope before starting the
next presenter. This preserves the handoff chain cap and the hibernated Flutter
PID without allowing two panel owners to overlap.

An unexpectedly killed RM2 renderer is reaped before the supervisor writes the
kernel framebuffer `blank` attribute to `POWERDOWN`, then requires the same
stable two-sample `OFF` proof before recovering to Home. This closes the
physical owner boundary that orderly handoff metadata cannot supply after a
crash.

The first substantive cross-app reconciliation job promotes the retained
complete target into one full-panel presenter job. Three bounded mode-6
black/white conditioning cycles precede complete mode-2 target content. The
same transition-key vector and 256-byte stack remap are reused, so the third
cycle adds no Flutter traversal, target copy, heap allocation, lifecycle path,
or app-visible API. Repeated formal Motion Lab stress rejected two cycles;
three cycles produced a clean following Ink Lab panel on the exact device.

### Move

Move retains its Gallery 3 and DRM implementation behind the same presenter
contract. Exact-color handoff, pen preview/truth, automatic ghost maintenance,
warm lifecycle, frontlight, and recovery remain common capabilities rather
than a separate product route.

### Common supervisor

A release launch request for the already healthy foreground app is now an
idempotent no-op. Control markers retain their 50/100 ms profile cadence, while
the expensive health-clock check runs only on the existing one-second safety
cadence. The latter removes repeated child-process work; physical sampling did
not show a material reduction in supervisor self-CPU, so no such claim is made.

## Installation state

All three tablets were provisioned transactionally from the same universal
manifest for the current boot. Stock remains the verified next-boot recovery
owner because boot-default enablement is still profile-gated.

| Device | Profile | Slice | Installed embedder | Common service | Stock UI while Pluto owns panel | Removed-runtime paths/processes |
| --- | --- | --- | --- | --- | --- | ---: |
| reMarkable 1 | `rm1` | `linux-arm` | `0a300e01…6915c9` | active | inactive | 0 / 0 |
| reMarkable 2 | `rm2` | `linux-arm` | `0a300e01…6915c9` | active | inactive | 0 / 0 |
| Paper Pro Move | `move` | `linux-arm64` | `ee52ddec…eef4e` | active | inactive | 0 / 0 |

The post-install audit is
`analysis/native-cutover/final-release/ed349d0b845412d77e9e83092472dffe39b60663/`.

## Physical acceptance

The formal visual smoke launches Counter, Motion Lab, Ink Lab, Validation Lab,
Ink, the real switcher, a selected Validation Lab card, a fresh blank Ink
canvas, an action-bound 24-event Flutter stylus stroke, and Home. Every stage
has a paired post-dither PNG and calibrated camera frame. Collection alone
does not pass: a human review receipt and the pixel-assignment verifier are
both required.

| Gate | RM1 | RM2 | Move |
| --- | --- | --- | --- |
| exact installed revision/profile/manifest | pass | pass | pass |
| common supervisor and release/AOT identity | pass | pass | pass |
| all target-supported apps | pass | pass | pass |
| real switcher and selected app | pass | pass | pass |
| blank-to-stroked Ink on glass | pass | pass | pass |
| Home return on glass | pass | pass | pass |
| calibrated 10-stage verifier | pass, alignment `0.3470`, pair min `0.1950`, Ink overlap `1.0000` | pass, alignment `0.3258`, pair min `0.1774`, Ink overlap `1.0000` | pass, alignment `0.5911`, pair min `0.4613`, Ink overlap `1.0000` |
| Paper Codex | not applicable | not applicable | pass: UI visible, `codex-cli 0.144.1` spawned |

Accepted optical evidence:

- `analysis/native-cutover/final-acceptance/ed349d0b845412d77e9e83092472dffe39b60663/rm1/`
- `analysis/native-cutover/final-acceptance/ed349d0b845412d77e9e83092472dffe39b60663/rm2/`
- `analysis/native-cutover/final-acceptance/ed349d0b845412d77e9e83092472dffe39b60663/move/`

The lifecycle gate preserves the same Home and Ink PIDs across twenty exact
RTC-bound suspend/resume cycles, restores the stroked Ink surface, and proves
foreground-crash recovery. USB-connected tablets are tested serially: making
several USB gadget interfaces disappear together can delay host interface
re-enumeration even when the on-device RTC receipt is exact.

| Lifecycle gate | RM1 | RM2 | Move |
| --- | --- | --- | --- |
| 20 exact RTC suspend/resume cycles | pass | pass | pass |
| same Home PID and advancing health | pass | pass | pass |
| stroked Ink restore | pass | pass | pass |
| foreground crash recovery | pass, zero post-cursor wake receipts | pass, stable PMIC `OFF` and zero post-cursor wake receipts | pass, zero post-cursor wake receipts |

RM1 and Move passed the complete 20-cycle plus crash command. RM2 passed all
20 cursor-bound cycles and restored the original stroked Ink PID; its correct
physical crash recovery then exposed a host-harness defect when journald
vacuum reduced the retained whole-boot wake count from 16 to 8. The harness now
binds crash recovery to its own pre-kill journal cursor and requires zero new
wake receipts. Its fixture and a focused exact-device supplement pass. The
runtime needed no change.

Lifecycle evidence:

- `analysis/native-cutover/lifecycle/ed349d0b845412d77e9e83092472dffe39b60663/rm1-final-serial/`
- `analysis/native-cutover/lifecycle/ed349d0b845412d77e9e83092472dffe39b60663/rm2-final-serial/`
- `analysis/native-cutover/lifecycle/ed349d0b845412d77e9e83092472dffe39b60663/rm2-crash-cursor-supplement/`
- `analysis/native-cutover/lifecycle/ed349d0b845412d77e9e83092472dffe39b60663/move-final-serial/`

## Host and artifact verification

The final sign-off passed:

- `./tools/setup/setup.sh --verify`;
- the 17-case calibrated visual-pixel regression suite;
- the lifecycle harness regression suite, including journal vacuum during
  crash recovery;
- source/build/payload residue denial;
- the complete `./ci/check.sh`;
- final `git diff --check`.

Evidence is under
`analysis/native-cutover/final-gates/ed349d0b845412d77e9e83092472dffe39b60663/`.

The final live audit put Home in the foreground on all three tablets and
rechecked the installed release revision, profile, release/native process
identity, common service, stock-service exclusion, embedder and supervisor
hashes, installed app set, removed-runtime path/process count, and next-boot
owner. All three report the exact frozen hashes, zero removed-runtime
paths/processes, transient Pluto for the current boot, and stock Xochitl first
on the next boot. The simultaneous rig frame and command transcripts are under
`analysis/native-cutover/final-audit/ed349d0b845412d77e9e83092472dffe39b60663/`.

## Acceptance decision

Accepted. Pluto Home, the switcher, every supported common app, physical Ink
drawing, warm suspend/resume, crash recovery, and the Move-only Paper Codex
capability all run through the common native supervisor and renderer contract
on the three physical tablets. Stock remains the tested recovery/next-boot
owner; it is not a runtime rendering fallback.
