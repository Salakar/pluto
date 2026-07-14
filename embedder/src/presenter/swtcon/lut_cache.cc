#include "presenter/swtcon/lut_cache.h"

#include <cassert>
#include <cstring>

namespace pluto::swtcon {

namespace {

// Per-op impulse sign of a 3-bit drive code: 0 = hold, 1-3 push-white,
// 4-7 push-black (refined by E2). Used here only for the conservative
// per-phase impulse bound; the authoritative charge map lives in
// DcLedgerConfig.
inline int impulse_sign(std::uint8_t code) {
  const std::uint8_t c = code & 0x7;
  if (c == 0) {
    return 0;
  }
  return c <= 3 ? 1 : -1;
}

}  // namespace

LutCache::LutCache(const WaveformTable* table, Config config)
    : table_(table), config_(config) {
  if (config_.capacity == 0) {
    config_.capacity = 1;
  }
  entries_.reserve(config_.capacity + 1);
}

LutCache::Entry* LutCache::find(int mode, int temp_bin) {
  std::size_t key;
  if (direct_key(mode, temp_bin, &key)) {
    return direct_[key];  // O(1) hot path (engine advance peeks per tile)
  }
  for (auto& entry : entries_) {
    if (entry->record.mode == mode && entry->record.temp_bin == temp_bin) {
      return entry.get();
    }
  }
  return nullptr;
}

const LutCache::Entry* LutCache::find(int mode, int temp_bin) const {
  std::size_t key;
  if (direct_key(mode, temp_bin, &key)) {
    return direct_[key];
  }
  for (const auto& entry : entries_) {
    if (entry->record.mode == mode && entry->record.temp_bin == temp_bin) {
      return entry.get();
    }
  }
  return nullptr;
}

LutCache::Entry* LutCache::expand(int mode, int temp_bin) {
  if (table_ == nullptr) {
    return nullptr;
  }
  const int phase_count = table_->phase_count(mode, temp_bin);
  if (phase_count <= 0) {
    return nullptr;
  }

  // Make room BEFORE inserting so the returned record can never be the one
  // evicted. Only unpinned records are candidates; when everything resident
  // is pinned the cache grows past capacity (admissions must not fail).
  while (entries_.size() >= config_.capacity) {
    std::size_t victim = entries_.size();
    std::uint64_t oldest = 0;
    for (std::size_t i = 0; i < entries_.size(); ++i) {
      if (entries_[i]->pin_refcount > 0) {
        continue;
      }
      if (victim == entries_.size() || entries_[i]->last_use < oldest) {
        victim = i;
        oldest = entries_[i]->last_use;
      }
    }
    if (victim == entries_.size()) {
      break;  // everything pinned
    }
    std::size_t victim_key;
    if (direct_key(entries_[victim]->record.mode,
                   entries_[victim]->record.temp_bin, &victim_key)) {
      direct_[victim_key] = nullptr;
    }
    entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(victim));
    ++evictions_;
  }

  auto entry = std::make_unique<Entry>();
  LutRecord& record = entry->record;
  record.mode = mode;
  record.temp_bin = temp_bin;
  record.phase_count = phase_count;
  record.codes.resize(static_cast<std::size_t>(phase_count) *
                      kWaveformMatrixCells);
  record.nonhold_count.assign(static_cast<std::size_t>(phase_count), 0);
  record.impulse_bound.assign(static_cast<std::size_t>(phase_count), 0);

  for (int phase = 0; phase < phase_count; ++phase) {
    const std::uint8_t* src = table_->phase_table(mode, temp_bin, phase);
    assert(src != nullptr);
    std::uint8_t* dst =
        record.codes.data() +
        static_cast<std::size_t>(phase) * kWaveformMatrixCells;
    // Decoder-native orientation: the table is already [next5*32 + prev5];
    // a straight memcpy, no transpose.
    std::memcpy(dst, src, kWaveformMatrixCells);

    std::uint16_t nonhold = 0;
    std::int16_t bound = 0;
    for (int cell = 0; cell < kWaveformMatrixCells; ++cell) {
      const std::uint8_t code = dst[cell] & 0x7;
      if (code != 0) {
        ++nonhold;
      }
      const int impulse = impulse_sign(code);
      const std::int16_t magnitude =
          static_cast<std::int16_t>(impulse < 0 ? -impulse : impulse);
      if (magnitude > bound) {
        bound = magnitude;
      }
    }
    record.nonhold_count[static_cast<std::size_t>(phase)] = nonhold;
    record.impulse_bound[static_cast<std::size_t>(phase)] = bound;
  }

  ++expansions_;
  entries_.push_back(std::move(entry));
  std::size_t key;
  if (direct_key(mode, temp_bin, &key)) {
    direct_[key] = entries_.back().get();
  }
  return entries_.back().get();
}

const LutRecord* LutCache::get(int mode, int temp_bin) {
  Entry* entry = find(mode, temp_bin);
  if (entry == nullptr) {
    entry = expand(mode, temp_bin);
    if (entry == nullptr) {
      return nullptr;
    }
  }
  entry->last_use = ++use_clock_;
  return &entry->record;
}

const LutRecord* LutCache::peek(int mode, int temp_bin) const {
  const Entry* entry = find(mode, temp_bin);
  return entry != nullptr ? &entry->record : nullptr;
}

const LutRecord* LutCache::pin(int mode, int temp_bin) {
  Entry* entry = find(mode, temp_bin);
  if (entry == nullptr) {
    entry = expand(mode, temp_bin);
    if (entry == nullptr) {
      return nullptr;
    }
  }
  entry->last_use = ++use_clock_;
  ++entry->pin_refcount;
  return &entry->record;
}

void LutCache::unpin(int mode, int temp_bin) {
  Entry* entry = find(mode, temp_bin);
  assert(entry != nullptr && "unpin of a non-resident record");
  if (entry == nullptr) {
    return;
  }
  assert(entry->pin_refcount > 0 && "unbalanced unpin");
  if (entry->pin_refcount > 0) {
    --entry->pin_refcount;
  }
}

bool LutCache::resident(int mode, int temp_bin) const {
  return find(mode, temp_bin) != nullptr;
}

int LutCache::pin_refcount(int mode, int temp_bin) const {
  const Entry* entry = find(mode, temp_bin);
  return entry != nullptr ? entry->pin_refcount : 0;
}

}  // namespace pluto::swtcon
