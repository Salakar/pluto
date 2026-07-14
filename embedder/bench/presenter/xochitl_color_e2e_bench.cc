#include "pluto/presenter.h"
#include "presenter/swtcon/drm_swtcon_presenter.h"
#include "presenter/swtcon/phase_emit.h"
#include "presenter/swtcon/pixel_engine.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "presenter/swtcon/xochitl_color_pipeline.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
using pluto::swtcon::MappedAdmitOutcome;
using pluto::swtcon::MappedAdmitRequest;
using pluto::swtcon::MappedAdmitStatus;
using pluto::swtcon::MappedEvent;
using pluto::swtcon::MappedEventKind;
using pluto::swtcon::MappedFinalizeStatus;
using pluto::swtcon::MappedOperationToken;
using pluto::swtcon::PhaseEmitter;
using pluto::swtcon::PhaseEmitterConfig;
using pluto::swtcon::PixelEngine;
using pluto::swtcon::PixelEngineConfig;
using pluto::swtcon::AdmitOutcome;
using pluto::swtcon::AdmitRequest;
using pluto::swtcon::FastCoverage;
using pluto::swtcon::RealWaveformFileReader;
using pluto::swtcon::SwtconWaveform;
using pluto::swtcon::XochitlColorPipeline;
using pluto::swtcon::XochitlHistoryState;

constexpr double kScanBudgetUs = 11764.0;
constexpr int kDefaultRoiSamples = 200;
constexpr int kDefaultFullSamples = 9;
constexpr int kDefaultPenTruthSamples = 9;
constexpr int kDefaultPenTruthRects = 8;

struct Distribution {
  double p50 = 0.0;
  double p95 = 0.0;
  double p99 = 0.0;
  double maximum = 0.0;
};

Distribution distribution(std::vector<double> values) {
  if (values.empty()) {
    return {};
  }
  std::sort(values.begin(), values.end());
  const auto pick = [&](double percentile) {
    const double scaled = percentile * static_cast<double>(values.size() - 1);
    return values[static_cast<std::size_t>(std::ceil(scaled))];
  };
  return {pick(0.50), pick(0.95), pick(0.99), values.back()};
}

double elapsed_us(Clock::time_point begin, Clock::time_point end) {
  return std::chrono::duration<double, std::micro>(end - begin).count();
}

struct Samples {
  std::vector<double> preprocess;
  std::vector<double> prepare;
  std::vector<double> admit;
  std::vector<double> first_build;
  std::vector<double> steady_build;
  std::vector<double> commit;
  std::vector<double> end_to_first;
  std::size_t prepare_build_deadline_misses = 0;
  std::size_t samples = 0;
  std::size_t phases = 0;
  std::uint64_t checksum = 0;
};

struct SafeFastSamples {
  std::vector<double> preprocess;
  std::vector<double> admit;
  std::vector<double> first_build;
  std::vector<double> steady_build;
  std::vector<double> latch_seed;
  std::vector<double> end_to_first;
  std::vector<double> cpu_end_to_seed;
  std::size_t samples = 0;
  std::size_t phases = 0;
  std::size_t driven_lanes = 0;
  std::uint64_t checksum = 0;
};

struct AdmissionAudit {
  double cold_us = 0.0;
  std::vector<double> warm_us;
  std::vector<double> rejection_us;
  std::size_t execution_lanes = 0;
  std::size_t runtime_lane_bytes = 0;
  std::size_t guard_bytes = 0;
  std::size_t rejected_pool_lane_capacity_bytes = 0;
  std::uint64_t checksum = 0;
};

struct PenTruthPresenterSamples {
  std::vector<double> submit;
  std::vector<double> post_submit_drain;
  std::vector<double> submit_to_idle;
  std::uint64_t updates_completed = 0;
  std::uint64_t mapped_admissions = 0;
  std::uint64_t mapped_terminals = 0;
  std::uint64_t mapped_confirmed = 0;
  std::uint64_t input_rects = 0;
  std::uint64_t grouped_tiles = 0;
  std::uint64_t masked_lanes = 0;
  std::uint64_t groups_per_request_max = 0;
};

struct Case {
  const char* name = nullptr;
  XochitlHistoryState::Mode mode = XochitlHistoryState::Mode::kFull;
  XochitlHistoryState::InclusiveRect update{};
  int samples = 0;
  bool draw_back = false;
  bool repeated_palette = false;
};

struct Paths {
  std::string eink;
  std::string ct33_std;
  std::string ct33_best;
  std::string ct33_pen;
  std::string ct33_fast;
};

std::uint64_t counter_delta(std::uint64_t after, std::uint64_t before) {
  return after >= before ? after - before : 0u;
}

bool parse_positive(std::string_view input, int* out) {
  if (out == nullptr || input.empty()) {
    return false;
  }
  int parsed = 0;
  const auto result =
      std::from_chars(input.data(), input.data() + input.size(), parsed);
  if (result.ec != std::errc{} || result.ptr != input.data() + input.size() ||
      parsed <= 0) {
    return false;
  }
  *out = parsed;
  return true;
}

bool regular_file(const std::string& path) {
  std::error_code error;
  return std::filesystem::is_regular_file(path, error);
}

bool load_waveform(const Paths& paths, SwtconWaveform* waveform,
                   std::string* error) {
  if (waveform == nullptr) {
    return false;
  }
  for (const std::string* path : {&paths.eink, &paths.ct33_std,
                                  &paths.ct33_best, &paths.ct33_pen,
                                  &paths.ct33_fast}) {
    if (!regular_file(*path)) {
      if (error != nullptr) {
        *error = "missing input: " + *path;
      }
      return false;
    }
  }
  SwtconWaveform::Files files;
  files.eink_path = paths.eink;
  files.ct33_std_path = paths.ct33_std;
  files.ct33_best_path = paths.ct33_best;
  files.ct33_pen_path = paths.ct33_pen;
  files.ct33_fast_path = paths.ct33_fast;
  RealWaveformFileReader reader;
  return waveform->load(files, reader, error);
}

void store_rgb565(std::vector<std::uint8_t>* surface, int x, int y,
                  std::uint16_t value) {
  const std::size_t offset =
      (static_cast<std::size_t>(y) * pluto::swtcon::kLogicalWidth +
       static_cast<std::size_t>(x)) *
      pluto::swtcon::kRgb565BytesPerPixel;
  (*surface)[offset] = static_cast<std::uint8_t>(value & 0xffu);
  (*surface)[offset + 1] = static_cast<std::uint8_t>(value >> 8u);
}

void paint_case(std::vector<std::uint8_t>* surface, const Case& bench_case,
                int iteration) {
  const auto rect = bench_case.update;
  for (int y = rect.top; y <= rect.bottom; ++y) {
    for (int x = rect.left; x <= rect.right; ++x) {
      std::uint16_t value = 0;
      if (bench_case.draw_back) {
        value = (iteration & 1) == 0 ? 0x001fu : 0xffffu;
      } else if (bench_case.repeated_palette) {
        constexpr std::array<std::uint16_t, 4> kPalette{
            0xf800u, 0x07e0u, 0x001fu, 0xffe0u};
        const std::size_t index = static_cast<std::size_t>(
            ((x >> 5) + (y >> 5) + iteration) & 3);
        value = kPalette[index];
      } else {
        const std::uint32_t hash = static_cast<std::uint32_t>(x) * 2246822519u ^
                                   static_cast<std::uint32_t>(y) * 3266489917u ^
                                   static_cast<std::uint32_t>(iteration) *
                                       668265263u;
        const std::uint16_t r = static_cast<std::uint16_t>((hash >> 27u) & 31u);
        const std::uint16_t g = static_cast<std::uint16_t>((hash >> 21u) & 63u);
        const std::uint16_t b = static_cast<std::uint16_t>((hash >> 16u) & 31u);
        value = static_cast<std::uint16_t>((r << 11u) | (g << 5u) | b);
      }
      store_rgb565(surface, x, y, value);
    }
  }
}

class Harness final {
 public:
  explicit Harness(const SwtconWaveform* waveform) : waveform_(waveform) {}

  bool configure(std::string* error) {
    if (waveform_ == nullptr || !waveform_->loaded() ||
        !pipeline_.configure(&waveform_->table(), waveform_->ct33_bytes(),
                             error) ||
        !pipeline_.initialize_white_history()) {
      return false;
    }

    PixelEngineConfig engine_config;
    engine_config.width = pluto::swtcon::kLogicalWidth;
    engine_config.height = pluto::swtcon::kLogicalHeight;
    engine_config.stride = pluto::swtcon::kPaddedSourceWidth;
    engine_config.tile_px = 32;
    engine_config.max_active_px =
        static_cast<std::uint32_t>(pluto::swtcon::kLogicalWidth) *
            static_cast<std::uint32_t>(pluto::swtcon::kLogicalHeight) +
        1u;
    engine_config.initial_prev_level = 30;
    if (!engine_.configure(&waveform_->table(), engine_config)) {
      if (error != nullptr) {
        *error = "PixelEngine configure failed";
      }
      return false;
    }
    engine_.set_temperature(25.0f);
    engine_.set_mapped_event_callback([this](const MappedEvent& event) {
      if (event.kind == MappedEventKind::kTerminal) {
        terminal_token_ = event.token;
      }
    });
    engine_.set_completion_callback(
        [this](std::uint64_t frame_id) { completions_.push_back(frame_id); });

    PhaseEmitterConfig emitter_config;
    emitter_config.slot_count = 1;
    if (!emitter_.configure(emitter_config)) {
      if (error != nullptr) {
        *error = "PhaseEmitter configure failed";
      }
      return false;
    }
    slot_.assign(pluto::swtcon::kDrmPhaseWords, 0u);
    if (!emitter_.set_slot_target(
            0, slot_.data(),
            pluto::swtcon::kDrmWidth * sizeof(std::uint16_t)) ||
        !emitter_.blank_slot(0)) {
      if (error != nullptr) {
        *error = "PhaseEmitter slot setup failed";
      }
      return false;
    }

    surface_.assign(static_cast<std::size_t>(pluto::swtcon::kLogicalWidth) *
                        pluto::swtcon::kLogicalHeight *
                        pluto::swtcon::kRgb565BytesPerPixel,
                    0xffu);
    return true;
  }

  bool run_safe_fast(XochitlHistoryState::InclusiveRect update, int samples,
                     SafeFastSamples* out, std::string* error) {
    if (out == nullptr || samples <= 0) {
      return false;
    }
    out->preprocess.reserve(samples);
    out->admit.reserve(samples);
    out->first_build.reserve(samples);
    out->latch_seed.reserve(samples);
    out->end_to_first.reserve(samples);
    out->cpu_end_to_seed.reserve(samples);

    const Case bench_case{"safe_fast96", XochitlHistoryState::Mode::kFast,
                          update, samples, true};
    constexpr std::uint64_t kFrameId = 0xf001u;
    for (int iteration = -2; iteration < samples; ++iteration) {
      // Alternate exact black/white so every measured sample is a real
      // opposite-rail draw-back, never a same-endpoint no-op.
      const std::uint16_t value = ((iteration + 2) & 1) == 0 ? 0x0000u
                                                             : 0xffffu;
      for (int y = update.top; y <= update.bottom; ++y) {
        for (int x = update.left; x <= update.right; ++x) {
          store_rgb565(&surface_, x, y, value);
        }
      }
      completions_.clear();

      const auto preprocess_begin = Clock::now();
      XochitlColorPipeline::BuildResult built =
          pipeline_.preprocess_rgb565(
              surface_, static_cast<std::size_t>(
                            pluto::swtcon::kLogicalWidth) *
                            pluto::swtcon::kRgb565BytesPerPixel,
              bench_case.update, XochitlHistoryState::Mode::kFast,
              /*temperature_bin=*/4, /*temperature_celsius=*/25.0f);
      const auto preprocess_end = Clock::now();
      if (!built) {
        if (error != nullptr) {
          *error = "safe Fast preprocess failed";
        }
        return false;
      }

      const auto execution = built.operation->execution();
      const int execution_width = execution.right - execution.left + 1;
      const int execution_height = execution.bottom - execution.top + 1;
      const int visible_right = std::min(
          execution.right, pluto::swtcon::kLogicalWidth - 1);
      const int visible_bottom = std::min(
          execution.bottom, pluto::swtcon::kLogicalHeight - 1);
      const PlutoRect visible{execution.left, execution.top,
                               visible_right - execution.left + 1,
                               visible_bottom - execution.top + 1};
      auto coverage = std::make_shared<FastCoverage>(visible);
      if (!coverage->valid()) {
        if (error != nullptr) {
          *error = "safe Fast coverage allocation failed";
        }
        return false;
      }
      std::vector<std::uint8_t> levels(
          static_cast<std::size_t>(visible.width) * visible.height);
      for (int y = 0; y < visible.height; ++y) {
        for (int x = 0; x < visible.width; ++x) {
          const std::uint8_t raw =
              built.operation->raw()[static_cast<std::size_t>(y) *
                                         built.operation->raw_stride() +
                                     static_cast<std::size_t>(x)];
          levels[static_cast<std::size_t>(y) * visible.width + x] =
              (raw & 31u) == 7u
                  ? pluto::swtcon::kMode7FastWhiteEndpoint
                  : pluto::swtcon::kMode7FastBlackEndpoint;
        }
      }

      AdmitRequest request;
      request.rect = visible;
      request.mode = 7;
      request.temp_bin = built.operation->temperature_bin();
      request.levels = levels.data();
      request.levels_stride = static_cast<std::size_t>(visible.width);
      request.frame_id = kFrameId;
      request.flags = pluto::swtcon::kAdmitFlagPenPreview |
                      pluto::swtcon::kAdmitFlagNoMappedInvalidation |
                      pluto::swtcon::kAdmitFlagFastRailRebase;
      request.fast_coverage = coverage;
      AdmitOutcome outcome;
      const auto admit_begin = Clock::now();
      const bool accepted = engine_.admit(request, &outcome);
      const auto admit_end = Clock::now();
      if (!accepted || !outcome.accepted || outcome.noop_tiles != 0) {
        if (error != nullptr) {
          *error = "safe Fast rail admission failed or became a no-op";
        }
        return false;
      }

      double first_us = 0.0;
      double build_total_us = 0.0;
      std::size_t phases = 0;
      while (std::find(completions_.begin(), completions_.end(), kFrameId) ==
             completions_.end()) {
        const auto build_begin = Clock::now();
        if (!emitter_.begin_frame(0, ++sequence_)) {
          if (error != nullptr) {
            *error = "safe Fast begin_frame failed";
          }
          return false;
        }
        engine_.advance(&emitter_);
        emitter_.end_frame();
        const auto build_end = Clock::now();
        const double build_us = elapsed_us(build_begin, build_end);
        if (phases == 0) {
          first_us = build_us;
        } else if (iteration >= 0) {
          out->steady_build.push_back(build_us);
        }
        build_total_us += build_us;
        if (++phases > 32u) {
          if (error != nullptr) {
            *error = "safe Fast exceeded its certified phase bound";
          }
          return false;
        }
      }
      if (phases != 11u || coverage->empty()) {
        if (error != nullptr) {
          *error = "safe Fast did not produce the exact 11-phase coverage";
        }
        return false;
      }

      const std::size_t mask_stride =
          (static_cast<std::size_t>(execution_width) + 7u) / 8u;
      std::vector<std::uint8_t> execution_mask(
          mask_stride * static_cast<std::size_t>(execution_height), 0u);
      for (int y = 0; y < visible.height; ++y) {
        for (int x = 0; x < visible.width; ++x) {
          if (!coverage->driven(visible.x + x, visible.y + y)) {
            continue;
          }
          execution_mask[static_cast<std::size_t>(y) * mask_stride +
                         static_cast<std::size_t>(x) / 8u] |=
              static_cast<std::uint8_t>(1u << (x & 7));
        }
      }
      const auto seed_begin = Clock::now();
      const bool seeded = pipeline_.history().reseed_fast_region_from_raw(
          built.operation->requested(), execution, built.operation->raw(),
          built.operation->raw_stride(), execution_mask, mask_stride);
      const bool confirmed =
          seeded && engine_.confirm_safe_fast_latched(
                        *coverage, coverage->bits(), coverage->stride_bytes());
      const auto seed_end = Clock::now();
      if (!confirmed) {
        if (error != nullptr) {
          *error = "safe Fast virtual-latch masked seed failed";
        }
        return false;
      }

      if (iteration < 0) {
        continue;
      }
      const double preprocess_us =
          elapsed_us(preprocess_begin, preprocess_end);
      const double admit_us = elapsed_us(admit_begin, admit_end);
      const double seed_us = elapsed_us(seed_begin, seed_end);
      out->preprocess.push_back(preprocess_us);
      out->admit.push_back(admit_us);
      out->first_build.push_back(first_us);
      out->latch_seed.push_back(seed_us);
      out->end_to_first.push_back(preprocess_us + admit_us + first_us);
      out->cpu_end_to_seed.push_back(preprocess_us + admit_us +
                                     build_total_us + seed_us);
      out->phases += phases;
      out->driven_lanes += coverage->driven_count();
      out->checksum += coverage->driven_count();
      out->checksum += built.operation->raw().front();
      ++out->samples;
    }
    return true;
  }

  bool run(const Case& bench_case, Samples* out, std::string* error) {
    if (out == nullptr || bench_case.samples <= 0) {
      return false;
    }
    out->preprocess.reserve(bench_case.samples);
    out->prepare.reserve(bench_case.samples);
    out->admit.reserve(bench_case.samples);
    out->first_build.reserve(bench_case.samples);
    out->commit.reserve(bench_case.samples);
    out->end_to_first.reserve(bench_case.samples);

    for (int iteration = -2; iteration < bench_case.samples; ++iteration) {
      paint_case(&surface_, bench_case, iteration);
      terminal_token_ = 0;

      const auto preprocess_begin = Clock::now();
      XochitlColorPipeline::BuildResult built =
          pipeline_.preprocess_rgb565(
              surface_, static_cast<std::size_t>(pluto::swtcon::kLogicalWidth) *
                            pluto::swtcon::kRgb565BytesPerPixel,
              bench_case.update, bench_case.mode, /*temperature_bin=*/4,
              /*temperature_celsius=*/25.0f);
      const auto preprocess_end = Clock::now();
      if (!built) {
        if (error != nullptr) {
          *error = "color preprocess failed";
        }
        return false;
      }

      const auto prepare_begin = Clock::now();
      XochitlColorPipeline::PrepareResult prepared =
          pipeline_.prepare(*built.operation);
      const auto prepare_end = Clock::now();
      if (!prepared) {
        if (error != nullptr) {
          *error = "history prepare failed";
        }
        return false;
      }

      MappedAdmitOutcome admitted;
      const auto admit_begin = Clock::now();
      const bool accepted = engine_.admit_mapped(
          MappedAdmitRequest{.operation = prepared.operation,
                             .history = &pipeline_.history(),
                             .temp_bin = built.operation->temperature_bin(),
                             .frame_id = 1},
          &admitted);
      const auto admit_end = Clock::now();
      if (!accepted) {
        if (error != nullptr) {
          *error = "mapped admission failed";
        }
        return false;
      }

      const auto first_begin = Clock::now();
      if (!emitter_.begin_frame(0, ++sequence_)) {
        if (error != nullptr) {
          *error = "first begin_frame failed";
        }
        return false;
      }
      engine_.advance(&emitter_);
      emitter_.end_frame();
      const auto first_end = Clock::now();
      const double first_us = elapsed_us(first_begin, first_end);
      std::size_t phases = 1;
      while (terminal_token_ == 0) {
        const auto steady_begin = Clock::now();
        if (!emitter_.begin_frame(0, ++sequence_)) {
          if (error != nullptr) {
            *error = "steady begin_frame failed";
          }
          return false;
        }
        engine_.advance(&emitter_);
        emitter_.end_frame();
        const auto steady_end = Clock::now();
        if (iteration >= 0) {
          out->steady_build.push_back(elapsed_us(steady_begin, steady_end));
        }
        if (++phases > 255u) {
          if (error != nullptr) {
            *error = "mapped operation exceeded 255 phases";
          }
          return false;
        }
      }
      if (terminal_token_ != admitted.token) {
        if (error != nullptr) {
          *error = "terminal token mismatch";
        }
        return false;
      }

      const auto commit_begin = Clock::now();
      const MappedFinalizeStatus committed =
          engine_.confirm_mapped(terminal_token_);
      const auto commit_end = Clock::now();
      if (committed != MappedFinalizeStatus::kConfirmed) {
        if (error != nullptr) {
          *error = "mapped commit failed";
        }
        return false;
      }

      if (iteration < 0) {
        continue;
      }
      const double preprocess_us =
          elapsed_us(preprocess_begin, preprocess_end);
      const double prepare_us = elapsed_us(prepare_begin, prepare_end);
      const double admit_us = elapsed_us(admit_begin, admit_end);
      const double commit_us = elapsed_us(commit_begin, commit_end);
      out->preprocess.push_back(preprocess_us);
      out->prepare.push_back(prepare_us);
      out->admit.push_back(admit_us);
      out->first_build.push_back(first_us);
      out->commit.push_back(commit_us);
      out->end_to_first.push_back(preprocess_us + prepare_us + admit_us +
                                  first_us);
      if (prepare_us + admit_us + first_us > kScanBudgetUs) {
        ++out->prepare_build_deadline_misses;
      }
      out->phases += phases;
      out->checksum += prepared.operation->lanes().front().transition;
      out->checksum += prepared.operation->lanes().back().a2;
      out->checksum += emitter_.stats().ops_deposited;
      ++out->samples;
    }
    return true;
  }

  bool run_admission_audit(AdmissionAudit* out, std::string* error) {
    if (out == nullptr) {
      return false;
    }
    constexpr int kWarmSamples = 20;
    constexpr int kRejectionSamples = 100;
    const Case near_full{
        "near_full_single_guard", XochitlHistoryState::Mode::kFull,
        {1, 0, pluto::swtcon::kLogicalWidth - 1,
         pluto::swtcon::kLogicalHeight - 1},
        1, false};
    const Case partial{"partial_rejection", XochitlHistoryState::Mode::kFull,
                       {1, 0, 8, 1}, 1, true};
    int iteration = 0;
    const auto prepare = [&](const Case& bench_case,
                             XochitlColorPipeline::PrepareResult* prepared,
                             int* temp_bin) {
      paint_case(&surface_, bench_case, iteration++);
      auto built = pipeline_.preprocess_rgb565(
          surface_,
          static_cast<std::size_t>(pluto::swtcon::kLogicalWidth) *
              pluto::swtcon::kRgb565BytesPerPixel,
          bench_case.update, bench_case.mode, /*temperature_bin=*/4,
          /*temperature_celsius=*/25.0f);
      if (!built) {
        return false;
      }
      *temp_bin = built.operation->temperature_bin();
      *prepared = pipeline_.prepare(*built.operation);
      return static_cast<bool>(*prepared);
    };
    const auto admit = [&](const XochitlColorPipeline::PrepareResult& prepared,
                           int temp_bin, MappedAdmitOutcome* admitted) {
      return engine_.admit_mapped(
          MappedAdmitRequest{.operation = prepared.operation,
                             .history = &pipeline_.history(),
                             .temp_bin = temp_bin,
                             .frame_id = 0xa001u},
          admitted);
    };

    XochitlColorPipeline::PrepareResult prepared;
    int temp_bin = 0;
    if (!prepare(near_full, &prepared, &temp_bin)) {
      if (error != nullptr) {
        *error = "admission audit cold prepare failed";
      }
      return false;
    }
    MappedAdmitOutcome admitted;
    auto begin = Clock::now();
    const bool cold_accepted = admit(prepared, temp_bin, &admitted);
    auto end = Clock::now();
    if (!cold_accepted || admitted.status != MappedAdmitStatus::kStarted) {
      if (error != nullptr) {
        *error = "admission audit cold admit failed";
      }
      return false;
    }
    out->cold_us = elapsed_us(begin, end);
    out->execution_lanes = prepared.operation->lanes().size();
    out->runtime_lane_bytes = engine_.mapped_runtime_lane_storage_bytes();
    out->guard_bytes = engine_.mapped_guard_storage_bytes();
    out->checksum += prepared.operation->transitions().front();
    if (engine_.discard_mapped(admitted.token) !=
        MappedFinalizeStatus::kDiscarded) {
      return false;
    }

    out->warm_us.reserve(kWarmSamples);
    for (int sample = 0; sample < kWarmSamples; ++sample) {
      if (!prepare(near_full, &prepared, &temp_bin)) {
        return false;
      }
      begin = Clock::now();
      const bool accepted = admit(prepared, temp_bin, &admitted);
      end = Clock::now();
      if (!accepted || admitted.status != MappedAdmitStatus::kStarted ||
          engine_.discard_mapped(admitted.token) !=
              MappedFinalizeStatus::kDiscarded) {
        return false;
      }
      out->warm_us.push_back(elapsed_us(begin, end));
    }

    if (!prepare(near_full, &prepared, &temp_bin) ||
        !admit(prepared, temp_bin, &admitted) ||
        admitted.status != MappedAdmitStatus::kStarted) {
      return false;
    }
    const MappedOperationToken active_token = admitted.token;
    out->rejection_us.reserve(kRejectionSamples);
    for (int sample = 0; sample < kRejectionSamples; ++sample) {
      XochitlColorPipeline::PrepareResult rejected;
      int rejected_bin = 0;
      if (!prepare(partial, &rejected, &rejected_bin)) {
        return false;
      }
      begin = Clock::now();
      const bool accepted = admit(rejected, rejected_bin, &admitted);
      end = Clock::now();
      if (accepted || admitted.status != MappedAdmitStatus::kConflictPartial) {
        return false;
      }
      out->rejection_us.push_back(elapsed_us(begin, end));
    }
    out->rejected_pool_lane_capacity_bytes =
        engine_.mapped_runtime_pool_lane_capacity_bytes();
    out->checksum += out->runtime_lane_bytes + out->guard_bytes +
                     out->rejected_pool_lane_capacity_bytes;
    return engine_.discard_mapped(active_token) ==
           MappedFinalizeStatus::kDiscarded;
  }

 private:
  const SwtconWaveform* waveform_ = nullptr;
  XochitlColorPipeline pipeline_;
  PixelEngine engine_;
  PhaseEmitter emitter_;
  std::vector<std::uint16_t> slot_;
  std::vector<std::uint8_t> surface_;
  std::vector<std::uint64_t> completions_;
  MappedOperationToken terminal_token_ = 0;
  std::uint64_t sequence_ = 0;
};

class PenTruthPresenterHarness final {
 public:
  ~PenTruthPresenterHarness() {
    if (presenter_ != nullptr && ops_ != nullptr) {
      ops_->close(presenter_);
    }
  }

  bool configure(const Paths &paths, std::string *error) {
    options_ =
        "dry_run=1,flip_interval_ms=0,scan_period_ns=0,stats_log_s=0,"
        "handoff=0,exact_color=1,eink=" +
        paths.eink + ",ct33_std=" + paths.ct33_std +
        ",ct33_best=" + paths.ct33_best + ",ct33_pen=" + paths.ct33_pen +
        ",ct33_fast=" + paths.ct33_fast;
    ops_ = pluto_presenter_by_name("swtcon");
    if (ops_ == nullptr) {
      if (error != nullptr) {
        *error = "swtcon presenter is not registered";
      }
      return false;
    }
    PlutoPresenterConfig config{};
    config.struct_size = sizeof(config);
    config.backend_name = "swtcon";
    config.options = options_.c_str();
    const PlutoStatus opened = ops_->open(&config, &presenter_);
    if (opened != kPlutoStatusOk || presenter_ == nullptr) {
      if (error != nullptr) {
        *error = "swtcon presenter open failed with status " +
                 std::to_string(static_cast<int>(opened));
      }
      return false;
    }
    surface_.assign(pluto::swtcon::kLogicalFrameBytes, 0xffu);
    if (ops_->wait_idle(presenter_, 30000) != kPlutoStatusOk) {
      if (error != nullptr) {
        *error = "swtcon cold-clear wait timed out";
      }
      return false;
    }
    return true;
  }

  bool run(std::span<const PlutoRect> rects, int samples, bool batched,
           PenTruthPresenterSamples *out, std::string *error) {
    if (presenter_ == nullptr || rects.size() < 2u || samples <= 0 ||
        out == nullptr) {
      return false;
    }
    out->submit.reserve(samples);
    out->post_submit_drain.reserve(samples);
    out->submit_to_idle.reserve(samples);

    const auto run_iteration = [&](int iteration, bool record) {
      const std::uint16_t value =
          ((iteration + 2) & 1) == 0 ? 0x0000u : 0xffffu;
      double submit_us = 0.0;
      const auto wall_begin = Clock::now();
      if (batched) {
        for (const PlutoRect &rect : rects) {
          paint_rect(rect, value);
        }
        const auto begin = Clock::now();
        if (!submit(rects, error)) {
          return false;
        }
        submit_us += elapsed_us(begin, Clock::now());
      } else {
        for (const PlutoRect &rect : rects) {
          // Model independent app frames: each exact region becomes visible
          // immediately before its own PenTruth request. This prevents the
          // first dense baseline request from observing all later changes.
          paint_rect(rect, value);
          const auto begin = Clock::now();
          if (!submit(std::span<const PlutoRect>(&rect, 1), error)) {
            return false;
          }
          submit_us += elapsed_us(begin, Clock::now());
        }
      }
      const auto drain_begin = Clock::now();
      if (ops_->wait_idle(presenter_, 30000) != kPlutoStatusOk) {
        if (error != nullptr) {
          *error = "PenTruth presenter drain timed out";
        }
        return false;
      }
      const auto idle = Clock::now();
      if (record) {
        out->submit.push_back(submit_us);
        out->post_submit_drain.push_back(elapsed_us(drain_begin, idle));
        out->submit_to_idle.push_back(elapsed_us(wall_begin, idle));
      }
      return true;
    };

    // Two opposite-rail warmups leave both strategies on identical white
    // history before the first measured black draw.
    if (!run_iteration(-2, false) || !run_iteration(-1, false)) {
      return false;
    }
    PlutoSwtconDebugStats before{};
    before.struct_size = sizeof(before);
    if (pluto_swtcon_presenter_debug_stats(presenter_, &before) !=
        kPlutoStatusOk) {
      if (error != nullptr) {
        *error = "PenTruth presenter pre-run stats failed";
      }
      return false;
    }
    for (int iteration = 0; iteration < samples; ++iteration) {
      if (!run_iteration(iteration, true)) {
        return false;
      }
    }
    PlutoSwtconDebugStats after{};
    after.struct_size = sizeof(after);
    if (pluto_swtcon_presenter_debug_stats(presenter_, &after) !=
        kPlutoStatusOk) {
      if (error != nullptr) {
        *error = "PenTruth presenter post-run stats failed";
      }
      return false;
    }
    out->updates_completed =
        counter_delta(after.updates_completed, before.updates_completed);
    out->mapped_admissions =
        counter_delta(after.mapped_admissions, before.mapped_admissions);
    out->mapped_terminals =
        counter_delta(after.mapped_terminals, before.mapped_terminals);
    out->mapped_confirmed =
        counter_delta(after.mapped_confirmed, before.mapped_confirmed);
    out->input_rects = counter_delta(after.color_pen_truth_input_rects,
                                     before.color_pen_truth_input_rects);
    out->grouped_tiles = counter_delta(after.color_pen_truth_grouped_tiles,
                                       before.color_pen_truth_grouped_tiles);
    out->masked_lanes = counter_delta(after.color_pen_truth_masked_lanes,
                                      before.color_pen_truth_masked_lanes);
    out->groups_per_request_max = after.color_pen_truth_groups_per_request_max;
    return true;
  }

 private:
  void paint_rect(const PlutoRect &rect, std::uint16_t value) {
    for (int y = rect.y; y < rect.y + rect.height; ++y) {
      for (int x = rect.x; x < rect.x + rect.width; ++x) {
        store_rgb565(&surface_, x, y, value);
      }
    }
  }

  bool submit(std::span<const PlutoRect> rects, std::string *error) {
    PlutoPresentRequest request{};
    request.struct_size = sizeof(request);
    request.surface.pixels = surface_.data();
    request.surface.stride_bytes = pluto::swtcon::kLogicalStrideBytes;
    request.surface.width = pluto::swtcon::kLogicalWidth;
    request.surface.height = pluto::swtcon::kLogicalHeight;
    request.surface.format = kPlutoPixelFormatRgb565;
    request.damage = rects.data();
    request.damage_count = rects.size();
    request.refresh_class = kPlutoRefreshFull;
    request.flags = kPlutoPresentFlagPenTruth;
    request.frame_id = next_frame_id_++;

    const auto deadline = Clock::now() + std::chrono::seconds(20);
    PlutoStatus status = kPlutoStatusAgain;
    while (status == kPlutoStatusAgain && Clock::now() < deadline) {
      status = ops_->present(presenter_, &request);
      if (status == kPlutoStatusAgain) {
        std::this_thread::yield();
      }
    }
    if (status == kPlutoStatusOk) {
      return true;
    }
    if (error != nullptr) {
      *error = "PenTruth present failed with status " +
               std::to_string(static_cast<int>(status));
    }
    return false;
  }

  const PlutoPresenterOps *ops_ = nullptr;
  PlutoPresenter *presenter_ = nullptr;
  std::string options_;
  std::vector<std::uint8_t> surface_;
  std::uint64_t next_frame_id_ = 1;
};

void print_distribution(const char* stage, const std::vector<double>& values) {
  const Distribution value = distribution(values);
  std::printf("  %-16s p50=%9.2f p95=%9.2f p99=%9.2f max=%9.2f us\n",
              stage, value.p50, value.p95, value.p99, value.maximum);
}

void print_case(const Case& bench_case, const Samples& samples) {
  const double average_phases =
      samples.samples == 0
          ? 0.0
          : static_cast<double>(samples.phases) / samples.samples;
  std::printf("color_e2e case=%s mode=%d rect=%d,%d-%d,%d samples=%zu "
              "avg_phases=%.1f scan_budget_us=%.0f misses=%zu checksum=%llu\n",
              bench_case.name, static_cast<int>(bench_case.mode),
              bench_case.update.left, bench_case.update.top,
              bench_case.update.right, bench_case.update.bottom,
              samples.samples, average_phases, kScanBudgetUs,
              samples.prepare_build_deadline_misses,
              static_cast<unsigned long long>(samples.checksum));
  print_distribution("preprocess", samples.preprocess);
  print_distribution("history_prepare", samples.prepare);
  print_distribution("engine_admit", samples.admit);
  print_distribution("first_build", samples.first_build);
  print_distribution("steady_build", samples.steady_build);
  print_distribution("history_commit", samples.commit);
  print_distribution("end_to_first", samples.end_to_first);
}

void print_safe_fast(const SafeFastSamples& samples) {
  const double average_phases =
      samples.samples == 0
          ? 0.0
          : static_cast<double>(samples.phases) / samples.samples;
  const double average_driven =
      samples.samples == 0
          ? 0.0
          : static_cast<double>(samples.driven_lanes) / samples.samples;
  std::printf("color_e2e case=safe_fast96_production mode=7 samples=%zu "
              "avg_phases=%.1f avg_driven=%.1f optical_first_scan=1 "
              "optical_terminal_scans=11 checksum=%llu\n",
              samples.samples, average_phases, average_driven,
              static_cast<unsigned long long>(samples.checksum));
  print_distribution("preprocess", samples.preprocess);
  print_distribution("engine_admit", samples.admit);
  print_distribution("first_build", samples.first_build);
  print_distribution("steady_build", samples.steady_build);
  print_distribution("latch_seed", samples.latch_seed);
  print_distribution("end_to_first", samples.end_to_first);
  print_distribution("cpu_end_to_seed", samples.cpu_end_to_seed);
}

void print_admission_audit(const AdmissionAudit& audit) {
  const Distribution warm = distribution(audit.warm_us);
  const Distribution rejected = distribution(audit.rejection_us);
  std::printf(
      "color_e2e case=mapped_admission_audit cold_us=%.2f "
      "warm_p50_us=%.2f warm_p95_us=%.2f rejection_p50_us=%.2f "
      "rejection_p95_us=%.2f execution_lanes=%zu runtime_lane_bytes=%zu "
      "guard_bytes=%zu rejected_pool_lane_capacity_bytes=%zu checksum=%llu\n",
      audit.cold_us, warm.p50, warm.p95, rejected.p50, rejected.p95,
      audit.execution_lanes, audit.runtime_lane_bytes, audit.guard_bytes,
      audit.rejected_pool_lane_capacity_bytes,
      static_cast<unsigned long long>(audit.checksum));
}

void print_pen_truth_strategy(const char *strategy, int samples,
                              const PenTruthPresenterSamples &value) {
  const double divisor = static_cast<double>(samples);
  std::printf(
      "pen_truth_same_tile strategy=%s samples=%d "
      "updates_per_sample=%.2f admissions_per_sample=%.2f "
      "terminals_per_sample=%.2f confirmed_per_sample=%.2f "
      "input_rects=%llu grouped_tiles=%llu masked_lanes=%llu "
      "group_max=%llu\n",
      strategy, samples, static_cast<double>(value.updates_completed) / divisor,
      static_cast<double>(value.mapped_admissions) / divisor,
      static_cast<double>(value.mapped_terminals) / divisor,
      static_cast<double>(value.mapped_confirmed) / divisor,
      static_cast<unsigned long long>(value.input_rects),
      static_cast<unsigned long long>(value.grouped_tiles),
      static_cast<unsigned long long>(value.masked_lanes),
      static_cast<unsigned long long>(value.groups_per_request_max));
  print_distribution("present_submit", value.submit);
  print_distribution("post_submit_drain", value.post_submit_drain);
  print_distribution("submit_to_idle", value.submit_to_idle);
}

bool run_pen_truth_comparison(const Paths &paths, int rect_count, int samples,
                              std::string *error) {
  constexpr int kBaseX = 96;
  constexpr int kBaseY = 256;
  constexpr int kCell = 4;
  constexpr int kStep = 8;
  constexpr int kColumns = 4;
  std::vector<PlutoRect> rects;
  rects.reserve(static_cast<std::size_t>(rect_count));
  for (int index = 0; index < rect_count; ++index) {
    rects.push_back({kBaseX + (index % kColumns) * kStep,
                     kBaseY + (index / kColumns) * kStep, kCell, kCell});
  }

  PenTruthPresenterSamples separate;
  {
    PenTruthPresenterHarness harness;
    if (!harness.configure(paths, error) ||
        !harness.run(rects, samples, /*batched=*/false, &separate, error)) {
      return false;
    }
  }
  PenTruthPresenterSamples batched;
  {
    PenTruthPresenterHarness harness;
    if (!harness.configure(paths, error) ||
        !harness.run(rects, samples, /*batched=*/true, &batched, error)) {
      return false;
    }
  }

  const std::uint64_t expected_input =
      static_cast<std::uint64_t>(samples) * rects.size();
  const std::uint64_t expected_groups = static_cast<std::uint64_t>(samples);
  const std::uint64_t expected_lanes =
      expected_input * static_cast<std::uint64_t>(kCell * kCell);
  if (separate.updates_completed != expected_input ||
      separate.mapped_admissions != expected_input ||
      separate.mapped_terminals != expected_input ||
      separate.mapped_confirmed != expected_input) {
    if (error != nullptr) {
      *error = "separate PenTruth baseline lost a mapped terminal";
    }
    return false;
  }
  if (batched.updates_completed != expected_groups ||
      batched.mapped_admissions != expected_groups ||
      batched.mapped_terminals != expected_groups ||
      batched.mapped_confirmed != expected_groups) {
    if (error != nullptr) {
      *error = "masked PenTruth batch did not produce exactly one terminal";
    }
    return false;
  }
  if (batched.input_rects != expected_input ||
      batched.grouped_tiles != expected_groups ||
      batched.masked_lanes != expected_lanes ||
      batched.groups_per_request_max != 1u) {
    if (error != nullptr) {
      *error = "same-tile request did not take the exact masked PenTruth path";
    }
    return false;
  }
  if (separate.grouped_tiles != 0u || separate.masked_lanes != 0u) {
    if (error != nullptr) {
      *error = "single-rect baseline unexpectedly took the grouped mask path";
    }
    return false;
  }

  std::printf(
      "pen_truth_same_tile rects=%d rect_px=%dx%d tile=32x32 "
      "mode=Full scan_period_ns=0\n",
      rect_count, kCell, kCell);
  print_pen_truth_strategy("separate", samples, separate);
  print_pen_truth_strategy("masked_batch", samples, batched);
  const Distribution separate_total = distribution(separate.submit_to_idle);
  const Distribution batched_total = distribution(batched.submit_to_idle);
  const Distribution separate_submit = distribution(separate.submit);
  const Distribution batched_submit = distribution(batched.submit);
  std::printf(
      "pen_truth_same_tile speedup_p50=%.2fx speedup_p95=%.2fx "
      "submit_speedup_p95=%.2fx operation_reduction=%.2fx\n",
      batched_total.p50 > 0.0 ? separate_total.p50 / batched_total.p50 : 0.0,
      batched_total.p95 > 0.0 ? separate_total.p95 / batched_total.p95 : 0.0,
      batched_submit.p95 > 0.0 ? separate_submit.p95 / batched_submit.p95 : 0.0,
      batched.mapped_terminals > 0u
          ? static_cast<double>(separate.mapped_terminals) /
                static_cast<double>(batched.mapped_terminals)
          : 0.0);
  return true;
}

void usage(const char* program) {
  std::fprintf(stderr,
               "usage: %s EINK CT33_DIR [--roi-samples=N] "
               "[--full-samples=N] [--pen-truth-samples=N] "
               "[--pen-truth-rects=2..16] [--pen-truth-only]\n",
               program);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    usage(argv[0]);
    return 2;
  }
  int roi_samples = kDefaultRoiSamples;
  int full_samples = kDefaultFullSamples;
  int pen_truth_samples = kDefaultPenTruthSamples;
  int pen_truth_rects = kDefaultPenTruthRects;
  bool pen_truth_only = false;
  for (int i = 3; i < argc; ++i) {
    const std::string_view argument(argv[i]);
    constexpr std::string_view kRoi = "--roi-samples=";
    constexpr std::string_view kFull = "--full-samples=";
    constexpr std::string_view kPenTruthSamples = "--pen-truth-samples=";
    constexpr std::string_view kPenTruthRects = "--pen-truth-rects=";
    if (argument.starts_with(kRoi)) {
      if (!parse_positive(argument.substr(kRoi.size()), &roi_samples)) {
        usage(argv[0]);
        return 2;
      }
    } else if (argument.starts_with(kFull)) {
      if (!parse_positive(argument.substr(kFull.size()), &full_samples)) {
        usage(argv[0]);
        return 2;
      }
    } else if (argument.starts_with(kPenTruthSamples)) {
      if (!parse_positive(argument.substr(kPenTruthSamples.size()),
                          &pen_truth_samples)) {
        usage(argv[0]);
        return 2;
      }
    } else if (argument.starts_with(kPenTruthRects)) {
      if (!parse_positive(argument.substr(kPenTruthRects.size()),
                          &pen_truth_rects) ||
          pen_truth_rects < 2 || pen_truth_rects > 16) {
        usage(argv[0]);
        return 2;
      }
    } else if (argument == "--pen-truth-only") {
      pen_truth_only = true;
    } else {
      usage(argv[0]);
      return 2;
    }
  }

  const std::filesystem::path ct33_dir(argv[2]);
  const Paths paths{
      .eink = argv[1],
      .ct33_std = (ct33_dir / "ct33_std.bin").string(),
      .ct33_best = (ct33_dir / "ct33_best.bin").string(),
      .ct33_pen = (ct33_dir / "ct33_pen.bin").string(),
      .ct33_fast = (ct33_dir / "ct33_fast.bin").string(),
  };
  SwtconWaveform waveform;
  std::string error;
  if (!load_waveform(paths, &waveform, &error)) {
    std::fprintf(stderr, "color_e2e: %s\n", error.c_str());
    return 3;
  }

  if (pen_truth_only) {
    if (!run_pen_truth_comparison(paths, pen_truth_rects, pen_truth_samples,
                                  &error)) {
      std::fprintf(stderr, "color_e2e pen_truth: %s\n", error.c_str());
      return 6;
    }
    return 0;
  }

  {
    Harness harness(&waveform);
    if (!harness.configure(&error)) {
      std::fprintf(stderr, "color_e2e safe_fast configure: %s\n",
                   error.c_str());
      return 4;
    }
    SafeFastSamples samples;
    if (!harness.run_safe_fast({96, 256, 191, 351}, roi_samples, &samples,
                               &error)) {
      std::fprintf(stderr, "color_e2e safe_fast: %s\n", error.c_str());
      return 5;
    }
    print_safe_fast(samples);
  }

  {
    Harness harness(&waveform);
    if (!harness.configure(&error)) {
      std::fprintf(stderr, "color_e2e admission audit configure: %s\n",
                   error.c_str());
      return 4;
    }
    AdmissionAudit audit;
    if (!harness.run_admission_audit(&audit, &error)) {
      std::fprintf(stderr, "color_e2e admission audit: %s\n",
                   error.c_str());
      return 5;
    }
    print_admission_audit(audit);
  }

  const int right = pluto::swtcon::kLogicalWidth - 1;
  const int bottom = pluto::swtcon::kLogicalHeight - 1;
  const std::array<Case, 8> cases{{
      {"mapped_fast96_reference", XochitlHistoryState::Mode::kFast,
       {96, 256, 191, 351}, roi_samples, false},
      {"full16", XochitlHistoryState::Mode::kFull, {96, 256, 111, 271},
       roi_samples, false},
      {"full96", XochitlHistoryState::Mode::kFull, {96, 256, 191, 351},
       roi_samples, false},
      {"directional256x64", XochitlHistoryState::Mode::kFull,
       {96, 256, 351, 319}, roi_samples, false},
      {"draw_back96", XochitlHistoryState::Mode::kFull,
       {96, 256, 191, 351}, roi_samples, true},
      {"bottom_right_guard", XochitlHistoryState::Mode::kFull,
       {right - 15, bottom - 15, right, bottom}, roi_samples, false},
      {"full_panel_palette", XochitlHistoryState::Mode::kFull,
       {0, 0, right, bottom}, full_samples, false, true},
      {"full_panel", XochitlHistoryState::Mode::kFull,
       {0, 0, right, bottom}, full_samples, false},
  }};

  for (const Case& bench_case : cases) {
    Harness harness(&waveform);
    if (!harness.configure(&error)) {
      std::fprintf(stderr, "color_e2e case=%s configure: %s\n",
                   bench_case.name, error.c_str());
      return 4;
    }
    Samples samples;
    if (!harness.run(bench_case, &samples, &error)) {
      std::fprintf(stderr, "color_e2e case=%s: %s\n", bench_case.name,
                   error.c_str());
      return 5;
    }
    print_case(bench_case, samples);
  }
  if (!run_pen_truth_comparison(paths, pen_truth_rects, pen_truth_samples,
                                &error)) {
    std::fprintf(stderr, "color_e2e pen_truth: %s\n", error.c_str());
    return 6;
  }
  return 0;
}
