#include "renderer/quantize.h"

#include <algorithm>
#include <type_traits>
#include <vector>

#include "renderer/kernels.h"

namespace pluto {

uint16_t rgb888_to_rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return static_cast<uint16_t>(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

void rgb888_to_rgb565(const uint8_t* src_rgb,
                      size_t src_stride_bytes,
                      uint16_t* dst_rgb565,
                      size_t dst_stride_bytes,
                      uint32_t width,
                      uint32_t height) {
  if (src_rgb == nullptr || dst_rgb565 == nullptr) {
    return;
  }
  for (uint32_t y = 0; y < height; ++y) {
    const uint8_t* src = src_rgb + y * src_stride_bytes;
    auto* dst = reinterpret_cast<uint16_t*>(
        reinterpret_cast<uint8_t*>(dst_rgb565) + y * dst_stride_bytes);
    for (uint32_t x = 0; x < width; ++x) {
      dst[x] = rgb888_to_rgb565(src[x * 3 + 0], src[x * 3 + 1], src[x * 3 + 2]);
    }
  }
}

uint8_t rgb565_luma8(uint16_t rgb565) {
  const uint8_t r5 = static_cast<uint8_t>((rgb565 >> 11) & 0x1f);
  const uint8_t g6 = static_cast<uint8_t>((rgb565 >> 5) & 0x3f);
  const uint8_t b5 = static_cast<uint8_t>(rgb565 & 0x1f);
  const uint32_t r = (static_cast<uint32_t>(r5) * 255u + 15u) / 31u;
  const uint32_t g = (static_cast<uint32_t>(g6) * 255u + 31u) / 63u;
  const uint32_t b = (static_cast<uint32_t>(b5) * 255u + 15u) / 31u;
  return static_cast<uint8_t>((54u * r + 183u * g + 19u * b + 128u) >> 8);
}

bool rgb565_has_chroma(uint16_t rgb565) {
  const uint8_t r = static_cast<uint8_t>(((rgb565 >> 11) & 0x1f) << 3);
  const uint8_t g = static_cast<uint8_t>(((rgb565 >> 5) & 0x3f) << 2);
  const uint8_t b = static_cast<uint8_t>((rgb565 & 0x1f) << 3);
  const int max_delta =
      std::max({std::abs(static_cast<int>(r) - static_cast<int>(g)),
                std::abs(static_cast<int>(r) - static_cast<int>(b)),
                std::abs(static_cast<int>(g) - static_cast<int>(b))});
  return max_delta > 12;
}

uint8_t quantize_gray4(uint8_t luma, uint8_t threshold) {
  constexpr uint32_t k_levels_minus_one = 3;
  const uint32_t scaled = static_cast<uint32_t>(luma) * k_levels_minus_one;
  uint32_t level = scaled / 255u;
  const uint32_t rem = scaled - level * 255u;
  if (rem > threshold && level < k_levels_minus_one) {
    ++level;
  }
  return static_cast<uint8_t>((level * 255u + k_levels_minus_one / 2u) /
                              k_levels_minus_one);
}

uint8_t quantize_gray16(uint8_t luma, uint8_t threshold) {
  constexpr uint32_t k_levels_minus_one = 15;
  const uint32_t scaled = static_cast<uint32_t>(luma) * k_levels_minus_one;
  uint32_t level = scaled / 255u;
  const uint32_t rem = scaled - level * 255u;
  if (rem > threshold && level < k_levels_minus_one) {
    ++level;
  }
  return static_cast<uint8_t>(level * 17u);
}

uint8_t quantize_mono(uint8_t luma, uint8_t threshold) {
  return luma > threshold ? 255 : 0;
}

namespace {

// Quantize + error tables for the Floyd-Steinberg inner loop, indexed by the
// pre-clamp value plus kBias. Built once at static init from the reference
// functions themselves, so they are byte-identical by construction:
//   q[i] = quantize_gray16(clamp(i - kBias, 0, 255), 127)
//   e[i] = clamp(i - kBias, 0, 255) - q[i]
// Domain: max |e| over all 256 lumas is 8, so an incoming error slot is
// bounded by (7+3+5+1)*8 = 128 raw, i.e. |err/16| <= 8, and the index
// luma + err/16 + kBias stays within [8, 279] c [0, 288).
struct FsTables {
  static constexpr int kBias = 16;
  static constexpr int kSize = 288;
  uint8_t q[kSize];
  int8_t e[kSize];
  int8_t div16[257];  // div16[raw + 128] = raw / 16 (trunc) for |raw| <= 128
  FsTables() {
    for (int i = 0; i < kSize; ++i) {
      const int v = std::clamp(i - kBias, 0, 255);
      q[i] = quantize_gray16(static_cast<uint8_t>(v), 127);
      e[i] = static_cast<int8_t>(v - q[i]);
    }
    for (int raw = -128; raw <= 128; ++raw) {
      div16[raw + 128] = static_cast<int8_t>(raw / 16);
    }
  }
};
const FsTables k_fs;  // namespace scope: no per-call magic-static guard

// LUT bases with the +kBias index offset folded in (drops one add per pixel).
const uint8_t* const k_fs_q = k_fs.q + FsTables::kBias;
const int8_t* const k_fs_e = k_fs.e + FsTables::kBias;
const int8_t* const k_fs_div16 = k_fs.div16 + 128;

// Wavefront cursor for one row. p is pre-offset by the row's lag within the
// group, so every active row is stepped with the same loop index x. The luma
// pre-pass stages each row's lumas IN the destination row itself (p[x] is
// read as luma, then overwritten with the quantized byte — strict
// read-before-write on the same address), so one pointer serves both sides
// and the side luma buffer plus its cache traffic disappear. Carried state:
// e1 = error(x-1), u = 5*error(x-1) + error(x-2) (exactly the sum this row's
// NEXT slot value needs — and, after the last pixel, the row's tail-slot
// value). 7*error(x-1) is recomputed from e1 with one shift-subtract instead
// of being carried (or table-loaded): three fields of state per row is what
// lets the eight-row wavefront below stay entirely in registers.
struct FsRow {
  uint8_t* p;
  int e1 = 0;
  int u = 0;
};

// One Floyd-Steinberg pixel. `incoming` is the raw (pre-division) error sum
// scattered onto this pixel by the row above: rows after the group head take
// it from a register FIFO instead of the error buffer — the row above
// finalized it exactly one shared-index iteration earlier, so it never needs
// to round-trip through memory. Returns this pixel's finalized sum
// v(x) = 3*e(x) + 5*e(x-1) + e(x-2), which the row below consumes at its
// pixel x-1 (the value the reference stored in next_error[x]).
inline int fs_step(FsRow& r, uint32_t x, int incoming) {
  const int raw = incoming + ((r.e1 << 3) - r.e1);  // + 7 * error(x-1)
  // The reference divides with int division: truncation toward zero.
  const int idx = r.p[x] + k_fs_div16[raw];
  r.p[x] = k_fs_q[idx];
  const int e = k_fs_e[idx];
  const int v = r.u + 3 * e;
  r.u = 5 * e + r.e1;
  r.e1 = e;
  return v;
}

// Compile-time-bounded unroll helper: calls f(integral_constant<int, K>) for
// K in [First, Last). Guarantees the row loops below fully scalarize (the
// fifo/v arrays must live in registers).
template <int First, int Last, typename F>
inline void fs_unroll(F&& f) {
  if constexpr (First < Last) {
    f(std::integral_constant<int, First>{});
    fs_unroll<First + 1, Last>(f);
  }
}

// One R-row wavefront group over row-local pixel indices. Each row trails
// its predecessor by two pixels — a trailing pixel only needs errors its
// predecessor row has already finalized, so the serial dependency chains of
// the R rows are independent and the core overlaps them. All active rows
// share loop index x (row k is active for x in [2k, width + 2k)), and each
// row's finalized sums reach the next row through a one-iteration register
// FIFO. The dataflow (and hence every byte) is identical to strict raster
// order. Values a row drops on the floor (v(0), v(1) of each activation
// pair, and the head values before a trailing row starts) are exactly the
// reference's never-read padding slots. Requires width >= 2 * (R - 1).
template <int R>
inline void fs_wavefront_group(FsRow (&rows)[R], const int16_t* in_a,
                               int16_t* err_out, uint32_t width) {
  static_assert(R >= 2);
  int16_t* const out_last = err_out - 2 * (R - 1);
  int fifo[R - 1] = {};  // fifo[k] = row k's v from the previous iteration
  // Staggered activation prologue: phase p turns row p on two iterations
  // after row p-1.
  fs_unroll<0, R - 1>([&](auto pc) {
    constexpr int p = pc;
    for (uint32_t x = 2 * p; x < 2 * p + 2; ++x) {
      int vnew[R - 1];
      vnew[0] = fs_step(rows[0], x, in_a[x]);
      fs_unroll<1, p + 1>(
          [&](auto kc) { vnew[kc] = fs_step(rows[kc], x, fifo[kc - 1]); });
      fs_unroll<0, p + 1>([&](auto kc) { fifo[kc] = vnew[kc]; });
    }
  });
  // Steady state: all R rows in flight. Only the LAST row stores its sums
  // (for the next group's head row) and only the HEAD row loads — interior
  // rows hand their sums down through the register FIFO.
  for (uint32_t x = 2 * (R - 1); x < width; ++x) {
    int vnew[R - 1];
    vnew[0] = fs_step(rows[0], x, in_a[x]);
    fs_unroll<1, R - 1>(
        [&](auto kc) { vnew[kc] = fs_step(rows[kc], x, fifo[kc - 1]); });
    out_last[x] = static_cast<int16_t>(fs_step(rows[R - 1], x, fifo[R - 2]));
    fs_unroll<0, R - 1>([&](auto kc) { fifo[kc] = vnew[kc]; });
  }
  // Drain epilogue: row j finishes at shared index width + 2j; from then on
  // its FIFO slot carries its tail value u = 5*e(w-1) + e(w-2), consumed by
  // the row below one iteration after it consumes v(w-1).
  fs_unroll<0, R - 1>([&](auto jc) {
    constexpr int j = jc;
    for (uint32_t x = width + 2 * j; x < width + 2 * j + 2; ++x) {
      int vnew[R - 1];
      fs_unroll<j + 1, R - 1>(
          [&](auto kc) { vnew[kc] = fs_step(rows[kc], x, fifo[kc - 1]); });
      out_last[x] = static_cast<int16_t>(fs_step(rows[R - 1], x, fifo[R - 2]));
      fifo[j] = rows[j].u;
      fs_unroll<j + 1, R - 1>([&](auto kc) { fifo[kc] = vnew[kc]; });
    }
  });
  err_out[width] = static_cast<int16_t>(rows[R - 1].u);
}

}  // namespace

void error_diffuse_rgb565_gray16_full(const uint16_t* src_rgb565,
                                      size_t src_stride_bytes,
                                      uint8_t* dst_gray8,
                                      size_t dst_stride_bytes,
                                      uint32_t width,
                                      uint32_t height) {
  if (src_rgb565 == nullptr || dst_gray8 == nullptr || width == 0 ||
      height == 0) {
    return;
  }
  // err rows: slot p+1 carries the raw (pre-division) weighted error sum the
  // row above scattered onto pixel p (3/16 + 5/16 + 1/16 contributions); the
  // in-row 7/16 term rides in registers. Only the wavefront's LAST row stores
  // its sums (for the next group's head row) and only the HEAD row loads —
  // interior rows hand their sums down through the register FIFO. Every slot
  // a later row reads is stored (not accumulated), so there is no per-row
  // zero fill, and the reference's per-pixel boundary guards vanish: they
  // only ever protected never-read padding slots. Values are bounded by
  // 16 * max|e| = 128, so int16 keeps the rows L1-resident.
  const size_t buf_len = static_cast<size_t>(width) + 2;
  std::vector<int16_t> err_storage(2 * buf_len, 0);
  int16_t* err_in = err_storage.data();
  int16_t* err_out = err_storage.data() + buf_len;
  const auto src_row = [&](uint32_t y) {
    return reinterpret_cast<const uint16_t*>(
        reinterpret_cast<const uint8_t*>(src_rgb565) +
        static_cast<size_t>(y) * src_stride_bytes);
  };
  uint32_t y = 0;
  // Runs one R-row wavefront group starting at row y. Luma has no dependence
  // on the diffused error, so it is hoisted out of the serial chain into the
  // vectorised span kernel (pinned byte-exact vs rgb565_luma8 for all 65536
  // inputs by kernels_test) — staged directly in each destination row, where
  // fs_step reads it back and overwrites it with the quantized byte.
  const auto run_group = [&]<int R>(std::integral_constant<int, R>) {
    uint8_t* const dst_a =
        dst_gray8 + static_cast<size_t>(y) * dst_stride_bytes;
    FsRow rows[R];
    fs_unroll<0, R>([&](auto kc) {
      constexpr int k = kc;
      uint8_t* const row_dst = dst_a + k * dst_stride_bytes;
      luma_from_rgb565_span(src_row(y + k), width, row_dst);
      rows[k] = FsRow{row_dst - 2 * k};
    });
    fs_wavefront_group<R>(rows, err_in + 1, err_out, width);
    std::swap(err_in, err_out);
  };
  // Widest wavefront the width admits (a group needs width >= 2 * (R - 1)),
  // then progressively narrower groups for the leftover rows. Eight rows is
  // the measured knee on both big and little cores: 3 registers of state per
  // row x 8 rows + the 7-deep FIFO still fits the GPR file, R = 9 spills.
  if (width >= 14) {
    for (; y + 8 <= height; y += 8) {
      run_group(std::integral_constant<int, 8>{});
    }
  }
  if (width >= 12) {
    for (; y + 7 <= height; y += 7) {
      run_group(std::integral_constant<int, 7>{});
    }
  }
  if (width >= 10) {
    for (; y + 6 <= height; y += 6) {
      run_group(std::integral_constant<int, 6>{});
    }
  }
  if (width >= 8) {
    for (; y + 5 <= height; y += 5) {
      run_group(std::integral_constant<int, 5>{});
    }
  }
  if (width >= 6) {
    for (; y + 4 <= height; y += 4) {
      run_group(std::integral_constant<int, 4>{});
    }
  }
  if (width >= 4) {
    for (; y + 3 <= height; y += 3) {
      run_group(std::integral_constant<int, 3>{});
    }
  }
  if (width >= 2) {
    for (; y + 2 <= height; y += 2) {
      run_group(std::integral_constant<int, 2>{});
    }
  }
  // Trailing single row, or whole width-1 frames: in-place pass — pixel x
  // reads err_in[x + 1] before storing err_in[x].
  for (; y < height; ++y) {
    uint8_t* dst_row = dst_gray8 + static_cast<size_t>(y) * dst_stride_bytes;
    luma_from_rgb565_span(src_row(y), width, dst_row);
    FsRow a{dst_row};
    for (uint32_t x = 0; x < width; ++x) {
      err_in[x] = static_cast<int16_t>(fs_step(a, x, err_in[x + 1]));
    }
    err_in[width] = static_cast<int16_t>(a.u);
  }
}

}  // namespace pluto
