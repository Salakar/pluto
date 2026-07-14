#include "renderer/abi_bridge.h"

#include <cstring>

#include "renderer/gallery3.h"
#include "renderer/rect_utils.h"
#include "renderer/kernels.h"

#if defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace pluto {
namespace {

size_t format_bytes_per_pixel(PlutoPixelFormat format) {
  switch (format) {
    case kPlutoPixelFormatRgb565:
      return 2;
    case kPlutoPixelFormatGray8:
      return 1;
    case kPlutoPixelFormatXrgb8888:
      return 4;
  }
  return 0;
}

bool target_format_supported(PlutoPixelFormat format) {
  return format == kPlutoPixelFormatRgb565 ||
         format == kPlutoPixelFormatGray8;
}

bool valid_rotation(uint32_t rotation) {
  return rotation == 0 || rotation == 90 || rotation == 180 ||
         rotation == 270;
}

PlutoRect rotate_rect(const PlutoRect& rect, uint32_t logical_width,
                        uint32_t logical_height, uint32_t rotation) {
  switch (rotation) {
    case 90:
      return PlutoRect{static_cast<int32_t>(logical_height) - rect.y -
                             rect.height,
                         rect.x, rect.height, rect.width};
    case 180:
      return PlutoRect{static_cast<int32_t>(logical_width) - rect.x -
                             rect.width,
                         static_cast<int32_t>(logical_height) - rect.y -
                             rect.height,
                         rect.width, rect.height};
    case 270:
      return PlutoRect{rect.y,
                         static_cast<int32_t>(logical_width) - rect.x -
                             rect.width,
                         rect.height, rect.width};
    default:
      return rect;
  }
}

#if defined(__ARM_NEON) && defined(__aarch64__)
// 32-entry level5 -> RGB565 palette, split into low/high byte planes so a
// 16-pixel lookup is two vqtbl2q + one interleaving vst2q (the generic span
// kernel widens to u16 and re-packs the 565 fields per vector instead).
// Built ONCE by running the frozen scalar reference kernel itself
// (levels_to_rgb565_span_scalar) over the 32 level bytes, so palette bytes
// are the reference bytes by construction. Indices are clamped to 31 with
// vminq_u8 — the same clamp level5_to_gray8 applies — so sentinel/garbage
// ledger bytes (e.g. kInvalidLevel5 = 0xff) dequantize identically.
struct Level5Rgb565Palette {
  uint8x16x2_t lo;
  uint8x16x2_t hi;
};

Level5Rgb565Palette build_level5_rgb565_palette() {
  uint8_t levels[32];
  uint16_t rgb565[32];
  for (uint32_t i = 0; i < 32; ++i) {
    levels[i] = static_cast<uint8_t>(i);
  }
  levels_to_rgb565_span_scalar(levels, 32, rgb565);
  uint8_t lo[32];
  uint8_t hi[32];
  for (uint32_t i = 0; i < 32; ++i) {
    lo[i] = static_cast<uint8_t>(rgb565[i] & 0xffu);
    hi[i] = static_cast<uint8_t>(rgb565[i] >> 8u);
  }
  Level5Rgb565Palette palette;
  palette.lo = uint8x16x2_t{{vld1q_u8(lo), vld1q_u8(lo + 16)}};
  palette.hi = uint8x16x2_t{{vld1q_u8(hi), vld1q_u8(hi + 16)}};
  return palette;
}

// Byte-identical fast twin of levels_to_rgb565_span_scalar (proven by the
// exhaustive golden in test/renderer/abi_bridge_convert_test.cc). Spans of
// >= 16 px finish with one overlapped vector over the last 16 inputs: the
// overlapping lanes rewrite bytes already written by the previous block with
// the same values (the conversion is a pure function of the input byte), so
// the output stays byte-identical with no scalar tail.
void levels_to_rgb565_span_bridge(const Level5Rgb565Palette& palette,
                                  const uint8_t* lvl5, size_t n,
                                  uint16_t* out) {
  if (n < 16) {
    levels_to_rgb565_span_scalar(lvl5, n, out);
    return;
  }
  auto* out_bytes = reinterpret_cast<uint8_t*>(out);
  const uint8x16_t max_index = vdupq_n_u8(31);
  size_t i = 0;
  for (; i + 16 <= n; i += 16) {
    const uint8x16_t idx = vminq_u8(vld1q_u8(lvl5 + i), max_index);
    uint8x16x2_t px;
    px.val[0] = vqtbl2q_u8(palette.lo, idx);
    px.val[1] = vqtbl2q_u8(palette.hi, idx);
    vst2q_u8(out_bytes + 2u * i, px);
  }
  if (i < n) {
    const size_t last = n - 16;
    const uint8x16_t idx = vminq_u8(vld1q_u8(lvl5 + last), max_index);
    uint8x16x2_t px;
    px.val[0] = vqtbl2q_u8(palette.lo, idx);
    px.val[1] = vqtbl2q_u8(palette.hi, idx);
    vst2q_u8(out_bytes + 2u * last, px);
  }
}
#endif  // __ARM_NEON && __aarch64__

}  // namespace

void AbiPresentBridge::configure(const AbiPresentBridgeConfig& config) {
  config_ = config;
  valid_ = config_.width > 0 && config_.height > 0 &&
           target_format_supported(config_.target_format) &&
           valid_rotation(config_.rotation);
  if (!valid_) {
    target_stride_ = 0;
    present_frame_.clear();
    panel_frame_.clear();
    panel_damage_.clear();
    return;
  }
  target_stride_ = static_cast<size_t>(config_.width) *
                   format_bytes_per_pixel(config_.target_format);
  // White, not black: regions never touched by a damage rect should read as
  // undeveloped paper in full-surface snapshots (0xff bytes are white in
  // both RGB565 and Gray8) — pinned contract.
  present_frame_.assign(target_stride_ * config_.height, 0xff);
  panel_width_ = config_.rotation == 90 || config_.rotation == 270
                     ? config_.height
                     : config_.width;
  panel_height_ = config_.rotation == 90 || config_.rotation == 270
                      ? config_.width
                      : config_.height;
  panel_stride_ = static_cast<size_t>(panel_width_) *
                  format_bytes_per_pixel(config_.target_format);
  panel_frame_.assign(panel_stride_ * panel_height_, 0xff);
  panel_damage_.clear();
  panel_damage_.reserve(256);
}

PlutoPresentRequest AbiPresentBridge::prepare(const PlutoPresentRequest &in,
                                                const FrameLedger &ledger) {
  if (!valid_ || in.damage == nullptr || in.damage_count == 0 ||
      !ledger.valid() || ledger.width() != config_.width ||
      ledger.height() != config_.height) {
    return in;
  }

  // Settled color develops on glass only via a full-class update; everything
  // below full presents chroma-free settled levels ("color is a settled
  // state"). Both color paths read the engine-true RGB565 mirror the caller
  // maintains for them.
  const bool settled_color =
      config_.panel_is_color && in.refresh_class == kPlutoRefreshFull &&
      config_.source_format == kPlutoPixelFormatRgb565 &&
      config_.target_format == kPlutoPixelFormatRgb565 &&
      in.surface.pixels != nullptr &&
      in.surface.format == kPlutoPixelFormatRgb565 &&
      in.surface.width == static_cast<int32_t>(config_.width) &&
      in.surface.height == static_cast<int32_t>(config_.height);
  const bool delegate_color = settled_color && config_.backend_quantizes_color;
  const bool reset_black =
      (in.flags & kPlutoPresentFlagPixelResetBlack) != 0;
  const bool reset_white =
      (in.flags & kPlutoPresentFlagPixelResetWhite) != 0;
  const bool pixel_reset = reset_black || reset_white;

  for (size_t i = 0; i < in.damage_count; ++i) {
    const PlutoRect rect =
        rect_clip(in.damage[i], static_cast<int32_t>(config_.width),
                  static_cast<int32_t>(config_.height));
    if (rect_is_empty(rect)) {
      continue;
    }
    if (pixel_reset) {
      fill_rect_solid(rect, reset_white);
    } else if (delegate_color) {
      copy_rect_from_mirror(in.surface, rect);
    } else if (settled_color) {
      convert_rect_gallery3(in.surface, rect);
    } else {
      convert_rect_levels(ledger, rect);
    }
  }

  PlutoPresentRequest out = in;
  out.surface = PlutoSurface{present_frame_.data(), target_stride_,
                               static_cast<int32_t>(config_.width),
                               static_cast<int32_t>(config_.height),
                               config_.target_format};
  if (config_.rotation != 0) {
    const size_t bpp = format_bytes_per_pixel(config_.target_format);
    panel_damage_.clear();
    for (size_t i = 0; i < in.damage_count; ++i) {
      const PlutoRect rect =
          rect_clip(in.damage[i], static_cast<int32_t>(config_.width),
                    static_cast<int32_t>(config_.height));
      if (rect_is_empty(rect)) {
        continue;
      }
      for (int32_t y = rect.y; y < rect.y + rect.height; ++y) {
        for (int32_t x = rect.x; x < rect.x + rect.width; ++x) {
          int32_t panel_x = x;
          int32_t panel_y = y;
          switch (config_.rotation) {
            case 90:
              panel_x = static_cast<int32_t>(config_.height) - 1 - y;
              panel_y = x;
              break;
            case 180:
              panel_x = static_cast<int32_t>(config_.width) - 1 - x;
              panel_y = static_cast<int32_t>(config_.height) - 1 - y;
              break;
            case 270:
              panel_x = y;
              panel_y = static_cast<int32_t>(config_.width) - 1 - x;
              break;
          }
          std::memcpy(panel_frame_.data() +
                          static_cast<size_t>(panel_y) * panel_stride_ +
                          static_cast<size_t>(panel_x) * bpp,
                      present_frame_.data() +
                          static_cast<size_t>(y) * target_stride_ +
                          static_cast<size_t>(x) * bpp,
                      bpp);
        }
      }
      panel_damage_.push_back(rotate_rect(
          rect, config_.width, config_.height, config_.rotation));
    }
    out.surface = PlutoSurface{panel_frame_.data(), panel_stride_,
                                 static_cast<int32_t>(panel_width_),
                                 static_cast<int32_t>(panel_height_),
                                 config_.target_format};
    out.damage = panel_damage_.data();
    out.damage_count = panel_damage_.size();
  }
  if (pixel_reset || !delegate_color) {
    out.flags |= kPlutoPresentFlagPreDithered;
  }
  return out;
}

void AbiPresentBridge::copy_rect_from_mirror(const PlutoSurface& src,
                                             const PlutoRect& rect) {
  const size_t bpp = format_bytes_per_pixel(config_.source_format);
  const size_t row_bytes = static_cast<size_t>(rect.width) * bpp;
  for (int32_t y = 0; y < rect.height; ++y) {
    const size_t src_offset =
        static_cast<size_t>(rect.y + y) * src.stride_bytes +
        static_cast<size_t>(rect.x) * bpp;
    const size_t dst_offset =
        static_cast<size_t>(rect.y + y) * target_stride_ +
        static_cast<size_t>(rect.x) * bpp;
    std::memcpy(present_frame_.data() + dst_offset, src.pixels + src_offset,
                row_bytes);
  }
}

void AbiPresentBridge::fill_rect_solid(const PlutoRect& rect, bool white) {
  const size_t bpp = format_bytes_per_pixel(config_.target_format);
  const size_t row_bytes = static_cast<size_t>(rect.width) * bpp;
  const uint8_t value = white ? 0xffu : 0x00u;
  for (int32_t y = 0; y < rect.height; ++y) {
    const size_t offset = static_cast<size_t>(rect.y + y) * target_stride_ +
                          static_cast<size_t>(rect.x) * bpp;
    std::memset(present_frame_.data() + offset, value, row_bytes);
  }
}

void AbiPresentBridge::convert_rect_gallery3(const PlutoSurface& src,
                                             const PlutoRect& rect) {
  // Position-keyed palette mapping (renderer/gallery3.h), so color-settle
  // bytes are a pure function of (pixel value, absolute coordinates) and
  // stay rect-local deterministic for the same mirror content.
  const Gallery3Palette& palette = Gallery3Palette::instance();
  for (int32_t y = 0; y < rect.height; ++y) {
    const int32_t absolute_y = rect.y + y;
    const auto* src_row = reinterpret_cast<const uint16_t*>(
        src.pixels + static_cast<size_t>(absolute_y) * src.stride_bytes);
    auto* dst_row = reinterpret_cast<uint16_t*>(
        present_frame_.data() +
        static_cast<size_t>(absolute_y) * target_stride_);
    for (int32_t x = 0; x < rect.width; ++x) {
      const int32_t absolute_x = rect.x + x;
      dst_row[absolute_x] =
          palette.map_rgb565(src_row[absolute_x], absolute_x, absolute_y);
    }
  }
}

void AbiPresentBridge::convert_rect_levels(const FrameLedger& ledger,
                                           const PlutoRect& rect) {
  const uint8_t* l_cur = ledger.l_cur();
  const size_t stride = ledger.stride();
  const size_t width = static_cast<size_t>(rect.width);
  uint8_t* const base = present_frame_.data();
  const size_t rx = static_cast<size_t>(rect.x);
  // Hoist the format decision out of the per-row loop so the branch and the
  // config_ read do not repeat for every scanline of the rect.
  if (config_.target_format == kPlutoPixelFormatGray8) {
    for (int32_t y = 0; y < rect.height; ++y) {
      const size_t absolute_y = static_cast<size_t>(rect.y + y);
      levels_to_gray8_span(l_cur + absolute_y * stride + rx, width,
                           base + absolute_y * target_stride_ + rx);
    }
  } else {
#if defined(__ARM_NEON) && defined(__aarch64__)
    // Palette lookup fast path; built once, fetched once per rect (no
    // per-row magic-static guard).
    static const Level5Rgb565Palette palette = build_level5_rgb565_palette();
    for (int32_t y = 0; y < rect.height; ++y) {
      const size_t absolute_y = static_cast<size_t>(rect.y + y);
      levels_to_rgb565_span_bridge(
          palette, l_cur + absolute_y * stride + rx, width,
          reinterpret_cast<uint16_t*>(base + absolute_y * target_stride_) + rx);
    }
#else
    for (int32_t y = 0; y < rect.height; ++y) {
      const size_t absolute_y = static_cast<size_t>(rect.y + y);
      levels_to_rgb565_span(
          l_cur + absolute_y * stride + rx, width,
          reinterpret_cast<uint16_t*>(base + absolute_y * target_stride_) + rx);
    }
#endif
  }
}

}  // namespace pluto
