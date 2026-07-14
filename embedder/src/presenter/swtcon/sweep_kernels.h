#ifndef PLUTO_PRESENTER_SWTCON_SWEEP_KERNELS_H_
#define PLUTO_PRESENTER_SWTCON_SWEEP_KERNELS_H_

#include "presenter/swtcon/pixel_engine.h"

#include <cstddef>
#include <cstdint>

// Fused advance+emit+ledger sweep kernels (hot path).
//
// One call advances every pixel of ONE tile-row segment (a single tile's
// span inside a single row, so mode/bin/phase-table are uniform) by one
// phase: LUT code gather, op emission, DC-ledger charge, fnum advance and
// waveform-boundary promotion — exactly the per-pixel body PixelEngine::
// advance used to inline.
//
// Contracts (mirrors src/renderer/kernels.h):
//   * sweep_segment_scalar is the bit-exact reference — its behavior is the
//     former PixelEngine::advance inner loop, verbatim.
//   * sweep_segment_neon (aarch64) must be bit-exact vs the scalar
//     reference over EVERY output: emitted ops (order, x, code), the
//     prev/next/final/fnum planes, the dc plane, the prev_est bitplane, and
//     every SweepResult field. Golden-tested over random states in
//     test/presenter/sweep_kernels_test.cc and at engine level in
//     pixel_engine_test.cc.
//   * The unsuffixed sweep_segment dispatches to the fastest available
//     implementation.

namespace pluto::swtcon {

// Inputs/state for one tile-row segment sweep. All plane pointers are
// pre-offset to the segment's first pixel (row_base + x0); `px0` is that
// pixel's ABSOLUTE plane index (row * stride + x0) for prev_est bitplane
// addressing, which is bit-indexed by absolute plane index.
struct SweepArgs {
  std::uint8_t* prev = nullptr;
  std::uint8_t* next = nullptr;
  std::uint8_t* final_lv = nullptr;
  std::uint8_t* fnum = nullptr;
  std::int8_t* dc = nullptr;        // DcLedger per-pixel impulse plane
  // Optional per-pixel evidence plane. A non-hold emitted code latches 1;
  // hold/idle lanes preserve the existing byte. Folding this into the sweep
  // avoids a second scalar pass over emitted PixelOps in PixelEngine.
  std::uint8_t* drove = nullptr;
  std::uint8_t* prev_est = nullptr; // DcLedger bitplane BASE (not offset)
  std::size_t px0 = 0;              // absolute plane index of pixel 0
  int x0 = 0;                       // logical column of pixel 0
  int count = 0;                    // pixels in the segment (<= tile_px)
  const std::uint8_t* codes = nullptr;  // LutRecord::codes.data()
  int phase_count = 0;
  const std::int8_t* impulse_map = nullptr;  // 8 entries (DcLedgerConfig)
  std::int8_t dc_cap = 0;
  // trust_vendor_balance && balanced_mode(tile.mode): a completed sequence
  // renormalizes dc[px] := 0 (DcLedger::renormalize_on_completion).
  bool renorm_dc = false;
};

struct SweepResult {
  std::uint32_t emitted = 0;      // ops written (== active pixels swept)
  std::uint32_t completed = 0;    // pixels that went idle this phase
  std::uint32_t saturations = 0;  // dc clamps (DcLedger::charge semantics)
  // Exact number of prev_est 1->0 transitions at waveform boundaries. The
  // owning DcLedger folds this into its O(1) estimate count after each
  // segment; counting transitions (not done lanes) preserves idempotence.
  std::uint32_t prev_estimated_cleared = 0;
  // Impulse-summary accumulation folded into the sweep (the former
  // ImpulseSummaryEmitter pass): sum of impulse_map[code] over NON-HOLD
  // emitted ops, and whether any non-hold op was emitted.
  std::int32_t impulse = 0;
  bool drove = false;
};

// Bit-exact reference (the former advance inner loop). Appends exactly one
// PixelOp per active pixel to `ops`, ascending x.
SweepResult sweep_segment_scalar(const SweepArgs& args, PixelOp* ops);

#if defined(__ARM_NEON) && defined(__aarch64__)
SweepResult sweep_segment_neon(const SweepArgs& args, PixelOp* ops);
#endif

inline SweepResult sweep_segment(const SweepArgs& args, PixelOp* ops) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  return sweep_segment_neon(args, ops);
#else
  return sweep_segment_scalar(args, ops);
#endif
}

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_SWEEP_KERNELS_H_
