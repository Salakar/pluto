#include "presenter/swtcon/xochitl_history_state.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>
#include <vector>

#include "presenter/swtcon/xochitl_parallel.h"

namespace pluto::swtcon {
namespace {

using HistoryPixel = XochitlHistoryState::HistoryPixel;
using InclusiveRect = XochitlHistoryState::InclusiveRect;
using LaneJournal = XochitlHistoryState::LaneJournal;
using Mode = XochitlHistoryState::Mode;

constexpr std::uint16_t kValidAMask = 0x00dfu; // low5 + bits 6/7

constexpr std::array<std::uint8_t, 16> kMode1Palette = {
    0, 14, 6, 22, 10, 18, 26, 30, 15, 19, 0, 30, 32, 32, 32, 32};
constexpr std::array<std::uint8_t, 16> kMode2Palette = {
    2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 30, 32, 32, 32, 32};
constexpr std::array<std::uint8_t, 16> kMode5Palette = {
    2, 13, 5, 21, 9, 17, 25, 28, 15, 19, 0, 30, 32, 32, 32, 32};
constexpr std::array<std::uint8_t, 16> kMode6Palette = {
    2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 28, 32, 32, 32, 32};
constexpr std::array<std::uint8_t, 16> kMode7Palette = {
    2, 32, 32, 32, 32, 32, 32, 28, 32, 32, 32, 32, 32, 32, 32, 32};

struct Thermal {
  std::int32_t amplitude = 0;
  std::int32_t limit = 0;
  std::uint16_t reset_flags = 0;
};

bool thermal_for(float temperature_c, Thermal *thermal) {
  if (!std::isfinite(temperature_c)) {
    return false;
  }
  // The stored context value is already binary32.  For finite float inputs,
  // FCVTZS(temp)>37 is exactly temp>=38, including out-of-range saturation.
  *thermal =
      temperature_c >= 38.0f ? Thermal{704, 2016, 2} : Thermal{576, 3456, 3};
  return true;
}

std::int32_t signed16(std::uint16_t value) {
  return (value & 0x8000u) != 0u ? static_cast<std::int32_t>(value) - 0x10000
                                 : static_cast<std::int32_t>(value);
}

std::int32_t arithmetic_shift_right_2(std::uint16_t value) {
  const std::int32_t signed_value = signed16(value);
  return signed_value >= 0 ? signed_value / 4 : -(((-signed_value) + 3) / 4);
}

std::int32_t decay_toward_zero(std::int32_t history) {
  return history < 0 ? history + 16 : history > 0 ? history - 16 : 0;
}

std::uint16_t encode_history(std::int32_t history, std::uint16_t flags) {
  return static_cast<std::uint16_t>(
      ((static_cast<std::uint16_t>(history) << 2) & 0xfffcu) | (flags & 3u));
}

std::uint16_t transition(std::uint16_t source, std::uint16_t destination) {
  return static_cast<std::uint16_t>(((source & 31u) << 5) |
                                    (destination & 31u));
}

bool raw_plane_fits(std::span<const std::uint8_t> raw, std::size_t raw_stride,
                    std::int32_t width, std::int32_t height) {
  if (width <= 0 || height <= 0 ||
      raw_stride < static_cast<std::size_t>(width)) {
    return false;
  }
  const std::size_t rows = static_cast<std::size_t>(height - 1);
  const std::size_t lane_width = static_cast<std::size_t>(width);
  if (raw_stride != 0 &&
      rows >
          (std::numeric_limits<std::size_t>::max() - lane_width) / raw_stride) {
    return false;
  }
  return raw.size() >= rows * raw_stride + lane_width;
}

} // namespace

std::atomic<std::uint64_t> XochitlHistoryState::next_owner_id_{1};

XochitlHistoryState::PreparedOperation::PreparedOperation(
    std::uint64_t owner_id, std::uint64_t operation_id,
    std::uint64_t base_generation, OperationKind kind, Mode mode,
    InclusiveRect requested, InclusiveRect execution, std::int32_t width,
    std::int32_t height, bool has_pending_flags, std::vector<LaneJournal> lanes,
    std::vector<std::uint16_t> transitions, std::vector<std::uint8_t> lane_mask,
    std::uint64_t seed_epoch, std::size_t first_tile_x,
    std::size_t first_tile_y, std::size_t tile_columns, std::size_t tile_rows,
    std::vector<std::uint64_t> tile_versions)
    : owner_id_(owner_id), operation_id_(operation_id),
      base_generation_(base_generation), kind_(kind), mode_(mode),
      requested_(requested), execution_(execution), width_(width),
      height_(height), has_pending_flags_(has_pending_flags),
      lanes_(std::move(lanes)), transitions_(std::move(transitions)),
      lane_mask_(std::move(lane_mask)), seed_epoch_(seed_epoch),
      first_tile_x_(first_tile_x), first_tile_y_(first_tile_y),
      tile_columns_(tile_columns), tile_rows_(tile_rows),
      tile_versions_(std::move(tile_versions)) {}

XochitlHistoryState::XochitlHistoryState()
    : committed_(kStoragePixels), tile_versions_(kVersionTileCount),
      owner_id_(next_owner_id_.fetch_add(1, std::memory_order_relaxed)) {}

bool XochitlHistoryState::tile_versions_match_locked(
    std::size_t first_tile_x, std::size_t first_tile_y,
    std::size_t tile_columns, std::size_t tile_rows,
    std::span<const std::uint64_t> expected) const {
  if (tile_columns == 0u || tile_rows == 0u ||
      first_tile_x >= kVersionTileColumns || first_tile_y >= kVersionTileRows ||
      tile_columns > kVersionTileColumns - first_tile_x ||
      tile_rows > kVersionTileRows - first_tile_y ||
      expected.size() != tile_columns * tile_rows) {
    return false;
  }
  std::size_t cursor = 0;
  for (std::size_t row = 0; row < tile_rows; ++row) {
    const std::size_t begin =
        (first_tile_y + row) * kVersionTileColumns + first_tile_x;
    for (std::size_t column = 0; column < tile_columns; ++column) {
      if (tile_versions_[begin + column] != expected[cursor++]) {
        return false;
      }
    }
  }
  return true;
}

void XochitlHistoryState::stamp_tile_versions_locked(std::size_t first_tile_x,
                                                     std::size_t first_tile_y,
                                                     std::size_t tile_columns,
                                                     std::size_t tile_rows) {
  for (std::size_t row = 0; row < tile_rows; ++row) {
    const std::size_t begin =
        (first_tile_y + row) * kVersionTileColumns + first_tile_x;
    std::fill_n(tile_versions_.begin() + static_cast<std::ptrdiff_t>(begin),
                tile_columns, generation_);
  }
}

void XochitlHistoryState::bump_generation_locked() {
  ++generation_;
  if (generation_ == 0) {
    // Generation zero is reserved for the never-initialized constructor
    // state.  Wrap is unrealistic, but keeping the invariant is free.
    generation_ = 1;
  }
}

void XochitlHistoryState::invalidate_locked() {
  std::fill(committed_.begin(), committed_.end(), HistoryPixel{});
  valid_ = false;
  outstanding_.clear();
  bump_generation_locked();
  ++seed_epoch_;
  if (seed_epoch_ == 0) {
    seed_epoch_ = 1;
  }
  std::fill(tile_versions_.begin(), tile_versions_.end(), generation_);
}

bool XochitlHistoryState::initialize_cold_clear(std::uint16_t logical_a) {
  std::lock_guard lock(mutex_);
  if (logical_a > 31u) {
    invalidate_locked();
    return false;
  }
  std::fill(committed_.begin(), committed_.end(), HistoryPixel{logical_a, 0});
  valid_ = true;
  outstanding_.clear();
  bump_generation_locked();
  ++seed_epoch_;
  if (seed_epoch_ == 0) {
    seed_epoch_ = 1;
  }
  std::fill(tile_versions_.begin(), tile_versions_.end(), generation_);
  return true;
}

bool XochitlHistoryState::seed_full_plane(std::span<const HistoryPixel> seed) {
  if (seed.size() != kStoragePixels ||
      std::any_of(seed.begin(), seed.end(), [](const HistoryPixel &pixel) {
        return (pixel.a & ~kValidAMask) != 0u;
      })) {
    std::lock_guard lock(mutex_);
    invalidate_locked();
    return false;
  }

  std::lock_guard lock(mutex_);
  std::copy(seed.begin(), seed.end(), committed_.begin());
  valid_ = true;
  outstanding_.clear();
  bump_generation_locked();
  ++seed_epoch_;
  if (seed_epoch_ == 0) {
    seed_epoch_ = 1;
  }
  std::fill(tile_versions_.begin(), tile_versions_.end(), generation_);
  return true;
}

bool XochitlHistoryState::seed_full_plane_interleaved(
    std::span<const std::uint16_t> interleaved_ab) {
  if (interleaved_ab.size() != kStoragePixels * 2u) {
    std::lock_guard lock(mutex_);
    invalidate_locked();
    return false;
  }
  for (std::size_t pixel = 0; pixel < kStoragePixels; ++pixel) {
    if ((interleaved_ab[pixel * 2u] & ~kValidAMask) != 0u) {
      std::lock_guard lock(mutex_);
      invalidate_locked();
      return false;
    }
  }

  std::lock_guard lock(mutex_);
  for (std::size_t pixel = 0; pixel < kStoragePixels; ++pixel) {
    committed_[pixel] = {interleaved_ab[pixel * 2u],
                         interleaved_ab[pixel * 2u + 1u]};
  }
  valid_ = true;
  outstanding_.clear();
  bump_generation_locked();
  ++seed_epoch_;
  if (seed_epoch_ == 0) {
    seed_epoch_ = 1;
  }
  std::fill(tile_versions_.begin(), tile_versions_.end(), generation_);
  return true;
}

void XochitlHistoryState::invalidate() {
  std::lock_guard lock(mutex_);
  invalidate_locked();
}

void XochitlHistoryState::invalidate_preserving_committed_for_reseed() {
  std::lock_guard lock(mutex_);
  valid_ = false;
  outstanding_.clear();
  bump_generation_locked();
  ++seed_epoch_;
  if (seed_epoch_ == 0) {
    seed_epoch_ = 1;
  }
  std::fill(tile_versions_.begin(), tile_versions_.end(), generation_);
}

bool XochitlHistoryState::reseed_region_from_levels(
    InclusiveRect update, std::span<const std::uint8_t> levels,
    std::size_t levels_stride) {
  if (update.left < 0 || update.top < 0 || update.right < update.left ||
      update.bottom < update.top || update.right >= kLogicalWidth ||
      update.bottom >= kLogicalHeight) {
    std::lock_guard lock(mutex_);
    invalidate_locked();
    return false;
  }
  const std::int32_t logical_width = update.right - update.left + 1;
  const std::int32_t logical_height = update.bottom - update.top + 1;
  const std::int32_t width = (logical_width + 7) & ~7;
  const std::int32_t height = (logical_height + 1) & ~1;
  if (levels_stride < static_cast<std::size_t>(logical_width) ||
      static_cast<std::size_t>(logical_height) >
          levels.size() / levels_stride ||
      update.left + width > kStorageStride ||
      update.top + height > kStorageRows) {
    std::lock_guard lock(mutex_);
    invalidate_locked();
    return false;
  }
  for (std::int32_t y = 0; y < logical_height; ++y) {
    const auto row = levels.subspan(static_cast<std::size_t>(y) * levels_stride,
                                    static_cast<std::size_t>(logical_width));
    if (std::any_of(row.begin(), row.end(),
                    [](std::uint8_t level) { return level > 31u; })) {
      std::lock_guard lock(mutex_);
      invalidate_locked();
      return false;
    }
  }

  std::lock_guard lock(mutex_);
  for (std::int32_t y = 0; y < height; ++y) {
    const std::int32_t source_y = std::min(y, logical_height - 1);
    for (std::int32_t x = 0; x < width; ++x) {
      const std::int32_t source_x = std::min(x, logical_width - 1);
      const std::uint8_t level =
          levels[static_cast<std::size_t>(source_y) * levels_stride +
                 static_cast<std::size_t>(source_x)];
      const std::size_t panel =
          static_cast<std::size_t>(update.top + y) * kStorageStride +
          static_cast<std::size_t>(update.left + x);
      committed_[panel] = HistoryPixel{level, 0};
    }
  }
  valid_ = true;
  outstanding_.clear();
  bump_generation_locked();
  ++seed_epoch_;
  if (seed_epoch_ == 0) {
    seed_epoch_ = 1;
  }
  std::fill(tile_versions_.begin(), tile_versions_.end(), generation_);
  return true;
}

bool XochitlHistoryState::reseed_fast_region_from_raw(
    InclusiveRect requested, InclusiveRect execution,
    std::span<const std::uint8_t> raw, std::size_t raw_stride,
    std::span<const std::uint8_t> driven_bits,
    std::size_t driven_stride_bytes) {
  if (requested.left < 0 || requested.top < 0 ||
      requested.right < requested.left || requested.bottom < requested.top ||
      requested.right >= kLogicalWidth || requested.bottom >= kLogicalHeight ||
      execution.left < 0 || execution.top < 0 ||
      execution.right < execution.left || execution.bottom < execution.top ||
      execution.right >= kStorageStride || execution.bottom >= kStorageRows) {
    return false;
  }
  const std::int32_t requested_width = requested.right - requested.left + 1;
  const std::int32_t requested_height = requested.bottom - requested.top + 1;
  const std::int32_t expected_width = (requested_width + 7) & ~7;
  const std::int32_t expected_height = (requested_height + 1) & ~1;
  if (execution.left != requested.left || execution.top != requested.top ||
      execution.right != requested.left + expected_width - 1 ||
      execution.bottom != requested.top + expected_height - 1) {
    return false;
  }
  const std::int32_t width = execution.right - execution.left + 1;
  const std::int32_t height = execution.bottom - execution.top + 1;
  const std::size_t mask_row_bytes =
      (static_cast<std::size_t>(width) + 7u) / 8u;
  if (!raw_plane_fits(raw, raw_stride, width, height) ||
      driven_stride_bytes < mask_row_bytes ||
      (height > 1 &&
       static_cast<std::size_t>(height - 1) >
           (std::numeric_limits<std::size_t>::max() - mask_row_bytes) /
               driven_stride_bytes) ||
      driven_bits.size() <
          static_cast<std::size_t>(height - 1) * driven_stride_bytes +
              mask_row_bytes) {
    return false;
  }

  // Snapshot the execution plane and proof mask before taking the owner lock.
  std::vector<std::uint8_t> raw_snapshot;
  std::vector<std::uint8_t> mask_snapshot;
  raw_snapshot.reserve(static_cast<std::size_t>(width) *
                       static_cast<std::size_t>(height));
  mask_snapshot.reserve(mask_row_bytes * static_cast<std::size_t>(height));
  for (std::int32_t y = 0; y < height; ++y) {
    const auto row = raw.subspan(static_cast<std::size_t>(y) * raw_stride,
                                 static_cast<std::size_t>(width));
    raw_snapshot.insert(raw_snapshot.end(), row.begin(), row.end());
    const auto mask_row = driven_bits.subspan(
        static_cast<std::size_t>(y) * driven_stride_bytes, mask_row_bytes);
    mask_snapshot.insert(mask_snapshot.end(), mask_row.begin(), mask_row.end());
  }

  const auto mask_set = [&](std::int32_t local_x, std::int32_t local_y) {
    const std::size_t x = static_cast<std::size_t>(local_x);
    return (mask_snapshot[static_cast<std::size_t>(local_y) * mask_row_bytes +
                          x / 8u] &
            static_cast<std::uint8_t>(1u << (x & 7u))) != 0;
  };
  const auto source_lane = [&](std::int32_t x, std::int32_t y,
                               std::uint8_t *value) {
    const std::int32_t panel_x = execution.left + x;
    const std::int32_t panel_y = execution.top + y;
    const std::int32_t source_panel_x = std::min(panel_x, kLogicalWidth - 1);
    const std::int32_t source_panel_y = std::min(panel_y, kLogicalHeight - 1);
    const std::int32_t source_x = source_panel_x - execution.left;
    const std::int32_t source_y = source_panel_y - execution.top;
    if (source_x < 0 || source_y < 0 || source_x >= width ||
        source_y >= height || !mask_set(source_x, source_y)) {
      return false;
    }
    *value = raw_snapshot[static_cast<std::size_t>(source_y) * width +
                          static_cast<std::size_t>(source_x)];
    return true;
  };
  bool any_write = false;
  for (std::int32_t y = 0; y < height; ++y) {
    for (std::int32_t x = 0; x < width; ++x) {
      std::uint8_t ignored = 0;
      any_write |= source_lane(x, y, &ignored);
    }
  }

  std::lock_guard lock(mutex_);
  if (!valid_) {
    return false;
  }
  if (!any_write) {
    return true;
  }
  // generation_ is only a source of fresh regional stamp values here. The
  // global seed epoch, validity and outstanding set deliberately stay intact.
  bump_generation_locked();
  for (std::int32_t y = 0; y < height; ++y) {
    const std::int32_t panel_y = execution.top + y;
    for (std::int32_t x = 0; x < width; ++x) {
      std::uint8_t value = 0;
      if (!source_lane(x, y, &value)) {
        continue;
      }
      const std::int32_t panel_x = execution.left + x;
      const bool white = (value & 31u) == 7u;
      const std::uint16_t a =
          static_cast<std::uint16_t>((value & 0x80u) | (white ? 28u : 2u));
      const std::size_t panel =
          static_cast<std::size_t>(panel_y) * kStorageStride +
          static_cast<std::size_t>(panel_x);
      committed_[panel] = HistoryPixel{a, 0};
      const std::size_t stamp =
          static_cast<std::size_t>(panel_y / kVersionTileHeight) *
              kVersionTileColumns +
          static_cast<std::size_t>(panel_x / kVersionTileWidth);
      tile_versions_[stamp] = generation_;
    }
  }
  return true;
}

bool XochitlHistoryState::valid() const {
  std::lock_guard lock(mutex_);
  return valid_;
}

bool XochitlHistoryState::admissible(const PreparedOperation &operation) const {
  if (operation.owner_id_ != owner_id_) {
    return false;
  }
  std::lock_guard lock(mutex_);
  const std::size_t expected = static_cast<std::size_t>(operation.width_) *
                               static_cast<std::size_t>(operation.height_);
  const auto outstanding = outstanding_.find(operation.operation_id_);
  return valid_ && operation.seed_epoch_ == seed_epoch_ &&
         outstanding != outstanding_.end() &&
         outstanding->second == operation.seed_epoch_ &&
         operation.lanes_.size() == expected &&
         operation.transitions_.size() == expected &&
         (operation.lane_mask_.empty() ||
          operation.lane_mask_.size() == expected) &&
         tile_versions_match_locked(
             operation.first_tile_x_, operation.first_tile_y_,
             operation.tile_columns_, operation.tile_rows_,
             operation.tile_versions_);
}

std::uint64_t XochitlHistoryState::generation() const {
  std::lock_guard lock(mutex_);
  return generation_;
}

std::size_t XochitlHistoryState::outstanding_count() const {
  std::lock_guard lock(mutex_);
  return outstanding_.size();
}

std::size_t XochitlHistoryState::owned_plane_storage_bytes() const {
  std::lock_guard lock(mutex_);
  return committed_.capacity() * sizeof(HistoryPixel) +
         tile_versions_.capacity() * sizeof(std::uint64_t);
}

std::optional<HistoryPixel> XochitlHistoryState::pixel(std::int32_t x,
                                                       std::int32_t y) const {
  std::lock_guard lock(mutex_);
  if (!valid_ || x < 0 || y < 0 || x >= kStorageStride || y >= kStorageRows) {
    return std::nullopt;
  }
  return committed_[static_cast<std::size_t>(y) * kStorageStride + x];
}

std::vector<HistoryPixel> XochitlHistoryState::snapshot_full_plane() const {
  std::lock_guard lock(mutex_);
  return valid_ ? committed_ : std::vector<HistoryPixel>{};
}

bool XochitlHistoryState::export_full_plane_interleaved(
    std::vector<std::uint16_t> *out_interleaved_ab) const {
  if (out_interleaved_ab == nullptr) {
    return false;
  }
  out_interleaved_ab->resize(kStoragePixels * 2u);
  std::lock_guard lock(mutex_);
  if (!valid_ || !outstanding_.empty()) {
    out_interleaved_ab->clear();
    return false;
  }
  for (std::size_t pixel = 0; pixel < kStoragePixels; ++pixel) {
    (*out_interleaved_ab)[pixel * 2u] = committed_[pixel].a;
    (*out_interleaved_ab)[pixel * 2u + 1u] = committed_[pixel].b;
  }
  return true;
}

const std::array<std::uint8_t, 16> *
XochitlHistoryState::mode_palette(Mode mode) {
  switch (mode) {
  case Mode::kText:
    return &kMode1Palette;
  case Mode::kContent:
    return &kMode2Palette;
  case Mode::kUi:
    return &kMode5Palette;
  case Mode::kFull:
    return &kMode6Palette;
  case Mode::kFast:
    return &kMode7Palette;
  }
  return nullptr;
}

XochitlHistoryState::PrepareResult
XochitlHistoryState::freeze(InclusiveRect update,
                            FrozenOperation *frozen) const {
  if (frozen == nullptr || update.left < 0 || update.top < 0 ||
      update.right < update.left || update.bottom < update.top ||
      update.right >= kLogicalWidth || update.bottom >= kLogicalHeight) {
    return {.error = PrepareError::kInvalidGeometry};
  }

  const std::int64_t logical_width =
      static_cast<std::int64_t>(update.right) - update.left + 1;
  const std::int64_t logical_height =
      static_cast<std::int64_t>(update.bottom) - update.top + 1;
  const std::int64_t width = (logical_width + 7) & ~std::int64_t{7};
  const std::int64_t height = (logical_height + 1) & ~std::int64_t{1};
  const std::int64_t execution_right =
      static_cast<std::int64_t>(update.left) + width - 1;
  const std::int64_t execution_bottom =
      static_cast<std::int64_t>(update.top) + height - 1;
  if (width <= 0 || height <= 0 || execution_right >= kStorageStride ||
      execution_bottom >= kStorageRows ||
      width > std::numeric_limits<std::int32_t>::max() ||
      height > std::numeric_limits<std::int32_t>::max()) {
    return {.error = PrepareError::kInvalidGeometry};
  }

  frozen->requested = update;
  frozen->execution = {update.left, update.top,
                       static_cast<std::int32_t>(execution_right),
                       static_cast<std::int32_t>(execution_bottom)};
  frozen->width = static_cast<std::int32_t>(width);
  frozen->height = static_cast<std::int32_t>(height);

  std::lock_guard lock(mutex_);
  if (!valid_) {
    return {.error = PrepareError::kInvalidHistory};
  }
  frozen->generation = generation_;
  frozen->seed_epoch = seed_epoch_;
  frozen->history.clear();
  frozen->history.reserve(static_cast<std::size_t>(width * height));
  for (std::int32_t y = 0; y < frozen->height; ++y) {
    const std::size_t begin =
        static_cast<std::size_t>(update.top + y) * kStorageStride +
        static_cast<std::size_t>(update.left);
    frozen->history.insert(frozen->history.end(), committed_.begin() + begin,
                           committed_.begin() + begin + frozen->width);
  }
  const std::size_t first_tile_x =
      static_cast<std::size_t>(frozen->execution.left / kVersionTileWidth);
  const std::size_t last_tile_x =
      static_cast<std::size_t>(frozen->execution.right / kVersionTileWidth);
  const std::size_t first_tile_y =
      static_cast<std::size_t>(frozen->execution.top / kVersionTileHeight);
  const std::size_t last_tile_y =
      static_cast<std::size_t>(frozen->execution.bottom / kVersionTileHeight);
  frozen->first_tile_x = first_tile_x;
  frozen->first_tile_y = first_tile_y;
  frozen->tile_columns = last_tile_x - first_tile_x + 1u;
  frozen->tile_rows = last_tile_y - first_tile_y + 1u;
  frozen->tile_versions.clear();
  frozen->tile_versions.reserve(frozen->tile_columns * frozen->tile_rows);
  for (std::size_t tile_y = first_tile_y; tile_y <= last_tile_y; ++tile_y) {
    for (std::size_t tile_x = first_tile_x; tile_x <= last_tile_x; ++tile_x) {
      const std::size_t index = tile_y * kVersionTileColumns + tile_x;
      frozen->tile_versions.push_back(tile_versions_[index]);
    }
  }
  return {};
}

XochitlHistoryState::PrepareResult
XochitlHistoryState::publish(FrozenOperation &&frozen, OperationKind kind,
                             Mode mode, bool has_pending_flags,
                             std::vector<LaneJournal> lanes,
                             std::vector<std::uint16_t> transitions,
                             std::vector<std::uint8_t> lane_mask) {
  const std::size_t expected = static_cast<std::size_t>(frozen.width) *
                               static_cast<std::size_t>(frozen.height);
  if (lanes.size() != expected || transitions.size() != expected ||
      (!lane_mask.empty() && lane_mask.size() != expected)) {
    return {.error = PrepareError::kInvalidGeometry};
  }

  std::lock_guard lock(mutex_);
  if (!valid_) {
    return {.error = PrepareError::kInvalidHistory};
  }
  if (seed_epoch_ != frozen.seed_epoch) {
    return {.error = PrepareError::kStaleGeneration};
  }
  if (!tile_versions_match_locked(frozen.first_tile_x, frozen.first_tile_y,
                                  frozen.tile_columns, frozen.tile_rows,
                                  frozen.tile_versions)) {
    return {.error = PrepareError::kStaleRegion};
  }
  if (next_operation_id_ == 0 ||
      next_operation_id_ == std::numeric_limits<std::uint64_t>::max()) {
    return {.error = PrepareError::kOperationIdExhausted};
  }
  const std::uint64_t operation_id = next_operation_id_++;
  outstanding_.emplace(operation_id, frozen.seed_epoch);
  auto operation =
      std::shared_ptr<const PreparedOperation>(new PreparedOperation(
          owner_id_, operation_id, frozen.generation, kind, mode,
          frozen.requested, frozen.execution, frozen.width, frozen.height,
          has_pending_flags, std::move(lanes), std::move(transitions),
          std::move(lane_mask), frozen.seed_epoch, frozen.first_tile_x,
          frozen.first_tile_y, frozen.tile_columns, frozen.tile_rows,
          std::move(frozen.tile_versions)));
  return {.operation = std::move(operation)};
}

XochitlHistoryState::PrepareResult XochitlHistoryState::prepare_legacy(
    Mode mode, InclusiveRect update, std::span<const std::uint8_t> raw,
    std::size_t raw_stride, std::span<const std::int16_t> delta,
    std::span<const std::uint8_t> lane_mask) {
  return prepare_legacy_with_stripes(mode, update, raw, raw_stride, delta, 0,
                                     lane_mask);
}

XochitlHistoryState::PrepareResult
XochitlHistoryState::prepare_legacy_with_stripes(
    Mode mode, InclusiveRect update, std::span<const std::uint8_t> raw,
    std::size_t raw_stride, std::span<const std::int16_t> delta,
    std::size_t forced_compute_stripes,
    std::span<const std::uint8_t> lane_mask) {
  const auto *palette = mode_palette(mode);
  if (palette == nullptr || mode == Mode::kFast) {
    return {.error = PrepareError::kInvalidMode};
  }
  if (delta.size() != kTransitionCount) {
    return {.error = PrepareError::kBufferTooSmall};
  }

  FrozenOperation frozen;
  PrepareResult frozen_result = freeze(update, &frozen);
  if (frozen_result.error != PrepareError::kNone) {
    return frozen_result;
  }
  if (!raw_plane_fits(raw, raw_stride, frozen.width, frozen.height)) {
    return {.error = PrepareError::kBufferTooSmall};
  }

  const std::size_t lane_count = static_cast<std::size_t>(frozen.width) *
                                 static_cast<std::size_t>(frozen.height);
  std::vector<std::uint8_t> canonical_mask;
  if (!lane_mask.empty()) {
    if (lane_mask.size() != lane_count) {
      return {.error = PrepareError::kInvalidMask};
    }
    canonical_mask.resize(lane_count);
    std::size_t selected = 0;
    for (std::size_t lane = 0; lane < lane_count; ++lane) {
      canonical_mask[lane] = lane_mask[lane] != 0u ? 1u : 0u;
      selected += canonical_mask[lane];
    }
    if (selected == 0u) {
      return {.error = PrepareError::kInvalidMask};
    }
    if (selected == lane_count) {
      canonical_mask.clear();
    }
  }
  const std::size_t stripe_count =
      forced_compute_stripes == 0
          ? xochitl_parallel::available_compute_stripes_for_work_items(
                lane_count)
          : std::clamp<std::size_t>(forced_compute_stripes, 1u,
                                    xochitl_parallel::kMaxComputeStripes);
  // Each compute stripe owns a one-row neighbour halo at both ends. The two
  // duplicated boundary rows let halo construction and journal mapping run in
  // one worker launch without a cross-stripe barrier or shared writes.
  const std::size_t halo_stride = static_cast<std::size_t>(frozen.width) + 2u;
  std::array<std::int32_t, xochitl_parallel::kMaxComputeStripes> stripe_first{};
  std::array<std::int32_t, xochitl_parallel::kMaxComputeStripes> stripe_last{};
  std::array<std::size_t, xochitl_parallel::kMaxComputeStripes> stripe_offset{};
  std::size_t halo_rows = 0;
  for (std::size_t stripe = 0; stripe < stripe_count; ++stripe) {
    stripe_first[stripe] = static_cast<std::int32_t>(
        stripe * static_cast<std::size_t>(frozen.height) / stripe_count);
    stripe_last[stripe] = static_cast<std::int32_t>(
        (stripe + 1u) * static_cast<std::size_t>(frozen.height) / stripe_count);
    stripe_offset[stripe] = halo_rows;
    halo_rows +=
        static_cast<std::size_t>(stripe_last[stripe] - stripe_first[stripe]) +
        2u;
  }
  const std::size_t halo_count = halo_stride * halo_rows;
  std::unique_ptr<std::uint8_t[]> old_low(new std::uint8_t[halo_count]);
  std::unique_ptr<std::uint8_t[]> mapped_raw(new std::uint8_t[halo_count]);
  constexpr std::uint8_t kEqualFlag = 0x20u;
  constexpr std::uint8_t kHighFlag = 0x40u;
  constexpr std::uint8_t kOutsideOldAndEqual = 31u | kEqualFlag | kHighFlag;
  constexpr std::uint8_t kOutsideMapped = 31u | kHighFlag;
  std::vector<LaneJournal> lanes(lane_count);
  std::vector<std::uint16_t> transitions(lane_count);
  std::array<bool, xochitl_parallel::kMaxComputeStripes> stripe_invalid{};
  std::array<bool, xochitl_parallel::kMaxComputeStripes> stripe_pending{};
  const auto run_stripe = [&](std::size_t stripe) {
    const std::int32_t first_y = stripe_first[stripe];
    const std::int32_t last_y = stripe_last[stripe];
    const std::int32_t stripe_height = last_y - first_y;
    std::uint8_t *const stripe_old =
        old_low.get() + stripe_offset[stripe] * halo_stride;
    std::uint8_t *const stripe_mapped =
        mapped_raw.get() + stripe_offset[stripe] * halo_stride;
    bool invalid = false;
    for (std::int32_t local_y = 0; local_y < stripe_height + 2; ++local_y) {
      const std::int32_t y = first_y + local_y - 1;
      std::uint8_t *const old_row =
          stripe_old + static_cast<std::size_t>(local_y) * halo_stride;
      std::uint8_t *const mapped_row =
          stripe_mapped + static_cast<std::size_t>(local_y) * halo_stride;
      if (y < 0 || y >= frozen.height) {
        std::fill_n(old_row, halo_stride, kOutsideOldAndEqual);
        std::fill_n(mapped_row, halo_stride, kOutsideMapped);
        continue;
      }
      const std::uint8_t *raw_row =
          raw.data() + static_cast<std::size_t>(y) * raw_stride;
      const HistoryPixel *history_row =
          frozen.history.data() + static_cast<std::size_t>(y) * frozen.width;
      old_row[0] = kOutsideOldAndEqual;
      old_row[static_cast<std::size_t>(frozen.width) + 1u] =
          kOutsideOldAndEqual;
      mapped_row[0] = kOutsideMapped;
      mapped_row[static_cast<std::size_t>(frozen.width) + 1u] = kOutsideMapped;
      for (std::int32_t x = 0; x < frozen.width; ++x) {
        const std::uint8_t old_level =
            static_cast<std::uint8_t>(history_row[x].a & 31u);
        const std::size_t lane = static_cast<std::size_t>(y) * frozen.width +
                                 static_cast<std::size_t>(x);
        const bool selected =
            canonical_mask.empty() || canonical_mask[lane] != 0u;
        const std::uint8_t value = raw_row[x];
        const std::uint8_t index = value & 31u;
        if (selected && (index >= palette->size() || (*palette)[index] > 31u)) {
          invalid = true;
          continue;
        }
        const std::uint8_t mapped_level =
            selected ? (*palette)[index] : old_level;
        old_row[static_cast<std::size_t>(x) + 1u] = static_cast<std::uint8_t>(
            old_level | (old_level == mapped_level ? kEqualFlag : 0u) |
            (old_level > 27u ? kHighFlag : 0u));
        mapped_row[static_cast<std::size_t>(x) + 1u] =
            static_cast<std::uint8_t>(
                ((selected ? value : history_row[x].a) & 0x80u) | mapped_level |
                (mapped_level > 27u ? kHighFlag : 0u));
      }
    }
    stripe_invalid[stripe] = invalid;
    if (invalid) {
      return;
    }
    bool local_pending_flags = false;
    for (std::int32_t y = first_y; y < last_y; ++y) {
      const std::size_t tight_row = static_cast<std::size_t>(y) * frozen.width;
      const std::size_t halo_row =
          (static_cast<std::size_t>(y - first_y) + 1u) * halo_stride + 1u;
      const std::uint8_t *old_above = stripe_old + halo_row - halo_stride;
      const std::uint8_t *old_center = stripe_old + halo_row;
      const std::uint8_t *old_below = stripe_old + halo_row + halo_stride;
      const std::uint8_t *new_above = stripe_mapped + halo_row - halo_stride;
      const std::uint8_t *new_center = stripe_mapped + halo_row;
      const std::uint8_t *new_below = stripe_mapped + halo_row + halo_stride;
      const auto equal_column = [&](std::ptrdiff_t x) {
        return static_cast<int>((old_above[x] >> 5u) & 1u) +
               static_cast<int>((old_center[x] >> 5u) & 1u) +
               static_cast<int>((old_below[x] >> 5u) & 1u);
      };
      int equal_left = equal_column(-1);
      int equal_center = equal_column(0);
      int equal_right = equal_column(1);
      for (std::int32_t x = 0; x < frozen.width; ++x) {
        const std::size_t center = tight_row + static_cast<std::size_t>(x);
        const HistoryPixel old = frozen.history[center];
        const auto advance_equal_window = [&] {
          equal_left = equal_center;
          equal_center = equal_right;
          if (x + 1 < frozen.width) {
            equal_right = equal_column(static_cast<std::ptrdiff_t>(x) + 2);
          }
        };
        if (!canonical_mask.empty() && canonical_mask[center] == 0u) {
          const std::uint8_t source = static_cast<std::uint8_t>(old.a & 31u);
          const std::uint16_t transition_word = transition(source, source);
          lanes[center] = {transition_word, old.a, old.b};
          transitions[center] = transition_word;
          advance_equal_window();
          continue;
        }
        const std::uint8_t mapped_and_marker = new_center[x];
        const std::uint8_t mapped_lane = mapped_and_marker & 31u;
        const std::uint8_t source = static_cast<std::uint8_t>(old.a & 31u);

        const int equal_moore = equal_left + equal_center + equal_right;

        const int old_high_cross =
            ((old_center[x] >> 6u) & 1u) + ((old_above[x] >> 6u) & 1u) +
            ((old_below[x] >> 6u) & 1u) + ((old_center[x - 1] >> 6u) & 1u) +
            ((old_center[x + 1] >> 6u) & 1u);
        const int new_high_cross =
            ((new_center[x] >> 6u) & 1u) + ((new_above[x] >> 6u) & 1u) +
            ((new_below[x] >> 6u) & 1u) + ((new_center[x - 1] >> 6u) & 1u) +
            ((new_center[x + 1] >> 6u) & 1u);

        const bool white_continuity = (old.a & 0x80u) != 0u &&
                                      (mapped_and_marker & 0x80u) != 0u &&
                                      source > 27u;
        const bool pair31 =
            white_continuity && new_high_cross == 5 && old_high_cross <= 4;
        const bool force27 = (equal_moore == 9 || white_continuity) && !pair31;
        const std::uint8_t drive = pair31 ? 31u : force27 ? 27u : mapped_lane;
        const std::uint16_t transition_word = transition(source, drive);

        const bool carry_bit6 =
            (old.a & 0x40u) != 0u && source > 27u && mapped_lane > 27u;
        const bool set_bit6 = new_high_cross == 5 && !pair31 && !force27 &&
                              (mapped_and_marker & 0x80u) != 0u &&
                              mapped_lane > 27u;
        const std::uint16_t a2 = static_cast<std::uint16_t>(
            (mapped_lane & 31u) | (mapped_and_marker & 0x80u) |
            ((carry_bit6 || set_bit6) ? 0x40u : 0u));
        const std::int32_t history = arithmetic_shift_right_2(old.b);
        const std::uint16_t history_sum = static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(history) +
            static_cast<std::uint16_t>(delta[transition_word]));
        const std::uint16_t b2 = static_cast<std::uint16_t>(
            ((history_sum << 2) & 0xfffcu) | (force27 ? (old.b & 3u) : 0u));
        local_pending_flags |= (b2 & 3u) != 0u;
        lanes[center] = {transition_word, a2, b2};
        transitions[center] = transition_word;
        advance_equal_window();
      }
    }
    stripe_pending[stripe] = local_pending_flags;
  };
  if (stripe_count == 1u) {
    run_stripe(0);
  } else {
    xochitl_parallel::run_compute_stripes(stripe_count, run_stripe);
  }
  bool has_pending_flags = false;
  for (std::size_t stripe = 0; stripe < stripe_count; ++stripe) {
    if (stripe_invalid[stripe]) {
      return {.error = PrepareError::kUnsupportedPaletteState};
    }
    has_pending_flags |= stripe_pending[stripe];
  }
  return publish(std::move(frozen), OperationKind::kLegacy, mode,
                 has_pending_flags, std::move(lanes), std::move(transitions),
                 std::move(canonical_mask));
}

XochitlHistoryState::PrepareResult XochitlHistoryState::prepare_fast_source(
    InclusiveRect update, std::span<const std::uint8_t> raw,
    std::size_t raw_stride, float temperature_c) {
  Thermal thermal;
  if (!thermal_for(temperature_c, &thermal)) {
    return {.error = PrepareError::kInvalidTemperature};
  }
  FrozenOperation frozen;
  PrepareResult frozen_result = freeze(update, &frozen);
  if (frozen_result.error != PrepareError::kNone) {
    return frozen_result;
  }
  if (!raw_plane_fits(raw, raw_stride, frozen.width, frozen.height)) {
    return {.error = PrepareError::kBufferTooSmall};
  }

  const std::size_t lane_count = static_cast<std::size_t>(frozen.width) *
                                 static_cast<std::size_t>(frozen.height);
  std::vector<std::uint8_t> raw_snapshot;
  raw_snapshot.reserve(lane_count);
  for (std::int32_t y = 0; y < frozen.height; ++y) {
    for (std::int32_t x = 0; x < frozen.width; ++x) {
      raw_snapshot.push_back(raw[static_cast<std::size_t>(y) * raw_stride + x]);
    }
  }

  std::vector<LaneJournal> lanes;
  lanes.reserve(lane_count);
  std::vector<std::uint16_t> transitions;
  transitions.reserve(lane_count);
  bool has_pending_flags = false;
  for (std::size_t index = 0; index < lane_count; ++index) {
    const HistoryPixel old = frozen.history[index];
    const std::uint8_t raw_lane = raw_snapshot[index];
    const std::uint8_t source = static_cast<std::uint8_t>(old.a & 31u);
    const std::int32_t history = arithmetic_shift_right_2(old.b);
    const std::uint16_t flags = old.b & 3u;
    const bool white = (raw_lane & 31u) == 7u;
    const bool mismatch = (source > 27u) != white;
    const bool mid = source > 2u && source <= 27u;
    const std::int32_t trial =
        history + (white ? thermal.amplitude : -thermal.amplitude);
    const bool hit = flags != 0u && std::abs(trial) <= thermal.limit;
    const bool partner = !mismatch && hit;
    const std::uint8_t state2 =
        white ? (partner ? 30u : 28u) : (partner ? 0u : 2u);
    const std::int32_t history2 =
        (mismatch || hit) ? trial : decay_toward_zero(history);
    const std::uint16_t flags2 =
        (mismatch || mid)
            ? thermal.reset_flags
            : static_cast<std::uint16_t>(flags - (partner ? 1u : 0u));
    const std::uint16_t a2 =
        static_cast<std::uint16_t>((raw_lane & 0x80u) | state2);
    const std::uint16_t b2 = encode_history(history2, flags2);
    has_pending_flags |= flags2 != 0u;
    const std::uint16_t transition_word = transition(source, state2);
    lanes.push_back({transition_word, a2, b2});
    transitions.push_back(transition_word);
  }
  return publish(std::move(frozen), OperationKind::kFastSource, Mode::kFast,
                 has_pending_flags, std::move(lanes), std::move(transitions));
}

XochitlHistoryState::PrepareResult
XochitlHistoryState::prepare_fast_continuation(InclusiveRect update,
                                               float temperature_c) {
  Thermal thermal;
  if (!thermal_for(temperature_c, &thermal)) {
    return {.error = PrepareError::kInvalidTemperature};
  }
  FrozenOperation frozen;
  PrepareResult frozen_result = freeze(update, &frozen);
  if (frozen_result.error != PrepareError::kNone) {
    return frozen_result;
  }

  std::vector<LaneJournal> lanes;
  lanes.reserve(frozen.history.size());
  std::vector<std::uint16_t> transitions;
  transitions.reserve(frozen.history.size());
  bool has_pending_flags = false;
  for (const HistoryPixel old : frozen.history) {
    const std::uint8_t source = static_cast<std::uint8_t>(old.a & 31u);
    const std::int32_t history = arithmetic_shift_right_2(old.b);
    const std::uint16_t flags = old.b & 3u;
    const bool high = source > 27u;
    const std::int32_t trial =
        history + (high ? thermal.amplitude : -thermal.amplitude);
    const bool hit = flags != 0u && std::abs(trial) <= thermal.limit;
    const std::int32_t history2 = hit ? trial : decay_toward_zero(history);
    const std::uint16_t flags2 =
        static_cast<std::uint16_t>(flags - (hit ? 1u : 0u));
    const std::uint8_t state2 = flags == 0u ? source
                                : high      ? (hit ? 30u : 28u)
                                            : (hit ? 0u : 2u);
    const std::uint8_t drive = flags == 0u ? 27u : state2;
    const std::uint16_t a2 =
        static_cast<std::uint16_t>((old.a & 0x80u) | state2);
    const std::uint16_t b2 = encode_history(history2, flags2);
    has_pending_flags |= flags2 != 0u;
    const std::uint16_t transition_word = transition(source, drive);
    lanes.push_back({transition_word, a2, b2});
    transitions.push_back(transition_word);
  }
  return publish(std::move(frozen), OperationKind::kFastContinuation,
                 Mode::kFast, has_pending_flags, std::move(lanes),
                 std::move(transitions));
}

XochitlHistoryState::FinalizeStatus
XochitlHistoryState::commit(const PreparedOperation &operation) {
  if (operation.owner_id_ != owner_id_) {
    return FinalizeStatus::kForeignOperation;
  }
  std::lock_guard lock(mutex_);
  if (!valid_) {
    return FinalizeStatus::kInvalidHistory;
  }
  if (operation.seed_epoch_ != seed_epoch_) {
    return FinalizeStatus::kStaleGeneration;
  }
  const auto outstanding = outstanding_.find(operation.operation_id_);
  if (outstanding == outstanding_.end() ||
      outstanding->second != operation.seed_epoch_) {
    return FinalizeStatus::kNotOutstanding;
  }
  if (!tile_versions_match_locked(operation.first_tile_x_,
                                  operation.first_tile_y_,
                                  operation.tile_columns_, operation.tile_rows_,
                                  operation.tile_versions_)) {
    return FinalizeStatus::kStaleRegion;
  }
  const std::size_t expected = static_cast<std::size_t>(operation.width_) *
                               static_cast<std::size_t>(operation.height_);
  if (operation.lanes_.size() != expected ||
      operation.transitions_.size() != expected ||
      (!operation.lane_mask_.empty() &&
       operation.lane_mask_.size() != expected)) {
    invalidate_locked();
    return FinalizeStatus::kInvalidHistory;
  }

  for (std::int32_t y = 0; y < operation.height_; ++y) {
    for (std::int32_t x = 0; x < operation.width_; ++x) {
      const std::size_t tight =
          static_cast<std::size_t>(y) * operation.width_ + x;
      if (!operation.lane_mask_.empty() && operation.lane_mask_[tight] == 0u) {
        continue;
      }
      const std::size_t panel =
          static_cast<std::size_t>(operation.execution_.top + y) *
              kStorageStride +
          static_cast<std::size_t>(operation.execution_.left + x);
      const LaneJournal &lane = operation.lanes_[tight];
      committed_[panel] = {lane.a2, lane.b2};
    }
  }
  outstanding_.erase(outstanding);
  bump_generation_locked();
  stamp_tile_versions_locked(operation.first_tile_x_, operation.first_tile_y_,
                             operation.tile_columns_, operation.tile_rows_);
  return FinalizeStatus::kCommitted;
}

XochitlHistoryState::FinalizeStatus
XochitlHistoryState::discard(const PreparedOperation &operation) {
  if (operation.owner_id_ != owner_id_) {
    return FinalizeStatus::kForeignOperation;
  }
  std::lock_guard lock(mutex_);
  const auto outstanding = outstanding_.find(operation.operation_id_);
  if (outstanding == outstanding_.end()) {
    return FinalizeStatus::kNotOutstanding;
  }
  outstanding_.erase(outstanding);
  return FinalizeStatus::kDiscarded;
}

} // namespace pluto::swtcon
