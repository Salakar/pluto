#include "presenter/swtcon/phase_emit.h"

#include <algorithm>
#include <cassert>
#include <cstring>

#if defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace pluto::swtcon {
namespace {

constexpr std::size_t kDirtyWords =
    (static_cast<std::size_t>(kDrmHeight) + 63) / 64;

inline void set_bit_parallel(std::vector<std::uint64_t> &bits, int index) {
  __atomic_fetch_or(&bits[static_cast<std::size_t>(index) >> 6],
                    std::uint64_t{1} << (index & 63), __ATOMIC_RELAXED);
}

inline bool test_bit(const std::vector<std::uint64_t>& bits, int index) {
  return (bits[static_cast<std::size_t>(index) >> 6] >>
          (index & 63)) & 1u;
}

// Lane math inherited VERBATIM from swtcon_packer.cc (store_phase_code,
// proven from packer 0xa565c0): the pixel field is 3-bit, 4 pixels per
// 16-bit word in bits[11:0]; the leftmost pixel of the group of 4
// occupies bits[11:9], so shift = 9 - 3*(x % 4). Clear only this lane's 3
// pixel bits, then OR the 3-bit drive code: the control bits laid down by
// init_blank_phase_frame (0x1000/0x2000/0x4000/0x8000) live in bits[15:12]
// with ZERO overlap and must survive every data-word write — clobbering
// them freezes the panel's frame-sync/gate scan (the raw-fill failure).
// `window` points at the row's data window (word kFirstDataWord is
// index 0), so word index = x / 4.
inline void deposit_code(std::uint16_t* window, int x, std::uint8_t code) {
  const std::size_t word = static_cast<std::size_t>(x) / 4;
  const int shift = 9 - 3 * (x % 4);
  const std::uint16_t mask = static_cast<std::uint16_t>(0x7 << shift);
  window[word] = static_cast<std::uint16_t>(
      (window[word] & ~mask) |
      (static_cast<std::uint16_t>(code & 0x7) << shift));
}

// Scalar deposit reference: one lane-RMW per op (the byte-exactness
// contract for the NEON packed deposit below).
inline void deposit_ops_scalar(std::uint16_t* window, const PixelOp* ops,
                               std::size_t count) {
  for (std::size_t i = 0; i < count; ++i) {
    deposit_code(window, ops[i].x, ops[i].code);
  }
}

// ---- fused single-pass compose (default hot path) ----------------------
//
// emit_row's original body composed a row in three passes over the 480 B
// data window: memcpy(template -> staging), deposit_ops (RMW staging), then
// memcpy(staging -> target). The compose_* helpers collapse that into ONE
// pass: every destination word is written EXACTLY ONCE as
//   dest[w] = data_template[w] | (deposited lanes of ops in word w)
// straight into the target/shadow window. There is no staging round-trip
// and, critically, the target is never read (WC-safe: writes stay strictly
// ascending, template supplies the OR base). Byte-identical to the
// memcpy-then-deposit_ops reference by construction — the OR base and lane
// math are unchanged, and ops carry unique ascending x so each lane is set
// at most once. `force_scalar_deposit` still routes emit_row through the
// unmodified deposit_ops_scalar reference; the NEON-vs-scalar golden
// (sweep_kernels_test) pins the fused path against it word-for-word.

// Write-once scalar merge of ops[i .. count) into dest, gap-filling
// untouched words from `tpl`; dest words [0, next) are assumed already
// written. The per-lane clear-then-set is deposit_code's lane math verbatim
// (shift 9 - 3*(x%4), code & 0x7), accumulated in a register so the WC
// destination is written once per word.
inline void compose_merge_scalar(std::uint16_t* dest, const std::uint16_t* tpl,
                                 const PixelOp* ops, std::size_t i,
                                 std::size_t count, std::size_t next) {
  while (i < count) {
    const std::size_t w = static_cast<std::size_t>(ops[i].x) / 4;
    if (w > next) {
      std::memcpy(dest + next, tpl + next,
                  (w - next) * sizeof(std::uint16_t));
    }
    std::uint16_t word = tpl[w];
    do {
      const int shift = 9 - 3 * (ops[i].x % 4);
      const std::uint16_t mask = static_cast<std::uint16_t>(0x7 << shift);
      word = static_cast<std::uint16_t>(
          (word & ~mask) |
          (static_cast<std::uint16_t>(ops[i].code & 0x7) << shift));
      ++i;
    } while (i < count && static_cast<std::size_t>(ops[i].x) / 4 == w);
    dest[w] = word;
    next = w + 1;
  }
  if (next < static_cast<std::size_t>(kDataWordCount)) {
    std::memcpy(dest + next, tpl + next,
                (static_cast<std::size_t>(kDataWordCount) - next) *
                    sizeof(std::uint16_t));
  }
}

#if defined(__ARM_NEON) && defined(__aarch64__)

static_assert(sizeof(PixelOp) == 4 && alignof(PixelOp) == 2,
              "vld2q op unpacking assumes {u16 x, u8 code, u8 pad}");

// Packs 16 ops' code lanes (two u16x8 halves carrying `code | pad<<8`) into 4
// phase words (4 px/word, lane shift 9-3*(x%4) applied as the {512,64,8,1}
// multiply + two pairwise adds). Returns the 4 words in the low half.
inline uint16x4_t pack16_codes(uint16x8_t cp_lo, uint16x8_t cp_hi,
                               uint16x8_t lane_mul) {
  const uint16x8_t m_lo =
      vmulq_u16(vandq_u16(cp_lo, vdupq_n_u16(0x7)), lane_mul);
  const uint16x8_t m_hi =
      vmulq_u16(vandq_u16(cp_hi, vdupq_n_u16(0x7)), lane_mul);
  return vget_low_u16(
      vpaddq_u16(vpaddq_u16(m_lo, m_hi), vpaddq_u16(m_lo, m_hi)));
}

// NEON fused compose for a fully CONTIGUOUS op run (x strictly ascending
// with no gaps — the dense full-row shape; dispatcher-checked in O(1)).
// Dense, word-aligned runs pack 4 px per u16 word OR'd onto the scaffold
// base and streamed to dest; head/tail words outside the run are template
// gap-fills; an unaligned run start falls to compose_merge_scalar.
//
//   * ops are read with 2-way vld2q_u16 (x, code|pad) — a light
//     deinterleave that lands `code` straight in u16 lanes for lane_mul.
//   * the OR base is the broadcast interior scaffold word (tpl[1]); word 0
//     additionally carries kLeftEdgeControlBit (w0extra), folded back in
//     for the single group that lands on it (the word-invariance is
//     asserted at configure()).
//   * the main loop consumes 32 ops per iteration and emits one 128-bit
//     vst1q_u16 (8 words); a 16-op tail group mops up the run before the
//     scalar merge.
inline void compose_ops_dense_neon(std::uint16_t* dest,
                                   const std::uint16_t* tpl,
                                   const PixelOp* ops, std::size_t count) {
  // Lane shift 9 - 3*(x%4) as a multiplier: {512, 64, 8, 1} repeating.
  const uint16x8_t lane_mul = {512, 64, 8, 1, 512, 64, 8, 1};
  const uint16x8_t base8 = vdupq_n_u16(tpl[1]);
  const uint16x4_t base4 = vdup_n_u16(tpl[1]);
  const std::uint16_t w0extra = static_cast<std::uint16_t>(tpl[0] & ~tpl[1]);
  std::size_t i = 0;
  std::size_t next = 0;
  // Wide path: 32 dense+aligned ops -> 8 words -> one 128-bit store. The
  // dispatcher proved the whole run contiguous, so no per-group x compare
  // is needed — only the word alignment of the run start gates entry.
  if ((ops[0].x & 3) == 0) {
    for (; i + 32 <= count; i += 32) {
      const std::uint16_t x0 = ops[i].x;
      const uint16x8x2_t a =
          vld2q_u16(reinterpret_cast<const std::uint16_t*>(ops + i));
      const uint16x8x2_t b =
          vld2q_u16(reinterpret_cast<const std::uint16_t*>(ops + i + 8));
      const uint16x8x2_t c =
          vld2q_u16(reinterpret_cast<const std::uint16_t*>(ops + i + 16));
      const uint16x8x2_t d =
          vld2q_u16(reinterpret_cast<const std::uint16_t*>(ops + i + 24));
      const std::size_t w = static_cast<std::size_t>(x0) / 4;
      if (next < w) {
        std::memcpy(dest + next, tpl + next,
                    (w - next) * sizeof(std::uint16_t));
      }
      const uint16x8_t words =
          vcombine_u16(pack16_codes(a.val[1], b.val[1], lane_mul),
                       pack16_codes(c.val[1], d.val[1], lane_mul));
      uint16x8_t merged = vorrq_u16(base8, words);
      if (w == 0) {
        merged = vsetq_lane_u16(
            static_cast<std::uint16_t>(vgetq_lane_u16(merged, 0) | w0extra),
            merged, 0);
      }
      vst1q_u16(dest + w, merged);
      next = w + 8;
    }
    // Tail: a single 16-op group (one 64-bit store) before the scalar merge.
    for (; i + 16 <= count; i += 16) {
      const std::uint16_t x0 = ops[i].x;
      const uint16x8x2_t lo =
          vld2q_u16(reinterpret_cast<const std::uint16_t*>(ops + i));
      const uint16x8x2_t hi =
          vld2q_u16(reinterpret_cast<const std::uint16_t*>(ops + i + 8));
      const std::size_t w = static_cast<std::size_t>(x0) / 4;
      if (next < w) {
        std::memcpy(dest + next, tpl + next,
                    (w - next) * sizeof(std::uint16_t));
      }
      uint16x4_t merged =
          vorr_u16(base4, pack16_codes(lo.val[1], hi.val[1], lane_mul));
      if (w == 0) {
        merged = vset_lane_u16(
            static_cast<std::uint16_t>(vget_lane_u16(merged, 0) | w0extra),
            merged, 0);
      }
      vst1_u16(dest + w, merged);
      next = w + 4;
    }
  }
  compose_merge_scalar(dest, tpl, ops, i, count, next);
}

// NEON fused compose for op runs WITH GAPS (R2, retuned R3). The R1 shape
// (vectorize the dense+aligned op PREFIX, scalar-merge the remainder)
// collapsed on the real fused build: an admission's ~3% target==prev idle
// pixels scatter through every row, so the first gap lands within a few
// groups and ~97% of each row ran the scalar word-RMW merge (emit_row
// measured ~10x its dense-row cost — half the fused frame). R2 decoupled op
// layout from word packing with a column-code plane; R3 retunes both
// passes:
//   1. scatter: ops' raw code bytes land in col[x] (one byte per logical
//      column of the window; 0 = untouched). Ops carry UNIQUE ASCENDING x,
//      so a run of 16 is gap-free iff its x-span is 15 — two scalar u16
//      loads + one compare replace R2's per-half vector compare + vminvq
//      (two cross-lane reductions stalling the in-order A55 per group).
//      One vld4q_u8 lands the 16 raw code bytes in a single register
//      (val[2]) for a one-store scatter of a contiguous group; a group
//      with gaps retries per 8-lane half, then per lane — only that
//      group, never the row remainder.
//   2. pack: every window word in the 16-word-aligned span COVERED BY OPS
//      is rebuilt: word = base | c0<<9 | c1<<6 | c2<<3 | c3 (lane shift
//      9-3*(x%4)) built as two 6-bit byte pairs (hi6 = c0<<3|c1,
//      lo6 = c2<<3|c3) via vsli_u8, recombined into word bytes with one
//      more vsli + vshr and a byte zip — half the pack ALU of the R2
//      widen+vsli_u16 chain, still multiply-free for the A55. Untouched
//      columns contribute 0 and reproduce the template word exactly;
//      window words OUTSIDE the op span are template memcpys (byte-equal
//      to packing zeros, without touching the col plane), so sparse rows
//      only pay for the span they cover.
// Byte-identity: identical to memcpy-template-then-deposit because ops
// carry unique ascending x (each lane set at most once) and the scaffold's
// data-word lane bits [11:0] are all zero (asserted at configure()), making
// clear-then-set equal to OR-onto-base — the same invariant the R1 dense
// path relied on. vsli auto-truncation keeps every junk bit of the raw
// (unmasked) code bytes out of bits [11:0]: c1/c3 enter as the low 3 bits
// of a vsli insert, c0/c2 are pre-masked, and the hi6<<6 / hi6>>2 byte
// split discards the rest. force_scalar_deposit still routes the
// unmodified scalar reference; the parity goldens pin this path
// word-for-word.
inline void compose_ops_cols_neon(std::uint16_t* dest,
                                  const std::uint16_t* tpl,
                                  const PixelOp* ops, std::size_t count) {
  if (count == 0) {
    // No ops: the whole window is the template (what packing an all-zero
    // col plane produces, without the round trip).
    std::memcpy(dest, tpl,
                static_cast<std::size_t>(kDataWordCount) *
                    sizeof(std::uint16_t));
    return;
  }
  const uint16x8_t base8 = vdupq_n_u16(tpl[1]);

  // Op-covered word span, rounded to the 16-word pack granule.
  static_assert(kDataWordCount % 16 == 0, "pack loop is 16 words wide");
  const std::size_t w_first =
      (static_cast<std::size_t>(ops[0].x) / 4) & ~std::size_t{15};
  const std::size_t w_end =
      ((static_cast<std::size_t>(ops[count - 1].x) / 4) + 16) &
      ~std::size_t{15};

  // 1. Scatter codes into the column plane, 16 ops per group.
  alignas(16) std::uint8_t col[static_cast<std::size_t>(kDataWordCount) * 4];
  std::memset(col + w_first * 4, 0, (w_end - w_first) * 4);
  std::size_t i = 0;
  for (; i + 16 <= count; i += 16) {
    const unsigned x_first = ops[i].x;
    const unsigned x_last = ops[i + 15].x;
    const uint8x16x4_t g =
        vld4q_u8(reinterpret_cast<const std::uint8_t*>(ops + i));
    if (x_last - x_first == 15) {
      vst1q_u8(col + x_first, g.val[2]);
      continue;
    }
    if (ops[i + 7].x - x_first == 7) {
      vst1_u8(col + x_first, vget_low_u8(g.val[2]));
    } else {
      for (std::size_t j = i; j < i + 8; ++j) {
        col[ops[j].x] = ops[j].code;
      }
    }
    const unsigned x_mid = ops[i + 8].x;
    if (x_last - x_mid == 7) {
      vst1_u8(col + x_mid, vget_high_u8(g.val[2]));
    } else {
      for (std::size_t j = i + 8; j < i + 16; ++j) {
        col[ops[j].x] = ops[j].code;
      }
    }
  }
  for (; i < count; ++i) {
    col[ops[i].x] = ops[i].code;
  }

  // 2. Template gap-fill outside the op span, 6-bit pair pack inside it.
  // The pack's first-iteration base carries word 0's extra control bit(s)
  // (tpl[0]; interior words are the uniform tpl[1], asserted at
  // configure()) — when the span starts past word 0, the head memcpy
  // covers word 0 with the template instead.
  if (w_first != 0) {
    std::memcpy(dest, tpl, w_first * sizeof(std::uint16_t));
  }
  if (w_end < static_cast<std::size_t>(kDataWordCount)) {
    std::memcpy(dest + w_end, tpl + w_end,
                (static_cast<std::size_t>(kDataWordCount) - w_end) *
                    sizeof(std::uint16_t));
  }
  const uint8x16_t seven = vdupq_n_u8(7);
  uint16x8_t base =
      w_first == 0 ? vsetq_lane_u16(tpl[0], base8, 0) : base8;
  for (std::size_t w = w_first; w < w_end; w += 16) {
    const uint8x16x4_t c = vld4q_u8(col + w * 4);
    // hi6 = c0<<3 | c1 and lo6 = c2<<3 | c3, 6-bit pairs. vsli keeps only
    // the low 3 bits of the raw c1/c3 bytes. c0 is pre-masked: its raw
    // bits [4:3] would survive hi6>>2 into word bits [13:12] (control
    // territory). c2's overflow lands in lo6 bits [7:6], which the final
    // vsli's &0x3f discards — no mask needed.
    const uint8x16_t c0 = vandq_u8(c.val[0], seven);
    const uint8x16_t hi6 = vsliq_n_u8(c.val[1], c0, 3);
    const uint8x16_t lo6 = vsliq_n_u8(c.val[3], c.val[2], 3);
    // word = hi6<<6 | lo6 (12 bits): low byte = (hi6<<6 | lo6) & 0xff via
    // one more vsli (keeps lo6's low 6 bits), high byte = hi6 >> 2.
    const uint8x16_t w_lo_b = vsliq_n_u8(lo6, hi6, 6);
    const uint8x16_t w_hi_b = vshrq_n_u8(hi6, 2);
    const uint16x8_t words_lo =
        vreinterpretq_u16_u8(vzip1q_u8(w_lo_b, w_hi_b));
    const uint16x8_t words_hi =
        vreinterpretq_u16_u8(vzip2q_u8(w_lo_b, w_hi_b));
    vst1q_u16(dest + w, vorrq_u16(base, words_lo));
    vst1q_u16(dest + w + 8, vorrq_u16(base8, words_hi));
    base = base8;
  }
}

// NEON compose dispatcher: ops carry unique ascending x, so the whole run
// is gap-free iff it spans exactly `count` columns — one O(1) check picks
// the R1 dense path (no column-plane round trip) for contiguous rows and
// the gap-insensitive column-plane path otherwise.
inline void compose_ops_neon(std::uint16_t* dest, const std::uint16_t* tpl,
                             const PixelOp* ops, std::size_t count) {
  if (count != 0 &&
      static_cast<std::size_t>(ops[count - 1].x) - ops[0].x + 1 == count) {
    compose_ops_dense_neon(dest, tpl, ops, count);
  } else {
    compose_ops_cols_neon(dest, tpl, ops, count);
  }
}

#endif  // __ARM_NEON && __aarch64__

// Fused compose dispatcher: writes the full data window to `dest` in one
// pass (see compose_merge_scalar / compose_ops_neon).
inline void compose_ops(std::uint16_t* dest, const std::uint16_t* tpl,
                        const PixelOp* ops, std::size_t count) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  compose_ops_neon(dest, tpl, ops, count);
#else
  compose_merge_scalar(dest, tpl, ops, 0, count, 0);
#endif
}

}  // namespace

bool PhaseEmitter::configure(const PhaseEmitterConfig& config) {
  if (config.slot_count == 0 ||
      (config.mode != EmissionMode::kRowStage &&
       config.mode != EmissionMode::kShadowCopy)) {
    return false;
  }
  config_ = config;

  // Scaffold template: cached copy of init_blank_phase_frame output,
  // built exactly once; read-only afterwards.
  template_.assign(kDrmPhaseWords, 0);
  init_blank_phase_frame(template_.data());

  // Perf: cache the row-invariant data-window scaffold once. Every data row
  // (kFirstDataRow .. kTrailingControlRow-1) carries the identical 240 words
  // in [kFirstDataWord, kLastDataWord], so the hot-path memcpy source is a
  // constant; keeping it L1-resident kills the cold per-row reads into the
  // 1.24 MB template_. Sourced from the first data row's window.
  std::memcpy(data_template_.data(),
              template_row(kFirstDataRow) + kFirstDataWord,
              static_cast<std::size_t>(kDataWordCount) * sizeof(std::uint16_t));
#ifndef NDEBUG
  // Guard the row-invariance the cache relies on (byte-identical substitution
  // for template_row(drm_row) + kFirstDataWord at every emitted/reblanked
  // data row).
  for (int y = kFirstDataRow; y < kTrailingControlRow; ++y) {
    assert(std::memcmp(template_row(y) + kFirstDataWord, data_template_.data(),
                       static_cast<std::size_t>(kDataWordCount) *
                           sizeof(std::uint16_t)) == 0 &&
           "data-window template is not row-invariant");
  }
  // Guard the WORD-invariance compose_ops_neon's broadcast OR base relies on:
  // every interior data-window word (index >= 1) must carry the identical
  // scaffold control mask, so vdup_n_u16(data_template_[1]) is byte-exact for
  // w >= 1. Word 0 (kFirstDataWord) is allowed to differ (kLeftEdgeControlBit,
  // re-applied via the first pack iteration's base).
  for (int w = 1; w < kDataWordCount; ++w) {
    assert(data_template_[static_cast<std::size_t>(w)] == data_template_[1] &&
           "interior data-window template word is not uniform");
  }
  // Guard the OR-base identity compose_ops_neon relies on: the scaffold's
  // data-word pixel lanes (bits [11:0]) are all zero, so deposit_code's
  // clear-then-set equals OR-onto-base for covered lanes and untouched
  // lanes reproduce the template word exactly.
  for (int w = 0; w < kDataWordCount; ++w) {
    assert((data_template_[static_cast<std::size_t>(w)] & 0x0fff) == 0 &&
           "data-window template carries non-zero pixel lane bits");
  }
#endif

  slots_.clear();
  slots_.resize(config_.slot_count);
  for (BuildSlotState& slot : slots_) {
    slot.dirty.assign(kDirtyWords, 0);
  }
  shadows_.clear();
  if (config_.mode == EmissionMode::kShadowCopy) {
    // Cached shadow planes exist only in fallback mode (memory budget:
    // the default path carries no shadow).
    shadows_.resize(config_.slot_count);
  }
  new_dirty_.assign(kDirtyWords, 0);
  frame_open_ = false;
  stats_ = PhaseEmitterStats{};
  configured_ = true;
  return true;
}

bool PhaseEmitter::set_slot_target(std::size_t slot, std::uint16_t* words,
                                   std::size_t pitch_bytes) {
  if (!configured_ || slot >= slots_.size() || words == nullptr ||
      pitch_bytes < static_cast<std::size_t>(kDrmWidth) * sizeof(std::uint16_t) ||
      pitch_bytes % sizeof(std::uint16_t) != 0) {
    return false;
  }
  BuildSlotState& state = slots_[slot];
  state.target = words;
  state.pitch_words = pitch_bytes / sizeof(std::uint16_t);
  state.primed = false;
  state.seq = 0;
  std::fill(state.dirty.begin(), state.dirty.end(), 0);
  if (config_.mode == EmissionMode::kShadowCopy) {
    shadows_[slot].assign(kDrmPhaseWords, 0);
  }
  return true;
}

bool PhaseEmitter::blank_slot(std::size_t slot) {
  if (!configured_ || slot >= slots_.size() ||
      slots_[slot].target == nullptr || frame_open_) {
    return false;
  }
  BuildSlotState& state = slots_[slot];
  // Full-scaffold prime: the only whole-plane write on the default path
  // (cold start / HOLD slot). Sequential row stores — WC-safe.
  for (int y = 0; y < kDrmHeight; ++y) {
    std::memcpy(target_row(state, y), template_row(y),
                static_cast<std::size_t>(kDrmWidth) * sizeof(std::uint16_t));
  }
  if (config_.mode == EmissionMode::kShadowCopy) {
    std::memcpy(shadows_[slot].data(), template_.data(),
                kDrmPhaseWords * sizeof(std::uint16_t));
  }
  std::fill(state.dirty.begin(), state.dirty.end(), 0);
  state.primed = true;
  state.seq = 0;
  return true;
}

bool PhaseEmitter::begin_frame(std::size_t slot, std::uint64_t seq) {
  if (!configured_ || frame_open_ || slot >= slots_.size() ||
      slots_[slot].target == nullptr || !slots_[slot].primed) {
    return false;
  }
  frame_open_ = true;
  frame_slot_ = slot;
  frame_seq_ = seq;
  std::fill(new_dirty_.begin(), new_dirty_.end(), 0);
  return true;
}

void PhaseEmitter::emit_row(int row, const PixelOp* ops, std::size_t count) {
  emit_row_impl(row, ops, count, true);
}

void PhaseEmitter::emit_row_parallel(int row, const PixelOp *ops,
                                     std::size_t count) {
  emit_row_impl(row, ops, count, false);
}

void PhaseEmitter::finish_parallel_rows(std::uint64_t rows, std::uint64_t ops) {
  stats_.rows_emitted += rows;
  stats_.ops_deposited += ops;
}

void PhaseEmitter::emit_row_impl(int row, const PixelOp *ops, std::size_t count,
                                 bool account_stats) {
  assert(frame_open_ && "emit_row outside begin_frame/end_frame");
  if (!frame_open_) {
    return;
  }
  const int drm_row = row + kFirstDataRow;
  if (drm_row < kFirstDataRow || drm_row >= kTrailingControlRow) {
    assert(false && "emit_row outside the data window");
    return;
  }

  // Compose the FULL 480 B data window over the scaffold template (pinned
  // rule: touched rows are fully rebuilt — idle lanes return to hold code
  // 0, so stale codes cannot survive inside a rewritten row). The
  // default path fuses template-compose + deposit + window write into a
  // single write-once pass straight into the target/shadow (no staging
  // round-trip, no memcpy-then-OR); force_scalar_deposit keeps the
  // unmodified scalar reference (staging RMW) for the parity golden.
  BuildSlotState& slot = slots_[frame_slot_];
  std::uint16_t* dest = data_window_dest(slot, drm_row);
  if (config_.force_scalar_deposit) {
    std::memcpy(
        staging_.data(), data_template_.data(),
        static_cast<std::size_t>(kDataWordCount) * sizeof(std::uint16_t));
    deposit_ops_scalar(staging_.data(), ops, count);
    std::memcpy(
        dest, staging_.data(),
        static_cast<std::size_t>(kDataWordCount) * sizeof(std::uint16_t));
  } else {
    compose_ops(dest, data_template_.data(), ops, count);
  }
  if (account_stats) {
    stats_.ops_deposited += count;
  }

  set_bit_parallel(new_dirty_, drm_row);
  if (account_stats) {
    ++stats_.rows_emitted;
  }
}

std::size_t PhaseEmitter::end_frame() {
  if (!frame_open_) {
    return 0;
  }
  BuildSlotState& slot = slots_[frame_slot_];

  // reblank_stale_rows: rows dirty from this slot's PREVIOUS use
  // (kDrmBufferCount flips ago) and not written this frame are streamed
  // back to the template, making stale-code re-drive impossible by
  // construction. Re-blanking at frame start would be equivalent; doing it
  // here — after the written set is known — produces the same bytes with
  // each stale row written exactly once.
  const std::size_t reblanked_before = stats_.rows_reblanked;
  reblank_stale_rows(slot);

  if (config_.mode == EmissionMode::kShadowCopy) {
    // Fallback publication: copy every row that differs (or differed) from
    // the scaffold out of the cached shadow, full kDrmWidth words per row —
    // the row-wise body of DrmSwtconDevice::copy_phase_to_buffer.
    const std::vector<std::uint16_t>& shadow = shadows_[frame_slot_];
    for (int y = 0; y < kDrmHeight; ++y) {
      if (!test_bit(new_dirty_, y) && !test_bit(slot.dirty, y)) {
        continue;
      }
      std::memcpy(target_row(slot, y),
                  shadow.data() + static_cast<std::size_t>(y) * kDrmWidth,
                  static_cast<std::size_t>(kDrmWidth) * sizeof(std::uint16_t));
      ++stats_.rows_copied;
    }
  }

  slot.dirty = new_dirty_;
  slot.seq = frame_seq_;
  ++stats_.frames;
  frame_open_ = false;
  return stats_.rows_reblanked - reblanked_before;
}

void PhaseEmitter::reblank_stale_rows(BuildSlotState& slot) {
  for (std::size_t word = 0; word < kDirtyWords; ++word) {
    std::uint64_t stale = slot.dirty[word] & ~new_dirty_[word];
    while (stale != 0) {
      const int bit = __builtin_ctzll(stale);
      stale &= stale - 1;
      const int drm_row = static_cast<int>(word * 64) + bit;
      write_data_window(slot, drm_row, data_template_.data());
      ++stats_.rows_reblanked;
    }
  }
}

std::uint16_t* PhaseEmitter::data_window_dest(BuildSlotState& slot,
                                              int drm_row) {
  // kRowStage: sequential write-only stores into the (WC) target mapping —
  // the target is never read on the hot path.
  // kShadowCopy: same composition into the cached shadow; the target is
  // written row-wise at end_frame().
  return config_.mode == EmissionMode::kRowStage
             ? target_row(slot, drm_row) + kFirstDataWord
             : shadows_[frame_slot_].data() +
                   static_cast<std::size_t>(drm_row) * kDrmWidth +
                   kFirstDataWord;
}

void PhaseEmitter::write_data_window(BuildSlotState& slot, int drm_row,
                                     const std::uint16_t* window) {
  std::memcpy(data_window_dest(slot, drm_row), window,
              static_cast<std::size_t>(kDataWordCount) * sizeof(std::uint16_t));
}

const std::uint16_t* PhaseEmitter::shadow_words(std::size_t slot) const {
  if (config_.mode != EmissionMode::kShadowCopy || slot >= shadows_.size() ||
      shadows_[slot].empty()) {
    return nullptr;
  }
  return shadows_[slot].data();
}

bool PhaseEmitter::row_dirty(std::size_t slot, int row) const {
  const int drm_row = row + kFirstDataRow;
  if (slot >= slots_.size() || drm_row < 0 || drm_row >= kDrmHeight) {
    return false;
  }
  return test_bit(slots_[slot].dirty, drm_row);
}

std::uint64_t PhaseEmitter::slot_seq(std::size_t slot) const {
  return slot < slots_.size() ? slots_[slot].seq : 0;
}

}  // namespace pluto::swtcon
