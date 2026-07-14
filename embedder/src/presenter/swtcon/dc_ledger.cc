#include "presenter/swtcon/dc_ledger.h"

#include <limits>

namespace pluto::swtcon {

bool DcLedger::configure(int width, int height, int stride,
                         std::uint32_t tile_px, const DcLedgerConfig& config) {
  valid_ = false;
  // Reconfiguration is a reset boundary even when the new geometry is
  // rejected. Never expose an aggregate count detached from a stale backing
  // bitplane through the const safety query.
  prev_est_.clear();
  prev_estimated_count_ = 0;
  if (width <= 0 || height <= 0 || stride < width || (stride % 8) != 0 ||
      tile_px == 0 || config.dc_pixel_cap <= 0 ||
      static_cast<std::size_t>(height) >
          std::numeric_limits<std::size_t>::max() /
              static_cast<std::size_t>(stride)) {
    return false;
  }

  const std::uint64_t tile_cols =
      (static_cast<std::uint64_t>(width) + tile_px - 1u) / tile_px;
  const std::uint64_t tile_rows =
      (static_cast<std::uint64_t>(height) + tile_px - 1u) / tile_px;
  if (tile_cols > std::numeric_limits<std::uint32_t>::max() ||
      tile_rows > std::numeric_limits<std::uint32_t>::max() ||
      (tile_cols != 0 &&
       tile_rows > std::numeric_limits<std::size_t>::max() / tile_cols)) {
    return false;
  }
  const std::int64_t cap = config.dc_pixel_cap;
  if (static_cast<std::uint64_t>(tile_px) >
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max() /
                                 cap) /
          tile_px) {
    return false;
  }

  config_ = config;
  width_ = width;
  height_ = height;
  stride_ = stride;
  tile_px_ = tile_px;
  tile_cols_ = static_cast<std::uint32_t>(tile_cols);
  tile_rows_ = static_cast<std::uint32_t>(tile_rows);
  saturations_ = 0;

  const std::size_t plane =
      static_cast<std::size_t>(stride) * static_cast<std::size_t>(height);
  dc_.assign(plane, 0);
  prev_est_.assign(plane / 8, 0);
  prev_estimated_count_ = 0;
  stress_.assign(tile_count(), 0);
  rescan_dc_.assign(tile_count(), 0);
  rescan_tile_cap_ = static_cast<std::int64_t>(config.dc_pixel_cap) *
                     static_cast<std::int64_t>(tile_px) *
                     static_cast<std::int64_t>(tile_px);

  valid_ = true;
  return true;
}

bool DcLedger::export_handoff_state(DcLedgerHandoffState *out) const {
  if (out == nullptr || !valid_ || prev_estimated_count_ != 0) {
    return false;
  }
  DcLedgerHandoffState state;
  state.width = width_;
  state.height = height_;
  state.stride = stride_;
  state.tile_px = tile_px_;
  state.tile_cols = tile_cols_;
  state.tile_rows = tile_rows_;
  state.config = config_;
  state.dc = dc_;
  state.stress = stress_;
  state.rescan_dc = rescan_dc_;
  if (!handoff_state_valid(state)) {
    return false;
  }
  *out = std::move(state);
  return true;
}

bool DcLedger::handoff_state_valid(const DcLedgerHandoffState &state) const {
  if (!valid_ || state.width != width_ || state.height != height_ ||
      state.stride != stride_ || state.tile_px != tile_px_ ||
      state.tile_cols != tile_cols_ || state.tile_rows != tile_rows_ ||
      state.config != config_ || state.dc.size() != dc_.size() ||
      state.stress.size() != stress_.size() ||
      state.rescan_dc.size() != rescan_dc_.size()) {
    return false;
  }
  const int cap = config_.dc_pixel_cap;
  if (std::any_of(state.dc.begin(), state.dc.end(), [cap](std::int8_t value) {
        return value < -cap || value > cap;
      })) {
    return false;
  }
  return std::all_of(state.rescan_dc.begin(), state.rescan_dc.end(),
                     [this](std::int32_t value) {
                       return value >= -rescan_tile_cap_ &&
                              value <= rescan_tile_cap_;
                     });
}

bool DcLedger::import_handoff_state(const DcLedgerHandoffState &state) {
  if (prev_estimated_count_ != 0 || !handoff_state_valid(state)) {
    return false;
  }
  std::copy(state.dc.begin(), state.dc.end(), dc_.begin());
  std::copy(state.stress.begin(), state.stress.end(), stress_.begin());
  std::copy(state.rescan_dc.begin(), state.rescan_dc.end(), rescan_dc_.begin());
  std::fill(prev_est_.begin(), prev_est_.end(), 0);
  prev_estimated_count_ = 0;
  saturations_ = 0;
  return true;
}

}  // namespace pluto::swtcon
