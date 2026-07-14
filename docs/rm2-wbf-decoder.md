# reMarkable 2 WBF decoder provenance and safety boundary

This document records the clean-room inputs and fail-closed contract for
Pluto's host-testable reMarkable 2 waveform decoder. The decoder is format
plumbing only. It does not select a Pluto refresh class, touch `/dev/fb0`, stop
Xochitl, or make the RM2 native presenter eligible for deployment.

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
| [reMarkable's public Linux `rm1xx_5.4.70_v1.6.x` branch](https://github.com/reMarkable/linux/tree/rm1xx_5.4.70_v1.6.x) | The future scanout boundary must use the public framebuffer ABI and must not depend on private Xochitl or QSG symbols | GPL kernel source used only to define the external kernel ABI. The public branch is v1.6.2-era while the observed device reports v1.6.3, so it is not claimed byte-exact |

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
assumption. Future native presentation must join the independently validated
waveform program and scanout ABI at a higher, device-gated layer.

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
commands per byte. This is the stable seam for later profile-specific LUT
codegen without placing file-format branches in the common scheduler.

## Intentional policy gap

The file's raw mode indices are exposed, but no `PlutoRefreshClass` mapping is
implemented here. The E Ink mode-version table and community RM2 observations
do not agree on every fast-mode label. Pluto must first compare raw mode/phase
behavior with the controlled stock oracle, then put the minimum verified map
behind `WaveformProgram`. Guessing here could under-drive the panel.

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
