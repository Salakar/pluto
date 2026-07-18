# Native cutover implementation and benchmark report

Status: final all-device release acceptance is in progress. Measured development
rounds are recorded below; the release tables remain explicitly unaccepted
until the same clean revision and artifact set passes on all three tablets.

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
tests pass. This is development evidence until a clean release repeats the
Motion Lab to Ink Lab and Validation Lab sequence on the tablet.

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
receipt exists. The final 20-cycle runs must be hands-off and pass this stronger
gate.

## Final host and artifact gates

The following table is intentionally not a promise from an intermediate build.
Each row receives its final revision, command, and result only after the tree is
clean and the exact artifacts used by all three tablets have been frozen.

| Gate | Final result | Evidence |
| --- | --- | --- |
| profile/table regeneration | pending final revision | pending |
| setup verification | pending final revision | pending |
| shell contracts | pending final revision | pending |
| Dart format/analyze/tests/goldens | pending final revision | pending |
| native debug/release CTest | pending final revision | pending |
| ASan/UBSan and focused TSan | pending final revision | pending |
| ARMv7 ELF/ABI and product AOT | pending final revision | pending |
| AArch64 ELF/ABI and product AOT | pending final revision | pending |
| `linux-arm` payload assembly | pending final revision | pending |
| `linux-arm64` payload assembly | pending final revision | pending |
| source/build/payload residue denylist | pending final revision | pending |
| complete `./ci/check.sh` | pending final revision | pending |

## Same-revision physical-device acceptance

All cells must refer to the same clean Git revision and corresponding target
artifact hashes. “Visible” means a fresh camera frame or video of the physical
panel. A stock screen, host screenshot alone, service log alone, or a frozen
previous e-ink image does not pass.

| Gate | RM1 | RM2 | Move |
| --- | --- | --- | --- |
| exact profile/kernel/panel/waveform accepted | pending | pending | pending |
| final release payload hash verified | pending | pending | pending |
| common supervisor healthy | pending | pending | pending |
| release/AOT process identity | pending | pending | pending |
| Pluto Home visible | pending | pending | pending |
| all target-supported apps launch and present | pending | pending | pending |
| switcher visible | pending | pending | pending |
| another app selected and visible | pending | pending | pending |
| Ink visible with deterministic pointer stroke | pending | pending | pending |
| Home return visible | pending | pending | pending |
| native Paper Codex capability | not applicable | not applicable | pending |
| screenshot, logs, and health agree with glass | pending | pending | pending |
| CPU, RSS, latency, thermal, and fault counters | pending | pending | pending |
| final residue audit | pending | pending | pending |

The final evidence bundle will live under
`analysis/native-cutover/final-acceptance/` and include command transcripts,
hash manifests, process and service records, health receipts, raw timing data,
camera stills/video/contact sheets, and a per-device audit.

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

Pending the same-revision all-device release and camera gate. This section will
state acceptance only after every required cell above is backed by preserved
evidence.
