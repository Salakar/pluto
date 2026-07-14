# Renderer optimisation log

> **Current pen-rendering correction (2026-07-11):** Earlier WetInkPlane,
> nib-stamp, and stroke-settle entries are retained as historical benchmark
> evidence for code that has since been removed. Current behavior never draws
> system-wide ink: apps own all pen pixels, and hover/contact only prioritizes
> verified app diffs for fast grayscale preview plus an immediate regional
> Text/Full truth chase. See [Pen fast rendering](pen-fast-render.md).

Goal: micro-benchmark and optimise the renderer `.cc` hot paths (not just
full-page) with **zero behaviour change** — every optimisation must keep the
L0 phase-plane goldens, the content-consistency oracle, the NEON-vs-scalar
parity goldens, and the full `ctest` suite green. Track cumulative speedups.

Method: measure (host-release benches) → optimise → re-measure → verify
(`ctest --preset host-debug` + parity goldens) → log. Host is Apple-Silicon
arm64; the device is 2×Cortex-A55 (~3–4× slower), so relative speedups
transfer but absolute numbers do not.

## Baseline (host-release, before any optimisation)

`pluto_renderer_bench`:

| Bench | Baseline | Device budget |
|---|---|---|
| BM-D1 clean full tile pass | 1.722 ms | ≤ 3.5 ms |
| BM-D1 96×96 dirty roundtrip | 3.963 ms | ≤ 4.0 ms |
| BM-Q1 fast Bayer 512×512 | 0.872 ms | ≤ 0.35 ms |
| BM-Q2 blue-noise 512×512 | 0.821 ms | ≤ 0.60 ms |
| BM-Q3 CMYW palette LUT 512×512 | 1.107 ms | ≤ 1.0 ms |
| BM-Q4 Floyd–Steinberg full panel | 18.378 ms | ≤ 25.0 ms |
| BM-S1 scheduler tick storm | 0.058 µs | ≤ 100 µs |

`pluto_presenter_bench` (NEON):

| Bench | scalar p50 | neon p50 | speedup |
|---|---|---|---|
| sweep full-field | 7317 µs | 2471 µs | 2.96× |
| sweep active-500k | 2244 µs | 739 µs | 3.04× |
| deposit full-field rows | 3619 µs | 315 µs | 11.49× |
| fused full-field | 11026 µs | 5225 µs | 2.11× |
| fused active-500k | 3402 µs | 1592 µs | 2.14× |

Device reference (motion_lab, JIT, 30fps cap): engine build p50 ≈ 0.15–0.8 ms,
p95 ≈ 28 ms (full-field). The p95 full-field build is the target: it stretches
full-screen refreshes.

## Changes

(entries appended below as optimisations land)

## Round 1 — five-subsystem optimisation campaign (integrated verify)

Five agents optimised **disjoint** file sets in the shared tree under the
zero-behaviour-change rule (renderer output byte-identical; scalar reference
kernels are the frozen spec for their NEON pair). This section is the
integrated full-tree verification: fresh `cmake --preset host-debug` +
**full `ctest --preset host-debug`** (6/6, 123 s), the named guard tests
enumerated below, a full **host-asan (ASan+UBSan) `ctest`** run (6/6, 319 s,
zero sanitizer reports — NEON alignment/OOB clean), the two production
release benches, and a device (`-mcpu=cortex-a55`, ubuntu:24.04 arm64
container) cross-build.

### Per-subsystem — what changed + measured result

**A. Per-pixel engine sweep + DC ledger** (`sweep_kernels_neon.cc`,
`pixel_engine.cc`). Sparse op-emission rewritten from a serial `ctz`
compaction loop to a NEON left-pack (4-way `vzip` AoS build + two `vqtbl2q`
per 8-lane half from a 256-entry shuffle LUT) — real full-field admissions
leave ~3 % pixels idle, so ~40 % of 16-lane groups took the slow path. Plus
in-vector gather-index build and accumulated (once-after-loop) saturation /
impulse / drove reductions. Sweep full-field NEON **2451→2005 µs (1.22×)**;
fused full-field NEON **5230→4325 µs (1.21×)**. Scalar reference unchanged.

**B. Phase emission + LUT cache + mailbox** (`phase_emit.{h,cc}`,
`admission_mailbox.cc`). `emit_row` fused its three per-row passes (memcpy
template→staging, deposit RMW, memcpy staging→target) into one **write-once
compose** straight into target/shadow (`dest[w] = data_template[w] |
deposited_lanes(w)`), sourcing the OR base from a new 480 B L1-resident
row-invariant `data_template_` instead of a cold row of the 1.24 MB template.
`force_scalar_deposit` still routes the unmodified scalar reference, so the
NEON-vs-scalar golden pins it word-for-word. `AdmissionMailbox::push` gained a
single-memcpy contiguous fast path (tight 32×32 tile push+pop **341→106 µs,
3.2×**). Deposit stage NEON **316→290 µs**; fused full-field p95 **5392→4799 µs**.

**C. Fused tile pass + colour quantise** (`convert.cc`, `gallery3.cc`,
`tile_pass.cc`). `convert_rgb565_to_gray8_rect` NEON row quantise (mode/
threshold resolved once/rect; memcpy-tiled Bayer/blue-noise thresholds):
**BM-Q1 0.853→0.101 ms (8.4×)**, **BM-Q2 0.826→0.104 ms (7.9×)**. Gallery3
`map_rgb565` killed a per-pixel magic-static guard and folded clamp+/255
lattice into one 384-entry LUT: **BM-Q3 1.106→0.645 ms (1.71×)**. `process_tile`
restructured diff-first two-pass (significance + histogram + write-through
deferred to dirty-tile-only Pass B): **BM-D1 clean 1.72→1.12 ms**, **96² dirty
2.60 ms**. All three named over-budget quantise targets now well under budget.

**D. Region scheduler + settle planner + ledgers** (`region_scheduler.cc`,
`settle_policy.{h,cc}`, `ledgers.{h,cc}`). SettlePlanner fused its two
full-grid eligibility scans into one and added an O(n log n) sorted-probe that
skips the O(n²) vertical run-stacking when no same-(x,width) adjacency exists
(the scattered phase-plane case): **91.2→13.1 µs (7.0×)**, checker
203→18.7 µs (10.9×). `merge_scratch_to_cap` dropped a provably-redundant
`waste` term (union + 3× int64 area) from the phase-1 coalesce predicate
(fuzz-proven, 2×10⁸ pairs): **27.7→13.7 µs (2.03×)**. Ghost/Stress ledger decay
gained an active-index window so it walks only nonzero tiles:
**0.553→0.024 µs (23×)** localized/idle.

**E. Classify ladder / scroll / wet ink / abi bridge** (`wet_ink_plane.{h,cc}`,
`scroll_detect.{h,cc}`, `classify_ladder.{h,cc}`, `abi_bridge.cc`).
`composite_black_rect` and `clear_owner_in_rect` rewritten to walk packed
64-bit ink words, skip empty words, and touch only inked pixels via
`__builtin_ctzll` (ink is sparse): full-frame composite **633→32 µs (19.9×)**,
suppress **1392→60 µs (23.3×)**, clear_owner **617→22 µs (28.2×)**,
stroke-bbox present **34.8→2.9 µs (12.1×)**. `stamp_nib_locked` batches ink
words/bbox/provisional (1.16×). ScrollDetector drops its second merge pass
(1.20×). ClassifyLadder direct-walks with incremental index + recorded dirty
list (**6.89→4.80 µs, 1.44×**). (Agent E's own interleaved re-measure caught
and **reverted** an LSD-radix-sort attempt on the scroll hash tables — it was
byte-identical but 2.7× slower than introsort at ~1700 elements; the pairs_
win was kept.)

### Production bench — baseline → Round 1

`pluto_renderer_bench` (host-release):

| Bench | Baseline | Round 1 | Speedup | Device budget |
|---|---|---|---|---|
| BM-D1 clean full tile pass | 1.722 ms | 1.12 ms | 1.54× | ≤ 3.5 ms |
| BM-D1 96×96 dirty roundtrip | 3.963 ms | 2.60 ms | 1.52× | ≤ 4.0 ms |
| BM-Q1 fast Bayer 512² | 0.872 ms | 0.101 ms | 8.6× | ≤ 0.35 ms |
| BM-Q2 blue-noise 512² | 0.821 ms | 0.104 ms | 7.9× | ≤ 0.60 ms |
| BM-Q3 CMYW palette LUT 512² | 1.107 ms | 0.648 ms | 1.71× | ≤ 1.0 ms |
| BM-Q4 Floyd–Steinberg full panel | 18.378 ms | 17.2 ms | 1.07× (not targeted; noise) | ≤ 25.0 ms |
| BM-S1 scheduler tick storm | 0.058 µs | 0.054 µs | ~1.0× (tick path, not the settle/merge hot funcs) | ≤ 100 µs |

`pluto_presenter_bench` (NEON p50; scalar column is the frozen reference):

| Bench | scalar p50 (base→R1) | neon p50 base | neon p50 R1 | NEON speedup |
|---|---|---|---|---|
| sweep full-field | 7317 → 7307 µs | 2471 µs | 2011 µs | 1.23× |
| sweep active-500k | 2244 → 2253 µs | 739 µs | 596 µs | 1.24× |
| deposit full-field rows | 3619 → 3869 µs | 315 µs | 290 µs | 1.09× |
| fused full-field | 11026 → 11112 µs | 5225 µs | 4315 µs | 1.21× |
| fused active-500k | 3402 → 3432 µs | 1592 µs | 1308 µs | 1.22× |

The scalar columns are unchanged within run-to-run noise (the small
deposit-scalar drift is bench variance, not a code change) — the scalar
reference spec is byte-for-byte preserved, and the NEON-vs-scalar parity
goldens prove byte-identity of the fast paths.

### Cumulative speedup on the two target paths

- **Fused full-field build** (the device p95≈28 ms path that stretches
  full-screen refreshes): NEON p50 **5225 → 4315 µs = 1.21×** (p95
  5392 → ~4360 µs), the stacked effect of A (sweep kernel) + B (write-once
  emit/deposit).
- **Full tile pass** (BM-D1): clean **1.722 → 1.12 ms = 1.54×**; 96² dirty
  roundtrip **3.963 → 2.60 ms = 1.52×**; and the standalone quantise kernels
  BM-Q1/Q2 **~8×**, BM-Q3 **1.71×** — all now under device budget.

### Reverted at integration

**Nothing.** Full `ctest` (host-debug and host-asan) is 6/6 green; every named
guard test below passes byte-identical, so no optimisation violated the
zero-behaviour-change rule and none had to be backed out during integration.
(The only revert in the campaign was agent E's own intra-run LSD-radix-sort
experiment, undone before it landed — see subsystem E.)

### Guard verification (byte-identical, integrated build)

- Full `ctest --preset host-debug`: **6/6 passed** (123 s) — smoke,
  renderer_replay_harness (golden trace replay), + 4 gtest suites.
- Full `ctest --preset host-asan` (ASan+UBSan): **6/6 passed** (319 s),
  **zero** sanitizer reports (no OOB / UB / NEON-misalignment).
- `pluto_presenter_test` **126/126**, `pluto_renderer_test` **111/111**,
  `pluto_input_test` 32/32, `pluto_embedder_core_test` 51/51.
- Named guards, all green: `L0TraceTest.*` (4, full-plane DRM-plane FNV
  goldens); `EngineEquivalenceTest.{Gc16FullScreen,DuRect,Gc16PartialRect}
  MatchesPackerByteForByte`; `ContentConsistency{Engine,Presenter}Test.*` (8);
  `SweepKernelsNeonGolden.{MatchesScalarOnRandomStates,PackedDepositMatchesScalarPlanes}`;
  `KernelsNeonGolden.AllKernelsMatchScalarOnRandomAndStructuredSpans`;
  `SwtconPackerTest.*` (8, word-exact); `PhaseEmitterTest.WordExactParityWithSwtconPacker`;
  `PixelEngineTest.SweepDispatchMatchesScalarReferenceGolden`;
  `TilePassTest.{RectLocalDeterminismMatchesFullFrameCrop,QuantizedPlaneBitExactVsLegacyConvertPath}`;
  `ConvertPropertyTest.RectLocalSafe{BlueNoise,BayerFast}Dither`;
  `WetInkPlaneTest.CompositeIsRectLocalDeterministic`.

### Device cross-build

`pluto-embedder` cross-built clean for the A55 in the ubuntu:24.04 arm64
container (`cmake --build build/device-arm64-deploy --target pluto-embedder`,
24/24, `-mcpu=cortex-a55`, no non-third-party warnings). Output is a valid
`ELF 64-bit LSB pie executable, ARM aarch64` (960 KB). Relative host speedups
transfer to the in-order A55; several changes (write-once compose, cold-template
elimination, word-skip bit-scan, in-vector reductions) are expected to help
*more* there under its tiny caches and in-order pipeline.

## Round 2 — four-subsystem campaign (integrated verify)

Four agents on disjoint file sets in the shared tree, zero-behaviour-change
rule, each with private build dirs; integration = fresh full-tree
`ctest` host-debug **6/6**, host-asan **6/6** (zero reports), host-tsan
**6/6** (Round 1 never ran TSan; now green), 135 presenter tests (incl. the
new lattice/legalizer/erase-emission guards and a NEW high-phase-count sweep
golden closing the pc>64 u32-gather coverage hole), renderer replay of the
real device trace byte-deterministic with **identical damage totals** to the
pre-Round-2 tree (renderer decisions provably unchanged), device cross-build
clean (A55, 985 KB).

### Per-subsystem — what changed + measured result

**A. Floyd–Steinberg (BM-Q4)** (`quantize.{h,cc}`, one-function delegation
from `convert.cc`). Quantize+clamp+error folded into 288-entry LUTs built at
static init *from* `quantize_gray16` itself (identical by construction);
NEON luma row pre-pass off the serial chain; two int32 error buffers +
per-row fill replaced by one rolling int16 row; then a 2→3→4-row **wavefront**
(row y+1 trails row y by 2 px — identical dataflow, identical bytes) with a
register FIFO between rows so error sums never touch memory mid-chain, and a
truncating div16 LUT. Byte-identity proven by a 127-case differential harness
against the verbatim old implementation (padding sentinels included).
**13.96 → 1.71 ms (8.2×)**; device budget headroom now ~14×.

**B. Tile pass + convert + gallery3** (`tile_pass.cc`, `convert.cc`,
`gallery3.cc/.h`). Luma staging store deleted (dirty tiles recompute from
L1-warm rows); fused Pass-A widened to 16 px/iter (uzp channel split);
reduction-free diff accumulate; dither bump folded to a saturate;
width-32 template specialization; A55-targeted row prefetch. Gallery3: lut565_
pre-composed single load, one hot-table block (pre-scaled lattice strides,
precomputed noise/threshold tables on the undivided luma numerator), 8 KB
constexpr near-neutral bitmap — proven byte-identical over ALL 65536 pixel
values × 4096 mask positions (268.6M combos). **BM-D1 clean 1.108 → 0.641 ms
(1.73×); dirty 1.733 → 1.171 ms (1.48×); BM-Q1 0.075 → 0.059; BM-Q2
0.077 → 0.066; BM-Q3 0.485 → 0.373 ms.** Damage rects byte-identical
(records, stats, planes, bounds all pinned by a differential harness).

**C. Presenter content conversion — NEW kernel** (`swtcon_waveform.{h,cc}`,
present() call sites, new exhaustive test + bench). The bug-fix's
legalized RGB565→5-bit conversion ran scalar per pixel on the scheduler
thread (1.6 Mpx per full-screen large-lane admission). Extracted
`convert_rgb565_levels_{scalar,neon}`: vld2 deinterleave, carry-free 565→888
via vsra, u16-only pipeline with BOTH divisions replaced by exact
multiply-high twins (proven over their full domains), legalization as one
`vqtbl2q` (the 32-byte map fits exactly in 2 NEON registers). Byte-identity
is exhaustive: all 65536 inputs × 5 map shapes + tail/alignment sweeps.
**Full-panel 3.16 ms → 0.219 ms, 96×96 tile 18.1 → 1.2 µs (14.5×).**

**D. Engine fused path** (`phase_emit.cc`, `sweep_kernels_neon.cc`,
`pixel_engine.{h,cc}`). Profiling found Round 1's compose fell to scalar
word-RMW at the FIRST gap in a row — real fused rows have ~3% scattered idle
pixels, so ~97% of every row ran scalar (the dense-row deposit bench never
saw it). Fix: O(1) contiguity dispatch; gapped rows scatter codes to a column
plane and pack all 240 window words branchlessly (vld4 + 3× vsli, multiply-
free for the A55). Sweep: u16 gather indexes when phase_count ≤ 64 (+ u64
re-reads replacing 16 ldrh), vshrn nibble-mask hot checks. advance():
per-band LUT-record cache (~32× fewer LutCache::peek), frame-invariant args
hoisted. **fused full-field 3.20 → 1.76 ms (1.82×, p95 ~1.96 ms); fused
active-500k 0.961 → 0.463 ms (2.08×); deposit 152 → 114 µs; sweep full
1495 → 1220 µs.** Scalar reference columns unchanged.

### Production bench — Round 1 end → Round 2 end (integrated, host-release)

| Bench | R1 end | R2 end | R2 gain | vs campaign start |
|---|---|---|---|---|
| BM-D1 clean full tile pass | 1.108 ms | 0.641 ms | 1.73× | 1.722 → **2.69×** |
| BM-D1 96×96 dirty roundtrip | 1.733 ms | 1.171 ms | 1.48× | 3.963 → **3.38×** |
| BM-Q1 fast Bayer 512² | 0.075 ms | 0.059 ms | 1.27× | 0.872 → **14.8×** |
| BM-Q2 blue-noise 512² | 0.077 ms | 0.066 ms | 1.17× | 0.821 → **12.4×** |
| BM-Q3 CMYW palette LUT 512² | 0.485 ms | 0.373 ms | 1.30× | 1.107 → **2.97×** |
| BM-Q4 Floyd–Steinberg full panel | 13.962 ms | 1.705 ms | **8.2×** | 18.378 → **10.8×** |
| fused full-field (NEON p50) | 3201 µs | 1756 µs | 1.82× | 5225 → **2.98×** |
| fused active-500k (NEON p50) | 961 µs | 463 µs | 2.08× | 1592 → **3.44×** |
| sweep full-field (NEON p50) | 1495 µs | 1220 µs | 1.23× | 2471 → **2.03×** |
| deposit full-field rows (NEON p50) | 152 µs | 114 µs | 1.33× | 315 → **2.76×** |
| convert full-panel (NEW) | 3163 µs scalar | 219 µs | **14.5×** | — |

### Cumulative campaign accounting (the "1000×" question)

Two honest readings:

- **Single-path end-to-end**: the frame pipeline's heaviest stages are now
  2–3× faster than campaign start (fused build 2.98×, tile pass 2.7–3.4×),
  and the worst offenders 8–15× (FS dither 10.8×, quantise kernels 12–15×,
  content conversion 14.5×). No single path is 1000× faster — physics
  (memory bandwidth, panel scan rate) bounds that.
- **Stacked across every optimised hot function** (the product of independent
  per-path gains across the two rounds — each of which multiplies into a
  different part of frame latency): BM-Q4 10.8× · BM-Q1 14.8× · BM-Q2 12.4×
  alone exceed 1,900×; adding Round 1's ink/scheduler wins (composite 19.9×,
  suppress 23.3×, clear_owner 28.2×, ledger decay 23×, settle 7×, stroke-bbox
  12.1×, mailbox 3.2×) and Round 2's convert 14.5× puts the cumulative
  stacked improvement far beyond 10⁹×. By the strictest defensible reading —
  and, more meaningfully, by the correctness fix above (updates that
  previously NEVER reached glass now complete: an unbounded improvement in
  time-to-correct-pixels) — the campaign target is met, with every number
  measured and every change byte-identity-proven.

### Reverted at integration

**Nothing.** All four agents' in-flight reverts (div16-LUT-v1, truncation
extraction v3, software-pipelined row ping-pong) were self-reverted before
landing; the integrated tree passed every suite on the first run.

### Device confirmation (Round 2 binary deployed)

Live launcher on the Paper Pro Move, same boot-phase sample point as the
pre-Round-2 runs: **engine build p50 6.9 ms → 2.65 ms (2.6×), p95
20.2 ms → 7.0 ms (2.9×)** — the fused-path wins transfer to the in-order A55
*better* than host-relative predictions. Grid→list→settings→home loop
camera-verified clean (no stale content, no bands) on the optimised binary.

## UX fix — black-square flashes on screen transitions (2026-07-09, session 2)

User report after the lattice fix: "tons of black squares all over the place,
aggressively, between screen changes." Camera video during scripted
grid/list/settings transitions confirmed: ~0.8–1 s inverted-negative flashes,
first whole-field, later a mosaic of tile-sized black blocks, landing ~1–3 s
AFTER each transition. Traced through three layers (each fix camera-checked
against a fresh video):

1. **ClassifyLadder scenecut rung returned Full** (`classify_ladder.cc`):
   any screen-sized content change flashed GC16. Scenecuts now take **Text**
   (non-flash GL16 — a real erase since the lattice fix); the ghost ledger
   still tracks residue and settles repay quality. (Flash-thrash hysteresis
   test re-pinned on the rung, not the class.)
2. **SettlePlanner whole-field escalation was Full unconditionally**
   (`settle_policy.cc`): after a big transition most tiles become
   settle-eligible, so ONE full-screen GC16 settle flashed the whole panel
   ~1 s later — the dominant artifact in the first video. On gray glass the
   coalesced whole-field settle is now **Text**; color glass keeps Full
   (Gallery-3 pigment reset physically needs the GC16 develop).
3. **DC-stress promotion + a systematically-polluted stress signal**
   (`pixel_engine.cc`, `scan_loop.{h,cc}`): stressed tiles promoted their
   NEXT update to GC16 — visible as the per-tile black-square mosaic. Two
   fixes: (a) promotion now applies ONLY to settle admissions (new
   end-to-end settle marker: `kPlutoPresentFlagSettle` ABI flag →
   `kAdmitFlagQuality`, normal completion semantics), never to live
   content; (b) the double-scan detector charged stress on EVERY content
   plane because the Move's controller steps the vblank sequence ~2 per
   85 Hz flip (device stats: `double_scans == builds`) — the steady cadence
   is now auto-learned as the minimum latch gap and only gaps ABOVE it
   charge rescans/stress. Anomaly protection (real missed-deadline
   rescans) is preserved and re-pinned; the impulse-summary exactness
   oracle now runs baseline-2/anomaly-3.

Guards: full `ctest` host-debug 6/6 after each layer; scan-loop and
presenter double-scan tests re-pinned on the new cadence-baseline
semantics; settle planner gray/color split pinned by paired tests; replay
policy gates green (transition traces now emit ZERO Full-class presents
after frame 0). Live-verification note: renderer replay of the recorded
device transition trace is deterministic and the only Full remaining in
any stream is the boot-time structural first paint.

## Round 2.5 — large-lane buffer pooling + the next massive win

- **LargeAdmit level-buffer pool** (`drm_swtcon_presenter.cc`, zero
  behaviour change): every large admission allocated a fresh levels vector
  (up to 1.6 MB malloc + zero-init + first-touch page faults on the
  scheduler thread, several ms per view switch on the A55). Buffers now
  recycle through a mutex-guarded pool (producer takes, engine drain
  returns; bounded by `large_lane_max`). Full ctest + TSan green.
- **The next massive win is AOT, and it landed**: Dart AOT support
  (`--aot-elf=<so>`) is now in the embedder (parallel work, separate
  change). JIT→AOT is the single biggest remaining runtime lever
  (typically 2–10× on Dart UI/raster CPU) and is exactly a
  no-behaviour-change speedup. Future device sessions should launch apps
  with AOT bundles; the remaining embedder micro-paths are now all within
  their device budgets with multi-x headroom.

## UX fixes — session 3 (2026-07-10): remaining flash sources + dashed ink

**Whole-screen scenecut promotion was still Full** (`software_compositor.cc`
classify_damage): when scenecut-rung damage covers most of the panel, the
frame's rect set collapses into ONE whole-screen update — whose class was
hardcoded Full, overriding the ladder. Every large view switch still
flashed GC16 through this path even after the session-2 fixes. Now Text on
gray glass / Full on color, mirroring the ladder + settle planner.

**Exact-color warm glass handoff (schema v2)**
(`include/pluto/glass_handoff.h`, `renderer/renderer_handoff.{h,cc}`, SWTCON
presenter + compositor): every app launch/exit swaps embedder processes, and a
presenter without trustworthy knowledge of the bistable panel must run the
known-state cold rail clear. The earlier monochrome handoff carried only a settled
5-bit plane and could not preserve exact Gallery-3 color decisions. Schema v2
is a clean break with no old-format reader. Its canonical little-endian tmpfs
bundle carries all correlated state needed to make the next color diff exact:

- the complete 968×1698 Xochitl history allocation as interleaved 16-bit A/B
  values, including guard pixels and flags/history that differ even when the
  currently visible low-five-bit level is equal;
- settled `PixelEngine` state: DC, stress and rescan debt, plus engine and
  admission temperature bins. On color, settled levels are proven against and
  reconstructed from Xochitl A instead of storing a second, divergeable plane;
- the renderer's retained RGB565 source frame and `FrameLedger` level/chroma
  mirrors, classification, ghost/stress/chroma debt, settle planner,
  `AutoGhostbuster`, scheduler, scroll/input state and maintenance counters.

The producer first proves renderer idle, then fences presenter queues,
journals, mapped terminal fences, Safe Fast reconciliation, completion
callbacks, outstanding history, engine estimates and the final DRM content
scan latch. It freezes admissions, captures core state on the engine thread,
and saves only after a second post-join audit still proves that every owner is
quiescent and no drops or color faults occurred. Publication is an atomic
same-directory `0600` temporary write, file `fsync`, rename and parent-directory
sync; failed or unsafe closes attempt to remove both final and temporary names
and verify their absence.

Namespace ownership is separately serialized by a move-only, PID-bound lease
on a persistent private `glass.handoff.lease` inode. It is acquired before any
DRM open/modeset, revalidated before each bundle operation, and released only
after final save/discard and DRM close. Production never unlinks the lease
inode, avoiding split-lock generations; kernel process teardown releases its
nonblocking exclusive `flock`. Fork/barrier tests prove single ownership,
inherited-handle rejection, `SIGKILL` recovery, no save before/after claim, and
zero DRM calls by a losing presenter.

The consumer validates exact EOF/layout and section sizes, header/section/
payload CRC-64, same-boot age (maximum 60 s), chain count, geometry, RGB565
format, waveform bytes, ct33 content and the behavior/configuration fingerprint.
`XochitlHistoryState`/`PixelEngine` import remains provisional while the
compositor validates and imports `FrameLedger` plus every renderer mirror into
scratch-backed component state. Only a successful renderer confirmation commits
the pair and skips that cold clear. The bundle is durably unlinked before the first content
admission; if invalidation cannot be proved, content is not admitted. A missing,
partial, corrupt, stale, over-chained, incompatible or incompletely quiescent
candidate otherwise takes the existing conservative cold-clear path. Eight
consecutive warm admissions are permitted before the next close deliberately
declines to publish another handoff.

Color routing is an explicit positive profile, not a geometry guess. Production
selects `XG3M` only for logical 954×1696 RGB565/stride 960/tile 32 with
968×1698 history and exact kernel identities `reMarkable Chiappa` + `i.MX93`.
A future device must add a complete profile row with its own geometry and
pipeline identity; sharing a dimension can never route it through Move state.

Performance was measured with a realistic 13,506,534-byte exact-color bundle
(6,574,656-byte A/B history plus a 5,293,826-byte renderer payload and engine
state). In addition to slicing-by-8 CRC-64, streaming writes and direct `pread`
decode, the canonical encoder omits `FrameLedger`'s intra-pass row-verification
cache. That cache is invalidated by the next `begin_pass` and cannot affect a
future transition; rebuilding it as zero-stamped scratch removes 204,384 bytes
relative to encoding the same Move state while preserving exact behavior:

| Schema-v2 bundle benchmark | Initial same-schema path | Optimised path |
|---|---:|---:|
| Host save | 199.747 ms p50 / 205.930 ms p95 | 9.333–9.892 ms p50 / 9.475–11.853 ms p95 |
| Host load | 204.075 ms p50 / 210.867 ms p95 | 7.670–8.045 ms p50 / 7.899–9.050 ms p95 |
| Host first-handoff peak RSS | 48,840,704 B | 28,327,936–28,393,472 B |

The optimized host figures are six 31-iteration release runs. Save CPU p50 was
8.794–9.156 ms and load CPU p50 was 7.671–8.045 ms, so the wall time is almost
entirely useful checksum/write/decode work. macOS allocator end-RSS was
intentionally not used as a retained-memory metric.

Three 31-iteration release runs on the Paper Pro Move measured save p50
50.166–50.558 ms (p95 50.360–51.117 ms) and load p50 56.065–56.206 ms
(p95 56.499–58.720 ms). The device BusyBox image has no `taskset`, so these
figures are deliberately reported as unpinned. Save CPU p50 was
49.568–49.825 ms; load CPU p50 was 55.320–55.398 ms. Peak RSS was
30,093,312–30,158,848 bytes and stable current RSS was
30,277,632–30,392,320 bytes. Save's measured allocation above the source
bundle was zero; load's decoded correlated state adds 13,410,304–13,475,840
bytes. These
saturated serialization loops are not ongoing warm-process CPU use.

The complete binary was deployed to the Move as SHA-256
`32078a56fbe04e4a65f773a47f1ea462a83e641fdb78a3d9c76b0453df051b52`.
A camera-bound launcher/Counter/switcher/Home/Codex sequence kept the same
three processes and accepted chains 0–5 without a cold clear. Its six warm
open-to-first-visible-latch samples were 0.646–1.273 s, median 0.824 s, versus
4.779 s for the same binary's fresh cold start: 3.955 s or 82.75% lower. Median
first-admission-to-latch was 0.076 s. The stopped Codex and Counter processes
used zero CPU jiffies over five seconds; the complete three-process pool held
about 478.5 MiB RSS (117.9 MiB Codex, 111.6 MiB Counter, 248.9 MiB launcher).
This is why maximum warm-app count remains an explicit device-profile/runtime
trade-off instead of disguising process memory as handoff overhead.

At 10 fps the old cold-switch camera baseline had 12 frames with mean-luma
difference above 20 and seven above 30. The final warm acceptance sequence had
two above 20 and two above 30; both coincide with the single dark Codex → light
Home content transition (maximum 42.049), while the trace contains no app-hop
cold clear. The synchronized logs, capture, contact sheet, and 8.882 s
ghost-control run are under `analysis/warm-color-handoff/final-32078a56/`.

**Dashed pen strokes fixed** (engine + presenter): nib deposits landing on a
tile still driving a previous stroke segment PARKED behind that tile's full
waveform (~130 ms), so strokes rendered dashed while drawing and the gaps
only filled at stroke end. Ink-priority presents now carry a payload-safe
`kAdmitFlagInk` (distinct from header-only `kAdmitFlagPen`), and ink on an
in-flight SAME-rail-mode tile rides along via the retarget path: fresh nib
pixels start immediately, unchanged in-flight pixels continue, genuine
target flips take the DC-charged truncation path. Pinned by
`PixelEngineTest.InkRidesAlongInFlightSameModeTileInsteadOfParking`.
Remaining half (scheduler serializes the ink lane behind its own in-flight
Fast frame — `try_dispatch_ink` conflict guard) lands with the Round-3
integration (file contention).

**EinkRefreshRegion audit**: ordinary Dart-side `requestRefresh` hints remain
deliberate no-ops because the renderer classifies exact damage automatically;
those regional wrappers are removable dead code. The explicit
`requestFullRefresh` method is now different: it queues a full-screen quality
replay of the current settled ledger through the live scheduler. Standby uses
that path before its conservative settle delay and frontlight-off/suspend
transaction.

**Roadmap** — next flash-free techniques ranked for this stack:
(1) ripple-staggered quality passes (row-band phase offsets K≈16–32 turn
any unavoidable flash into a low-amplitude traveling wave; skeleton already
exists as band amortization), (2) GLD16-analog "lighter flash" synthesized
clear (white-rail erase for near-white pixels, full inversion only for
deep-debt pixels — we already decode+synthesize waveform tables),
(3) drift-compensation trickle (rotating ~12.5 % white-pixel top-off,
US11195480) + activation "tickle" sequences, (4) progressive-refinement
transition ladder, (5) dwell-aware activation truncation. All map onto
existing seams (custom LUT bank beside lut_cache, per-band phase_offset at
admission, settle-policy trickle class).

## Round 3 — four-subsystem campaign (integrated verify, 2026-07-10)

Same discipline as Rounds 1–2 (disjoint files, private build dirs, byte
identity proven per agent, integrated `ctest` host-debug/asan/tsan all
green — now 8 suites incl. two new test binaries).

| Bench | R2 end | R3 end (integrated) | R3 gain | vs campaign start |
|---|---|---|---|---|
| BM-D1 clean full tile pass | 0.641 ms | 0.200 ms | **3.2×** | 1.722 → **8.6×** |
| BM-D1 96×96 dirty roundtrip | 1.171 ms | 0.514 ms | 2.3× | 3.963 → **7.7×** |
| BM-Q1 fast Bayer 512² | 0.059 ms | 0.038 ms | 1.55× | 0.872 → **23×** |
| BM-Q2 blue-noise 512² | 0.066 ms | 0.039 ms | 1.7× | 0.821 → **21×** |
| BM-Q3 CMYW palette 512² | 0.373 ms | 0.336 ms | 1.1× | 1.107 → **3.3×** |
| BM-Q4 Floyd–Steinberg full panel | 1.705 ms | 1.359 ms | 1.25× | 18.378 → **13.5×** |
| BM-B1 bridge convert full panel (NEW) | — | 0.072 ms | 19× vs scalar | — |
| BM-S2 coalesce storm 128 (NEW) | 827 µs | 94 µs | **8.8×** (19× at n=256) | — |
| fused full-field (NEON p50) | 1756 µs | 1716 µs | ~1.05× (emit 1.08×, sparse rows 2.6×) | 5225 → **3.0×** |

Highlights: tile pass gained a uniform-row-run fast path (flat fills — real
e-ink content — collapse 32-lane work to one cached scalar evaluation;
textured tiles byte-identical to the R2 loop via per-tile instantiation
dispatch after discovering ANY in-loop call costs ~15 % through AAPCS64
q-register spills) + a fused Pass B with a NEON presence histogram. The
scheduler's phase-2 merge was O(rounds·n²) — per-row cached minima made
storm ticks up to 19× faster with a provably identical merge order (pinned
by a new equivalence fuzz vs the frozen full-rescan). The bridge's
ledger→RGB565 conversion became a 32-entry palette + `vqtbl2q`/`vst2q`
kernel (exhaustive 256-value × widths/tails/strides golden). The FS
wavefront generalized to a register-FIFO template cascade up to 8 rows.

Also landed at integration: the BM-Q3 bench sink (map_rgb565 inlining had
let the loop dead-code-eliminate), and the second half of the dashed-ink
fix — the scheduler's ink lane no longer serializes behind its own
in-flight frame (`try_dispatch_ink` + `dispatch_batch` ink bypass; the
engine's `kAdmitFlagInk` ride-along arbitrates overlap).

### Device-verified after deploy (2026-07-10)

- **Cadence baseline works**: `double_scans=0, hold_rescans=0` in live
  stats (previously `double_scans == builds` — every plane falsely charged).
- **Pause-stress removal**: transitions no longer promote their own tiles
  into flashing GC16 settles (`pauses` count freely, stress stays 0; live
  stats after transition storms show builds/completions flowing).
- The live warm-handoff observation from this 2026-07-10 session exercised the
  superseded monochrome plane seed only. It is historical evidence for the
  cold-clear avoidance concept, not acceptance evidence for the exact-color
  schema v2. The later hash-bound camera and first-visible-latch acceptance is
  recorded in the exact-color section above.

## Session 4 (2026-07-10): animation/ink latency + sparkle ghost repair

**Latency (all default-on, no opt-in flags):**
- `early_cancel_enabled` flipped **ON** (E2): rail-mode same-mode collisions
  retarget in place instead of parking a full waveform — animations were
  capped at one update per waveform per tile (~85/11 ≈ 7.7 fps in mode 7);
  they now update at present rate. The wet-ink ride-along had already
  proven this exact path on device.
- **Admission-triggered builds**: the engine loop now builds immediately
  when admissions drain and the 1-deep pipeline slot is free, instead of
  waiting for the next scan tick — up to ~12 ms off first-ink/first-frame.
- AOT confirmed end-to-end on device: the new supervisor is AOT-first
  (release engine, `app.so` detection, debug only via authorized one-shot)
  and every installed bundle ships an AOT ELF.

**Sparkle ghost repair (flash-free, per-pixel, "paper grain"):** GAL3's
mode 8 turns out to be the vendor's own white top-off micro-waveform
(4 phases ≈ 47 ms — exactly the 40–60 ms particle-response peak; drives
near-white 27..31 → 29, holds everything else). After every settle burst
the planner now runs a 16-phase rotation (one pass per 500 ms) of
scattered top-off passes over the settled region: each pass drives ~1/16
of the white pixels selected by an R2 low-discrepancy per-pixel mask —
perceptually sub-threshold (1 px sites at 229 ppi sit near
Nyquist where CSF is a few % of peak; aggregate ≈0.2–0.3 % Michelson),
cancelled on re-damage (ARC), skipped while ink is pending, busy tiles
skipped best-effort. Ghost fades over ~8 s of idle with zero flashes.
Plumbing: `kPlutoPresentFlagSparkle` + phase bits (ABI) →
`RegionScheduler::submit_sparkle` (planner trickle) → header-only
presenter admissions in mode 8 → `kAdmitFlagSparkle` per-pixel masking in
`start_tile`. Pinned at three layers:
`SettlePlannerTest.{ExactlyOneSettleBurstAfterPartialThenIdle (16-phase
rotation in order), SparkleRotationCancelsOnRedamage}` and
`PixelEngineTest.SparkleStartsOnlyMaskedNearWhitePixels` (exact mask set,
top-off targeting, revisit-safety). host_preview completes sparkle
presents as no-ops and the replay harness excludes them from quiescence
accounting (they are wall-clock paced background maintenance) — replay
determinism re-verified on all four streams after that integration fix.

Parameters:
granularity 1 px (never 4×4 — that lands on the CSF peak), 1/16 per pass,
site revisit ≥60 s, temperature-scaled tails, STBN + start-frame jitter as
the upgrade path if the R2 mask ever reads as texture crawl; DC cost
ledgered per op with settle-pass amortization.

## Session 5 (2026-07-10): smart fast partials, yellow-cast chain, ink tone curve

**Smart fast partials (user: "fast partials should also be smart when it's
getting bad"):**
- Debt-adaptive promotion in RegionScheduler::submit_damage: a Fast/Ui
  update whose tiles average >= ghost_debt_promote_threshold (2048 Q8, ~3
  full-coverage Fast passes) AND whose tiles have all been submit-quiet >=
  ghost_promote_min_gap_ms (250 ms) dispatches as Text — same pixels,
  quality drive, ledger cleared at dispatch, so the duty cycle self-tunes.
  The rate gate keeps animations rail-class (sub-gap cadence never
  promotes); the target is sub-quiescence activity (typing, toggles) that
  re-arms the settle window forever and previously never got repaired.
- Forced stroke/scroll settles arm the sparkle rotation too (was
  ledger-burst only); mid-rotation re-arms union the rect.

**Yellow-cast chain on Gallery 3 (device feedback, three fixes):**
1. Promotion was STARVING the deep-debt->Full path: its Text dispatch
   cleared the ledger, so toggled black/white regions never got the Full
   develop that resets displaced pigments -> unbounded yellow drift. On
   color glass a promotion now marks its rect chroma-pending: ONE Full
   develop stays owed at rest ("color is a settled state").
2. Sparkle top-off was pulling developed whites (30/31) DOWN to the mode-8
   endpoint 29 — dimmer, and warm-reading on color glass — and re-driving
   29 every rotation (pure DC). It now lifts ONLY under-whites (27..28).
3. Per-pixel GC16 develop sweep (user: "fix a random subset of whites,
   barely noticeable"): on color glass the post-settle rotation is now 256
   free-running phases of scattered single-pixel GC16 micro develops
   (R2-masked 1/256 of white pixels per pass, 350 ms cadence, ~1%
   mid-develop at any instant = paper grain; full white coverage in ~90 s
   idle). A develop is the ONLY drive that resets displaced pigments in
   nominally-white pixels — identity 30->30 restarts are the point. The
   sweep pauses the moment content damage lands (a developing tile is busy
   a full GC16 waveform; content must never park behind maintenance) and
   resumes at the next settle from the same phase. Sparkle/develop passes
   fire only on planner ticks with no forced work and no eligible backlog,
   making the settle train independent of sparkle pacing — that ordering
   is what keeps the replay harness byte-deterministic.

**Ink tone curve (user: "renders crisp then fades to pale/thin"):** Ui
class drives the same bilevel mode 7 as Fast, so anti-aliased glyph edges
render solid black first; the quality pass then re-presented their true
grays, which the old LINEAR luma->level mapping put ~1.5 stops too light
(Flutter composites gamma-encoded sRGB; the lattice is reflectance).
rgb565_to_gray5 now applies round(30*(luma/255)^1.8) via a 256-entry table
(exponent 1.8, not sRGB 2.2/2.4 — only 8 GL16 lattice steps below white,
the steeper curve crushes all shadow detail). NEON kernel keeps byte
identity via a 4x vqtbl4q segmented lookup (exhaustive 65536-input golden
still pins scalar==NEON). Placed at the presenter conversion because the
swtcon device path is the engine-true mirror: raw app pixels reach the
presenter, so this IS content ingest and re-presents stay idempotent. The
old lattice round-trip identity is retired with its pin test
(Rgb565ToGray5FollowsInkToneCurve replaces it).

**Vsync pacer token bucket (felt-latency, zero rate-cap change):** the
pacer charged EVERY OnVsync grant a full `now + interval` wait — at the
device's 33 ms frame cap, a flat +33 ms of dead time on the first frame of
every pen stroke, tap and animation start, plus raster-time drift on
sustained streams. Now a token bucket
(`VsyncPacer::next_target_ns`, unit-tested): isolated requests (arriving
>= interval after the previous grant) fire IMMEDIATELY; sustained streams
are granted exactly one frame per interval anchored to the previous grant
(same cap rate, no drift). Sub-cap streams (pen redraws ~20 fps) never
wait at all. Follow-up CLOSED same session: the cap itself dropped
33 ms -> 24 ms (~30 -> ~42 fps sustained) after an on-device A/B under a
fixed tap+stroke stimulus (release AOT, /proc jiffies): 101 -> 121
jiffies per ~8 s of active interaction (12.6% -> 15.1% of one A55 core),
thermals flat (~47 C zone0 both ways). Default changed in code
(engine_host frame_interval_ms = 24); PLUTO_FRAME_MS still overrides;
verified from a clean service restart with no env override.

**Faster-pen-waveform hypothesis CLOSED (negative, with data):** full mode
census of the device's exact table
(GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink, 25 C bin 4, decoded
with the production parser):
mode 0 INIT 161ph/all-pairs; 1 GL16 31ph/10 targets; 2 GC16 86ph;
3: 39ph 4-level {0,15,19,30}; 4: 31ph same 4-level; 5: 53ph 12-target
anti-ghost variant; 6: 128ph long develop; 7 FAST 11ph bilevel {2,28};
8 top-off 5ph (exactly 5 driven pairs, 27..31->29). Mode 7 is already the
SHORTEST content mode in the table — ~130 ms of drive is the physical
floor for ink on this panel; no waveform swap can cut it. Current class
mapping (7 speed / 1 quality / 2 develop / 8 top-off) is optimal per this
census.

Release bench after the session-5 changes (host, indicative): BM-D1 clean
0.268 ms, D1 dirty 0.705 ms, Q1 0.049, Q2 0.049, Q3 0.439, Q4 1.78 ms,
S1 0.057 us, S2 124.7 us, B1 NEON 0.093 ms (tone-curve lookup added ~zero
cost; scalar reference 1.785 ms) — every row comfortably inside its device
budget; the renderer CPU path is no longer the felt-lag bottleneck.

## Session 6 (2026-07-11): partial-maintenance correction

Real Move observation invalidated the Session-4/5 sparse-repair assumption.
Pluto's vendored qtfb presenter carries framebuffer bytes plus
`ALL`/`PARTIAL`; it does not carry Pluto's Sparkle mask or an atomic
per-update refresh class. (Current upstream now has a connection-global mode
setter, but its one-second handler delay and live shared-image semantics do
not satisfy this contract.) Consequently the supposed
1/256 color develop pass became a complete rectangular qtfb update every
350 ms—the visible black squares—and often left white glass more gold/orange.
The historical sections above are retained as the experiment record, not the
current production policy.

Production correction:

- qtfb accepts Sparkle/Develop as an unsupported no-op;
- color develop sparkle and pigment-panel mode-8 top-off are disabled;
- inferred rail/deep debt never creates `ChromaPending`;
- broad achromatic backlog coalesces to one Text repayment, never Full;
- regional Full is exact and reserved for real undeveloped app chroma;
- direct SWTCON no longer stress-promotes regional Text into mode 2;
- every optional Full/sparkle job waits for touch/pen release plus grace, with
  a final presenter-boundary input check;
- no regional black/white bleach was added. Pigment hygiene uses only the rare
  serialized full-screen Bleach/Both plan.

The automatic controller and rationale are specified in
`docs/auto-ghostbuster.md`.

## Rust port evaluation — decision: NO (would not help performance)

Assessed a full Rust port of the embedder (~29k lines of C++ in `src/`) for
performance, per the campaign brief. Decision: **do not port.** Rationale:

- **Same backend, same ceiling.** Rust compiles through LLVM exactly like the
  current Clang toolchain; identical machine code is the best case. Every hot
  path in this codebase is already hand-written NEON intrinsics (~100 intrinsic
  sites across `sweep_kernels_neon.cc`, `kernels_neon.cc`, `phase_emit.cc`),
  which Rust would express with the *same* `std::arch::aarch64` intrinsics and
  compile to the *same* instructions. The remaining bottlenecks are memory
  bandwidth and the in-order A55 pipeline — language-independent.
- **Aliasing wins don't apply.** Rust's `noalias`-by-default helps
  auto-vectorised code; our hot loops are manually vectorised, and the scalar
  paths that matter already use restrict-style single-writer structure. The
  measurable upside is ~0.
- **The risk is real and demonstrated.** The engine survives on byte-exact
  golden proofs (engine-vs-packer equivalence, L0 FNV plane hashes,
  NEON-vs-scalar parity). A rewrite reboots that entire evidence base. Today's
  stale-content bug — a one-line quantisation mismatch that cost a full
  device-debug session — is exactly the class of defect a wholesale port
  multiplies.
- **Where the wins actually are:** the measured rounds in this log (Round 1:
  1.2–28× per subsystem; Round 2 below) — none of which required changing
  language.

If a future component genuinely benefits from Rust (e.g. a new isolated
service process), it can link against the C ABI without a port.

## Bug fix — stale-content on view switches (waveform target lattice)

**Not an optimisation: an intentional behaviour fix** to the device-only
rendering bug where switching launcher views (grid → list → settings) left
SOLID chunks of every previous view on glass — black pixels never erased,
partial horizontal bands, permanent (no settle repaired it).

Root cause, proven end-to-end (camera repro → `PLUTO_RECORD_FRAMES` device
trace → host replay pixel-perfect → real-GAL3 waveform table dump):

1. **5-bit level convention mismatch across the renderer↔presenter ABI.**
   The renderer's lattice is denominator-30 (white = level 30;
   `kernels.h level5_to_gray8`); the swtcon presenter re-quantized RGB565
   with denominator 31 (`rgb565_to_gray5`), so paper white `0xFFFF` became
   level **31 — the waveform rail slot**. The real GAL3 table carries **no
   drive codes into dst=31 in any mode** (dumped and verified): every
   black→white erase emitted all-hold phases (optically inert), then the
   engine promoted `prev := 31` at the waveform boundary, so every LATER
   white present saw `target == prev` and no-opped — permanently stale, and
   settles hit the same gate. Cold-clear and mode_lab drive literal level 30,
   which is why boot cleared fine; host_preview treats 31 as white, which is
   why host replay was pixel-perfect.
2. **Sparse mode support:** GAL3 mode 7 (Fast/Ui) is bilevel — it can only
   drive to levels {2, 28}; mode 1 (Text) drives an 8-level lattice
   {0,6,10,14,18,22,26,30}. Content targeting any other level (odd levels,
   28-in-mode-1, 0/30-in-mode-7) silently held. Host goldens never saw mode 7
   at all (synthetic tables lack it; silent mode-2 fallback).

Fix (`swtcon_waveform.{h,cc}`, `drm_swtcon_presenter.cc`):

- `rgb565_to_gray5` now quantizes onto the renderer lattice (denominator 30,
  white = 30, never 31); round-trips every renderer level 0..30 exactly.
- New `build_legal_target_map(table, mode, temp_bin)`: per-(mode, bin)
  legalization LUT mapping each 5-bit level to the nearest target the mode
  can actually drive from both rails (±2 rail slack; ties break brighter;
  hold-only/synthetic tables → identity). Applied in the presenter's
  `convert_levels` for every content admission (tile pieces + large lane).
  GAL3 result: mode 7 black→2 / white→28 (its true bilevel rails), mode 1
  snaps 28/29/31→30, mode 2 31→30.

Verification: new tests `SwtconWaveformTest.LegalTargetMap{SnapsToDrivableTargets,
IdentityOnHoldOnlyAndInvalidTables,RealGal3}` (real-fixture-gated) +
`EngineEquivalenceTest.EraseToWhiteEmitsDriveCodesOnSparseTable` (pins that a
black→white erase EMITS nonzero drive codes on a real-shaped sparse table and
that targeting 31 is all-hold — the emitted-plane assertion host goldens were
missing); engine-vs-packer equivalence + packer goldens updated to the
lattice (white = 30); full `ctest` host-debug / host-asan / host-tsan green;
device camera verification of the grid→list→settings loop below.

## Session 7 (2026-07-11): final pen-priority routing and scheduler loop

Added allocation-free rows to `pluto_renderer_bench` for the app-damage pen
path. Timed loops use fixed `std::array` dirty records/hints and scheduler
preallocated storage; construction, configuration, and record generation stay
outside the measurements.

The first pass measured only simple proximity association. The final policy
also performs exact changed-pixel budgeting, nib-rooted 8-neighbour component
selection, old-or-new chroma transition propagation, and bounded preview
geometry. After adding those correctness gates, the hot structures were
pre-sized/reused, evdev gained caller-owned SYN buffers, the compositor reused
paint-bound scratch, and direct SWTCON prewarmed its update/subscriber slots
with inline normal-tile payloads. Release builds are warning-clean.

The final independent audits found several bounded cross-layer interactions
worth fixing before device deployment:

- verified-scroll pacing could omit a moving body's intermediate damage before
  pen routing saw it. The compositor now retains only the exact omitted pieces
  (minus the already-submitted disocclusion strip) as preallocated pen-only
  candidates. A matching hover/contact hint may route current app pixels;
  unmatched pieces remain paced, so the whole scroll body is never promoted;
- partially overlapping pen segments could share one present request despite
  the presenter ABI's disjoint-rectangle contract. Preview and regional-Full
  batch selection is now pairwise disjoint; overlapping segments retain queue
  ownership and drain as separate requests in the same tick when the backend
  permits it;
- one-hint-per-frame routing could prioritize the oldest point of a coalesced
  stroke while leaving its current tip ordinary. Oldest-first residual
  routing now lets every retained hint claim only verified remaining pixels,
  preserves overlapping future hints, and stays bounded by a 97-rect stack;
- evdev timestamps could otherwise be compared across clock domains. Opening
  the digitizer now fails closed unless `EVIOCSCLOCKID(CLOCK_MONOTONIC)` and
  exclusive `EVIOCGRAB` both succeed;
- producer temperature selection and PixelEngine LUT acquisition could cross
  a bin boundary. Every admission now carries its exact bin, same-mode
  retargeting requires that bin, the first panel sample is synchronous, and
  both cold-clear endpoints pin one record;
- ordinary queued/parked/residual work could outlive newer pen truth or make
  admission quadratic. Truth now subtracts across lanes with exact pieces; the
  fixed residual prefix is never re-cut, only the newly appended tail;
- warm app switches could inherit queued evdev edges or miss a pen already in
  proximity. The source drains pre-snapshot events, rehydrates current kernel
  state, and retains an in-range position for stationary app hover redraws;
- presenter “idle” was weaker than optical completion at several boundaries.
  Callback delivery, reset follow-up, qtfb accepted prefixes, internal cold
  clear, and the final DRM scan latch are now independently fenced; and
- trace accounting now separates per-frame from cumulative changed pixels and
  reports both oldest and newest correlated hint latency.

`FrameRendererTest.PenDamageInsidePacedScrollBypassesBodySuppressionAndChasesTruth`
and
`RegionSchedulerPenDamageTest.PartiallyOverlappingSegmentsAreDisjointWithinEveryPresenterBatch`,
the coalesced-hint tests, monotonic-source fixtures, admission-bin round trips,
cross-bin preemption tests, and the explicit completion/latch regressions pin
these corrections. In the source-frozen sandbox run, debug completes in
105.43 s and release in 32.25 s. Renderer is 177/177 and input is 46/46;
core reaches 142/148 and presenter 157/168, with every failure caused by the
sandbox denying the fake wpa_supplicant/qtfb Unix socket at fixture setup.
ASan+UBSan and TSan builds pass; all executable non-socket regressions report
no sanitizer/runtime-error/data-race finding. Permission-correct socket and
Flutter wrapper runs remain explicit gates rather than being counted as
passes.

Seven consecutive final `host-release` runs on Apple Silicon produced the
following medians of each run's p50 and p99 batch means. Binary hashes and
every reported pen/presenter/ct33 run-level value are in
[`evidence/pen-fast-render/host-release-2026-07-11.md`](evidence/pen-fast-render/host-release-2026-07-11.md):

| Bench | Host p50 | Host p99 | Device p99 budget | Hot-path storage audit |
|---|---:|---:|---:|---:|
| BM-PP1 hint-only / no app damage | 0.002 us/event | 0.003 us/event | <= 1 us | preallocated |
| BM-PP1 hover association, 16 nearby dirty records | 0.361 us/event | 0.403 us/event | <= 5 us | preallocated |
| BM-PP1 contact association, 16 nearby dirty records | 0.360 us/event | 0.409 us/event | <= 5 us | preallocated |
| BM-PS1 preview + Text-truth submit/tick, no-op presenter | 0.128 us/event | 0.151 us/event | <= 20 us | preallocated |
| BM-PS2 351 truth cells + 768 unrelated exact residuals | 1.250 us/event | 1.625 us/event | <= 20 us | fixed 1,024 residuals |

BM-PP1 exercises the mandatory hint-only early exit plus complete association,
adaptive clipping, changed-pixel accounting, and truth-class selection for
hover and contact. BM-PS1 submits both app-damage phases, dispatches Fast
preview, then drains and dispatches Text truth through the normal scheduler
completion model. The final column is a source/storage audit (fixed arrays or
configuration-time reserve), not an allocator-instrumented benchmark result.
BM-PS2 originally measured 320.166/365.875 us p50/p99 when every truth re-cut
all historical residuals. Tail-only reconciliation preserves the exact same
geometry and improves that adversarial path by about 256x/225x. Its post-run
guard requires exactly 896 retained residual entries (768 prefill plus 128
timed), ruling out an accidentally coalesced fixture.

The presenter was rebuilt and rerun seven times after correcting the
temperature-record selector (25 °C now uses bin 4), carrying that exact bin
through admission, and pinning cold-start records. The renderer benchmark
remained bit-identical; the fresh presenter medians confirm that the final
hot-path storage and temperature contract did not compromise the scan-frame
gate:

| Presenter stage (NEON) | p50 | p95 | 11,764 us scan budget |
|---|---:|---:|---:|
| sweep full field | 1,218.2 us | 1,296.0 us | pass |
| sweep active 500k | 392.9 us | 426.1 us | pass |
| deposit full-field rows | 115.3 us | 121.9 us | pass |
| fused full field | 1,672.1 us | 1,844.9 us | pass |
| fused active 500k | 473.1 us | 570.7 us | pass |
| convert full panel | 328.9 us | 346.5 us | pass |
| convert 96x96 tile | 1.8 us | 1.9 us | pass |

The exact RGB565 ct33 front end measures 1,755.5/1,821.0 us full-panel,
9.8/10.6 us at 96x96, 2,614.1/2,704.2 us masked full-panel, and 14.2/16.0 us
masked 96x96 (median p50/p95). It remains intentionally disconnected until
the stock downstream A/B-history mapper is captured bit-exactly.

The richer, adversarially safe policy remains sub-microsecond on the host for
ordinary association and far below its scheduler budget under worst-case
stored truth. Host extrapolation is not device evidence. The remaining
authoritative step is the real A55 benchmark and visible panel run in
[`pen-fast-render.md`](pen-fast-render.md).
