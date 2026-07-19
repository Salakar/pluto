# Native runtime benchmark and optical performance report

Date: 2026-07-19

Runtime revision:
`6aadd9886c0f5409eb575940f35e1349d88bbcb9`

Status: exact-device optimization decisions are final. RM1 video and optical
acceptance are complete; the matching RM2 final video is pending its serialized
lifecycle soak.

## Method and acceptance rule

Optimization was performed on the exact tablet that consumes each path.
Measurements record target ABI, executable hash, sample count, warm-up,
frequency/governor, temperature, checksum or byte equality, allocations,
resident memory, page faults, file descriptors, and service state where
applicable.

Correctness, panel safety, and physical image quality are hard gates. A faster
path was rejected if it lost rollback authority, changed an oracle result,
missed an RM2 phase, weakened exact waveform binding, tore a stroke, or left
visible retained content. Host numbers detect regressions; ARMv7 production
selection is based on the physical Cortex-A9/A7 devices.

## RM1: Cortex-A9, one core, 512 MiB

### Round 1 — generated RGB565 optical table: retained

Forty alternating full-plane passes followed four warm-ups. Both definitions
processed 2,628,288 pixels and produced checksum `1577115660`.

| Path | p50 | p95 | p99 | Decision |
| --- | ---: | ---: | ---: | --- |
| component arithmetic | 203.140 ms | 207.927 ms | 209.734 ms | reference |
| generated 64 KiB table | 80.756 ms | 82.548 ms | 82.998 ms | retain, 2.52–2.53x faster |

Temperature moved only 26.2 to 26.3 °C. Evidence:
`analysis/native-cutover/performance/rm1-lut/`.

### Round 2 — preserve regional Full damage: retained

The old policy converted every quality-`Full` request into a full-panel
rectangle. Keeping the requested damage does not change the waveform class,
ioctl count, marker, or rollback transaction.

| Case | Previous amplification | Retained policy |
| --- | ---: | ---: |
| 702×936 Full | 4.000x | 1.000x |
| 96×96 Full | 285.187x | 1.000x |
| complete fixed corpus | 4,590,288 extra driven pixels | avoided |

Widely separated multi-rect requests still use one bounding rectangle because
splitting one logical transaction across several kernel submissions would
weaken fail-closed rollback. Evidence:
`analysis/native-cutover/performance/rm1-damage-amplification/`.

### Round 3 — remove the settled mirror: rejected

| Path | Full p50 | Medium p50 | Sparse p50 | Steady RSS change | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| exact mirror | 14.717 ms | 4.926 ms | 0.393 ms | baseline | retain |
| safe rollback journal | 22.517 ms | 6.198 ms | 0.338 ms | about -5.1 MiB | reject |
| one copy, no rollback authority | 7.568 ms | 2.478 ms | 0.172 ms | about -5.1 MiB | unsafe |

The safe journal regressed full work 53.0% and medium work 25.8%, while its
full-update peak memory was effectively unchanged. The fast one-copy ceiling
cannot restore bytes written before a rejected kernel submission. Evidence:
`analysis/native-cutover/performance/rm1-framebuffer-mirror/`.

### Round 4 — physical cross-app cleanup: two-pair sequence retained

Camera trials rejected:

1. ordinary partial replay, which retained the previous app strongly;
2. one full GC16 replay, which left vertical bands;
3. one black/white conditioning pair, which left a short high-contrast line.

Two bounded pairs plus the final GC16 restore removed the artifacts in the
formal application sequence. The sequence uses the existing target mirror,
allocates no second full target, and leaves ordinary regional and pen updates
unchanged.

### Final recorded Ink window

Rig 2 recorded 450 H.264 frames over 14.981 s at approximately 30 fps. The
action was the same PID-bound 24-event stylus sequence used by formal
acceptance. A 30 fps contact sheet shows first visible stroke material at
about 3.167 s and the continuous final S-curve by 3.240 s: a 73 ms observed
glass-build interval, not an input-latency claim. No split line, skipped
segment, or horizontal tear is visible.

The synchronized 24 s resource window includes the stroke and a post-dither
screenshot:

| Process/system metric | Result |
| --- | ---: |
| Ink average CPU | 17.583% of one core |
| Ink peak sample CPU | 98.000% of one core |
| Ink RSS min / average / max | 115,024 / 123,991 / 157,104 KiB |
| Ink maximum HWM | 167,376 KiB |
| supervisor average / peak CPU | 3.417% / 5.000% of one core |
| supervisor RSS | 4,108 KiB |
| minimum system `MemAvailable` | 223,576 KiB |
| CPU0 range | 792–996 MHz |
| maximum temperature | 28.9 °C |
| central post-dither stroke delta | `YAVG=0.690128` |

Evidence:
`analysis/native-cutover/performance/final-video-6aadd9886c0f5409eb575940f35e1349d88bbcb9/rm1/`.
The bright horizontal band in the rig video is fixed room-light reflection; it
is stationary before, during, and after the panel update.

## RM2: Cortex-A7, two cores, 1 GiB

### Round 1 — generated tables: one retained, one rejected

| Candidate | p50 | p95 | p99 | Decision |
| --- | ---: | ---: | ---: | --- |
| RGB565 arithmetic | 45.142 ms | 46.142 ms | 47.664 ms | retain |
| generated RGB565 table | 51.798 ms | 52.924 ms | 54.890 ms | reject, 13% slower |
| direct WBF transition decode | 192.548 ms | 199.169 ms | 201.195 ms | reference |
| immutable expanded transition table | 20.928 ms | 21.222 ms | 21.279 ms | retain, 9.38x p95 |
| original complete phase encode | 32.696 ms | 33.032 ms | 33.139 ms | reject, misses cadence |

The retained WBF expansion costs about 1.06 MiB and is rebuilt from the exact
device-owned waveform at startup. A mutable disk cache was rejected because
one avoided startup operation did not justify staleness and corruption risk.

### Round 2 — split encoder and direct condition wake: retained

The original helper slept 2 ms and then busy-spun for up to 4 ms after every
encode. Returning directly to its existing condition-variable wait preserves
the phase deadline and removes unnecessary helper work.

| Path | Process CPU / phase | Helper CPU / phase | Encode p99 | CPU / wall |
| --- | ---: | ---: | ---: | ---: |
| sleep plus spin, 2,000 phases | 17.627 ms | 9.796 ms | 7.757 ms | 1.485 |
| direct condition wake, 10,000 phases | 15.381 ms | 7.613 ms | 7.682 ms | 1.288 |

Process CPU fell 12.74% and helper CPU fell 22.28%.

### Round 3 — independent 10,000-phase correctness and production soaks

The correctness run compared every complete 1,464,320-byte slot with an
independent oracle: 10,000/10,000 matched.

The separate production run completed 10,000/10,000 phases:

| Metric | Result |
| --- | ---: |
| encode p50 / p95 / p99 / max | 7.618 / 7.657 / 7.682 / 7.913 ms |
| accepted p99 budget | 8.234 ms |
| cadence p50 / p95 / p99 / max | 11.935 / 11.962 / 11.984 / 12.103 ms |
| process CPU per phase | 15.381 ms |
| allocations before / after | 89 / 89 |
| RSS before / after | 45,584,384 / 45,584,384 bytes |
| PSS delta | 0 bytes |
| minor / major faults | 0 / 0 |
| file descriptors before / after | 5 / 5 |
| deadline/cadence misses | 0 / 0 |
| underflows/latched-slot mutations | 0 / 0 |
| pan/reference/thermal failures | 0 / 0 / 0 |
| maximum CPU temperature | 38 °C |

Evidence:
`analysis/native-cutover/rm2/perf/current-20260716T131039Z/`.

### Round 4 — physical rail, handoff, and ghosting work

Physical app switching rejected several logically plausible shortcuts:

- framebuffer blank completion was not treated as proof that the PMIC was
  already `OFF`;
- diagnostic state text was not treated as a stable ownership latch;
- one white rail and one black/white cycle both left visible stress content;
- the warm-handoff chain cap was not removed merely to avoid a cold boundary.

The retained path uses bracketed live-power reads, two black/white conditioning
cycles for a substantive cross-app reconciliation, safe-hold validation, and
the supervisor's two-sample cold power boundary. Every failed candidate
recovered to Home rather than retrying uncertain panel work.

### Final recorded Ink window

Pending the serialized RM2 lifecycle run. The final entry will include the
same 15 s camera video, 30 fps transition contact sheet, CPU ticks, RSS/HWM,
available memory, frequency, temperature, post-dither delta, and optical
tear/ghost review used for RM1.

## Move regression and shared pen path

Move's full-panel phase builder now uses a persistent two-core worker rather
than rebuilding worker state for each phase, and removes one per-lane phase
cursor of about 1.62 million bytes. The exact final full-panel sample measured
steady-build p50/p95/p99 of 11.552/18.254/19.096 ms. Sparse/full first builds
remain around 1.5–1.8 ms for the representative 16–96 pixel fixtures. Formal
camera acceptance passed all ten stages on the same universal release.

The shared pen-truth batching path reduced eight same-tile truth updates to one
masked operation:

| Strategy | submit-to-idle p50 | p95 | Operations |
| --- | ---: | ---: | ---: |
| eight separate truths | 1,553.609 ms | 1,567.501 ms | 8 |
| one masked batch | 196.083 ms | 198.545 ms | 1 |

That is 7.92x p50, 7.89x p95, and exactly 8x fewer waveform operations. The
preview remains only a hint; exact app-owned truth follows.

## Memory and CPU conclusions

- RM1 keeps the 5.0 MiB mirror because it is safety authority, not accidental
  duplication. Its generated LUT and regional damage policy produce the large
  safe wins.
- RM2's production phase loop is allocation-free and flat in RSS/PSS, while
  direct condition wake materially reduces CPU.
- The common supervisor is about 4–5 MiB RSS on the monochrome devices.
  Moving health checks to the one-second safety cadence removes repeated child
  process work, but measured supervisor self-CPU was not materially lower and
  is not claimed as a win.
- Camera video, not framebuffer screenshots alone, is the final arbiter for
  tearing, skipped stroke segments, retained app content, and settle quality.

## Final decision

The retained optimizations are checksum- or oracle-exact, bounded, and
profile-gated. Losing paths were removed or left only in benchmark evidence;
there is no production benchmark selector. Final acceptance remains open only
for the serialized RM2 video/optical pass and the final all-device lifecycle
and host gates.

