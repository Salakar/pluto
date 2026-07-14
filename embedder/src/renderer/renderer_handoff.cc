#include "renderer/renderer_handoff.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace pluto {
namespace {

constexpr uint8_t kMagic[8] = {'P', 'L', 'R', 'H', 'N', 'D', '0', '1'};
constexpr uint32_t kWireVersion = 1;
constexpr size_t kHeaderSize = 72;
constexpr size_t kMaximumPayloadBytes = 64u * 1024u * 1024u;
constexpr uint64_t kCrc64Polynomial = 0x42f0e1eba9ea3693ULL;

using Crc64Tables = std::array<std::array<uint64_t, 256>, 8>;

constexpr Crc64Tables make_crc64_tables() {
  Crc64Tables tables{};
  for (size_t index = 0; index < tables[0].size(); ++index) {
    uint64_t value = static_cast<uint64_t>(index) << 56u;
    for (int bit = 0; bit < 8; ++bit) {
      value = (value & (uint64_t{1} << 63u)) != 0
                  ? (value << 1u) ^ kCrc64Polynomial
                  : value << 1u;
    }
    tables[0][index] = value;
  }
  for (size_t slice = 1; slice < tables.size(); ++slice) {
    for (size_t index = 0; index < tables[slice].size(); ++index) {
      const uint64_t previous = tables[slice - 1u][index];
      tables[slice][index] = (previous << 8u) ^ tables[0][previous >> 56u];
    }
  }
  return tables;
}

inline constexpr auto kCrc64Tables = make_crc64_tables();

uint64_t load_be64(const uint8_t *bytes) {
  uint64_t word = 0;
  std::memcpy(&word, bytes, sizeof(word));
  if constexpr (std::endian::native == std::endian::little) {
#if defined(__clang__) || defined(__GNUC__)
    return __builtin_bswap64(word);
#else
    return ((word & 0x00000000000000ffULL) << 56u) |
           ((word & 0x000000000000ff00ULL) << 40u) |
           ((word & 0x0000000000ff0000ULL) << 24u) |
           ((word & 0x00000000ff000000ULL) << 8u) |
           ((word & 0x000000ff00000000ULL) >> 8u) |
           ((word & 0x0000ff0000000000ULL) >> 24u) |
           ((word & 0x00ff000000000000ULL) >> 40u) |
           ((word & 0xff00000000000000ULL) >> 56u);
#endif
  }
  return word;
}

uint64_t crc64_advance_eight(uint64_t mixed) {
  return kCrc64Tables[7][(mixed >> 56u) & 0xffu] ^
         kCrc64Tables[6][(mixed >> 48u) & 0xffu] ^
         kCrc64Tables[5][(mixed >> 40u) & 0xffu] ^
         kCrc64Tables[4][(mixed >> 32u) & 0xffu] ^
         kCrc64Tables[3][(mixed >> 24u) & 0xffu] ^
         kCrc64Tables[2][(mixed >> 16u) & 0xffu] ^
         kCrc64Tables[1][(mixed >> 8u) & 0xffu] ^
         kCrc64Tables[0][mixed & 0xffu];
}

void set_reject(RendererHandoffReject value, RendererHandoffReject *out) {
  if (out != nullptr) {
    *out = value;
  }
}

uint64_t crc64(std::span<const uint8_t> bytes) {
  uint64_t crc = 0;
  const uint8_t *cursor = bytes.data();
  size_t remaining = bytes.size();
  while (remaining >= sizeof(uint64_t)) {
    crc = crc64_advance_eight(crc ^ load_be64(cursor));
    cursor += sizeof(uint64_t);
    remaining -= sizeof(uint64_t);
  }
  while (remaining != 0) {
    crc = kCrc64Tables[0][static_cast<uint8_t>((crc >> 56u) ^ *cursor++)] ^
          (crc << 8u);
    --remaining;
  }
  return crc;
}

class Writer {
public:
  explicit Writer(size_t reserve = 0) { bytes_.reserve(reserve); }

  void u8(uint8_t value) { bytes_.push_back(value); }
  void boolean(bool value) { u8(value ? 1u : 0u); }
  void u16(uint16_t value) {
    u8(static_cast<uint8_t>(value));
    u8(static_cast<uint8_t>(value >> 8u));
  }
  void u32(uint32_t value) {
    for (unsigned shift = 0; shift < 32; shift += 8) {
      u8(static_cast<uint8_t>(value >> shift));
    }
  }
  void i32(int32_t value) { u32(static_cast<uint32_t>(value)); }
  void u64(uint64_t value) {
    for (unsigned shift = 0; shift < 64; shift += 8) {
      u8(static_cast<uint8_t>(value >> shift));
    }
  }
  void f32(float value) { u32(std::bit_cast<uint32_t>(value)); }
  void raw(std::span<const uint8_t> bytes) {
    bytes_.insert(bytes_.end(), bytes.begin(), bytes.end());
  }
  void zeros(size_t count) { bytes_.resize(bytes_.size() + count, 0); }
  void vector_u8(const std::vector<uint8_t> &values) {
    u64(values.size());
    raw(values);
  }
  void vector_u16(const std::vector<uint16_t> &values) {
    u64(values.size());
    for (uint16_t value : values) {
      u16(value);
    }
  }
  void vector_u32(const std::vector<uint32_t> &values) {
    u64(values.size());
    for (uint32_t value : values) {
      u32(value);
    }
  }
  void vector_u64(const std::vector<uint64_t> &values) {
    u64(values.size());
    for (uint64_t value : values) {
      u64(value);
    }
  }

  const std::vector<uint8_t> &bytes() const { return bytes_; }
  std::vector<uint8_t> &mutable_bytes() { return bytes_; }
  std::vector<uint8_t> take() { return std::move(bytes_); }

private:
  std::vector<uint8_t> bytes_;
};

class Reader {
public:
  explicit Reader(std::span<const uint8_t> bytes) : bytes_(bytes) {}

  uint8_t u8() {
    if (!need(1)) {
      return 0;
    }
    return bytes_[offset_++];
  }
  bool boolean() {
    const uint8_t value = u8();
    if (value > 1u) {
      ok_ = false;
    }
    return value != 0;
  }
  uint16_t u16() {
    uint16_t value = 0;
    for (unsigned shift = 0; shift < 16; shift += 8) {
      value |= static_cast<uint16_t>(u8()) << shift;
    }
    return value;
  }
  uint32_t u32() {
    uint32_t value = 0;
    for (unsigned shift = 0; shift < 32; shift += 8) {
      value |= static_cast<uint32_t>(u8()) << shift;
    }
    return value;
  }
  int32_t i32() { return static_cast<int32_t>(u32()); }
  uint64_t u64() {
    uint64_t value = 0;
    for (unsigned shift = 0; shift < 64; shift += 8) {
      value |= static_cast<uint64_t>(u8()) << shift;
    }
    return value;
  }
  float f32() { return std::bit_cast<float>(u32()); }

  std::vector<uint8_t> vector_u8() {
    const size_t count = count_for(1);
    if (!ok_) {
      return {};
    }
    std::vector<uint8_t> result(bytes_.begin() + offset_,
                                bytes_.begin() + offset_ + count);
    offset_ += count;
    return result;
  }
  std::vector<uint16_t> vector_u16() {
    const size_t count = count_for(2);
    std::vector<uint16_t> result;
    if (!ok_) {
      return result;
    }
    result.reserve(count);
    for (size_t i = 0; i < count; ++i) {
      result.push_back(u16());
    }
    return result;
  }
  std::vector<uint32_t> vector_u32() {
    const size_t count = count_for(4);
    std::vector<uint32_t> result;
    if (!ok_) {
      return result;
    }
    result.reserve(count);
    for (size_t i = 0; i < count; ++i) {
      result.push_back(u32());
    }
    return result;
  }
  std::vector<uint64_t> vector_u64() {
    const size_t count = count_for(8);
    std::vector<uint64_t> result;
    if (!ok_) {
      return result;
    }
    result.reserve(count);
    for (size_t i = 0; i < count; ++i) {
      result.push_back(u64());
    }
    return result;
  }

  bool ok() const { return ok_; }
  size_t remaining() const { return bytes_.size() - offset_; }
  void invalidate() { ok_ = false; }

private:
  bool need(size_t count) {
    if (!ok_ || count > bytes_.size() - offset_) {
      ok_ = false;
      return false;
    }
    return true;
  }
  size_t count_for(size_t element_size) {
    const uint64_t wire_count = u64();
    if (!ok_ || wire_count > std::numeric_limits<size_t>::max()) {
      ok_ = false;
      return 0;
    }
    const size_t count = static_cast<size_t>(wire_count);
    if (element_size == 0 || count > remaining() / element_size) {
      ok_ = false;
      return 0;
    }
    return count;
  }

  std::span<const uint8_t> bytes_;
  size_t offset_ = 0;
  bool ok_ = true;
};

size_t format_bytes(PlutoPixelFormat format) {
  switch (format) {
  case kPlutoPixelFormatGray8:
    return 1;
  case kPlutoPixelFormatRgb565:
    return 2;
  case kPlutoPixelFormatXrgb8888:
    return 4;
  }
  return 0;
}

bool valid_rotation(uint32_t rotation) {
  return rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270;
}

void write_rect(Writer &writer, const PlutoRect &rect) {
  writer.i32(rect.x);
  writer.i32(rect.y);
  writer.i32(rect.width);
  writer.i32(rect.height);
}

PlutoRect read_rect(Reader &reader) {
  return PlutoRect{reader.i32(), reader.i32(), reader.i32(), reader.i32()};
}

void write_grid(Writer &writer, const TileGrid &grid) {
  writer.i32(grid.width);
  writer.i32(grid.height);
  writer.u32(grid.tile_px);
  writer.u32(grid.cols);
  writer.u32(grid.rows);
}

TileGrid read_grid(Reader &reader) {
  TileGrid grid;
  grid.width = reader.i32();
  grid.height = reader.i32();
  grid.tile_px = reader.u32();
  grid.cols = reader.u32();
  grid.rows = reader.u32();
  return grid;
}

void write_renderer_config(Writer &writer, const RendererConfig &config) {
  writer.u32(config.tile_px);
  writer.u8(config.chroma_floor);
  writer.u8(static_cast<uint8_t>(config.dither_mask));
  writer.u32(config.settle_quiesce_ms);
  writer.u32(config.pen_hover_radius_px);
  writer.u32(config.pen_contact_radius_px);
  writer.u32(config.pen_changed_pixel_area_scale);
  writer.u32(config.pen_max_preview_area_percent);
  writer.u32(config.ghost_tau_ms);
  writer.u16(config.ghost_debt_settle_threshold);
  writer.u16(config.stress_settle_threshold);
  writer.u16(config.ghost_debt_promote_threshold);
  writer.u32(config.ghost_promote_min_gap_ms);
  writer.u32(config.settle_full_area_percent);
  writer.u32(config.settle_max_rects);
  writer.u32(config.settle_cluster_gap_px);
  writer.u32(config.settle_cluster_max_waste_px);
  writer.u32(config.cbs_settle_budget_pct);
  writer.u32(config.guard_px);
  writer.boolean(config.flag_map_enabled);
  writer.boolean(config.nas_enabled);
  writer.u32(config.scroll_min_band_rows);
  writer.u32(config.scroll_max_dy);
  writer.u32(config.scroll_body_emit_px);
}

RendererConfig read_renderer_config(Reader &reader) {
  RendererConfig config;
  config.tile_px = reader.u32();
  config.chroma_floor = reader.u8();
  const uint8_t dither = reader.u8();
  if (dither !=
      static_cast<uint8_t>(RendererConfig::DitherMask::kBlueNoise64)) {
    // Mark malformed without inventing a future enum value.
    reader.invalidate();
    return config;
  }
  config.dither_mask = static_cast<RendererConfig::DitherMask>(dither);
  config.settle_quiesce_ms = reader.u32();
  config.pen_hover_radius_px = reader.u32();
  config.pen_contact_radius_px = reader.u32();
  config.pen_changed_pixel_area_scale = reader.u32();
  config.pen_max_preview_area_percent = reader.u32();
  config.ghost_tau_ms = reader.u32();
  config.ghost_debt_settle_threshold = reader.u16();
  config.stress_settle_threshold = reader.u16();
  config.ghost_debt_promote_threshold = reader.u16();
  config.ghost_promote_min_gap_ms = reader.u32();
  config.settle_full_area_percent = reader.u32();
  config.settle_max_rects = reader.u32();
  config.settle_cluster_gap_px = reader.u32();
  config.settle_cluster_max_waste_px = reader.u32();
  config.cbs_settle_budget_pct = reader.u32();
  config.guard_px = reader.u32();
  config.flag_map_enabled = reader.boolean();
  config.nas_enabled = reader.boolean();
  config.scroll_min_band_rows = reader.u32();
  config.scroll_max_dy = reader.u32();
  config.scroll_body_emit_px = reader.u32();
  return config;
}

void write_perception(Writer &writer, const PerceptionConstants &perception) {
  writer.u16(perception.ghost_debt_settle_threshold());
  writer.u16(perception.stress_settle_threshold());
  writer.u32(perception.quiesce_ms());
  writer.u32(perception.ghost_tau_ms());
  writer.u32(perception.settle_full_area_percent());
  writer.u32(perception.settle_max_rects());
  writer.u32(perception.settle_cluster_gap_px());
  writer.u32(perception.settle_cluster_max_waste_px());
  writer.u32(perception.cbs_settle_budget_pct());
}

PerceptionConstants read_perception(Reader &reader) {
  RendererConfig config;
  config.ghost_debt_settle_threshold = reader.u16();
  config.stress_settle_threshold = reader.u16();
  config.settle_quiesce_ms = reader.u32();
  config.ghost_tau_ms = reader.u32();
  config.settle_full_area_percent = reader.u32();
  config.settle_max_rects = reader.u32();
  config.settle_cluster_gap_px = reader.u32();
  config.settle_cluster_max_waste_px = reader.u32();
  config.cbs_settle_budget_pct = reader.u32();
  return PerceptionConstants(config);
}

void write_frame_ledger(Writer &writer, const FrameLedgerState &state) {
  writer.u32(state.version);
  writer.u32(state.config.width);
  writer.u32(state.config.height);
  writer.u32(state.config.tile_px);
  writer.u64(state.stride);
  writer.u64(state.chroma_stride);
  writer.u32(state.epoch);
  writer.u32(state.cur_hash);
  writer.vector_u8(state.levels);
  writer.vector_u8(state.chroma_bits);
  writer.vector_u32(state.row_hash[0]);
  writer.vector_u32(state.row_hash[1]);
  // row_samples/row_sample_epoch are intra-pass scroll-verification scratch,
  // not persistent history. A future begin_pass increments the ledger epoch
  // before any sample can be queried and re-snapshots every candidate row.
  // Omitting this dead cache makes quiescent handoffs canonical across a
  // full seeded reconciliation vs. an equivalent bounded live pass and saves
  // 204,384 bytes on the Move.
  writer.u64(state.stats.size());
  for (const TileStats &stats : state.stats) {
    writer.u16(stats.changed_px);
    writer.u16(stats.sad_pre_dither);
    writer.u8(stats.max_diff);
    writer.u8(stats.level_hist_lo);
    writer.u16(stats.level_hist);
    writer.u8(stats.chroma_frac);
    writer.u8(stats.motion_class);
    writer.u8(stats.changed_chroma);
    write_rect(writer, stats.dirty);
    writer.u32(stats.epoch);
  }
}

FrameLedgerState read_frame_ledger(Reader &reader) {
  FrameLedgerState state;
  state.version = reader.u32();
  state.config.width = reader.u32();
  state.config.height = reader.u32();
  state.config.tile_px = reader.u32();
  state.stride = reader.u64();
  state.chroma_stride = reader.u64();
  state.epoch = reader.u32();
  state.cur_hash = reader.u32();
  state.levels = reader.vector_u8();
  state.chroma_bits = reader.vector_u8();
  state.row_hash[0] = reader.vector_u32();
  state.row_hash[1] = reader.vector_u32();
  // Reconstruct the correctly-sized invalid scratch cache. Zero stamps can
  // never match a live epoch (begin_pass starts at one), and candidate rows
  // are overwritten before the scroll verifier reads them.
  if (state.config.height == 0 || state.stride == 0 ||
      state.stride > std::numeric_limits<size_t>::max()) {
    reader.invalidate();
    return state;
  }
  const uint64_t sample_rows =
      (static_cast<uint64_t>(state.config.height) - 1u) /
          FrameLedger::kRowSamplePeriod +
      1u;
  if (sample_rows > std::numeric_limits<size_t>::max() ||
      sample_rows > kMaximumPayloadBytes / sizeof(uint32_t) ||
      state.stride > kMaximumPayloadBytes / sample_rows) {
    reader.invalidate();
    return state;
  }
  state.row_samples.assign(static_cast<size_t>(sample_rows * state.stride), 0u);
  state.row_sample_epoch.assign(static_cast<size_t>(sample_rows), 0u);
  const uint64_t count = reader.u64();
  if (count > reader.remaining() / 31u ||
      count > std::numeric_limits<size_t>::max()) {
    reader.invalidate();
    return state;
  }
  state.stats.reserve(static_cast<size_t>(count));
  for (uint64_t i = 0; i < count; ++i) {
    TileStats stats{};
    stats.changed_px = reader.u16();
    stats.sad_pre_dither = reader.u16();
    stats.max_diff = reader.u8();
    stats.level_hist_lo = reader.u8();
    stats.level_hist = reader.u16();
    stats.chroma_frac = reader.u8();
    stats.motion_class = reader.u8();
    stats.changed_chroma = reader.u8();
    stats.dirty = read_rect(reader);
    stats.epoch = reader.u32();
    state.stats.push_back(stats);
  }
  return state;
}

void write_ladder_config(Writer &writer, const ClassifyLadderConfig &config) {
  writer.i32(config.width);
  writer.i32(config.height);
  writer.u32(config.tile_px);
  writer.u32(config.motion_streak);
  writer.u32(config.motion_tile_percent);
  writer.u32(config.motion_cooldown_epochs);
  writer.boolean(config.nas_enabled);
  for (uint32_t value : config.nas_k_q8) {
    writer.u32(value);
  }
  writer.u32(config.nas_tau_q8);
  writer.u32(config.nas_l);
  writer.u32(config.scenecut_coverage_percent);
  writer.u8(config.scenecut_intensity_min);
  writer.u32(config.scenecut_ghost_bias_percent);
  writer.u32(config.scenecut_cooldown_epochs);
  writer.u32(config.full_screen_area_percent);
  writer.u32(config.dwell_hot_epochs);
  writer.u32(config.dwell_cold_epochs);
  writer.u32(config.text_area_percent);
}

ClassifyLadderConfig read_ladder_config(Reader &reader) {
  ClassifyLadderConfig config;
  config.width = reader.i32();
  config.height = reader.i32();
  config.tile_px = reader.u32();
  config.motion_streak = reader.u32();
  config.motion_tile_percent = reader.u32();
  config.motion_cooldown_epochs = reader.u32();
  config.nas_enabled = reader.boolean();
  for (uint32_t &value : config.nas_k_q8) {
    value = reader.u32();
  }
  config.nas_tau_q8 = reader.u32();
  config.nas_l = reader.u32();
  config.scenecut_coverage_percent = reader.u32();
  config.scenecut_intensity_min = reader.u8();
  config.scenecut_ghost_bias_percent = reader.u32();
  config.scenecut_cooldown_epochs = reader.u32();
  config.full_screen_area_percent = reader.u32();
  config.dwell_hot_epochs = reader.u32();
  config.dwell_cold_epochs = reader.u32();
  config.text_area_percent = reader.u32();
  return config;
}

void write_ladder(Writer &writer, const ClassifyLadderState &state) {
  writer.u32(state.version);
  write_ladder_config(writer, state.config);
  writer.u32(state.epoch);
  writer.u64(state.history.size());
  for (const ClassifyTileHistoryState &history : state.history) {
    writer.u32(history.last_epoch);
    writer.u32(history.prev_epoch);
    writer.u32(history.streak);
    writer.u32(history.fast_until);
    writer.u32(history.scenecut_epoch);
    write_rect(writer, history.last_dirty);
  }
}

ClassifyLadderState read_ladder(Reader &reader) {
  ClassifyLadderState state;
  state.version = reader.u32();
  state.config = read_ladder_config(reader);
  state.epoch = reader.u32();
  const uint64_t count = reader.u64();
  constexpr size_t kHistoryWireBytes = 36;
  if (count > reader.remaining() / kHistoryWireBytes ||
      count > std::numeric_limits<size_t>::max()) {
    reader.invalidate();
    return state;
  }
  state.history.reserve(static_cast<size_t>(count));
  for (uint64_t i = 0; i < count; ++i) {
    ClassifyTileHistoryState history;
    history.last_epoch = reader.u32();
    history.prev_epoch = reader.u32();
    history.streak = reader.u32();
    history.fast_until = reader.u32();
    history.scenecut_epoch = reader.u32();
    history.last_dirty = read_rect(reader);
    state.history.push_back(history);
  }
  return state;
}

void write_ghost(Writer &writer, const GhostLedgerState &state) {
  writer.u32(state.version);
  write_grid(writer, state.grid);
  writer.u32(state.tau_ms);
  writer.u16(state.owed_threshold);
  writer.u64(state.last_decay_us);
  writer.boolean(state.clock_started);
  writer.u64(state.active_lo);
  writer.u64(state.active_hi);
  writer.vector_u16(state.debt);
  writer.vector_u8(state.owed);
}

GhostLedgerState read_ghost(Reader &reader) {
  GhostLedgerState state;
  state.version = reader.u32();
  state.grid = read_grid(reader);
  state.tau_ms = reader.u32();
  state.owed_threshold = reader.u16();
  state.last_decay_us = reader.u64();
  state.clock_started = reader.boolean();
  state.active_lo = reader.u64();
  state.active_hi = reader.u64();
  state.debt = reader.vector_u16();
  state.owed = reader.vector_u8();
  return state;
}

void write_stress(Writer &writer, const StressLedgerState &state) {
  writer.u32(state.version);
  write_grid(writer, state.grid);
  writer.u64(state.last_decay_us);
  writer.boolean(state.clock_started);
  writer.u64(state.active_lo);
  writer.u64(state.active_hi);
  writer.vector_u16(state.stress);
}

StressLedgerState read_stress(Reader &reader) {
  StressLedgerState state;
  state.version = reader.u32();
  state.grid = read_grid(reader);
  state.last_decay_us = reader.u64();
  state.clock_started = reader.boolean();
  state.active_lo = reader.u64();
  state.active_hi = reader.u64();
  state.stress = reader.vector_u16();
  return state;
}

void write_chroma(Writer &writer, const ChromaPendingState &state) {
  writer.u32(state.version);
  write_grid(writer, state.grid);
  writer.u64(state.pending_count);
  writer.vector_u8(state.pending);
}

ChromaPendingState read_chroma(Reader &reader) {
  ChromaPendingState state;
  state.version = reader.u32();
  state.grid = read_grid(reader);
  state.pending_count = reader.u64();
  state.pending = reader.vector_u8();
  return state;
}

void write_planner_config(Writer &writer, const SettlePlannerConfig &config) {
  writer.i32(config.width);
  writer.i32(config.height);
  writer.u32(config.tile_px);
  writer.u32(config.align_px);
  writer.boolean(config.panel_is_color);
  writer.boolean(config.enable_sparkle_topoff);
  write_perception(writer, config.perception);
}

SettlePlannerConfig read_planner_config(Reader &reader) {
  SettlePlannerConfig config;
  config.width = reader.i32();
  config.height = reader.i32();
  config.tile_px = reader.u32();
  config.align_px = reader.u32();
  config.panel_is_color = reader.boolean();
  config.enable_sparkle_topoff = reader.boolean();
  config.perception = read_perception(reader);
  return config;
}

void write_planner(Writer &writer, const SettlePlannerState &state) {
  writer.u32(state.version);
  write_planner_config(writer, state.config);
  writer.vector_u64(state.last_damage_us);
  writer.u64(state.forced.size());
  for (const SettlePlannerForcedState &forced : state.forced) {
    write_rect(writer, forced.rect);
    writer.u64(forced.ready_us);
  }
  writer.u64(state.emitted_settles);
  writer.u64(state.emitted_full_flashes);
  writer.u64(state.emitted_sparkles);
  write_rect(writer, state.sparkle_rect);
  writer.u32(state.sparkle_phase);
  writer.u64(state.sparkle_next_us);
}

SettlePlannerState read_planner(Reader &reader) {
  SettlePlannerState state;
  state.version = reader.u32();
  state.config = read_planner_config(reader);
  state.last_damage_us = reader.vector_u64();
  const uint64_t count = reader.u64();
  if (count > reader.remaining() / 24u ||
      count > std::numeric_limits<size_t>::max()) {
    reader.invalidate();
    return state;
  }
  state.forced.reserve(static_cast<size_t>(count));
  for (uint64_t i = 0; i < count; ++i) {
    state.forced.push_back(
        SettlePlannerForcedState{read_rect(reader), reader.u64()});
  }
  state.emitted_settles = reader.u64();
  state.emitted_full_flashes = reader.u64();
  state.emitted_sparkles = reader.u64();
  state.sparkle_rect = read_rect(reader);
  state.sparkle_phase = reader.u32();
  state.sparkle_next_us = reader.u64();
  return state;
}

void write_auto_config(Writer &writer, const AutoGhostbusterConfig &config) {
  writer.u16(config.ghost_tile_threshold_q8);
  writer.u16(config.yellow_tile_threshold_q8);
  writer.u8(config.ghost_display_percent);
  writer.u8(config.yellow_display_percent);
  writer.u8(config.ghost_low_water_percent);
  writer.u8(config.yellow_low_water_percent);
  writer.u64(config.damage_quiescence_us);
  writer.u64(config.input_release_grace_us);
  writer.u64(config.cooldown_us);
  writer.u64(config.scan_cadence_us);
  writer.u64(config.failure_retry_initial_us);
  writer.u64(config.failure_retry_max_us);
  writer.boolean(config.pigment_hygiene_supported);
}

AutoGhostbusterConfig read_auto_config(Reader &reader) {
  AutoGhostbusterConfig config;
  config.ghost_tile_threshold_q8 = reader.u16();
  config.yellow_tile_threshold_q8 = reader.u16();
  config.ghost_display_percent = reader.u8();
  config.yellow_display_percent = reader.u8();
  config.ghost_low_water_percent = reader.u8();
  config.yellow_low_water_percent = reader.u8();
  config.damage_quiescence_us = reader.u64();
  config.input_release_grace_us = reader.u64();
  config.cooldown_us = reader.u64();
  config.scan_cadence_us = reader.u64();
  config.failure_retry_initial_us = reader.u64();
  config.failure_retry_max_us = reader.u64();
  config.pigment_hygiene_supported = reader.boolean();
  return config;
}

void write_auto_plane(Writer &writer, const AutoGhostbusterPlaneState &state) {
  writer.vector_u16(state.debt);
  writer.vector_u64(state.remainder);
  writer.vector_u8(state.qualified);
  writer.u64(state.qualified_pixels);
  writer.boolean(state.latched);
}

AutoGhostbusterPlaneState read_auto_plane(Reader &reader) {
  AutoGhostbusterPlaneState state;
  state.debt = reader.vector_u16();
  state.remainder = reader.vector_u64();
  state.qualified = reader.vector_u8();
  state.qualified_pixels = reader.u64();
  state.latched = reader.boolean();
  return state;
}

void write_auto(Writer &writer, const AutoGhostbusterState &state) {
  writer.u32(state.version);
  write_grid(writer, state.grid);
  write_auto_config(writer, state.config);
  writer.u64(state.display_pixels);
  write_auto_plane(writer, state.ghost);
  write_auto_plane(writer, state.yellow);
  write_auto_plane(writer, state.active_ghost);
  write_auto_plane(writer, state.active_yellow);
  writer.boolean(state.touch_active);
  writer.boolean(state.pen_active);
  writer.boolean(state.have_input_event);
  writer.boolean(state.have_input_release);
  writer.u64(state.last_input_release_us);
  writer.u64(state.last_input_event_us);
  writer.boolean(state.have_damage);
  writer.u64(state.last_damage_us);
  writer.u64(state.next_scan_us);
  writer.u64(state.cooldown_until_us);
  writer.u64(state.retry_not_before_us);
  writer.u32(state.consecutive_failures);
  writer.u8(static_cast<uint8_t>(state.active_decision));
}

AutoGhostbusterState read_auto(Reader &reader) {
  AutoGhostbusterState state;
  state.version = reader.u32();
  state.grid = read_grid(reader);
  state.config = read_auto_config(reader);
  state.display_pixels = reader.u64();
  state.ghost = read_auto_plane(reader);
  state.yellow = read_auto_plane(reader);
  state.active_ghost = read_auto_plane(reader);
  state.active_yellow = read_auto_plane(reader);
  state.touch_active = reader.boolean();
  state.pen_active = reader.boolean();
  state.have_input_event = reader.boolean();
  state.have_input_release = reader.boolean();
  state.last_input_release_us = reader.u64();
  state.last_input_event_us = reader.u64();
  state.have_damage = reader.boolean();
  state.last_damage_us = reader.u64();
  state.next_scan_us = reader.u64();
  state.cooldown_until_us = reader.u64();
  state.retry_not_before_us = reader.u64();
  state.consecutive_failures = reader.u32();
  const uint8_t decision = reader.u8();
  if (decision > static_cast<uint8_t>(AutoGhostbusterDecision::kBoth)) {
    // Preserve parsing alignment while guaranteeing validation fails.
    state.active_decision = static_cast<AutoGhostbusterDecision>(0xffu);
  } else {
    state.active_decision = static_cast<AutoGhostbusterDecision>(decision);
  }
  return state;
}

void write_scheduler_config(Writer &writer,
                            const RegionSchedulerStateConfig &config) {
  writer.i32(config.width);
  writer.i32(config.height);
  writer.u32(config.align_px);
  writer.u32(config.presenter_rotation);
  writer.u32(config.pen_collision_tile_px);
  writer.boolean(config.serialize_pen_truth_by_tile);
  writer.u32(config.merge_gap_px);
  for (uint8_t value : config.max_rects) {
    writer.u8(value);
  }
  for (uint32_t value : config.class_deadline_us) {
    writer.u32(value);
  }
  for (uint32_t value : config.latency_model_us) {
    writer.u32(value);
  }
  writer.f32(config.fence_margin);
  writer.u32(config.fence_timeout_ms);
  writer.u32(config.cbs_settle_budget_pct);
  writer.u16(config.debt_promote_threshold);
  writer.u32(config.debt_promote_min_gap_us);
  writer.boolean(config.text_settle_nonintrusive);
  writer.boolean(config.presenter_reports_completion);
  writer.boolean(config.presenter_collision_safe);
  writer.u64(config.surface_stride_bytes);
  writer.i32(config.surface_width);
  writer.i32(config.surface_height);
  writer.u32(config.surface_format);
}

RegionSchedulerStateConfig read_scheduler_config(Reader &reader) {
  RegionSchedulerStateConfig config;
  config.width = reader.i32();
  config.height = reader.i32();
  config.align_px = reader.u32();
  config.presenter_rotation = reader.u32();
  config.pen_collision_tile_px = reader.u32();
  config.serialize_pen_truth_by_tile = reader.boolean();
  config.merge_gap_px = reader.u32();
  for (uint8_t &value : config.max_rects) {
    value = reader.u8();
  }
  for (uint32_t &value : config.class_deadline_us) {
    value = reader.u32();
  }
  for (uint32_t &value : config.latency_model_us) {
    value = reader.u32();
  }
  config.fence_margin = reader.f32();
  config.fence_timeout_ms = reader.u32();
  config.cbs_settle_budget_pct = reader.u32();
  config.debt_promote_threshold = reader.u16();
  config.debt_promote_min_gap_us = reader.u32();
  config.text_settle_nonintrusive = reader.boolean();
  config.presenter_reports_completion = reader.boolean();
  config.presenter_collision_safe = reader.boolean();
  config.surface_stride_bytes = reader.u64();
  config.surface_width = reader.i32();
  config.surface_height = reader.i32();
  config.surface_format = reader.u32();
  return config;
}

void write_scheduler(Writer &writer, const RegionSchedulerState &state) {
  writer.u32(state.version);
  write_scheduler_config(writer, state.config);
  writer.boolean(state.has_debt_grid);
  write_grid(writer, state.debt_grid);
  writer.u64(state.next_frame_id);
  writer.u64(state.damage_epoch);
  writer.u64(state.cbs_total_slots);
  writer.u64(state.cbs_settle_slots);
  writer.vector_u64(state.last_submit_us);
}

RegionSchedulerState read_scheduler(Reader &reader) {
  RegionSchedulerState state;
  state.version = reader.u32();
  state.config = read_scheduler_config(reader);
  state.has_debt_grid = reader.boolean();
  state.debt_grid = read_grid(reader);
  state.next_frame_id = reader.u64();
  state.damage_epoch = reader.u64();
  state.cbs_total_slots = reader.u64();
  state.cbs_settle_slots = reader.u64();
  state.last_submit_us = reader.vector_u64();
  return state;
}

void write_top_config(Writer &writer, const RendererHandoffState &state) {
  writer.u32(state.version);
  writer.u32(state.width);
  writer.u32(state.height);
  writer.u32(state.rotation);
  writer.u32(static_cast<uint32_t>(state.pixel_format));
  writer.u32(static_cast<uint32_t>(state.presenter_format));
  writer.u64(state.retained_stride);
  write_renderer_config(writer, state.renderer_config);
  writer.boolean(state.start_presenter_thread);
  writer.boolean(state.presenter_pen_focus_from_host);
  writer.boolean(state.enable_present_bridge);
  writer.boolean(state.display_info_available);
  writer.boolean(state.present_bridge_active);
  writer.boolean(state.mirror_enabled);
  writer.boolean(state.enable_auto_ghostbuster);
  writer.boolean(state.pigment_hygiene_supported);
  writer.boolean(state.panel_is_color);
  writer.boolean(state.backend_quantizes_color);
  writer.boolean(state.presenter_controls_refresh_class);
}

void write_configuration(Writer &writer, const RendererHandoffState &state) {
  write_top_config(writer, state);
  writer.u32(state.frame_ledger.version);
  writer.u32(state.frame_ledger.config.width);
  writer.u32(state.frame_ledger.config.height);
  writer.u32(state.frame_ledger.config.tile_px);
  writer.u64(state.frame_ledger.stride);
  writer.u64(state.frame_ledger.chroma_stride);
  writer.u32(state.classify_ladder.version);
  write_ladder_config(writer, state.classify_ladder.config);
  writer.u32(state.ghost_ledger.version);
  write_grid(writer, state.ghost_ledger.grid);
  writer.u32(state.ghost_ledger.tau_ms);
  writer.u16(state.ghost_ledger.owed_threshold);
  writer.u32(state.stress_ledger.version);
  write_grid(writer, state.stress_ledger.grid);
  writer.u32(state.chroma_pending.version);
  write_grid(writer, state.chroma_pending.grid);
  writer.u32(state.settle_planner.version);
  write_planner_config(writer, state.settle_planner.config);
  writer.u32(state.auto_ghostbuster.version);
  write_grid(writer, state.auto_ghostbuster.grid);
  write_auto_config(writer, state.auto_ghostbuster.config);
  writer.u64(state.auto_ghostbuster.display_pixels);
  writer.u32(state.region_scheduler.version);
  write_scheduler_config(writer, state.region_scheduler.config);
  writer.boolean(state.region_scheduler.has_debt_grid);
  write_grid(writer, state.region_scheduler.debt_grid);
}

void write_body(Writer &writer, const RendererHandoffState &state) {
  write_top_config(writer, state);
  writer.vector_u8(state.retained_frame);
  writer.u32(state.scroll_pending_px);
  writer.i32(state.scroll_ledger_shift_px);
  writer.u64(state.scroll_moves);
  writer.u8(state.active_input_mask);
  writer.u64(state.last_input_change_us);
  writer.u64(state.automatic_ghost_actions);
  write_frame_ledger(writer, state.frame_ledger);
  write_ladder(writer, state.classify_ladder);
  write_ghost(writer, state.ghost_ledger);
  write_stress(writer, state.stress_ledger);
  write_chroma(writer, state.chroma_pending);
  write_planner(writer, state.settle_planner);
  write_auto(writer, state.auto_ghostbuster);
  write_scheduler(writer, state.region_scheduler);
}

RendererHandoffState read_body(Reader &reader) {
  RendererHandoffState state;
  state.version = reader.u32();
  state.width = reader.u32();
  state.height = reader.u32();
  state.rotation = reader.u32();
  state.pixel_format = static_cast<PlutoPixelFormat>(reader.u32());
  state.presenter_format = static_cast<PlutoPixelFormat>(reader.u32());
  state.retained_stride = reader.u64();
  state.renderer_config = read_renderer_config(reader);
  state.start_presenter_thread = reader.boolean();
  state.presenter_pen_focus_from_host = reader.boolean();
  state.enable_present_bridge = reader.boolean();
  state.display_info_available = reader.boolean();
  state.present_bridge_active = reader.boolean();
  state.mirror_enabled = reader.boolean();
  state.enable_auto_ghostbuster = reader.boolean();
  state.pigment_hygiene_supported = reader.boolean();
  state.panel_is_color = reader.boolean();
  state.backend_quantizes_color = reader.boolean();
  state.presenter_controls_refresh_class = reader.boolean();
  state.retained_frame = reader.vector_u8();
  state.scroll_pending_px = reader.u32();
  state.scroll_ledger_shift_px = reader.i32();
  state.scroll_moves = reader.u64();
  state.active_input_mask = reader.u8();
  state.last_input_change_us = reader.u64();
  state.automatic_ghost_actions = reader.u64();
  state.frame_ledger = read_frame_ledger(reader);
  state.classify_ladder = read_ladder(reader);
  state.ghost_ledger = read_ghost(reader);
  state.stress_ledger = read_stress(reader);
  state.chroma_pending = read_chroma(reader);
  state.settle_planner = read_planner(reader);
  state.auto_ghostbuster = read_auto(reader);
  state.region_scheduler = read_scheduler(reader);
  return state;
}

RegionSchedulerConfig
scheduler_config_from_state(const RegionSchedulerStateConfig &state,
                            uint8_t *pixels) {
  RegionSchedulerConfig config;
  config.width = state.width;
  config.height = state.height;
  config.align_px = state.align_px;
  config.presenter_rotation = state.presenter_rotation;
  config.pen_collision_tile_px = state.pen_collision_tile_px;
  config.serialize_pen_truth_by_tile = state.serialize_pen_truth_by_tile;
  config.merge_gap_px = state.merge_gap_px;
  config.max_rects = state.max_rects;
  config.class_deadline_us = state.class_deadline_us;
  config.latency_model_us = state.latency_model_us;
  config.fence_margin = state.fence_margin;
  config.fence_timeout_ms = state.fence_timeout_ms;
  config.cbs_settle_budget_pct = state.cbs_settle_budget_pct;
  config.debt_promote_threshold = state.debt_promote_threshold;
  config.debt_promote_min_gap_us = state.debt_promote_min_gap_us;
  config.text_settle_nonintrusive = state.text_settle_nonintrusive;
  config.presenter_reports_completion = state.presenter_reports_completion;
  config.presenter_collision_safe = state.presenter_collision_safe;
  config.surface =
      PlutoSurface{pixels, static_cast<size_t>(state.surface_stride_bytes),
                   state.surface_width, state.surface_height,
                   static_cast<PlutoPixelFormat>(state.surface_format)};
  return config;
}

bool same_grid(const TileGrid &left, const TileGrid &right) {
  return left.width == right.width && left.height == right.height &&
         left.tile_px == right.tile_px && left.cols == right.cols &&
         left.rows == right.rows;
}

} // namespace

const char *renderer_handoff_reject_name(RendererHandoffReject reject) {
  switch (reject) {
  case RendererHandoffReject::kNone:
    return "none";
  case RendererHandoffReject::kArgument:
    return "argument";
  case RendererHandoffReject::kTooLarge:
    return "too-large";
  case RendererHandoffReject::kTruncated:
    return "truncated";
  case RendererHandoffReject::kMagic:
    return "magic";
  case RendererHandoffReject::kVersion:
    return "version";
  case RendererHandoffReject::kHeader:
    return "header";
  case RendererHandoffReject::kChecksum:
    return "checksum";
  case RendererHandoffReject::kConfiguration:
    return "configuration";
  case RendererHandoffReject::kGeometry:
    return "geometry";
  case RendererHandoffReject::kFormat:
    return "format";
  case RendererHandoffReject::kState:
    return "state";
  case RendererHandoffReject::kTrailingData:
    return "trailing-data";
  }
  return "unknown";
}

uint64_t
renderer_handoff_configuration_hash(const RendererHandoffState &state) {
  Writer writer(512);
  write_configuration(writer, state);
  return crc64(writer.bytes());
}

bool renderer_handoff_validate(const RendererHandoffState &state) {
  const size_t bpp = format_bytes(state.pixel_format);
  if (state.version != RendererHandoffState::kVersion || state.width == 0 ||
      state.height == 0 || !valid_rotation(state.rotation) || bpp == 0 ||
      format_bytes(state.presenter_format) == 0 ||
      state.width > std::numeric_limits<size_t>::max() / bpp ||
      state.retained_stride != static_cast<uint64_t>(state.width) * bpp ||
      state.height >
          std::numeric_limits<size_t>::max() / state.retained_stride ||
      state.retained_frame.size() != state.retained_stride * state.height ||
      state.scroll_pending_px >=
          std::max<uint32_t>(1u, state.renderer_config.scroll_body_emit_px) ||
      state.active_input_mask != 0 ||
      state.frame_ledger.config.width != state.width ||
      state.frame_ledger.config.height != state.height ||
      state.frame_ledger.config.tile_px != state.renderer_config.tile_px ||
      state.classify_ladder.config.width != static_cast<int32_t>(state.width) ||
      state.classify_ladder.config.height !=
          static_cast<int32_t>(state.height) ||
      state.classify_ladder.config.tile_px != state.renderer_config.tile_px ||
      state.settle_planner.config.width != static_cast<int32_t>(state.width) ||
      state.settle_planner.config.height !=
          static_cast<int32_t>(state.height) ||
      state.settle_planner.config.tile_px != state.renderer_config.tile_px ||
      state.settle_planner.config.panel_is_color != state.panel_is_color ||
      state.auto_ghostbuster.config.pigment_hygiene_supported !=
          state.pigment_hygiene_supported ||
      state.auto_ghostbuster.touch_active ||
      state.auto_ghostbuster.pen_active ||
      state.region_scheduler.config.width !=
          static_cast<int32_t>(state.width) ||
      state.region_scheduler.config.height !=
          static_cast<int32_t>(state.height) ||
      state.region_scheduler.config.presenter_rotation != state.rotation ||
      state.region_scheduler.config.surface_stride_bytes !=
          state.retained_stride ||
      state.region_scheduler.config.surface_width !=
          static_cast<int32_t>(state.width) ||
      state.region_scheduler.config.surface_height !=
          static_cast<int32_t>(state.height) ||
      state.region_scheduler.config.surface_format !=
          static_cast<uint32_t>(state.pixel_format) ||
      !std::isfinite(state.region_scheduler.config.fence_margin) ||
      state.region_scheduler.config.fence_margin <= 0.0f ||
      state.region_scheduler.next_frame_id == 0 ||
      state.auto_ghostbuster.active_decision !=
          AutoGhostbusterDecision::kNone ||
      (state.present_bridge_active &&
       (!state.enable_present_bridge || !state.display_info_available)) ||
      state.mirror_enabled != (state.pixel_format == kPlutoPixelFormatRgb565 ||
                               !state.present_bridge_active)) {
    return false;
  }

  TileGrid expected_grid;
  if (!expected_grid.configure(static_cast<int32_t>(state.width),
                               static_cast<int32_t>(state.height),
                               state.renderer_config.tile_px) ||
      !same_grid(state.ghost_ledger.grid, expected_grid) ||
      !same_grid(state.stress_ledger.grid, expected_grid) ||
      !same_grid(state.chroma_pending.grid, expected_grid) ||
      !same_grid(state.auto_ghostbuster.grid, expected_grid) ||
      (state.region_scheduler.has_debt_grid &&
       !same_grid(state.region_scheduler.debt_grid, expected_grid))) {
    return false;
  }

  // A physical seed may not carry unknown logical levels. Padded stride bytes
  // are permitted to retain FrameLedger's invalid sentinel.
  if (state.frame_ledger.levels.size() !=
      state.frame_ledger.stride * state.height) {
    return false;
  }
  for (uint32_t y = 0; y < state.height; ++y) {
    const size_t row = static_cast<size_t>(y) * state.frame_ledger.stride;
    for (uint32_t x = 0; x < state.width; ++x) {
      if (state.frame_ledger.levels[row + x] > 31u) {
        return false;
      }
    }
  }

  // Component imports are the authoritative exhaustive validators. All are
  // exercised against scratch objects, so failure cannot partially mutate a
  // live renderer transaction.
  FrameLedger frame;
  if (!frame.configure(state.frame_ledger.config) ||
      !frame.import_state(state.frame_ledger)) {
    return false;
  }
  ClassifyLadder ladder;
  if (!ladder.configure(state.classify_ladder.config) ||
      !ladder.import_state(state.classify_ladder)) {
    return false;
  }
  GhostLedger ghost;
  StressLedger stress;
  ChromaPendingSet chroma;
  if (!ghost.configure(state.ghost_ledger.grid, state.ghost_ledger.tau_ms,
                       state.ghost_ledger.owed_threshold) ||
      !ghost.import_state(state.ghost_ledger) ||
      !stress.configure(state.stress_ledger.grid) ||
      !stress.import_state(state.stress_ledger) ||
      !chroma.configure(state.chroma_pending.grid) ||
      !chroma.import_state(state.chroma_pending)) {
    return false;
  }
  SettlePlanner planner;
  if (!planner.configure(state.settle_planner.config, &ghost, &stress,
                         &chroma) ||
      !planner.import_state(state.settle_planner)) {
    return false;
  }
  AutoGhostbuster ghostbuster;
  if (!ghostbuster.configure(state.auto_ghostbuster.grid,
                             state.auto_ghostbuster.config) ||
      !ghostbuster.import_state(state.auto_ghostbuster)) {
    return false;
  }
  std::vector<uint8_t> scratch_surface = state.retained_frame;
  RegionScheduler scheduler(
      scheduler_config_from_state(state.region_scheduler.config,
                                  scratch_surface.data()),
      {}, &ghost, &stress, &chroma);
  return scheduler.valid() && scheduler.import_state(state.region_scheduler);
}

bool renderer_handoff_encode(const RendererHandoffState &state,
                             std::vector<uint8_t> *out,
                             RendererHandoffReject *reject) {
  set_reject(RendererHandoffReject::kNone, reject);
  if (out == nullptr) {
    set_reject(RendererHandoffReject::kArgument, reject);
    return false;
  }
  if (!renderer_handoff_validate(state)) {
    set_reject(RendererHandoffReject::kState, reject);
    return false;
  }

  if (state.retained_frame.size() > kMaximumPayloadBytes - kHeaderSize) {
    set_reject(RendererHandoffReject::kTooLarge, reject);
    return false;
  }
  // RGB565's retained plane dominates the Move payload; its ledger/history
  // companions are bounded below three quarters of that plane. Reserving the
  // correlated bundle in one allocation avoids both a growth copy and the
  // allocator's roughly 7.5 MiB capacity class for today's 5.5 MiB wire image.
  // A future format with a different ratio can still grow normally.
  const size_t base_reserve = kHeaderSize + state.retained_frame.size();
  const size_t companion_reserve =
      state.retained_frame.size() - state.retained_frame.size() / 4u;
  const size_t reserve = base_reserve > kMaximumPayloadBytes - companion_reserve
                             ? kMaximumPayloadBytes
                             : base_reserve + companion_reserve;
  Writer encoded(reserve);
  encoded.zeros(kHeaderSize);
  write_body(encoded, state);
  if (encoded.bytes().size() > kMaximumPayloadBytes) {
    set_reject(RendererHandoffReject::kTooLarge, reject);
    return false;
  }
  const uint64_t configuration_hash =
      renderer_handoff_configuration_hash(state);
  const std::span<const uint8_t> body(encoded.bytes().data() + kHeaderSize,
                                      encoded.bytes().size() - kHeaderSize);

  Writer header(kHeaderSize);
  header.raw(kMagic);
  header.u32(kWireVersion);
  header.u32(kHeaderSize);
  header.u64(encoded.bytes().size());
  header.u64(configuration_hash);
  header.u32(state.width);
  header.u32(state.height);
  header.u32(state.rotation);
  header.u32(static_cast<uint32_t>(state.pixel_format));
  header.u64(state.retained_stride);
  header.u64(crc64(body));
  header.u64(crc64(header.bytes()));
  if (header.bytes().size() != kHeaderSize) {
    set_reject(RendererHandoffReject::kHeader, reject);
    return false;
  }

  std::copy(header.bytes().begin(), header.bytes().end(),
            encoded.mutable_bytes().begin());
  *out = encoded.take();
  return true;
}

bool renderer_handoff_decode(std::span<const uint8_t> bytes,
                             uint64_t expected_configuration_hash,
                             RendererHandoffState *out,
                             RendererHandoffReject *reject) {
  set_reject(RendererHandoffReject::kNone, reject);
  if (out == nullptr) {
    set_reject(RendererHandoffReject::kArgument, reject);
    return false;
  }
  if (bytes.size() < kHeaderSize) {
    set_reject(RendererHandoffReject::kTruncated, reject);
    return false;
  }
  if (bytes.size() > kMaximumPayloadBytes) {
    set_reject(RendererHandoffReject::kTooLarge, reject);
    return false;
  }
  if (!std::equal(std::begin(kMagic), std::end(kMagic), bytes.begin())) {
    set_reject(RendererHandoffReject::kMagic, reject);
    return false;
  }

  Reader header(bytes.first(kHeaderSize));
  for (size_t i = 0; i < sizeof(kMagic); ++i) {
    (void)header.u8();
  }
  const uint32_t version = header.u32();
  const uint32_t header_size = header.u32();
  const uint64_t total_size = header.u64();
  const uint64_t configuration_hash = header.u64();
  const uint32_t width = header.u32();
  const uint32_t height = header.u32();
  const uint32_t rotation = header.u32();
  const uint32_t format = header.u32();
  const uint64_t stride = header.u64();
  const uint64_t body_checksum = header.u64();
  const uint64_t header_checksum = header.u64();
  if (!header.ok() || header.remaining() != 0 || header_size != kHeaderSize ||
      total_size != bytes.size()) {
    set_reject(RendererHandoffReject::kHeader, reject);
    return false;
  }
  if (version != kWireVersion) {
    set_reject(RendererHandoffReject::kVersion, reject);
    return false;
  }
  if (header_checksum != crc64(bytes.first(kHeaderSize - sizeof(uint64_t))) ||
      body_checksum != crc64(bytes.subspan(kHeaderSize))) {
    set_reject(RendererHandoffReject::kChecksum, reject);
    return false;
  }
  if (configuration_hash != expected_configuration_hash) {
    set_reject(RendererHandoffReject::kConfiguration, reject);
    return false;
  }
  if (width == 0 || height == 0 || !valid_rotation(rotation)) {
    set_reject(RendererHandoffReject::kGeometry, reject);
    return false;
  }
  const auto pixel_format = static_cast<PlutoPixelFormat>(format);
  if (format_bytes(pixel_format) == 0) {
    set_reject(RendererHandoffReject::kFormat, reject);
    return false;
  }
  if (stride != static_cast<uint64_t>(width) * format_bytes(pixel_format)) {
    set_reject(RendererHandoffReject::kGeometry, reject);
    return false;
  }

  Reader body(bytes.subspan(kHeaderSize));
  RendererHandoffState decoded = read_body(body);
  if (!body.ok()) {
    set_reject(RendererHandoffReject::kTruncated, reject);
    return false;
  }
  if (body.remaining() != 0) {
    set_reject(RendererHandoffReject::kTrailingData, reject);
    return false;
  }
  if (decoded.width != width || decoded.height != height ||
      decoded.rotation != rotation || decoded.pixel_format != pixel_format ||
      decoded.retained_stride != stride) {
    set_reject(RendererHandoffReject::kGeometry, reject);
    return false;
  }
  if (renderer_handoff_configuration_hash(decoded) != configuration_hash) {
    set_reject(RendererHandoffReject::kConfiguration, reject);
    return false;
  }
  if (!renderer_handoff_validate(decoded)) {
    set_reject(RendererHandoffReject::kState, reject);
    return false;
  }
  *out = std::move(decoded);
  return true;
}

} // namespace pluto
