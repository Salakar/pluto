#ifndef PLUTO_PRESENTER_SWTCON_XOCHITL_COLOR_PIPELINE_H_
#define PLUTO_PRESENTER_SWTCON_XOCHITL_COLOR_PIPELINE_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "presenter/swtcon/ct33_frontend.h"
#include "presenter/swtcon/xochitl_history_state.h"
#include "presenter/swtcon/xochitl_selector16.h"

namespace pluto::swtcon {

class WaveformTable;

// Producer-side, fail-closed front half of the recovered Xochitl Gallery-3
// pipeline. It snapshots a complete RGB565 app surface synchronously and
// publishes only a compact immutable raw operation. Persistent A/B mapping is
// deliberately deferred to prepare() on the engine thread: an overlapping
// predecessor must be terminal-scan-confirmed before its successor snapshots
// history.
class XochitlColorPipeline final {
public:
  using Mode = XochitlHistoryState::Mode;
  using InclusiveRect = XochitlHistoryState::InclusiveRect;
  using PreparedOperation = XochitlHistoryState::PreparedOperation;
  using PrepareResult = XochitlHistoryState::PrepareResult;

  static constexpr std::size_t kInstalledTemperatureBins = 9;

  enum class BuildError : std::uint8_t {
    kNone = 0,
    kNotConfigured,
    kInvalidSurface,
    kInvalidGeometry,
    kInvalidMode,
    kSelectorFailed,
    kConversionFailed,
    kStaleConfiguration,
    kInvalidMask,
  };

  class ImmutableOperation final {
  public:
    Mode mode() const { return mode_; }
    InclusiveRect requested() const { return requested_; }
    InclusiveRect execution() const { return execution_; }
    std::int32_t width() const { return width_; }
    std::int32_t height() const { return height_; }
    int temperature_bin() const { return temperature_bin_; }
    float temperature_celsius() const { return temperature_celsius_; }
    std::span<const std::uint8_t> raw() const { return raw_; }
    std::size_t raw_stride() const { return static_cast<std::size_t>(width_); }
    // Empty is the dense legacy representation. A non-empty mask is tight to
    // execution() and contains canonical 0/1 bytes.
    std::span<const std::uint8_t> lane_mask() const { return lane_mask_; }
    bool masked() const { return !lane_mask_.empty(); }
    std::size_t owned_bytes() const {
      return raw_.capacity() + lane_mask_.capacity();
    }

  private:
    friend class XochitlColorPipeline;
    ImmutableOperation(std::uint64_t configuration_generation, Mode mode,
                       InclusiveRect requested, InclusiveRect execution,
                       std::int32_t width, std::int32_t height,
                       int temperature_bin, float temperature_celsius,
                       std::vector<std::uint8_t> raw,
                       std::vector<std::uint8_t> lane_mask);

    std::uint64_t configuration_generation_ = 0;
    Mode mode_ = Mode::kFast;
    InclusiveRect requested_{};
    InclusiveRect execution_{};
    std::int32_t width_ = 0;
    std::int32_t height_ = 0;
    int temperature_bin_ = 0;
    float temperature_celsius_ = 25.0f;
    std::vector<std::uint8_t> raw_;
    std::vector<std::uint8_t> lane_mask_;
  };

  struct BuildResult {
    BuildError error = BuildError::kNone;
    std::shared_ptr<const ImmutableOperation> operation;

    explicit operator bool() const {
      return error == BuildError::kNone && operation != nullptr;
    }
  };

  XochitlColorPipeline() = default;
  XochitlColorPipeline(const XochitlColorPipeline &) = delete;
  XochitlColorPipeline &operator=(const XochitlColorPipeline &) = delete;

  // All four blobs are mandatory even when an individual operation selects
  // only one. Every required mode/bin waveform and exact legacy delta table
  // must validate before color_capable() can become true.
  bool
  configure(const WaveformTable *waveform,
            const std::map<std::string, std::vector<std::uint8_t>> &ct33_blobs,
            std::string *error);
  void clear();
  bool color_capable() const { return color_capable_; }

  // `surface` is the complete authoritative 954x1696 RGB565 little-endian
  // app surface. No caller pointer survives this call. Right/bottom vector
  // guards replicate the nearest logical edge and are retained only in the
  // compact raw payload.
  BuildResult preprocess_rgb565(std::span<const std::uint8_t> surface,
                                std::size_t surface_stride,
                                InclusiveRect update, Mode mode,
                                int temperature_bin, float temperature_celsius,
                                std::span<const std::uint8_t> lane_mask = {},
                                std::size_t lane_mask_stride = 0);

  // Engine-thread operation. Does not commit history.
  PrepareResult prepare(const ImmutableOperation &operation);

  bool initialize_white_history() {
    return color_capable_ && history_.initialize_cold_clear(30);
  }
  void invalidate_history() { history_.invalidate(); }
  XochitlHistoryState &history() { return history_; }
  const XochitlHistoryState &history() const { return history_; }

  std::size_t owned_bytes() const;

private:
  using Delta = std::array<std::int16_t, XochitlHistoryState::kTransitionCount>;

  static int delta_slot(Mode mode);
  static bool valid_update(InclusiveRect update);
  static InclusiveRect rounded_execution(InclusiveRect update);
  Ct33Frontend *frontend_for(Mode mode);
  const Ct33Frontend *frontend_for(Mode mode) const;
  void fail(std::string *error, const std::string &message);

  const WaveformTable *waveform_ = nullptr; // borrowed, presenter-owned
  Ct33Frontend std_frontend_;
  Ct33Frontend best_frontend_;
  Ct33Frontend pen_frontend_;
  Ct33Frontend fast_frontend_;
  XochitlSelector16 selector_;
  XochitlHistoryState history_;
  std::array<std::array<Delta, kInstalledTemperatureBins>, 3> deltas_{};
  bool color_capable_ = false;
  std::uint64_t configuration_generation_ = 0;
};

} // namespace pluto::swtcon

#endif // PLUTO_PRESENTER_SWTCON_XOCHITL_COLOR_PIPELINE_H_
