#include "presenter/swtcon/pixel_engine.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <limits>

#include "presenter/swtcon/mapped_sweep.h"
#include "presenter/swtcon/fast_rail_admit_kernels.h"
#include "presenter/swtcon/sweep_kernels.h"

namespace pluto::swtcon {

FastCoverage::FastCoverage(PlutoRect rect) : rect_(rect) {
  if (rect.width <= 0 || rect.height <= 0) {
    return;
  }
  stride_bytes_ =
      (static_cast<std::size_t>(rect.width) + std::size_t{7}) / 8u;
  if (stride_bytes_ == 0 ||
      static_cast<std::size_t>(rect.height) >
          std::numeric_limits<std::size_t>::max() / stride_bytes_) {
    stride_bytes_ = 0;
    return;
  }
  bits_.assign(stride_bytes_ * static_cast<std::size_t>(rect.height), 0);
  recovery_generations_.assign(
      static_cast<std::size_t>(rect.width) *
          static_cast<std::size_t>(rect.height),
      0);
}

bool FastCoverage::valid() const {
  return rect_.width > 0 && rect_.height > 0 && stride_bytes_ != 0 &&
         bits_.size() ==
             stride_bytes_ * static_cast<std::size_t>(rect_.height) &&
         recovery_generations_.size() ==
             static_cast<std::size_t>(rect_.width) *
                 static_cast<std::size_t>(rect_.height);
}

bool FastCoverage::driven(std::int32_t x, std::int32_t y) const {
  if (!valid() || x < rect_.x || y < rect_.y ||
      x >= rect_.x + rect_.width || y >= rect_.y + rect_.height) {
    return false;
  }
  const std::size_t local_x = static_cast<std::size_t>(x - rect_.x);
  const std::size_t byte =
      static_cast<std::size_t>(y - rect_.y) * stride_bytes_ + local_x / 8u;
  return (bits_[byte] & static_cast<std::uint8_t>(1u << (local_x & 7u))) != 0;
}

std::uint32_t FastCoverage::recovery_generation(std::int32_t x,
                                                std::int32_t y) const {
  if (!valid() || x < rect_.x || y < rect_.y ||
      x >= rect_.x + rect_.width || y >= rect_.y + rect_.height) {
    return 0;
  }
  return recovery_generations_[
      static_cast<std::size_t>(y - rect_.y) *
          static_cast<std::size_t>(rect_.width) +
      static_cast<std::size_t>(x - rect_.x)];
}

void FastCoverage::mark(std::int32_t x, std::int32_t y,
                        std::uint64_t engine_frame,
                        std::uint32_t recovery_generation) {
  if (!valid() || x < rect_.x || y < rect_.y ||
      x >= rect_.x + rect_.width || y >= rect_.y + rect_.height) {
    return;
  }
  const std::size_t local_x = static_cast<std::size_t>(x - rect_.x);
  const std::size_t byte =
      static_cast<std::size_t>(y - rect_.y) * stride_bytes_ + local_x / 8u;
  const std::uint8_t mask =
      static_cast<std::uint8_t>(1u << (local_x & 7u));
  if ((bits_[byte] & mask) == 0) {
    bits_[byte] = static_cast<std::uint8_t>(bits_[byte] | mask);
    ++driven_count_;
  }
  recovery_generations_[
      static_cast<std::size_t>(y - rect_.y) *
          static_cast<std::size_t>(rect_.width) +
      local_x] = recovery_generation;
  last_drive_engine_frame_ =
      std::max(last_drive_engine_frame_, engine_frame);
}

namespace {

// Clips `rect` to [0,width)x[0,height); returns false when empty.
bool clip_rect(const PlutoRect &rect, int width, int height,
               PlutoRect *out) {
  const std::int32_t x0 = rect.x < 0 ? 0 : rect.x;
  const std::int32_t y0 = rect.y < 0 ? 0 : rect.y;
  const std::int32_t x1 =
      rect.x + rect.width > width ? width : rect.x + rect.width;
  const std::int32_t y1 =
      rect.y + rect.height > height ? height : rect.y + rect.height;
  if (x1 <= x0 || y1 <= y0) {
    return false;
  }
  out->x = x0;
  out->y = y0;
  out->width = x1 - x0;
  out->height = y1 - y0;
  return true;
}

bool rects_intersect(const PlutoRect &a, const PlutoRect &b) {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height &&
         b.y < a.y + a.height;
}

bool inclusive_intersects(const XochitlHistoryState::InclusiveRect& a,
                          const XochitlHistoryState::InclusiveRect& b) {
  return a.left <= b.right && b.left <= a.right && a.top <= b.bottom &&
         b.top <= a.bottom;
}

bool inclusive_contains(const XochitlHistoryState::InclusiveRect& outer,
                        const XochitlHistoryState::InclusiveRect& inner) {
  return outer.left <= inner.left && outer.top <= inner.top &&
         outer.right >= inner.right && outer.bottom >= inner.bottom;
}

bool mapped_lane_selected(
    const XochitlHistoryState::PreparedOperation& operation, int x, int y) {
  const auto execution = operation.execution();
  if (x < execution.left || x > execution.right || y < execution.top ||
      y > execution.bottom) {
    return false;
  }
  const std::size_t lane =
      static_cast<std::size_t>(y - execution.top) *
          static_cast<std::size_t>(operation.width()) +
      static_cast<std::size_t>(x - execution.left);
  return operation.lane_selected(lane);
}

bool mapped_operation_covers(
    const XochitlHistoryState::PreparedOperation& candidate,
    const XochitlHistoryState::PreparedOperation& older) {
  const auto candidate_execution = candidate.execution();
  const auto older_execution = older.execution();
  if (!inclusive_contains(candidate_execution, older_execution)) {
    return false;
  }
  if (!candidate.masked()) {
    return true;
  }
  for (int y = older_execution.top; y <= older_execution.bottom; ++y) {
    for (int x = older_execution.left; x <= older_execution.right; ++x) {
      if (mapped_lane_selected(older, x, y) &&
          !mapped_lane_selected(candidate, x, y)) {
        return false;
      }
    }
  }
  return true;
}

template <typename Callback>
class ScopeExit final {
 public:
  explicit ScopeExit(Callback callback) : callback_(std::move(callback)) {}
  ~ScopeExit() noexcept {
    if (active_) {
      callback_();
    }
  }

  ScopeExit(const ScopeExit&) = delete;
  ScopeExit& operator=(const ScopeExit&) = delete;
  void release() noexcept { active_ = false; }

 private:
  Callback callback_;
  bool active_ = true;
};

std::size_t mapped_guard_lane_count(
    XochitlHistoryState::InclusiveRect execution, std::int32_t width,
    const PixelEngineConfig& config) {
  const std::int32_t visible_rows =
      std::max(0, std::min(execution.bottom + 1, config.height) -
                      execution.top);
  const std::int32_t right_guard_columns =
      std::max(0, execution.right + 1 - config.stride);
  const std::int32_t bottom_guard_rows =
      std::max(0, execution.bottom + 1 - config.height);
  return static_cast<std::size_t>(visible_rows) *
             static_cast<std::size_t>(right_guard_columns) +
         static_cast<std::size_t>(bottom_guard_rows) *
             static_cast<std::size_t>(width);
}

constexpr std::uint16_t kValidXochitlAMask = 0x00dfu;

bool exact_color_a_view_valid(const ExactColorAView &view,
                              const PixelEngineConfig &config) {
  if (view.history_stride < static_cast<std::size_t>(config.stride) ||
      view.history_rows < static_cast<std::size_t>(config.height) ||
      view.history_stride == 0 || view.history_rows == 0 ||
      view.history_rows >
          std::numeric_limits<std::size_t>::max() / view.history_stride) {
    return false;
  }
  const std::size_t pixels = view.history_stride * view.history_rows;
  if (pixels > std::numeric_limits<std::size_t>::max() / 2u ||
      view.interleaved_ab.size() != pixels * 2u) {
    return false;
  }
  // Xochitl A permits low5 plus marker bits 6/7. B is a full 16-bit history
  // word and therefore has no rejected bit pattern.
  for (std::size_t i = 0; i < view.interleaved_ab.size(); i += 2u) {
    if ((view.interleaved_ab[i] & ~kValidXochitlAMask) != 0) {
      return false;
    }
  }
  return true;
}

std::uint8_t exact_color_level(const ExactColorAView &view, std::size_t x,
                               std::size_t y) {
  return static_cast<std::uint8_t>(
      view.interleaved_ab[(y * view.history_stride + x) * 2u] & 0x1fu);
}

} // namespace

bool PixelEngine::configure(const WaveformTable *waveform,
                            const PixelEngineConfig &config) {
  configured_ = false;
  if (waveform == nullptr || !waveform->valid()) {
    return false;
  }
  if (config.width <= 0 || config.height <= 0 || config.stride < config.width ||
      (config.stride % 8) != 0 || config.tile_px == 0 ||
      config.width > 0xffff || config.full_flash_band_frames == 0 ||
      config.initial_prev_level > 0x1fu ||
      !std::isfinite(config.temp_hysteresis_c) ||
      config.temp_hysteresis_c < 0.0f) {
    return false;
  }

  config_ = config;
  waveform_ = waveform;
  mode7_fast_recovery_supported_ =
      supports_mode7_fast_recovery(*waveform_);
  lut_cache_ = std::make_unique<LutCache>(waveform_);
  if (!dc_.configure(config_.width, config_.height, config_.stride,
                     config_.tile_px, config_.dc)) {
    return false;
  }

  const std::size_t plane = static_cast<std::size_t>(config_.stride) *
                            static_cast<std::size_t>(config_.height);
  prev_.assign(plane, config_.initial_prev_level);
  next_.assign(plane, config_.initial_prev_level);
  final_.assign(plane, config_.initial_prev_level);
  fnum_.assign(plane, kFnumIdle);
  waveform_drove_.assign(plane, 0);
  fast_rebase_pending_generation_.assign(plane, 0);
  next_fast_recovery_generation_ = 1;

  tile_cols_ = dc_.tile_cols();
  tile_rows_ = dc_.tile_rows();
  tiles_.assign(dc_.tile_count(), TileState{});
  tile_subscribers_.assign(dc_.tile_count(), {});

  row_active_.assign(static_cast<std::size_t>(config_.height), 0);
  clip_min_row_ = 0;
  clip_max_row_ = -1;
  total_active_px_ = 0;

  // The direct presenter splits a typical ~100x100 pen corridor into about 16
  // tile admissions. Prewarm 16 pieces for each of RegionScheduler's 512 live
  // request slots, and keep their normal tile payload inline, so the sustained
  // trail does not hit either a vector growth or thousands of tiny heaps.
  constexpr std::size_t kWarmUpdateSlots = 8192;
  constexpr std::size_t kWarmSubscribersPerTile = 512;
  updates_.clear();
  updates_.resize(kWarmUpdateSlots);
  free_updates_.clear();
  free_updates_.reserve(kWarmUpdateSlots);
  for (std::size_t i = kWarmUpdateSlots; i > 0; --i) {
    free_updates_.push_back(static_cast<std::uint32_t>(i - 1));
  }
  for (std::vector<std::uint32_t> &subscribers : tile_subscribers_) {
    subscribers.reserve(kWarmSubscribersPerTile);
  }
  pending_pieces_.clear();
  pending_pieces_.reserve(512);
  pieces_scratch_.clear();
  pieces_scratch_.reserve(512);
  supersede_scratch_.clear();
  supersede_scratch_.reserve(2048);
  // Sized (not just reserved): the sweep kernels write ops through raw
  // cursors, at most one op per pixel of the row. The NEON kernel's sparse
  // left-pack emission stores a full 16-lane group (writing up to 16 op slots
  // past the compacted `emitted` cursor as harmless scratch that is never
  // read); the +16 tail guarantees those stores stay in bounds for a fully
  // packed final row.
  row_ops_.resize(static_cast<std::size_t>(config_.width) + 16);
  mapped_terminal_scratch_.resize(static_cast<std::size_t>(config_.width) +
                                  16);
  completed_tiles_.reserve(dc_.tile_count());
  band_records_.assign(tile_cols_, nullptr);
  band_renorm_.assign(tile_cols_, 0);

  mapped_operations_.clear();
  mapped_runtime_pool_.clear();
  mapped_runtime_pool_.reserve(1);
  mapped_tile_owner_.assign(dc_.tile_count(), 0);
  mapped_tile_runtime_.assign(dc_.tile_count(), nullptr);
  mapped_poisoned_owner_.assign(dc_.tile_count(), nullptr);
  invalidated_histories_.clear();
  reseeded_histories_.clear();
  mapped_poison_regions_.clear();
  mapped_poisoned_count_ = 0;
  mapped_history_invalid_ = false;
  mapped_row_active_.assign(static_cast<std::size_t>(config_.height), 0);
  mapped_active_px_ = 0;
  mapped_clip_min_row_ = 0;
  mapped_clip_max_row_ = -1;
  next_mapped_token_ = 1;
  next_recovery_token_ = 1;
  active_recoveries_.clear();
  terminal_recoveries_.clear();
  latched_recoveries_.clear();

  frame_ = 0;
  stats_ = PixelEngineStats{};
  bin_selector_ = TemperatureBinSelector(config_.temp_hysteresis_c);
  current_bin_ = bin_selector_.select(waveform_->temp_thresholds(), 25.0f);

  configured_ = true;
  return true;
}

bool PixelEngine::seed_prev(const std::uint8_t *levels, int width, int height) {
  if (!configured_ || levels == nullptr || total_active_px_ != 0 ||
      !pending_pieces_.empty() || !mapped_operations_.empty() ||
      width != config_.width ||
      height != config_.height) {
    return false;
  }
  for (int y = 0; y < height; ++y) {
    const std::uint8_t *src =
        levels + static_cast<std::size_t>(y) * static_cast<std::size_t>(width);
    const std::size_t row =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride);
    for (int x = 0; x < width; ++x) {
      const std::uint8_t level = static_cast<std::uint8_t>(src[x] & 0x1f);
      prev_[row + static_cast<std::size_t>(x)] = level;
      next_[row + static_cast<std::size_t>(x)] = level;
      final_[row + static_cast<std::size_t>(x)] = level;
    }
  }
  std::fill(waveform_drove_.begin(), waveform_drove_.end(), 0);
  std::fill(fast_rebase_pending_generation_.begin(),
            fast_rebase_pending_generation_.end(), 0);
  dc_.clear_all_prev_estimated();
  return true;
}

bool PixelEngine::export_handoff_state(PixelEngineHandoffState *out) const {
  return export_handoff_state_impl(nullptr, out);
}

bool PixelEngine::export_handoff_state(const ExactColorAView &exact_color,
                                       PixelEngineHandoffState *out) const {
  return export_handoff_state_impl(&exact_color, out);
}

bool PixelEngine::export_handoff_state_impl(
    const ExactColorAView *exact_color, PixelEngineHandoffState *out) const {
  if (out == nullptr || !quiescent_handoff_invariants_hold() ||
      (exact_color != nullptr &&
       !exact_color_a_view_valid(*exact_color, config_))) {
    return false;
  }

  if (exact_color != nullptr) {
    for (int y = 0; y < config_.height; ++y) {
      const std::size_t row = static_cast<std::size_t>(y) *
                              static_cast<std::size_t>(config_.stride);
      for (int x = 0; x < config_.stride; ++x) {
        // Xochitl exclusively owns packed execution guards [width,stride):
        // mapped edge journals intentionally replicate visible A/B into
        // those lanes, while PixelEngine never admits or drives them. Keep
        // the engine padding on its configured invariant instead of
        // pretending the two owners describe the same pixels.
        const std::uint8_t expected =
            x < config_.width
                ? exact_color_level(*exact_color, static_cast<std::size_t>(x),
                                    static_cast<std::size_t>(y))
                : config_.initial_prev_level;
        if (prev_[row + static_cast<std::size_t>(x)] != expected) {
          return false;
        }
      }
    }
  }

  PixelEngineHandoffState state;
  state.config = config_;
  state.temperature_bin = current_bin_;
  if (exact_color == nullptr) {
    state.settled_levels = prev_;
  }
  if (!dc_.export_handoff_state(&state.dc)) {
    return false;
  }
  *out = std::move(state);
  return true;
}

bool PixelEngine::import_handoff_state(const PixelEngineHandoffState &state) {
  return import_handoff_state_impl(state, nullptr);
}

bool PixelEngine::import_handoff_state(const PixelEngineHandoffState &state,
                                       const ExactColorAView &exact_color) {
  return import_handoff_state_impl(state, &exact_color);
}

bool PixelEngine::import_handoff_state_impl(
    const PixelEngineHandoffState &state, const ExactColorAView *exact_color) {
  if (!quiescent_handoff_invariants_hold() || state.config != config_ ||
      !dc_.handoff_state_valid(state.dc) || waveform_ == nullptr ||
      state.temperature_bin < 0 ||
      static_cast<std::size_t>(state.temperature_bin) >=
          waveform_->temp_thresholds().size()) {
    return false;
  }

  const std::size_t plane = static_cast<std::size_t>(config_.stride) *
                            static_cast<std::size_t>(config_.height);
  if (exact_color == nullptr) {
    if (state.settled_levels.size() != plane ||
        std::any_of(state.settled_levels.begin(), state.settled_levels.end(),
                    [](std::uint8_t level) { return level > 0x1fu; })) {
      return false;
    }
  } else if (!state.settled_levels.empty() ||
             !exact_color_a_view_valid(*exact_color, config_)) {
    return false;
  }

  // Build replacement free-slot state before the commit point. All remaining
  // work below uses already-sized vectors and cannot partially allocate a
  // handoff into the live engine.
  std::vector<std::uint32_t> reset_free_updates;
  reset_free_updates.reserve(updates_.size());
  for (std::size_t i = updates_.size(); i > 0; --i) {
    reset_free_updates.push_back(static_cast<std::uint32_t>(i - 1u));
  }

  if (!dc_.import_handoff_state(state.dc)) {
    return false;
  }
  if (exact_color == nullptr) {
    std::copy(state.settled_levels.begin(), state.settled_levels.end(),
              prev_.begin());
  } else {
    for (int y = 0; y < config_.height; ++y) {
      const std::size_t row = static_cast<std::size_t>(y) *
                              static_cast<std::size_t>(config_.stride);
      for (int x = 0; x < config_.stride; ++x) {
        prev_[row + static_cast<std::size_t>(x)] =
            x < config_.width
                ? exact_color_level(*exact_color, static_cast<std::size_t>(x),
                                    static_cast<std::size_t>(y))
                : config_.initial_prev_level;
      }
    }
  }
  std::copy(prev_.begin(), prev_.end(), next_.begin());
  std::copy(prev_.begin(), prev_.end(), final_.begin());
  const bool seeded = bin_selector_.seed_held_bin(
      state.temperature_bin, waveform_->temp_thresholds().size());
  assert(seeded);
  (void)seeded;
  current_bin_ = state.temperature_bin;
  reset_handoff_transients(std::move(reset_free_updates));
  return true;
}

bool PixelEngine::quiescent_handoff_invariants_hold() const {
  if (!configured_ || !handoff_safe() || sink_impulse_ != nullptr ||
      sink_drive_ != nullptr || current_bin_ < 0 ||
      bin_selector_.held_bin() != current_bin_ || waveform_ == nullptr ||
      static_cast<std::size_t>(current_bin_) >=
          waveform_->temp_thresholds().size()) {
    return false;
  }
  const std::size_t plane = static_cast<std::size_t>(config_.stride) *
                            static_cast<std::size_t>(config_.height);
  if (prev_.size() != plane || next_.size() != plane ||
      final_.size() != plane || fnum_.size() != plane ||
      waveform_drove_.size() != plane ||
      fast_rebase_pending_generation_.size() != plane) {
    return false;
  }
  for (std::size_t px = 0; px < plane; ++px) {
    if (prev_[px] > 0x1fu || prev_[px] != next_[px] ||
        prev_[px] != final_[px] || fnum_[px] != kFnumIdle ||
        waveform_drove_[px] != 0 || fast_rebase_pending_generation_[px] != 0) {
      return false;
    }
  }
  if (std::any_of(row_active_.begin(), row_active_.end(),
                  [](std::uint16_t active) { return active != 0; }) ||
      std::any_of(mapped_row_active_.begin(), mapped_row_active_.end(),
                  [](std::uint16_t active) { return active != 0; }) ||
      mapped_active_px_ != 0 || mapped_poisoned_count_ != 0 ||
      !invalidated_histories_.empty() || !reseeded_histories_.empty() ||
      !mapped_poison_regions_.empty() || !active_recoveries_.empty() ||
      !terminal_recoveries_.empty() || !latched_recoveries_.empty()) {
    return false;
  }
  if (std::any_of(tiles_.begin(), tiles_.end(),
                  [](const TileState &tile) {
                    return tile.active_px != 0 ||
                           tile.update_index != kNoUpdate;
                  }) ||
      std::any_of(
          tile_subscribers_.begin(), tile_subscribers_.end(),
          [](const auto &subscribers) { return !subscribers.empty(); }) ||
      std::any_of(updates_.begin(), updates_.end(),
                  [](const Update &update) {
                    return update.live || update.pending != 0 ||
                           update.borrow != nullptr ||
                           update.retained_size != 0 ||
                           update.fast_coverage != nullptr;
                  }) ||
      std::any_of(mapped_tile_owner_.begin(), mapped_tile_owner_.end(),
                  [](MappedOperationToken token) { return token != 0; }) ||
      std::any_of(
          mapped_tile_runtime_.begin(), mapped_tile_runtime_.end(),
          [](const MappedRuntime *runtime) { return runtime != nullptr; }) ||
      std::any_of(
          mapped_poisoned_owner_.begin(), mapped_poisoned_owner_.end(),
          [](const XochitlHistoryState *owner) { return owner != nullptr; })) {
    return false;
  }
  return true;
}

void PixelEngine::reset_handoff_transients(
    std::vector<std::uint32_t> reset_free_updates) {
  std::fill(fnum_.begin(), fnum_.end(), kFnumIdle);
  std::fill(waveform_drove_.begin(), waveform_drove_.end(), 0);
  std::fill(fast_rebase_pending_generation_.begin(),
            fast_rebase_pending_generation_.end(), 0);
  next_fast_recovery_generation_ = 1;

  std::fill(tiles_.begin(), tiles_.end(), TileState{});
  for (auto &subscribers : tile_subscribers_) {
    subscribers.clear();
  }
  std::fill(row_active_.begin(), row_active_.end(), 0);
  clip_min_row_ = 0;
  clip_max_row_ = -1;
  total_active_px_ = 0;

  for (Update &update : updates_) {
    update = Update{};
  }
  free_updates_.swap(reset_free_updates);
  pending_pieces_.clear();
  pieces_scratch_.clear();
  supersede_scratch_.clear();

  mapped_operations_.clear();
  mapped_runtime_pool_.clear();
  std::fill(mapped_tile_owner_.begin(), mapped_tile_owner_.end(), 0);
  std::fill(mapped_tile_runtime_.begin(), mapped_tile_runtime_.end(), nullptr);
  std::fill(mapped_poisoned_owner_.begin(), mapped_poisoned_owner_.end(),
            nullptr);
  invalidated_histories_.clear();
  reseeded_histories_.clear();
  mapped_poison_regions_.clear();
  mapped_poisoned_count_ = 0;
  mapped_history_invalid_ = false;
  std::fill(mapped_row_active_.begin(), mapped_row_active_.end(), 0);
  mapped_active_px_ = 0;
  mapped_clip_min_row_ = 0;
  mapped_clip_max_row_ = -1;
  next_mapped_token_ = 1;
  next_recovery_token_ = 1;
  active_recoveries_.clear();
  terminal_recoveries_.clear();
  latched_recoveries_.clear();

  frame_ = 0;
  stats_ = PixelEngineStats{};
  sink_impulse_ = nullptr;
  sink_drive_ = nullptr;
  std::fill(mapped_terminal_scratch_.begin(), mapped_terminal_scratch_.end(),
            0);
  completed_tiles_.clear();
  std::fill(band_records_.begin(), band_records_.end(), nullptr);
  std::fill(band_renorm_.begin(), band_renorm_.end(), 0);
}

void PixelEngine::set_temperature(float celsius) {
  if (waveform_ == nullptr) {
    return;
  }
  current_bin_ = bin_selector_.select(waveform_->temp_thresholds(), celsius);
}

void PixelEngine::set_completion_callback(CompletionFn fn) {
  completion_fn_ = std::move(fn);
}

std::size_t PixelEngine::mapped_queued_count() const {
  return static_cast<std::size_t>(std::count_if(
      mapped_operations_.begin(), mapped_operations_.end(),
      [](const auto& operation) {
        return operation->state == MappedState::kQueued;
      }));
}

std::size_t PixelEngine::mapped_runtime_lane_storage_bytes() const {
  std::size_t bytes = 0;
  for (const auto& operation : mapped_operations_) {
    bytes += operation->fnum.size() * sizeof(std::uint8_t);
    bytes += operation->guard_dc.size() * sizeof(std::int8_t);
  }
  return bytes;
}

std::size_t PixelEngine::mapped_guard_storage_bytes() const {
  std::size_t bytes = 0;
  for (const auto& operation : mapped_operations_) {
    bytes += operation->guard_dc.size() * sizeof(std::int8_t);
  }
  return bytes;
}

std::size_t PixelEngine::mapped_runtime_pool_lane_capacity_bytes() const {
  std::size_t bytes = 0;
  for (const auto& operation : mapped_runtime_pool_) {
    bytes += operation->fnum.capacity() * sizeof(std::uint8_t);
    bytes += operation->guard_dc.capacity() * sizeof(std::int8_t);
  }
  return bytes;
}

PixelEngine::MappedRuntime* PixelEngine::find_mapped(
    MappedOperationToken token) {
  const std::size_t index = find_mapped_index(token);
  return index == mapped_operations_.size() ? nullptr
                                             : mapped_operations_[index].get();
}

const PixelEngine::MappedRuntime* PixelEngine::find_mapped(
    MappedOperationToken token) const {
  const std::size_t index = find_mapped_index(token);
  return index == mapped_operations_.size() ? nullptr
                                             : mapped_operations_[index].get();
}

std::size_t PixelEngine::find_mapped_index(MappedOperationToken token) const {
  for (std::size_t i = 0; i < mapped_operations_.size(); ++i) {
    if (mapped_operations_[i]->token == token) {
      return i;
    }
  }
  return mapped_operations_.size();
}

std::unique_ptr<PixelEngine::MappedRuntime>
PixelEngine::acquire_mapped_runtime() {
  if (mapped_runtime_pool_.empty()) {
    return std::make_unique<MappedRuntime>();
  }
  auto operation = std::move(mapped_runtime_pool_.back());
  mapped_runtime_pool_.pop_back();
  return operation;
}

void PixelEngine::recycle_mapped_runtime(
    std::unique_ptr<MappedRuntime> operation) noexcept {
  operation->token = 0;
  operation->frame_id = 0;
  operation->retry_cookie = 0;
  operation->recovery_token = 0;
  operation->mode = 0;
  operation->temp_bin = 0;
  operation->codes = nullptr;
  operation->phase_count = 0;
  operation->history = nullptr;
  operation->operation.reset();
  operation->state = MappedState::kQueued;
  operation->ever_emitted = false;
  operation->reconcile_invalidated = false;
  operation->active_lanes = 0;
  operation->fnum.clear();
  operation->guard_dc.clear();
  operation->tile_indices.clear();
  if (mapped_runtime_pool_.empty()) {
    mapped_runtime_pool_.push_back(std::move(operation));
  }
}

bool PixelEngine::mapped_operations_overlap(const MappedRuntime& a,
                                            const MappedRuntime& b) const {
  const auto ar = a.operation->execution();
  const auto br = b.operation->execution();
  return ar.left <= br.right && br.left <= ar.right && ar.top <= br.bottom &&
         br.top <= ar.bottom;
}

bool PixelEngine::mapped_history_regions_overlap(const MappedRuntime& a,
                                                 const MappedRuntime& b) const {
  if (a.history != b.history) {
    return false;
  }
  const auto ar = a.operation->execution();
  const auto br = b.operation->execution();
  constexpr int kHistoryTileWidth = 8;
  constexpr int kHistoryTileHeight = 2;
  return ar.left / kHistoryTileWidth <= br.right / kHistoryTileWidth &&
         br.left / kHistoryTileWidth <= ar.right / kHistoryTileWidth &&
         ar.top / kHistoryTileHeight <= br.bottom / kHistoryTileHeight &&
         br.top / kHistoryTileHeight <= ar.bottom / kHistoryTileHeight;
}

bool PixelEngine::mapped_operation_intersects(
    const MappedRuntime& operation, const PlutoRect& rect) const {
  const auto requested = operation.operation->execution();
  const PlutoRect mapped{
      requested.left,
      requested.top,
      requested.right - requested.left + 1,
      requested.bottom - requested.top + 1,
  };
  return rects_intersect(mapped, rect);
}

bool PixelEngine::mapped_tile_claimed(std::uint32_t tile_index) const {
  return std::any_of(mapped_operations_.begin(), mapped_operations_.end(),
                     [&](const auto& operation) {
                       return std::find(operation->tile_indices.begin(),
                                        operation->tile_indices.end(),
                                        tile_index) !=
                              operation->tile_indices.end();
                     });
}

bool PixelEngine::mapped_can_start(const MappedRuntime& operation) const {
  return std::all_of(
      operation.tile_indices.begin(), operation.tile_indices.end(),
      [&](std::uint32_t tile_index) {
        return tiles_[tile_index].active_px == 0 &&
               mapped_tile_owner_[tile_index] == 0 &&
               (mapped_poisoned_owner_[tile_index] == nullptr ||
                mapped_reconcile_covers_tile_poison(operation, tile_index));
      });
}

bool PixelEngine::mapped_reconcile_covers_tile_poison(
    const MappedRuntime& operation, std::uint32_t tile_index) const {
  if (!operation.reconcile_invalidated ||
      mapped_poisoned_owner_[tile_index] != operation.history) {
    return false;
  }
  const int tile_px = static_cast<int>(config_.tile_px);
  const int tx = static_cast<int>(tile_index % tile_cols_);
  const int ty = static_cast<int>(tile_index / tile_cols_);
  const XochitlHistoryState::InclusiveRect tile_rect{
      tx * tile_px,
      ty * tile_px,
      std::min((tx + 1) * tile_px, config_.stride) - 1,
      std::min((ty + 1) * tile_px, config_.height) - 1,
  };
  const auto candidate = operation.operation->execution();
  bool found = false;
  for (const MappedPoisonRegion& poison : mapped_poison_regions_) {
    if (poison.history != operation.history ||
        !inclusive_intersects(poison.execution, tile_rect)) {
      continue;
    }
    found = true;
    if (!poison.regional_reseed_allowed ||
        poison.recovery_token != operation.recovery_token ||
        !inclusive_contains(candidate, poison.execution)) {
      return false;
    }
  }
  return found;
}

void PixelEngine::activate_mapped(MappedRuntime& operation) {
  assert(operation.state == MappedState::kQueued);
  assert(mapped_can_start(operation));
  if (operation.reconcile_invalidated) {
    const auto candidate = operation.operation->execution();
    mapped_poison_regions_.erase(
        std::remove_if(mapped_poison_regions_.begin(),
                       mapped_poison_regions_.end(),
                       [&](const MappedPoisonRegion& poison) {
                         return poison.history == operation.history &&
                                poison.regional_reseed_allowed &&
                                poison.recovery_token ==
                                    operation.recovery_token &&
                                inclusive_contains(candidate, poison.execution);
                       }),
        mapped_poison_regions_.end());
    rebuild_mapped_poison_tiles();
    if (std::find(reseeded_histories_.begin(), reseeded_histories_.end(),
                  operation.history) == reseeded_histories_.end()) {
      reseeded_histories_.push_back(operation.history);
    }
  }
  for (const std::uint32_t tile_index : operation.tile_indices) {
    mapped_tile_owner_[tile_index] = operation.token;
    mapped_tile_runtime_[tile_index] = &operation;
  }

  const auto execution = operation.operation->execution();
  const int x0 = execution.left;
  const int x1 = std::min(execution.right + 1, config_.stride);
  const int y0 = execution.top;
  const int y1 = std::min(execution.bottom + 1, config_.height);
  operation.active_lanes = static_cast<std::uint32_t>(
      std::count_if(operation.fnum.begin(), operation.fnum.end(),
                    [](std::uint8_t phase) {
                      return phase != kMappedSweepIdle;
                    }));
  for (int y = y0; y < y1; ++y) {
    const std::size_t tight_row =
        static_cast<std::size_t>(y - execution.top) *
        static_cast<std::size_t>(operation.operation->width());
    const std::size_t panel_row =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride);
    std::uint16_t row_lanes = 0;
    for (int x = x0; x < x1; ++x) {
      const std::size_t lane = tight_row + static_cast<std::size_t>(x - x0);
      if (operation.fnum[lane] == kMappedSweepIdle) {
        continue;
      }
      ++row_lanes;
      const std::size_t px = panel_row + static_cast<std::size_t>(x);
      const std::uint8_t logical = static_cast<std::uint8_t>(
          operation.operation->lanes()[lane].a2 & 31u);
      // next/final are logical intent only. The mapped drive state remains in
      // LaneJournal::transition and is never installed in a logical plane.
      if (x < config_.width) {
        next_[px] = logical;
        final_[px] = logical;
      }
    }
    mapped_row_active_[static_cast<std::size_t>(y)] = static_cast<std::uint16_t>(
        mapped_row_active_[static_cast<std::size_t>(y)] + row_lanes);
    mapped_active_px_ += row_lanes;
  }
  assert(operation.active_lanes != 0);
  operation.state = MappedState::kActive;
  ++stats_.mapped_started;
  recompute_mapped_clip();
}

void PixelEngine::activate_mapped_queue() {
  // Admissions are ordered. Starting one operation can lock tiles needed by
  // a later one; disjoint later operations still start in this same pass.
  std::size_t i = 0;
  while (i < mapped_operations_.size()) {
    MappedRuntime& operation = *mapped_operations_[i];
    if (operation.state == MappedState::kQueued &&
        mapped_can_start(operation)) {
      if (!operation.history->admissible(*operation.operation)) {
        const auto discarded =
            operation.history->discard(*operation.operation);
        if (discarded == XochitlHistoryState::FinalizeStatus::kDiscarded) {
          erase_mapped(i, MappedEventKind::kDiscarded, false, true,
                       MappedDiscardReason::kStaleAfterMvccSeed);
        } else {
          XochitlHistoryState* const history = operation.history;
          invalidate_mapped_owner(history);
          i = 0;
        }
        continue;
      }
      activate_mapped(operation);
    }
    ++i;
  }
}

void PixelEngine::recompute_mapped_clip() {
  mapped_clip_min_row_ = 0;
  mapped_clip_max_row_ = -1;
  for (int y = 0; y < config_.height; ++y) {
    if (mapped_row_active_[static_cast<std::size_t>(y)] == 0) {
      continue;
    }
    if (mapped_clip_max_row_ < mapped_clip_min_row_) {
      mapped_clip_min_row_ = y;
    }
    mapped_clip_max_row_ = y;
  }
}

void PixelEngine::reset_mapped_intent(const MappedRuntime& operation) {
  if (operation.state == MappedState::kQueued) {
    return;
  }
  const auto execution = operation.operation->execution();
  const int x1 = std::min(execution.right + 1, config_.stride);
  const int y1 = std::min(execution.bottom + 1, config_.height);
  for (int y = execution.top; y < y1; ++y) {
    const std::size_t row =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride);
    for (int x = execution.left; x < std::min(x1, config_.width); ++x) {
      const std::size_t lane =
          static_cast<std::size_t>(y - execution.top) *
              static_cast<std::size_t>(operation.operation->width()) +
          static_cast<std::size_t>(x - execution.left);
      if (!operation.operation->lane_selected(lane)) {
        continue;
      }
      const std::size_t px = row + static_cast<std::size_t>(x);
      next_[px] = prev_[px];
      final_[px] = prev_[px];
    }
  }
}

void PixelEngine::release_mapped_locks(const MappedRuntime& operation) {
  for (const std::uint32_t tile_index : operation.tile_indices) {
    if (mapped_tile_owner_[tile_index] == operation.token) {
      mapped_tile_owner_[tile_index] = 0;
      mapped_tile_runtime_[tile_index] = nullptr;
    }
  }
}

void PixelEngine::emit_mapped_event(MappedEventKind kind,
                                    const MappedRuntime& operation,
                                    MappedDiscardReason discard_reason) {
  if (mapped_event_fn_) {
    MappedEvent event;
    event.kind = kind;
    event.token = operation.token;
    event.history_operation_id = operation.operation->operation_id();
    event.frame_id = operation.frame_id;
    event.retry_cookie = operation.retry_cookie;
    event.recovery_token = operation.recovery_token;
    event.requested = operation.operation->requested();
    event.execution = operation.operation->execution();
    event.scanned = operation.ever_emitted ||
                    operation.state == MappedState::kAwaitingConfirm;
    event.reseed_required =
        kind == MappedEventKind::kDisplacedForFast ||
        kind == MappedEventKind::kInvalidatedForReseed;
    event.discard_reason = discard_reason;
    mapped_event_fn_(event);
  }
}

void PixelEngine::erase_mapped(std::size_t index,
                               MappedEventKind event_kind,
                               bool user_completion, bool reset_intent,
                               MappedDiscardReason discard_reason) {
  assert(index < mapped_operations_.size());
  MappedRuntime& operation = *mapped_operations_[index];
  if (operation.state == MappedState::kActive) {
    const auto execution = operation.operation->execution();
    const int x1 = std::min(execution.right + 1, config_.stride);
    const int y1 = std::min(execution.bottom + 1, config_.height);
    for (int y = execution.top; y < y1; ++y) {
      const std::size_t tight_row =
          static_cast<std::size_t>(y - execution.top) *
          static_cast<std::size_t>(operation.operation->width());
      std::uint16_t active_in_row = 0;
      for (int x = execution.left; x < x1; ++x) {
        const std::size_t lane =
            tight_row + static_cast<std::size_t>(x - execution.left);
        if (operation.fnum[lane] != kMappedSweepIdle) {
          operation.fnum[lane] = kMappedSweepIdle;
          ++active_in_row;
        }
      }
      assert(mapped_row_active_[static_cast<std::size_t>(y)] >= active_in_row);
      mapped_row_active_[static_cast<std::size_t>(y)] =
          static_cast<std::uint16_t>(
              mapped_row_active_[static_cast<std::size_t>(y)] - active_in_row);
      assert(mapped_active_px_ >= active_in_row);
      mapped_active_px_ -= active_in_row;
    }
  }
  if (reset_intent) {
    reset_mapped_intent(operation);
  }
  release_mapped_locks(operation);
  emit_mapped_event(event_kind, operation, discard_reason);
  switch (event_kind) {
    case MappedEventKind::kTerminal:
      break;
    case MappedEventKind::kConfirmed:
      ++stats_.mapped_confirmed;
      break;
    case MappedEventKind::kDiscarded:
      ++stats_.mapped_discarded;
      break;
    case MappedEventKind::kDisplacedForFast:
    case MappedEventKind::kInvalidatedForReseed:
    case MappedEventKind::kInvalidated:
      ++stats_.mapped_invalidated;
      break;
  }
  const std::uint64_t frame_id = operation.frame_id;
  auto retired = std::move(mapped_operations_[index]);
  mapped_operations_.erase(mapped_operations_.begin() +
                            static_cast<std::ptrdiff_t>(index));
  recycle_mapped_runtime(std::move(retired));
  recompute_mapped_clip();
  if (user_completion && frame_id != 0) {
    ++stats_.completions;
    if (completion_fn_) {
      completion_fn_(frame_id);
    }
  }
}

bool PixelEngine::discard_mapped_at(std::size_t index, bool superseded) {
  assert(index < mapped_operations_.size());
  MappedRuntime& operation = *mapped_operations_[index];
  const auto status = operation.history->discard(*operation.operation);
  if (status != XochitlHistoryState::FinalizeStatus::kDiscarded) {
    XochitlHistoryState* const history = operation.history;
    invalidate_mapped_owner(history);
    return false;
  }
  erase_mapped(index, MappedEventKind::kDiscarded, superseded, true,
               superseded ? MappedDiscardReason::kSupersededByNewer
                          : MappedDiscardReason::kExplicitCancel);
  if (superseded) {
    ++stats_.mapped_unstarted_superseded;
  }
  return true;
}

void PixelEngine::invalidate_mapped_owner(
    XochitlHistoryState* history, bool preserve_for_regional_reseed) {
  if (history == nullptr) {
    return;
  }
  if (preserve_for_regional_reseed) {
    history->invalidate_preserving_committed_for_reseed();
  } else {
    history->invalidate();
  }
  if (std::find(invalidated_histories_.begin(), invalidated_histories_.end(),
                history) == invalidated_histories_.end()) {
    invalidated_histories_.push_back(history);
  }
  reseeded_histories_.erase(
      std::remove(reseeded_histories_.begin(), reseeded_histories_.end(),
                  history),
      reseeded_histories_.end());
  mapped_history_invalid_ = true;
  if (!preserve_for_regional_reseed) {
    mapped_poison_regions_.push_back(MappedPoisonRegion{
        history,
        XochitlHistoryState::InclusiveRect{0, 0, config_.stride - 1,
                                            config_.height - 1},
        false});
  }
  for (std::size_t i = mapped_operations_.size(); i > 0; --i) {
    if (mapped_operations_[i - 1]->history == history) {
      const bool scanned = mapped_operations_[i - 1]->ever_emitted ||
                           mapped_operations_[i - 1]->state ==
                               MappedState::kAwaitingConfirm;
      if (scanned) {
        estimate_mapped_prev(*mapped_operations_[i - 1]);
        if (preserve_for_regional_reseed) {
          mapped_poison_regions_.push_back(MappedPoisonRegion{
              history, mapped_operations_[i - 1]->operation->execution(),
              true});
        }
      }
      erase_mapped(i - 1,
                   preserve_for_regional_reseed
                       ? MappedEventKind::kInvalidatedForReseed
                       : MappedEventKind::kInvalidated,
                   false, !scanned);
    }
  }
  rebuild_mapped_poison_tiles();
}

void PixelEngine::invalidate_mapped_owner_for_fast(
    XochitlHistoryState* history, const PlutoRect& fast_rect,
    MappedRecoveryToken recovery_token,
    const std::vector<MappedOperationToken>& displaced_tokens) {
  assert(history != nullptr && recovery_token != 0);
  history->invalidate_preserving_committed_for_reseed();
  if (std::find(invalidated_histories_.begin(), invalidated_histories_.end(),
                history) == invalidated_histories_.end()) {
    invalidated_histories_.push_back(history);
  }
  reseeded_histories_.erase(
      std::remove(reseeded_histories_.begin(), reseeded_histories_.end(),
                  history),
      reseeded_histories_.end());
  if (std::find(active_recoveries_.begin(), active_recoveries_.end(),
                recovery_token) == active_recoveries_.end()) {
    active_recoveries_.push_back(recovery_token);
  }
  mapped_history_invalid_ = true;

  const auto add_poison = [&](XochitlHistoryState::InclusiveRect execution) {
    const bool duplicate = std::any_of(
        mapped_poison_regions_.begin(), mapped_poison_regions_.end(),
        [&](const MappedPoisonRegion& poison) {
          return poison.history == history &&
                 poison.recovery_token == recovery_token &&
                 poison.execution == execution;
        });
    if (!duplicate) {
      mapped_poison_regions_.push_back(
          MappedPoisonRegion{history, execution, true, recovery_token});
    }
  };
  const int fast_width = (fast_rect.width + 7) & ~7;
  const int fast_height = (fast_rect.height + 1) & ~1;
  add_poison(XochitlHistoryState::InclusiveRect{
      fast_rect.x, fast_rect.y, fast_rect.x + fast_width - 1,
      fast_rect.y + fast_height - 1});

  for (std::size_t i = mapped_operations_.size(); i > 0; --i) {
    MappedRuntime& operation = *mapped_operations_[i - 1];
    if (operation.history != history) {
      continue;
    }
    const bool scanned = operation.ever_emitted ||
                         operation.state == MappedState::kAwaitingConfirm;
    operation.recovery_token = recovery_token;
    if (scanned) {
      estimate_mapped_prev(operation);
      add_poison(operation.operation->execution());
    }
    const bool displaced =
        !scanned &&
        std::find(displaced_tokens.begin(), displaced_tokens.end(),
                  operation.token) != displaced_tokens.end();
    erase_mapped(i - 1,
                 displaced ? MappedEventKind::kDisplacedForFast
                           : MappedEventKind::kInvalidatedForReseed,
                 false, !scanned);
  }
  rebuild_mapped_poison_tiles();
}

void PixelEngine::estimate_mapped_prev(const MappedRuntime& operation) {
  const auto execution = operation.operation->execution();
  const int x1 = std::min({execution.right + 1, config_.stride, config_.width});
  const int y1 = std::min(execution.bottom + 1, config_.height);
  for (int y = execution.top; y < y1; ++y) {
    const std::size_t tight_row =
        static_cast<std::size_t>(y - execution.top) *
        static_cast<std::size_t>(operation.operation->width());
    const std::size_t panel_row =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride);
    for (int x = execution.left; x < x1; ++x) {
      const std::size_t lane =
          tight_row + static_cast<std::size_t>(x - execution.left);
      if (!operation.operation->lane_selected(lane)) {
        continue;
      }
      const std::size_t px = panel_row + static_cast<std::size_t>(x);
      // Emergency grayscale uses the mapper's terminal drive as a conservative
      // restart approximation, including auxiliary 27/31. It is not a measured
      // mid-waveform state or committed logical A; prev_est + truncation debt
      // remain until a covering Fast terminal scan and regional A/B reseed.
      const std::uint8_t estimated_drive = static_cast<std::uint8_t>(
          operation.operation->lanes()[lane].transition & 31u);
      prev_[px] = estimated_drive;
      next_[px] = estimated_drive;
      final_[px] = estimated_drive;
      dc_.mark_prev_estimated(px);
    }
  }
  for (const std::uint32_t tile_index : operation.tile_indices) {
    dc_.charge_truncation(tile_index);
    ++stats_.truncations;
  }
}

void PixelEngine::rebuild_mapped_poison_tiles() {
  std::fill(mapped_poisoned_owner_.begin(), mapped_poisoned_owner_.end(),
            nullptr);
  mapped_poisoned_count_ = 0;
  const int tile_px = static_cast<int>(config_.tile_px);
  for (const MappedPoisonRegion& poison : mapped_poison_regions_) {
    const int left = std::max(0, poison.execution.left);
    const int top = std::max(0, poison.execution.top);
    const int right = std::min(config_.stride - 1, poison.execution.right);
    const int bottom = std::min(config_.height - 1, poison.execution.bottom);
    if (right < left || bottom < top) {
      continue;
    }
    const int tx0 = left / tile_px;
    const int tx1 = std::min(right / tile_px,
                             static_cast<int>(tile_cols_) - 1);
    const int ty0 = top / tile_px;
    const int ty1 = std::min(bottom / tile_px,
                             static_cast<int>(tile_rows_) - 1);
    for (int ty = ty0; ty <= ty1; ++ty) {
      for (int tx = tx0; tx <= tx1; ++tx) {
        const std::size_t tile = static_cast<std::size_t>(ty) * tile_cols_ +
                                 static_cast<std::size_t>(tx);
        if (mapped_poisoned_owner_[tile] == nullptr) {
          mapped_poisoned_owner_[tile] = poison.history;
          ++mapped_poisoned_count_;
        }
      }
    }
  }
}

void PixelEngine::clear_invalidated_history_if_resolved(
    XochitlHistoryState* history) {
  if (history == nullptr || !history->valid()) {
    return;
  }
  if (std::find(reseeded_histories_.begin(), reseeded_histories_.end(),
                history) == reseeded_histories_.end()) {
    return;
  }
  const bool still_poisoned = std::any_of(
      mapped_poisoned_owner_.begin(), mapped_poisoned_owner_.end(),
      [&](XochitlHistoryState* owner) { return owner == history; });
  if (still_poisoned) {
    return;
  }
  invalidated_histories_.erase(
      std::remove(invalidated_histories_.begin(), invalidated_histories_.end(),
                  history),
      invalidated_histories_.end());
  reseeded_histories_.erase(
      std::remove(reseeded_histories_.begin(), reseeded_histories_.end(),
                  history),
      reseeded_histories_.end());
  mapped_history_invalid_ = !invalidated_histories_.empty();
  active_recoveries_.erase(
      std::remove_if(active_recoveries_.begin(), active_recoveries_.end(),
                     [&](MappedRecoveryToken token) {
                       const bool poison_remains = std::any_of(
                           mapped_poison_regions_.begin(),
                           mapped_poison_regions_.end(),
                           [&](const MappedPoisonRegion& poison) {
                             return poison.recovery_token == token;
                           });
                       const bool operation_remains = std::any_of(
                           mapped_operations_.begin(), mapped_operations_.end(),
                           [&](const auto& operation) {
                             return operation->recovery_token == token;
                           });
                       return !poison_remains && !operation_remains;
                     }),
      active_recoveries_.end());
  latched_recoveries_.erase(
      std::remove_if(latched_recoveries_.begin(), latched_recoveries_.end(),
                     [&](MappedRecoveryToken token) {
                       return std::find(active_recoveries_.begin(),
                                        active_recoveries_.end(), token) ==
                              active_recoveries_.end();
                     }),
      latched_recoveries_.end());
  terminal_recoveries_.erase(
      std::remove_if(terminal_recoveries_.begin(),
                     terminal_recoveries_.end(),
                     [&](MappedRecoveryToken token) {
                       return std::find(active_recoveries_.begin(),
                                        active_recoveries_.end(), token) ==
                              active_recoveries_.end();
                     }),
      terminal_recoveries_.end());
}

bool PixelEngine::confirm_fast_recovery_latched(MappedRecoveryToken token) {
  if (token == 0 ||
      std::find(active_recoveries_.begin(), active_recoveries_.end(), token) ==
          active_recoveries_.end() ||
      std::find(terminal_recoveries_.begin(), terminal_recoveries_.end(),
                token) == terminal_recoveries_.end()) {
    return false;
  }
  if (std::find(latched_recoveries_.begin(), latched_recoveries_.end(), token) ==
      latched_recoveries_.end()) {
    latched_recoveries_.push_back(token);
  }
  terminal_recoveries_.erase(
      std::remove(terminal_recoveries_.begin(), terminal_recoveries_.end(),
                  token),
      terminal_recoveries_.end());
  return true;
}

bool PixelEngine::resolve_mapped_invalidation_after_reseed(
    XochitlHistoryState* history,
    XochitlHistoryState::InclusiveRect reseeded_update,
    MappedRecoveryToken recovery_token) {
  if (!configured_ || history == nullptr || !history->valid() ||
      recovery_token == 0 ||
      std::find(latched_recoveries_.begin(), latched_recoveries_.end(),
                recovery_token) == latched_recoveries_.end() ||
      std::find(invalidated_histories_.begin(), invalidated_histories_.end(),
                history) == invalidated_histories_.end() ||
      reseeded_update.left < 0 || reseeded_update.top < 0 ||
      reseeded_update.right < reseeded_update.left ||
      reseeded_update.bottom < reseeded_update.top ||
      reseeded_update.right >= config_.width ||
      reseeded_update.bottom >= config_.height) {
    return false;
  }
  if (std::any_of(mapped_poison_regions_.begin(), mapped_poison_regions_.end(),
                  [&](const MappedPoisonRegion& poison) {
                    return poison.history == history &&
                           poison.recovery_token == recovery_token &&
                           !poison.regional_reseed_allowed;
                  })) {
    return false;
  }
  const int logical_width =
      reseeded_update.right - reseeded_update.left + 1;
  const int logical_height =
      reseeded_update.bottom - reseeded_update.top + 1;
  const XochitlHistoryState::InclusiveRect execution{
      reseeded_update.left,
      reseeded_update.top,
      reseeded_update.left + ((logical_width + 7) & ~7) - 1,
      reseeded_update.top + ((logical_height + 1) & ~1) - 1,
  };
  bool matching_poison = false;
  for (const MappedPoisonRegion& poison : mapped_poison_regions_) {
    if (poison.history != history ||
        poison.recovery_token != recovery_token) {
      continue;
    }
    matching_poison = true;
    if (!poison.regional_reseed_allowed ||
        !inclusive_contains(execution, poison.execution)) {
      return false;
    }
  }
  if (!matching_poison) {
    return false;
  }
  const std::size_t before = mapped_poison_regions_.size();
  mapped_poison_regions_.erase(
      std::remove_if(mapped_poison_regions_.begin(),
                     mapped_poison_regions_.end(),
                     [&](const MappedPoisonRegion& poison) {
                       return poison.history == history &&
                              poison.recovery_token == recovery_token &&
                              poison.regional_reseed_allowed &&
                              inclusive_contains(execution, poison.execution);
                     }),
      mapped_poison_regions_.end());
  if (mapped_poison_regions_.size() == before) {
    return false;
  }
  rebuild_mapped_poison_tiles();
  if (std::find(reseeded_histories_.begin(), reseeded_histories_.end(),
                history) == reseeded_histories_.end()) {
    reseeded_histories_.push_back(history);
  }
  const int x1 = std::min(execution.right + 1, config_.width);
  const int y1 = std::min(execution.bottom + 1, config_.height);
  for (int y = execution.top; y < y1; ++y) {
    const std::size_t row =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride);
    for (int x = execution.left; x < x1; ++x) {
      const std::size_t px = row + static_cast<std::size_t>(x);
      next_[px] = prev_[px];
      final_[px] = prev_[px];
      dc_.clear_prev_estimated(px);
    }
  }
  activate_mapped_queue();
  return true;
}

MappedRecoveryToken PixelEngine::resolve_fast_mapped_conflicts(
    const PlutoRect& rect, AdmitOutcome* outcome) {
  std::vector<MappedOperationToken> displaced;
  std::vector<XochitlHistoryState*> histories;
  for (const auto& operation_ptr : mapped_operations_) {
    const MappedRuntime& operation = *operation_ptr;
    if (!mapped_operation_intersects(operation, rect)) {
      continue;
    }
    ++stats_.mapped_fast_conflicts;
    if (outcome != nullptr) {
      ++outcome->mapped_conflicts;
    }
    if (operation.state == MappedState::kQueued ||
        (operation.state == MappedState::kActive &&
         !operation.ever_emitted)) {
      displaced.push_back(operation.token);
    }
    if (std::find(histories.begin(), histories.end(), operation.history) ==
        histories.end()) {
      histories.push_back(operation.history);
    }
  }
  if (histories.empty()) {
    MappedRecoveryToken poison_token = 0;
    for (const MappedPoisonRegion& poison : mapped_poison_regions_) {
      const PlutoRect poisoned{
          poison.execution.left,
          poison.execution.top,
          poison.execution.right - poison.execution.left + 1,
          poison.execution.bottom - poison.execution.top + 1,
      };
      if (!poison.regional_reseed_allowed ||
          !rects_intersect(poisoned, rect)) {
        continue;
      }
      if (poison_token != 0 && poison_token != poison.recovery_token) {
        // One Fast frame cannot prove two unrelated recovery generations.
        return 0;
      }
      poison_token = poison.recovery_token;
    }
    if (poison_token != 0) {
      latched_recoveries_.erase(
          std::remove(latched_recoveries_.begin(),
                      latched_recoveries_.end(), poison_token),
          latched_recoveries_.end());
      if (outcome != nullptr) {
        outcome->mapped_reconcile_required = true;
        outcome->mapped_recovery_token = poison_token;
      }
    }
    return poison_token;
  }
  if (next_recovery_token_ == 0 ||
      next_recovery_token_ ==
          std::numeric_limits<MappedRecoveryToken>::max()) {
    for (XochitlHistoryState* history : histories) {
      invalidate_mapped_owner(history);
    }
    if (outcome != nullptr) {
      outcome->mapped_reconcile_required = true;
    }
    return 0;
  }
  const MappedRecoveryToken recovery_token = next_recovery_token_++;
  for (XochitlHistoryState* history : histories) {
    std::vector<MappedOperationToken> owner_displaced;
    for (const MappedOperationToken token : displaced) {
      const MappedRuntime* operation = find_mapped(token);
      if (operation != nullptr && operation->history == history) {
        owner_displaced.push_back(token);
      }
    }
    invalidate_mapped_owner_for_fast(history, rect, recovery_token,
                                     owner_displaced);
  }
  if (outcome != nullptr) {
    outcome->mapped_reconcile_required = true;
    outcome->mapped_recovery_token = recovery_token;
  }
  return recovery_token;
}

bool PixelEngine::admit_mapped(const MappedAdmitRequest& request,
                               MappedAdmitOutcome* outcome) {
  if (outcome != nullptr) {
    *outcome = MappedAdmitOutcome{};
  }
  if (!configured_ || request.operation == nullptr ||
      request.history == nullptr ||
      !request.history->owns(*request.operation) ||
      !request.history->admissible(*request.operation)) {
    return false;
  }
  const bool owner_invalidated =
      std::find(invalidated_histories_.begin(), invalidated_histories_.end(),
                request.history) != invalidated_histories_.end();
  if (!request.history->valid() ||
      (owner_invalidated && !request.reconcile_invalidated) ||
      (request.reconcile_invalidated && !owner_invalidated)) {
    return false;
  }
  if (request.reconcile_invalidated &&
      (request.recovery_token == 0 ||
       std::find(active_recoveries_.begin(), active_recoveries_.end(),
                 request.recovery_token) == active_recoveries_.end() ||
       std::find(latched_recoveries_.begin(), latched_recoveries_.end(),
                 request.recovery_token) == latched_recoveries_.end())) {
    return false;
  }
  const int mode = static_cast<int>(request.operation->mode());
  const int temp_bin = request.temp_bin >= 0 ? request.temp_bin : current_bin_;
  const int phase_count = waveform_->phase_count(mode, temp_bin);
  const std::span<const std::uint8_t> codes =
      waveform_->phase_record_codes(mode, temp_bin);
  const auto requested = request.operation->requested();
  const auto execution = request.operation->execution();
  const std::size_t expected_lanes =
      static_cast<std::size_t>(request.operation->width()) *
      static_cast<std::size_t>(request.operation->height());
  if (mode < 0 || temp_bin < 0 || temp_bin >= waveform_->temp_count() ||
      phase_count <= 0 || phase_count > static_cast<int>(kMappedSweepIdle) ||
      codes.size() != static_cast<std::size_t>(phase_count) *
                          kWaveformMatrixCells ||
      requested.left < 0 || requested.top < 0 ||
      requested.right < requested.left ||
      requested.bottom < requested.top || requested.right >= config_.width ||
      requested.bottom >= config_.height || execution.left < 0 ||
      execution.top < 0 || execution.right < execution.left ||
      execution.bottom < execution.top || execution.left >= config_.stride ||
      execution.top >= config_.height ||
      request.operation->lanes().size() != expected_lanes ||
      (!request.operation->lane_mask().empty() &&
       request.operation->lane_mask().size() != expected_lanes) ||
      expected_lanes == 0 ||
      expected_lanes > std::numeric_limits<std::uint32_t>::max() ||
      next_mapped_token_ == 0 ||
      next_mapped_token_ == std::numeric_limits<MappedOperationToken>::max()) {
    return false;
  }
  for (const auto& existing : mapped_operations_) {
    if (existing->history == request.history &&
        existing->operation->operation_id() ==
            request.operation->operation_id()) {
      return false;
    }
  }

  auto candidate = acquire_mapped_runtime();
  ScopeExit recycle_candidate([&] {
    if (candidate != nullptr) {
      recycle_mapped_runtime(std::move(candidate));
    }
  });
  candidate->token = next_mapped_token_++;
  candidate->frame_id = request.frame_id;
  candidate->retry_cookie = request.retry_cookie;
  candidate->recovery_token = request.recovery_token;
  candidate->mode = mode;
  candidate->temp_bin = temp_bin;
  candidate->codes = codes.data();
  candidate->phase_count = phase_count;
  candidate->history = request.history;
  candidate->operation = request.operation;
  candidate->reconcile_invalidated = request.reconcile_invalidated;

  const int tile_px = static_cast<int>(config_.tile_px);
  const int tx0 = execution.left / tile_px;
  const int tx1 = std::min((std::min(execution.right, config_.stride - 1) /
                            tile_px),
                           static_cast<int>(tile_cols_) - 1);
  const int ty0 = execution.top / tile_px;
  const int ty1 = std::min((std::min(execution.bottom, config_.height - 1) /
                            tile_px),
                           static_cast<int>(tile_rows_) - 1);
  for (int ty = ty0; ty <= ty1; ++ty) {
    for (int tx = tx0; tx <= tx1; ++tx) {
      candidate->tile_indices.push_back(
          static_cast<std::uint32_t>(ty) * tile_cols_ +
          static_cast<std::uint32_t>(tx));
    }
  }
  if (candidate->tile_indices.empty()) {
    return false;
  }
  for (const std::uint32_t tile_index : candidate->tile_indices) {
    if (mapped_poisoned_owner_[tile_index] != nullptr &&
        !mapped_reconcile_covers_tile_poison(*candidate, tile_index)) {
      const auto discarded = request.history->discard(*request.operation);
      if (discarded != XochitlHistoryState::FinalizeStatus::kDiscarded) {
        invalidate_mapped_owner(request.history);
      }
      if (outcome != nullptr) {
        outcome->status = MappedAdmitStatus::kConflictPartial;
      }
      return false;
    }
  }

  ++stats_.mapped_admissions;
  // An operation that has entered a built phase owns real optical state. A
  // precomputed overlapping successor is necessarily based on the old A/B and
  // cannot be queued/rebased safely; consume its journal and ask the presenter
  // to prepare again after the predecessor commits or is reconciled.
  for (const auto& existing : mapped_operations_) {
    if (mapped_operations_overlap(*existing, *candidate) &&
        (existing->state == MappedState::kAwaitingConfirm ||
         (existing->state == MappedState::kActive &&
          existing->ever_emitted))) {
      (void)request.history->discard(*request.operation);
      if (outcome != nullptr) {
        outcome->status = MappedAdmitStatus::kConflictScanned;
      }
      return false;
    }
  }

  for (const auto& existing : mapped_operations_) {
    if (mapped_operations_overlap(*existing, *candidate) ||
        !mapped_history_regions_overlap(*existing, *candidate)) {
      continue;
    }
    const auto discarded = request.history->discard(*request.operation);
    if (discarded != XochitlHistoryState::FinalizeStatus::kDiscarded) {
      invalidate_mapped_owner(request.history);
    }
    if (outcome != nullptr) {
      outcome->status = MappedAdmitStatus::kConflictHistoryRegion;
    }
    return false;
  }

  // Whole immutable journals cannot be clipped. Newest-wins replacement is
  // therefore legal only when the candidate covers every selected lane of
  // every intersecting unstarted predecessor. A partial overlap leaves the
  // predecessor intact and consumes the candidate so no older-only pixel or
  // completion obligation is lost.
  for (const auto& existing : mapped_operations_) {
    if (!mapped_operations_overlap(*existing, *candidate)) {
      continue;
    }
    if (!mapped_operation_covers(*candidate->operation,
                                 *existing->operation)) {
      const auto discarded = request.history->discard(*request.operation);
      if (discarded != XochitlHistoryState::FinalizeStatus::kDiscarded) {
        invalidate_mapped_owner(request.history);
      }
      if (outcome != nullptr) {
        outcome->status = MappedAdmitStatus::kConflictPartial;
      }
      return false;
    }
  }

  std::uint32_t superseded = 0;
  for (std::size_t i = mapped_operations_.size(); i > 0; --i) {
    const MappedRuntime& existing = *mapped_operations_[i - 1];
    if (!mapped_operations_overlap(existing, *candidate)) {
      continue;
    }
    assert(existing.state == MappedState::kQueued ||
           (existing.state == MappedState::kActive &&
            !existing.ever_emitted));
    if (!discard_mapped_at(i - 1, true)) {
      // discard_mapped_at invalidated this history owner on failure, which
      // also consumed candidate's journal when both share the owner.
      if (outcome != nullptr) {
        outcome->status = MappedAdmitStatus::kRejected;
      }
      return false;
    }
    ++superseded;
  }

  // Conflict checks touch only immutable geometry and tile ownership. Allocate
  // the full lane cursor only once admission is certain; rejected full-panel
  // candidates therefore neither dirty nor evict the pooled hot allocation.
  if (request.operation->lane_mask().empty()) {
    candidate->fnum.assign(expected_lanes, 0);
  } else {
    candidate->fnum.resize(expected_lanes);
    std::transform(request.operation->lane_mask().begin(),
                   request.operation->lane_mask().end(),
                   candidate->fnum.begin(), [](std::uint8_t selected) {
                     return selected != 0u ? std::uint8_t{0}
                                           : kMappedSweepIdle;
                   });
  }
  candidate->guard_dc.assign(
      mapped_guard_lane_count(execution, request.operation->width(), config_),
      0);

  const MappedOperationToken token = candidate->token;
  mapped_operations_.push_back(std::move(candidate));
  recycle_candidate.release();
  MappedRuntime& admitted = *mapped_operations_.back();
  const bool start = mapped_can_start(admitted);
  if (start) {
    activate_mapped(admitted);
  } else {
    ++stats_.mapped_queued;
  }
  if (outcome != nullptr) {
    outcome->status = start ? MappedAdmitStatus::kStarted
                            : MappedAdmitStatus::kQueued;
    outcome->token = token;
    outcome->superseded_unstarted = superseded;
  }
  return true;
}

MappedFinalizeStatus PixelEngine::confirm_mapped(MappedOperationToken token) {
  const std::size_t index = find_mapped_index(token);
  if (index == mapped_operations_.size()) {
    return MappedFinalizeStatus::kUnknownToken;
  }
  MappedRuntime& operation = *mapped_operations_[index];
  if (operation.state != MappedState::kAwaitingConfirm) {
    return MappedFinalizeStatus::kNotTerminal;
  }
  const auto committed = operation.history->commit(*operation.operation);
  if (committed != XochitlHistoryState::FinalizeStatus::kCommitted) {
    XochitlHistoryState* const history = operation.history;
    invalidate_mapped_owner(history);
    return MappedFinalizeStatus::kHistoryFailure;
  }

  const auto execution = operation.operation->execution();
  const int x1 = std::min({execution.right + 1, config_.stride, config_.width});
  const int y1 = std::min(execution.bottom + 1, config_.height);
  for (int y = execution.top; y < y1; ++y) {
    const std::size_t tight_row =
        static_cast<std::size_t>(y - execution.top) *
        static_cast<std::size_t>(operation.operation->width());
    const std::size_t panel_row =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride);
    for (int x = execution.left; x < x1; ++x) {
      const std::size_t lane =
          tight_row + static_cast<std::size_t>(x - execution.left);
      if (!operation.operation->lane_selected(lane)) {
        continue;
      }
      const std::size_t px = panel_row + static_cast<std::size_t>(x);
      const std::uint8_t logical = static_cast<std::uint8_t>(
          operation.operation->lanes()[lane].a2 & 31u);
      prev_[px] = logical;
      next_[px] = logical;
      final_[px] = logical;
      dc_.clear_prev_estimated(px);
      if (dc_.balanced_mode(operation.mode)) {
        dc_.dc_data()[px] = 0;
      }
    }
  }
  XochitlHistoryState* const history = operation.history;
  erase_mapped(index, MappedEventKind::kConfirmed, true, false);
  clear_invalidated_history_if_resolved(history);
  activate_mapped_queue();
  return MappedFinalizeStatus::kConfirmed;
}

MappedFinalizeStatus PixelEngine::discard_mapped(MappedOperationToken token) {
  const std::size_t index = find_mapped_index(token);
  if (index == mapped_operations_.size()) {
    return MappedFinalizeStatus::kUnknownToken;
  }
  const MappedRuntime& operation = *mapped_operations_[index];
  if (operation.state == MappedState::kAwaitingConfirm ||
      operation.ever_emitted) {
    return MappedFinalizeStatus::kAlreadyScanned;
  }
  if (!discard_mapped_at(index, false)) {
    return MappedFinalizeStatus::kHistoryFailure;
  }
  activate_mapped_queue();
  return MappedFinalizeStatus::kDiscarded;
}

MappedFinalizeStatus PixelEngine::invalidate_mapped(
    MappedOperationToken token) {
  MappedRuntime* const operation = find_mapped(token);
  if (operation == nullptr) {
    return MappedFinalizeStatus::kUnknownToken;
  }
  XochitlHistoryState* const history = operation->history;
  invalidate_mapped_owner(history);
  return MappedFinalizeStatus::kInvalidated;
}

bool PixelEngine::confirm_safe_fast_latched(
    const FastCoverage& coverage,
    std::span<const std::uint8_t> confirmed_bits,
    std::size_t confirmed_stride_bytes) {
  const PlutoRect rect = coverage.rect();
  if (!configured_ || !coverage.valid() || rect.x < 0 || rect.y < 0 ||
      rect.x + rect.width > config_.width ||
      rect.y + rect.height > config_.height) {
    return false;
  }
  const std::size_t row_bytes =
      (static_cast<std::size_t>(rect.width) + 7u) / 8u;
  if (confirmed_stride_bytes < row_bytes ||
      (rect.height > 1 &&
       static_cast<std::size_t>(rect.height - 1) >
           (std::numeric_limits<std::size_t>::max() - row_bytes) /
               confirmed_stride_bytes) ||
      confirmed_bits.size() <
          static_cast<std::size_t>(rect.height - 1) *
                  confirmed_stride_bytes +
              row_bytes) {
    return false;
  }
  const auto selected = [&](int x, int y) {
    const std::size_t local_x = static_cast<std::size_t>(x - rect.x);
    return (confirmed_bits[static_cast<std::size_t>(y - rect.y) *
                               confirmed_stride_bytes +
                           local_x / 8u] &
            static_cast<std::uint8_t>(1u << (local_x & 7u))) != 0;
  };

  // Preflight makes malformed masks atomic. A newer active/terminal recovery
  // is not an error: its per-lane generation simply will not match this older
  // coverage and therefore remains fenced.
  for (int y = rect.y; y < rect.y + rect.height; ++y) {
    std::size_t px =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride) +
        static_cast<std::size_t>(rect.x);
    for (int x = rect.x; x < rect.x + rect.width; ++x, ++px) {
      if (!selected(x, y)) {
        continue;
      }
      if (!coverage.driven(x, y)) {
        return false;
      }
    }
  }
  for (int y = rect.y; y < rect.y + rect.height; ++y) {
    std::size_t px =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride) +
        static_cast<std::size_t>(rect.x);
    for (int x = rect.x; x < rect.x + rect.width; ++x, ++px) {
      if (!selected(x, y)) {
        continue;
      }
      const std::uint32_t generation =
          coverage.recovery_generation(x, y);
      if (generation == 0 ||
          fast_rebase_pending_generation_[px] != generation) {
        continue;
      }
      fast_rebase_pending_generation_[px] = 0;
      dc_.clear_prev_estimated(px);
    }
  }
  return true;
}

const std::uint8_t *PixelEngine::update_level_row(const Update &update,
                                                  int y) const {
  if ((update.flags & kAdmitFlagGuardNull) != 0) {
    return nullptr;
  }
  const std::uint8_t *base;
  std::size_t pitch;
  if (update.retained_size != 0) {
    base = update.retained_data();
    pitch = static_cast<std::size_t>(update.rect.width);
  } else {
    base = update.borrow;
    pitch = update.borrow_stride;
  }
  return base + static_cast<std::size_t>(y - update.rect.y) * pitch;
}

std::uint8_t PixelEngine::target_level(const Update &update, int x, int y,
                                       std::size_t px) const {
  if ((update.flags & kAdmitFlagGuardNull) != 0) {
    return prev_[px]; // null transition: drive back to the glass state
  }
  const std::uint8_t *row = update_level_row(update, y);
  return static_cast<std::uint8_t>(row[x - update.rect.x] & 0x1f);
}

bool PixelEngine::force_identity(const Update &update) const {
  if ((update.flags & (kAdmitFlagForceIdentity | kAdmitFlagGuardNull)) != 0) {
    return true;
  }
  return (update.flags & kAdmitFlagSettle) != 0 &&
         config_.settle_force_identity;
}

void PixelEngine::retain_payload(Update &update) {
  if (update.retained_size != 0 || (update.flags & kAdmitFlagGuardNull) != 0) {
    return;
  }
  const std::size_t retained_size =
      static_cast<std::size_t>(update.rect.width) * update.rect.height;
  std::uint8_t *retained = update.retain(retained_size);
  for (int y = 0; y < update.rect.height; ++y) {
    std::memcpy(retained + static_cast<std::size_t>(y) *
                               static_cast<std::size_t>(update.rect.width),
                update.borrow +
                    static_cast<std::size_t>(y) * update.borrow_stride,
                static_cast<std::size_t>(update.rect.width));
  }
  update.borrow = nullptr;
  update.borrow_stride = 0;
}

std::uint32_t PixelEngine::alloc_update(const AdmitRequest &request) {
  std::uint32_t index;
  if (!free_updates_.empty()) {
    index = free_updates_.back();
    free_updates_.pop_back();
  } else {
    index = static_cast<std::uint32_t>(updates_.size());
    updates_.emplace_back();
  }
  Update &update = updates_[index];
  update.frame_id = request.frame_id;
  update.flags = request.flags;
  update.mode = request.mode;
  update.temp_bin = request.temp_bin >= 0 ? request.temp_bin : current_bin_;
  update.pending = 0;
  update.recovery_token = 0;
  update.fast_coverage = request.fast_coverage;
  update.fast_recovery_generation = 0;
  if ((request.flags & kAdmitFlagFastRailRebase) != 0) {
    update.fast_recovery_generation = next_fast_recovery_generation_++;
  }
  update.live = true;
  update.rect = request.rect;
  update.clear_retained();
  update.borrow = request.levels;
  update.borrow_stride = request.levels_stride != 0
                             ? request.levels_stride
                             : static_cast<std::size_t>(request.rect.width);
  return index;
}

void PixelEngine::release_update(std::uint32_t update_index) {
  Update &update = updates_[update_index];
  update.live = false;
  update.clear_retained();
  update.borrow = nullptr;
  update.fast_coverage.reset();
  free_updates_.push_back(update_index);
}

void PixelEngine::subscribe(std::uint32_t tile_index,
                            std::uint32_t update_index) {
  tile_subscribers_[tile_index].push_back(update_index);
  ++updates_[update_index].pending;
}

void PixelEngine::grow_clip(const PlutoRect &sub) {
  const int y0 = sub.y;
  const int y1 = sub.y + sub.height - 1;
  if (clip_min_row_ > clip_max_row_) {
    clip_min_row_ = y0;
    clip_max_row_ = y1;
    return;
  }
  clip_min_row_ = std::min(clip_min_row_, y0);
  clip_max_row_ = std::max(clip_max_row_, y1);
}

void PixelEngine::shrink_clip() {
  if (total_active_px_ == 0) {
    clip_min_row_ = 0;
    clip_max_row_ = -1;
    return;
  }
  while (clip_min_row_ <= clip_max_row_ && row_active_[clip_min_row_] == 0) {
    ++clip_min_row_;
  }
  while (clip_max_row_ >= clip_min_row_ && row_active_[clip_max_row_] == 0) {
    --clip_max_row_;
  }
}

bool PixelEngine::targets_equal(const Update &update,
                                const PlutoRect &sub) const {
  for (int y = sub.y; y < sub.y + sub.height; ++y) {
    const std::uint8_t *row = update_level_row(update, y);
    std::size_t px =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride) +
        static_cast<std::size_t>(sub.x);
    for (int x = sub.x; x < sub.x + sub.width; ++x, ++px) {
      if (static_cast<std::uint8_t>(row[x - update.rect.x] & 0x1f) !=
          final_[px]) {
        return false;
      }
    }
  }
  return true;
}

void PixelEngine::start_tile(std::uint32_t tile_index,
                             std::uint32_t update_index, const PlutoRect &sub,
                             AdmitOutcome *outcome) {
  Update &update = updates_[update_index];
  TileState &tile = tiles_[tile_index];
  assert(tile.active_px == 0);

  int mode = update.mode;
  std::uint8_t tile_flags = 0;
  if ((update.flags & kAdmitFlagSettle) != 0) {
    tile_flags |= kTileFlagSettle;
  }
  if ((update.flags & kAdmitFlagGuardNull) != 0) {
    tile_flags |= kTileFlagGuard;
  }
  if ((update.flags & (kAdmitFlagPen | kAdmitFlagPenPreview)) != 0) {
    tile_flags |= kTileFlagPenPriority;
  }
  // DC stress gate: stress above dc_stress_force forces this
  // tile's next SETTLE into a balanced quality mode. Settle-only (sentinel
  // settles and renderer quality settles): promoting live content
  // admissions made every stressed tile flash the GC16 develop
  // mid-interaction (a mosaic of black squares across the changed region on
  // every view switch). The renderer's settle planner reads its own stress
  // ledger, so stressed tiles are guaranteed a settle admission shortly
  // after quiescence — the balance pass rides that instead, and the DC
  // protection horizon (minutes) is unaffected by the ~1 s deferral.
  if (config_.promote_regional_stress &&
      (update.flags & (kAdmitFlagSettle | kAdmitFlagQuality)) != 0 &&
      dc_.forces_balanced(tile_index) && !dc_.balanced_mode(mode) &&
      waveform_->phase_count(config_.stress_balanced_mode, update.temp_bin) >
          0) {
    mode = config_.stress_balanced_mode;
    tile_flags |= kTileFlagStressPromoted;
    ++stats_.stress_promotions;
  }

  const int bin = update.temp_bin;
  const LutRecord *record = lut_cache_->pin(mode, bin);
  assert(record != nullptr && "admission validated the mode");
  if (record == nullptr) {
    return;
  }

  const bool force = force_identity(update);
  const bool guard = (update.flags & kAdmitFlagGuardNull) != 0;
  const bool sparkle = (update.flags & kAdmitFlagSparkle) != 0;
  const bool develop = (update.flags & kAdmitFlagSparkleDevelop) != 0;
  const bool fast_rail_rebase = (update.flags & kAdmitFlagFastRailRebase) != 0;
  const std::uint32_t sparkle_phase =
      (update.flags & kAdmitSparklePhaseMask) >> kAdmitSparklePhaseShift;
  std::uint32_t started = 0;
  bool rebased = false;
  const bool vector_fast_rail =
      fast_rail_rebase && dc_.prev_estimated_count() == 0 && sub.width <= 64;
  if (vector_fast_rail) {
    // Safe Fast establishes certified opposite-rail transitions. With no
    // pre-existing estimates, initialize the inactive tile a row at a time;
    // the kernel returns exact masks so the rare arbitrary-prev rebase keeps
    // the same DC/generation bookkeeping as the scalar reference below.
    for (int y = sub.y; y < sub.y + sub.height; ++y) {
      const std::uint8_t *row = update_level_row(update, y);
      const std::size_t px0 = static_cast<std::size_t>(y) *
                                  static_cast<std::size_t>(config_.stride) +
                              static_cast<std::size_t>(sub.x);
      const FastRailStartRowResult initialized = fast_rail_start_row(
          row + (sub.x - update.rect.x), prev_.data() + px0, next_.data() + px0,
          final_.data() + px0, fnum_.data() + px0, waveform_drove_.data() + px0,
          sub.width);
      const std::uint32_t row_started =
          static_cast<std::uint32_t>(__builtin_popcountll(initialized.started));
      started += row_started;
      row_active_[y] = static_cast<std::uint16_t>(row_active_[y] + row_started);
      std::uint64_t rebase = initialized.rebased;
      while (rebase != 0) {
        const int lane = __builtin_ctzll(rebase);
        rebase &= rebase - 1;
        const std::size_t px = px0 + static_cast<std::size_t>(lane);
        dc_.mark_prev_estimated(px);
        fast_rebase_pending_generation_[px] = update.fast_recovery_generation;
        rebased = true;
      }
    }
  } else {
    for (int y = sub.y; y < sub.y + sub.height; ++y) {
      const std::uint8_t *row =
          (guard || sparkle) ? nullptr : update_level_row(update, y);
      std::size_t px = static_cast<std::size_t>(y) *
                           static_cast<std::size_t>(config_.stride) +
                       static_cast<std::size_t>(sub.x);
      for (int x = sub.x; x < sub.x + sub.width; ++x, ++px) {
        std::uint8_t target;
        bool develop_start = false;
        if (sparkle) {
          // Sparkle ghost repair: drive ONLY the white-family pixels whose
          // low-discrepancy (R2) spatial slot matches this pass's phase —
          // scattered single pixels, invisible per pass, a full rotation
          // covers every white pixel with no flash. target == prev for
          // everything else, so those pixels simply never start.
          const std::uint32_t hash =
              static_cast<std::uint32_t>(x) * 3242174889u +
              static_cast<std::uint32_t>(y) * 2447445413u;
          // Top-off rotations mask 1/16 (hash top nibble); develop rotations
          // 1/256 (top byte) — each masked pixel runs a GC16 inversion, so
          // the mask must stay at paper-grain density.
          const bool masked =
              (develop ? (hash >> 24) : (hash >> 28)) == sparkle_phase;
          if (develop) {
            // Per-pixel white develop (color glass): the whole white family
            // re-develops to TRUE white — identity 30->30 included, because
            // the yellow cast lives in pixels whose LEDGER level is already
            // white; only the GC16 develop resets the pigment stack.
            develop_start = masked && prev_[px] >= kSparkleMinLevel;
            target = develop_start ? kSparkleDevelopTargetLevel : prev_[px];
          } else {
            // Lift ONLY under-white pixels (rail whites / ghosted
            // near-whites, 27..28). Pixels at or above the target stay
            // untouched: pulling a developed white (30/31) DOWN to the
            // 4-phase top-off endpoint dims it — on Gallery-3 glass that
            // under-developed state reads warm yellow — and re-driving 29
            // each rotation injects DC for nothing.
            target = (masked && prev_[px] >= kSparkleMinLevel &&
                      prev_[px] < kSparkleTargetLevel)
                         ? kSparkleTargetLevel
                         : prev_[px];
          }
        } else if (guard) {
          target = prev_[px];
        } else {
          target = static_cast<std::uint8_t>(row[x - update.rect.x] & 0x1f);
        }
        final_[px] = target;
        next_[px] = target;
        bool should_start =
            target != prev_[px] || (force && !sparkle) || develop_start;
        if (fast_rail_rebase) {
          const bool estimated = dc_.prev_estimated(px);
          should_start = target != prev_[px] || estimated;
          if (should_start) {
            const std::uint8_t opposite = target == kMode7FastBlackEndpoint
                                              ? kMode7FastWhiteEndpoint
                                              : kMode7FastBlackEndpoint;
            if (prev_[px] != opposite) {
              prev_[px] = opposite;
              dc_.mark_prev_estimated(px);
              fast_rebase_pending_generation_[px] =
                  update.fast_recovery_generation;
              rebased = true;
            } else if (estimated) {
              fast_rebase_pending_generation_[px] =
                  update.fast_recovery_generation;
              rebased = true;
            }
          }
        }
        if (should_start) {
          waveform_drove_[px] = 0;
          fnum_[px] = 0;
          ++started;
          ++row_active_[y];
        }
      }
    }
  }

  if (started == 0) {
    lut_cache_->unpin(mode, bin);
    if (outcome != nullptr) {
      ++outcome->noop_tiles;
    }
    return;
  }

  if (rebased) {
    dc_.charge_truncation(tile_index);
    ++stats_.fast_rail_rebases;
  }

  tile.mode = static_cast<std::uint8_t>(mode);
  tile.temp_bin = static_cast<std::uint8_t>(bin);
  tile.flags = tile_flags;
  tile.active_px = static_cast<std::uint16_t>(started);
  tile.admit_frame = static_cast<std::uint32_t>(frame_);
  tile.complete_frame = static_cast<std::uint32_t>(frame_) +
                        static_cast<std::uint32_t>(record->phase_count);
  tile.update_index = update_index;
  total_active_px_ += started;
  grow_clip(sub);
  subscribe(tile_index, update_index);
  if (hooks_ != nullptr) {
    hooks_->on_tile_start(tile_index, mode);
  }
  ++stats_.tiles_started;
  if (outcome != nullptr) {
    ++outcome->started_tiles;
  }
}

void PixelEngine::retarget_tile(std::uint32_t tile_index,
                                std::uint32_t update_index,
                                const PlutoRect &sub, AdmitOutcome *outcome) {
  Update &update = updates_[update_index];
  TileState &tile = tiles_[tile_index];
  const LutRecord *record = lut_cache_->peek(tile.mode, tile.temp_bin);
  assert(record != nullptr && "pinned record must be resident");

  const bool force = force_identity(update);
  const bool guard = (update.flags & kAdmitFlagGuardNull) != 0;
  const bool fast_rail_rebase =
      (update.flags & kAdmitFlagFastRailRebase) != 0;
  std::uint32_t started = 0;
  bool truncated = false;
  bool rebased = false;
  for (int y = sub.y; y < sub.y + sub.height; ++y) {
    const std::uint8_t *row = guard ? nullptr : update_level_row(update, y);
    std::size_t px =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride) +
        static_cast<std::size_t>(sub.x);
    for (int x = sub.x; x < sub.x + sub.width; ++x, ++px) {
      const std::uint8_t target =
          guard ? prev_[px]
                : static_cast<std::uint8_t>(row[x - update.rect.x] & 0x1f);
      final_[px] = target;
      if (fnum_[px] == kFnumIdle) {
        next_[px] = target;
        const bool estimated = dc_.prev_estimated(px);
        bool should_start = target != prev_[px] || force;
        if (fast_rail_rebase) {
          should_start = target != prev_[px] || estimated;
          if (should_start) {
            const std::uint8_t opposite =
                target == kMode7FastBlackEndpoint
                    ? kMode7FastWhiteEndpoint
                    : kMode7FastBlackEndpoint;
            if (prev_[px] != opposite) {
              prev_[px] = opposite;
              dc_.mark_prev_estimated(px);
              fast_rebase_pending_generation_[px] =
                  update.fast_recovery_generation;
              rebased = true;
            } else if (estimated) {
              fast_rebase_pending_generation_[px] =
                  update.fast_recovery_generation;
              rebased = true;
            }
          }
        }
        if (should_start) {
          waveform_drove_[px] = 0;
          fnum_[px] = 0;
          ++started;
          ++row_active_[y];
        }
      } else if (next_[px] != target) {
        // Mid-sequence truncation (rail-only): estimate prev as the
        // rail the truncated prefix was pushing toward, mark it estimated,
        // and restart toward the new target. The accumulated dc impulse
        // stays on the ledger (deviation model).
        prev_[px] = next_[px];
        dc_.mark_prev_estimated(px);
        if (fast_rail_rebase) {
          fast_rebase_pending_generation_[px] =
              update.fast_recovery_generation;
        }
        next_[px] = target;
        waveform_drove_[px] = 0;
        fnum_[px] = 0;
        truncated = true;
      }
      // else: already heading to the same target — continue in place.
    }
  }

  tile.active_px = static_cast<std::uint16_t>(tile.active_px + started);
  total_active_px_ += started;
  if (started > 0) {
    grow_clip(sub);
  }
  if (truncated) {
    dc_.charge_truncation(tile_index);
    ++stats_.truncations;
  }
  if (rebased) {
    dc_.charge_truncation(tile_index);
    ++stats_.fast_rail_rebases;
  }
  tile.update_index = update_index;
  tile.admit_frame = static_cast<std::uint32_t>(frame_);
  tile.complete_frame = static_cast<std::uint32_t>(frame_) +
                        static_cast<std::uint32_t>(record->phase_count);
  subscribe(tile_index, update_index);
  ++stats_.tiles_retargeted;
  if (outcome != nullptr) {
    ++outcome->retargeted_tiles;
  }
}

bool PixelEngine::pen_preview_covers_active_tile(std::uint32_t tile_index,
                                                 const PlutoRect &sub) const {
  const int tile_px = static_cast<int>(config_.tile_px);
  const int tx = static_cast<int>(tile_index % tile_cols_);
  const int ty = static_cast<int>(tile_index / tile_cols_);
  const int x0 = tx * tile_px;
  const int x1 = std::min(x0 + tile_px, config_.width);
  const int y0 = ty * tile_px;
  const int y1 = std::min(y0 + tile_px, config_.height);
  for (int y = y0; y < y1; ++y) {
    std::size_t px =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride) +
        static_cast<std::size_t>(x0);
    for (int x = x0; x < x1; ++x, ++px) {
      if (fnum_[px] == kFnumIdle) {
        continue;
      }
      if (x < sub.x || x >= sub.x + sub.width || y < sub.y ||
          y >= sub.y + sub.height) {
        return false;
      }
    }
  }
  return true;
}

void PixelEngine::preempt_tile_for_pen_preview(std::uint32_t tile_index) {
  TileState &tile = tiles_[tile_index];
  assert(tile.active_px != 0);
  const int tile_px = static_cast<int>(config_.tile_px);
  const int tx = static_cast<int>(tile_index % tile_cols_);
  const int ty = static_cast<int>(tile_index / tile_cols_);
  const int x0 = tx * tile_px;
  const int x1 = std::min(x0 + tile_px, config_.width);
  const int y0 = ty * tile_px;
  const int y1 = std::min(y0 + tile_px, config_.height);
  std::uint32_t truncated = 0;
  for (int y = y0; y < y1; ++y) {
    std::size_t px =
        static_cast<std::size_t>(y) * static_cast<std::size_t>(config_.stride) +
        static_cast<std::size_t>(x0);
    for (int x = x0; x < x1; ++x, ++px) {
      if (fnum_[px] == kFnumIdle) {
        continue;
      }
      // Admission runs between scan frames. Estimate the interrupted
      // optical state at the old target rail and restart from there; the
      // later Text/Full truth repays the approximation and DC ledger.
      prev_[px] = next_[px];
      dc_.mark_prev_estimated(px);
      fnum_[px] = kFnumIdle;
      waveform_drove_[px] = 0;
      --row_active_[y];
      --total_active_px_;
      ++truncated;
    }
  }
  assert(truncated == tile.active_px);
  (void)truncated;
  for (const std::uint32_t update_index : tile_subscribers_[tile_index]) {
    assert(updates_[update_index].pending > 0);
    --updates_[update_index].pending;
  }
  tile_subscribers_[tile_index].clear();
  lut_cache_->unpin(tile.mode, tile.temp_bin);
  tile.active_px = 0;
  tile.update_index = kNoUpdate;
  tile.flags = 0;
  dc_.charge_truncation(tile_index);
  ++stats_.truncations;
  ++stats_.pen_cross_mode_preemptions;
  shrink_clip();
}

void PixelEngine::process_piece(std::uint32_t update_index,
                                const PlutoRect &rect, bool allow_split,
                                AdmitOutcome *outcome) {
  Update &update = updates_[update_index];
  const bool pen = (update.flags & (kAdmitFlagPen | kAdmitFlagPenPreview)) != 0;
  const bool pen_preview =
      (update.flags & kAdmitFlagPenPreview) != 0;
  const bool guard = (update.flags & kAdmitFlagGuardNull) != 0;
  // Sparkle: budget/band-exempt (it activates ~1/16 of near-white pixels,
  // a fraction of any rect's area) and strictly best-effort on busy tiles
  // (skip, never park — the trickle's later rotations retry).
  const bool sparkle = (update.flags & kAdmitFlagSparkle) != 0;

  if (allow_split && !pen && !sparkle) {
    // Pixel-based admission pacing (PEN budget-exempt).
    if (total_active_px_ >= config_.max_active_px) {
      retain_payload(update);
      PendingPiece piece;
      piece.kind = PieceKind::kBudget;
      piece.update_index = update_index;
      piece.rect = rect;
      pending_pieces_.push_back(piece);
      ++update.pending;
      ++stats_.budget_deferrals;
      if (outcome != nullptr) {
        outcome->budget_deferred = true;
      }
      return;
    }
    // Full-field flash amortization: top-to-bottom row-band slices
    // over consecutive scan frames, <= full_flash_band_frames onset stagger.
    // Split points snap to the global tile grid so no tile straddles two
    // staggered bands (a straddled tile would self-park its second half
    // behind its first for a whole waveform).
    const std::uint64_t area = static_cast<std::uint64_t>(rect.width) *
                               static_cast<std::uint64_t>(rect.height);
    if (area > config_.max_active_px) {
      const std::uint64_t needed =
          (area + config_.max_active_px - 1) / config_.max_active_px;
      const std::uint32_t bands = static_cast<std::uint32_t>(
          std::min<std::uint64_t>(needed, config_.full_flash_band_frames));
      const int tile_px = static_cast<int>(config_.tile_px);
      std::vector<std::int32_t> splits; // admission path, not the hot loop
      splits.reserve(bands + 1);
      splits.push_back(rect.y);
      for (std::uint32_t i = 1; i < bands; ++i) {
        std::int32_t split =
            rect.y + static_cast<std::int32_t>(
                         (static_cast<std::uint64_t>(rect.height) * i) / bands);
        split = (split / tile_px) * tile_px; // snap down to tile grid
        if (split > splits.back() && split < rect.y + rect.height) {
          splits.push_back(split);
        }
      }
      splits.push_back(rect.y + rect.height);
      if (splits.size() > 2) {
        retain_payload(update);
        for (std::size_t i = 1; i + 1 < splits.size(); ++i) {
          PendingPiece piece;
          piece.kind = PieceKind::kBand;
          piece.update_index = update_index;
          piece.rect.x = rect.x;
          piece.rect.width = rect.width;
          piece.rect.y = splits[i];
          piece.rect.height = splits[i + 1] - splits[i];
          piece.admit_at_frame = frame_ + i;
          pending_pieces_.push_back(piece);
          ++update.pending;
          ++stats_.bands_deferred;
          if (outcome != nullptr) {
            ++outcome->deferred_bands;
          }
        }
        PlutoRect band0 = rect;
        band0.height = splits[1] - splits[0];
        process_piece(update_index, band0, false, outcome);
        return;
      }
    }
  }

  // Tile-granular admission arbitration.
  const int tile_px = static_cast<int>(config_.tile_px);
  const int ty0 = rect.y / tile_px;
  const int ty1 = (rect.y + rect.height - 1) / tile_px;
  const int tx0 = rect.x / tile_px;
  const int tx1 = (rect.x + rect.width - 1) / tile_px;
  for (int ty = ty0; ty <= ty1; ++ty) {
    for (int tx = tx0; tx <= tx1; ++tx) {
      const std::uint32_t tile_index =
          static_cast<std::uint32_t>(ty) * tile_cols_ +
          static_cast<std::uint32_t>(tx);
      PlutoRect sub;
      sub.x = std::max(rect.x, tx * tile_px);
      sub.y = std::max(rect.y, ty * tile_px);
      sub.width = std::min(rect.x + rect.width, (tx + 1) * tile_px) - sub.x;
      sub.height = std::min(rect.y + rect.height, (ty + 1) * tile_px) - sub.y;

      TileState &tile = tiles_[tile_index];
      if (mapped_tile_claimed(tile_index) ||
          mapped_poisoned_owner_[tile_index] != nullptr) {
        // Exact mapped journals claim their tiles before activation and retain
        // them through scan confirmation. Ordinary Pen Fast never invalidates
        // the history owner: every mapped/poison conflict parks without
        // touching mapped logical intent, including queued/unstarted truth.
        retain_payload(updates_[update_index]);
        PendingPiece piece;
        piece.kind = PieceKind::kParked;
        piece.update_index = update_index;
        piece.rect = sub;
        piece.blocker_tile = tile_index;
        pending_pieces_.push_back(piece);
        ++updates_[update_index].pending;
        ++stats_.tiles_parked;
        if (pen_preview) {
          ++stats_.mapped_fast_parks;
        }
        if (outcome != nullptr) {
          ++outcome->parked_tiles;
        }
        continue;
      }
      if (tile.active_px == 0) {
        start_tile(tile_index, update_index, sub, outcome);
        continue;
      }
      if (sparkle) {
        // Best-effort: never park or retarget content for a top-off pass
        // (levels are null; the collision paths below read them).
        ++stats_.tiles_absorbed;
        if (outcome != nullptr) {
          ++outcome->absorbed_tiles;
        }
        continue;
      }
      // Value-aware collision (US8723889 shape).
      if (!force_identity(updates_[update_index]) &&
          targets_equal(updates_[update_index], sub)) {
        subscribe(tile_index, update_index); // redundant damage is free
        ++stats_.tiles_absorbed;
        if (outcome != nullptr) {
          ++outcome->absorbed_tiles;
        }
        continue;
      }
      // Early cancel / rail retarget: rail modes ONLY, E2-gated,
      // default OFF. CORE stage additionally requires an identical mode and
      // temperature record: in-place fnum values stay valid only against the
      // exact pinned LUT.
      //
      // Pen-priority app pixels are ALWAYS retarget-eligible under the same
      // rail/same-mode guard: parking correlated damage behind the tile's
      // in-flight waveform (~130 ms in mode 7) made motion appear dashed.
      // Fresh pixels are idle and start immediately, already-driving pixels
      // with an unchanged target continue in place, and genuine target flips
      // take the DC-charged truncation path.
      // A guard is non-authoring maintenance (`target := prev`). If it
      // retargets an active rail tile, `prev` is still the older glass state
      // and the truncation path rolls the newer in-flight content back to it.
      // Park the guard instead; when the blocker reaches terminal, start_tile
      // samples the now-current prev and performs the intended identity drive.
      if (!guard && (config_.early_cancel_enabled || pen_preview) &&
          rail_mode(tile.mode) && rail_mode(updates_[update_index].mode) &&
          tile.mode == updates_[update_index].mode &&
          tile.temp_bin == updates_[update_index].temp_bin) {
        retarget_tile(tile_index, update_index, sub, outcome);
        continue;
      }
      // A draw-back can revisit a tile while its trailing Text/Full truth is
      // still developing. If this preview covers EVERY active pixel in the
      // tile, admission happens at a scan boundary and can safely supersede
      // the old pass: truncate/estimate it, unpin its mode, then start the
      // newest Fast payload immediately. If any unrelated active pixel lies
      // outside the preview, retain the conservative park path below.
      if (pen_preview && pen_preview_covers_active_tile(tile_index, sub)) {
        preempt_tile_for_pen_preview(tile_index);
        start_tile(tile_index, update_index, sub, outcome);
        if (outcome != nullptr) {
          ++outcome->retargeted_tiles;
        }
        continue;
      }
      // Park shrunk to the conflict tile; re-admitted the frame after the
      // blocker's waveform boundary (queue-jump never mid-waveform).
      retain_payload(updates_[update_index]);
      PendingPiece piece;
      piece.kind = PieceKind::kParked;
      piece.update_index = update_index;
      piece.rect = sub;
      piece.blocker_tile = tile_index;
      pending_pieces_.push_back(piece);
      ++updates_[update_index].pending;
      ++stats_.tiles_parked;
      if (outcome != nullptr) {
        ++outcome->parked_tiles;
      }
    }
  }
}

bool PixelEngine::admit(const AdmitRequest &request, AdmitOutcome *outcome) {
  if (outcome != nullptr) {
    *outcome = AdmitOutcome{};
  }
  if (!configured_) {
    return false;
  }
  const bool no_mapped_invalidation =
      (request.flags & kAdmitFlagNoMappedInvalidation) != 0;
  const bool fast_rail_rebase =
      (request.flags & kAdmitFlagFastRailRebase) != 0;
  if (no_mapped_invalidation &&
      ((request.flags & kAdmitFlagPenPreview) == 0 || request.mode != 7 ||
       request.fast_coverage == nullptr || !fast_rail_rebase)) {
    return false;
  }
  if (fast_rail_rebase && !no_mapped_invalidation) {
    return false;
  }
  if (fast_rail_rebase &&
      (next_fast_recovery_generation_ == 0 ||
       next_fast_recovery_generation_ ==
           std::numeric_limits<std::uint32_t>::max())) {
    return false;
  }
  if (request.fast_coverage != nullptr &&
      (!no_mapped_invalidation || !request.fast_coverage->valid() ||
       !request.fast_coverage->empty())) {
    return false;
  }
  if ((request.flags & (kAdmitFlagGuardNull | kAdmitFlagSparkle)) == 0 &&
      request.levels == nullptr) {
    return false;
  }
  if (fast_rail_rebase) {
    if (!mode7_fast_recovery_supported_) {
      return false;
    }
    const std::size_t stride =
        request.levels_stride != 0
            ? request.levels_stride
            : static_cast<std::size_t>(request.rect.width);
    if (request.rect.width <= 0 || request.rect.height <= 0 ||
        stride < static_cast<std::size_t>(request.rect.width)) {
      return false;
    }
    if (!fast_rail_levels_valid(request.levels, stride, request.rect.width,
                                request.rect.height)) {
      return false;
    }
  }
  PlutoRect clipped;
  if (!clip_rect(request.rect, config_.width, config_.height, &clipped)) {
    return false;
  }
  if (request.fast_coverage != nullptr) {
    const PlutoRect coverage_rect = request.fast_coverage->rect();
    if (coverage_rect.x != request.rect.x ||
        coverage_rect.y != request.rect.y ||
        coverage_rect.width != request.rect.width ||
        coverage_rect.height != request.rect.height ||
        clipped.x != request.rect.x || clipped.y != request.rect.y ||
        clipped.width != request.rect.width ||
        clipped.height != request.rect.height) {
      return false;
    }
  }
  const int request_bin =
      request.temp_bin >= 0 ? request.temp_bin : current_bin_;
  if (request_bin < 0 || request_bin >= waveform_->temp_count() ||
      waveform_->phase_count(request.mode, request_bin) <= 0) {
    return false; // unknown waveform mode for the pinned bin
  }

  // Mapped truth is never preempted by this generic admission surface. Exact
  // colour Pen Fast parks at tile arbitration below; disjoint ordinary mode-7
  // work and same-mode legacy retargeting remain latency-critical. The old
  // owner-wide recovery machinery stays private for now but has no admission
  // route: regional MVCC reseed is the production recovery contract.
  MappedRecoveryToken recovery_token = 0;

  // Newest-wins supersession (no-damage-loss rule: every dirty tile
  // is presented OR superseded by newer covering content): this admission
  // owns every pixel of `clipped` from now on. Pending pieces — parked
  // conflicts, deferred full-field bands, budget-deferred regions — from
  // OLDER admissions keep only the uncovered remainder; re-admitting them
  // over the newer content would resurrect stale content on glass (the
  // device scene-bleed bug). Guard-null and sparkle admissions author no
  // content (next := prev / white top-off) and therefore supersede nothing.
  if ((request.flags & (kAdmitFlagGuardNull | kAdmitFlagSparkle)) == 0) {
    supersede_pending(clipped);
  }

  const std::uint32_t update_index = alloc_update(request);
  updates_[update_index].recovery_token = recovery_token;
  if (updates_[update_index].fast_coverage != nullptr) {
    retain_payload(updates_[update_index]);
  }
  ++stats_.admissions;
  process_piece(update_index, clipped, true, outcome);
  if (outcome != nullptr) {
    outcome->accepted = true;
  }
  // Instantly satisfied admissions (all no-op tiles) complete here.
  flush_completions();
  return true;
}

// Subtract `cut` (a newer admission's clipped rect) from every pending
// piece. A piece splits into at most four remainder fragments (top band,
// bottom band, left, right); each fragment inherits the piece's kind,
// blocker and wake frame, and carries its own +1 on the owning update's
// pending count. A fully covered piece releases its obligation — the
// newer admission presents those pixels, so the older frame's completion
// accounting treats them as satisfied (superseded, not dropped).
void PixelEngine::supersede_pending(const PlutoRect &cut) {
  if (pending_pieces_.empty()) {
    return;
  }
  supersede_scratch_.clear();
  for (const PendingPiece &piece : pending_pieces_) {
    if (!rects_intersect(piece.rect, cut)) {
      supersede_scratch_.push_back(piece);
      continue;
    }
    const std::size_t before = supersede_scratch_.size();
    const std::int32_t px0 = piece.rect.x;
    const std::int32_t px1 = piece.rect.x + piece.rect.width;
    const std::int32_t py0 = piece.rect.y;
    const std::int32_t py1 = piece.rect.y + piece.rect.height;
    const std::int32_t cy0 = std::max(py0, cut.y);
    const std::int32_t cy1 = std::min(py1, cut.y + cut.height);
    const std::int32_t cx0 = std::max(px0, cut.x);
    const std::int32_t cx1 = std::min(px1, cut.x + cut.width);
    PendingPiece fragment = piece;
    if (cy0 > py0) {
      fragment.rect = {px0, py0, px1 - px0, cy0 - py0};
      supersede_scratch_.push_back(fragment);
    }
    if (py1 > cy1) {
      fragment.rect = {px0, cy1, px1 - px0, py1 - cy1};
      supersede_scratch_.push_back(fragment);
    }
    if (cx0 > px0) {
      fragment.rect = {px0, cy0, cx0 - px0, cy1 - cy0};
      supersede_scratch_.push_back(fragment);
    }
    if (px1 > cx1) {
      fragment.rect = {cx1, cy0, px1 - cx1, cy1 - cy0};
      supersede_scratch_.push_back(fragment);
    }
    const std::size_t fragments = supersede_scratch_.size() - before;
    Update &update = updates_[piece.update_index];
    if (fragments == 0) {
      assert(update.pending > 0);
      --update.pending; // completion (if due) fires at flush_completions
      ++stats_.pieces_superseded;
    } else {
      update.pending += static_cast<std::uint32_t>(fragments - 1);
      ++stats_.pieces_clipped;
    }
  }
  pending_pieces_.swap(supersede_scratch_);
}

void PixelEngine::process_pending_pieces() {
  if (pending_pieces_.empty()) {
    return;
  }
  pieces_scratch_.clear();
  std::size_t keep = 0;
  for (std::size_t i = 0; i < pending_pieces_.size(); ++i) {
    const PendingPiece &piece = pending_pieces_[i];
    bool ready = false;
    switch (piece.kind) {
    case PieceKind::kBand:
      // Bring-up sweep bound (device livelock fix): force-identity
      // bands (forced diagnostics, forced settles, guard nulls) activate
      // EVERY pixel of the band, so the onset stagger alone cannot
      // bound the per-frame sweep — the bands of one admission all run
      // for the whole waveform and overlap into a full-field sweep
      // (active_px_peak = the entire panel on device). Each such band
      // additionally waits for busy-pixel headroom, so the concurrent
      // sweep stays <= max_active_px + one band. Content bands keep
      // the pure <= full_flash_band_frames onset stagger (E10).
      ready = frame_ >= piece.admit_at_frame &&
              (!force_identity(updates_[piece.update_index]) ||
               total_active_px_ < config_.max_active_px);
      break;
    case PieceKind::kParked:
      ready = tiles_[piece.blocker_tile].active_px == 0 &&
              !mapped_tile_claimed(piece.blocker_tile) &&
              mapped_poisoned_owner_[piece.blocker_tile] == nullptr;
      break;
    case PieceKind::kBudget:
      ready = total_active_px_ < config_.max_active_px;
      break;
    }
    if (ready) {
      pieces_scratch_.push_back(piece);
    } else {
      pending_pieces_[keep++] = piece;
    }
  }
  pending_pieces_.resize(keep);

  for (const PendingPiece &piece : pieces_scratch_) {
    if (piece.kind == PieceKind::kBand &&
        force_identity(updates_[piece.update_index]) &&
        total_active_px_ >= config_.max_active_px) {
      // An earlier piece admitted in this same pass consumed the headroom:
      // re-defer so the sweep bound holds at every admission instant.
      pending_pieces_.push_back(piece);
      continue;
    }
    --updates_[piece.update_index].pending;
    if (piece.kind == PieceKind::kParked) {
      ++stats_.parked_wakes;
    }
    process_piece(piece.update_index, piece.rect,
                  piece.kind == PieceKind::kBudget, nullptr);
  }
}

void PixelEngine::finalize_tile(std::uint32_t tile_index) {
  TileState &tile = tiles_[tile_index];
  assert(tile.active_px == 0);
  if (hooks_ != nullptr) {
    hooks_->on_tile_pass_end(tile_index);
  }
  lut_cache_->unpin(tile.mode, tile.temp_bin);
  // A completed balanced-quality pass repays the tile's DC stress (the
  // renormalization already zeroed the per-pixel debt). E2.
  if (dc_.balanced_mode(tile.mode)) {
    dc_.clear_stress(tile_index);
  }
  const int tile_px = static_cast<int>(config_.tile_px);
  const int tx = static_cast<int>(tile_index % tile_cols_);
  const int ty = static_cast<int>(tile_index / tile_cols_);
  const int tile_x0 = tx * tile_px;
  const int tile_x1 = std::min(tile_x0 + tile_px, config_.width);
  const int tile_y0 = ty * tile_px;
  const int tile_y1 = std::min(tile_y0 + tile_px, config_.height);
  for (const std::uint32_t update_index : tile_subscribers_[tile_index]) {
    Update& update = updates_[update_index];
    if (update.fast_coverage != nullptr) {
      const int x0 = std::max(tile_x0, update.rect.x);
      const int x1 = std::min(tile_x1, update.rect.x + update.rect.width);
      const int y0 = std::max(tile_y0, update.rect.y);
      const int y1 = std::min(tile_y1, update.rect.y + update.rect.height);
      for (int y = y0; y < y1; ++y) {
        std::size_t px = static_cast<std::size_t>(y) *
                             static_cast<std::size_t>(config_.stride) +
                         static_cast<std::size_t>(x0);
        for (int x = x0; x < x1; ++x, ++px) {
          if (waveform_drove_[px] != 0 &&
              target_level(update, x, y, px) == prev_[px]) {
            update.fast_coverage->mark(
                x, y, frame_, fast_rebase_pending_generation_[px]);
          }
        }
      }
    }
    assert(updates_[update_index].pending > 0);
    --updates_[update_index].pending;
  }
  for (int y = tile_y0; y < tile_y1; ++y) {
    const std::size_t begin =
        static_cast<std::size_t>(y) *
            static_cast<std::size_t>(config_.stride) +
        static_cast<std::size_t>(tile_x0);
    for (std::size_t px = begin;
         px < begin + static_cast<std::size_t>(tile_x1 - tile_x0); ++px) {
      if (waveform_drove_[px] != 0 &&
          fast_rebase_pending_generation_[px] != 0) {
        // The fused kernel clears estimates at build completion. A safe Fast
        // rebase is not optical truth until positive scan evidence, so restore
        // that fence after coverage has been captured and retain it for the
        // explicit latch hook.
        dc_.mark_prev_estimated(px);
      }
    }
    std::fill(waveform_drove_.begin() + static_cast<std::ptrdiff_t>(begin),
              waveform_drove_.begin() +
                  static_cast<std::ptrdiff_t>(begin + tile_x1 - tile_x0),
              0);
  }
  tile_subscribers_[tile_index].clear();
  tile.update_index = kNoUpdate;
  tile.flags = 0;
}

void PixelEngine::flush_completions() {
  for (std::uint32_t i = 0; i < updates_.size(); ++i) {
    Update &update = updates_[i];
    if (!update.live || update.pending != 0) {
      continue;
    }
    if (update.recovery_token != 0 &&
        std::find(terminal_recoveries_.begin(), terminal_recoveries_.end(),
                  update.recovery_token) == terminal_recoveries_.end()) {
      terminal_recoveries_.push_back(update.recovery_token);
    }
    // Settle regions carry sentinel frame_id 0, fire no user completion,
    // and count in debug stats (pinned behavior).
    if ((update.flags & kAdmitFlagSettle) != 0 || update.frame_id == 0) {
      ++stats_.settle_completions;
    } else {
      ++stats_.completions;
      if (completion_fn_) {
        completion_fn_(update.frame_id);
      }
    }
    release_update(i);
  }
}

void PixelEngine::advance(RowEmitter *emitter) {
  if (!configured_) {
    return;
  }
  activate_mapped_queue();
  process_pending_pieces();
  completed_tiles_.clear();

  if (total_active_px_ > 0 || mapped_active_px_ > 0) {
    const int tile_px = static_cast<int>(config_.tile_px);
    const DcLedgerConfig &dc_config = dc_.config();
    // Per-segment sweep invariants hoisted out of the row loop. The record
    // pointer, codes base, phase count and renorm flag of every tile are
    // frame-invariant (admissions only happen before the sweep; active
    // tiles only COMPLETE mid-frame), so they are cached once per tile-row
    // band instead of re-derived via lut_cache_->peek per (row, tile)
    // segment — ~32x fewer lookups on a dense band. Iteration order (rows
    // ascending, tiles ascending within a row) and all outputs are
    // unchanged.
    SweepArgs sweep;
    sweep.prev_est = dc_.prev_est_data();
    sweep.impulse_map = dc_config.impulse_map.data();
    sweep.dc_cap = dc_config.dc_pixel_cap;
    std::uint64_t saturations = 0;
    int cached_band = -1;
    int sweep_min_row = config_.height;
    int sweep_max_row = -1;
    if (total_active_px_ != 0) {
      sweep_min_row = std::min(sweep_min_row, clip_min_row_);
      sweep_max_row = std::max(sweep_max_row, clip_max_row_);
    }
    if (mapped_active_px_ != 0) {
      sweep_min_row = std::min(sweep_min_row, mapped_clip_min_row_);
      sweep_max_row = std::max(sweep_max_row, mapped_clip_max_row_);
    }
    for (int row = sweep_min_row; row <= sweep_max_row; ++row) {
      if (row_active_[row] == 0 &&
          mapped_row_active_[static_cast<std::size_t>(row)] == 0) {
        continue; // row-skip
      }
      PixelOp *const row_ops = row_ops_.data();
      std::size_t ops_count = 0;
      const std::size_t row_base = static_cast<std::size_t>(row) *
                                   static_cast<std::size_t>(config_.stride);
      const int tile_row = row / tile_px;
      if (tile_row != cached_band) {
        cached_band = tile_row;
        const std::size_t band_base =
            static_cast<std::size_t>(tile_row) * tile_cols_;
        for (std::uint32_t tx = 0; tx < tile_cols_; ++tx) {
          const TileState &tile = tiles_[band_base + tx];
          if (tile.active_px == 0) {
            band_records_[tx] = nullptr;
            continue;
          }
          // Bin pinning invariant: the record every active tile
          // pinned at admission must still be resident (O(1) direct-mapped
          // peek).
          const LutRecord *record = lut_cache_->peek(tile.mode, tile.temp_bin);
          assert(record != nullptr && "pinned LUT record evicted");
          band_records_[tx] = record;
          band_renorm_[tx] =
              dc_config.trust_vendor_balance && dc_.balanced_mode(tile.mode);
        }
      }
      const std::uint32_t band_base =
          static_cast<std::uint32_t>(tile_row) * tile_cols_;
      for (std::uint32_t tx = 0; tx < tile_cols_; ++tx) {
        const std::uint32_t tile_index = band_base + tx;
        TileState &tile = tiles_[tile_index];
        const MappedOperationToken mapped_owner =
            mapped_tile_owner_[tile_index];
        if (mapped_owner != 0) {
          MappedRuntime* const operation = mapped_tile_runtime_[tile_index];
          assert(operation != nullptr && operation->token == mapped_owner);
          if (operation->state != MappedState::kActive) {
            continue;  // terminal tile remains locked but emits nothing
          }
          const auto execution = operation->operation->execution();
          if (row < execution.top || row > execution.bottom) {
            continue;
          }
          const int x0 = std::max(static_cast<int>(tx) * tile_px,
                                  execution.left);
          const int x1 = std::min(
              {static_cast<int>(tx + 1) * tile_px, execution.right + 1,
               config_.stride});
          if (x1 <= x0) {
            continue;
          }
          const std::size_t tight =
              static_cast<std::size_t>(row - execution.top) *
                  static_cast<std::size_t>(operation->operation->width()) +
              static_cast<std::size_t>(x0 - execution.left);
          const std::size_t px0 =
              row_base + static_cast<std::size_t>(x0);
          MappedSweepArgs mapped;
          mapped.transitions =
              operation->operation->transitions().data() + tight;
          mapped.fnum = operation->fnum.data() + tight;
          mapped.dc = dc_.dc_data() + px0;
          mapped.terminal = mapped_terminal_scratch_.data();
          mapped.x0 = x0;
          mapped.count = x1 - x0;
          mapped.codes = operation->codes;
          mapped.phase_count = operation->phase_count;
          mapped.impulse_map = dc_config.impulse_map.data();
          mapped.dc_cap = dc_config.dc_pixel_cap;
          const MappedSweepResult swept =
              config_.force_scalar_sweep
                  ? mapped_sweep_scalar(mapped, row_ops + ops_count)
                  : mapped_sweep(mapped, row_ops + ops_count);
          operation->ever_emitted |= swept.emitted != 0;
          ops_count += swept.emitted;
          saturations += swept.saturations;
          assert(operation->active_lanes >= swept.completed);
          operation->active_lanes -= swept.completed;
          assert(mapped_row_active_[static_cast<std::size_t>(row)] >=
                 swept.completed);
          mapped_row_active_[static_cast<std::size_t>(row)] =
              static_cast<std::uint16_t>(
                  mapped_row_active_[static_cast<std::size_t>(row)] -
                  swept.completed);
          assert(mapped_active_px_ >= swept.completed);
          mapped_active_px_ -= swept.completed;
          if (emitter != nullptr && sink_impulse_ != nullptr) {
            sink_impulse_[tile_index] += swept.impulse;
            if (swept.drove) {
              sink_drive_[tile_index] = 1;
            }
          }
          continue;
        }
        if (tile.active_px == 0) {
          continue;
        }
        const LutRecord *record = band_records_[tx];
        if (record == nullptr) {
          continue;
        }
        const int x0 = static_cast<int>(tx) * tile_px;
        const int x1 = std::min(x0 + tile_px, config_.width);
        const std::size_t px0 = row_base + static_cast<std::size_t>(x0);

        // Fused sweep (sweep_kernels.h): LUT gather + op emission + DC
        // charge (EVERY emitted op is ledgered, including
        // guard-band and settle identity transitions) + fnum advance +
        // waveform-boundary promotion, one tile-row segment wide.
        sweep.prev = prev_.data() + px0;
        sweep.next = next_.data() + px0;
        sweep.final_lv = final_.data() + px0;
        sweep.fnum = fnum_.data() + px0;
        sweep.dc = dc_.dc_data() + px0;
        sweep.drove = waveform_drove_.data() + px0;
        sweep.px0 = px0;
        sweep.x0 = x0;
        sweep.count = x1 - x0;
        sweep.codes = record->codes.data();
        sweep.phase_count = record->phase_count;
        sweep.renorm_dc = band_renorm_[tx];
        const SweepResult swept =
            config_.force_scalar_sweep
                ? sweep_segment_scalar(sweep, row_ops + ops_count)
                : sweep_segment(sweep, row_ops + ops_count);
        ops_count += swept.emitted;
        saturations += swept.saturations;
        dc_.account_sweep_prev_estimated_clears(
            swept.prev_estimated_cleared);
        if (emitter != nullptr && sink_impulse_ != nullptr) {
          sink_impulse_[tile_index] += swept.impulse;
          if (swept.drove) {
            sink_drive_[tile_index] = 1;
          }
        }
        if (swept.completed != 0) {
          row_active_[row] =
              static_cast<std::uint16_t>(row_active_[row] - swept.completed);
          total_active_px_ -= swept.completed;
          tile.active_px =
              static_cast<std::uint16_t>(tile.active_px - swept.completed);
          if (tile.active_px == 0) {
            completed_tiles_.push_back(tile_index);
          }
        }
      }
      if (ops_count != 0 && emitter != nullptr) {
        emitter->emit_row(row, row_ops, ops_count);
      }
      stats_.ops_emitted += ops_count;
    }

    // Rounded mapper operations can include x>=960 and y>=1696 history guard
    // lanes. They must reach the same terminal phase before A/B commit, but
    // must never index the panel/DC planes or emit into DRM's trailing control
    // row. Advance those lanes against private DC storage and discard their
    // wire ops. The physical prefix was advanced above.
    for (auto& operation_ptr : mapped_operations_) {
      MappedRuntime& operation = *operation_ptr;
      if (operation.state != MappedState::kActive) {
        continue;
      }
      const auto execution = operation.operation->execution();
      const int width = operation.operation->width();
      std::size_t guard_dc_offset = 0;
      for (int y = execution.top; y <= execution.bottom; ++y) {
        const int guard_x0 =
            y < config_.height ? std::max(execution.left, config_.stride)
                               : execution.left;
        if (guard_x0 > execution.right) {
          continue;
        }
        const std::size_t tight =
            static_cast<std::size_t>(y - execution.top) *
                static_cast<std::size_t>(width) +
            static_cast<std::size_t>(guard_x0 - execution.left);
        MappedSweepArgs guard;
        guard.transitions =
            operation.operation->transitions().data() + tight;
        guard.fnum = operation.fnum.data() + tight;
        const std::size_t guard_count =
            static_cast<std::size_t>(execution.right - guard_x0 + 1);
        assert(guard_dc_offset + guard_count <= operation.guard_dc.size());
        guard.dc = operation.guard_dc.data() + guard_dc_offset;
        guard.terminal = mapped_terminal_scratch_.data();
        guard.x0 = guard_x0;
        guard.count = execution.right - guard_x0 + 1;
        guard.codes = operation.codes;
        guard.phase_count = operation.phase_count;
        guard.impulse_map = dc_config.impulse_map.data();
        guard.dc_cap = dc_config.dc_pixel_cap;
        const MappedSweepResult swept =
            config_.force_scalar_sweep
                ? mapped_sweep_scalar(guard, row_ops_.data())
                : mapped_sweep(guard, row_ops_.data());
        assert(operation.active_lanes >= swept.completed);
        operation.active_lanes -= swept.completed;
        guard_dc_offset += guard_count;
      }
      assert(guard_dc_offset == operation.guard_dc.size());
    }
    if (saturations != 0) {
      dc_.add_saturations(saturations);
    }
    shrink_clip();
    recompute_mapped_clip();
    for (const std::uint32_t tile_index : completed_tiles_) {
      finalize_tile(tile_index);
    }
    for (auto& operation : mapped_operations_) {
      if (operation->state == MappedState::kActive &&
          operation->active_lanes == 0) {
        operation->state = MappedState::kAwaitingConfirm;
        ++stats_.mapped_terminals;
        emit_mapped_event(MappedEventKind::kTerminal, *operation);
      }
    }
    activate_mapped_queue();
  }

  ++frame_;
  flush_completions();
}

void PixelEngine::pause() {
  if (!configured_) {
    return;
  }
  ++stats_.pauses;
  // A missed deadline stretches every in-flight waveform by one scan frame:
  // nothing was emitted and no fnum advances. The stretch is COUNTED but no
  // longer charged as stress: the scanned plane is the impulse-free HOLD
  // scaffold, so zero extra drive reaches any pixel — and pauses are
  // ROUTINE under transition load (device: pauses ~= builds), so charging
  // k_pause tripped dc_stress_force on exactly the tiles every transition
  // had just painted, promoting their next settle to a flashing GC16 (the
  // recurring tile-region black flash ~1 s after every screen change).
  // Genuine extra impulse (real double scans of content planes) still
  // charges via charge_double_scan against the learned scan cadence.
}

} // namespace pluto::swtcon
