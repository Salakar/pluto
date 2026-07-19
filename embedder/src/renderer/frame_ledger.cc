#include "renderer/frame_ledger.h"

#include <algorithm>
#include <cstring>
#include <utility>

namespace pluto {

bool FrameLedger::configure(const FrameLedgerConfig &config) {
  valid_ = false;
  width_ = 0;
  height_ = 0;
  tile_px_ = 0;
  tile_cols_ = 0;
  tile_rows_ = 0;
  stride_ = 0;
  chroma_stride_ = 0;
  epoch_ = 0;
  cur_hash_ = 0;
  if (config.width == 0 || config.height == 0 || config.tile_px == 0 ||
      config.tile_px > kMaxTilePx || (config.tile_px % 8u) != 0u) {
    l_cur_.clear();
    chroma_bits_.clear();
    row_hash_[0].clear();
    row_hash_[1].clear();
    row_samples_.clear();
    row_sample_epoch_.clear();
    stats_.clear();
    return false;
  }
  width_ = config.width;
  height_ = config.height;
  tile_px_ = config.tile_px;
  tile_cols_ = (width_ + tile_px_ - 1u) / tile_px_;
  tile_rows_ = (height_ + tile_px_ - 1u) / tile_px_;
  stride_ = static_cast<size_t>(tile_cols_) * tile_px_;
  chroma_stride_ = stride_ / 8u;
  l_cur_.assign(stride_ * height_, kInvalidLevel5);
  chroma_bits_.assign(chroma_stride_ * height_, 0u);
  row_hash_[0].assign(height_, 0u);
  row_hash_[1].assign(height_, 0u);
  const size_t sample_rows =
      (static_cast<size_t>(height_) - 1u) / kRowSamplePeriod + 1u;
  row_samples_.assign(sample_rows * stride_, 0u);
  row_sample_epoch_.assign(sample_rows, 0u);
  stats_.assign(static_cast<size_t>(tile_cols_) * tile_rows_, TileStats{});
  valid_ = true;
  return true;
}

void FrameLedger::invalidate() {
  if (!valid_) {
    return;
  }
  std::fill(l_cur_.begin(), l_cur_.end(), kInvalidLevel5);
  std::fill(chroma_bits_.begin(), chroma_bits_.end(), uint8_t{0});
  std::fill(row_hash_[0].begin(), row_hash_[0].end(), 0u);
  std::fill(row_hash_[1].begin(), row_hash_[1].end(), 0u);
  // 0 never matches a live pass epoch (begin_pass starts at 1), so stale
  // samples cannot verify a post-invalidate vote.
  std::fill(row_sample_epoch_.begin(), row_sample_epoch_.end(), 0u);
  std::fill(stats_.begin(), stats_.end(), TileStats{});
}

void FrameLedger::fill_levels(uint8_t lvl5) {
  std::fill(l_cur_.begin(), l_cur_.end(), lvl5);
}

uint32_t FrameLedger::begin_pass() {
  cur_hash_ ^= 1u;
  // Carry the previous pass's hashes forward; TilePass re-hashes only the
  // rows whose quantized bytes changed.
  std::memcpy(row_hash_[cur_hash_].data(), row_hash_[cur_hash_ ^ 1u].data(),
              height_ * sizeof(uint32_t));
  return ++epoch_;
}

bool FrameLedger::export_state(FrameLedgerState *out) const {
  if (!valid_ || out == nullptr) {
    return false;
  }
  FrameLedgerState state;
  state.config = FrameLedgerConfig{width_, height_, tile_px_};
  state.stride = stride_;
  state.chroma_stride = chroma_stride_;
  state.epoch = epoch_;
  state.cur_hash = cur_hash_;
  state.levels = l_cur_;
  state.chroma_bits = chroma_bits_;
  state.row_hash[0] = row_hash_[0];
  state.row_hash[1] = row_hash_[1];
  state.row_samples = row_samples_;
  state.row_sample_epoch = row_sample_epoch_;
  state.stats = stats_;
  *out = std::move(state);
  return true;
}

bool FrameLedger::import_state(const FrameLedgerState &state) {
  if (!valid_ || state.config.width != width_ ||
      state.config.height != height_ || state.config.tile_px != tile_px_ ||
      state.stride != stride_ || state.chroma_stride != chroma_stride_ ||
      state.cur_hash > 1u || state.levels.size() != l_cur_.size() ||
      state.chroma_bits.size() != chroma_bits_.size() ||
      state.row_hash[0].size() != row_hash_[0].size() ||
      state.row_hash[1].size() != row_hash_[1].size() ||
      state.row_samples.size() != row_samples_.size() ||
      state.row_sample_epoch.size() != row_sample_epoch_.size() ||
      state.stats.size() != stats_.size()) {
    return false;
  }

  for (uint8_t level : state.levels) {
    if (level > 31u && level != kInvalidLevel5) {
      return false;
    }
  }
  for (size_t i = 0; i < state.stats.size(); ++i) {
    const TileStats &stats = state.stats[i];
    const uint32_t tx = static_cast<uint32_t>(i) % tile_cols_;
    const uint32_t ty = static_cast<uint32_t>(i) / tile_cols_;
    const uint32_t tile_width = std::min(tile_px_, width_ - tx * tile_px_);
    const uint32_t tile_height = std::min(tile_px_, height_ - ty * tile_px_);
    if (stats.changed_px > tile_width * tile_height ||
        (stats.level_hist_lo & 0xf0u) != 0u ||
        stats.motion_class > kMotionChaotic || stats.changed_chroma > 1u) {
      return false;
    }
    if (stats.dirty.width <= 0 || stats.dirty.height <= 0) {
      if (stats.dirty.x != 0 || stats.dirty.y != 0 || stats.dirty.width != 0 ||
          stats.dirty.height != 0) {
        return false;
      }
    } else if (stats.dirty.x < 0 || stats.dirty.y < 0 ||
               static_cast<uint64_t>(stats.dirty.x) + stats.dirty.width >
                   width_ ||
               static_cast<uint64_t>(stats.dirty.y) + stats.dirty.height >
                   height_) {
      return false;
    }
  }

  // All validation above is read-only. Replace every correlated mirror as one
  // logical transaction only after the full state has proved compatible.
  epoch_ = state.epoch;
  cur_hash_ = state.cur_hash;
  std::copy(state.levels.begin(), state.levels.end(), l_cur_.begin());
  std::copy(state.chroma_bits.begin(), state.chroma_bits.end(),
            chroma_bits_.begin());
  std::copy(state.row_hash[0].begin(), state.row_hash[0].end(),
            row_hash_[0].begin());
  std::copy(state.row_hash[1].begin(), state.row_hash[1].end(),
            row_hash_[1].begin());
  std::copy(state.row_samples.begin(), state.row_samples.end(),
            row_samples_.begin());
  std::copy(state.row_sample_epoch.begin(), state.row_sample_epoch.end(),
            row_sample_epoch_.begin());
  std::copy(state.stats.begin(), state.stats.end(), stats_.begin());
  return true;
}

} // namespace pluto
