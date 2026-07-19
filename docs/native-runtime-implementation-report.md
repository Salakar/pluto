# Native runtime cutover implementation report

Date: 2026-07-19

Runtime revision:
`6aadd9886c0f5409eb575940f35e1349d88bbcb9`

Status: final acceptance is being serialized across the three USB-connected
tablets. The release and the RM1/Move optical runs are accepted; the remaining
RM2 optical and final lifecycle rows are intentionally not pre-declared here.

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
| universal release manifest | `99a865fa47656758639984b358c04cfa4e01ff3c448e334b761ce06d798dda1d` |
| AArch64 embedder | `e642ffa2835ef879fa6013968bd711600b429c81bc31c2adeb63ce7baea5f1ff` |
| ARMv7 hard-float embedder | `de234470e16a19e6acac143e5303799c3978ee14142c1fcf4dcec25190e6b27b` |
| common supervisor, both slices | `bb6907ef4fc15f09ff676ee4926de06b3af7824629fe48c7e76caed87ae13d32` |

The exact hash list is preserved in
`analysis/native-cutover/final-release/6aadd9886c0f5409eb575940f35e1349d88bbcb9/artifact-hashes.txt`.

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
| reMarkable 1 | `rm1` | `linux-arm` | `de234470…e6b27b` | active | inactive | 0 / 0 |
| reMarkable 2 | `rm2` | `linux-arm` | `de234470…e6b27b` | active | inactive | 0 / 0 |
| Paper Pro Move | `move` | `linux-arm64` | `e642ffa2…f1ff` | active | inactive | 0 / 0 |

The post-install audit is
`analysis/native-cutover/final-release/6aadd9886c0f5409eb575940f35e1349d88bbcb9/post-install-fence.txt`.

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
| all target-supported apps | pass | pending final optical run | pass |
| real switcher and selected app | pass | pending final optical run | pass |
| blank-to-stroked Ink on glass | pass | pending final optical run | pass |
| Home return on glass | pass | pending final optical run | pass |
| calibrated 10-stage verifier | pass, `ink_overlap=1.0000` | pending | pass, `ink_overlap=1.0000` |
| Paper Codex | not applicable | not applicable | supported |

Accepted optical evidence:

- `analysis/native-cutover/final-acceptance/6aadd9886c0f5409eb575940f35e1349d88bbcb9/rm1/`
- `analysis/native-cutover/final-acceptance/6aadd9886c0f5409eb575940f35e1349d88bbcb9/move/`

The lifecycle gate preserves the same Home and Ink PIDs across twenty exact
RTC-bound suspend/resume cycles, restores the stroked Ink surface, and proves
foreground-crash recovery. USB-connected tablets are tested serially: making
several USB gadget interfaces disappear together can delay host interface
re-enumeration even when the on-device RTC receipt is exact.

| Lifecycle gate | RM1 | RM2 | Move |
| --- | --- | --- | --- |
| 20 exact RTC suspend/resume cycles | pending serialized final | pending serialized final | pending serialized final |
| same Home PID and advancing health | pending | pending | pending |
| stroked Ink restore | pending | pending | pending |
| foreground crash recovery | pending | pending | pending |

## Host and artifact verification

The final sign-off runs:

- deterministic profile regeneration and setup verification;
- Dart formatting, analysis, workspace/CLI tests, and goldens;
- native debug/release CTest plus focused sanitizers;
- ARMv7 hard-float and AArch64 ELF/library-ceiling gates;
- product-AOT validation and both universal release slices;
- source/build/payload residue denial;
- the complete `./ci/check.sh`.

Final results will be recorded here only after the serialized physical runs no
longer contend for host USB transport.

## Acceptance decision

Pending the RM2 optical run, all three serialized lifecycle soaks, the final
full host gate, and a final three-panel Home frame. No pending item requires a
second runtime architecture or compatibility work.

