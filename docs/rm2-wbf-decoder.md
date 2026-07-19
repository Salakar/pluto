# reMarkable 2 WBF decoder provenance and safety boundary

This document records the clean-room inputs and fail-closed contract for
Pluto's host-testable reMarkable 2 waveform decoder. The decoder itself remains
format plumbing: it never owns `/dev/fb0`, power rails, blanking, or scanout.
The profile-gated `Rm2WaveformProgram` and `LcdifTconDisplayBackend` now join
that validated output to Pluto refresh classes and the native LCDIF transport.

## Source and license ledger

The implementation was written for Pluto from the published binary format and
independently checked against permissively licensed parsers. No vendor
waveform bytes and no GPL-only implementation code are copied into the
repository.

| Input | What it established | License/use boundary |
| --- | --- | --- |
| [E Ink 800-1101 Rev01 AF waveform flash file product specification](https://files.waveshare.com/upload/c/c4/E-paper-mode-declaration.pdf) | File CRC32 with bytes 0-3 treated as zero, exact little-endian file length, FPL lot, mode version `0x19`, AF type `0x51`, CS1, temperature/mode meanings, and the fact that a waveform is display-lot-specific | E Ink-authored format specification, used as documentation only |
| [Samuel Holland's DRM EPD helper RFC](https://lists.infradead.org/pipermail/linux-rockchip/2022-April/031024.html) | Three-byte little-endian offsets, additive pointer checksums, header/temperature table shape, 5-bit packed LUT dimensions, and the two-state RLE grammar | Explicit `GPL-2.0 OR MIT`; consulted under the MIT option, with an independent bounded C++ implementation |
| [`yobert/swtcon`](https://github.com/yobert/swtcon) and its [WBF parser](https://raw.githubusercontent.com/yobert/swtcon/main/src/wbf.rs) | Independent RM2-oriented cross-check of the two-level `(mode, temperature)` tables, marker-controlled RLE, temperature intervals, and phase sizing | MIT; behavioral/API cross-check only, no source copied |
| [reMarkable's public Linux `rm1xx_5.4.70_v1.6.x` branch](https://github.com/reMarkable/linux/tree/rm1xx_5.4.70_v1.6.x) | The scanout boundary uses the public framebuffer ABI and does not depend on private stock-UI or QSG symbols | GPL kernel source used only to define the external kernel ABI. The public branch is v1.6.2-era while the observed device reports v1.6.3, so it is not claimed byte-exact |
| [The same branch's i.MX thermal driver](https://github.com/reMarkable/linux/blob/rm1xx_5.4.70_v1.6.x/drivers/thermal/imx_thermal.c) | The driver programs an approximately 10 Hz measurement interval, waits only 20--50 us when `FINISHED` is clear, and returns `-EAGAIN` if the measurement still has not completed | GPL kernel source used only to explain the external sysfs behavior. Exact-tablet sampling independently confirmed the intermittent `EAGAIN` contract; no kernel implementation text is copied |

GPL-only `waved`, `rM2-stuff`, and stock Xochitl disassembly are not source
inputs for this decoder. They may inform later black-box behavioral experiments
but cannot supply implementation text, constants without independent format
provenance, or copied control flow.

## Stock scanout oracle boundary

A fresh read-only trace of the unmodified RM2 stack is the authoritative
scanout oracle for later presenter work. `FBIOGET_FSCREENINFO` reported id
`mxs-lcdif`, `smem_len=33554432`, and `line_length=1040`.
`FBIOGET_VSCREENINFO` reported `260x1408`, virtual `260x23936`, and 32 bits per
pixel; the observed mmap length was 33,554,432 bytes. A 553-call startup sample
of `FBIOPAN_DISPLAY` had median 11.886 ms and p95 11.933 ms, using y-offset
slots 0 through 16. Blank values 0 and 4 bracketed scans, while PUT selected
base slots.

These are scanout observations, not WBF fields. The decoder therefore makes no
framebuffer-size, orientation, slot-count, panning, blanking, or pixel-format
assumption. The generated RM2 profile and native LCDIF device layer own those
independently validated constraints.

## Vendor artifact boundary

The observed active RM2 file is local and ignored:

```text
analysis/native-cutover/rm2/vendor/active.wbf
size:   285735 bytes
sha256: 79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870f9c6f8
panel:  ED103TC2C5
FPL lot: 405
```

It is used only for local validation. It must never be committed, copied into a
payload, embedded in a generated source file, or redistributed. Native device
integration must bind to the tablet's own accepted path, panel, lot, and
SHA-256.

Tests use a small WBF generated from semantic fields and synthetic RLE runs.
No fixture field or byte is copied or derived from the vendor file.

The ignored artifact passes the decoder as 8 modes by 14 temperature bins,
with 79 unique records, 10-159 phases per table, and 1,161,728 decoded packed
bytes. Those figures are inspection evidence only, not redistributable LUT
content.

## Decoder gates

`WbfDecoder::inspect` validates the complete reachable file before returning
metadata:

- input and aggregate decoded sizes are bounded;
- the little-endian file length is exact;
- the standard CRC32 matches with the stored CRC field zeroed;
- header CS1, header CS2, and the temperature-table additive checksum match;
- only the observed AF, mode-version `0x19`, 5-bit LUT layout is accepted;
- temperature boundaries are complete and strictly increasing;
- the XWI name is bounded ASCII and its `R<lot>` and `ED...` tokens agree with
  the header;
- every u24 mode/temperature pointer is in range and carries the correct
  additive checksum;
- metadata tables and RLE records do not overlap;
- every referenced RLE stream terminates, stays within phase/size limits, and
  expands to an exact number of 256-byte packed 5-bit phases;
- independently addressed RLE records cannot overlap.

`WbfDecoder::open` adds the generated-profile authorization gate: exact
SHA-256, exact panel signature, and exact FPL lot are all mandatory. A failed
open clears all prior state.

The decoder stores deduplicated packed phase records. A transition lookup is
constant-time with matrix index `new_state * 32 + old_state` and four 2-bit
commands per byte. `Rm2WaveformProgram` expands only required accepted records
into the measured hot representation, without placing file-format branches in
the common scheduler or redistributing vendor waveform bytes.

## Refresh mapping and native execution

The clean-room oracle work resolved the minimum accepted mode map behind
`Rm2WaveformProgram`: `Text` and `Full` use raw mode 2, `Ui` uses mode 3, and
`Fast` uses mode 6. Open fails unless all required modes exist for the selected
temperature table. The choice remains outside `WbfDecoder`, so parsing cannot
silently invent a display policy.

An exact cross-app warm handoff has one additional RM2 execution rule. The
renderer may partition its complete retained-surface reconciliation into
several presenter jobs, so the backend promotes the first request to an exact
full-panel Text job unless it is the single `{0,0,1,1}` Fast same-surface
liveness proof. A white-only rail failed physical RM2 verification, so the
promoted job drives mode 6 from the recorded source to black, mode 6 from black
to white, then mode 2 from white to the incoming content. This bounded reset is
needed when logical target history cannot represent residual pigment. The
worker remaps the existing transition keys through a 256-byte phase-local LUT;
it does not allocate another panel buffer, rewalk the Flutter surface, or
expose a second lifecycle flow.

`LcdifTconDisplayBackend` consumes the selected immutable record, advances
settled optical state only after completion, writes only within the exact
kernel-reported mapping and slots, enforces the generated phase cadence, and
ends in safe hold. The exact profile binds firmware, kernel, panel, local WBF
path, SHA-256, and geometry before start. There is no nearest-file or
nearest-mode fallback.

## Exact-device representation decisions

All hot-representation choices were measured on the two-core ARMv7 RM2, not
selected from host results alone:

- A generated 65,536-entry RGB565-to-gray table lost to the integer arithmetic
  conversion (about 52 ms versus 45 ms per full panel). A second 1 KiB
  split-byte LUT also lost: arithmetic measured 44.847/44.904 ms p50/p95 while
  the split LUT measured 61.380/61.426 ms. The production path therefore keeps
  exhaustive-hash-pinned arithmetic and removes the generator and generated
  artifact.
- Expanding accepted WBF records once at open won decisively. Exact-device
  transition lookup measured 190.447/190.478 ms p50/p95 through decoded packed
  records versus 20.851/20.887 ms through the expanded tables, a 9.13x/9.12x
  speedup. The immutable expanded representation is retained.
- Opening the tablet's exact 285,735-byte WBF, validating its identity, decoding
  1,161,728 packed bytes, and expanding 1,057,280 hot-table bytes took 78.986 ms
  wall/79.016 ms CPU once at startup. A derived mmap cache was rejected: it
  would not change steady-state lookup, would still need exact vendor
  SHA/panel/lot validation and prefaulting, and would add mutable-cache
  corruption, staleness, transaction, and vendor-byte redistribution risks.
- The retained full-panel phase packer uses a persistent, profile-gated
  two-core ARMv7 kernel. A production-cadence 10,000-phase soak measured
  7.631 ms p50, 7.676 ms p95, 7.699 ms p99, and 7.933 ms maximum against an
  8.234 ms p99 budget. Pan cadence measured 11.975 ms p99 and 12.031 ms
  maximum against the 11.763 ms physical interval plus the 5% fail-closed
  deadline. There were zero encode, full-slot reference, pan, deadline,
  cadence, underflow, or latched-slot-mutation failures, and zero allocations
  or current-RSS growth. The independent 1.46 MiB byte-for-byte slot oracle ran
  for every phase after the preceding pan boundary and before submission of
  the validated slot, so benchmark-only oracle work was not charged to the
  production encode/pan overlap.

## CPU-frequency and thermal safety

The full-panel deadline is met only while both RM2 cores remain at the exact
1.2 GHz policy ceiling. The native backend therefore owns a short,
profile-gated frequency lease rather than changing the device's boot policy:

- acquisition requires exact policy0 identity (`related_cpus` is `0 1`, the
  ceiling is 1,200,000 kHz, the original minimum is within the accepted RM2
  range, and the governor token is safe);
- an exact six-line mode-0600 receipt is atomically published under
  `/run/pluto` before the minimum changes, while a mode-0600 `flock` remains
  exclusively held for the burst;
- acquisition and every 128 soak phases read the exact
  `imx_thermal_zone`. A kernel `EAGAIN` reopens the same exact attribute at
  1 ms intervals for at most 128 fresh attempts. The 127 ms of explicit retry
  spacing spans more than one nominal 10 Hz period, and the fixed attempt count
  also bounds sysfs work. Exhaustion backpressures with no retained frequency
  floor or panel work; malformed data, wrong sensor identity, and non-`EAGAIN`
  errors remain immediate faults. A valid value at/above 45 C remains a thermal
  hold before further work;
- release restores and verifies the original minimum, maximum, governor, and
  CPU binding before retiring the receipt. Bounded readback retries cover the
  RM2 sysfs attribute's observed settling edge without accepting a different
  policy;
- the supervisor runs the companion strict receipt restorer at startup, every
  foreground boundary, stock handoff, and service stop. It refuses malformed,
  mutable, live-owner, PID-reused, or externally changed state.

On the exact tablet, 20 acquire/release cycles had 595.5/7025.5 microseconds
acquire p50/p99 and 221.6/344.0 microseconds release p50/p99, with zero
allocations or RSS growth. A deliberate `SIGKILL` left the matching owner
receipt, exclusively held lock, and 1.2 GHz floor in place; the companion
restorer then recovered the exact 792,000/1,200,000 kHz `ondemand` policy and
retired the receipt. The final 10,000-phase soak peaked at 37 C, restored that
same policy, left the stock UI active, and did not change the device boot ID.

The temperature retry constants were selected on the exact RM2. The original
11-attempt, 10 ms grid exhausted during a real standby-child start and the
bounded supervisor correctly restored stock. Independent sampling then showed
that valid readings occur in narrow, clustered windows rather than reliably on
that grid. The retained 128-attempt, 1 ms scheme completed 1,000/1,000 bounded
target-native production trials without exhaustion or another fault. Monotonic
read-window latency measured 6.062 ms p50, 13.114 ms p99, and 19.137 ms maximum;
temperature remained 35--36 C, allocation and RSS deltas were zero, policy0 was
unchanged, and Xochitl retained the same PID. This changes only how Pluto waits
for a fresh valid kernel sample: it does not cache temperature, relax the 45 C
limit, or permit an unverified frequency raise.

The ignored raw evidence is under `analysis/native-cutover/rm2/perf/`. It
includes binary hashes, the complete-slot reference checksum, resource
counters, thermal state, and the exact on-device commands.

## Offline inspection and metadata codegen

Build the host tool, then inspect a local file while pinning its expected hash:

```bash
cmake --preset host-release -S embedder
cmake --build embedder/build/host-release --target pluto_wbf_inspect
embedder/build/host-release/pluto_wbf_inspect \
  --expect-sha256=79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870f9c6f8 \
  analysis/native-cutover/rm2/vendor/active.wbf
```

`--format=cpp` emits only identity, dimensions, temperature boundaries, and
phase counts. It never emits compressed records, decoded drive commands, or
any other vendor LUT bytes.
