// NEON (aarch64) implementation of the fused advance+emit+ledger sweep.
// Bit-exact vs sweep_segment_scalar (sweep_kernels_scalar.cc) over every
// output — pinned by test/presenter/sweep_kernels_test.cc (random-state
// goldens) and the engine-level scalar/NEON parity test in
// pixel_engine_test.cc. The Apple Silicon host and the device A55s are both
// aarch64, so this kernel is golden-tested on host CI as well as in the
// device-arm64 Release build.
//
// Strategy (measured fastest on both the M-series host and the in-order
// A55): the 1024-entry (next5<<5|prev5) phase-slice gather stays SCALAR —
// a 1 KiB table defeats TBL chunking (16 vqtbx4q per 16 lanes measured
// slower than a tight ldrb gather on both cores) — while EVERYTHING else
// (index math, DC saturating charge + saturation count, impulse summary,
// fnum advance, boundary promotion/renormalize/retarget-link, op packing)
// runs 16 lanes wide. Waveform-boundary work (rare: one frame per
// sequence) and partially-active groups keep vector state updates and only
// scalarize the op compaction, so sparse text tiles stay correct and dense
// full-field sweeps hit the wide path.

#include "presenter/swtcon/sweep_kernels.h"

#if defined(__ARM_NEON) && defined(__aarch64__)

#include "presenter/swtcon/swtcon_constants.h"

#include <arm_neon.h>

#include <array>
#include <cstring>

namespace pluto::swtcon {
namespace {

static_assert(sizeof(PixelOp) == 4 && alignof(PixelOp) == 2,
              "vst4q op packing assumes {u16 x, u8 code, u8 pad}");

// Left-pack shuffle LUT for the sparse (non-dense) emission path. For an
// 8-lane active mask `m`, kPackLut[m] holds 32 byte-indices: the first 16
// (idx0) feed vqtbl2q over the 8 candidate 4-byte PixelOps (a 32-byte table)
// to produce output ops 0..3 compacted (active lanes moved to the front, in
// ascending lane order); the second 16 (idx1) produce ops 4..7. Indices for
// output positions beyond popcount(m) are 0xff (>= 32) so vqtbl2q yields 0 —
// those slots sit past `emitted` and are never read. The former scalar
// ctz-compaction loop (a serial bit chain per active pixel) is replaced by
// two vqtbl2q per 8-lane half, which is what makes the sparse full-field
// sweep (~3% idle pixels on a phase-plane flash) fast.
using PackRow = std::array<std::uint8_t, 32>;
constexpr std::array<PackRow, 256> make_pack_lut() {
  std::array<PackRow, 256> table{};
  for (int m = 0; m < 256; ++m) {
    for (int i = 0; i < 32; ++i) {
      table[static_cast<std::size_t>(m)][static_cast<std::size_t>(i)] = 0xff;
    }
    int k = 0;
    for (int lane = 0; lane < 8; ++lane) {
      if ((m & (1 << lane)) != 0) {
        for (int b = 0; b < 4; ++b) {
          table[static_cast<std::size_t>(m)]
               [static_cast<std::size_t>(4 * k + b)] =
                   static_cast<std::uint8_t>(4 * lane + b);
        }
        ++k;
      }
    }
  }
  return table;
}
alignas(16) constexpr std::array<PackRow, 256> kPackLut = make_pack_lut();

// Per-byte movemask: bit j of the result = (mask lane j != 0). `mask` lanes
// must be 0x00 or 0xff (NEON compare results).
inline std::uint16_t movemask_u8(uint8x16_t mask) {
  const uint8x16_t bits = {1, 2, 4, 8, 16, 32, 64, 128,
                           1, 2, 4, 8, 16, 32, 64, 128};
  const uint8x16_t masked = vandq_u8(mask, bits);
  const std::uint16_t lo = vaddv_u8(vget_low_u8(masked));
  const std::uint16_t hi = vaddv_u8(vget_high_u8(masked));
  return static_cast<std::uint16_t>(lo | (hi << 8));
}

// Nibble mask (vshrn trick): 4 bits per lane, lane j != 0 <-> nibble j != 0.
// One non-cross-lane shrn + one lane move — far cheaper than movemask_u8's
// two vaddv cross-lane reductions for the any/all/none checks on the hot
// path (the full byte-granular movemask is only computed on the rare
// sparse-emission and boundary paths that index the pack LUT / popcount).
inline std::uint64_t nibblemask_u8(uint8x16_t mask) {
  return vget_lane_u64(
      vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(mask), 4)), 0);
}

// Loop body over one segment, specialized on the gather-index width.
// kSmallPc (phase_count <= 64, every warm-bin production table and every
// synthetic host table): idx = (sf << 10) | cell fits u16, built with one
// vsli per 8 lanes and stored/reloaded as 32 B instead of the generic
// 64 B u32 chain (4x vshll + 4x vaddw). phase_count 65..255 (cold-bin
// tables) keeps the R1 u32 index build verbatim.
//
// R3 structure: the per-16-lane body is a force-inlined lambda (byte-for-
// byte the R2 loop body) so the remainder (count % 16, when count >= 16)
// can run it as one OVERLAPPED masked group anchored at count-16: lanes
// that the main loop already processed enter with lane_valid = 0, making
// every store a write-back of the unmodified just-written value and every
// accumulator contribution zero — byte-identical to not touching them,
// with no reads past the segment. This retires the per-row scalar tail (a
// full-field row's last segment is 26 px: 16 vector + 10 scalar before
// R3). Segments shorter than one group keep the scalar reference tail.
// (An R3 experiment that ALSO specialized the whole body on the all-active
// mask measured 6-10% SLOWER on the fused build — the ~40/60 random
// dense/mixed dispatch in front of two large bodies mispredicts and bloats
// I-cache; the masked ANDs/BSLs it saved were already hidden by the gather
// chain. Reverted: one body, one predictable path.)
template <bool kSmallPc>
SweepResult sweep_segment_neon_impl(const SweepArgs& args, PixelOp* ops) {

  SweepResult result;
  const uint8x16_t v_idle = vdupq_n_u8(PixelEngine::kFnumIdle);
  const uint8x16_t v_pc = vdupq_n_u8(static_cast<std::uint8_t>(args.phase_count));
  const uint8x16_t v_seven = vdupq_n_u8(0x7);
  const uint8x16_t v_one = vdupq_n_u8(1);
  const int16x8_t v_cap = vdupq_n_s16(args.dc_cap);
  const int16x8_t v_ncap = vdupq_n_s16(static_cast<std::int16_t>(-args.dc_cap));
  const uint16x8_t ramp_lo = {0, 1, 2, 3, 4, 5, 6, 7};
  const uint16x8_t ramp_hi = {8, 9, 10, 11, 12, 13, 14, 15};

  // impulse_map as two TBL tables: entries 8..15 zero (codes are masked to
  // 3 bits before lookup). map_dc mirrors DcLedger::charge (index 0 as
  // configured); map_sum zeroes index 0 — the summary skips hold ops even
  // when impulse_map[0] is configured non-zero. Built with one 8-byte
  // vector load + a lane clear: this setup runs once per SEGMENT CALL (30
  // calls per full-field row), and the R2 shape (zeroed 16 B stack buffer,
  // memcpy, reload) paid a stack round trip each time.
  const int8x8_t map8 = vld1_s8(args.impulse_map);
  const int8x16_t map_dc = vcombine_s8(map8, vdup_n_s8(0));
  const int8x16_t map_sum =
      vcombine_s8(vset_lane_s8(0, map8, 0), vdup_n_s8(0));

  // Saturation count, impulse-summary sum and the drove flag accumulate in
  // vector lanes and reduce to scalars ONCE after the loop. A per-group
  // horizontal reduction (vaddvq/vmaxvq) is a cross-lane pipeline stall,
  // costliest on the in-order A55. The lane accumulators cannot overflow for
  // any legal segment: with G = count/16 <= 65535/16 = 4095 groups, sat_acc
  // holds <= G per u16 lane and imp_acc holds a pairwise sum of magnitude
  // <= 6*G = 24570 per s16 lane, both inside range (the engine drives at most
  // one tile-row segment, G <= 2).
  uint16x8_t sat_acc = vdupq_n_u16(0);
  int16x8_t imp_acc = vdupq_n_s16(0);
  uint8x16_t drove_acc = vdupq_n_u8(0);

  // One 16-lane group at pixel offset `i`. `active` is the effective lane
  // mask (fnum != idle, pre-ANDed with the overlap tail's lane_valid by the
  // caller); `active_nib` its nibble mask (nonzero — all-idle groups are
  // skipped by the caller).
  const auto sweep_group = [&](int i, uint8x16_t f, uint8x16_t active,
                               std::uint64_t active_nib)
                               __attribute__((always_inline)) {
    const uint8x16_t pv = vld1q_u8(args.prev + i);
    const uint8x16_t nx = vld1q_u8(args.next + i);

    // cell = (next5 << 5) | prev5, u16 lanes; safe fnum = 0 on idle lanes
    // (a valid in-bounds gather whose result is discarded).
    const uint16x8_t cell_lo = vorrq_u16(vshll_n_u8(vget_low_u8(nx), 5),
                                         vmovl_u8(vget_low_u8(pv)));
    const uint16x8_t cell_hi = vorrq_u16(vshll_n_u8(vget_high_u8(nx), 5),
                                         vmovl_u8(vget_high_u8(pv)));
    const uint8x16_t sf = vandq_u8(f, active);

    // Gather index = (sf << 10) | cell, one index load + one codes load per
    // lane. idle lanes gather phase 0 (sf == 0); their result is discarded
    // downstream. kSmallPc keeps the index in u16 (vsli fuses the shift+or;
    // half the index stores/loads); larger tables build u32 indexes.
    const uint16x8_t sfw_lo = vmovl_u8(vget_low_u8(sf));
    const uint16x8_t sfw_hi = vmovl_u8(vget_high_u8(sf));
    alignas(16) std::uint8_t code_a[16];
    const std::uint8_t* codes = args.codes;
    if constexpr (kSmallPc) {
      // Four u64 lane extracts (umov) hand the 16 u16 indexes straight to
      // the address units — no stack round trip: the R2 shape (2 vector
      // stores + 4 u64 reloads) both stalled on store-to-load forwarding
      // and burned load-port slots, and load ports are the gather's
      // bottleneck (16 ldrb per group) — biggest effect on the
      // single-load-port in-order A55.
      const uint64x2_t idx_lo =
          vreinterpretq_u64_u16(vsliq_n_u16(cell_lo, sfw_lo, 10));
      const uint64x2_t idx_hi =
          vreinterpretq_u64_u16(vsliq_n_u16(cell_hi, sfw_hi, 10));
      const std::uint64_t four_q[4] = {
          vgetq_lane_u64(idx_lo, 0), vgetq_lane_u64(idx_lo, 1),
          vgetq_lane_u64(idx_hi, 0), vgetq_lane_u64(idx_hi, 1)};
      for (int q = 0; q < 4; ++q) {
        const std::uint64_t four = four_q[q];
        code_a[q * 4 + 0] = codes[four & 0xffff];
        code_a[q * 4 + 1] = codes[(four >> 16) & 0xffff];
        code_a[q * 4 + 2] = codes[(four >> 32) & 0xffff];
        code_a[q * 4 + 3] = codes[four >> 48];
      }
    } else {
      const uint32x4_t idx0 = vaddw_u16(vshll_n_u16(vget_low_u16(sfw_lo), 10),
                                        vget_low_u16(cell_lo));
      const uint32x4_t idx1 = vaddw_u16(vshll_n_u16(vget_high_u16(sfw_lo), 10),
                                        vget_high_u16(cell_lo));
      const uint32x4_t idx2 = vaddw_u16(vshll_n_u16(vget_low_u16(sfw_hi), 10),
                                        vget_low_u16(cell_hi));
      const uint32x4_t idx3 = vaddw_u16(vshll_n_u16(vget_high_u16(sfw_hi), 10),
                                        vget_high_u16(cell_hi));
      alignas(16) std::uint32_t idx_a[16];
      vst1q_u32(idx_a, idx0);
      vst1q_u32(idx_a + 4, idx1);
      vst1q_u32(idx_a + 8, idx2);
      vst1q_u32(idx_a + 12, idx3);
      for (int j = 0; j < 16; ++j) {
        code_a[j] = codes[idx_a[j]];
      }
    }

    // Raw codes feed the emitted ops (scalar emits the raw gathered byte);
    // ledger/summary math masks to 3 bits like the scalar reference.
    const uint8x16_t code_raw = vld1q_u8(code_a);
    const uint8x16_t code =
        vandq_u8(vandq_u8(code_raw, v_seven), active);

    // Latch non-hold drive evidence in the same state-plane pass. `code` is
    // already zero on idle/overlap-tail lanes, so OR'ing a 0/1 mark preserves
    // their previous byte exactly; active non-hold lanes become 1, matching
    // the former post-sweep PixelOp fold without rereading the op stream.
    if (args.drove != nullptr) {
      const uint8x16_t old_drove = vld1q_u8(args.drove + i);
      const uint8x16_t drove = vandq_u8(
          vmvnq_u8(vceqq_u8(code, vdupq_n_u8(0))), v_one);
      vst1q_u8(args.drove + i, vorrq_u8(old_drove, drove));
    }

    // DC charge, 16 lanes: widen to s16, add, clamp to +-cap, count
    // out-of-range lanes. Idle/zero-impulse lanes add 0 and dc is already
    // within cap (charge invariant), so clamp and count are no-ops there —
    // exactly DcLedger::charge's early return.
    const int8x16_t imp = vandq_s8(vqtbl1q_s8(map_dc, code),
                                   vreinterpretq_s8_u8(active));
    const int8x16_t dcv = vld1q_s8(args.dc + i);
    const int16x8_t sum_lo = vaddl_s8(vget_low_s8(dcv), vget_low_s8(imp));
    const int16x8_t sum_hi = vaddl_s8(vget_high_s8(dcv), vget_high_s8(imp));
    const uint16x8_t sat_lo =
        vorrq_u16(vcgtq_s16(sum_lo, v_cap), vcltq_s16(sum_lo, v_ncap));
    const uint16x8_t sat_hi =
        vorrq_u16(vcgtq_s16(sum_hi, v_cap), vcltq_s16(sum_hi, v_ncap));
    // Saturated lanes are all-ones (== -1 as u16): subtracting accumulates a
    // +1 count per saturation into sat_acc (reduced after the loop).
    sat_acc = vsubq_u16(vsubq_u16(sat_acc, sat_lo), sat_hi);
    int8x16_t new_dc = vcombine_s8(
        vqmovn_s16(vminq_s16(vmaxq_s16(sum_lo, v_ncap), v_cap)),
        vqmovn_s16(vminq_s16(vmaxq_s16(sum_hi, v_ncap), v_cap)));

    // Impulse summary fold: non-hold ops only. Pairwise-accumulate into imp_acc
    // and OR codes into drove_acc; both reduce after the loop.
    const int8x16_t imp_sum = vandq_s8(vqtbl1q_s8(map_sum, code),
                                       vreinterpretq_s8_u8(active));
    imp_acc = vpadalq_s8(imp_acc, imp_sum);
    drove_acc = vorrq_u8(drove_acc, code);

    // fnum advance + waveform boundary.
    const uint8x16_t nf = vaddq_u8(sf, v_one);
    const uint8x16_t done = vandq_u8(vcgeq_u8(nf, v_pc), active);
    uint8x16_t new_f = vbslq_u8(active, nf, f);

    if (nibblemask_u8(done) == 0) {
      // Common mid-sequence frame: no boundary work.
      vst1q_u8(args.fnum + i, new_f);
      vst1q_s8(args.dc + i, new_dc);
    } else {
      const uint8x16_t fin = vld1q_u8(args.final_lv + i);
      const uint8x16_t restart =
          vandq_u8(done, vmvnq_u8(vceqq_u8(fin, nx)));
      // prev' = done ? next : prev; next' = restart ? final : next;
      // fnum' = restart ? 0 : done ? idle : nf.
      vst1q_u8(args.prev + i, vbslq_u8(done, nx, pv));
      vst1q_u8(args.next + i, vbslq_u8(restart, fin, nx));
      new_f = vbslq_u8(done, v_idle, new_f);
      new_f = vbicq_u8(new_f, restart);  // restart lanes -> 0
      vst1q_u8(args.fnum + i, new_f);
      if (args.renorm_dc) {
        new_dc = vbicq_s8(new_dc, vreinterpretq_s8_u8(done));
      }
      vst1q_s8(args.dc + i, new_dc);

      const std::uint16_t done_bits = movemask_u8(done);
      const std::uint16_t restart_bits = movemask_u8(restart);
      result.completed += static_cast<std::uint32_t>(
          __builtin_popcount(done_bits & ~restart_bits));

      // prev_est clear for done lanes (renormalize_on_completion).
      const std::size_t px = args.px0 + static_cast<std::size_t>(i);
      if ((px & 7) == 0) {
        const std::size_t byte = px >> 3;
        const std::uint16_t old_bits = static_cast<std::uint16_t>(
            args.prev_est[byte] |
            (static_cast<std::uint16_t>(args.prev_est[byte + 1]) << 8));
        const std::uint16_t cleared_bits =
            static_cast<std::uint16_t>(old_bits & done_bits);
        args.prev_est[byte] = static_cast<std::uint8_t>(
            args.prev_est[byte] & ~(done_bits & 0xff));
        args.prev_est[byte + 1] = static_cast<std::uint8_t>(
            args.prev_est[byte + 1] & ~(done_bits >> 8));
        result.prev_estimated_cleared += static_cast<std::uint32_t>(
            __builtin_popcount(cleared_bits));
      } else {
        std::uint16_t bits = done_bits;
        while (bits != 0) {
          const int j = __builtin_ctz(bits);
          bits = static_cast<std::uint16_t>(bits & (bits - 1));
          const std::size_t p = px + static_cast<std::size_t>(j);
          const std::uint8_t mask =
              static_cast<std::uint8_t>(1u << (p & 7));
          std::uint8_t& prev_est_byte = args.prev_est[p >> 3];
          if ((prev_est_byte & mask) != 0) {
            prev_est_byte =
                static_cast<std::uint8_t>(prev_est_byte & ~mask);
            ++result.prev_estimated_cleared;
          }
        }
      }
    }

    // Op emission (ascending x). The candidate ops' interleaved bytes
    // (x_lo, x_hi, code, 0) are built once for both paths: dense groups (all
    // 16 lanes active — the full-field / large-region shape) store all 16 via
    // one st4; partial groups (sparse text tiles, and the ~3% target==prev
    // idle pixels scattered through a phase-plane flash) left-pack the active
    // lanes with the shuffle LUT + vqtbl2q instead of a serial ctz loop. The
    // dense test reuses the nibble mask; the byte-granular movemask is only
    // built when the pack LUT needs it.
    const uint16x8_t base =
        vdupq_n_u16(static_cast<std::uint16_t>(args.x0 + i));
    const uint16x8_t xs_lo = vaddq_u16(base, ramp_lo);
    const uint16x8_t xs_hi = vaddq_u16(base, ramp_hi);
    const uint8x16_t x_lo_bytes =
        vcombine_u8(vmovn_u16(xs_lo), vmovn_u16(xs_hi));
    const uint8x16_t x_hi_bytes =
        vcombine_u8(vshrn_n_u16(xs_lo, 8), vshrn_n_u16(xs_hi, 8));
    if (active_nib == ~std::uint64_t{0}) {
      uint8x16x4_t packed;
      packed.val[0] = x_lo_bytes;
      packed.val[1] = x_hi_bytes;
      packed.val[2] = code_raw;
      packed.val[3] = vdupq_n_u8(0);
      vst4q_u8(reinterpret_cast<std::uint8_t*>(ops + result.emitted),
               packed);
      result.emitted += 16;
    } else {
      const std::uint16_t active_bits = movemask_u8(active);
      // Build the 16 candidate PixelOps AoS in registers (no memory round
      // trip): a 4-way byte interleave of (x_lo, x_hi, code, 0). cand_lo
      // holds ops 0..7, cand_hi ops 8..15, each a 32-byte vqtbl2q table.
      const uint8x16x2_t z01 = vzipq_u8(x_lo_bytes, x_hi_bytes);
      const uint8x16x2_t z23 = vzipq_u8(code_raw, vdupq_n_u8(0));
      const uint16x8x2_t wlo =
          vzipq_u16(vreinterpretq_u16_u8(z01.val[0]),
                    vreinterpretq_u16_u8(z23.val[0]));
      const uint16x8x2_t whi =
          vzipq_u16(vreinterpretq_u16_u8(z01.val[1]),
                    vreinterpretq_u16_u8(z23.val[1]));
      const uint8x16x2_t cand_lo = {vreinterpretq_u8_u16(wlo.val[0]),
                                    vreinterpretq_u8_u16(wlo.val[1])};
      const uint8x16x2_t cand_hi = {vreinterpretq_u8_u16(whi.val[0]),
                                    vreinterpretq_u8_u16(whi.val[1])};
      const std::uint8_t mask_lo = static_cast<std::uint8_t>(active_bits);
      const std::uint8_t mask_hi = static_cast<std::uint8_t>(active_bits >> 8);
      const int n_lo = __builtin_popcount(mask_lo);
      std::uint8_t* out =
          reinterpret_cast<std::uint8_t*>(ops + result.emitted);
      vst1q_u8(out, vqtbl2q_u8(cand_lo,
                               vld1q_u8(kPackLut[mask_lo].data())));
      vst1q_u8(out + 16, vqtbl2q_u8(cand_lo,
                                    vld1q_u8(kPackLut[mask_lo].data() + 16)));
      vst1q_u8(out + n_lo * 4,
               vqtbl2q_u8(cand_hi, vld1q_u8(kPackLut[mask_hi].data())));
      vst1q_u8(out + n_lo * 4 + 16,
               vqtbl2q_u8(cand_hi, vld1q_u8(kPackLut[mask_hi].data() + 16)));
      result.emitted +=
          static_cast<std::uint32_t>(n_lo + __builtin_popcount(mask_hi));
    }
  };

  const int vec_count = args.count & ~15;
  int i = 0;
  for (; i < vec_count; i += 16) {
    const uint8x16_t f = vld1q_u8(args.fnum + i);
    const uint8x16_t active = vmvnq_u8(vceqq_u8(f, v_idle));
    const std::uint64_t active_nib = nibblemask_u8(active);
    if (active_nib == 0) {
      continue;  // whole group idle
    }
    sweep_group(i, f, active, active_nib);
  }

  if (i < args.count) {
    if (args.count >= 16) {
      // Overlapped masked remainder: one group anchored at count-16.
      // Lanes below 16-rem were processed by the main loop and are forced
      // inactive; the group reads/writes stay inside the segment.
      const int rem = args.count - i;
      const int g = args.count - 16;
      const uint8x16_t lane_ramp = {0, 1, 2,  3,  4,  5,  6,  7,
                                    8, 9, 10, 11, 12, 13, 14, 15};
      const uint8x16_t lane_valid =
          vcgeq_u8(lane_ramp, vdupq_n_u8(static_cast<std::uint8_t>(16 - rem)));
      const uint8x16_t f = vld1q_u8(args.fnum + g);
      const uint8x16_t active =
          vandq_u8(vmvnq_u8(vceqq_u8(f, v_idle)), lane_valid);
      const std::uint64_t active_nib = nibblemask_u8(active);
      if (active_nib != 0) {
        sweep_group(g, f, active, active_nib);
      }
      i = args.count;
    }
  }

  // Reduce the vector accumulators once (see the declarations above).
  result.saturations += vaddlvq_u16(sat_acc);
  result.impulse += vaddlvq_s16(imp_acc);
  if (vmaxvq_u8(drove_acc) != 0) {
    result.drove = true;
  }

  if (i < args.count) {
    SweepArgs tail = args;
    tail.prev += i;
    tail.next += i;
    tail.final_lv += i;
    tail.fnum += i;
    tail.dc += i;
    if (tail.drove != nullptr) {
      tail.drove += i;
    }
    tail.px0 += static_cast<std::size_t>(i);
    tail.x0 += i;
    tail.count -= i;
    const SweepResult t = sweep_segment_scalar(tail, ops + result.emitted);
    result.emitted += t.emitted;
    result.completed += t.completed;
    result.saturations += t.saturations;
    result.prev_estimated_cleared += t.prev_estimated_cleared;
    result.impulse += t.impulse;
    result.drove = result.drove || t.drove;
  }
  return result;
}

}  // namespace

SweepResult sweep_segment_neon(const SweepArgs& args, PixelOp* ops) {
  // fnum is u8 and the boundary compare runs in u8 lanes; every real
  // waveform has phase_count <= 255 (cold-bin worst ~244), but stay exact
  // for synthetic extremes.
  if (args.phase_count > 255 || args.phase_count <= 0) {
    return sweep_segment_scalar(args, ops);
  }
  // u16 gather indexes are exact iff (phase_count-1) << 10 | 1023 fits u16,
  // i.e. phase_count <= 64 — every warm-bin production table and every
  // synthetic host table. Larger (cold-bin) tables take the u32 build.
  return args.phase_count <= 64 ? sweep_segment_neon_impl<true>(args, ops)
                                : sweep_segment_neon_impl<false>(args, ops);
}

}  // namespace pluto::swtcon

#endif  // __ARM_NEON && __aarch64__
