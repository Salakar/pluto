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

### RM2 round 5: live power versus retained fault state

A physical multi-app run rendered Pluto Home and Ink, then failed closed during
a later switch. After stock recovery the SY7636A reported live
`power_good=OFF` with retained state `UVP at VN rail`; during the failed Pluto
start, the live rails had reached power-good while the same state remained
latched. Treating that historical event as a current rail failure made every
subsequent healthy power-up inadmissible.

The vendor MFD and regulator contracts expose two different facts: power-good
is live, while the fault-event code persists until a physical PMIC-enable
reset. Pluto captures the exact event code after LCDIF powerdown, requires
power-good on every powered check, and permits only that unchanged baseline as
diagnostic telemetry. An unreadable value, unknown vendor string, power-good
loss, latch creation, latch clearing, or code-to-code change fails closed.

The checks enclose the actual drive, not only admission. They run around the
powered temperature read, on the worker immediately before phase zero, and
after the final safe-idle pan before phase cells are cleared, logical state is
committed, or a completion callback is issued. Cold INIT has both an immediate
pre-drive gate after its three safe fills and a post-drive gate before blank or
logical state is committed. Focused host coverage now exercises all 16 vendor
state strings, unreadable attributes, stable historical state, pre-drive loss,
faults injected only after real phase activity, post-blank decay, and retained
powered safe-HOLD handoff; 79/79 RM2 native tests pass. This is development
evidence until the corrected frozen
release repeats the physical switch and soak.

### RM2 round 6: post-blank rail decay

The first universal-release candidate
`22e26a0673b1a623225d93715cae7e84fd82f7e7` presented Home, Counter, and
Motion Lab on the physical RM2, then rejected Ink Lab startup at
`start.panel-fault-baseline`: the framebuffer was logically blanked while the
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
powered-safe-HOLD fault baseline, fills only inactive slots, and never rewrites
the scanned HOLD slot. A cold start, invalid or missing handoff, noncanonical
live slot, unreadable attribute, unknown state, later power loss, or latch
transition still fails closed. Host coverage includes transient `ON, ON, OFF`,
persistent `ON` without a handoff, retained-powered valid HOLD, tampered HOLD,
and unreadable sequences; all 79 RM2 native tests pass. Physical acceptance
must repeat on the next frozen release.

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
