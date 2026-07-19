# Native cutover implementation and benchmark report

Status: accepted. Runtime revision
`ed349d0b845412d77e9e83092472dffe39b60663` and one frozen universal artifact
set passed the final host, physical-device, optical, performance, lifecycle,
crash-recovery, and residue gates on RM1, RM2, and Move.

## Scope and acceptance rule

This cutover replaces the unpublished alternate ARMv7 display path with the
same native Pluto product architecture used by Move. RM1, RM2, and Move now
share discovery, provisioning, release assembly, application packaging,
supervision, lifecycle, rendering policy, input, control, logs, screenshots,
restore, uninstall, and documentation. Generated hardware profiles select only
the panel driver and genuine device capabilities.

The final result is accepted only when one clean release revision is deployed
to all three physical devices and camera evidence shows Pluto—not the stock
UI—running on each. Every device must show Home, open the switcher, change the
foreground app, launch Ink, render a deterministic real Flutter pointer stroke,
and return Home while the supervisor remains healthy. Installed hashes,
release/AOT process identity, completion receipts, screenshots, logs, and glass
must agree.

## Implementation result

The completed source cut has these boundaries:

- one generated profile source, with matched C++, Dart, and shell output;
- one public CLI flow and one `/home/root/pluto` runtime layout;
- one `native` presenter and `NativeDisplayBackend` contract;
- RM1 kernel-EPDC, RM2 userspace-WBF/LCDIF, and Move Gallery3/DRM drivers behind
  the factory;
- one transactional boot-first supervisor, health protocol, warm LRU,
  switcher, control socket, stock rescue, restore, and uninstall path;
- release AOT by default on both target slices, with ARMv7 intentionally
  release-only;
- target-native ARMv7 engine, embedder, and control client kept as first-class
  build inputs;
- Paper Codex declared `linux-arm64` only; the abandoned custom ARMv7 source
  recipe, patches, pin, artifacts, materializer, packaging/provisioning hooks,
  tests, documentation, and caches are removed;
- no compatibility reader, alias, migration, alternate provisioner, or second
  runtime flow for the device, package, presenter, handoff, or supervisor
  contracts replaced by this cutover.

The durable design is in
[native-display-architecture.md](native-display-architecture.md).

## Performance method

Optimization candidates are selected on the exact tablet that consumes them.
Each run records the executable hash and ABI, identity and boot ID, CPU topology
and governor, sample count and warm-up, temperature and memory envelope,
checksums or byte equality, and service state. Host numbers are useful for
regression detection but do not select an ARMv7 hot path.

Correctness and panel safety are hard gates. A faster candidate is rejected if
it can expose unacknowledged bytes, change an optical checksum, miss an RM2
phase deadline, weaken exact waveform/profile binding, or make rollback
ambiguous. Production keeps no runtime benchmark selector or dormant losing
algorithm.

### RM1 round 1: generated optical-state table

RM1 handoff derives one compact optical value for every RGB565 pixel. A
deterministic 65,536-entry table replaces per-pixel component extraction and
weighted arithmetic. The exact-device benchmark used 40 alternating measured
passes after four warm-ups on one CPU; every result matched checksum
`1577115660`.

| Exact RM1 path | p50 | p95 | p99 | Relative p99 |
| --- | ---: | ---: | ---: | ---: |
| arithmetic definition | 203.140 ms | 207.927 ms | 209.734 ms | 1.00x |
| generated 64 KiB table | 80.756 ms | 82.548 ms | 82.998 ms | **2.53x** |

The table was retained. Generation is reproducible, and a host regression
checks all 65,536 source values against the definition. Raw evidence and the
reproduction commands are under
[`analysis/native-cutover/performance/rm1-lut/`](../analysis/native-cutover/performance/rm1-lut/README.md).

### RM1 round 2: framebuffer mirror removal

RM1 must write new RGB565 bytes into `/dev/fb0` before submitting the kernel
update. If submission is rejected, Pluto must restore the exact previous mapped
bytes and must not expose the rejected frame through screenshot or warm
handoff. Three implementations were measured on the exact RM1:

| Candidate | Full-frame p50 | Medium p50 | Sparse p50 | Steady RSS effect | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| current exact mirror | 14.717 ms | 4.926 ms | 0.393 ms | baseline | retain |
| bounded rollback journal | 22.517 ms | 6.198 ms | 0.338 ms | about -5.1 MiB | reject |
| single copy, no rollback authority | 7.568 ms | 2.478 ms | 0.172 ms | about -5.1 MiB | unsafe; reject |

The only fail-closed mirror-free design was 53.0% slower for full updates and
25.8% slower for medium updates. It improved the tiny sparse case by 14.0%, but
its peak memory during a full update was effectively unchanged. The tempting
1.94–2.28x single-copy ceiling cannot restore pre-request state after a failed
submission. Production therefore retains the mirror. A regression now proves
that rejected overlapping and duplicate damage cannot leak into the mapped
framebuffer, snapshot, serialized handoff, or imported warm state.

Evidence is under
[`analysis/native-cutover/performance/rm1-framebuffer-mirror/`](../analysis/native-cutover/performance/rm1-framebuffer-mirror/README.md).

### RM1 round 3: resident-process memory bound

The supervisor's warm-LRU limit moved into the generated hardware profile.
RM1 admits at most two total resident release processes; RM2 and Move admit
four. The production override was removed. Shell regressions prove RM1 evicts
the oldest process at exactly that boundary and still cold-falls back when an
app does not acknowledge native-resource quiescence.

Final on-device CPU, RSS, zero-CPU stopped-process, switch latency, and optical
transition measurements will be recorded in the release table below.

### RM1 round 4: cross-app pigment cleanup

Exact release `6d7009e97da51141f08af0fb1d9581c5366bdb43`, universal
manifest SHA-256
`f3c59ea8ee2398b2908040d2b4675301ab70fcc343ac37f5077b4c312af3593a`,
completed all ten scripted RM1 interaction stages. Counter, Motion Lab, Ink
Lab, Validation Lab, Ink, the real switcher, a PID-bound deterministic Ink
stroke, and Home all ran as release AOT under the common supervisor. Native
screenshots were correct, the Ink stroke changed decoded pixels, and the
process/CPU/RSS/system-memory evidence bundle passed.

The release is nevertheless rejected on RM1. The camera frames under
`analysis/native-cutover/final-acceptance/6d7009e/rm1/` showed Motion Lab's
high-contrast vertical pattern and spinner retained across the following Ink
Lab and Validation Lab surfaces while their paired native screenshots were
clean. The objective visual verifier rejected the bundle with a `-0.098`
correct-pair discrimination margin. This proves that lifecycle, rendering, and
framebuffer state were correct while the existing RM1 `GC16_FAST`/PARTIAL
cross-app update was not a sufficient pigment cleanup.

Exact candidate
`63c0e0fe0826dcc633ec59eb05caceaffe2cb596` then tested a single
full-panel GC16/FULL admission at ambient temperature. The controlled
Motion-to-Ink Lab run under
`analysis/native-cutover/diagnostics/rm1-handoff-gc16-63c0e0f/` logged
`warm handoff full-panel GC16/FULL cleanup completed`. It removed the strong
spinner, box, and dark line but left faint Motion Lab vertical bands across
Ink Lab's settled field while the paired native screenshot contained only the
intended sparse canvas grid. This candidate is rejected optically.

A diagnostic SIGHUP then exercised the existing three-cycle pixel reset on
that same settled Ink Lab surface. Its black/white/content sequence completed
in `3450 ms` and removed the bands. The before/after camera stills and video in
the same evidence directory prove the bands were retained pigment rather than
camera lighting. The result also proves that using the entire 3.45-second
maintenance reset for every switch is unnecessary and too expensive.

Exact candidate
`dbd7e7dba28335153e8f357646d1799fcc190bc3`, universal manifest SHA-256
`b7dab5d0d1245273761c08b5923c3432916ba2487bff20202955e13df4bfd23c`,
then ran one DU black/white pair between the accepted and restored GC16 target.
The controlled transition appeared clean, but the complete ten-stage run under
`analysis/native-cutover/final-acceptance/dbd7e7d/rm1/` found a short dark
line from Motion Lab's lower-right fixture retained over the following Ink Lab
field. The paired native screenshot contains no such line. All shared apps,
the real switcher, the PID-bound Ink stroke, exact installed-byte proof, and
CPU/RSS/memory/thermal/presenter metrics passed, but the release is rejected
optically and has no visual-review receipt.

The next bounded candidate remains inside the RM1 presenter seam. After an
accepted handoff, the renderer's exact `{0,0,1,1}` Fast same-surface proof
remains a regional DU/PARTIAL request and consumes the one-shot decision
without a flash. Any other first physical request is promoted to a full-panel
GC16/FULL admission using the request's already-rendered complete surface.
After that marker completes, the same presenter job drives two full-panel DU
black/white pairs and a final GC16/FULL restore from the retained target
mirror. The second pair is the smallest escalation supported by the physical
failure and mirrors the already accepted RM2 conditioning count. The app
receives one completion only after the final marker. Ordinary UI, Text, Full,
and pen-truth requests keep their exact regional policy.

The sequence adds no Flutter frame, scheduler branch, public lifecycle state,
app buffer, setup path, or install flow. Retaining the first accepted target
in the existing RM1 mirror avoids another roughly 5.0 MiB target allocation
on the 512 MiB tablet. Focused tests prove complete-surface copy outside the
original damage, exact waveform order, delayed single completion, same-surface
suppression, Sparkle no-op handling, rejected-admission rollback and retry,
temporary-rail rejection restoration and fail-closed behavior,
claim-loss-before-write, and unchanged regional Full/pen behavior. Physical
Motion-to-Ink testing decides whether two bounded DU conditioning pairs are
sufficient. All 65 RM1 native tests pass normally and under ASan/UBSan and
TSan; the exact ARMv7 hard-float, GLIBC, GLIBCXX, and CXXABI gates and the
complete 18-test host release suite pass for the two-pair candidate.

### RM2 round 1: select tables on the Cortex-A7

The first exact-device encoder sweep compared the source-color conversion,
expanded WBF transition lookup, and complete phase build. It ran 100 measured
iterations after eight warm-ups on the exact accepted RM2 with checksum equality
and zero failures.

| RM2 candidate | p50 | p95 | p99 | Result |
| --- | ---: | ---: | ---: | --- |
| RGB565 arithmetic | 45.142 ms | 46.142 ms | 47.664 ms | retain definition |
| generated 64 KiB RGB565 table | 51.798 ms | 52.924 ms | 54.890 ms | **reject: 13% slower** |
| direct WBF transition decode | 192.548 ms | 199.169 ms | 201.195 ms | reference |
| expanded transition table | 20.928 ms | 21.222 ms | 21.279 ms | **retain: 9.38x p95** |
| original complete phase encode | 32.696 ms | 33.032 ms | 33.139 ms | reject: misses cadence |

This round demonstrates why table generation is measured rather than assumed:
the compact transition expansion is a major Cortex-A7 win, while the seemingly
obvious 64 KiB color table is slower and has been deleted. The original complete
phase builder could not meet the 11.763 ms profile interval and was prohibited
from release deployment.

### RM2 round 2: phase encoder deadline

The optimized encoder is accepted only at p99 no greater than 70% of one phase
interval (`8.234 ms`) and after a 10,000-job soak with zero checksum failures,
missed phases, underflows, or unsafe final state. Correctness and production
timing were run as separate exact-binary 10,000-phase soaks so the dual-core
tablet could cool between loads. The correctness pass compared every complete
1.46 MiB slot against the independent oracle: 10,000/10,000 matched, with zero
encode, reference, wake, or thermal failures and encode p99 `7.705 ms`. The
production pass completed 10,000/10,000 phases with encode p99 `7.682 ms` and
cadence p99 `11.984 ms`, leaving `0.552 ms` and `0.368 ms` of their respective
gates. It recorded zero pan, deadline, cadence, underflow,
latched-slot-mutation, post-reference, allocation, page-fault, or display-FD
failures.

The benchmark deliberately made no framebuffer mapping, pan ioctl, display
service stop, or panel write. It exercised the production encoder and scan
cadence against an exact mock transport while stock Xochitl remained active.
A later intermediate release rendered Pluto Home and Ink on the physical RM2;
that run exposed the retained-power-fault interpretation described in round 5
and is development evidence only. The corrected implementation still requires
the frozen same-revision physical rerun below.

Meeting the phase deadline requires a bounded `1.2 GHz` RM2 frequency lease.
Twenty acquire/release cycles measured `595.5 us` p50 and `7025.5 us` p99 to
acquire, and `221.6 us` p50 and `344.0 us` p99 to release. A deliberate
`SIGKILL` recovery restored the exact original
`792000/1200000/ondemand` policy and retired the mode-0600 receipt. The soak
peaked at `39 C`; the boot ID and stock service state did not change. An
earlier combined oracle-plus-production attempt completed all 10,000 oracle
comparisons but stopped the production half at its fail-closed thermal guard.
It is preserved as diagnostic evidence, not counted as the accepted timing
run.

### RM2 round 3: release runtime CPU and memory

The phase helper originally slept for a fixed 2 ms and then busy-spun for up to
4 ms after every encode. Replacing that loop with the existing condition
variable's direct wake retained deadline behavior while removing useless
helper-core work:

| Exact RM2 path | Process CPU / phase | Helper CPU / phase | Encode p99 | Cadence p99 | Memory/fault result |
| --- | ---: | ---: | ---: | ---: | --- |
| fixed sleep + spin, 2k baseline | 17.627 ms | 9.796 ms | 7.757 ms | 11.902 ms | RSS flat; zero faults |
| direct condition wake, 10k final | **15.381 ms** | **7.613 ms** | **7.682 ms** | 11.984 ms | RSS/PSS/VmSize/HWM flat; zero faults |

Process CPU fell **12.74%** and helper CPU fell **22.28%**. Caller CPU also
fell 1.09%; CPU/wall dropped from 1.485 to 1.288. The exact final ARMv7 binary
hash was
`26ec536c7b7f5971d22106b6ddf51b69f0d0b23802bb0772a68b7b4b0d336938`.
The benchmark opened no display descriptor and made no panel write. Afterward
the lease receipt and lock were absent, policy0 was exactly
`792000/1200000/ondemand`, Xochitl retained the same PID and boot ID, and the
device was at `35 C`.

The final physical release run still records supervisor and foreground RSS,
stopped-process CPU, total resident memory, switch latency, full/sparse damage,
panel temperature, and optical behavior. Any further allocation or copy
reduction must repeat checksum, deadline, soak, and optical gates.

### RM2 round 4: thermal-sample admission latency

The first physical multi-app release run exposed a kernel timing edge that the
host transport mocks could not reproduce. The i.MX7 thermal zone returned
`EAGAIN` often enough for the original 11 reads at 10 ms intervals, followed by
one whole-start retry, to exhaust while the supervisor launched the standby
child. Pluto performed no unsafe frequency raise or panel work and correctly
restored stock after its bounded foreground-failure budget, but the device
could not enter standby.

The public reMarkable i.MX thermal driver explains the failure mode: it programs
approximately 10 Hz auto-measurement, waits only 20--50 us when the `FINISHED`
bit is clear, and returns `-EAGAIN` if the sample is still unavailable. A fixed
10 ms grid can repeatedly miss the valid window. The retained implementation
reopens the exact sysfs attribute every 1 ms for at most 128 fresh attempts.
That spans 127 ms, more than one nominal sensor period, while preserving the
same fail-closed rules: no cached value, no frequency floor without valid
pre-raise and post-raise samples below 45 C, immediate failure for identity or
non-`EAGAIN` errors, and backpressure with exact policy restoration on bounded
exhaustion.

On the exact RM2, the target-native release benchmark called the production
temperature-read method for 1,000 independent windows. All 1,000 returned a
fresh valid 35--36 C sample with zero exhaustion, thermal hold, or other fault.
Monotonic latency was `6.062 ms` p50, `6.092 ms` p95, `13.114 ms` p99, and
`19.137 ms` maximum; allocation and RSS deltas were zero. The benchmark did not
acquire the frequency lease or touch the display: policy0 remained exactly
`792000/1200000/ondemand`, no receipt existed, and stock Xochitl retained the
same PID. The fixed attempt count still bounds sysfs work, with at most 127 ms
of explicit retry delay per sample. Final release standby and render acceptance
remains part of the same-revision table below.

### RM2 round 5: the retained-fault hypothesis

A physical multi-app run rendered Pluto Home and Ink, then failed closed during
a later switch. After stock recovery the SY7636A reported live
`power_good=OFF` with state `UVP at VN rail`; during the failed Pluto start,
the live rails had reached power-good while the same text remained visible.
That established that the text was not, by itself, proof of a current rail
failure. The intermediate implementation still assumed it would remain
unchanged during one presenter ownership interval. Round 8 rejects that
remaining hypothesis using both real-panel evidence and the official driver
source.

### RM2 round 6: post-blank rail decay

The first universal-release candidate
`22e26a0673b1a623225d93715cae7e84fd82f7e7` presented Home, Counter, and
Motion Lab on the physical RM2, then rejected Ink Lab startup at
`start.panel-powerdown-state`: the framebuffer was logically blanked while the
SY7636A still reported live `power_good=ON`. The supervisor recovered to Pluto
Home, so the tablet was not left UI-less, but the candidate correctly failed
final acceptance.

A read-only sysfs sampler around a later successful app switch observed the
real rail cycle at monotonic times `331551.35 ON`, `331553.38 OFF`, and
`331555.11 ON`. This does not measure the ioctl-to-rail delay by itself, but it
proves that `FBIOBLANK(POWERDOWN)` completion and the PMIC's settled `OFF` state
are separate lifecycle boundaries. Treating the first post-ioctl `ON` sample
as a permanent contradiction created an app-switch race.

The next exact release candidate,
`d9b2f479b4083a7160c7b8e05b8521bef6d86aa6`, retained that bounded wait. It
passed provisioning and camera-visible Home, but its first formal Counter
switch encountered the intermittent state again: an exact warm-handoff bundle
and safe idle existed while power-good remained `ON` for the entire 250 ms
window. Counter failed closed and the supervisor resumed Home, so this
candidate is also rejected.

An instrumented follow-up switched successfully through Validation Lab,
Counter, Motion Lab, Ink Lab, Ink, and the warm pool while sampling kernel
regulator counts. Normal shutdown removed the VCOM consumer, then SDOE, with
power-good falling roughly 50--100 ms later. The failing state is therefore not
ordinary slow rail decay and must not be hidden behind a longer sleep.

The retained startup contract polls the expected post-blank `ON` to `OFF`
decay at 2 ms intervals for at most 250 ms. At the deadline, `ON` is admissible
only when the strict incoming handoff is valid and the untouched live LCDIF
offset and bytes revalidate as the canonical safe-HOLD slot. Pluto records that
powered-safe-HOLD state, fills only inactive slots, and never rewrites the
scanned HOLD slot. A cold start, invalid or missing handoff, noncanonical live
slot, unreadable attribute, unknown state, or later power loss still fails
closed. Host coverage includes transient `ON, ON, OFF`, persistent `ON` without
a handoff, retained-powered valid HOLD, tampered HOLD, and unreadable sequences;
all 79 RM2 native tests pass. Physical acceptance must repeat on the next
frozen release.

### RM2 round 7: warm switcher acceptance and Ink proof timing

Exact candidate `1693a187b94eda8940974f79a3d0a5e6f323b121` and universal
manifest SHA-256
`0829aaa4aecf0f4755e90ae56c9dd77b88733e06f6fd26c8ca3a5b70875f1149`
provisioned through the common CLI and rendered camera-visible Pluto Home.
Counter, Motion Lab, Ink Lab, Validation Lab, and Ink then launched and
presented consecutively on RM2 without a deadline miss, underflow, presenter
loss, or stock fallback.

The first formal run stopped at the switcher even though the camera and native
state showed the real switcher, a healthy launcher, and a selectable Validation
Lab card. The acceptance predicate required
`--dart-entrypoint-args=--switcher` in the immutable launcher command line.
That is correct for a cold switcher host but impossible when the supervisor
reuses the normal warm Home process and routes it in place. The gate now accepts
exactly two release-launcher identities: the cold process with the switcher
entrypoint, or a hibernating launcher whose PID matches the supervisor's warm
registry. Both paths additionally require the exact live PID, ready file,
health receipt, switcher origin, and live warm origin app. Selection still goes
through the real Flutter center tap and must foreground the deterministic
Validation Lab process.

The no-flag path was recreated physically: normal Home PID `17291` was
cold-launched, hibernated behind Ink, resumed as the switcher host with the same
PID, and selected Validation Lab through the action-bound control receipt. The
following warm Ink exact-Full proof completed in 1.93 s.

One earlier post-switch Ink proof exceeded its strict four-second bound. A
retry on the same healthy PID completed in 2.49 s. Follow-up sampling retained
the four-second bound and produced:

- 10/10 quiescent exact-Full proofs in 1.92--1.96 s;
- 8/8 receipt-gated Validation Lab to warm Ink resumes, seven in
  1.93--1.95 s and one in 3.01 s;
- 6/6 switcher-selected Validation Lab to Ink cycles in 1.94--2.53 s; and
- the recreated no-flag warm-launcher cycle in 1.93 s.

The candidate is not final because its host acceptance predicate changed after
assembly. The replacement exact release must repeat the complete camera and
metrics gate from fresh evidence directories.

### RM2 round 8: fault-register text is a non-atomic diagnostic

Exact candidate `9aafb309e394d26e24cecf7db0383207d545d0c0` passed its clean
host, sanitizer, cross-ABI, and universal-release gates. In the formal physical
run, Counter rendered on RM2, but Motion Lab was then cold-restarted repeatedly.
The presenter rejected changes among `UVP at VN rail`, `UVP at VNEG rail`,
`UVP at VEE rail`, and `no fault event` at powered temperature and post-drive
checks even though every paired log reported `power_good=ON`, live rails in
regulation, zero underflows, and zero missed deadlines. The attempt under
`analysis/native-cutover/final-acceptance/9aafb30/rm2-attempt2/` is therefore
quarantined and cannot contribute final evidence.

The official reMarkable `zero-sugar` kernel at
`2be45d43a07299fcd7a19d4cb914880c53b054de` explains the observation.
`drivers/mfd/sy7636a.c` implements both `state_show` and `powergood_show` with
independent `regmap_read` calls to `SY7636A_REG_FAULT_FLAG` (`0x07`).
`state_show` shifts the sampled byte right by one and maps it to one of 16 text
values; `powergood_show` independently masks bit zero. The files are not an
atomic pair, and the driver provides no contract that the upper-bit text is
stable across panel phases or a presenter lifetime. Equality with a
powered-down text sample was therefore an invalid safety predicate.

The corrected reader samples `power_good`, then `state`, then `power_good`
again. Powered work proceeds only when both live samples are readable, equal,
and `ON`; a torn sample, unknown string, unreadable attribute, or live
power-good loss fails closed. During the expected post-blank rail decay, a torn
sample is retried only within the existing 250 ms bound. The 16 known state
strings remain diagnostic telemetry: changes are counted and logged at a
bounded rate, but no text-to-text transition restarts an otherwise healthy
app.

The same stable-live-power gates still enclose the powered temperature read,
cold INIT, phase zero, and the final safe-idle pan. No logical state or
completion callback advances before the post-drive gate. Focused host coverage
proves a deterministic torn `ON`-to-`OFF` sample, changing diagnostics during
cold start and multiple jobs, powered-down-to-powered text changes, unreadable
attributes, and real pre/post-drive power loss; all 79 RM2 native tests pass.
This correction is development evidence until a newly frozen release repeats
the complete physical and performance gate.

### RM2 round 9: warm-handoff pigment cleanup

Exact candidate `a71aed6bf1d4e5dca6907795a339d9288bcd4b89` and universal
manifest SHA-256
`2570550b6a6318d13bd0b97d75d0cf748029d468614d96d57b97cf29d3f142fd`
completed all ten scripted RM2 interaction stages and collected their process,
health, timing, CPU, RSS, memory, thermal, framebuffer, and camera evidence
under
`analysis/native-cutover/final-acceptance/a71aed6/rm2-final/`. It is rejected:
the camera showed Motion Lab's vertical pattern strongly retained over the
following Ink Lab and Validation Lab screens.

The pixel verifier correctly found a negative discrimination margin rather
than merely failing on alignment. The intended Ink Lab camera/native pair
scored `0.1929`, while the following ghost-contaminated Validation Lab camera
matched the Ink Lab native frame at `0.2580`, a `-0.0650` margin. From the
camera row, Ink Lab's intended match scored `0.1929` and the native Ink canvas
scored `0.2511`, a `-0.0581` margin. A later clean switcher could not identify
the cause: cumulative content passes and automatic maintenance had already
changed the glass. Automatic bleach restored clean Home but took about
`7.148 s`; a diagnostic SIGHUP black/white/blink/bleach/restore cycle took
about `9.942 s`. Either delayed multi-cycle sequence is too slow to make every
ordinary app switch optically correct.

RM2 maps both `Text` and `Full` to WBF mode 2 with 38 phases. The relevant
difference is that ordinary `Text` encoding zeros old-equals-new transition
cells, while `Full` retains the complete table. The first attempted correction
used that complete table for the already scheduled full-panel reconciliation.
Focused host coverage proved the intended cells were driven exactly once and
all 80 RM2 native tests passed.

Exact clean candidate `18cf107875a2c44c9e5648edc6d337400a4d1e2a`,
manifest SHA-256
`8d5a6492533ff5463e3ba7a0bfe0677cfb7a4bf43125cd59a4fce0853fe5d356`,
then disproved the correction on the physical RM2. It was provisioned through
the common CLI and logged
`warm handoff full-panel replay drives complete mode-2 transitions` with
`handoff_cleanup_jobs=1`, zero missed deadlines, and zero underflows. The
paired native Ink Lab frame was clean, but
`analysis/native-cutover/diagnostics/rm2-handoff-cleanup-18cf107/02-ink-lab-camera.jpg`
still showed Motion Lab's stripes, spinner, line, and box. This candidate is
rejected; diagonal mode-2 drive cannot substitute for a pigment precondition
when commanded target history and physical residue have diverged.

### RM2 round 10: AF white exit rail before content

The retained replacement follows the AF fast-mode exit rule inside the RM2
presenter. On the first common full-panel reconciliation after an accepted
handoff, the same admitted job first drives mode 6 to white from every recorded
source level, then drives complete mode-2 content from white to the incoming
target. At the measured 24 C table this is 10 plus 38 phases instead of a
7--10 second multi-cycle bleach.

The job keeps its original `target-new | recorded-old` byte per pixel. For each
precondition phase, a 256-byte stack LUT ignores the recorded target nibble and
selects `white | recorded-old`; for each content phase it ignores the recorded
old nibble and selects `target-new | white`. That avoids another 2.6-million
pixel key buffer, allocation, Flutter traversal, or frame copy. Stable live
power checks, cadence deadlines, safe-idle boundaries, final commit, and
failure blanking enclose both stages. A sparse same-app resume consumes the
handoff marker without the precondition, and later updates keep normal
old-equals-new suppression.

Focused coverage derives the exact phase counts from the bound WBF, observes
the white precondition, proves it occurs once, and proves the next identical
`Text` job returns to the ordinary suppressed phase stream; all 80 RM2 native
tests pass.

Exact clean candidate `b29e55838b3e82b8954974e1ae967136607a3516`,
manifest SHA-256
`1271e1706ac7f9372b2406a7c353408b1807ce69fc342e267aa8b27318342cad`,
was then provisioned through the common CLI. The timed
`analysis/native-cutover/diagnostics/rm2-handoff-white-b29e558/02-motion-to-ink-lab-camera.mp4`
and immediate/late frames still showed Motion Lab residue over Ink Lab.
Crucially, this did not disprove the white rail: after hibernation the exact
incoming activation reported two jobs, 76 phases, `requested_pixels=2640000`,
and `handoff_cleanup_jobs=0`. The physical panel has 2,628,288 pixels; the
total is one panel plus a preceding 11,712-pixel Text job. That smaller job
consumed the one-shot marker before the full-coverage job, so the new waveform
sequence never ran. This candidate is rejected for its trigger semantics.

### RM2 round 11: promote the first cross-app presenter job

The renderer replays the complete retained app surface, but its scheduler may
partition that reconciliation into several presenter jobs. RM2 therefore no
longer infers cross-app cleanup from one request's damage area. The exact
same-surface liveness contract is a single `{0,0,1,1}` `Fast` request; only
that request consumes the marker without a flash. Every other first request
after an accepted handoff is promoted inside the RM2 backend to one exact
full-panel `Text` job, then runs the mode-6 white precondition and complete
mode-2 content.

The promotion reads the already validated full input surface and replaces only
the backend job region and effective waveform class. It does not add a Flutter
frame, public lifecycle state, buffer, traversal, install path, or app-switch
flow. Focused coverage starts with a deliberately partial Text request, proves
that a sample outside its damage is driven by the promoted white/content
sequence exactly once, and separately proves the exact 1x1 same-surface probe
does not arm a later cleanup. All 81 RM2 native tests pass.

Exact clean candidate `03ee403f1399d286cdd325311ddf12f5d598d0dc`,
manifest SHA-256
`780f4bbc319f2b911dac74fdd7540a2ec2ba0fb0f48e0fa9f348d24633b6f30a`,
then proved the promotion and disproved the white-only waveform. The exact
release logged
`warm handoff full-panel replay completed white mode-6 precondition then complete mode-2 content`.
After hibernation it reported three jobs, 96 phases,
`handoff_cleanup_jobs=1`, zero missed deadlines, zero underflows, and zero
hardware faults. Nevertheless,
`analysis/native-cutover/diagnostics/rm2-handoff-promoted-03ee403/02-motion-to-ink-lab-camera.mp4`
and the paired late still retained Motion Lab's stripes, spinner, line, and box
strongly over the correct native Ink Lab frame. This candidate is rejected:
one white rail is not a sufficient pigment reset.

### RM2 round 12: bounded black/white rail pair

The next candidate uses the cheap physical reset already exercised by the
common ghost-control path, but executes it inside the same promoted RM2 job:
mode 6 from the recorded source to black, mode 6 from black to white, then
complete mode-2 content from white. At the measured 24 C table this is
10 + 10 + 38 phases, not the multi-second, multi-frame bleach state machine.

The same transition byte and 256-byte stack LUT are reused for all three
stages. The remaps select `black | recorded-old`, then the constant
`white | black`, then `target-new | white`; no new panel buffer or surface
walk is introduced. Safe-idle and stable-power boundaries remain between
every rail, and logical state commits only after final content succeeds.
Focused coverage observes drive at a sample outside the original partial
damage during both reset rails and content, proves the sequence occurs exactly
once, and retains the flash-free exact 1x1 same-surface proof. Physical
testing of exact clean candidate
`05b350380d784c7e1745a5b4f0e707d422032e2a`, universal manifest SHA-256
`56dbcfe61e86e6ca7d9558ab519cc48079d5a624f62c26dd5685c81e4285d478`,
proved that the sequence ran but rejected one cycle as insufficient. The
incoming activation logged
`warm handoff full-panel replay completed black/white mode-6 precondition then complete mode-2 content`.
After hibernation it reported one cleanup job, zero missed deadlines, zero
underflows, and zero hardware faults. The camera frame at
`analysis/native-cutover/diagnostics/rm2-handoff-black-white-05b3503/02-ink-lab-camera.jpg`
was dramatically cleaner than the white-only attempt, but Motion Lab's
vertical stress pattern remained faintly visible in Ink Lab's otherwise
uniform drawing field. Native screenshots contained no such structure. This
candidate is rejected optically rather than by timing, trigger, or logical
content.

### RM2 round 13: two bounded black/white rail cycles

The common ghost-control path's successful bleach uses two black/white cycles,
so the next candidate completes that same physical conditioning inside the
already promoted presenter job: recorded source to black, black to white,
white to black, black to white, then complete mode-2 content from white. At
the measured 24 C table this is `10 + 10 + 10 + 10 + 38 = 78` phases.

The first black rail selects `black | recorded-old`; the second selects the
constant `black | white`. Both white rails select `white | black`, and content
selects `target-new | white`. All five stages reuse the one transition-key
vector and a 256-byte stack remap. No second panel buffer, allocation, surface
walk, Flutter frame, lifecycle transition, setup path, or app-switch path is
introduced. Existing safe-idle and stable-power checks remain between every
stage, and failure before final content cannot commit logical state.

Focused coverage derives all 78 phases from the bound WBF, observes drive in
both rail cycles plus final content outside the originally requested partial
damage, proves the sequence occurs exactly once, and retains the flash-free
exact 1x1 same-surface proof. All 81 RM2 native tests pass.

Exact clean release `6d7009e97da51141f08af0fb1d9581c5366bdb43`, universal
manifest SHA-256
`f3c59ea8ee2398b2908040d2b4675301ab70fcc343ac37f5077b4c312af3593a`,
then passed the controlled physical Motion-to-Ink test. The camera video and
paired stills under
`analysis/native-cutover/diagnostics/rm2-handoff-two-cycle-6d7009e/` show the
high-contrast Motion Lab source, two black/white cycles, and a clean Ink Lab
target with no visible source stripes. Visible transition began at about
`4.10 s` and was stable by about `5.10 s`.

The exact activation logged one cleanup job and the expected two mode-6
black/white cycles followed by complete mode-2 content. Across three jobs it
recorded 126 phases, encode p50 `7.727 ms`, p95 `7.812 ms`, p99 `7.897 ms`,
maximum `7.913 ms`, zero missed phases, zero underflows, zero hardware faults,
and no buffer growth. This accepted the presenter-local optical sequence at
that intermediate stage; round 14 and the final table record the later
worst-case correction and all-device result.

### RM2 round 14: three cycles survive repeated formal stress

The controlled round-13 source-to-target trial was necessary but not a
sufficient worst-case history. During a later complete ten-stage formal run,
two correctly executed cycles left strong Motion Lab stripes, spinner, line,
and box over the following Ink Lab panel. The paired native Ink Lab screenshot
was clean. App and presenter logs proved that both cycles completed with zero
missed deadlines, underflows, power faults, or hardware faults, so the
candidate was rejected optically rather than by trigger, timing, or logical
content.

Final runtime revision
`ed349d0b845412d77e9e83092472dffe39b60663` adds one more mode-6
black/white pair before complete mode-2 content. The full sequence is recorded
source to black, black to white, white to black, black to white, white to
black, black to white, then target content from white. The original transition
key and 256-byte stack remap still encode every stage inside one promoted
presenter job. There is no second panel target, heap allocation, surface walk,
Flutter frame, lifecycle transition, or new app-facing control. The marginal
20 phases cost about 236 ms at the bound 24 C table.

The focused exact-revision Motion-Lab-to-Ink-Lab video under
`analysis/native-cutover/diagnostics/rm2-handoff-three-cycle-ed349d0b845412d77e9e83092472dffe39b60663/`
shows the bounded rail sequence and a clean stable Ink Lab target. The
back-to-back formal ten-stage run also remained clean. Its device log records
three black/white mode-6 cycles followed by complete mode-2 content, and the
camera/native pairs contain no tear, skipped content, or retained source
structure after settle. Three cycles are therefore the accepted RM2
cross-app bound; ordinary regional work, pen work, and the exact 1x1
same-surface liveness proof keep their non-flashing paths.

### Lifecycle acceptance: reject early external wakes

An intermediate RM1 soak entered deep suspend but woke early on later cycles.
Kernel timing showed sleeps of about 4.6 s, 0.83 s, and 0.75 s while the armed
RTC alarm remained tens of seconds in the future; the journal also recorded
physical short power-key events around one cycle. This is external/input wake
contamination, not evidence of a Pluto suspend failure. It did expose that one
brief SSH outage was insufficient acceptance evidence.

The hardware soak now binds each cycle to the exact next supervisor wake
receipt and the accepted RTC epoch. The supervisor samples `rtc0` immediately
after the blocking suspend command returns, before UI restoration or relaunch.
Acceptance requires that immutable receipt to fall within the fixed two-second
whole-clock tolerance on either side of the armed epoch, whether or not SSH
briefly became unreachable. It distinguishes early wake, late wake, and no
suspend receipt, and accepts slow USB transport only when the exact on-time
receipt exists. The final hands-off runs passed this stronger gate. RM1 and
Move each passed the complete 20-cycle plus crash command. RM2 passed all 20
exact cycles and physically recovered from the deliberate crash, but its
original host command then reported a false negative because journald vacuum
reduced the retained whole-boot receipt count. The corrected cursor-scoped
fixture and an exact-device crash supplement both pass, with zero post-cursor
wake receipts; the runtime needed no change.

## Final host and artifact gates

The device runtime and payloads are frozen at `ed349d0…`. The final host-only
acceptance commit descends from that revision and changes no installed binary
or payload. Detailed logs are under
`analysis/native-cutover/final-gates/ed349d0b845412d77e9e83092472dffe39b60663/`.

| Gate | Final result | Evidence |
| --- | --- | --- |
| profile/table regeneration | pass | complete repository quality gate |
| setup verification | pass | `setup-verify.log` |
| shell contracts | pass | complete repository quality gate |
| Dart format/analyze/tests/goldens | pass | complete repository quality gate |
| native debug/release CTest | pass | frozen-runtime native test records below |
| ASan/UBSan and focused TSan | pass | focused driver records below |
| ARMv7 ELF/ABI and product AOT | pass | frozen release and quality gate |
| AArch64 ELF/ABI and product AOT | pass | frozen release and quality gate |
| `linux-arm` payload assembly | pass | frozen release manifest |
| `linux-arm64` payload assembly | pass | frozen release manifest |
| source/build/payload residue denylist | pass | `residue-test.log` |
| calibrated visual-pixel regressions | pass, 17 cases | `visual-pixels-test.log` |
| lifecycle harness regressions | pass | `lifecycle-harness-test.log` |
| complete `./ci/check.sh` | pass | `ci-check.log` |

## Same-revision physical-device acceptance

All device cells refer to runtime revision `ed349d0…`, manifest SHA-256
`74b2b7223a2c388395a92539fc06aa40d9e7d14ac8d4186e6e34bb19eb5956fa`,
ARM embedder `0a300e01…6915c9`, ARM64 embedder `ee52ddec…eef4e`, and common
supervisor `8f3ff898…24e63`. “Visible” means a fresh camera frame or video of
the physical panel.

| Gate | RM1 | RM2 | Move |
| --- | --- | --- | --- |
| exact profile/kernel/panel/waveform accepted | pass | pass | pass |
| final release payload hash verified | pass | pass | pass |
| common supervisor healthy | pass | pass | pass |
| release/AOT process identity | pass | pass | pass |
| Pluto Home visible | pass | pass | pass |
| all target-supported apps launch and present | pass | pass | pass |
| switcher visible | pass | pass | pass |
| another app selected and visible | pass | pass | pass |
| Ink visible with deterministic pointer stroke | pass | pass | pass |
| Home return visible | pass | pass | pass |
| native Paper Codex capability | not applicable | not applicable | pass |
| screenshot, logs, and health agree with glass | pass | pass | pass |
| CPU, RSS, latency, thermal, and fault counters | pass | pass | pass |
| 20 exact RTC cycles and stroked-Ink restoration | pass | pass | pass |
| foreground-crash recovery | pass | pass, corrected cursor supplement | pass |
| final residue and installed-state audit | pass | pass | pass |

The evidence bundles are under
`analysis/native-cutover/final-acceptance/ed349d0b845412d77e9e83092472dffe39b60663/`,
`analysis/native-cutover/lifecycle/ed349d0b845412d77e9e83092472dffe39b60663/`,
and
`analysis/native-cutover/final-audit/ed349d0b845412d77e9e83092472dffe39b60663/`.

### Development optical smoke is not final acceptance

An intermediate RM1 candidate rendered Pluto Home, Counter, and the Ink gallery
on the physical panel through the native EPDC path. That established the first
camera-visible native RM1 render, but the original Ink control falsely reported
success while its before/after post-dither images were identical. The candidate
is therefore preserved only as development evidence and is not credited in the
table above. Final acceptance uses semantic canvas preparation, exact PID-bound
control receipts, decoded-pixel change checks, and paired camera/native evidence
from the frozen release.

## Final conclusion

Accepted. The three tablets run the same native Pluto product architecture,
with profile-selected panel drivers only at the true hardware boundary. Home,
the switcher, every target-supported app, deterministic Ink drawing, warm
suspend/resume, foreground-crash recovery, screenshots, logs, and health agree
with the physical panels. No tearing or skipped Ink segment was observed.
Move's transient Gallery 3 pigment during stress settles to the intended
content and is not described as zero transient pigment. Pluto owns the current
boot; stock remains the verified next-boot recovery owner because
boot-default enablement stays profile-gated.
