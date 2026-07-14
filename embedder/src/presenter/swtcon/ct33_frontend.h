#ifndef PLUTO_PRESENTER_SWTCON_CT33_FRONTEND_H_
#define PLUTO_PRESENTER_SWTCON_CT33_FRONTEND_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace pluto::swtcon {

// Exact, statically closed first stage of Xochitl 3.27's Gallery-3 colour
// pipeline:
//
//   RGB -> tetrahedral interpolation in the 33^3 x 8 ct33 cube
//       -> compare against the position-keyed 64x64 threshold field
//       -> 3-bit colour state (0..7)
//       -> optional luma-selector substitution + white marker byte
//
// This class deliberately stops at that byte plane. The stock active A/B
// history mapper (0x004814a0) is not yet reproduced, so Ct33Frontend output
// MUST NOT be used as a waveform target or enable a colour presenter path.
//
// configure() owns a copy of the validated blob and precomputes all 65,536
// RGB565 interpolants. All conversion methods are allocation-free after a
// successful configure(). The class is single-owner and conversions are safe
// to call concurrently while no thread calls configure()/clear().
class Ct33Frontend final {
 public:
  static constexpr int kCubeEdge = 33;
  static constexpr int kThresholdSlots = 8;
  static constexpr std::size_t kCubeCells =
      static_cast<std::size_t>(kCubeEdge) * kCubeEdge * kCubeEdge;
  static constexpr std::size_t kBlobBytes =
      kCubeCells * kThresholdSlots;
  static constexpr int kSpatialPeriod = 64;
  static constexpr std::size_t kRgb565Values = 1u << 16;

  Ct33Frontend() = default;
  Ct33Frontend(const Ct33Frontend&) = delete;
  Ct33Frontend& operator=(const Ct33Frontend&) = delete;
  Ct33Frontend(Ct33Frontend&&) = delete;
  Ct33Frontend& operator=(Ct33Frontend&&) = delete;

  // Validates and copies exactly one raw ct33_*.bin. Validation requires the
  // exact 33^3*8 size, nondecreasing thresholds in every cell, a 255 terminal
  // threshold in every cell, and the proven black/white endpoint cells.
  // A failed configure leaves the object invalid.
  bool configure(std::span<const std::uint8_t> blob, std::string* error);
  void clear();
  bool valid() const { return valid_; }

  static bool validate_blob(std::span<const std::uint8_t> blob,
                            std::string* error);

  // The exact active 64x64 Xochitl 3.27 threshold field. Coordinates repeat
  // modulo 64. This standalone helper accepts any signed coordinates and uses
  // two's-complement modulo, matching the kernel's bit masks.
  static std::uint16_t spatial_threshold(std::int32_t x, std::int32_t y);

  // Eight unnormalised tetrahedral interpolants in [0, 2040]. Their weights
  // sum to 8; there is intentionally no division or rounding. Returns false
  // if this object is not configured or out is null.
  bool interpolate_rgb8(
      std::uint8_t r, std::uint8_t g, std::uint8_t b,
      std::array<std::uint16_t, kThresholdSlots>* out) const;

  // Quantize one RGB value at absolute panel coordinates to a ct33 state.
  // Returns 0 when called before a successful configure().
  std::uint8_t quantize_rgb8(std::uint8_t r, std::uint8_t g, std::uint8_t b,
                             std::int32_t x, std::int32_t y) const;

  // Exact outer 0xb65060 byte encoding. luma_select_mask is a bit-select
  // byte (normally 0x00 or 0xff): selected bits come from the proven 2-bit
  // luma palette {10,8,9,11}, unselected bits from the ct33 state. Exact RGB
  // white then sets marker bit 0x80. Returns 0 before configure().
  std::uint8_t encode_rgb8(std::uint8_t r, std::uint8_t g, std::uint8_t b,
                           std::int32_t x, std::int32_t y,
                           std::uint8_t luma_select_mask = 0u) const;

  // Convert tightly/interleaved RGB888 (byte order R,G,B) or little-endian
  // RGB565 regions. src/out point at the region's first pixel; origin_x/y are
  // its absolute panel coordinates and therefore key the spatial threshold.
  // Strides are whole-surface byte strides and must cover one region row.
  // Optional luma_select is a one-byte-per-pixel bit-select plane; nullptr
  // means all-zero selection and requires a zero selector stride. Empty
  // regions are accepted. Source, selector, and destination must not overlap.
  bool convert_rgb888(const std::uint8_t* src,
                      std::size_t src_stride_bytes, std::int32_t origin_x,
                      std::int32_t origin_y, std::int32_t width,
                      std::int32_t height, std::uint8_t* out,
                      std::size_t out_stride_bytes,
                      const std::uint8_t* luma_select = nullptr,
                      std::size_t luma_select_stride_bytes = 0u) const;
  bool convert_rgb565_le(const std::uint8_t* src,
                         std::size_t src_stride_bytes,
                         std::int32_t origin_x, std::int32_t origin_y,
                         std::int32_t width, std::int32_t height,
                         std::uint8_t* out,
                         std::size_t out_stride_bytes,
                         const std::uint8_t* luma_select = nullptr,
                         std::size_t luma_select_stride_bytes = 0u) const;

  // Stable accounting for deployment/bench evidence.
  std::size_t owned_bytes() const {
    return blob_.size() * sizeof(blob_[0]) +
           rgb565_interpolants_.size() * sizeof(rgb565_interpolants_[0]) +
           rgb565_luma_.size() * sizeof(rgb565_luma_[0]);
  }

 private:
  struct Axis {
    std::uint8_t fraction = 0;
    std::uint16_t cube_step = 0;
  };

  static Axis sample_axis(std::uint8_t channel, std::uint16_t cube_step,
                          std::uint8_t* base);
  void interpolate_unchecked(
      std::uint8_t r, std::uint8_t g, std::uint8_t b,
      std::uint16_t* out) const;
  static std::uint8_t count_thresholds(const std::uint16_t* interpolants,
                                       std::uint16_t threshold);
  static std::uint8_t luma_state(std::uint8_t r, std::uint8_t g,
                                 std::uint8_t b);
  static std::uint8_t encode_outer(std::uint8_t r, std::uint8_t g,
                                   std::uint8_t b, std::uint8_t ct33_state,
                                   std::uint8_t luma_select_mask);
  static bool valid_region(const std::uint8_t* src,
                           std::size_t src_stride_bytes,
                           std::size_t bytes_per_pixel,
                           std::int32_t origin_x, std::int32_t origin_y,
                           std::int32_t width, std::int32_t height,
                           const std::uint8_t* out,
                           std::size_t out_stride_bytes);
  static bool valid_selector(const std::uint8_t* selector,
                             std::size_t selector_stride_bytes,
                             std::int32_t width, std::int32_t height);

  std::vector<std::uint8_t> blob_;
  // [rgb565][slot], unnormalised uint16 interpolants.
  std::vector<std::uint16_t> rgb565_interpolants_;
  // Exact {10,8,9,11} luma state for each replicated RGB565 value.
  std::vector<std::uint8_t> rgb565_luma_;
  bool valid_ = false;
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_CT33_FRONTEND_H_
