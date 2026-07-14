// Scalar reference of the fused advance+emit+ledger sweep — the former
// PixelEngine::advance inner loop, verbatim. This is the bit-exactness
// contract for sweep_kernels_neon.cc.

#include "presenter/swtcon/sweep_kernels.h"

#include "presenter/swtcon/swtcon_constants.h"

namespace pluto::swtcon {

SweepResult sweep_segment_scalar(const SweepArgs& args, PixelOp* ops) {
  SweepResult result;
  const int phase_count = args.phase_count;
  const int cap = args.dc_cap;
  for (int i = 0; i < args.count; ++i) {
    std::uint8_t f = args.fnum[i];
    if (f == PixelEngine::kFnumIdle) {
      continue;
    }
    const std::uint8_t code =
        args.codes[static_cast<std::size_t>(f) * kWaveformMatrixCells +
                   ((static_cast<std::size_t>(args.next[i]) << 5) |
                    args.prev[i])];
    ops[result.emitted++] =
        PixelOp{static_cast<std::uint16_t>(args.x0 + i), code};
    if (args.drove != nullptr && (code & 0x7) != 0) {
      args.drove[i] = 1;
    }
    // EVERY emitted op is ledgered — DcLedger::charge semantics: a
    // zero-impulse code leaves dc untouched and never saturates.
    const int impulse = args.impulse_map[code & 0x7];
    if ((code & 0x7) != 0) {
      // Impulse-summary fold (the former ImpulseSummaryEmitter body): hold
      // ops are impulse-free and not a drive.
      result.impulse += impulse;
      result.drove = true;
    }
    if (impulse != 0) {
      const int sum = args.dc[i] + impulse;
      if (sum > cap) {
        args.dc[i] = static_cast<std::int8_t>(cap);
        ++result.saturations;
      } else if (sum < -cap) {
        args.dc[i] = static_cast<std::int8_t>(-cap);
        ++result.saturations;
      } else {
        args.dc[i] = static_cast<std::int8_t>(sum);
      }
    }
    ++f;
    if (f >= phase_count) {
      // Waveform boundary: promote, renormalize, link a queued retarget,
      // or go idle.
      args.prev[i] = args.next[i];
      const std::size_t px = args.px0 + static_cast<std::size_t>(i);
      const std::uint8_t mask =
          static_cast<std::uint8_t>(1u << (px & 7));
      std::uint8_t& prev_est_byte = args.prev_est[px >> 3];
      if ((prev_est_byte & mask) != 0) {
        prev_est_byte = static_cast<std::uint8_t>(prev_est_byte & ~mask);
        ++result.prev_estimated_cleared;
      }
      if (args.renorm_dc) {
        args.dc[i] = 0;
      }
      if (args.final_lv[i] != args.next[i]) {
        args.next[i] = args.final_lv[i];
        args.fnum[i] = 0;
      } else {
        args.fnum[i] = PixelEngine::kFnumIdle;
        ++result.completed;
      }
    } else {
      args.fnum[i] = f;
    }
  }
  return result;
}

}  // namespace pluto::swtcon
