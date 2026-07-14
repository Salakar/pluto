#ifndef PLUTO_PRESENTER_SWTCON_LUT_CACHE_H_
#define PLUTO_PRESENTER_SWTCON_LUT_CACHE_H_

#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace pluto::swtcon {

// One (mode, temp-bin) waveform record expanded for the per-pixel engine's
// gather loop. The layout is DECODER-NATIVE: `codes` is a straight memcpy
// of WaveformTable::phase_table(mode, bin, fnum) — indexed
// [fnum][next5 * 32 + prev5] with NO transpose step, eliminating the
// transpose bug class; golden-tested against WaveformTable::code().
struct LutRecord {
  int mode = -1;
  int temp_bin = -1;
  int phase_count = 0;  // N (cold bin worst ~238 -> ~244 KB per record)

  // phase_count * kWaveformMatrixCells 3-bit codes.
  std::vector<std::uint8_t> codes;
  // Precomputed per phase: the number of non-hold codes in the 1024-cell
  // table (scheduler emission-cost estimate) and a conservative per-pixel
  // |net impulse| bound for one played phase (0 when the phase is
  // all-hold, else 1).
  std::vector<std::uint16_t> nonhold_count;
  std::vector<std::int16_t> impulse_bound;

  const std::uint8_t* phase(int fnum) const {
    return codes.data() +
           static_cast<std::size_t>(fnum) * kWaveformMatrixCells;
  }
  // Drive code for one pixel at one phase; identical to
  // WaveformTable::code(mode, temp_bin, prev5, next5, fnum).
  std::uint8_t code(int fnum, std::uint8_t prev5, std::uint8_t next5) const {
    return phase(fnum)[(static_cast<std::size_t>(next5 & 0x1f) << 5) |
                       (prev5 & 0x1f)];
  }
};

// (mode, temp_bin)-keyed LRU cache of expanded LutRecords with pin
// refcounts:
//   - records with pin_refcount > 0 are NEVER evicted; every active tile
//     holds one pin for its whole sequence, so the engine can assert
//     residency at every admission and advance.
//   - eviction happens only when expanding a new record while at capacity;
//     when every resident record is pinned the cache grows past capacity
//     rather than failing an admission.
//
// Thread ownership: single-thread confined, no internal locking. In the
// endgame layout expansion runs on the scheduler thread; host tests
// and the CORE-stage engine drive it single-threaded. Record pointers stay
// valid until eviction (entries are heap-stable), which pinning prevents.
class LutCache final {
 public:
  struct Config {
    // Maximum resident expanded records. Default 4 (~1 MB worst with the
    // cold-bin N~238 record); the bandwidth bench sizes it for the device.
    std::size_t capacity = 4;
  };

  // `table` must outlive the cache; it is the .eink decoder surface
  // (swtcon_waveform.h) and the only source of drive codes.
  explicit LutCache(const WaveformTable* table) : LutCache(table, Config{}) {}
  LutCache(const WaveformTable* table, Config config);

  LutCache(const LutCache&) = delete;
  LutCache& operator=(const LutCache&) = delete;

  // Resident record for (mode, temp_bin), expanding on a miss (LRU eviction
  // of unpinned records first). nullptr when the table has no such record.
  const LutRecord* get(int mode, int temp_bin);

  // Residency probe: never expands, never touches LRU order. The engine's
  // advance loop uses this to ASSERT the pinned record is resident.
  const LutRecord* peek(int mode, int temp_bin) const;

  // Pin/unpin: pinned records are never evicted. pin() expands on a miss
  // and returns the record (nullptr when the table lacks the record, in
  // which case nothing was pinned).
  const LutRecord* pin(int mode, int temp_bin);
  void unpin(int mode, int temp_bin);

  bool resident(int mode, int temp_bin) const;
  int pin_refcount(int mode, int temp_bin) const;
  std::size_t resident_count() const { return entries_.size(); }
  std::uint64_t expansions() const { return expansions_; }
  std::uint64_t evictions() const { return evictions_; }

 private:
  struct Entry {
    LutRecord record;
    int pin_refcount = 0;
    std::uint64_t last_use = 0;
  };

  // Direct-mapped (mode, temp_bin) -> Entry* index for O(1) hot-path
  // lookups (peek runs per active tile per row in the engine's advance
  // sweep — the old linear scan was flagged hot). Keys outside the direct
  // range fall back to the linear scan; entries are heap-stable
  // (unique_ptr), so the cached pointers survive vector growth and only
  // eviction/insertion maintain them.
  static constexpr int kDirectModes = 16;
  static constexpr int kDirectBins = 32;
  static bool direct_key(int mode, int temp_bin, std::size_t* out) {
    if (mode < 0 || mode >= kDirectModes || temp_bin < 0 ||
        temp_bin >= kDirectBins) {
      return false;
    }
    *out = static_cast<std::size_t>(mode) * kDirectBins +
           static_cast<std::size_t>(temp_bin);
    return true;
  }

  Entry* find(int mode, int temp_bin);
  const Entry* find(int mode, int temp_bin) const;
  Entry* expand(int mode, int temp_bin);

  const WaveformTable* table_ = nullptr;
  Config config_{};
  // unique_ptr entries keep record addresses stable across vector growth.
  std::vector<std::unique_ptr<Entry>> entries_;
  std::array<Entry*, static_cast<std::size_t>(kDirectModes) * kDirectBins>
      direct_{};
  std::uint64_t use_clock_ = 0;
  std::uint64_t expansions_ = 0;
  std::uint64_t evictions_ = 0;
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_LUT_CACHE_H_
