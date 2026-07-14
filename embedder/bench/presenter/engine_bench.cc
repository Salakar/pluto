// Presenter engine bench: scalar-vs-NEON A/B of the per-pixel engine's
// fused advance+emit+ledger sweep hot path against the 11.76 ms (85.01 Hz)
// scan budget.
//
// Scenarios (the mission gate is p95 build < scan period at realistic
// active sets):
//   * full-field: 954x1696 = 1.62 Mpx active (GC16 page flash shape)
//   * active-500k: 954x525 = ~0.50 Mpx active (the "realistic active set")
// Stages:
//   * sweep:   PixelEngine::advance into a null-op emitter (gather + ops +
//              DC ledger + fnum/boundary, no deposit)
//   * deposit: PhaseEmitter::emit_row over dense full rows (template
//              compose + 4px/word lane packing + window write)
//   * fused:   the real build path — advance through the PhaseEmitter with
//              the impulse sink attached (what build_frame runs)
//
// A/B via PixelEngineConfig::force_scalar_sweep and
// PhaseEmitterConfig::force_scalar_deposit. On non-NEON hosts both columns
// run the scalar reference.

#include "presenter/swtcon/ct33_frontend.h"
#include "presenter/swtcon/drm_swtcon_presenter.h"
#include "presenter/swtcon/phase_emit.h"
#include "presenter/swtcon/pixel_engine.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "presenter/swtcon/xochitl_selector16.h"
#include "renderer/kernels.h"  // kNeonKernels (aarch64 dispatch flag)

#include "swtcon_eink_synth.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

namespace {

using pluto::swtcon::AdmitRequest;
using pluto::swtcon::Ct33Frontend;
using pluto::swtcon::kDrmWidth;
using pluto::swtcon::kLogicalHeight;
using pluto::swtcon::kLogicalWidth;
using pluto::swtcon::kPaddedSourceWidth;
using pluto::swtcon::PhaseEmitter;
using pluto::swtcon::PhaseEmitterConfig;
using pluto::swtcon::PixelEngine;
using pluto::swtcon::PixelEngineConfig;
using pluto::swtcon::PixelOp;
using pluto::swtcon::RowEmitter;
using pluto::swtcon::WaveformTable;
using pluto::swtcon::XochitlSelector16;

constexpr int kPhases = 32;  // GC16-shaped sequence length

struct NullEmitter final : RowEmitter {
  std::uint64_t ops = 0;
  void emit_row(int, const PixelOp*, std::size_t count) override {
    ops += count;
  }
};

struct Percentiles {
  double p50 = 0;
  double p95 = 0;
  double max = 0;
};

Percentiles percentiles(std::vector<double> samples);

struct CoverageMask {
  PlutoRect rect{};
  std::size_t stride = 0;
  std::vector<std::uint8_t> bits;
};

bool coverage_driven_legacy(const CoverageMask& coverage, std::int32_t x,
                            std::int32_t y) {
  if (coverage.rect.width <= 0 || coverage.rect.height <= 0 ||
      coverage.stride == 0 ||
      coverage.bits.size() !=
          coverage.stride * static_cast<std::size_t>(coverage.rect.height) ||
      x < coverage.rect.x || y < coverage.rect.y ||
      x >= coverage.rect.x + coverage.rect.width ||
      y >= coverage.rect.y + coverage.rect.height) {
    return false;
  }
  const std::size_t local_x =
      static_cast<std::size_t>(x - coverage.rect.x);
  const std::size_t offset =
      static_cast<std::size_t>(y - coverage.rect.y) * coverage.stride +
      local_x / 8u;
  return (coverage.bits[offset] &
          static_cast<std::uint8_t>(1u << (local_x & 7u))) != 0;
}

void legacy_fast_reconcile_mask(const CoverageMask& current,
                                const std::vector<CoverageMask>& newer,
                                std::vector<std::uint8_t>* retained) {
  std::fill(retained->begin(), retained->end(), 0u);
  for (std::int32_t local_y = 0; local_y < current.rect.height; ++local_y) {
    for (std::int32_t local_x = 0; local_x < current.rect.width; ++local_x) {
      const std::int32_t panel_x = current.rect.x + local_x;
      const std::int32_t panel_y = current.rect.y + local_y;
      if (!coverage_driven_legacy(current, panel_x, panel_y)) {
        continue;
      }
      bool covered = false;
      for (const CoverageMask& coverage : newer) {
        if (coverage_driven_legacy(coverage, panel_x, panel_y)) {
          covered = true;
          break;
        }
      }
      if (!covered) {
        const std::size_t byte_offset =
            static_cast<std::size_t>(local_y) * current.stride +
            static_cast<std::size_t>(local_x) / 8u;
        (*retained)[byte_offset] = static_cast<std::uint8_t>(
            (*retained)[byte_offset] |
            static_cast<std::uint8_t>(
                1u << (static_cast<unsigned>(local_x) & 7u)));
      }
    }
  }
}

bool word_fast_reconcile_mask(const CoverageMask& current,
                              const std::vector<CoverageMask>& newer,
                              std::vector<std::uint8_t>* aggregate,
                              std::vector<std::uint8_t>* retained) {
  std::fill(aggregate->begin(), aggregate->end(), 0u);
  for (const CoverageMask& coverage : newer) {
    if (!pluto::swtcon::or_fast_coverage_overlap(
            coverage.rect, coverage.bits, coverage.stride, current.rect,
            *aggregate, current.stride)) {
      return false;
    }
  }
  for (std::size_t index = 0; index < retained->size(); ++index) {
    (*retained)[index] = static_cast<std::uint8_t>(
        current.bits[index] & static_cast<std::uint8_t>(~(*aggregate)[index]));
  }
  return true;
}

// Primitive-only A/B for the newer-live-coverage subtraction inside Fast
// reconciliation. It deliberately excludes history reseed/confirmation and
// scan-fence work; the reported speedup applies only to this replaced mask
// hot path, not to end-to-end presentation latency.
bool run_fast_reconcile_bench() {
  constexpr int kNewerPieces = 64;
  constexpr int kIterations = 240;
  std::mt19937 rng(0xfa57ca5eu);
  CoverageMask current;
  current.rect = PlutoRect{387, 801, 96, 96};
  current.stride = 12;
  current.bits.assign(current.stride * 96u, 0u);
  for (std::uint8_t& value : current.bits) {
    value = static_cast<std::uint8_t>(rng());
  }

  std::uniform_int_distribution<int> offset(-40, 40);
  std::uniform_int_distribution<int> extent(24, 96);
  std::vector<CoverageMask> newer;
  newer.reserve(kNewerPieces);
  for (int piece = 0; piece < kNewerPieces; ++piece) {
    CoverageMask coverage;
    coverage.rect = PlutoRect{current.rect.x + offset(rng),
                                current.rect.y + offset(rng), extent(rng),
                                extent(rng)};
    coverage.stride =
        (static_cast<std::size_t>(coverage.rect.width) + 7u) / 8u;
    coverage.bits.assign(
        coverage.stride * static_cast<std::size_t>(coverage.rect.height), 0u);
    // Sparse newer drive proofs model thin pen segments. Most current bits
    // therefore exercise the legacy scan through all 64 live pieces.
    for (std::int32_t y = 0; y < coverage.rect.height; ++y) {
      for (std::int32_t x = 0; x < coverage.rect.width; ++x) {
        if ((rng() & 127u) != 0) {
          continue;
        }
        coverage.bits[static_cast<std::size_t>(y) * coverage.stride +
                      static_cast<std::size_t>(x) / 8u] |=
            static_cast<std::uint8_t>(
                1u << (static_cast<unsigned>(x) & 7u));
      }
    }
    newer.push_back(std::move(coverage));
  }

  std::vector<std::uint8_t> aggregate(current.bits.size(), 0u);
  std::vector<std::uint8_t> legacy(current.bits.size(), 0u);
  std::vector<std::uint8_t> word(current.bits.size(), 0u);
  legacy_fast_reconcile_mask(current, newer, &legacy);
  if (!word_fast_reconcile_mask(current, newer, &aggregate, &word) ||
      legacy != word) {
    std::fprintf(stderr, "fast reconcile benchmark correctness mismatch\n");
    return false;
  }

  std::vector<double> legacy_samples;
  std::vector<double> word_samples;
  std::uint64_t checksum = 0;
  for (int iteration = 0; iteration < kIterations; ++iteration) {
    auto start = std::chrono::steady_clock::now();
    legacy_fast_reconcile_mask(current, newer, &legacy);
    auto end = std::chrono::steady_clock::now();
    if (iteration >= kIterations / 10) {
      legacy_samples.push_back(
          std::chrono::duration<double, std::micro>(end - start).count());
    }
    checksum += legacy[static_cast<std::size_t>(iteration) % legacy.size()];

    start = std::chrono::steady_clock::now();
    if (!word_fast_reconcile_mask(current, newer, &aggregate, &word)) {
      std::fprintf(stderr, "fast reconcile word merge failed\n");
      return false;
    }
    end = std::chrono::steady_clock::now();
    if (iteration >= kIterations / 10) {
      word_samples.push_back(
          std::chrono::duration<double, std::micro>(end - start).count());
    }
    checksum += word[static_cast<std::size_t>(iteration) % word.size()];
  }
  const Percentiles before = percentiles(std::move(legacy_samples));
  const Percentiles after = percentiles(std::move(word_samples));
  std::printf(
      "fast coverage primitive 96x96/64 legacy p50 %9.1f us  "
      "p95 %9.1f us | "
      "word64 p50 %9.1f us  p95 %9.1f us | speedup %.2fx | checksum %llu\n",
      before.p50, before.p95, after.p50, after.p95,
      after.p50 > 0 ? before.p50 / after.p50 : 0.0,
      static_cast<unsigned long long>(checksum));
  return true;
}

Percentiles percentiles(std::vector<double> samples) {
  Percentiles out;
  if (samples.empty()) {
    return out;
  }
  std::sort(samples.begin(), samples.end());
  out.p50 = samples[samples.size() / 2];
  out.p95 = samples[(samples.size() * 95) / 100];
  out.max = samples.back();
  return out;
}

std::vector<std::uint8_t> random_levels(std::mt19937* rng, std::size_t count) {
  std::uniform_int_distribution<int> level(0, 31);
  std::vector<std::uint8_t> out(count);
  for (auto& byte : out) {
    byte = static_cast<std::uint8_t>(level(*rng));
  }
  return out;
}

// One scenario x one implementation: repeated admissions of `rect` with
// alternating random content, timing every advance (begin_frame -> advance
// -> end_frame when `emitter` is the PhaseEmitter). Returns per-frame us.
struct BenchIo {
  const WaveformTable* table = nullptr;
  PlutoRect rect{};
  bool force_scalar = false;
  bool with_phase_emitter = false;  // fused (vs null-emitter sweep stage)
  int admissions = 6;
};

Percentiles run_engine_bench(const BenchIo& io) {
  PixelEngineConfig config;
  config.width = kLogicalWidth;
  config.height = kLogicalHeight;
  config.stride = kPaddedSourceWidth;
  config.tile_px = 32;
  config.max_active_px = static_cast<std::uint32_t>(kLogicalWidth) *
                             static_cast<std::uint32_t>(kLogicalHeight) +
                         1;  // no banding/budget pacing: pure sweep cost
  config.force_scalar_sweep = io.force_scalar;

  PixelEngine engine;
  if (!engine.configure(io.table, config)) {
    std::fprintf(stderr, "engine configure failed\n");
    return {};
  }

  PhaseEmitter emitter;
  std::vector<std::uint16_t> slot_words;
  std::vector<std::int32_t> impulse_sink;
  std::vector<std::uint8_t> drive_sink;
  if (io.with_phase_emitter) {
    PhaseEmitterConfig emitter_config;
    emitter_config.slot_count = 1;
    emitter_config.force_scalar_deposit = io.force_scalar;
    if (!emitter.configure(emitter_config)) {
      std::fprintf(stderr, "emitter configure failed\n");
      return {};
    }
    slot_words.assign(pluto::swtcon::kDrmPhaseWords, 0);
    emitter.set_slot_target(0, slot_words.data(),
                            kDrmWidth * sizeof(std::uint16_t));
    emitter.blank_slot(0);
    const std::size_t tiles = engine.dc_ledger().tile_count();
    impulse_sink.assign(tiles, 0);
    drive_sink.assign(tiles, 0);
  }
  NullEmitter null_emitter;

  std::mt19937 rng(0x5eedu);
  std::vector<double> per_frame_us;
  std::uint64_t seq = 0;
  for (int admission = 0; admission < io.admissions; ++admission) {
    const std::vector<std::uint8_t> levels = random_levels(
        &rng, static_cast<std::size_t>(io.rect.width) *
                  static_cast<std::size_t>(io.rect.height));
    AdmitRequest request;
    request.rect = io.rect;
    request.mode = 2;
    request.levels = levels.data();
    request.levels_stride = 0;
    request.frame_id = static_cast<std::uint64_t>(admission) + 1;
    if (!engine.admit(request)) {
      std::fprintf(stderr, "admit failed\n");
      return {};
    }
    while (!engine.idle()) {
      const auto start = std::chrono::steady_clock::now();
      if (io.with_phase_emitter) {
        emitter.begin_frame(0, ++seq);
        std::fill(impulse_sink.begin(), impulse_sink.end(), 0);
        std::fill(drive_sink.begin(), drive_sink.end(), 0);
        engine.set_impulse_sink(impulse_sink.data(), drive_sink.data());
        engine.advance(&emitter);
        engine.set_impulse_sink(nullptr, nullptr);
        emitter.end_frame();
      } else {
        engine.advance(&null_emitter);
      }
      const std::chrono::duration<double, std::micro> elapsed =
          std::chrono::steady_clock::now() - start;
      if (admission > 0) {  // warm-up admission excluded
        per_frame_us.push_back(elapsed.count());
      }
    }
  }
  return percentiles(std::move(per_frame_us));
}

// Content conversion (BM-C1): the presenter's convert_levels hot path —
// RGB565 rect -> legalized 5-bit levels via the swtcon_waveform kernel.
// Runs per admission on the scheduler thread; the full-panel case is the
// large-lane worst case (954x1696 = 1.6 Mpx), the 96x96 case one mailbox
// tile piece.
Percentiles run_convert_bench(const PlutoRect& rect, bool force_scalar) {
  constexpr std::size_t kStrideBytes =
      static_cast<std::size_t>(kLogicalWidth) * 2u;
  std::mt19937 rng(0xc0117e57u);
  std::uniform_int_distribution<int> byte(0, 255);
  std::vector<std::uint8_t> surface(
      kStrideBytes * static_cast<std::size_t>(kLogicalHeight));
  for (auto& value : surface) {
    value = static_cast<std::uint8_t>(byte(rng));
  }
  // GAL3 mode-7-shaped bilevel snap map ({2, 28}, ties brighter): the
  // realistic non-identity legalization. Map contents do not affect timing
  // (pure vqtbl2q/LUT lookup).
  std::array<std::uint8_t, 32> map{};
  for (int t = 0; t < 32; ++t) {
    map[static_cast<std::size_t>(t)] = static_cast<std::uint8_t>(t <= 14 ? 2 : 28);
  }
  std::vector<std::uint8_t> out(static_cast<std::size_t>(rect.width) *
                                static_cast<std::size_t>(rect.height));
  const std::uint8_t* src = surface.data() +
                            static_cast<std::size_t>(rect.y) * kStrideBytes +
                            static_cast<std::size_t>(rect.x) * 2u;

  const int iterations = rect.width >= kLogicalWidth ? 60 : 4000;
  std::vector<double> per_call_us;
  std::uint8_t sink = 0;
  for (int i = 0; i < iterations; ++i) {
    const auto start = std::chrono::steady_clock::now();
    if (force_scalar) {
      pluto::swtcon::convert_rgb565_levels_scalar(
          src, kStrideBytes, rect.width, rect.height, map.data(), out.data());
    } else {
      pluto::swtcon::convert_rgb565_levels(
          src, kStrideBytes, rect.width, rect.height, map.data(), out.data());
    }
    const std::chrono::duration<double, std::micro> elapsed =
        std::chrono::steady_clock::now() - start;
    sink ^= out[out.size() / 2];
    if (i >= iterations / 10) {  // warm-up excluded
      per_call_us.push_back(elapsed.count());
    }
  }
  if (sink == 0xff) {
    std::fprintf(stderr, "(sink)\n");  // defeat dead-code elimination
  }
  return percentiles(std::move(per_call_us));
}

std::vector<std::uint8_t> make_bench_ct33() {
  std::vector<std::uint8_t> blob(Ct33Frontend::kBlobBytes);
  for (int r = 0; r < Ct33Frontend::kCubeEdge; ++r) {
    for (int g = 0; g < Ct33Frontend::kCubeEdge; ++g) {
      for (int b = 0; b < Ct33Frontend::kCubeEdge; ++b) {
        const std::size_t cell =
            (static_cast<std::size_t>(r) * Ct33Frontend::kCubeEdge + g) *
                Ct33Frontend::kCubeEdge +
            b;
        const int base = (r + 2 * g + b) / 2;
        for (int slot = 0; slot < 7; ++slot) {
          blob[cell * 8u + static_cast<std::size_t>(slot)] =
              static_cast<std::uint8_t>(
                  std::min(254, base + slot * (255 - base) / 7));
        }
        blob[cell * 8u + 7u] = 255u;
      }
    }
  }
  std::fill_n(blob.begin(), 8, 255u);
  const std::size_t white = (Ct33Frontend::kCubeCells - 1u) * 8u;
  std::fill_n(blob.begin() + static_cast<std::ptrdiff_t>(white), 7, 0u);
  blob[white + 7u] = 255u;
  return blob;
}

// BM-C2: the statically closed ct33 RGB front end. The RGB565 column uses
// configure-time precomputed interpolants; RGB888 performs arbitrary-color
// tetrahedral interpolation on demand. Outputs are byte-identical after 565
// expansion (exhaustively covered in ct33_frontend_test.cc).
Percentiles run_ct33_bench(const PlutoRect& rect, bool rgb565,
                           bool with_luma_selector = false) {
  Ct33Frontend frontend;
  std::string error;
  const std::vector<std::uint8_t> blob = make_bench_ct33();
  if (!frontend.configure(blob, &error)) {
    std::fprintf(stderr, "ct33 configure failed: %s\n", error.c_str());
    return {};
  }

  const std::size_t pixels = static_cast<std::size_t>(rect.width) *
                             static_cast<std::size_t>(rect.height);
  std::mt19937 rng(0xc733beefu);
  std::uniform_int_distribution<int> word(0, 0xffff);
  std::vector<std::uint8_t> source(pixels * (rgb565 ? 2u : 3u));
  for (std::size_t i = 0; i < pixels; ++i) {
    const std::uint16_t packed = static_cast<std::uint16_t>(word(rng));
    if (rgb565) {
      source[i * 2u] = static_cast<std::uint8_t>(packed);
      source[i * 2u + 1u] = static_cast<std::uint8_t>(packed >> 8);
    } else {
      const std::uint8_t r5 = static_cast<std::uint8_t>(packed >> 11);
      const std::uint8_t g6 = static_cast<std::uint8_t>((packed >> 5) & 63u);
      const std::uint8_t b5 = static_cast<std::uint8_t>(packed & 31u);
      source[i * 3u] = static_cast<std::uint8_t>((r5 << 3) | (r5 >> 2));
      source[i * 3u + 1u] = static_cast<std::uint8_t>((g6 << 2) | (g6 >> 4));
      source[i * 3u + 2u] = static_cast<std::uint8_t>((b5 << 3) | (b5 >> 2));
    }
  }
  std::vector<std::uint8_t> out(pixels);
  std::vector<std::uint8_t> selector;
  if (with_luma_selector) {
    selector.assign(pixels, 0xffu);  // worst case: every lane takes luma
  }
  const int iterations = rect.width >= kLogicalWidth ? 24 : 1000;
  std::vector<double> samples;
  std::uint8_t sink = 0;
  for (int i = 0; i < iterations; ++i) {
    const auto start = std::chrono::steady_clock::now();
    const bool ok = rgb565
                        ? frontend.convert_rgb565_le(
                              source.data(),
                              static_cast<std::size_t>(rect.width) * 2u,
                              rect.x, rect.y, rect.width, rect.height,
                              out.data(), rect.width,
                              selector.empty() ? nullptr : selector.data(),
                              selector.empty() ? 0u
                                               : static_cast<std::size_t>(
                                                     rect.width))
                        : frontend.convert_rgb888(
                              source.data(),
                              static_cast<std::size_t>(rect.width) * 3u,
                              rect.x, rect.y, rect.width, rect.height,
                              out.data(), rect.width,
                              selector.empty() ? nullptr : selector.data(),
                              selector.empty() ? 0u
                                               : static_cast<std::size_t>(
                                                     rect.width));
    if (!ok) {
      std::fprintf(stderr, "ct33 conversion failed\n");
      return {};
    }
    const std::chrono::duration<double, std::micro> elapsed =
        std::chrono::steady_clock::now() - start;
    sink ^= out[out.size() / 2u];
    if (i >= iterations / 10) {
      samples.push_back(elapsed.count());
    }
  }
  if (sink == 0xffu) {
    std::fprintf(stderr, "(ct33 sink)\n");
  }
  return percentiles(std::move(samples));
}

// BM-C3: deterministic production selector-16, including source expansion,
// three globally barriered stages, immutable result allocation, and copy-out.
// The object (its backend-lifetime scratch and persistent workers) and source
// surface are intentionally constructed outside the timed loop.
Percentiles run_selector16_bench(const PlutoRect& rect, bool rgb565) {
  const std::size_t bytes_per_pixel = rgb565 ? 2u : 4u;
  const std::size_t stride =
      static_cast<std::size_t>(kLogicalWidth) * bytes_per_pixel;
  std::vector<std::uint8_t> source(
      stride * static_cast<std::size_t>(kLogicalHeight));
  std::mt19937 rng(0x5e1ec716u);
  std::uniform_int_distribution<int> byte(0, 255);
  for (std::size_t offset = 0; offset < source.size();
       offset += bytes_per_pixel) {
    source[offset] = static_cast<std::uint8_t>(byte(rng));
    source[offset + 1u] = static_cast<std::uint8_t>(byte(rng));
    if (!rgb565) {
      source[offset + 2u] = static_cast<std::uint8_t>(byte(rng));
      source[offset + 3u] = 0xffu;
    }
  }

  XochitlSelector16 selector;
  const XochitlSelector16::SourceView view{
      .bytes = source,
      .stride_bytes = stride,
      .width = kLogicalWidth,
      .height = kLogicalHeight,
      .format = rgb565
                    ? XochitlSelector16::SourceFormat::kRgb565LittleEndian
                    : XochitlSelector16::SourceFormat::kArgb8888LittleEndian,
      .right_padding =
          XochitlSelector16::RightPadding::kReplicateLogicalEdge};
  const XochitlSelector16::InclusiveRect update{
      .left = rect.x,
      .top = rect.y,
      .right = rect.x + rect.width - 1,
      .bottom = rect.y + rect.height - 1};
  const int iterations = rect.width >= kLogicalWidth ? 24 : 1000;
  std::vector<double> samples;
  std::uint8_t sink = 0;
  for (int iteration = 0; iteration < iterations; ++iteration) {
    const auto start = std::chrono::steady_clock::now();
    const XochitlSelector16::BuildResult result = selector.build(view, update);
    const std::chrono::duration<double, std::micro> elapsed =
        std::chrono::steady_clock::now() - start;
    if (!result) {
      std::fprintf(stderr, "selector-16 build failed\n");
      return {};
    }
    sink ^= result.mask->bytes()[result.mask->bytes().size() / 2u];
    if (iteration >= iterations / 10) {
      samples.push_back(elapsed.count());
    }
  }
  if (sink == 0x5au) {
    std::fprintf(stderr, "(selector sink)\n");
  }
  return percentiles(std::move(samples));
}

// Deposit stage in isolation: dense full-width rows through emit_row.
Percentiles run_deposit_bench(bool force_scalar) {
  PhaseEmitterConfig config;
  config.slot_count = 1;
  config.force_scalar_deposit = force_scalar;
  PhaseEmitter emitter;
  if (!emitter.configure(config)) {
    return {};
  }
  std::vector<std::uint16_t> slot_words(pluto::swtcon::kDrmPhaseWords, 0);
  emitter.set_slot_target(0, slot_words.data(),
                          kDrmWidth * sizeof(std::uint16_t));
  emitter.blank_slot(0);

  std::mt19937 rng(0xdeedu);
  std::uniform_int_distribution<int> code(0, 7);
  std::vector<PixelOp> ops(static_cast<std::size_t>(kLogicalWidth));
  for (int x = 0; x < kLogicalWidth; ++x) {
    ops[static_cast<std::size_t>(x)] = PixelOp{
        static_cast<std::uint16_t>(x), static_cast<std::uint8_t>(code(rng))};
  }

  std::vector<double> per_frame_us;
  for (int frame = 0; frame < 40; ++frame) {
    const auto start = std::chrono::steady_clock::now();
    emitter.begin_frame(0, static_cast<std::uint64_t>(frame) + 1);
    for (int row = 0; row < kLogicalHeight; ++row) {
      emitter.emit_row(row, ops.data(), ops.size());
    }
    emitter.end_frame();
    const std::chrono::duration<double, std::micro> elapsed =
        std::chrono::steady_clock::now() - start;
    if (frame >= 4) {
      per_frame_us.push_back(elapsed.count());
    }
  }
  return percentiles(std::move(per_frame_us));
}

void print_row(const std::string& name, const Percentiles& scalar,
               const Percentiles& fast) {
  std::printf(
      "%-26s scalar p50 %9.1f us  p95 %9.1f us | %-6s p50 %9.1f us  "
      "p95 %9.1f us | speedup %.2fx\n",
      name.c_str(), scalar.p50, scalar.p95,
      pluto::kNeonKernels ? "neon" : "scalar", fast.p50, fast.p95,
      fast.p50 > 0 ? scalar.p50 / fast.p50 : 0.0);
}

void print_ct33_row(const std::string& name, const Percentiles& rgb888,
                    const Percentiles& rgb565) {
  std::printf(
      "%-26s rgb888 p50 %9.1f us  p95 %9.1f us | rgb565 p50 %9.1f us  "
      "p95 %9.1f us | speedup %.2fx\n",
      name.c_str(), rgb888.p50, rgb888.p95, rgb565.p50, rgb565.p95,
      rgb565.p50 > 0 ? rgb888.p50 / rgb565.p50 : 0.0);
}

void print_selector_row(const std::string& name, const Percentiles& argb,
                        const Percentiles& rgb565) {
  std::printf(
      "%-26s argb   p50 %9.1f us  p95 %9.1f us | rgb565 p50 %9.1f us  "
      "p95 %9.1f us\n",
      name.c_str(), argb.p50, argb.p95, rgb565.p50, rgb565.p95);
}

}  // namespace

int main(int argc, char** argv) {
  const PlutoRect full{0, 0, kLogicalWidth, kLogicalHeight};   // 1.62 Mpx
  const PlutoRect tile96{384, 800, 96, 96};  // interior tile piece
  if (argc == 2 && std::string(argv[1]) == "--fast-reconcile-only") {
    return run_fast_reconcile_bench() ? 0 : 1;
  }
  if (argc == 2 && std::string(argv[1]) == "--selector-only") {
    const Percentiles selector_full_argb = run_selector16_bench(full, false);
    const Percentiles selector_full_rgb565 = run_selector16_bench(full, true);
    print_selector_row("selector16 full-panel", selector_full_argb,
                       selector_full_rgb565);
    const Percentiles selector_tile_argb =
        run_selector16_bench(tile96, false);
    const Percentiles selector_tile_rgb565 =
        run_selector16_bench(tile96, true);
    print_selector_row("selector16 96x96", selector_tile_argb,
                       selector_tile_rgb565);
    return 0;
  }

  WaveformTable table;
  std::string error;
  if (!table.parse(swtcon_synth::make_synthetic_eink(kPhases), &error)) {
    std::fprintf(stderr, "waveform parse failed: %s\n", error.c_str());
    return 1;
  }

  const PlutoRect half_meg{0, 0, kLogicalWidth, 525};          // ~501 Kpx

  std::printf("engine bench: %d phases, scan budget 11764 us/frame, %s\n\n",
              kPhases,
              pluto::kNeonKernels ? "NEON available" : "scalar-only host");

  BenchIo io;
  io.table = &table;

  io.rect = full;
  io.with_phase_emitter = false;
  io.force_scalar = true;
  const Percentiles sweep_full_scalar = run_engine_bench(io);
  io.force_scalar = false;
  const Percentiles sweep_full_fast = run_engine_bench(io);
  print_row("sweep full-field", sweep_full_scalar, sweep_full_fast);

  io.rect = half_meg;
  io.force_scalar = true;
  const Percentiles sweep_half_scalar = run_engine_bench(io);
  io.force_scalar = false;
  const Percentiles sweep_half_fast = run_engine_bench(io);
  print_row("sweep active-500k", sweep_half_scalar, sweep_half_fast);

  const Percentiles deposit_scalar = run_deposit_bench(true);
  const Percentiles deposit_fast = run_deposit_bench(false);
  print_row("deposit full-field rows", deposit_scalar, deposit_fast);

  io.rect = full;
  io.with_phase_emitter = true;
  io.force_scalar = true;
  const Percentiles fused_full_scalar = run_engine_bench(io);
  io.force_scalar = false;
  const Percentiles fused_full_fast = run_engine_bench(io);
  print_row("fused full-field", fused_full_scalar, fused_full_fast);

  io.rect = half_meg;
  io.force_scalar = true;
  const Percentiles fused_half_scalar = run_engine_bench(io);
  io.force_scalar = false;
  const Percentiles fused_half_fast = run_engine_bench(io);
  print_row("fused active-500k", fused_half_scalar, fused_half_fast);

  // BM-C1: content conversion (convert_levels kernel), per-admission cost.
  const Percentiles convert_full_scalar = run_convert_bench(full, true);
  const Percentiles convert_full_fast = run_convert_bench(full, false);
  print_row("convert full-panel", convert_full_scalar, convert_full_fast);
  const Percentiles convert_tile_scalar = run_convert_bench(tile96, true);
  const Percentiles convert_tile_fast = run_convert_bench(tile96, false);
  print_row("convert 96x96 tile", convert_tile_scalar, convert_tile_fast);

  const Percentiles ct33_full_rgb888 = run_ct33_bench(full, false);
  const Percentiles ct33_full_rgb565 = run_ct33_bench(full, true);
  print_ct33_row("ct33 full-panel", ct33_full_rgb888, ct33_full_rgb565);
  const Percentiles ct33_tile_rgb888 = run_ct33_bench(tile96, false);
  const Percentiles ct33_tile_rgb565 = run_ct33_bench(tile96, true);
  print_ct33_row("ct33 96x96 tile", ct33_tile_rgb888, ct33_tile_rgb565);
  const Percentiles ct33_masked_full_rgb888 =
      run_ct33_bench(full, false, true);
  const Percentiles ct33_masked_full_rgb565 =
      run_ct33_bench(full, true, true);
  print_ct33_row("ct33 masked full", ct33_masked_full_rgb888,
                 ct33_masked_full_rgb565);
  const Percentiles ct33_masked_tile_rgb888 =
      run_ct33_bench(tile96, false, true);
  const Percentiles ct33_masked_tile_rgb565 =
      run_ct33_bench(tile96, true, true);
  print_ct33_row("ct33 masked 96x96", ct33_masked_tile_rgb888,
                 ct33_masked_tile_rgb565);

  const Percentiles selector_full_argb = run_selector16_bench(full, false);
  const Percentiles selector_full_rgb565 = run_selector16_bench(full, true);
  print_selector_row("selector16 full-panel", selector_full_argb,
                     selector_full_rgb565);
  const Percentiles selector_tile_argb = run_selector16_bench(tile96, false);
  const Percentiles selector_tile_rgb565 = run_selector16_bench(tile96, true);
  print_selector_row("selector16 96x96", selector_tile_argb,
                     selector_tile_rgb565);

  return 0;
}
