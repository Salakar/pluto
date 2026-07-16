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
- target-native ARMv7 engine, embedder, control client, and real Codex CLI kept
  as first-class build inputs;
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
The first RM2 panel write remains reserved for the frozen same-revision release
acceptance below.

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
| all standard apps launch and present | pending | pending | pending |
| switcher visible | pending | pending | pending |
| another app selected and visible | pending | pending | pending |
| Ink visible with deterministic pointer stroke | pending | pending | pending |
| Home return visible | pending | pending | pending |
| Codex binary/auth/real request | pending | pending | pending |
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
