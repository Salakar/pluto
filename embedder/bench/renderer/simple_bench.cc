#include "renderer/abi_bridge.h"
#include "renderer/convert.h"
#include "renderer/frame_ledger.h"
#include "renderer/gallery3.h"
#include "renderer/kernels.h"
#include "renderer/pen_render_policy.h"
#include "renderer/quantize.h"
#include "renderer/rect_utils.h"
#include "renderer/region_scheduler.h"
#include "renderer/tile_pass.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

struct Timing {
  double mean = 0;
  double p50 = 0;
  double p95 = 0;
  double p99 = 0;
  double max = 0;
};

Timing scaled(Timing timing, double factor) {
  timing.mean *= factor;
  timing.p50 *= factor;
  timing.p95 *= factor;
  timing.p99 *= factor;
  timing.max *= factor;
  return timing;
}

template <typename Fn>
Timing time_ms(int iterations, Fn fn) {
  constexpr int kMaxBatches = 256;
  const int batch_size = std::max(1, iterations / kMaxBatches);
  std::vector<double> samples;
  samples.reserve(static_cast<size_t>((iterations + batch_size - 1) /
                                      batch_size));
  int i = 0;
  while (i < iterations) {
    const int begin = i;
    const int end = std::min(iterations, i + batch_size);
    const auto start = Clock::now();
    for (; i < end; ++i) {
      fn(i);
    }
    const std::chrono::duration<double, std::milli> elapsed =
        Clock::now() - start;
    samples.push_back(elapsed.count() / static_cast<double>(end - begin));
  }
  // Drop the first batch as warm-up when possible, then report the
  // distribution of per-call batch means. Batching keeps sub-microsecond pen
  // policy timing above clock-read noise while still exposing run-to-run
  // stalls; larger renderer operations naturally use one call per batch.
  if (samples.size() > 4) {
    samples.erase(samples.begin());
  }
  Timing timing;
  timing.mean = std::accumulate(samples.begin(), samples.end(), 0.0) /
                static_cast<double>(samples.size());
  std::sort(samples.begin(), samples.end());
  const auto percentile = [&](size_t numerator) {
    const size_t index =
        std::min(samples.size() - 1, (samples.size() * numerator) / 100);
    return samples[index];
  };
  timing.p50 = percentile(50);
  timing.p95 = percentile(95);
  timing.p99 = percentile(99);
  timing.max = samples.back();
  return timing;
}

void print_result(const std::string& name, const Timing& timing,
                  const std::string& unit,
                  const std::string& budget) {
  std::cout << std::left << std::setw(34) << name << " " << std::right
            << std::fixed << std::setprecision(3) << "mean " << std::setw(9)
            << timing.mean << " " << unit << " p50 " << std::setw(9)
            << timing.p50 << " p95 " << std::setw(9) << timing.p95 << " p99 "
            << std::setw(9) << timing.p99 << " max " << std::setw(9)
            << timing.max << "   budget " << budget << '\n';
}

struct NullPresenter {
  static bool present(void*, const PlutoPresentRequest*) { return true; }
};

PlutoSurface surface_565(const std::vector<uint16_t>& pixels, uint32_t width,
                           uint32_t height) {
  return PlutoSurface{reinterpret_cast<const uint8_t*>(pixels.data()),
                        width * sizeof(uint16_t), static_cast<int32_t>(width),
                        static_cast<int32_t>(height),
                        kPlutoPixelFormatRgb565};
}

}  // namespace

int main() {
  constexpr uint32_t kWidth = 954;
  constexpr uint32_t kHeight = 1696;
  std::vector<uint16_t> frame(kWidth * kHeight, 0);
  std::vector<uint16_t> frame_b(kWidth * kHeight, 0);
  std::vector<uint8_t> gray(kWidth * kHeight, 0);

  // Fused tile pass, clean frame: full-surface verify (no hints) against a
  // settled ledger — the steady-state cost of an unchanged frame.
  pluto::FrameLedgerConfig ledger_config;
  ledger_config.width = kWidth;
  ledger_config.height = kHeight;
  pluto::FrameLedger clean_ledger(ledger_config);
  pluto::TilePass clean_pass;
  clean_pass.run(surface_565(frame, kWidth, kHeight), nullptr, 0,
                 &clean_ledger);
  const Timing clean_pass_ms = time_ms(25, [&](int) {
    clean_pass.run(surface_565(frame, kWidth, kHeight), nullptr, 0,
                   &clean_ledger);
  });

  // Production direct-colour path: after the first retained frame, the
  // renderer owns an exact RGB565 mirror of the engine content. Flutter can
  // still over-report broad paint bounds for a tiny pen/cursor update. This
  // fixture measures a full-surface candidate scan with one new 24x3 segment
  // per frame and an exact previous mirror, including the same small retained
  // mirror copy FrameRenderer performs after the pass.
  std::vector<uint16_t> retained_frame(kWidth * kHeight, 0);
  std::vector<uint16_t> retained_previous = retained_frame;
  pluto::FrameLedger retained_ledger(ledger_config);
  pluto::TilePass retained_pass;
  retained_pass.run(surface_565(retained_frame, kWidth, kHeight), nullptr, 0,
                    &retained_ledger, nullptr, 0,
                    /*compare_rgb565=*/true);
  size_t retained_dirty_tiles = 0;
  size_t retained_processed_tiles = 0;
  const Timing retained_pass_ms = time_ms(25, [&](int i) {
    const int32_t x0 = 64 + (i % 25) * 32;
    const int32_t y0 = 736 + (i % 4) * 32;
    for (int32_t y = y0; y < y0 + 3; ++y) {
      std::fill_n(retained_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  24, uint16_t{0xffff});
    }
    retained_dirty_tiles += retained_pass.run(
        surface_565(retained_frame, kWidth, kHeight), nullptr, 0,
        &retained_ledger,
        reinterpret_cast<const uint8_t*>(retained_previous.data()),
        static_cast<size_t>(kWidth) * sizeof(uint16_t),
        /*compare_rgb565=*/true);
    retained_processed_tiles += retained_pass.processed_tile_count();
    for (int32_t y = y0; y < y0 + 3; ++y) {
      std::memcpy(retained_previous.data() +
                      static_cast<size_t>(y) * kWidth + x0,
                  retained_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  24 * sizeof(uint16_t));
    }
  });
  if (retained_dirty_tiles != 25u || retained_processed_tiles != 25u) {
    std::cerr << "retained overreport benchmark missed raw damage or failed "
                 "one-tile narrowing\n";
    return 1;
  }

  // Fused tile pass, 96x96 dirty roundtrip: paint + full-surface verify,
  // revert + full-surface verify (the trust-but-verify worst case).
  pluto::FrameLedger dirty_ledger(ledger_config);
  pluto::TilePass dirty_pass;
  dirty_pass.run(surface_565(frame, kWidth, kHeight), nullptr, 0,
                 &dirty_ledger);
  const Timing dirty_pass_ms = time_ms(25, [&](int i) {
    frame_b = frame;
    const uint32_t x0 = static_cast<uint32_t>((i * 37) % (kWidth - 96));
    const uint32_t y0 = static_cast<uint32_t>((i * 53) % (kHeight - 96));
    for (uint32_t y = y0; y < y0 + 96; ++y) {
      for (uint32_t x = x0; x < x0 + 96; ++x) {
        frame_b[y * kWidth + x] = 0xffff;
      }
    }
    dirty_pass.run(surface_565(frame_b, kWidth, kHeight), nullptr, 0,
                   &dirty_ledger);
    dirty_pass.run(surface_565(frame, kWidth, kHeight), nullptr, 0,
                   &dirty_ledger);
  });

  // The attached color panel's production shape: the exact engine-true
  // RGB565 mirror is supplied on both the draw and draw-back pass. Keep the
  // broad/no-hint nomination to model Flutter over-reporting, but assert that
  // collision-free row/tile narrowing admits exactly the tiles intersecting
  // the 96x96 update. Timing includes the same small mirror copies the
  // compositor performs after each accepted pass.
  std::vector<uint16_t> exact_frame(kWidth * kHeight, 0);
  std::vector<uint16_t> exact_previous = exact_frame;
  pluto::FrameLedger exact_ledger(ledger_config);
  pluto::TilePass exact_pass;
  exact_pass.run(surface_565(exact_frame, kWidth, kHeight), nullptr, 0,
                 &exact_ledger, nullptr, 0,
                 /*compare_rgb565=*/true);
  size_t exact_dirty_tiles = 0;
  size_t exact_processed_tiles = 0;
  size_t exact_expected_tiles = 0;
  const Timing exact_roundtrip_ms = time_ms(25, [&](int i) {
    const int32_t x0 = 65 + (i % 10) * 67;
    const int32_t y0 = 701 + (i % 5) * 73;
    const int32_t tx0 = x0 / 32;
    const int32_t tx1 = (x0 + 95) / 32;
    const int32_t ty0 = y0 / 32;
    const int32_t ty1 = (y0 + 95) / 32;
    const size_t tiles = static_cast<size_t>(tx1 - tx0 + 1) *
                         static_cast<size_t>(ty1 - ty0 + 1);
    exact_expected_tiles += tiles * 2u;
    for (int32_t y = y0; y < y0 + 96; ++y) {
      std::fill_n(exact_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  96, uint16_t{0xffff});
    }
    exact_dirty_tiles += exact_pass.run(
        surface_565(exact_frame, kWidth, kHeight), nullptr, 0, &exact_ledger,
        reinterpret_cast<const uint8_t*>(exact_previous.data()),
        static_cast<size_t>(kWidth) * sizeof(uint16_t),
        /*compare_rgb565=*/true);
    exact_processed_tiles += exact_pass.processed_tile_count();
    for (int32_t y = y0; y < y0 + 96; ++y) {
      std::memcpy(exact_previous.data() + static_cast<size_t>(y) * kWidth + x0,
                  exact_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  96 * sizeof(uint16_t));
      std::fill_n(exact_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  96, uint16_t{0});
    }
    exact_dirty_tiles += exact_pass.run(
        surface_565(exact_frame, kWidth, kHeight), nullptr, 0, &exact_ledger,
        reinterpret_cast<const uint8_t*>(exact_previous.data()),
        static_cast<size_t>(kWidth) * sizeof(uint16_t),
        /*compare_rgb565=*/true);
    exact_processed_tiles += exact_pass.processed_tile_count();
    for (int32_t y = y0; y < y0 + 96; ++y) {
      std::memcpy(exact_previous.data() + static_cast<size_t>(y) * kWidth + x0,
                  exact_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  96 * sizeof(uint16_t));
    }
  });
  if (exact_dirty_tiles != exact_expected_tiles ||
      exact_processed_tiles != exact_expected_tiles) {
    std::cerr << "exact-mirror 96x96 benchmark missed draw/draw-back damage "
                 "or over-processed tiles\n";
    return 1;
  }

  // Same production draw/draw-back, but with a precise Flutter paint bound.
  // The delta from the broad row above isolates the unavoidable full-panel
  // exact-mirror proof when Flutter nominates the entire surface.
  std::vector<uint16_t> hinted_frame(kWidth * kHeight, 0);
  std::vector<uint16_t> hinted_previous = hinted_frame;
  pluto::FrameLedger hinted_ledger(ledger_config);
  pluto::TilePass hinted_pass;
  hinted_pass.run(surface_565(hinted_frame, kWidth, kHeight), nullptr, 0,
                  &hinted_ledger, nullptr, 0,
                  /*compare_rgb565=*/true);
  size_t hinted_dirty_tiles = 0;
  size_t hinted_processed_tiles = 0;
  size_t hinted_expected_tiles = 0;
  const Timing hinted_roundtrip_ms = time_ms(25, [&](int i) {
    const int32_t x0 = 65 + (i % 10) * 67;
    const int32_t y0 = 701 + (i % 5) * 73;
    const PlutoRect hint{x0, y0, 96, 96};
    const size_t tiles =
        static_cast<size_t>((x0 + 95) / 32 - x0 / 32 + 1) *
        static_cast<size_t>((y0 + 95) / 32 - y0 / 32 + 1);
    hinted_expected_tiles += tiles * 2u;
    for (int32_t y = y0; y < y0 + 96; ++y) {
      std::fill_n(hinted_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  96, uint16_t{0xffff});
    }
    hinted_dirty_tiles += hinted_pass.run(
        surface_565(hinted_frame, kWidth, kHeight), &hint, 1, &hinted_ledger,
        reinterpret_cast<const uint8_t*>(hinted_previous.data()),
        static_cast<size_t>(kWidth) * sizeof(uint16_t), true);
    hinted_processed_tiles += hinted_pass.processed_tile_count();
    for (int32_t y = y0; y < y0 + 96; ++y) {
      std::memcpy(hinted_previous.data() +
                      static_cast<size_t>(y) * kWidth + x0,
                  hinted_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  96 * sizeof(uint16_t));
      std::fill_n(hinted_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  96, uint16_t{0});
    }
    hinted_dirty_tiles += hinted_pass.run(
        surface_565(hinted_frame, kWidth, kHeight), &hint, 1, &hinted_ledger,
        reinterpret_cast<const uint8_t*>(hinted_previous.data()),
        static_cast<size_t>(kWidth) * sizeof(uint16_t), true);
    hinted_processed_tiles += hinted_pass.processed_tile_count();
    for (int32_t y = y0; y < y0 + 96; ++y) {
      std::memcpy(hinted_previous.data() +
                      static_cast<size_t>(y) * kWidth + x0,
                  hinted_frame.data() + static_cast<size_t>(y) * kWidth + x0,
                  96 * sizeof(uint16_t));
    }
  });
  if (hinted_dirty_tiles != hinted_expected_tiles ||
      hinted_processed_tiles != hinted_expected_tiles) {
    std::cerr << "hinted exact-mirror benchmark fixture lost parity\n";
    return 1;
  }

  for (uint32_t y = 0; y < kHeight; ++y) {
    for (uint32_t x = 0; x < kWidth; ++x) {
      frame[y * kWidth + x] =
          pluto::rgb888_to_rgb565(static_cast<uint8_t>(x & 0xffu),
                                    static_cast<uint8_t>(y & 0xffu),
                                    static_cast<uint8_t>((x + y) & 0xffu));
    }
  }

  pluto::ConvertConfig fast_config;
  fast_config.width = kWidth;
  fast_config.height = kHeight;
  fast_config.refresh_class = kPlutoRefreshFast;
  fast_config.kernel = pluto::DitherKernel::kBayer4;
  const PlutoRect bench_rect{128, 128, 512, 512};
  const Timing fast_dither_ms = time_ms(50, [&](int) {
    pluto::convert_rgb565_to_gray8_rect(frame.data(), kWidth * sizeof(uint16_t),
                                          gray.data(), 512, bench_rect,
                                          fast_config);
  });

  pluto::ConvertConfig blue_config;
  blue_config.width = kWidth;
  blue_config.height = kHeight;
  blue_config.refresh_class = kPlutoRefreshUi;
  blue_config.kernel = pluto::DitherKernel::kBlueNoise64;
  const Timing blue_dither_ms = time_ms(50, [&](int) {
    pluto::convert_rgb565_to_gray8_rect(frame.data(), kWidth * sizeof(uint16_t),
                                          gray.data(), 512, bench_rect,
                                          blue_config);
  });

  const pluto::Gallery3Palette& palette = pluto::Gallery3Palette::instance();
  std::vector<uint16_t> palette_out(512 * 512);
  // volatile sink: map_rgb565 is header-inline now — without consuming the
  // output the whole loop is dead-code-eliminated and the row reads 0.000.
  volatile uint16_t palette_sink = 0;
  const Timing palette_ms = time_ms(50, [&](int) {
    for (int32_t y = 0; y < 512; ++y) {
      const uint16_t* src_row = frame.data() + (128 + y) * kWidth + 128;
      uint16_t* dst_row = palette_out.data() + y * 512;
      for (int32_t x = 0; x < 512; ++x) {
        dst_row[x] = palette.map_rgb565(src_row[x], 128 + x, 128 + y);
      }
    }
    palette_sink = static_cast<uint16_t>(palette_sink ^ palette_out[0] ^
                                         palette_out[512 * 512 - 1]);
  });
  (void)palette_sink;

  std::vector<uint8_t> full_gray(kWidth * kHeight);
  const Timing floyd_ms = time_ms(10, [&](int) {
    pluto::convert_rgb565_to_gray8_full_error_diffusion(
        frame.data(), kWidth * sizeof(uint16_t), full_gray.data(), kWidth,
        kWidth, kHeight);
  });

  // BM-B1: AbiPresentBridge full-panel levels->RGB565 present conversion —
  // the raster-thread cost of converting one full-panel damage rect from the
  // ledger's settled 5-bit levels into the RGB565 present buffer. The scalar
  // row is the frozen per-pixel reference (levels_to_rgb565_span_scalar);
  // the dispatch row is the production prepare() path.
  pluto::FrameLedger bridge_ledger(ledger_config);
  {
    pluto::TilePass bridge_pass;
    bridge_pass.run(surface_565(frame, kWidth, kHeight), nullptr, 0,
                    &bridge_ledger);
  }
  pluto::AbiPresentBridgeConfig bridge_config;
  bridge_config.width = kWidth;
  bridge_config.height = kHeight;
  pluto::AbiPresentBridge bridge;
  bridge.configure(bridge_config);
  const PlutoRect full_rect{0, 0, static_cast<int32_t>(kWidth),
                              static_cast<int32_t>(kHeight)};
  PlutoPresentRequest bridge_request{};
  bridge_request.struct_size = sizeof(bridge_request);
  bridge_request.surface = surface_565(frame, kWidth, kHeight);
  bridge_request.damage = &full_rect;
  bridge_request.damage_count = 1;
  bridge_request.refresh_class = kPlutoRefreshUi;
  bridge_request.frame_id = 1;
  const Timing bridge_dispatch_ms = time_ms(200, [&](int) {
    (void)bridge.prepare(bridge_request, bridge_ledger);
  });
  std::vector<uint16_t> bridge_scalar_out(kWidth * kHeight);
  const Timing bridge_scalar_ms = time_ms(200, [&](int) {
    const uint8_t* l_cur = bridge_ledger.l_cur();
    const size_t stride = bridge_ledger.stride();
    for (uint32_t y = 0; y < kHeight; ++y) {
      pluto::levels_to_rgb565_span_scalar(
          l_cur + y * stride, kWidth, bridge_scalar_out.data() + y * kWidth);
    }
  });

  pluto::RegionSchedulerConfig scheduler_config;
  scheduler_config.width = kWidth;
  scheduler_config.height = kHeight;
  scheduler_config.latency_model_us = {1000, 1000, 1000, 1000};
  scheduler_config.fence_margin = 1.0f;
  pluto::RegionPresenterHooks presenter;
  presenter.present = &NullPresenter::present;
  pluto::RegionScheduler scheduler(scheduler_config, presenter);
  const Timing scheduler_us = scaled(time_ms(1000, [&](int i) {
    const PlutoRect rect{static_cast<int32_t>((i * 17) % 900),
                           static_cast<int32_t>((i * 31) % 1600), 24, 24};
    const PlutoRefreshClass cls = kPlutoRefreshFast;
    const uint64_t now = static_cast<uint64_t>(i) * 1000u;
    scheduler.submit_damage(&rect, &cls, 1, now);
    scheduler.tick(now);
    scheduler.tick(now + 1000u);
  }), 1000.0);

  // BM-S2: coalesce storm — one tick that reduces a full scattered UI queue
  // (128 pairwise-distant 8x8 rects, gap > merge_gap so phase-1 never
  // merges) down to the class cap via the min-waste reduction, then a drain
  // tick. The worst-case scheduler-thread stall shape (queue backed up
  // behind a Full in flight, then released).
  pluto::RegionSchedulerConfig storm_config;
  storm_config.width = kWidth;
  storm_config.height = kHeight;
  storm_config.latency_model_us = {1, 1, 1, 1};
  storm_config.fence_margin = 1.0f;
  pluto::RegionScheduler storm_scheduler(storm_config, presenter);
  std::vector<PlutoRect> storm_rects;
  std::vector<PlutoRefreshClass> storm_classes;
  constexpr size_t kStormRectCount = 128;
  for (size_t i = 0; i < kStormRectCount; ++i) {
    const int32_t gx = static_cast<int32_t>(i % 23);
    const int32_t gy = static_cast<int32_t>(i / 23);
    storm_rects.push_back(PlutoRect{gx * 41, gy * 41, 8, 8});
    storm_classes.push_back(kPlutoRefreshUi);
  }
  if (storm_rects.size() != kStormRectCount ||
      storm_rects.size() != storm_classes.size()) {
    std::cerr << "coalesce storm benchmark fixture is invalid\n";
    return 1;
  }
  uint64_t storm_now = 0;
  const Timing storm_us = scaled(time_ms(200, [&](int) {
    storm_now += 1000000u;
    storm_scheduler.submit_damage(storm_rects.data(), storm_classes.data(),
                                  storm_rects.size(), storm_now);
    storm_scheduler.tick(storm_now);
    storm_now += 1000000u;
    storm_scheduler.tick(storm_now);  // drain the synthetic completion
  }), 1000.0);

  // BM-PP1: pen-policy routing over preallocated dirty records. Hint-only
  // measures the mandatory no-damage exit (hover must never create pixels by
  // itself); hover/contact measure association, adaptive clipping, changed-
  // pixel accounting, and truth-class selection. All setup and storage live
  // outside the timed loops, so the measured paths are allocation-free.
  pluto::PenRenderPolicyConfig pen_policy_config;
  pen_policy_config.width = kWidth;
  pen_policy_config.height = kHeight;
  pluto::PenRenderPolicy pen_policy;
  if (!pen_policy.configure(pen_policy_config)) {
    std::cerr << "pen render policy configuration failed\n";
    return 1;
  }
  constexpr size_t kPenRecordCount = 16;
  std::array<pluto::DirtyTileRecord, kPenRecordCount> pen_records{};
  for (size_t i = 0; i < pen_records.size(); ++i) {
    const int32_t x = 384 + static_cast<int32_t>(i % 4) * 32;
    const int32_t y = 720 + static_cast<int32_t>(i / 4) * 32;
    pen_records[i].tile_idx = static_cast<uint32_t>(i);
    pen_records[i].dirty = PlutoRect{x, y, 24, 24};
    pen_records[i].stats.changed_px = 96;
    pen_records[i].stats.changed_chroma = i == 10 ? 1 : 0;
    pen_records[i].stats.chroma_frac = i == 10 ? 32 : 0;
  }
  const PlutoRect pen_region{384, 720, 192, 128};
  std::array<pluto::PenRenderHintSnapshot, 4> hover_hints{};
  std::array<pluto::PenRenderHintSnapshot, 4> contact_hints{};
  for (size_t i = 0; i < hover_hints.size(); ++i) {
    const int32_t offset = static_cast<int32_t>(i) * 2;
    hover_hints[i] = pluto::PenRenderHintSnapshot{
        .in_range = true,
        .contact = false,
        .previous_x = 420 + offset,
        .previous_y = 766,
        .current_x = 448 + offset,
        .current_y = 776,
        .predicted_x = 470 + offset,
        .predicted_y = 784,
        .sequence = i + 1,
    };
    contact_hints[i] = hover_hints[i];
    contact_hints[i].contact = true;
  }
  const auto no_damage_probe =
      pen_policy.route_region(pen_region, hover_hints[0], pen_records.data(), 0,
                              /*panel_is_color=*/true);
  const auto hover_probe = pen_policy.route_region(
      pen_region, hover_hints[0], pen_records.data(), pen_records.size(),
      /*panel_is_color=*/true);
  const auto contact_probe = pen_policy.route_region(
      pen_region, contact_hints[0], pen_records.data(), pen_records.size(),
      /*panel_is_color=*/true);
  if (no_damage_probe.associated || !hover_probe.associated ||
      !contact_probe.associated || !hover_probe.carries_chroma ||
      !contact_probe.carries_chroma ||
      hover_probe.truth_class != kPlutoRefreshFull ||
      contact_probe.truth_class != kPlutoRefreshFull) {
    std::cerr << "pen render policy benchmark fixture is invalid\n";
    return 1;
  }
  volatile uint64_t pen_policy_sink = 0;
  constexpr int kPenPolicyIterations = 500000;
  const Timing pen_hint_only_us =
      scaled(time_ms(kPenPolicyIterations,
              [&](int i) {
                const auto route = pen_policy.route_region(
                    pen_region, hover_hints[static_cast<size_t>(i) & 3u],
                    pen_records.data(), 0, /*panel_is_color=*/true);
                pen_policy_sink =
                    route.changed_pixels + route.dirty_tiles +
                    static_cast<uint64_t>(route.truth_class) +
                    static_cast<uint64_t>(route.carries_chroma);
              }), 1000.0);
  const Timing pen_hover_policy_us =
      scaled(time_ms(kPenPolicyIterations,
              [&](int i) {
                const auto route = pen_policy.route_region(
                    pen_region, hover_hints[static_cast<size_t>(i) & 3u],
                    pen_records.data(), pen_records.size(),
                    /*panel_is_color=*/true);
                pen_policy_sink = route.changed_pixels + route.dirty_tiles +
                                  static_cast<uint64_t>(route.preview.width) +
                                  static_cast<uint64_t>(route.truth_class) +
                                  static_cast<uint64_t>(route.carries_chroma);
              }), 1000.0);
  const Timing pen_contact_policy_us =
      scaled(time_ms(kPenPolicyIterations,
              [&](int i) {
                const auto route = pen_policy.route_region(
                    pen_region, contact_hints[static_cast<size_t>(i) & 3u],
                    pen_records.data(), pen_records.size(),
                    /*panel_is_color=*/true);
                pen_policy_sink = route.changed_pixels + route.dirty_tiles +
                                  static_cast<uint64_t>(route.preview.height) +
                                  static_cast<uint64_t>(route.truth_class) +
                                  static_cast<uint64_t>(route.carries_chroma);
              }), 1000.0);

  // BM-PP2: one coalesced Flutter frame can contain a long, thin stroke while
  // the current pen focus touches only its leading tile. The association gate
  // must find the connected verified component without expanding output to the
  // broad focus box. Correct tile indices exercise the production adjacency
  // walk; the route remains allocation-free.
  constexpr size_t kLongPenRecords = 27;
  constexpr int32_t kLongPenTileRow = 24;
  constexpr int32_t kPanelTileColumns = (kWidth + 31) / 32;
  std::array<pluto::DirtyTileRecord, kLongPenRecords> long_pen_records{};
  PlutoRect long_pen_region{};
  for (size_t i = 0; i < long_pen_records.size(); ++i) {
    const int32_t tile_x = static_cast<int32_t>(i) + 1;
    auto &record = long_pen_records[i];
    record.tile_idx = static_cast<uint32_t>(kLongPenTileRow * kPanelTileColumns +
                                            tile_x);
    record.dirty = PlutoRect{tile_x * 32 + 2, 770, 28, 3};
    record.stats.changed_px = 84;
    long_pen_region = pluto::rect_union(long_pen_region, record.dirty);
  }
  std::array<pluto::PenRenderHintSnapshot, 4> long_pen_hints{};
  for (size_t i = 0; i < long_pen_hints.size(); ++i) {
    const int32_t offset = static_cast<int32_t>(i);
    long_pen_hints[i] = pluto::PenRenderHintSnapshot{
        .in_range = true,
        .contact = true,
        .previous_x = 880 + offset,
        .previous_y = 771,
        .current_x = 888 + offset,
        .current_y = 771,
        .predicted_x = 896 + offset,
        .predicted_y = 771,
        .sequence = i + 1,
    };
  }
  const auto long_pen_probe = pen_policy.route_region(
      long_pen_region, long_pen_hints[0], long_pen_records.data(),
      long_pen_records.size(), /*panel_is_color=*/true);
  bool long_pen_covered = long_pen_probe.associated &&
                          long_pen_probe.dirty_tiles == kLongPenRecords;
  for (const auto &record : long_pen_records) {
    long_pen_covered = long_pen_covered &&
                       pluto::rect_intersects(long_pen_probe.preview,
                                                record.dirty);
  }
  if (!long_pen_covered ||
      pluto::rect_area(long_pen_probe.preview) !=
          pluto::rect_area(long_pen_region)) {
    std::cerr << "long thin pen benchmark fixture is invalid\n";
    return 1;
  }
  const Timing pen_long_policy_us =
      scaled(time_ms(200000,
              [&](int i) {
                const auto route = pen_policy.route_region(
                    long_pen_region,
                    long_pen_hints[static_cast<size_t>(i) & 3u],
                    long_pen_records.data(), long_pen_records.size(),
                    /*panel_is_color=*/true);
                pen_policy_sink =
                    route.changed_pixels + route.dirty_tiles +
                    static_cast<uint64_t>(pluto::rect_area(route.preview));
              }), 1000.0);
  (void)pen_policy_sink;

  // BM-PS1: allocation-free pen preview + Text-truth scheduling with a
  // no-op presenter. One event submits both app-damage phases; successive
  // ticks retire the synthetic one-microsecond preview/truth completions so
  // every iteration begins from the same idle state.
  pluto::RegionSchedulerConfig pen_scheduler_config = scheduler_config;
  pen_scheduler_config.latency_model_us = {1, 1, 1, 1};
  pluto::RegionScheduler pen_scheduler(pen_scheduler_config, presenter);
  const Timing pen_scheduler_us =
      scaled(time_ms(200000,
              [&](int i) {
                const PlutoRect damage{
                    64 + static_cast<int32_t>((i * 17) % 800),
                    64 + static_cast<int32_t>((i * 31) % 1500), 32, 32};
                const uint64_t now = static_cast<uint64_t>(i) * 4u;
                pen_scheduler.submit_pen_damage(damage, damage,
                                                kPlutoRefreshText, now);
                pen_scheduler.tick(now);
                pen_scheduler.tick(now + 1u);
                pen_scheduler.tick(now + 2u);
              }), 1000.0);
  if (pen_scheduler.dispatched_updates() != 400000u || !pen_scheduler.idle()) {
    std::cerr << "pen scheduler benchmark did not dispatch both phases\n";
    return 1;
  }

  // BM-PS1C: exact-colour variant. Text/Full truth may not claim a 32-pixel
  // presenter tile until the corresponding Fast preview completes; this is
  // the no-dash ordering check used on Gallery-3 glass. It must remain a
  // sub-microsecond scheduling decision rather than moving work into the nib
  // path.
  pluto::RegionSchedulerConfig color_pen_scheduler_config =
      pen_scheduler_config;
  color_pen_scheduler_config.serialize_pen_truth_by_tile = true;
  color_pen_scheduler_config.pen_collision_tile_px = 32;
  pluto::RegionScheduler color_pen_scheduler(color_pen_scheduler_config,
                                                presenter);
  const Timing color_pen_scheduler_us =
      scaled(time_ms(200000,
              [&](int i) {
                const PlutoRect damage{
                    64 + static_cast<int32_t>((i * 17) % 800),
                    64 + static_cast<int32_t>((i * 31) % 1500), 8, 8};
                const uint64_t now = static_cast<uint64_t>(i) * 4u;
                color_pen_scheduler.submit_pen_damage(
                    damage, damage, kPlutoRefreshText, now);
                color_pen_scheduler.tick(now);
                color_pen_scheduler.tick(now + 1u);
                color_pen_scheduler.tick(now + 2u);
              }), 1000.0);
  if (color_pen_scheduler.dispatched_updates() != 400000u ||
      color_pen_scheduler.pen_truth_tile_holds() == 0u ||
      !color_pen_scheduler.idle()) {
    std::cerr << "exact-color pen scheduler benchmark lost tile ordering\n";
    return 1;
  }

  // BM-PS2: adversarial reverse-supersession routing. Force pen truth into
  // its production overload-cell representation across thirteen of the
  // panel's fifteen 64-pixel columns (13 * 27 = 351 active truth cells), then
  // retain a deep exact generic-residual lane in the uncovered right edge.
  // The timed submissions are disjoint from every truth cell: their cost
  // should therefore depend on the active truth geometry, not on how much
  // unrelated exact work was already retained.
  pluto::RegionScheduler pen_route_scheduler(pen_scheduler_config,
                                                presenter);
  uint64_t pen_route_now = 1;
  for (int32_t row = 0; row < 27; ++row) {
    for (int32_t col = 0; col < 13; ++col) {
      const PlutoRect truth{col * 64, row * 64, 8, 8};
      pen_route_scheduler.submit_pen_damage(
          PlutoRect{}, truth, kPlutoRefreshText, pen_route_now++);
    }
  }
  const PlutoRect unrelated_residual{904, 8, 8, 8};
  constexpr int kPenRoutePrefill = 768;
  for (int i = 0; i < kPenRoutePrefill; ++i) {
    const PlutoRefreshClass cls = kPlutoRefreshFast;
    pen_route_scheduler.submit_damage(&unrelated_residual, &cls, 1,
                                      pen_route_now++);
  }
  const Timing pen_route_us = scaled(time_ms(128, [&](int) {
    const PlutoRefreshClass cls = kPlutoRefreshFast;
    pen_route_scheduler.submit_damage(&unrelated_residual, &cls, 1,
                                      pen_route_now++);
  }), 1000.0);
  if (!pen_route_scheduler.user_work_pending() ||
      pen_route_scheduler.pending_pen_residuals_for_testing() !=
          kPenRoutePrefill + 128u ||
      pen_route_scheduler.superseded_updates() != 0u ||
      pen_route_scheduler.dispatched_updates() != 0u) {
    std::cerr << "pen reverse-supersession benchmark left its exact path\n";
    return 1;
  }

  std::cout << "Pluto renderer host microbenchmarks (indicative; device budgets are authoritative)\n";
  print_result("BM-D1 clean full tile pass", clean_pass_ms, "ms", "<= 3.5 ms p99 device");
  print_result("BM-D1 retained one-tile overreport", retained_pass_ms, "ms",
               "production exact-mirror path");
  print_result("BM-D1 96x96 dirty roundtrip", dirty_pass_ms, "ms",
               "<= 4.0 ms p99 device");
  print_result("BM-D1 exact 96x96 roundtrip", exact_roundtrip_ms, "ms",
               "production RGB565 mirror");
  print_result("BM-D1 hinted 96x96 roundtrip", hinted_roundtrip_ms, "ms",
               "isolates fused dirty-tile work");
  print_result("BM-Q1 fast Bayer 512x512", fast_dither_ms, "ms",
               "<= 0.35 ms p99 device");
  print_result("BM-Q2 blue-noise 512x512", blue_dither_ms, "ms",
               "<= 0.60 ms p99 device");
  print_result("BM-Q3 CMYW palette LUT 512x512", palette_ms, "ms",
               "<= 1.0 ms p99 device");
  print_result("BM-Q4 Floyd-Steinberg full panel", floyd_ms, "ms",
               "<= 25.0 ms p99 device");
  print_result("BM-S1 scheduler tick storm", scheduler_us, "us",
               "<= 100 us/tick p99 device");
  print_result("BM-S2 coalesce storm 128", storm_us, "us",
               "<= 400 us/storm-tick device");
  print_result("BM-B1 bridge convert full (scalar)", bridge_scalar_ms, "ms",
               "reference");
  print_result("BM-B1 bridge convert full panel", bridge_dispatch_ms, "ms",
               "<= 1.5 ms p99 device");
  print_result("BM-PP1 hint-only no damage", pen_hint_only_us, "us",
               "<= 1 us/event device; preallocated path");
  print_result("BM-PP1 hover association", pen_hover_policy_us, "us",
               "<= 5 us/event device; preallocated path");
  print_result("BM-PP1 contact association", pen_contact_policy_us, "us",
               "<= 5 us/event device; preallocated path");
  print_result("BM-PP2 long thin connected", pen_long_policy_us, "us",
               "<= 15 us/event device; 27 verified tiles");
  print_result("BM-PS1 preview + Text truth", pen_scheduler_us, "us",
               "<= 20 us/event device; preallocated path");
  print_result("BM-PS1C color tile-ordered truth", color_pen_scheduler_us,
               "us", "<= 20 us/event device; no mapped nib blocker");
  print_result("BM-PS2 351 truth + deep residual", pen_route_us, "us",
               "<= 20 us/event device; unrelated work bounded");
  return 0;
}
