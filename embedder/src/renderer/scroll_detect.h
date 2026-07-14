#ifndef PLUTO_RENDERER_SCROLL_DETECT_H_
#define PLUTO_RENDERER_SCROLL_DETECT_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/frame_ledger.h"

namespace pluto {

// ScrollDetector: the row-hash majority-vote MOVE(dy) detector over the
// FrameLedger's ping-pong row hashes. Runs between TilePass and
// classification — the hashes are produced for free inside the fused pass.
//
// Algorithm (pixel-exact, microsecond-class):
//   1. Distinctive-row filter: within the damaged band, rows whose hash
//      repeats (blank rows, striped patterns) are skipped on BOTH sides of
//      the vote — repeated content cannot testify to a unique offset.
//   2. Majority vote: every distinctive current row matching a distinctive
//      previous row votes for dy = y_cur - y_prev (0 < |dy| <= max_dy).
//      Ties break toward the smaller |dy| (scroll deltas are locality-
//      bounded per frame).
//   3. VERIFY before accepting (secondary-hash discipline): >= verify_rows
//      sampled voting pairs are memcmp'd byte-exact against the TRUE
//      previous-pass pixels the tile pass snapshotted into the ledger's
//      row-sample plane. Any mismatch (hash collision, torn content)
//      rejects the whole MOVE.
//
// Scope: whole-row hashes detect full-width vertical translation only —
// the dominant e-reader gesture. A scroll viewport narrower than the
// logical row (static sidebar) never matches and safely falls through to
// the classify ladder. Quantized-plane caveat: the blue-noise dither is
// position-keyed, so only content whose quantized bytes are translation-
// invariant (rails: text, line art) votes; continuous-tone rows simply
// abstain, they never produce false votes.
//
// Thread ownership: raster-thread confined (FrameRenderer submit path).
// Pre-allocated scratch; no per-frame heap in steady state.
struct ScrollDetectConfig {
  int32_t width = 954;
  int32_t height = 1696;
  // Bands smaller than this (rows, or rows*width px of area) skip the vote:
  // small damage is cheaper to just classify.
  int32_t min_band_rows = 64;
  int64_t min_band_area_px = 60000;  // x11vnc scr_area shape
  int32_t max_dy = 128;              // per-frame locality bound
  uint32_t min_votes = 24;           // absolute evidence floor
  uint32_t majority_percent = 60;    // of all votes cast across every dy
  uint32_t verify_rows = 3;          // sampled memcmp confirmations required
};

struct ScrollMove {
  // Translation: new[y] == old[y - dy]. dy > 0 = content moved down,
  // dy < 0 = content moved up (the reading-scroll direction).
  int32_t dy = 0;
  PlutoRect band{0, 0, 0, 0};   // moved body + disocclusion strip
  PlutoRect body{0, 0, 0, 0};   // rows whose content translated
  PlutoRect strip{0, 0, 0, 0};  // revealed strip (fresh content)
};

class ScrollDetector {
 public:
  bool configure(const ScrollDetectConfig& config);
  bool valid() const { return valid_; }

  // Runs the vote over the damaged band of the CURRENT pass. Returns true
  // (and fills *out) only for a verified translation.
  bool detect(const FrameLedger& ledger, const PlutoRect& damage_bounds,
              ScrollMove* out);

  size_t detected_moves() const { return detected_moves_; }

 private:
  struct HashRow {
    uint32_t hash = 0;
    int32_t row = 0;
  };
  // A distinctive current row and the offset it voted for; recorded during
  // the vote so the matched-extent pass is a filter over these instead of a
  // second full merge.
  struct VotePair {
    int32_t row = 0;
    int32_t dy = 0;
  };

  ScrollDetectConfig config_{};
  bool valid_ = false;
  size_t detected_moves_ = 0;
  std::vector<HashRow> prev_rows_;   // sorted by (hash, row)
  std::vector<HashRow> cur_rows_;    // sorted by (hash, row)
  std::vector<uint32_t> votes_;      // index dy + max_dy
  std::vector<VotePair> pairs_;      // distinctive voting pairs this pass
};

}  // namespace pluto

#endif  // PLUTO_RENDERER_SCROLL_DETECT_H_
