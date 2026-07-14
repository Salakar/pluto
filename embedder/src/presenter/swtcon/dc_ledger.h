#ifndef PLUTO_PRESENTER_SWTCON_DC_LEDGER_H_
#define PLUTO_PRESENTER_SWTCON_DC_LEDGER_H_

#include <algorithm>
#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pluto::swtcon {

// Constants of the DC-balance ledger. Every field carries its experiment
// tag; defaults are conservative placeholders until the E2 torture run
// calibrates them on glass.
struct DcLedgerConfig {
  // Saturation cap for the per-pixel net-impulse plane: +-64 of the int8
  // +-127 range (E2).
  std::int8_t dc_pixel_cap = 64;

  // Per-op impulse map, indexed by 3-bit drive code: 0 = hold, 1-3
  // push-white (+1), 4-7 push-black (-1); E2 refines the code->rail
  // mapping.
  std::array<std::int8_t, 8> impulse_map = {0, 1, 1, 1, -1, -1, -1, -1};

  // trust_vendor_balance deviation model (E2-gated):
  // completion of a FULL sequence in a balanced mode resets dc[px] := 0, so
  // saturation can never mask truncation debt.
  bool trust_vendor_balance = true;

  // Vendor DC-balanced waveform modes: the flashing GC16 family {2, 5, 6}
  // by drive signature (E1/E2).
  std::uint16_t balanced_mode_mask = (1u << 2) | (1u << 5) | (1u << 6);

  // Per-tile stress charges (all E2-tagged placeholders): per early cancel
  // / truncation, per neutral-frame miss on an active tile, per detected
  // double-scan.
  std::uint16_t k_cancel = 4;
  std::uint16_t k_pause = 1;
  std::uint16_t k_dscan = 2;

  // Stress above which the NEXT update on the tile is forced into a
  // balanced quality mode (E2).
  std::uint16_t dc_stress_force = 24;

  friend bool operator==(const DcLedgerConfig &,
                         const DcLedgerConfig &) = default;
};

// Quiescent, behavior-bearing state carried across embedder processes.
// `dc` includes every stride-padding pixel. Estimated-prev bits are
// deliberately absent: exporting is legal only when none remain, and import
// always installs an all-clear estimate plane.
struct DcLedgerHandoffState {
  int width = 0;
  int height = 0;
  int stride = 0;
  std::uint32_t tile_px = 0;
  std::uint32_t tile_cols = 0;
  std::uint32_t tile_rows = 0;
  DcLedgerConfig config{};
  std::vector<std::int8_t> dc;
  std::vector<std::uint16_t> stress;
  std::vector<std::int32_t> rescan_dc;

  friend bool operator==(const DcLedgerHandoffState &,
                         const DcLedgerHandoffState &) = default;
};

// DcLedger: saturating per-pixel int8 net-impulse plane + the `prev_est`
// 1 bpp side plane + the per-tile stress accumulator. Charged for EVERY
// emitted op — including guard-band and settle identity transitions — by
// the engine's advance loop.
//
// Thread ownership: engine-thread confined, no internal locking;
// hot-path methods are inline. Host tests drive it single-threaded.
class DcLedger final {
 public:
  DcLedger() = default;
  DcLedger(const DcLedger&) = delete;
  DcLedger& operator=(const DcLedger&) = delete;

  // Geometry mirrors the engine planes: `stride` px per row (padded, must
  // be a multiple of 8 for the byte-aligned prev_est bitplane rows),
  // `tile_px` matches the engine tile grid. Returns false on bad geometry.
  bool configure(int width, int height, int stride, std::uint32_t tile_px,
                 const DcLedgerConfig& config);
  bool valid() const { return valid_; }
  const DcLedgerConfig& config() const { return config_; }

  // Export/import are all-or-nothing. Export refuses estimated optical state.
  // Import validates geometry, configuration, exact vector lengths, and every
  // bounded element before changing the live ledger. Saturation counters are
  // diagnostics rather than future-behavior state and restart at zero.
  bool export_handoff_state(DcLedgerHandoffState *out) const;
  bool handoff_state_valid(const DcLedgerHandoffState &state) const;
  bool import_handoff_state(const DcLedgerHandoffState &state);

  std::uint32_t tile_cols() const { return tile_cols_; }
  std::uint32_t tile_rows() const { return tile_rows_; }
  std::size_t tile_count() const {
    return static_cast<std::size_t>(tile_cols_) * tile_rows_;
  }

  // ---- per-pixel impulse (hot path) ------------------------------------

  int impulse(std::uint8_t code) const {
    return config_.impulse_map[code & 0x7];
  }

  // Saturating charge of one emitted op. Every add that would push |dc|
  // past dc_pixel_cap clamps and counts one saturation.
  void charge(std::size_t px, std::uint8_t code) {
    const int impulse_value = config_.impulse_map[code & 0x7];
    if (impulse_value == 0) {
      return;
    }
    const int cap = config_.dc_pixel_cap;
    const int sum = dc_[px] + impulse_value;
    if (sum > cap) {
      dc_[px] = static_cast<std::int8_t>(cap);
      ++saturations_;
    } else if (sum < -cap) {
      dc_[px] = static_cast<std::int8_t>(-cap);
      ++saturations_;
    } else {
      dc_[px] = static_cast<std::int8_t>(sum);
    }
  }

  // Full-sequence completion at one pixel (waveform boundary): the
  // optical state is trusted again (prev_est cleared); under the
  // trust_vendor_balance deviation model a balanced-mode completion also
  // renormalizes dc[px] := 0.
  void renormalize_on_completion(std::size_t px, int mode) {
    clear_prev_estimated(px);
    if (config_.trust_vendor_balance && balanced_mode(mode)) {
      dc_[px] = 0;
    }
  }

  bool balanced_mode(int mode) const {
    return mode >= 0 && mode < 16 &&
           ((config_.balanced_mode_mask >> mode) & 1u) != 0;
  }

  std::int8_t dc(std::size_t px) const { return dc_[px]; }
  std::uint64_t saturations() const { return saturations_; }

  // Fused-sweep plane access (engine hot path, sweep_kernels.{h,cc}): the
  // sweep kernel charges/renormalizes the dc plane and clears prev_est bits
  // in place with EXACTLY the charge()/renormalize_on_completion semantics
  // above (golden-tested), then reports its clamp count here.
  std::int8_t* dc_data() { return dc_.data(); }
  std::uint8_t* prev_est_data() { return prev_est_.data(); }
  void add_saturations(std::uint64_t count) { saturations_ += count; }

  // O(1) warm-handoff safety oracle: number of pixels whose prev level is
  // only an estimate of what reached glass. An idle engine is not sufficient
  // evidence of optical truth: a sparse cross-mode pen preemption can
  // estimate the interrupted target, drive only replacement pixels that
  // differ, and leave same-target pixels with no waveform to clear them.
  std::size_t prev_estimated_count() const { return prev_estimated_count_; }

  // ---- prev_est bitplane (set on truncation/retarget, cleared only on
  // full-sequence completion) ---------------------------------------------

  void mark_prev_estimated(std::size_t px) {
    const std::uint8_t mask = static_cast<std::uint8_t>(1u << (px & 7));
    std::uint8_t& byte = prev_est_[px >> 3];
    if ((byte & mask) == 0) {
      byte = static_cast<std::uint8_t>(byte | mask);
      ++prev_estimated_count_;
    }
  }
  void clear_prev_estimated(std::size_t px) {
    const std::uint8_t mask = static_cast<std::uint8_t>(1u << (px & 7));
    std::uint8_t& byte = prev_est_[px >> 3];
    if ((byte & mask) != 0) {
      byte = static_cast<std::uint8_t>(byte & ~mask);
      assert(prev_estimated_count_ > 0);
      --prev_estimated_count_;
    }
  }
  bool prev_estimated(std::size_t px) const {
    return (prev_est_[px >> 3] >> (px & 7)) & 1u;
  }
  // The fused scalar/NEON sweep clears bits in bulk through prev_est_data().
  // Each kernel reports exactly how many 1->0 transitions it performed;
  // retire that count in the same engine-thread sweep transaction.
  void account_sweep_prev_estimated_clears(std::size_t count) {
    assert(count <= prev_estimated_count_);
    prev_estimated_count_ -= count;
  }
  // A trusted external glass seed replaces every logical prev value, so no
  // estimate may survive the seed even if seed_prev() is called from an idle
  // but estimate-bearing test/recovery state.
  void clear_all_prev_estimated() {
    std::fill(prev_est_.begin(), prev_est_.end(), 0);
    prev_estimated_count_ = 0;
  }

  // ---- per-tile stress accumulator --------------------------------------

  void charge_truncation(std::size_t tile) {
    stress_[tile] = saturating_add(stress_[tile], config_.k_cancel);
  }
  void charge_pause(std::size_t tile) {
    stress_[tile] = saturating_add(stress_[tile], config_.k_pause);
  }
  // `count` extra scans at once (double-scan recharges coalesce; the
  // charge is linear in the extra-scan count).
  void charge_double_scan(std::size_t tile, std::uint64_t count = 1) {
    const std::uint64_t delta =
        static_cast<std::uint64_t>(config_.k_dscan) * count;
    stress_[tile] = saturating_add(
        stress_[tile], delta > 0xffffu ? static_cast<std::uint16_t>(0xffffu)
                                       : static_cast<std::uint16_t>(delta));
  }
  // stress > dc_stress_force forces the tile's next update into a balanced
  // quality mode; the completed balanced pass repays it.
  bool forces_balanced(std::size_t tile) const {
    return stress_[tile] > config_.dc_stress_force;
  }
  void clear_stress(std::size_t tile) {
    stress_[tile] = 0;
    rescan_dc_[tile] = 0;  // the balanced pass repays the rescan debt too
  }
  std::uint16_t stress(std::size_t tile) const { return stress_[tile]; }

  // ---- aggregate rescan account (double-scan recharge) -------------------
  // Per-tile signed net impulse of EXTRA hardware scans of already-emitted
  // planes, charged from the presenter's build-time impulse summaries. The
  // per-pixel dc plane is never touched here and the recharge path never
  // reads the WC dumb buffers (device livelock fix: a 1.24 MB uncached
  // read per gap starved the engine). Saturates at the plane-level
  // equivalent of the pixel cap (dc_pixel_cap x tile area); every clamp
  // counts one saturation. clear_stress (a completed balanced pass)
  // repays it.
  void charge_rescan(std::size_t tile, std::int64_t impulse) {
    if (impulse == 0) {
      return;
    }
    const std::int64_t cap = rescan_tile_cap_;
    const std::int64_t sum =
        static_cast<std::int64_t>(rescan_dc_[tile]) + impulse;
    if (sum > cap) {
      rescan_dc_[tile] = static_cast<std::int32_t>(cap);
      ++saturations_;
    } else if (sum < -cap) {
      rescan_dc_[tile] = static_cast<std::int32_t>(-cap);
      ++saturations_;
    } else {
      rescan_dc_[tile] = static_cast<std::int32_t>(sum);
    }
  }
  std::int32_t rescan_dc(std::size_t tile) const { return rescan_dc_[tile]; }

 private:
  static std::uint16_t saturating_add(std::uint16_t value,
                                      std::uint16_t delta) {
    const std::uint32_t sum =
        static_cast<std::uint32_t>(value) + static_cast<std::uint32_t>(delta);
    return sum > 0xffffu ? static_cast<std::uint16_t>(0xffffu)
                         : static_cast<std::uint16_t>(sum);
  }

  bool valid_ = false;
  DcLedgerConfig config_{};
  int width_ = 0;
  int height_ = 0;
  int stride_ = 0;
  std::uint32_t tile_px_ = 0;
  std::uint32_t tile_cols_ = 0;
  std::uint32_t tile_rows_ = 0;
  std::uint64_t saturations_ = 0;
  std::int64_t rescan_tile_cap_ = 0;   // dc_pixel_cap * tile_px^2
  std::vector<std::int8_t> dc_;        // stride * height
  std::vector<std::uint8_t> prev_est_; // stride / 8 * height, 1 bpp
  std::size_t prev_estimated_count_ = 0;  // exact popcount(prev_est_)
  std::vector<std::uint16_t> stress_;  // tile grid
  std::vector<std::int32_t> rescan_dc_;  // tile grid, aggregate rescans
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_DC_LEDGER_H_
