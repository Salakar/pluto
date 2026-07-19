#include "presenter/swtcon/mapped_sweep.h"

#include "presenter/swtcon/swtcon_constants.h"

#include <algorithm>
#include <cstddef>

#if defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace pluto::swtcon {
namespace {

inline std::size_t waveform_cell(std::uint16_t transition) {
  const std::size_t source = (transition >> 5) & 31u;
  const std::size_t drive = transition & 31u;
  return (drive << 5) | source;
}

inline void fold_result(MappedSweepResult* result,
                        std::uint8_t code,
                        int impulse) {
  if ((code & 7u) != 0) {
    result->impulse += impulse;
    result->drove = true;
  }
}

}  // namespace

MappedSweepResult mapped_sweep_scalar(const MappedSweepArgs& args,
                                      MappedPixelOp* ops) {
  MappedSweepResult result;
  const int cap = args.dc_cap;
  for (int i = 0; i < args.count; ++i) {
    if (args.terminal != nullptr) {
      args.terminal[i] = 0;
    }
    const std::uint8_t f = args.uniform_phase >= 0
                               ? static_cast<std::uint8_t>(args.uniform_phase)
                               : args.fnum[i];
    if (f == kMappedSweepIdle) {
      continue;
    }

    const std::uint8_t code =
        args.codes[static_cast<std::size_t>(f) * kWaveformMatrixCells +
                   waveform_cell(args.transitions[i])];
    ops[result.emitted++] = MappedPixelOp{
        static_cast<std::uint16_t>(args.x0 + i), code, 0};

    // Every active lane is ledgered, including identity transitions and hold
    // codes.  Only the summary treats hold as non-driving.
    const int impulse = args.impulse_map[code & 7u];
    fold_result(&result, code, impulse);
    if (impulse != 0) {
      const int sum = static_cast<int>(args.dc[i]) + impulse;
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

    const int next_phase = static_cast<int>(f) + 1;
    if (next_phase >= args.phase_count) {
      if (args.uniform_phase < 0) {
        args.fnum[i] = kMappedSweepIdle;
      }
      if (args.terminal != nullptr) {
        args.terminal[i] = 1;
      }
      ++result.completed;
    } else {
      if (args.uniform_phase < 0) {
        args.fnum[i] = static_cast<std::uint8_t>(next_phase);
      }
    }
  }
  return result;
}

#if defined(__ARM_NEON) && defined(__aarch64__)
namespace {

inline std::uint16_t movemask_u8(uint8x16_t mask) {
  const uint8x16_t bits = {1, 2, 4, 8, 16, 32, 64, 128,
                           1, 2, 4, 8, 16, 32, 64, 128};
  const uint8x16_t masked = vandq_u8(mask, bits);
  const std::uint16_t lo = vaddv_u8(vget_low_u8(masked));
  const std::uint16_t hi = vaddv_u8(vget_high_u8(masked));
  return static_cast<std::uint16_t>(lo | (hi << 8));
}

inline std::uint64_t nibblemask_u8(uint8x16_t mask) {
  return vget_lane_u64(
      vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(mask), 4)), 0);
}

template <bool kSmallPhaseCount, bool kUniformPhase>
MappedSweepResult mapped_sweep_neon_impl(const MappedSweepArgs &args,
                                         MappedPixelOp *ops) {
  MappedSweepResult result;
  const uint8x16_t v_idle = vdupq_n_u8(kMappedSweepIdle);
  const uint8x16_t v_pc =
      vdupq_n_u8(static_cast<std::uint8_t>(args.phase_count));
  const uint8x16_t v_seven = vdupq_n_u8(7);
  const uint8x16_t v_one = vdupq_n_u8(1);
  const int16x8_t v_cap = vdupq_n_s16(args.dc_cap);
  const int16x8_t v_ncap =
      vdupq_n_s16(static_cast<std::int16_t>(-args.dc_cap));
  const uint16x8_t ramp_lo = {0, 1, 2, 3, 4, 5, 6, 7};
  const uint16x8_t ramp_hi = {8, 9, 10, 11, 12, 13, 14, 15};

  const int8x8_t map8 = vld1_s8(args.impulse_map);
  const int8x16_t map_dc = vcombine_s8(map8, vdup_n_s8(0));
  const int8x16_t map_sum =
      vcombine_s8(vset_lane_s8(0, map8, 0), vdup_n_s8(0));

  uint32x4_t saturation_acc = vdupq_n_u32(0);
  int32x4_t impulse_acc = vdupq_n_s32(0);
  uint8x16_t drove_acc = vdupq_n_u8(0);

  const auto sweep_group = [&](int i, uint8x16_t f,
                               uint8x16_t active,
                               std::uint64_t active_nibbles)
                               __attribute__((always_inline)) {
    const uint16x8_t transition_lo = vld1q_u16(args.transitions + i);
    const uint16x8_t transition_hi = vld1q_u16(args.transitions + i + 8);
    const uint16x8_t v_31 = vdupq_n_u16(31);

    // Mapper orientation is source<<5|drive.  Transpose to the decoder's
    // drive<<5|source cell without touching the immutable transition plane.
    const uint16x8_t cell_lo = vorrq_u16(
        vshlq_n_u16(vandq_u16(transition_lo, v_31), 5),
        vandq_u16(vshrq_n_u16(transition_lo, 5), v_31));
    const uint16x8_t cell_hi = vorrq_u16(
        vshlq_n_u16(vandq_u16(transition_hi, v_31), 5),
        vandq_u16(vshrq_n_u16(transition_hi, 5), v_31));
    const uint8x16_t safe_f = kUniformPhase ? f : vandq_u8(f, active);
    const uint16x8_t fw_lo = vmovl_u8(vget_low_u8(safe_f));
    const uint16x8_t fw_hi = vmovl_u8(vget_high_u8(safe_f));

    alignas(16) std::uint8_t code_bytes[16];
    if constexpr (kSmallPhaseCount) {
      const uint64x2_t index_lo =
          vreinterpretq_u64_u16(vsliq_n_u16(cell_lo, fw_lo, 10));
      const uint64x2_t index_hi =
          vreinterpretq_u64_u16(vsliq_n_u16(cell_hi, fw_hi, 10));
      const std::uint64_t packed_indexes[4] = {
          vgetq_lane_u64(index_lo, 0), vgetq_lane_u64(index_lo, 1),
          vgetq_lane_u64(index_hi, 0), vgetq_lane_u64(index_hi, 1)};
      for (int q = 0; q < 4; ++q) {
        const std::uint64_t packed = packed_indexes[q];
        code_bytes[q * 4] = args.codes[packed & 0xffffu];
        code_bytes[q * 4 + 1] = args.codes[(packed >> 16) & 0xffffu];
        code_bytes[q * 4 + 2] = args.codes[(packed >> 32) & 0xffffu];
        code_bytes[q * 4 + 3] = args.codes[packed >> 48];
      }
    } else {
      const uint32x4_t index0 = vaddw_u16(
          vshll_n_u16(vget_low_u16(fw_lo), 10), vget_low_u16(cell_lo));
      const uint32x4_t index1 = vaddw_u16(
          vshll_n_u16(vget_high_u16(fw_lo), 10), vget_high_u16(cell_lo));
      const uint32x4_t index2 = vaddw_u16(
          vshll_n_u16(vget_low_u16(fw_hi), 10), vget_low_u16(cell_hi));
      const uint32x4_t index3 = vaddw_u16(
          vshll_n_u16(vget_high_u16(fw_hi), 10), vget_high_u16(cell_hi));
      alignas(16) std::uint32_t indexes[16];
      vst1q_u32(indexes, index0);
      vst1q_u32(indexes + 4, index1);
      vst1q_u32(indexes + 8, index2);
      vst1q_u32(indexes + 12, index3);
      for (int lane = 0; lane < 16; ++lane) {
        code_bytes[lane] = args.codes[indexes[lane]];
      }
    }

    const uint8x16_t code_raw = vld1q_u8(code_bytes);
    const uint8x16_t code = kUniformPhase
                                ? vandq_u8(code_raw, v_seven)
                                : vandq_u8(vandq_u8(code_raw, v_seven), active);
    const int8x16_t impulse =
        kUniformPhase
            ? vqtbl1q_s8(map_dc, code)
            : vandq_s8(vqtbl1q_s8(map_dc, code), vreinterpretq_s8_u8(active));
    const uint8x16_t charge =
        vmvnq_u8(vceqq_s8(impulse, vdupq_n_s8(0)));
    if (nibblemask_u8(charge) != 0) {
      const int8x16_t old_dc = vld1q_s8(args.dc + i);
      const int16x8_t sum_lo =
          vaddl_s8(vget_low_s8(old_dc), vget_low_s8(impulse));
      const int16x8_t sum_hi =
          vaddl_s8(vget_high_s8(old_dc), vget_high_s8(impulse));
      const uint16x8_t charge_lo =
          vcgtq_u16(vmovl_u8(vget_low_u8(charge)), vdupq_n_u16(0));
      const uint16x8_t charge_hi =
          vcgtq_u16(vmovl_u8(vget_high_u8(charge)), vdupq_n_u16(0));
      const uint16x8_t saturated_lo = vandq_u16(
          vorrq_u16(vcgtq_s16(sum_lo, v_cap), vcltq_s16(sum_lo, v_ncap)),
          charge_lo);
      const uint16x8_t saturated_hi = vandq_u16(
          vorrq_u16(vcgtq_s16(sum_hi, v_cap), vcltq_s16(sum_hi, v_ncap)),
          charge_hi);
      const uint16x8_t saturation_counts =
          vsubq_u16(vdupq_n_u16(0), vpaddq_u16(saturated_lo, saturated_hi));
      saturation_acc = vpadalq_u16(saturation_acc, saturation_counts);

      const int8x16_t clamped_dc =
          vcombine_s8(vqmovn_s16(vminq_s16(vmaxq_s16(sum_lo, v_ncap), v_cap)),
                      vqmovn_s16(vminq_s16(vmaxq_s16(sum_hi, v_ncap), v_cap)));
      // DcLedger::charge is an exact no-op for zero impulse. Preserve that
      // behavior even for a diagnostic/corrupt pre-state outside +-cap.
      const int8x16_t new_dc = vbslq_s8(charge, clamped_dc, old_dc);
      vst1q_s8(args.dc + i, new_dc);
    }

    const int8x16_t summary_impulse =
        kUniformPhase
            ? vqtbl1q_s8(map_sum, code)
            : vandq_s8(vqtbl1q_s8(map_sum, code), vreinterpretq_s8_u8(active));
    impulse_acc =
        vpadalq_s16(impulse_acc, vpaddlq_s8(summary_impulse));
    drove_acc = vorrq_u8(drove_acc, code);

    const uint8x16_t next_f = vaddq_u8(safe_f, v_one);
    const uint8x16_t done =
        kUniformPhase
            ? vdupq_n_u8(static_cast<std::uint8_t>(
                  args.uniform_phase + 1 >= args.phase_count ? 0xff : 0))
            : vandq_u8(vcgeq_u8(next_f, v_pc), active);
    if constexpr (!kUniformPhase) {
      const uint8x16_t new_f =
          vbslq_u8(done, v_idle, vbslq_u8(active, next_f, f));
      vst1q_u8(args.fnum + i, new_f);
    }
    if (args.terminal != nullptr) {
      // Store exactly 0 or 1 for every lane, including idle lanes.
      vst1q_u8(args.terminal + i, vandq_u8(done, v_one));
    }
    if constexpr (!kUniformPhase) {
      if (nibblemask_u8(done) != 0) {
        const std::uint16_t done_bits = movemask_u8(done);
        result.completed +=
            static_cast<std::uint32_t>(__builtin_popcount(done_bits));
      }
    }

    const uint16x8_t base =
        vdupq_n_u16(static_cast<std::uint16_t>(args.x0 + i));
    const uint16x8_t x_lo = vaddq_u16(base, ramp_lo);
    const uint16x8_t x_hi = vaddq_u16(base, ramp_hi);
    const uint8x16_t x_low_bytes =
        vcombine_u8(vmovn_u16(x_lo), vmovn_u16(x_hi));
    const uint8x16_t x_high_bytes =
        vcombine_u8(vshrn_n_u16(x_lo, 8), vshrn_n_u16(x_hi, 8));

    if (kUniformPhase || active_nibbles == ~std::uint64_t{0}) {
      uint8x16x4_t packed;
      packed.val[0] = x_low_bytes;
      packed.val[1] = x_high_bytes;
      packed.val[2] = code_raw;
      packed.val[3] = vdupq_n_u8(0);
      vst4q_u8(reinterpret_cast<std::uint8_t*>(ops + result.emitted), packed);
      result.emitted += 16;
    } else {
      std::uint16_t active_bits = movemask_u8(active);
      while (active_bits != 0) {
        const int lane = __builtin_ctz(active_bits);
        active_bits = static_cast<std::uint16_t>(active_bits &
                                                 (active_bits - 1));
        ops[result.emitted++] = MappedPixelOp{
            static_cast<std::uint16_t>(args.x0 + i + lane),
            code_bytes[lane], 0};
      }
    }
  };

  int i = 0;
  const int vector_count = args.count & ~15;
  for (; i < vector_count; i += 16) {
    const uint8x16_t f =
        kUniformPhase
            ? vdupq_n_u8(static_cast<std::uint8_t>(args.uniform_phase))
            : vld1q_u8(args.fnum + i);
    const uint8x16_t active =
        kUniformPhase ? vdupq_n_u8(0xff) : vmvnq_u8(vceqq_u8(f, v_idle));
    const std::uint64_t active_nibbles = nibblemask_u8(active);
    if (!kUniformPhase && active_nibbles == 0) {
      if (args.terminal != nullptr) {
        vst1q_u8(args.terminal + i, vdupq_n_u8(0));
      }
      continue;
    }
    sweep_group(i, f, active, active_nibbles);
  }

  result.saturations += vaddvq_u32(saturation_acc);
  result.impulse += vaddvq_s32(impulse_acc);
  result.drove = vmaxvq_u8(drove_acc) != 0;

  if (i < args.count) {
    MappedSweepArgs tail = args;
    tail.transitions += i;
    if (tail.fnum != nullptr) {
      tail.fnum += i;
    }
    tail.dc += i;
    if (tail.terminal != nullptr) {
      tail.terminal += i;
    }
    tail.x0 += i;
    tail.count -= i;
    const MappedSweepResult tail_result =
        mapped_sweep_scalar(tail, ops + result.emitted);
    result.emitted += tail_result.emitted;
    result.completed += tail_result.completed;
    result.saturations += tail_result.saturations;
    result.impulse += tail_result.impulse;
    result.drove = result.drove || tail_result.drove;
  }
  if constexpr (kUniformPhase) {
    result.completed = args.uniform_phase + 1 >= args.phase_count
                           ? static_cast<std::uint32_t>(args.count)
                           : 0;
  }
  return result;
}

}  // namespace

MappedSweepResult mapped_sweep_neon(const MappedSweepArgs& args,
                                    MappedPixelOp* ops) {
  if (args.phase_count <= 0 || args.phase_count > 255) {
    return mapped_sweep_scalar(args, ops);
  }
  if (args.uniform_phase >= 0) {
    return args.phase_count <= 64
               ? mapped_sweep_neon_impl<true, true>(args, ops)
               : mapped_sweep_neon_impl<false, true>(args, ops);
  }
  return args.phase_count <= 64
             ? mapped_sweep_neon_impl<true, false>(args, ops)
             : mapped_sweep_neon_impl<false, false>(args, ops);
}
#endif

}  // namespace pluto::swtcon
