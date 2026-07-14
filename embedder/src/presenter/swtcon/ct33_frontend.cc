#include "presenter/swtcon/ct33_frontend.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <limits>
#include <utility>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace pluto::swtcon {

namespace {

constexpr std::uint16_t kRedStep = 33u * 33u;
constexpr std::uint16_t kGreenStep = 33u;
constexpr std::uint16_t kBlueStep = 1u;

// Extracted byte-for-byte from Xochitl 3.27.1-1451, VMA 0x01526e78. The
// binary stores 64 rows of 72 u16 values; each row's final eight duplicate
// its first eight for SIMD wrap. Only the active 64x64 field is retained.
constexpr std::array<std::uint16_t,
                     Ct33Frontend::kSpatialPeriod *
                         Ct33Frontend::kSpatialPeriod>
    kSpatialThresholds = {
#include "presenter/swtcon/ct33_threshold_field.inc"
};

static_assert(kSpatialThresholds.size() == 4096u);

void set_error(std::string* error, const std::string& message) {
  if (error != nullptr) {
    *error = message;
  }
}

std::uint8_t expand5(std::uint16_t value) {
  const std::uint8_t v = static_cast<std::uint8_t>(value & 0x1fu);
  return static_cast<std::uint8_t>((v << 3) | (v >> 2));
}

std::uint8_t expand6(std::uint16_t value) {
  const std::uint8_t v = static_cast<std::uint8_t>(value & 0x3fu);
  return static_cast<std::uint8_t>((v << 2) | (v >> 4));
}

}  // namespace

bool Ct33Frontend::validate_blob(std::span<const std::uint8_t> blob,
                                 std::string* error) {
  if (blob.data() == nullptr) {
    set_error(error, "ct33 blob is null");
    return false;
  }
  if (blob.size() != kBlobBytes) {
    set_error(error, "ct33 blob size must be exactly 287496 bytes");
    return false;
  }

  for (std::size_t cell = 0; cell < kCubeCells; ++cell) {
    const std::uint8_t* thresholds =
        blob.data() + cell * kThresholdSlots;
    for (int slot = 1; slot < kThresholdSlots; ++slot) {
      if (thresholds[slot - 1] > thresholds[slot]) {
        set_error(error, "ct33 cell thresholds are not nondecreasing at cell " +
                             std::to_string(cell));
        return false;
      }
    }
    if (thresholds[kThresholdSlots - 1] != 255u) {
      set_error(error, "ct33 terminal threshold is not 255 at cell " +
                           std::to_string(cell));
      return false;
    }
  }

  // These endpoint invariants are what make state 0 the black rail and state
  // 7 the white rail under the 0..2039 spatial threshold field.
  for (int slot = 0; slot < kThresholdSlots; ++slot) {
    if (blob[static_cast<std::size_t>(slot)] != 255u) {
      set_error(error, "ct33 black endpoint cell is invalid");
      return false;
    }
  }
  const std::size_t white = (kCubeCells - 1u) * kThresholdSlots;
  for (int slot = 0; slot < kThresholdSlots - 1; ++slot) {
    if (blob[white + static_cast<std::size_t>(slot)] != 0u) {
      set_error(error, "ct33 white endpoint cell is invalid");
      return false;
    }
  }

  if (error != nullptr) {
    error->clear();
  }
  return true;
}

bool Ct33Frontend::configure(std::span<const std::uint8_t> blob,
                             std::string* error) {
  clear();
  if (!validate_blob(blob, error)) {
    return false;
  }

  blob_.assign(blob.begin(), blob.end());
  rgb565_interpolants_.resize(kRgb565Values * kThresholdSlots);
  rgb565_luma_.resize(kRgb565Values);
  valid_ = true;

  for (std::uint32_t packed = 0; packed < kRgb565Values; ++packed) {
    const std::uint16_t pixel = static_cast<std::uint16_t>(packed);
    const std::uint8_t r = expand5(pixel >> 11);
    const std::uint8_t g = expand6(pixel >> 5);
    const std::uint8_t b = expand5(pixel);
    interpolate_unchecked(
        r, g, b,
        rgb565_interpolants_.data() +
            static_cast<std::size_t>(packed) * kThresholdSlots);
    rgb565_luma_[packed] = luma_state(r, g, b);
  }
  return true;
}

void Ct33Frontend::clear() {
  valid_ = false;
  blob_.clear();
  rgb565_interpolants_.clear();
  rgb565_luma_.clear();
}

std::uint16_t Ct33Frontend::spatial_threshold(std::int32_t x,
                                              std::int32_t y) {
  const std::uint32_t ux = static_cast<std::uint32_t>(x) & 63u;
  const std::uint32_t uy = static_cast<std::uint32_t>(y) & 63u;
  return kSpatialThresholds[static_cast<std::size_t>(uy) * kSpatialPeriod +
                            ux];
}

Ct33Frontend::Axis Ct33Frontend::sample_axis(std::uint8_t channel,
                                             std::uint16_t cube_step,
                                             std::uint8_t* base) {
  assert(base != nullptr);
  if (channel == 255u) {
    *base = 31u;
    return Axis{8u, cube_step};
  }
  *base = static_cast<std::uint8_t>(channel >> 3);
  return Axis{static_cast<std::uint8_t>(channel & 7u), cube_step};
}

void Ct33Frontend::interpolate_unchecked(std::uint8_t r, std::uint8_t g,
                                         std::uint8_t b,
                                         std::uint16_t* out) const {
  assert(valid_);
  assert(out != nullptr);

  std::uint8_t ri = 0;
  std::uint8_t gi = 0;
  std::uint8_t bi = 0;
  std::array<Axis, 3> axes{{sample_axis(r, kRedStep, &ri),
                            sample_axis(g, kGreenStep, &gi),
                            sample_axis(b, kBlueStep, &bi)}};
  // Ties may take either order: the intervening weight is zero, so the
  // result is byte-exact independent of stable ordering.
  if (axes[0].fraction < axes[1].fraction) {
    std::swap(axes[0], axes[1]);
  }
  if (axes[1].fraction < axes[2].fraction) {
    std::swap(axes[1], axes[2]);
  }
  if (axes[0].fraction < axes[1].fraction) {
    std::swap(axes[0], axes[1]);
  }

  const std::size_t c0 =
      (static_cast<std::size_t>(ri) * kCubeEdge + gi) * kCubeEdge + bi;
  const std::size_t c1 = c0 + axes[0].cube_step;
  const std::size_t c2 = c1 + axes[1].cube_step;
  const std::size_t c3 = c2 + axes[2].cube_step;
  assert(c3 < kCubeCells);

  const std::uint16_t w0 =
      static_cast<std::uint16_t>(8u - axes[0].fraction);
  const std::uint16_t w1 = static_cast<std::uint16_t>(
      axes[0].fraction - axes[1].fraction);
  const std::uint16_t w2 = static_cast<std::uint16_t>(
      axes[1].fraction - axes[2].fraction);
  const std::uint16_t w3 = axes[2].fraction;

  const std::uint8_t* p0 = blob_.data() + c0 * kThresholdSlots;
  const std::uint8_t* p1 = blob_.data() + c1 * kThresholdSlots;
  const std::uint8_t* p2 = blob_.data() + c2 * kThresholdSlots;
  const std::uint8_t* p3 = blob_.data() + c3 * kThresholdSlots;
  for (int slot = 0; slot < kThresholdSlots; ++slot) {
    out[slot] = static_cast<std::uint16_t>(
        p0[slot] * w0 + p1[slot] * w1 + p2[slot] * w2 +
        p3[slot] * w3);
  }
}

bool Ct33Frontend::interpolate_rgb8(
    std::uint8_t r, std::uint8_t g, std::uint8_t b,
    std::array<std::uint16_t, kThresholdSlots>* out) const {
  if (!valid_ || out == nullptr) {
    return false;
  }
  interpolate_unchecked(r, g, b, out->data());
  return true;
}

std::uint8_t Ct33Frontend::count_thresholds(
    const std::uint16_t* interpolants, std::uint16_t threshold) {
  assert(interpolants != nullptr);
#if defined(__aarch64__)
  // Clang's scalar-loop vectorisation materialises a per-lane bit mask and
  // then popcounts it. We only need the number of true lanes: normalize each
  // unsigned comparison to 0/1 and reduce those eight halfwords directly.
  const uint16x8_t values = vld1q_u16(interpolants);
  const uint16x8_t selected = vcleq_u16(values, vdupq_n_u16(threshold));
  const std::uint8_t count = static_cast<std::uint8_t>(
      vaddvq_u16(vshrq_n_u16(selected, 15)));
#else
  std::uint8_t count = 0;
  for (int slot = 0; slot < kThresholdSlots; ++slot) {
    count = static_cast<std::uint8_t>(
        count + (interpolants[slot] <= threshold ? 1u : 0u));
  }
#endif
  // The validated terminal 255 produces interpolant 2040, strictly above
  // the field maximum 2039, so the production result is always 0..7.
  assert(count <= 7u);
  return count;
}

std::uint8_t Ct33Frontend::quantize_rgb8(std::uint8_t r, std::uint8_t g,
                                         std::uint8_t b, std::int32_t x,
                                         std::int32_t y) const {
  if (!valid_) {
    return 0u;
  }
  std::array<std::uint16_t, kThresholdSlots> interpolants{};
  interpolate_unchecked(r, g, b, interpolants.data());
  return count_thresholds(interpolants.data(), spatial_threshold(x, y));
}

std::uint8_t Ct33Frontend::luma_state(std::uint8_t r, std::uint8_t g,
                                      std::uint8_t b) {
  constexpr std::array<std::uint8_t, 4> kLumaPalette{{10u, 8u, 9u, 11u}};
  // Xochitl uses u16 R*77 + G*150 + B*29, truncates by 8, then takes the
  // top two bits. Since the weights sum to 256 this is exactly >>14.
  const std::uint32_t weighted = static_cast<std::uint32_t>(r) * 77u +
                                 static_cast<std::uint32_t>(g) * 150u +
                                 static_cast<std::uint32_t>(b) * 29u;
  return kLumaPalette[(weighted >> 14) & 3u];
}

std::uint8_t Ct33Frontend::encode_outer(std::uint8_t r, std::uint8_t g,
                                        std::uint8_t b,
                                        std::uint8_t ct33_state,
                                        std::uint8_t luma_select_mask) {
  const bool exact_white = r == 255u && g == 255u && b == 255u;
  if (luma_select_mask == 0u) {
    return static_cast<std::uint8_t>(ct33_state |
                                     (exact_white ? 0x80u : 0u));
  }
  const std::uint8_t luma = luma_state(r, g, b);
  std::uint8_t encoded = static_cast<std::uint8_t>(
      (luma_select_mask & luma) |
      (static_cast<std::uint8_t>(~luma_select_mask) & ct33_state));
  if (exact_white) {
    encoded = static_cast<std::uint8_t>(encoded | 0x80u);
  }
  return encoded;
}

std::uint8_t Ct33Frontend::encode_rgb8(std::uint8_t r, std::uint8_t g,
                                       std::uint8_t b, std::int32_t x,
                                       std::int32_t y,
                                       std::uint8_t luma_select_mask) const {
  if (!valid_) {
    return 0u;
  }
  return encode_outer(r, g, b, quantize_rgb8(r, g, b, x, y),
                      luma_select_mask);
}

bool Ct33Frontend::valid_region(const std::uint8_t* src,
                                std::size_t src_stride_bytes,
                                std::size_t bytes_per_pixel,
                                std::int32_t origin_x,
                                std::int32_t origin_y, std::int32_t width,
                                std::int32_t height, const std::uint8_t* out,
                                std::size_t out_stride_bytes) {
  if (width < 0 || height < 0 || origin_x < 0 || origin_y < 0) {
    return false;
  }
  if (static_cast<std::int64_t>(origin_x) + width >
          std::numeric_limits<std::int32_t>::max() ||
      static_cast<std::int64_t>(origin_y) + height >
          std::numeric_limits<std::int32_t>::max()) {
    return false;
  }
  if (width == 0 || height == 0) {
    return true;
  }
  if (src == nullptr || out == nullptr) {
    return false;
  }
  const std::size_t row_pixels = static_cast<std::size_t>(width);
  const std::size_t src_row_bytes = row_pixels * bytes_per_pixel;
  if (src_stride_bytes < src_row_bytes || out_stride_bytes < row_pixels) {
    return false;
  }
  const std::size_t row_count = static_cast<std::size_t>(height - 1);
  const std::size_t limit = std::numeric_limits<std::size_t>::max();
  return row_count == 0u ||
         (src_stride_bytes <= (limit - src_row_bytes) / row_count &&
          out_stride_bytes <= (limit - row_pixels) / row_count);
}

bool Ct33Frontend::valid_selector(const std::uint8_t* selector,
                                  std::size_t selector_stride_bytes,
                                  std::int32_t width, std::int32_t height) {
  if (selector == nullptr) {
    return selector_stride_bytes == 0u;
  }
  if (width <= 0 || height <= 0) {
    return true;
  }
  const std::size_t row_bytes = static_cast<std::size_t>(width);
  if (selector_stride_bytes < row_bytes) {
    return false;
  }
  const std::size_t row_count = static_cast<std::size_t>(height - 1);
  return row_count == 0u ||
         selector_stride_bytes <=
             (std::numeric_limits<std::size_t>::max() - row_bytes) / row_count;
}

bool Ct33Frontend::convert_rgb888(
    const std::uint8_t* src, std::size_t src_stride_bytes,
    std::int32_t origin_x, std::int32_t origin_y, std::int32_t width,
    std::int32_t height, std::uint8_t* out,
    std::size_t out_stride_bytes, const std::uint8_t* luma_select,
    std::size_t luma_select_stride_bytes) const {
  if (!valid_ ||
      !valid_region(src, src_stride_bytes, 3u, origin_x, origin_y, width,
                    height, out, out_stride_bytes) ||
      !valid_selector(luma_select, luma_select_stride_bytes, width, height)) {
    return false;
  }
  if (width == 0 || height == 0) {
    return true;
  }
  for (std::int32_t row = 0; row < height; ++row) {
    const std::uint8_t* src_row =
        src + static_cast<std::size_t>(row) * src_stride_bytes;
    std::uint8_t* out_row =
        out + static_cast<std::size_t>(row) * out_stride_bytes;
    const std::uint8_t* select_row =
        luma_select == nullptr
            ? nullptr
            : luma_select +
                  static_cast<std::size_t>(row) * luma_select_stride_bytes;
    for (std::int32_t column = 0; column < width; ++column) {
      const std::uint8_t* pixel =
          src_row + static_cast<std::size_t>(column) * 3u;
      out_row[column] = encode_rgb8(
          pixel[0], pixel[1], pixel[2], origin_x + column, origin_y + row,
          select_row == nullptr ? 0u : select_row[column]);
    }
  }
  return true;
}

bool Ct33Frontend::convert_rgb565_le(
    const std::uint8_t* src, std::size_t src_stride_bytes,
    std::int32_t origin_x, std::int32_t origin_y, std::int32_t width,
    std::int32_t height, std::uint8_t* out,
    std::size_t out_stride_bytes, const std::uint8_t* luma_select,
    std::size_t luma_select_stride_bytes) const {
  if (!valid_ ||
      !valid_region(src, src_stride_bytes, 2u, origin_x, origin_y, width,
                    height, out, out_stride_bytes) ||
      !valid_selector(luma_select, luma_select_stride_bytes, width, height)) {
    return false;
  }
  if (width == 0 || height == 0) {
    return true;
  }
  const auto convert_ct33_row = [&](const std::uint8_t* src_row,
                                    std::uint8_t* out_row,
                                    std::int32_t absolute_y) {
    const std::uint16_t* const threshold_row =
        kSpatialThresholds.data() +
        (static_cast<std::uint32_t>(absolute_y) & 63u) * kSpatialPeriod;
    std::int32_t column = 0;
    std::int32_t threshold_x =
        static_cast<std::int32_t>(static_cast<std::uint32_t>(origin_x) & 63u);
    while (column < width) {
      const std::int32_t run =
          std::min(width - column, kSpatialPeriod - threshold_x);
      for (std::int32_t index = 0; index < run; ++index) {
        const std::int32_t x = column + index;
        const std::uint8_t* bytes =
            src_row + static_cast<std::size_t>(x) * 2u;
        const std::uint16_t pixel = static_cast<std::uint16_t>(
            bytes[0] | (static_cast<std::uint16_t>(bytes[1]) << 8));
        const std::uint16_t* interpolants =
            rgb565_interpolants_.data() +
            static_cast<std::size_t>(pixel) * kThresholdSlots;
        const std::uint8_t state = count_thresholds(
            interpolants, threshold_row[threshold_x + index]);
        const std::uint8_t white_marker = static_cast<std::uint8_t>(
            static_cast<std::uint8_t>(pixel == 0xffffu) << 7);
        out_row[x] = static_cast<std::uint8_t>(state | white_marker);
      }
      column += run;
      threshold_x = 0;
    }
  };
  // Keep the overwhelmingly common no-selector path branch-free inside the
  // pixel loop. This preserves compiler vectorization of the eight threshold
  // comparisons; the exact-white marker is a branchless predicate.
  if (luma_select == nullptr) {
    for (std::int32_t row = 0; row < height; ++row) {
      const std::uint8_t* src_row =
          src + static_cast<std::size_t>(row) * src_stride_bytes;
      std::uint8_t* out_row =
          out + static_cast<std::size_t>(row) * out_stride_bytes;
      convert_ct33_row(src_row, out_row, origin_y + row);
    }
    return true;
  }

  for (std::int32_t row = 0; row < height; ++row) {
    const std::uint8_t* src_row =
        src + static_cast<std::size_t>(row) * src_stride_bytes;
    std::uint8_t* out_row =
        out + static_cast<std::size_t>(row) * out_stride_bytes;
    const std::uint8_t* select_row =
        luma_select +
        static_cast<std::size_t>(row) * luma_select_stride_bytes;
    // A ct33-first row benefits from walking the repeating threshold field in
    // contiguous runs. Preserve the simpler luma-first loop below for rows
    // that begin selected, including the all-0xff production case.
    if (select_row[0] != 0xffu) {
      const std::uint16_t* const threshold_row =
          kSpatialThresholds.data() +
          (static_cast<std::uint32_t>(origin_y + row) & 63u) * kSpatialPeriod;
      std::int32_t column = 0;
      std::int32_t threshold_x = static_cast<std::int32_t>(
          static_cast<std::uint32_t>(origin_x) & 63u);
      while (column < width) {
        const std::int32_t run =
            std::min(width - column, kSpatialPeriod - threshold_x);
        for (std::int32_t index = 0; index < run; ++index) {
          const std::int32_t x = column + index;
          const std::uint8_t* bytes =
              src_row + static_cast<std::size_t>(x) * 2u;
          const std::uint16_t pixel = static_cast<std::uint16_t>(
              bytes[0] | (static_cast<std::uint16_t>(bytes[1]) << 8));
          const std::uint8_t select = select_row[x];
          std::uint8_t encoded = 0;
          if (select == 0xffu) {
            encoded = rgb565_luma_[pixel];
          } else {
            const std::uint16_t* interpolants =
                rgb565_interpolants_.data() +
                static_cast<std::size_t>(pixel) * kThresholdSlots;
            const std::uint8_t ct33_state = count_thresholds(
                interpolants, threshold_row[threshold_x + index]);
            if (select == 0u) {
              encoded = ct33_state;
            } else {
              const std::uint8_t luma = rgb565_luma_[pixel];
              encoded = static_cast<std::uint8_t>(
                  (select & luma) |
                  (static_cast<std::uint8_t>(~select) & ct33_state));
            }
          }
          const std::uint8_t white_marker = static_cast<std::uint8_t>(
              static_cast<std::uint8_t>(pixel == 0xffffu) << 7);
          out_row[x] = static_cast<std::uint8_t>(encoded | white_marker);
        }
        column += run;
        threshold_x = 0;
      }
      continue;
    }
    for (std::int32_t column = 0; column < width; ++column) {
      const std::uint8_t* bytes =
          src_row + static_cast<std::size_t>(column) * 2u;
      const std::uint16_t pixel = static_cast<std::uint16_t>(
          bytes[0] | (static_cast<std::uint16_t>(bytes[1]) << 8));
      const std::uint8_t select = select_row[column];
      std::uint8_t encoded = 0;
      if (select == 0xffu) {
        // Selector-16 resolves production masks to whole-byte 0xff/0x00.
        // A fully selected pixel discards every ct33 bit, so avoid the random
        // 1 MB interpolant-table read and eight comparisons entirely.
        encoded = rgb565_luma_[pixel];
      } else {
        const std::uint16_t* interpolants =
            rgb565_interpolants_.data() +
            static_cast<std::size_t>(pixel) * kThresholdSlots;
        const std::uint8_t ct33_state = count_thresholds(
            interpolants,
            spatial_threshold(origin_x + column, origin_y + row));
        if (select == 0u) {
          // The complementary production case needs no luma-table read.
          encoded = ct33_state;
        } else {
          const std::uint8_t luma = rgb565_luma_[pixel];
          encoded = static_cast<std::uint8_t>(
              (select & luma) |
              (static_cast<std::uint8_t>(~select) & ct33_state));
        }
      }
      const std::uint8_t white_marker = static_cast<std::uint8_t>(
          static_cast<std::uint8_t>(pixel == 0xffffu) << 7);
      out_row[column] = static_cast<std::uint8_t>(encoded | white_marker);
    }
  }
  return true;
}

}  // namespace pluto::swtcon
