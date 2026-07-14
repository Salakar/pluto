#include "renderer/scroll_detect.h"

#include <algorithm>
#include <cstring>

#include "renderer/rect_utils.h"

namespace pluto {

bool ScrollDetector::configure(const ScrollDetectConfig& config) {
  valid_ = false;
  config_ = config;
  detected_moves_ = 0;
  if (config.width <= 0 || config.height <= 0 || config.max_dy <= 0 ||
      config.min_band_rows <= 0 || config.verify_rows == 0) {
    return false;
  }
  prev_rows_.clear();
  prev_rows_.reserve(static_cast<size_t>(config.height));
  cur_rows_.clear();
  cur_rows_.reserve(static_cast<size_t>(config.height));
  pairs_.clear();
  pairs_.reserve(static_cast<size_t>(config.height));
  votes_.assign(static_cast<size_t>(config.max_dy) * 2u + 1u, 0u);
  valid_ = true;
  return true;
}

bool ScrollDetector::detect(const FrameLedger& ledger,
                            const PlutoRect& damage_bounds,
                            ScrollMove* out) {
  if (!valid_ || out == nullptr || !ledger.valid()) {
    return false;
  }
  const PlutoRect band =
      rect_clip(damage_bounds, config_.width, config_.height);
  if (band.height < config_.min_band_rows ||
      rect_area(band) < config_.min_band_area_px) {
    return false;
  }
  const int32_t y0 = band.y;
  const int32_t y1 = rect_bottom(band);
  const uint32_t* cur = ledger.row_hash_cur();
  const uint32_t* prev = ledger.row_hash_prev();

  // Sorted (hash, row) tables of the band; hash 0 = never hashed, skipped.
  const auto less = [](const HashRow& a, const HashRow& b) {
    return a.hash != b.hash ? a.hash < b.hash : a.row < b.row;
  };
  prev_rows_.clear();
  cur_rows_.clear();
  for (int32_t y = y0; y < y1; ++y) {
    if (prev[y] != 0u) {
      prev_rows_.push_back(HashRow{prev[y], y});
    }
    if (cur[y] != 0u) {
      cur_rows_.push_back(HashRow{cur[y], y});
    }
  }
  std::sort(prev_rows_.begin(), prev_rows_.end(), less);
  std::sort(cur_rows_.begin(), cur_rows_.end(), less);

  // Majority vote over dy from distinctive-row pairs. Each distinctive pair is
  // recorded so the matched-extent computation below is a filter over these
  // instead of a second full merge of the sorted tables.
  std::fill(votes_.begin(), votes_.end(), 0u);
  pairs_.clear();
  uint32_t total_votes = 0;
  size_t p = 0;
  size_t c = 0;
  while (c < cur_rows_.size() && p < prev_rows_.size()) {
    // Advance to the next hash present on both sides.
    if (cur_rows_[c].hash < prev_rows_[p].hash) {
      ++c;
      continue;
    }
    if (prev_rows_[p].hash < cur_rows_[c].hash) {
      ++p;
      continue;
    }
    const uint32_t hash = cur_rows_[c].hash;
    size_t c_end = c;
    while (c_end < cur_rows_.size() && cur_rows_[c_end].hash == hash) {
      ++c_end;
    }
    size_t p_end = p;
    while (p_end < prev_rows_.size() && prev_rows_[p_end].hash == hash) {
      ++p_end;
    }
    // Distinctive-row filter: rows whose hash repeats within the band (on
    // either side) abstain — repeated content is offset-ambiguous.
    if (c_end - c == 1 && p_end - p == 1) {
      const int32_t d = cur_rows_[c].row - prev_rows_[p].row;
      if (d != 0 && d >= -config_.max_dy && d <= config_.max_dy) {
        ++votes_[static_cast<size_t>(d + config_.max_dy)];
        ++total_votes;
        pairs_.push_back(VotePair{cur_rows_[c].row, d});
      }
    }
    c = c_end;
    p = p_end;
  }
  if (total_votes == 0) {
    return false;
  }

  // Winner: max votes, ties toward the smaller |dy| (locality bias).
  int32_t best_dy = 0;
  uint32_t best_votes = 0;
  for (int32_t mag = 1; mag <= config_.max_dy; ++mag) {
    for (const int32_t d : {-mag, mag}) {
      const uint32_t v = votes_[static_cast<size_t>(d + config_.max_dy)];
      if (v > best_votes) {
        best_votes = v;
        best_dy = d;
      }
    }
  }
  if (best_votes < config_.min_votes ||
      best_votes * 100u < config_.majority_percent * total_votes) {
    return false;
  }

  // VERIFY (secondary-hash discipline): sampled voting pairs must be
  // byte-identical against the tile pass's true previous-pass row samples.
  // Any mismatch rejects — a hash collision must never move ghost state.
  const int32_t period = static_cast<int32_t>(FrameLedger::kRowSamplePeriod);
  const uint8_t* l_cur = ledger.l_cur();
  const size_t stride = ledger.stride();
  uint32_t verified = 0;
  for (int32_t y_prev = ceil_to_multiple(y0, period);
       y_prev < y1 && verified < config_.verify_rows; y_prev += period) {
    const int32_t y_cur = y_prev + best_dy;
    if (y_cur < y0 || y_cur >= y1) {
      continue;
    }
    if (prev[y_prev] == 0u || cur[y_cur] != prev[y_prev]) {
      continue;  // this pair did not vote
    }
    const uint8_t* sample =
        ledger.row_sample(static_cast<uint32_t>(y_prev));
    if (sample == nullptr) {
      continue;  // row not snapshotted this pass
    }
    if (std::memcmp(l_cur + static_cast<size_t>(y_cur) * stride, sample,
                    ledger.width()) != 0) {
      return false;  // collision / torn content: reject the whole MOVE
    }
    ++verified;
  }
  if (verified < config_.verify_rows) {
    return false;
  }

  // Matched extent at the winning offset (voting rows only): filter the
  // recorded distinctive pairs — same rows the second merge would re-derive.
  int32_t match_min = y1;
  int32_t match_max = y0 - 1;
  for (const VotePair& pair : pairs_) {
    if (pair.dy == best_dy) {
      match_min = std::min(match_min, pair.row);
      match_max = std::max(match_max, pair.row);
    }
  }
  if (match_max < match_min) {
    return false;  // defensive: votes imply matches exist
  }

  ++detected_moves_;
  out->dy = best_dy;
  out->body = PlutoRect{band.x, match_min, band.width,
                          match_max - match_min + 1};
  if (best_dy < 0) {
    // Content moved up: fresh rows revealed at the bottom of the band.
    out->strip = PlutoRect{band.x, match_max + 1, band.width,
                             y1 - (match_max + 1)};
  } else {
    // Content moved down: fresh rows revealed at the top of the band.
    out->strip = PlutoRect{band.x, y0, band.width, match_min - y0};
  }
  if (rect_is_empty(out->strip)) {
    out->strip = PlutoRect{0, 0, 0, 0};
  }
  out->band = rect_is_empty(out->strip) ? out->body
                                        : rect_union(out->body, out->strip);
  return true;
}

}  // namespace pluto
