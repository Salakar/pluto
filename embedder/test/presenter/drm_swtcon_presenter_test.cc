// Gallery3DrmPresenter behavior tests — the per-pixel-engine presenter glue.
// Re-pins from the deleted record-playback core (deletion notes in
// swtcon_packer_test.cc):
//   - dry-run frame lifecycle + option surface (retired keys accepted)
//   - the presenter never self-schedules settles (SettlePlanner authority)
//   - scan always parks on the blank HOLD plane (structural, via ScanLoop +
//     PhaseEmitter and the DrmInterface mock)
//   - deterministic slot sequence (build slots rotate 0..14 in flip order)
//   - multi-inflight presents (max_inflight_updates = 0)

#include "presenter/swtcon/drm_swtcon_presenter.h"

#include <gtest/gtest.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <future>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <random>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>
#include <vector>

#include "compositor/software_compositor.h"
#include "pluto/glass_handoff.h"
#include "pluto/presenter.h"
#include "presenter/swtcon/dc_ledger.h"
#include "presenter/swtcon/drm_swtcon_device.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/xochitl_history_state.h"
#include "renderer/renderer_handoff.h"
#include "swtcon_eink_synth.h"

namespace {

#ifdef GTEST_SKIP
#define PLUTO_SKIP_EXACT_COLOR_FIXTURES()                                      \
  GTEST_SKIP() << "installed exact-color waveform/ct33 fixtures are absent"
#else
#define PLUTO_SKIP_EXACT_COLOR_FIXTURES()                                      \
  do {                                                                         \
    std::fprintf(stderr, "[  SKIPPED ] installed exact-color waveform/ct33 "   \
                         "fixtures are absent\n");                             \
    return;                                                                    \
  } while (false)
#endif

using pluto::swtcon::kDrmBufferCount;
using pluto::swtcon::kDrmHeight;
using pluto::swtcon::kDrmPhaseBytes;
using pluto::swtcon::kDrmPhaseWords;
using pluto::swtcon::kDrmWidth;
using pluto::swtcon::kLogicalFrameBytes;
using pluto::swtcon::kLogicalHeight;
using pluto::swtcon::kLogicalStrideBytes;
using pluto::swtcon::kLogicalWidth;
using pluto::swtcon::kRgb565BytesPerPixel;

bool discard_handoff_path(const std::string &path) {
  bool discarded = false;
  {
    pluto::GlassHandoffLease lease;
    if (!pluto::glass_handoff_acquire_lease(path, &lease)) {
      return false;
    }
    discarded = pluto::glass_handoff_discard(lease, path);
  }
  const std::string lease_path = path + ".lease";
  const bool lease_removed =
      std::remove(lease_path.c_str()) == 0 || errno == ENOENT;
  return discarded && lease_removed;
}

void fill_rgb565(std::vector<std::uint8_t> *frame, std::uint16_t value) {
  for (std::size_t i = 0; i < frame->size(); i += 2) {
    (*frame)[i] = static_cast<std::uint8_t>(value & 0xffU);
    (*frame)[i + 1] = static_cast<std::uint8_t>(value >> 8);
  }
}

void store_rgb565(std::vector<std::uint8_t> *frame, int x, int y,
                  std::uint16_t value) {
  const std::size_t offset = static_cast<std::size_t>(y) * kLogicalStrideBytes +
                             static_cast<std::size_t>(x) * kRgb565BytesPerPixel;
  (*frame)[offset] = static_cast<std::uint8_t>(value & 0xffU);
  (*frame)[offset + 1] = static_cast<std::uint8_t>(value >> 8);
}

TEST(Gallery3DrmPresenterTest,
     ExactColorHandoffRouteRequiresCompleteMoveIdentityAndGeometry) {
  const auto matches = [](int width, int height, int engine_stride,
                          std::uint32_t tile_px, int history_stride,
                          int history_rows, std::string_view machine,
                          std::string_view soc) {
    return pluto::swtcon::color_handoff_profile_matches_for_testing(
        width, height, engine_stride, tile_px, history_stride, history_rows,
        machine, soc);
  };

  EXPECT_TRUE(
      matches(954, 1696, 960, 32, 968, 1698, "reMarkable Chiappa", "i.MX93"));

  EXPECT_FALSE(
      matches(954, 1696, 960, 32, 968, 1698, "reMarkable Paper Pro", "i.MX93"));
  EXPECT_FALSE(
      matches(954, 1696, 960, 32, 968, 1698, "reMarkable Chiappa", "i.MX8"));

  // No single shared dimension (including both visible dimensions) is
  // enough to select the Move's fixed Xochitl storage profile.
  EXPECT_FALSE(
      matches(953, 1696, 960, 32, 968, 1698, "reMarkable Chiappa", "i.MX93"));
  EXPECT_FALSE(
      matches(954, 1697, 960, 32, 968, 1698, "reMarkable Chiappa", "i.MX93"));
  EXPECT_FALSE(
      matches(954, 1696, 959, 32, 968, 1698, "reMarkable Chiappa", "i.MX93"));
  EXPECT_FALSE(
      matches(954, 1696, 960, 16, 968, 1698, "reMarkable Chiappa", "i.MX93"));
  EXPECT_FALSE(
      matches(954, 1696, 960, 32, 967, 1698, "reMarkable Chiappa", "i.MX93"));
  EXPECT_FALSE(
      matches(954, 1696, 960, 32, 968, 1697, "reMarkable Chiappa", "i.MX93"));
}

TEST(Gallery3DrmPresenterTest,
     ProductionColorHandoffNamespaceRejectsEveryNoncanonicalPath) {
  EXPECT_FALSE(
      pluto::swtcon::production_handoff_path_is_secure_tmpfs_for_testing(""));
  EXPECT_FALSE(
      pluto::swtcon::production_handoff_path_is_secure_tmpfs_for_testing(
          "/tmp/pluto/glass.handoff"));
  EXPECT_FALSE(
      pluto::swtcon::production_handoff_path_is_secure_tmpfs_for_testing(
          "/run/pluto/glass.handoff.other"));
  EXPECT_FALSE(
      pluto::swtcon::production_handoff_path_is_secure_tmpfs_for_testing(
          "/run/pluto/../pluto/glass.handoff"));
}

TEST(Gallery3DrmPresenterTest,
     FastCoverageWordMergeMatchesScalarForUnalignedOverlaps) {
  {
    // A clipped coverage proof strictly inside execution, with a five-bit
    // origin delta, must land at execution-local x=5/11/8 rather than being
    // copied at coverage-local x=0/6/3.
    const PlutoRect coverage_rect{13, 12, 7, 2};
    const std::vector<std::uint8_t> coverage_bits{
        static_cast<std::uint8_t>((1u << 0u) | (1u << 6u)),
        static_cast<std::uint8_t>(1u << 3u)};
    const PlutoRect execution_rect{8, 10, 24, 6};
    std::vector<std::uint8_t> actual(3u * 6u, 0u);
    std::vector<std::uint8_t> expected(actual.size(), 0u);
    expected[2u * 3u] = static_cast<std::uint8_t>(1u << 5u);
    expected[2u * 3u + 1u] = static_cast<std::uint8_t>(1u << 3u);
    expected[3u * 3u + 1u] = static_cast<std::uint8_t>(1u << 0u);
    ASSERT_TRUE(pluto::swtcon::or_fast_coverage_overlap(
        coverage_rect, coverage_bits, 1u, execution_rect, actual, 3u));
    EXPECT_TRUE(actual == expected);
  }

  std::mt19937 rng(0xf45c0a11u);
  std::uniform_int_distribution<int> origin(0, 191);
  std::uniform_int_distribution<int> extent(1, 129);
  std::uniform_int_distribution<int> padding(0, 4);
  std::uniform_int_distribution<int> byte(0, 255);
  constexpr std::size_t kCanaryBytes = 16;
  constexpr std::uint8_t kCanary = 0xc7u;

  for (int iteration = 0; iteration < 500; ++iteration) {
    const PlutoRect source{origin(rng), origin(rng), extent(rng), extent(rng)};
    const PlutoRect destination{origin(rng), origin(rng), extent(rng),
                                extent(rng)};
    const std::size_t source_stride =
        (static_cast<std::size_t>(source.width) + 7u) / 8u +
        static_cast<std::size_t>(padding(rng));
    const std::size_t destination_stride =
        (static_cast<std::size_t>(destination.width) + 7u) / 8u +
        static_cast<std::size_t>(padding(rng));
    const std::size_t source_size =
        source_stride * static_cast<std::size_t>(source.height);
    const std::size_t destination_size =
        destination_stride * static_cast<std::size_t>(destination.height);
    std::vector<std::uint8_t> source_storage(source_size + 2u * kCanaryBytes,
                                             kCanary);
    std::vector<std::uint8_t> actual_storage(
        destination_size + 2u * kCanaryBytes, kCanary);
    std::span<std::uint8_t> source_bits(source_storage.data() + kCanaryBytes,
                                        source_size);
    std::span<std::uint8_t> actual(actual_storage.data() + kCanaryBytes,
                                   destination_size);
    for (std::uint8_t &value : source_bits) {
      value = static_cast<std::uint8_t>(byte(rng));
    }
    for (std::uint8_t &value : actual) {
      value = static_cast<std::uint8_t>(byte(rng));
    }
    std::vector<std::uint8_t> expected(actual.begin(), actual.end());

    for (std::int32_t destination_y = 0; destination_y < destination.height;
         ++destination_y) {
      const std::int32_t panel_y = destination.y + destination_y;
      if (panel_y < source.y || panel_y >= source.y + source.height) {
        continue;
      }
      for (std::int32_t destination_x = 0; destination_x < destination.width;
           ++destination_x) {
        const std::int32_t panel_x = destination.x + destination_x;
        if (panel_x < source.x || panel_x >= source.x + source.width) {
          continue;
        }
        const std::size_t source_x =
            static_cast<std::size_t>(panel_x - source.x);
        const std::size_t source_byte =
            static_cast<std::size_t>(panel_y - source.y) * source_stride +
            source_x / 8u;
        if ((source_bits[source_byte] &
             static_cast<std::uint8_t>(1u << (source_x & 7u))) == 0) {
          continue;
        }
        const std::size_t destination_byte =
            static_cast<std::size_t>(destination_y) * destination_stride +
            static_cast<std::size_t>(destination_x) / 8u;
        expected[destination_byte] = static_cast<std::uint8_t>(
            expected[destination_byte] |
            static_cast<std::uint8_t>(
                1u << (static_cast<unsigned>(destination_x) & 7u)));
      }
    }

    ASSERT_TRUE(pluto::swtcon::or_fast_coverage_overlap(
        source, source_bits, source_stride, destination, actual,
        destination_stride));
    EXPECT_TRUE(std::equal(actual.begin(), actual.end(), expected.begin()))
        << "random overlap iteration " << iteration;
    EXPECT_TRUE(std::all_of(
        actual_storage.begin(), actual_storage.begin() + kCanaryBytes,
        [](std::uint8_t value) { return value == kCanary; }));
    EXPECT_TRUE(
        std::all_of(actual_storage.end() - kCanaryBytes, actual_storage.end(),
                    [](std::uint8_t value) { return value == kCanary; }));
    EXPECT_TRUE(std::all_of(
        source_storage.begin(), source_storage.begin() + kCanaryBytes,
        [](std::uint8_t value) { return value == kCanary; }));
    EXPECT_TRUE(
        std::all_of(source_storage.end() - kCanaryBytes, source_storage.end(),
                    [](std::uint8_t value) { return value == kCanary; }));
  }

  std::vector<std::uint8_t> too_small(1, 0xffu);
  std::vector<std::uint8_t> destination(2, 0u);
  EXPECT_FALSE(pluto::swtcon::or_fast_coverage_overlap(
      PlutoRect{0, 0, 16, 2}, too_small, 2, PlutoRect{0, 0, 8, 2}, destination,
      1));
}

// Writes the shared synthetic 3-mode .eink (mode 2 = the GC16/Full index,
// `phases` phases; modes 0/1 = 1-phase all-hold) to a temp file the
// presenter's real file reader can load.
std::string write_synth_eink(int phases, const char *tag) {
  static int counter = 0;
  const std::string path = "/tmp/pluto_swtcon_presenter_" +
                           std::to_string(::getpid()) + "_" + tag + "_" +
                           std::to_string(++counter) + ".eink";
  const std::vector<std::uint8_t> file =
      swtcon_synth::make_synthetic_eink(phases);
  std::ofstream out(path, std::ios::binary);
  EXPECT_TRUE(out.good());
  out.write(reinterpret_cast<const char *>(file.data()),
            static_cast<std::streamsize>(file.size()));
  return path;
}

std::string installed_color_options(bool include_all_blobs = true,
                                    bool exact_color = true,
                                    bool dry_run = true) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  std::string options = dry_run ? "dry_run=1," : "";
  options += "flip_interval_ms=0,stats_log_s=0,handoff=0,";
  if (exact_color) {
    options += "exact_color=1,";
  }
  options += "eink=" + eink.string();
  options += ",ct33_std=" + (directory / "ct33_std.bin").string();
  options += ",ct33_best=" + (directory / "ct33_best.bin").string();
  options += ",ct33_fast=" + (directory / "ct33_fast.bin").string();
  options +=
      ",ct33_pen=" + (include_all_blobs ? (directory / "ct33_pen.bin").string()
                                        : "/missing/ct33_pen.bin");
  return options;
}

struct CallbackLog {
  std::atomic<int> calls{0};
  std::atomic<std::uint64_t> last_frame_id{0};
  mutable std::mutex mutex;
  std::vector<std::uint64_t> frame_ids;

  std::vector<std::uint64_t> snapshot() const {
    std::lock_guard<std::mutex> lock(mutex);
    return frame_ids;
  }
};

struct BlockingCallback {
  std::mutex mutex;
  std::condition_variable cv;
  bool entered = false;
  bool release = false;
  bool returned = false;
  std::uint64_t frame_id = 0;

  static void invoke(std::uint64_t id, void *user_data) {
    auto *self = static_cast<BlockingCallback *>(user_data);
    std::unique_lock<std::mutex> lock(self->mutex);
    self->entered = true;
    self->frame_id = id;
    self->cv.notify_all();
    self->cv.wait(lock, [self] { return self->release; });
    self->returned = true;
    self->cv.notify_all();
  }

  bool wait_until_entered(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex);
    return cv.wait_for(lock, timeout, [this] { return entered; });
  }

  void unblock() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      release = true;
    }
    cv.notify_all();
  }

  bool wait_until_returned(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex);
    return cv.wait_for(lock, timeout, [this] { return returned; });
  }
};

// Presenter harness: opens "gallery3_drm" through the registry with the given
// options; present() retries kPlutoStatusAgain (the cold-clear gate)
// with a deadline.
class Presenter {
public:
  explicit Presenter(const std::string &options,
                     PlutoPresentCompleteCallback callback = nullptr,
                     void *callback_user_data = nullptr,
                     bool install_default_callback = true)
      : options_(options) {
    ops_ = pluto_gallery3_drm_presenter_ops();
    EXPECT_TRUE(ops_ != nullptr);
    PlutoPresenterConfig config{};
    config.struct_size = sizeof(config);
    config.backend_name = "gallery3_drm";
    config.options = options_.c_str();
    if (callback != nullptr) {
      config.on_complete = callback;
      config.user_data = callback_user_data;
    } else if (install_default_callback) {
      config.on_complete = [](std::uint64_t frame_id, void *user_data) {
        auto *log = static_cast<CallbackLog *>(user_data);
        {
          std::lock_guard<std::mutex> lock(log->mutex);
          log->frame_ids.push_back(frame_id);
        }
        log->last_frame_id.store(frame_id, std::memory_order_release);
        log->calls.fetch_add(1, std::memory_order_acq_rel);
      };
      config.user_data = &log_;
    }
    open_status_ = ops_->open(&config, &presenter_);
    frame_.assign(kLogicalFrameBytes, 0);
    fill_rgb565(&frame_, 0xffff);
  }

  ~Presenter() { close_now(); }

  PlutoStatus open_status() const { return open_status_; }
  const PlutoPresenterOps *ops() const { return ops_; }
  PlutoPresenter *raw() { return presenter_; }
  std::vector<std::uint8_t> *frame() { return &frame_; }
  const CallbackLog &log() const { return log_; }

  PlutoStatus stage_handoff(std::span<const std::uint8_t> renderer_payload =
                                std::span<const std::uint8_t>(),
                            std::uint32_t timeout_ms = 30000) {
    static constexpr std::array<std::uint8_t, 8> kDefaultPayload{
        'R', 'E', 'N', 'D', 'E', 'R', '2', 0};
    if (renderer_payload.empty()) {
      renderer_payload = kDefaultPayload;
    }
    PlutoHandoffPayload payload{};
    payload.struct_size = sizeof(payload);
    payload.bytes = renderer_payload.data();
    payload.byte_count = renderer_payload.size();
    payload.width = kLogicalWidth;
    payload.height = kLogicalHeight;
    payload.rotation = 0;
    payload.pixel_format = kPlutoPixelFormatRgb565;
    payload.configuration_hash = 0x123456789abcdef0ull;
    return ops_->stage_handoff(presenter_, &payload, timeout_ms);
  }

  PlutoStatus confirm_incoming_handoff(bool accepted = true) {
    PlutoHandoffPayload payload{};
    payload.struct_size = sizeof(payload);
    const PlutoStatus get_status = ops_->get_handoff(presenter_, &payload);
    if (get_status != kPlutoStatusOk) {
      return get_status;
    }
    EXPECT_TRUE(payload.bytes != nullptr);
    EXPECT_GT(payload.byte_count, 0u);
    EXPECT_EQ(payload.width, kLogicalWidth);
    EXPECT_EQ(payload.height, kLogicalHeight);
    return ops_->confirm_handoff(presenter_, accepted);
  }

  void close_now() {
    if (presenter_ != nullptr) {
      ops_->close(presenter_);
      presenter_ = nullptr;
    }
  }

  PlutoStatus present_once(PlutoRefreshClass refresh_class,
                           const PlutoRect &damage, std::uint64_t frame_id,
                           std::uint32_t flags = 0) {
    return present_many_once(
        refresh_class, std::span<const PlutoRect>(&damage, 1), frame_id, flags);
  }

  PlutoStatus present_many_once(PlutoRefreshClass refresh_class,
                                std::span<const PlutoRect> damage,
                                std::uint64_t frame_id,
                                std::uint32_t flags = 0) {
    PlutoPresentRequest request{};
    request.struct_size = sizeof(request);
    request.surface.pixels = frame_.data();
    request.surface.stride_bytes = kLogicalStrideBytes;
    request.surface.width = kLogicalWidth;
    request.surface.height = kLogicalHeight;
    request.surface.format = kPlutoPixelFormatRgb565;
    request.damage = damage.data();
    request.damage_count = damage.size();
    request.refresh_class = refresh_class;
    request.flags = flags;
    request.frame_id = frame_id;
    return ops_->present(presenter_, &request);
  }

  void present_many(PlutoRefreshClass refresh_class,
                    std::span<const PlutoRect> damage, std::uint64_t frame_id,
                    std::uint32_t flags = 0) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    PlutoStatus status = kPlutoStatusAgain;
    while (std::chrono::steady_clock::now() < deadline) {
      status = present_many_once(refresh_class, damage, frame_id, flags);
      if (status != kPlutoStatusAgain) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_EQ(status, kPlutoStatusOk);
    ASSERT_EQ(ops_->wait_idle(presenter_, 30000), kPlutoStatusOk);
  }

  // present() with Again retries: the cold clear gates every class until
  // it completes.
  void present(PlutoRefreshClass refresh_class, const PlutoRect &damage,
               std::uint64_t frame_id, std::uint32_t flags = 0) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    PlutoStatus status = kPlutoStatusAgain;
    while (std::chrono::steady_clock::now() < deadline) {
      status = present_once(refresh_class, damage, frame_id, flags);
      if (status != kPlutoStatusAgain) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_EQ(status, kPlutoStatusOk);
    ASSERT_EQ(ops_->wait_idle(presenter_, 30000), kPlutoStatusOk);
  }

  PlutoGallery3DrmDebugStats stats() const {
    PlutoGallery3DrmDebugStats out{};
    out.struct_size = sizeof(out);
    EXPECT_EQ(pluto_gallery3_drm_presenter_debug_stats(presenter_, &out),
              kPlutoStatusOk);
    return out;
  }

  static constexpr PlutoRect kFullScreen{0, 0, kLogicalWidth, kLogicalHeight};

private:
  const PlutoPresenterOps *ops_ = nullptr;
  PlutoPresenter *presenter_ = nullptr;
  PlutoStatus open_status_ = kPlutoStatusInternal;
  CallbackLog log_;
  std::string options_;
  std::vector<std::uint8_t> frame_;
};

// True process-boundary exact-color handoff oracle. The child processes below
// open their own presenter, engine, color workers, renderer, and scheduler;
// the only state crossing the boundary is the production bundle path.
struct ExactColorCompletionBridge {
  std::atomic<pluto::FrameRenderer *> renderer{nullptr};
  std::atomic<std::uint64_t> calls{0};

  static void complete(std::uint64_t frame_id, void *user_data) {
    auto *self = static_cast<ExactColorCompletionBridge *>(user_data);
    if (pluto::FrameRenderer *renderer =
            self->renderer.load(std::memory_order_acquire);
        renderer != nullptr) {
      renderer->notify_present_complete(frame_id);
    }
    self->calls.fetch_add(1, std::memory_order_acq_rel);
  }
};

struct ExactColorPolicyClock {
  std::atomic<std::uint64_t> now_us{0};

  static std::uint64_t read(void *context) {
    return static_cast<ExactColorPolicyClock *>(context)->now_us.load(
        std::memory_order_acquire);
  }
};

struct ExactColorHistoryPair {
  std::int32_t x0 = -1;
  std::int32_t y0 = -1;
  std::int32_t x1 = -1;
  std::int32_t y1 = -1;
  std::uint16_t a0 = 0;
  std::uint16_t b0 = 0;
  std::uint16_t a1 = 0;
  std::uint16_t b1 = 0;
};

constexpr std::array<PlutoRect, 5> kExactColorOutcomeProbes{{
    {64, 64, 1, 1},
    {160, 64, 1, 1},
    {64, 192, 1, 1},
    {160, 192, 1, 1},
    {320, 320, 1, 1},
}};
constexpr PlutoRect kExactColorFastHistory{64, 64, 32, 32};
constexpr PlutoRect kExactColorDevelopedHistory{160, 64, 32, 32};
constexpr PlutoRect kExactColorHistoryProbeA{168, 64, 1, 1};
constexpr PlutoRect kExactColorHistoryProbeB{171, 71, 1, 1};

struct ExactColorProcessOutcome {
  static constexpr std::uint32_t kMagic = 0x43505832u; // "2XPC"

  std::uint32_t magic = kMagic;
  std::int32_t cold_clear_mode = -99;
  std::uint64_t color_faults = UINT64_MAX;
  std::uint64_t resume_damage_count = 0;
  std::uint64_t resume_glass_hash = 0;
  std::uint64_t resume_dc_hash = 0;
  std::uint64_t resume_stress_hash = 0;
  std::array<std::uint16_t, kExactColorOutcomeProbes.size()> resume_a{};
  std::array<std::uint16_t, kExactColorOutcomeProbes.size()> resume_b{};
  std::uint16_t imported_a0 = 0;
  std::uint16_t imported_b0 = 0;
  std::uint16_t imported_a1 = 0;
  std::uint16_t imported_b1 = 0;
  std::uint16_t imported_guard_a = 0;
  std::uint16_t imported_guard_b = 0;
  std::uint8_t reset_rejected_before_resume = 0;
  std::uint8_t seed_present_before_resume = 0;
  std::uint8_t seed_unlinked_on_first_admission = 0;
  std::uint8_t bundle_written = 0;
};

struct RawExactColorBundle {
  std::vector<std::uint8_t> bytes;
  std::map<std::uint32_t, std::pair<std::uint64_t, std::uint64_t>> sections;
  std::uint64_t renderer_configuration_hash = 0;

  std::span<const std::uint8_t> section(pluto::GlassHandoffSection type) const {
    const auto found = sections.find(static_cast<std::uint32_t>(type));
    if (found == sections.end()) {
      return {};
    }
    return std::span<const std::uint8_t>(
        bytes.data() + static_cast<std::size_t>(found->second.first),
        static_cast<std::size_t>(found->second.second));
  }
};

std::uint32_t exact_read_u32(std::span<const std::uint8_t> bytes,
                             std::size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < 4u) {
    return 0;
  }
  return static_cast<std::uint32_t>(bytes[offset]) |
         (static_cast<std::uint32_t>(bytes[offset + 1u]) << 8u) |
         (static_cast<std::uint32_t>(bytes[offset + 2u]) << 16u) |
         (static_cast<std::uint32_t>(bytes[offset + 3u]) << 24u);
}

std::uint64_t exact_read_u64(std::span<const std::uint8_t> bytes,
                             std::size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < 8u) {
    return 0;
  }
  std::uint64_t value = 0;
  for (unsigned byte = 0; byte < 8u; ++byte) {
    value |= static_cast<std::uint64_t>(bytes[offset + byte]) << (byte * 8u);
  }
  return value;
}

bool load_raw_exact_color_bundle(const std::string &path,
                                 RawExactColorBundle *out) {
  if (out == nullptr) {
    return false;
  }
  std::ifstream input(path, std::ios::binary);
  RawExactColorBundle parsed;
  parsed.bytes.assign(std::istreambuf_iterator<char>(input),
                      std::istreambuf_iterator<char>());
  if (!input.is_open() || input.bad() || parsed.bytes.size() < 192u ||
      exact_read_u32(parsed.bytes, 0) != pluto::kGlassHandoffMagic ||
      exact_read_u32(parsed.bytes, 4) != pluto::kGlassHandoffVersion) {
    return false;
  }
  const std::uint32_t header_bytes = exact_read_u32(parsed.bytes, 8);
  const std::uint32_t section_count = exact_read_u32(parsed.bytes, 24);
  if (header_bytes != 192u + static_cast<std::uint64_t>(section_count) * 32u ||
      header_bytes > parsed.bytes.size()) {
    return false;
  }
  parsed.renderer_configuration_hash = exact_read_u64(parsed.bytes, 160);
  std::uint64_t expected_offset = header_bytes;
  for (std::uint32_t index = 0; index < section_count; ++index) {
    const std::size_t entry = 192u + static_cast<std::size_t>(index) * 32u;
    const std::uint32_t type = exact_read_u32(parsed.bytes, entry);
    const std::uint64_t offset = exact_read_u64(parsed.bytes, entry + 8u);
    const std::uint64_t size = exact_read_u64(parsed.bytes, entry + 16u);
    if (offset != expected_offset || offset > parsed.bytes.size() ||
        size > parsed.bytes.size() - offset ||
        !parsed.sections.emplace(type, std::pair{offset, size}).second) {
      return false;
    }
    expected_offset += size;
  }
  if (expected_offset != parsed.bytes.size()) {
    return false;
  }
  *out = std::move(parsed);
  return true;
}

bool read_exact_color_history_pair(std::span<const std::uint8_t> history,
                                   PlutoRect first, PlutoRect second,
                                   ExactColorHistoryPair *out) {
  constexpr std::size_t kPixelBytes = 4u;
  constexpr std::size_t kExpectedBytes =
      pluto::swtcon::XochitlHistoryState::kStoragePixels * kPixelBytes;
  if (out == nullptr || history.size() != kExpectedBytes || first.x < 0 ||
      first.y < 0 || first.x >= kLogicalWidth || first.y >= kLogicalHeight ||
      second.x < 0 || second.y < 0 || second.x >= kLogicalWidth ||
      second.y >= kLogicalHeight) {
    return false;
  }
  const auto read = [&](PlutoRect rect) {
    const std::size_t pixel =
        static_cast<std::size_t>(rect.y) *
            pluto::swtcon::XochitlHistoryState::kStorageStride +
        static_cast<std::size_t>(rect.x);
    return std::pair{
        static_cast<std::uint16_t>(
            history[pixel * kPixelBytes] |
            static_cast<std::uint16_t>(history[pixel * kPixelBytes + 1u])
                << 8u),
        static_cast<std::uint16_t>(
            history[pixel * kPixelBytes + 2u] |
            static_cast<std::uint16_t>(history[pixel * kPixelBytes + 3u])
                << 8u)};
  };
  const auto [a0, b0] = read(first);
  const auto [a1, b1] = read(second);
  *out = ExactColorHistoryPair{first.x, first.y, second.x, second.y,
                               a0,      b0,      a1,       b1};
  return true;
}

template <typename T>
std::uint64_t hash_exact_values(std::span<const T> values,
                                std::uint64_t seed = 1469598103934665603ull) {
  std::uint64_t hash = seed;
  for (const T value : values) {
    using Unsigned = std::make_unsigned_t<T>;
    const Unsigned raw = static_cast<Unsigned>(value);
    for (unsigned byte = 0; byte < sizeof(T); ++byte) {
      hash ^= static_cast<std::uint8_t>(raw >> (byte * 8u));
      hash *= 1099511628211ull;
    }
  }
  return hash;
}

bool write_exact_color_outcome(const std::string &path,
                               const ExactColorProcessOutcome &outcome) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(reinterpret_cast<const char *>(&outcome), sizeof(outcome));
  return output.good();
}

bool read_exact_color_outcome(const std::string &path,
                              ExactColorProcessOutcome *outcome) {
  if (outcome == nullptr) {
    return false;
  }
  std::ifstream input(path, std::ios::binary);
  input.read(reinterpret_cast<char *>(outcome), sizeof(*outcome));
  return input.good() && input.peek() == std::char_traits<char>::eof() &&
         outcome->magic == ExactColorProcessOutcome::kMagic;
}

std::string installed_color_handoff_options(const std::string &path,
                                            bool dry_run = true) {
  std::string options = installed_color_options(
      /*include_all_blobs=*/true, /*exact_color=*/true, dry_run);
  constexpr std::string_view kDisabled = "handoff=0";
  const std::size_t marker = options.find(kDisabled);
  if (marker == std::string::npos) {
    return {};
  }
  options.replace(marker, kDisabled.size(), "handoff=" + path);
  return options;
}

void fill_exact_rect(std::vector<std::uint16_t> *frame, PlutoRect rect,
                     std::uint16_t color) {
  for (std::int32_t y = rect.y; y < rect.y + rect.height; ++y) {
    for (std::int32_t x = rect.x; x < rect.x + rect.width; ++x) {
      (*frame)[static_cast<std::size_t>(y) * kLogicalWidth +
               static_cast<std::size_t>(x)] = color;
    }
  }
}

void fill_exact_history_palette(std::vector<std::uint16_t> *frame,
                                PlutoRect rect) {
  std::uint32_t state = 0x6d2b79f5u;
  for (std::int32_t y = rect.y; y < rect.y + rect.height; ++y) {
    for (std::int32_t x = rect.x; x < rect.x + rect.width; ++x) {
      state = state * 1664525u + 1013904223u;
      (*frame)[static_cast<std::size_t>(y) * kLogicalWidth +
               static_cast<std::size_t>(x)] =
          static_cast<std::uint16_t>(state >> 16u);
    }
  }
}

pluto::PlutoFramePacket
exact_color_packet(const std::vector<std::uint16_t> &frame,
                   std::span<const PlutoRect> paint_bounds,
                   std::uint64_t sequence) {
  pluto::PlutoFramePacket packet{};
  packet.pixels = frame.data();
  packet.row_bytes = static_cast<std::size_t>(kLogicalWidth) * sizeof(uint16_t);
  packet.width = kLogicalWidth;
  packet.height = kLogicalHeight;
  packet.format = kPlutoPixelFormatRgb565;
  packet.did_update = true;
  packet.presentation_time_ns = sequence * 1'000'000u;
  packet.paint_bounds = paint_bounds.data();
  packet.paint_bounds_count = paint_bounds.size();
  return packet;
}

bool exact_presenter_ready(Presenter *presenter) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (std::chrono::steady_clock::now() < deadline) {
    if (presenter->ops()->ready(presenter->raw(), kPlutoRefreshUi)) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return false;
}

bool submit_exact_color_frame(Presenter *presenter,
                              pluto::FrameRenderer *renderer,
                              ExactColorCompletionBridge *bridge,
                              const std::vector<std::uint16_t> &frame,
                              std::span<const PlutoRect> paint_bounds,
                              std::uint64_t sequence) {
  const std::uint64_t calls_before =
      bridge->calls.load(std::memory_order_acquire);
  if (!renderer->submit_frame(
          exact_color_packet(frame, paint_bounds, sequence))) {
    return false;
  }
  const bool expects_present = renderer->last_damage_count() != 0u;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  if (expects_present) {
    while (bridge->calls.load(std::memory_order_acquire) == calls_before &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (bridge->calls.load(std::memory_order_acquire) == calls_before) {
      return false;
    }
  }

  // A renderer frame may split into several scheduler regions. Require three
  // quiet presenter-loop windows after both the optical fence and completion
  // mailbox drain, so a transient idle gap cannot be mistaken for quiescence.
  int quiet_windows = 0;
  std::uint64_t previous_calls = UINT64_MAX;
  while (std::chrono::steady_clock::now() < deadline && quiet_windows < 3) {
    if (presenter->ops()->wait_idle(presenter->raw(), 5000) != kPlutoStatusOk) {
      return false;
    }
    const auto drain_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (renderer->queued_present_completions_for_testing() != 0u &&
           std::chrono::steady_clock::now() < drain_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const std::uint64_t current_calls =
        bridge->calls.load(std::memory_order_acquire);
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    const bool quiet =
        current_calls == previous_calls &&
        current_calls == bridge->calls.load(std::memory_order_acquire) &&
        renderer->queued_present_completions_for_testing() == 0u &&
        presenter->ops()->wait_idle(presenter->raw(), 0) == kPlutoStatusOk;
    quiet_windows = quiet ? quiet_windows + 1 : 0;
    previous_calls = current_calls;
  }
  return quiet_windows == 3;
}

enum class ExactColorProcessMode {
  kOutgoing,
  kIncoming,
  kUninterruptedOracle,
};

bool capture_exact_color_outcome(Presenter *presenter,
                                 pluto::FrameRenderer *renderer,
                                 ExactColorProcessOutcome *outcome) {
  std::vector<std::uint8_t> glass;
  int width = 0;
  int height = 0;
  int stride = 0;
  std::vector<std::int32_t> dc;
  std::vector<std::uint16_t> stress;
  std::uint32_t tile_cols = 0;
  if (!pluto::swtcon::debug_glass_for_testing(presenter->raw(), &glass, &width,
                                              &height, &stride) ||
      width != kLogicalWidth || height != kLogicalHeight ||
      !pluto::swtcon::debug_dc_for_testing(presenter->raw(), &dc, &stress,
                                           &tile_cols) ||
      tile_cols == 0u) {
    return false;
  }
  outcome->resume_damage_count = renderer->last_damage_count();
  outcome->resume_glass_hash = hash_exact_values<std::uint8_t>(glass);
  outcome->resume_dc_hash = hash_exact_values<std::int32_t>(dc);
  outcome->resume_stress_hash = hash_exact_values<std::uint16_t>(stress);
  for (std::size_t index = 0; index < kExactColorOutcomeProbes.size();
       ++index) {
    const PlutoRect probe = kExactColorOutcomeProbes[index];
    if (!pluto::swtcon::debug_color_history_for_testing(
            presenter->raw(), probe.x, probe.y, &outcome->resume_a[index],
            &outcome->resume_b[index])) {
      return false;
    }
  }
  return true;
}

bool run_exact_color_process(ExactColorProcessMode mode,
                             const std::string &handoff_path,
                             const std::string &outcome_path,
                             const ExactColorHistoryPair &import_pair = {}) {
  const std::string options = installed_color_handoff_options(handoff_path);
  if (options.empty()) {
    return false;
  }
  ExactColorCompletionBridge bridge;
  ExactColorPolicyClock clock;
  constexpr std::uint64_t kOutgoingClockBaseUs = 1'000'000u;
  constexpr std::uint64_t kSuccessorClockBaseUs = 1'100'000u;
  std::uint64_t clock_base_us = mode == ExactColorProcessMode::kIncoming
                                    ? kSuccessorClockBaseUs
                                    : kOutgoingClockBaseUs;
  clock.now_us.store(clock_base_us, std::memory_order_release);
  Presenter presenter(options, ExactColorCompletionBridge::complete, &bridge);
  if (presenter.open_status() != kPlutoStatusOk) {
    return false;
  }
  pluto::FrameRendererConfig config{};
  config.width = kLogicalWidth;
  config.height = kLogicalHeight;
  config.format = kPlutoPixelFormatRgb565;
  config.presenter_ops = presenter.ops();
  config.presenter = presenter.raw();
  config.start_presenter_thread = true;
  config.enable_auto_ghostbuster = true;
  config.monotonic_now_for_testing = ExactColorPolicyClock::read;
  config.monotonic_now_context_for_testing = &clock;
  auto renderer = std::make_unique<pluto::FrameRenderer>(config);
  bridge.renderer.store(renderer.get(), std::memory_order_release);
  if (!renderer->valid() || !exact_presenter_ready(&presenter)) {
    return false;
  }
  // Keep the test deterministic while still exercising a real, enabled
  // automatic-debt ledger. The supervisor gate is deliberately not serialized;
  // each process owns this disabled test gate independently.
  renderer->set_auto_maintenance_allowed(false);

  ExactColorProcessOutcome outcome;
  PlutoGallery3DrmDebugStats stats{};
  stats.struct_size = sizeof(stats);
  if (pluto_gallery3_drm_presenter_debug_stats(presenter.raw(), &stats) !=
      kPlutoStatusOk) {
    return false;
  }
  outcome.cold_clear_mode = stats.cold_clear_mode;

  std::vector<std::uint16_t> frame(
      static_cast<std::size_t>(kLogicalWidth) * kLogicalHeight, 0xffffu);
  constexpr PlutoRect kSameLuma{64, 192, 32, 32};
  constexpr PlutoRect kChroma{160, 192, 48, 32};
  constexpr PlutoRect kOrdinary{320, 320, 48, 32};
  constexpr std::uint16_t kHueA = 0x023bu;
  constexpr std::uint16_t kHueB = 0x88dfu;

  std::uint64_t sequence = 1;
  const auto submit = [&](std::span<const PlutoRect> bounds) {
    clock.now_us.store(clock_base_us + sequence * 1'000u,
                       std::memory_order_release);
    return submit_exact_color_frame(&presenter, renderer.get(), &bridge, frame,
                                    bounds, sequence++);
  };
  const auto update = [&](PlutoRect rect, std::uint16_t color) {
    fill_exact_rect(&frame, rect, color);
    return submit(std::span<const PlutoRect>(&rect, 1));
  };

  if (mode != ExactColorProcessMode::kIncoming) {
    if (!submit(std::span<const PlutoRect>(&Presenter::kFullScreen, 1)) ||
        !update(kExactColorFastHistory, 0x0000u) ||
        !update(kExactColorFastHistory, 0xffffu)) {
      return false;
    }
    fill_exact_history_palette(&frame, kExactColorDevelopedHistory);
    if (!submit(std::span<const PlutoRect>(&kExactColorDevelopedHistory, 1)) ||
        !update(kSameLuma, kHueA) || !update(kChroma, 0x07e0u)) {
      return false;
    }
  } else {
    if (import_pair.x0 < 0 || import_pair.x1 < 0 ||
        !pluto::swtcon::debug_color_history_for_testing(
            presenter.raw(), import_pair.x0, import_pair.y0,
            &outcome.imported_a0, &outcome.imported_b0) ||
        !pluto::swtcon::debug_color_history_for_testing(
            presenter.raw(), import_pair.x1, import_pair.y1,
            &outcome.imported_a1, &outcome.imported_b1) ||
        !pluto::swtcon::debug_color_history_for_testing(
            presenter.raw(), kLogicalWidth, 0, &outcome.imported_guard_a,
            &outcome.imported_guard_b)) {
      return false;
    }
    outcome.reset_rejected_before_resume = !renderer->request_pixel_reset();
    outcome.seed_present_before_resume = std::filesystem::exists(handoff_path);
    // Reconstruct the outgoing app surface. The imported renderer mirror is
    // the exact physical baseline, while this vector represents the first
    // newly rastered frame from the incoming warm app.
    fill_exact_rect(&frame, kExactColorFastHistory, 0xffffu);
    fill_exact_history_palette(&frame, kExactColorDevelopedHistory);
    fill_exact_rect(&frame, kSameLuma, kHueA);
    fill_exact_rect(&frame, kChroma, 0x07e0u);
  }

  if (mode != ExactColorProcessMode::kOutgoing) {
    if (mode == ExactColorProcessMode::kUninterruptedOracle) {
      // Match the new process's successor timing and frame timestamp without
      // closing, serializing, or importing any state. This is the independent
      // live-state oracle for the handoff round trip below.
      clock_base_us = kSuccessorClockBaseUs;
      sequence = 1;
    }
    fill_exact_rect(&frame, kSameLuma, kHueB);
    fill_exact_rect(&frame, kChroma, 0x07ffu);
    if (mode == ExactColorProcessMode::kIncoming) {
      // Flutter paint bounds are app-local and can be misleading on warm
      // resume. The seeded renderer must compare the complete first frame,
      // discovering both regional RGB/chroma changes from one 1x1 hint.
      constexpr PlutoRect kMisleading{64, 192, 1, 1};
      if (!submit(std::span<const PlutoRect>(&kMisleading, 1))) {
        return false;
      }
      outcome.seed_unlinked_on_first_admission =
          !std::filesystem::exists(handoff_path);
    } else {
      constexpr std::array<PlutoRect, 2> kExactBounds{kSameLuma, kChroma};
      if (!submit(kExactBounds)) {
        return false;
      }
    }
    if (!capture_exact_color_outcome(&presenter, renderer.get(), &outcome)) {
      return false;
    }
    fill_exact_rect(&frame, kOrdinary, 0xf81fu);
    if (!submit(std::span<const PlutoRect>(&kOrdinary, 1))) {
      return false;
    }
  }

  stats = {};
  stats.struct_size = sizeof(stats);
  if (pluto_gallery3_drm_presenter_debug_stats(presenter.raw(), &stats) !=
      kPlutoStatusOk) {
    return false;
  }
  outcome.cold_clear_mode = stats.cold_clear_mode;
  outcome.color_faults = stats.color_faults;
  if (!renderer->detach_presenter(30000)) {
    return false;
  }
  bridge.renderer.store(nullptr, std::memory_order_release);
  renderer.reset();
  presenter.close_now();
  outcome.bundle_written = std::filesystem::exists(handoff_path);
  return write_exact_color_outcome(outcome_path, outcome);
}

template <typename Child> bool run_exact_color_child(Child child) {
  const pid_t pid = ::fork();
  if (pid < 0) {
    return false;
  }
  if (pid == 0) {
    const bool ok = child();
    std::fflush(nullptr);
    ::_exit(ok ? 0 : 1);
  }
  int status = 0;
  while (::waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      return false;
    }
  }
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

} // namespace

// Re-pin: dry-run frame lifecycle through the engine path. Retired option
// keys (settle_delay_ms + the emergency-DU surface) stay in the option
// string on purpose: they must parse as accepted-and-ignored. NOTE the old
// no-eink lifecycle variant is deleted: the engine drives exclusively from
// a decoded .eink.
TEST(Gallery3DrmPresenterTest, DryRunLifecycleCompletesFramesAndSnapshots) {
  const std::string eink = write_synth_eink(3, "lifecycle");
  Presenter p("dry_run=1,flip_interval_ms=0,settle_delay_ms=0,du_frames=5," +
              std::string("dither=1,eink=") + eink);
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);

  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  ASSERT_EQ(p.ops()->info(p.raw(), &info), kPlutoStatusOk);
  // Multi-inflight for real: the engine admits every scan frame; the only
  // backpressure is mailbox-full.
  EXPECT_EQ(info.max_inflight_updates, 0);
  EXPECT_TRUE(info.reports_completion);

  // Frame 42: full-screen Ui (large-admission lane, band-amortized).
  fill_rgb565(p.frame(), 0x0000);
  p.present(kPlutoRefreshUi, Presenter::kFullScreen, 42);
  EXPECT_EQ(p.log().last_frame_id.load(std::memory_order_acquire), 42u);

  // Frame 43: explicit Full-class quality pass (mid grays).
  fill_rgb565(p.frame(), 0x8410);
  p.present(kPlutoRefreshFull, Presenter::kFullScreen, 43);
  EXPECT_EQ(p.log().last_frame_id.load(std::memory_order_acquire), 43u);
  EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 2);

  PlutoGallery3DrmDebugStats stats = p.stats();
  EXPECT_EQ(stats.updates_completed, 2u);
  EXPECT_EQ(stats.full_updates, 1u);
  // Both frames fell back to mode 2 (the synthetic table lacks mode 7), a
  // GC16-family balanced mode.
  EXPECT_EQ(stats.gc16_updates, 2u);
  EXPECT_EQ(stats.settle_updates, 0u);
  EXPECT_GT(stats.admissions, 0u);
  EXPECT_NE(stats.cold_clear_mode, 0);

  // Snapshot mirrors the last presented content.
  std::vector<std::uint8_t> snapshot(kLogicalFrameBytes);
  PlutoSurface out{};
  out.pixels = snapshot.data();
  out.stride_bytes = kLogicalStrideBytes;
  out.width = kLogicalWidth;
  out.height = kLogicalHeight;
  out.format = kPlutoPixelFormatRgb565;
  EXPECT_EQ(p.ops()->snapshot(p.raw(), &out), kPlutoStatusOk);
  EXPECT_EQ(std::memcmp(snapshot.data(), p.frame()->data(), snapshot.size()),
            0);

  std::remove(eink.c_str());
}

TEST(Gallery3DrmPresenterTest,
     ExactColorCapabilityIsFailClosedAndMappedDryRunCompletes) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    PLUTO_SKIP_EXACT_COLOR_FIXTURES();
  }

  {
    Presenter default_off(installed_color_options(
        /*include_all_blobs=*/true, /*exact_color=*/false));
    ASSERT_EQ(default_off.open_status(), kPlutoStatusOk);
    PlutoDisplayInfo info{};
    info.struct_size = sizeof(info);
    ASSERT_EQ(default_off.ops()->info(default_off.raw(), &info),
              kPlutoStatusOk);
    EXPECT_FALSE(info.is_color);
    EXPECT_FALSE(info.backend_quantizes_color);
    EXPECT_FALSE(info.supports_overlap_supersession);
  }
  {
    Presenter requested_but_incomplete(
        installed_color_options(/*include_all_blobs=*/false));
    EXPECT_EQ(requested_but_incomplete.open_status(),
              kPlutoStatusInvalidArgument);
  }

  Presenter p(installed_color_options());
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  ASSERT_EQ(p.ops()->info(p.raw(), &info), kPlutoStatusOk);
  EXPECT_TRUE(info.is_color);
  EXPECT_TRUE(info.backend_quantizes_color);
  EXPECT_FALSE(info.supports_overlap_supersession);

  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
  EXPECT_EQ(p.stats().cold_clear_mode, 2);
  std::vector<std::uint8_t> glass;
  int width = 0;
  int height = 0;
  int stride = 0;
  ASSERT_TRUE(pluto::swtcon::debug_glass_for_testing(p.raw(), &glass, &width,
                                                     &height, &stride));
  ASSERT_EQ(width, kLogicalWidth);
  ASSERT_EQ(height, kLogicalHeight);
  ASSERT_TRUE(!glass.empty());
  EXPECT_EQ(glass[0], 30u);

  // Exact Fast is the ordinary safe mode-7 island. It only completes at the
  // dry-run virtual scan boundary, then masked-seeds A=2/28,B=0. A stationary
  // hover-style repeat is a true no-op, and two overlapping frames accepted
  // before completion retarget to the newest payload without losing either
  // callback.
  const PlutoRect fast_rect{32, 48, 32, 32};
  fill_rgb565(p.frame(), 0x0000);
  p.present(kPlutoRefreshFast, fast_rect, 1, kPlutoPresentFlagInkPriority);
  std::uint16_t history_a = 0;
  std::uint16_t history_b = 0;
  ASSERT_TRUE(pluto::swtcon::debug_color_history_for_testing(
      p.raw(), fast_rect.x, fast_rect.y, &history_a, &history_b));
  EXPECT_EQ(history_a, 2u);
  EXPECT_EQ(history_b, 0u);

  p.present(kPlutoRefreshFast, fast_rect, 2, kPlutoPresentFlagInkPriority);
  fill_rgb565(p.frame(), 0xffff);
  ASSERT_EQ(p.present_once(kPlutoRefreshFast, fast_rect, 3,
                           kPlutoPresentFlagInkPriority),
            kPlutoStatusOk);
  fill_rgb565(p.frame(), 0x0000);
  ASSERT_EQ(p.present_once(kPlutoRefreshFast, fast_rect, 4,
                           kPlutoPresentFlagInkPriority),
            kPlutoStatusOk);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
  ASSERT_TRUE(pluto::swtcon::debug_color_history_for_testing(
      p.raw(), fast_rect.x, fast_rect.y, &history_a, &history_b));
  EXPECT_EQ(history_a, 2u);
  EXPECT_EQ(history_b, 0u);

  fill_rgb565(p.frame(), 0xffff);
  p.present(kPlutoRefreshFast, fast_rect, 5, kPlutoPresentFlagInkPriority);
  ASSERT_TRUE(pluto::swtcon::debug_color_history_for_testing(
      p.raw(), fast_rect.x, fast_rect.y, &history_a, &history_b));
  EXPECT_EQ(history_a, static_cast<std::uint16_t>(0x80u | 28u));
  EXPECT_EQ(history_b, 0u);

  // Bottom-right execution padding is outside PixelEngine's visible plane;
  // the visible 1x1 coverage proof expands only into storage guards during
  // the masked history seed.
  fill_rgb565(p.frame(), 0x0000);
  p.present(kPlutoRefreshFast,
            PlutoRect{kLogicalWidth - 1, kLogicalHeight - 1, 1, 1}, 6,
            kPlutoPresentFlagInkPriority);
  for (const auto &[x, y] : {std::pair{kLogicalWidth - 1, kLogicalHeight - 1},
                             std::pair{960, 1696}}) {
    ASSERT_TRUE(pluto::swtcon::debug_color_history_for_testing(
        p.raw(), x, y, &history_a, &history_b));
    EXPECT_EQ(history_a, 2u);
    EXPECT_EQ(history_b, 0u);
  }

  // Full + PenTruth remains exact mapped truth and stays raw/unprepared until
  // every earlier Fast fence has positively latched and seeded.
  fill_rgb565(p.frame(), 0xf800);
  p.present(kPlutoRefreshFull, PlutoRect{40, 56, 24, 24}, 7,
            kPlutoPresentFlagPenTruth);
  EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 7);
  std::vector<std::uint64_t> callbacks = p.log().snapshot();
  std::sort(callbacks.begin(), callbacks.end());
  ASSERT_EQ(callbacks.size(), 7u);
  for (std::size_t index = 0; index < callbacks.size(); ++index) {
    EXPECT_EQ(callbacks[index], index + 1);
  }
  const PlutoGallery3DrmDebugStats stats = p.stats();
  EXPECT_EQ(stats.full_updates, 1u);
  EXPECT_EQ(stats.color_enabled, 1u);
  // Fast uses the safe ordinary mode-7 island; only trailing Full is mapped.
  EXPECT_GE(stats.mapped_admissions, 1u);
  EXPECT_GE(stats.mapped_started, 1u);
  EXPECT_GE(stats.mapped_terminals, 1u);
  EXPECT_GE(stats.mapped_confirmed, 1u);
  EXPECT_GE(stats.color_reconciles, 1u);
  EXPECT_EQ(stats.mapped_invalidated, 0u);
  EXPECT_EQ(stats.mapped_poison_regions, 0u);
  EXPECT_GE(stats.color_queue_peak, 1u);
  EXPECT_EQ(stats.color_faults, 0u);
}

TEST(Gallery3DrmPresenterTest, PenTruthFullPreservesRegionalRequest) {
  const std::string eink = write_synth_eink(3, "pen_truth_region");
  Presenter p("dry_run=1,flip_interval_ms=0,eink=" + eink);
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);

  // The source outside `damage` is deliberately black too. Snapshot
  // semantics prove direct SWTCON consumed only the requested truth region;
  // PenTruth selects regional Full fidelity, not synthetic or full-field ink.
  fill_rgb565(p.frame(), 0x0000);
  const PlutoRect damage{32, 48, 32, 24};
  p.present(kPlutoRefreshFull, damage, 1, kPlutoPresentFlagPenTruth);

  std::vector<std::uint8_t> snapshot(kLogicalFrameBytes);
  PlutoSurface out{};
  out.pixels = snapshot.data();
  out.stride_bytes = kLogicalStrideBytes;
  out.width = kLogicalWidth;
  out.height = kLogicalHeight;
  out.format = kPlutoPixelFormatRgb565;
  ASSERT_EQ(p.ops()->snapshot(p.raw(), &out), kPlutoStatusOk);

  const std::size_t inside =
      static_cast<std::size_t>(damage.y) * kLogicalStrideBytes +
      static_cast<std::size_t>(damage.x) * kRgb565BytesPerPixel;
  EXPECT_EQ(snapshot[inside], 0u);
  EXPECT_EQ(snapshot[inside + 1], 0u);
  EXPECT_EQ(snapshot[0], 0xffu);
  EXPECT_EQ(snapshot[1], 0xffu);
  EXPECT_EQ(p.log().last_frame_id.load(std::memory_order_acquire), 1u);
  EXPECT_EQ(p.stats().full_updates, 1u);

  std::remove(eink.c_str());
}

TEST(Gallery3DrmPresenterTest,
     SameTilePenTruthCoalescesExactlyForFullTextAndPackedEdge) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }

  Presenter p(installed_color_options());
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);

  const auto history = [&](int x, int y) {
    std::pair<std::uint16_t, std::uint16_t> pixel{};
    EXPECT_TRUE(pluto::swtcon::debug_color_history_for_testing(
        p.raw(), x, y, &pixel.first, &pixel.second));
    return pixel;
  };

  // Two sparse Full regions share one physical tile. The hole's chroma
  // history must be byte-exact while the request admits/completes once.
  const std::array<PlutoRect, 2> full_damage = {PlutoRect{64, 64, 4, 4},
                                                PlutoRect{80, 80, 4, 4}};
  const auto full_hole_before = history(72, 72);
  const auto full_selected_before = history(64, 64);
  const PlutoGallery3DrmDebugStats before = p.stats();
  fill_rgb565(p.frame(), 0x0000);
  p.present_many(kPlutoRefreshFull, full_damage, 1, kPlutoPresentFlagPenTruth);
  const PlutoGallery3DrmDebugStats after_full = p.stats();
  EXPECT_EQ(after_full.mapped_admissions, before.mapped_admissions + 1u);
  EXPECT_EQ(after_full.mapped_confirmed, before.mapped_confirmed + 1u);
  EXPECT_EQ(after_full.color_pen_truth_input_rects,
            before.color_pen_truth_input_rects + 2u);
  EXPECT_EQ(after_full.color_pen_truth_grouped_tiles,
            before.color_pen_truth_grouped_tiles + 1u);
  EXPECT_EQ(after_full.color_pen_truth_masked_lanes,
            before.color_pen_truth_masked_lanes + 32u);
  EXPECT_EQ(after_full.color_pen_truth_groups_per_request_max, 1u);
  const auto full_hole_after = history(72, 72);
  const auto full_selected_after = history(64, 64);
  EXPECT_EQ(full_hole_after.first, full_hole_before.first);
  EXPECT_EQ(full_hole_after.second, full_hole_before.second);
  EXPECT_TRUE(full_selected_after.first != full_selected_before.first ||
              full_selected_after.second != full_selected_before.second);

  // Text uses the same exact masked path and retains a disjoint in-tile hole.
  const std::array<PlutoRect, 2> text_damage = {PlutoRect{128, 64, 3, 3},
                                                PlutoRect{144, 72, 4, 2}};
  const auto text_hole_before = history(136, 68);
  const auto text_selected_before = history(128, 64);
  fill_rgb565(p.frame(), 0xf800);
  p.present_many(kPlutoRefreshText, text_damage, 2, kPlutoPresentFlagPenTruth);
  const PlutoGallery3DrmDebugStats after_text = p.stats();
  EXPECT_EQ(after_text.mapped_admissions, after_full.mapped_admissions + 1u);
  EXPECT_EQ(after_text.color_pen_truth_input_rects,
            after_full.color_pen_truth_input_rects + 2u);
  EXPECT_EQ(after_text.color_pen_truth_grouped_tiles,
            after_full.color_pen_truth_grouped_tiles + 1u);
  EXPECT_EQ(after_text.color_pen_truth_masked_lanes,
            after_full.color_pen_truth_masked_lanes + 17u);
  const auto text_hole_after = history(136, 68);
  const auto text_selected_after = history(128, 64);
  EXPECT_EQ(text_hole_after.first, text_hole_before.first);
  EXPECT_EQ(text_hole_after.second, text_hole_before.second);
  EXPECT_TRUE(text_selected_after.first != text_selected_before.first ||
              text_selected_after.second != text_selected_before.second);

  // Preserve the union of independently rounded envelopes away from panel
  // guards too: x=7,w=1 formerly executed through x=14 even when another
  // contributor moves the grouped origin to x=1.
  const std::array<PlutoRect, 2> unaligned_damage = {PlutoRect{1, 200, 1, 1},
                                                     PlutoRect{7, 202, 1, 1}};
  const auto unaligned_hole_before = history(14, 202);
  fill_rgb565(p.frame(), 0x0000);
  p.present_many(kPlutoRefreshFull, unaligned_damage, 3,
                 kPlutoPresentFlagPenTruth);
  const PlutoGallery3DrmDebugStats after_unaligned = p.stats();
  EXPECT_EQ(after_unaligned.mapped_admissions,
            after_text.mapped_admissions + 1u);
  EXPECT_EQ(after_unaligned.color_pen_truth_input_rects,
            after_text.color_pen_truth_input_rects + 2u);
  EXPECT_EQ(after_unaligned.color_pen_truth_grouped_tiles,
            after_text.color_pen_truth_grouped_tiles + 1u);
  EXPECT_EQ(after_unaligned.color_pen_truth_masked_lanes,
            after_text.color_pen_truth_masked_lanes + 2u);
  const auto unaligned_hole_after = history(14, 202);
  EXPECT_EQ(unaligned_hole_after.first, unaligned_hole_before.first);
  EXPECT_EQ(unaligned_hole_after.second, unaligned_hole_before.second);

  // Logical x=953 owns replicated mapper/history guards through packed x=959.
  // The x=946 contributor deliberately changes the union's rounding anchor;
  // guard lanes remain preserved and excluded from the authored-lane counter.
  const std::array<PlutoRect, 2> edge_damage = {PlutoRect{946, 100, 1, 2},
                                                PlutoRect{952, 102, 2, 2}};
  const auto edge_hole_before = history(948, 100);
  const auto edge_guard_before = history(959, 102);
  fill_rgb565(p.frame(), 0x0000);
  p.present_many(kPlutoRefreshFull, edge_damage, 4, kPlutoPresentFlagPenTruth);
  const PlutoGallery3DrmDebugStats after_edge = p.stats();
  EXPECT_EQ(after_edge.mapped_admissions,
            after_unaligned.mapped_admissions + 1u);
  EXPECT_EQ(after_edge.color_pen_truth_input_rects,
            after_unaligned.color_pen_truth_input_rects + 2u);
  EXPECT_EQ(after_edge.color_pen_truth_grouped_tiles,
            after_unaligned.color_pen_truth_grouped_tiles + 1u);
  EXPECT_EQ(after_edge.color_pen_truth_masked_lanes,
            after_unaligned.color_pen_truth_masked_lanes + 6u);
  const auto edge_hole_after = history(948, 100);
  const auto edge_guard_after = history(959, 102);
  EXPECT_EQ(edge_hole_after.first, edge_hole_before.first);
  EXPECT_EQ(edge_hole_after.second, edge_hole_before.second);
  EXPECT_TRUE(edge_guard_after.first != edge_guard_before.first ||
              edge_guard_after.second != edge_guard_before.second);
  EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 4);
}

TEST(Gallery3DrmPresenterTest,
     SpanningAndFullScreenPenTruthRemainDenseAndAccepted) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }

  Presenter p(installed_color_options());
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
  const PlutoGallery3DrmDebugStats before = p.stats();

  // The first execution crosses x=32 and blocks the second contributor's
  // tile from grouping. Both remain the original dense operations.
  const std::array<PlutoRect, 2> spanning = {PlutoRect{30, 96, 4, 2},
                                             PlutoRect{4, 100, 4, 2}};
  fill_rgb565(p.frame(), 0x0000);
  p.present_many(kPlutoRefreshFull, spanning, 1, kPlutoPresentFlagPenTruth);
  const PlutoGallery3DrmDebugStats after_spanning = p.stats();
  EXPECT_EQ(after_spanning.mapped_admissions, before.mapped_admissions + 2u);
  EXPECT_EQ(after_spanning.color_pen_truth_input_rects,
            before.color_pen_truth_input_rects);
  EXPECT_EQ(after_spanning.color_pen_truth_grouped_tiles,
            before.color_pen_truth_grouped_tiles);

  // Bottom padding cannot be represented inside the final physical tile:
  // y=1695 executes through storage guard y=1696. It therefore blocks
  // grouping and retains the original dense guard journal.
  const std::array<PlutoRect, 2> bottom = {
      PlutoRect{200, kLogicalHeight - 1, 1, 1},
      PlutoRect{208, kLogicalHeight - 8, 1, 1}};
  std::uint16_t bottom_guard_a_before = 0;
  std::uint16_t bottom_guard_b_before = 0;
  ASSERT_TRUE(pluto::swtcon::debug_color_history_for_testing(
      p.raw(), 200, kLogicalHeight, &bottom_guard_a_before,
      &bottom_guard_b_before));
  fill_rgb565(p.frame(), 0x0000);
  p.present_many(kPlutoRefreshFull, bottom, 2, kPlutoPresentFlagPenTruth);
  const PlutoGallery3DrmDebugStats after_bottom = p.stats();
  EXPECT_EQ(after_bottom.mapped_admissions,
            after_spanning.mapped_admissions + 2u);
  EXPECT_EQ(after_bottom.color_pen_truth_input_rects,
            before.color_pen_truth_input_rects);
  EXPECT_EQ(after_bottom.color_pen_truth_grouped_tiles,
            before.color_pen_truth_grouped_tiles);
  std::uint16_t bottom_guard_a_after = 0;
  std::uint16_t bottom_guard_b_after = 0;
  ASSERT_TRUE(pluto::swtcon::debug_color_history_for_testing(
      p.raw(), 200, kLogicalHeight, &bottom_guard_a_after,
      &bottom_guard_b_after));
  EXPECT_TRUE(bottom_guard_a_after != bottom_guard_a_before ||
              bottom_guard_b_after != bottom_guard_b_before);

  // A promoted full-screen PenTruth must stay one bounded operation rather
  // than expanding into ~1,590 tile obligations and livelocking at the cap.
  fill_rgb565(p.frame(), 0xffff);
  p.present(kPlutoRefreshFull, Presenter::kFullScreen, 3,
            kPlutoPresentFlagPenTruth);
  const PlutoGallery3DrmDebugStats after_full = p.stats();
  EXPECT_EQ(after_full.mapped_admissions, after_bottom.mapped_admissions + 1u);
  EXPECT_EQ(after_full.color_pen_truth_input_rects,
            before.color_pen_truth_input_rects);
  EXPECT_EQ(after_full.color_pen_truth_grouped_tiles,
            before.color_pen_truth_grouped_tiles);
  EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 3);
  EXPECT_EQ(after_full.color_faults, 0u);
}

// PlutoGallery3DrmDebugStats is APPEND-ONLY ABI: callers pass struct_size and
// must never see existing fields move. The engine stage appended ten
// fields; every offset below is pinned — moving, removing, or reordering
// ANY field breaks this at compile time.
static_assert(offsetof(PlutoGallery3DrmDebugStats, struct_size) == 0);
static_assert(offsetof(PlutoGallery3DrmDebugStats, updates_completed) == 8);
static_assert(offsetof(PlutoGallery3DrmDebugStats, gc16_updates) == 16);
static_assert(offsetof(PlutoGallery3DrmDebugStats, full_updates) == 24);
static_assert(offsetof(PlutoGallery3DrmDebugStats, settle_updates) == 32);
// Appended at the per-pixel engine stage (now equally frozen):
static_assert(offsetof(PlutoGallery3DrmDebugStats, admissions) == 40);
static_assert(offsetof(PlutoGallery3DrmDebugStats, absorbed) == 48);
static_assert(offsetof(PlutoGallery3DrmDebugStats, parked) == 56);
static_assert(offsetof(PlutoGallery3DrmDebugStats, retargets) == 64);
static_assert(offsetof(PlutoGallery3DrmDebugStats, cancels) == 72);
static_assert(offsetof(PlutoGallery3DrmDebugStats, neutral_frames) == 80);
static_assert(offsetof(PlutoGallery3DrmDebugStats, double_scans) == 88);
static_assert(offsetof(PlutoGallery3DrmDebugStats, dc_saturations) == 96);
static_assert(offsetof(PlutoGallery3DrmDebugStats, pauses) == 104);
static_assert(offsetof(PlutoGallery3DrmDebugStats, active_px_peak) == 112);
// Appended at the HOLD-gap exemption stage (device livelock fix):
static_assert(offsetof(PlutoGallery3DrmDebugStats, hold_rescans) == 120);
static_assert(offsetof(PlutoGallery3DrmDebugStats, pen_cross_mode_preemptions) ==
              136);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_enabled) == 144);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_preprocess_max_us) == 256);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_fast_bypasses) == 264);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_fast_bypass_wait_max_us) ==
              272);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_fast_obligations) == 280);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_fast_reserve_declines) ==
              320);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_pen_focus_updates) == 328);
static_assert(offsetof(PlutoGallery3DrmDebugStats,
                       color_pen_focus_deferred_current) == 360);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_pen_truth_input_rects) ==
              368);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_pen_truth_grouped_tiles) ==
              376);
static_assert(offsetof(PlutoGallery3DrmDebugStats, color_pen_truth_masked_lanes) ==
              384);
static_assert(offsetof(PlutoGallery3DrmDebugStats,
                       color_pen_truth_groups_per_request_max) == 392);
static_assert(sizeof(PlutoGallery3DrmDebugStats) == 400,
              "append new fields at the END and update this pin");
static_assert(offsetof(PlutoPenFocus, struct_size) == 0);
static_assert(offsetof(PlutoPenFocus, rect) == 8);
static_assert(offsetof(PlutoPenFocus, flags) == 24);
static_assert(offsetof(PlutoPenFocus, sequence) == 32);
static_assert(sizeof(PlutoPenFocus) == 40);
static_assert(offsetof(PlutoPresenterOps, set_pen_focus) == 72);
static_assert(offsetof(PlutoPresenterOps, stage_handoff) == 80);
static_assert(offsetof(PlutoPresenterOps, get_handoff) == 88);
static_assert(offsetof(PlutoPresenterOps, confirm_handoff) == 96);
static_assert(sizeof(PlutoPresenterOps) == 104,
              "presenter ops are append-only; add new hooks at the tail");

// Re-pin: option parsing. Invalid values reject the open; retired keys are
// accepted-and-ignored; the engine constants parse.
TEST(Gallery3DrmPresenterTest, OptionSurfaceValidatesAndRetiresKeys) {
  const std::string eink = write_synth_eink(3, "options");

  {
    // All retired keys + engine constant overrides parse fine.
    Presenter p("dry_run=1,flip_interval_ms=0,eink=" + eink +
                ",settle_delay_ms=25,full_refresh_every=1,du_mode=1,"
                "du_white=3,du_black=4,dither=0,du_frames=5,"
                "max_active_px=100000,full_flash_band_frames=2,"
                "early_cancel=0,settle_force_identity=0,"
                "emission_mode=row_stage,scan_period_ns=0");
    EXPECT_EQ(p.open_status(), kPlutoStatusOk);
  }
  {
    Presenter p("dry_run=1,eink=" + eink + ",max_active_px=abc");
    EXPECT_EQ(p.open_status(), kPlutoStatusInvalidArgument);
  }
  {
    Presenter p("dry_run=1,eink=" + eink + ",early_cancel=maybe");
    EXPECT_EQ(p.open_status(), kPlutoStatusInvalidArgument);
  }
  {
    Presenter p("dry_run=1,eink=" + eink + ",emission_mode=bogus");
    EXPECT_EQ(p.open_status(), kPlutoStatusInvalidArgument);
  }
  {
    // The engine requires a decoded waveform; a missing .eink fails open.
    Presenter p("dry_run=1,eink=/nonexistent/pluto-test.eink");
    EXPECT_EQ(p.open_status(), kPlutoStatusInvalidArgument);
  }

  std::remove(eink.c_str());
}

// Re-pin: the presenter never self-schedules a quality pass — every drive
// maps 1:1 to an explicit present(), completing its frame_id exactly once;
// retired settle keys with old "aggressive" values change nothing.
TEST(Gallery3DrmPresenterTest, PresenterNeverSelfSchedulesSettles) {
  const std::string eink = write_synth_eink(3, "settle");
  Presenter p("dry_run=1,flip_interval_ms=0,eink=" + eink +
              ",settle_delay_ms=25,full_refresh_every=1");
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);

  // Frame 1: partial Fast update (black square on white). Under the old
  // machinery settle_delay_ms=25 + full_refresh_every=1 would have armed a
  // self-scheduled settle AND a promoted Full.
  for (int y = 8; y < 72; ++y) {
    for (int x = 8; x < 72; ++x) {
      store_rgb565(p.frame(), x, y, 0x0000);
    }
  }
  p.present(kPlutoRefreshFast, PlutoRect{8, 8, 64, 64}, 1);

  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  PlutoGallery3DrmDebugStats stats = p.stats();
  EXPECT_EQ(stats.updates_completed, 1u);
  EXPECT_EQ(stats.settle_updates, 0u);
  EXPECT_EQ(stats.full_updates, 0u);
  EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 1);

  // An explicit renderer-scheduled quality pass (what the SettlePlanner
  // sends) completes like any other frame.
  fill_rgb565(p.frame(), 0xffff);
  p.present(kPlutoRefreshFull, Presenter::kFullScreen, 2);
  stats = p.stats();
  EXPECT_EQ(stats.updates_completed, 2u);
  EXPECT_EQ(stats.full_updates, 1u);
  EXPECT_EQ(stats.settle_updates, 0u);
  EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 2);
  EXPECT_EQ(p.log().last_frame_id.load(std::memory_order_acquire), 2u);

  std::remove(eink.c_str());
}

// Multi-inflight: two presents accepted back-to-back without waiting for
// completion (ready() does not gate on in-flight updates), both complete.
TEST(Gallery3DrmPresenterTest, AcceptsConcurrentPresentsWithoutInflightGate) {
  const std::string eink = write_synth_eink(3, "inflight");
  Presenter p("dry_run=1,flip_interval_ms=0,eink=" + eink);
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);

  // Wait out the cold-clear gate with a first present.
  fill_rgb565(p.frame(), 0xffff);
  p.present(kPlutoRefreshUi, PlutoRect{0, 0, 64, 64}, 1);

  // Two back-to-back presents on overlapping tiles with DIFFERENT content:
  // the second parks behind the first and re-admits at the waveform
  // boundary — both must complete exactly once.
  for (int y = 8; y < 72; ++y) {
    for (int x = 8; x < 72; ++x) {
      store_rgb565(p.frame(), x, y, 0x0000);
    }
  }
  ASSERT_EQ(p.present_once(kPlutoRefreshUi, PlutoRect{8, 8, 64, 64}, 2),
            kPlutoStatusOk);
  EXPECT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshUi));
  for (int y = 8; y < 72; ++y) {
    for (int x = 8; x < 72; ++x) {
      store_rgb565(p.frame(), x, y, 0x8410);
    }
  }
  ASSERT_EQ(p.present_once(kPlutoRefreshUi, PlutoRect{8, 8, 64, 64}, 3),
            kPlutoStatusOk);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
  EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 3);
  EXPECT_EQ(p.log().last_frame_id.load(std::memory_order_acquire), 3u);

  std::remove(eink.c_str());
}

// wait_idle is also the renderer's rotation/hibernate generation fence. The
// engine removes a frame from its optical bookkeeping before invoking the
// enqueue-only completion callback, so that delivery must have an explicit
// second fence of its own. Deliberately blocking the test callback makes the
// otherwise tiny handoff window deterministic.
TEST(Gallery3DrmPresenterTest, WaitIdleIncludesCompletionCallbackDelivery) {
  const std::string eink = write_synth_eink(3, "callback_fence");
  BlockingCallback callback;
  Presenter p("dry_run=1,flip_interval_ms=0,stats_log_s=0,eink=" + eink,
              &BlockingCallback::invoke, &callback);
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);

  const auto ready_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!p.ops()->ready(p.raw(), kPlutoRefreshFast) &&
         std::chrono::steady_clock::now() < ready_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshFast));

  fill_rgb565(p.frame(), 0x0000);
  const PlutoRect damage{8, 8, 32, 32};
  PlutoStatus status = kPlutoStatusAgain;
  const auto present_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (status == kPlutoStatusAgain &&
         std::chrono::steady_clock::now() < present_deadline) {
    status = p.present_once(kPlutoRefreshFast, damage, 77);
  }
  ASSERT_EQ(status, kPlutoStatusOk);

  const bool entered =
      callback.wait_until_entered(std::chrono::milliseconds(10000));
  if (!entered) {
    callback.unblock();
    EXPECT_TRUE(entered) << "completion callback did not start";
    std::remove(eink.c_str());
    return;
  }
  EXPECT_EQ(callback.frame_id, 77u);
  EXPECT_EQ(p.ops()->wait_idle(p.raw(), 0), kPlutoStatusTimeout)
      << "optical completion is not idle until callback delivery returns";

  callback.unblock();
  EXPECT_TRUE(callback.wait_until_returned(std::chrono::milliseconds(10000)));
  EXPECT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);

  std::remove(eink.c_str());
}

TEST(Gallery3DrmPresenterTest,
     NullAndThrowingCompletionCallbacksCannotStrandIdle) {
  const std::string eink = write_synth_eink(3, "callback_edges");
  const std::string options =
      "dry_run=1,flip_interval_ms=0,stats_log_s=0,handoff=0,eink=" + eink;

  // A null callback has no second delivery phase: optical bookkeeping alone
  // controls idle and must still wake its waiter.
  {
    Presenter p(options, nullptr, nullptr, /*install_default_callback=*/false);
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);
    fill_rgb565(p.frame(), 0x0000);
    p.present(kPlutoRefreshFast, PlutoRect{8, 8, 32, 32}, 81);
    EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 0);
  }

  // A C++ callback is contractually enqueue-only and must not throw, but a
  // defensive boundary keeps one bad embedder from terminating the engine
  // thread or leaving the delivery fence permanently nonzero.
  {
    std::atomic<int> calls{0};
    const auto throwing = +[](std::uint64_t, void *user_data) {
      static_cast<std::atomic<int> *>(user_data)->fetch_add(
          1, std::memory_order_acq_rel);
      throw 1;
    };
    Presenter p(options, throwing, &calls);
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);
    fill_rgb565(p.frame(), 0x0000);
    p.present(kPlutoRefreshFast, PlutoRect{8, 8, 32, 32}, 82);
    EXPECT_EQ(calls.load(std::memory_order_acquire), 1);
  }

  std::remove(eink.c_str());
}

namespace {

// DrmInterface mock for the non-dry-run presenter: standard 365x1700 pipe,
// 16 dumb buffers, flip-event scripting, and per-atomic-flip recording of
// (fb_id, bytes-equal-blank-scaffold). set_crtc (the modeset enable) is
// recorded separately.
class RecordingDrm final : public pluto::swtcon::DrmInterface {
public:
  struct Flip {
    std::uint32_t fb_id = 0;
    bool blank = false;
  };

  RecordingDrm() {
    blank_.assign(kDrmPhaseWords, 0);
    pluto::swtcon::init_blank_phase_frame(blank_.data());
  }

  int open_card(const std::string &, std::string *) override {
    open_card_calls_.fetch_add(1, std::memory_order_relaxed);
    return 7;
  }
  void close_fd(int) override {}
  bool set_client_cap(int, std::uint64_t, std::uint64_t,
                      std::string *) override {
    return true;
  }
  bool get_cap(int, std::uint64_t, std::uint64_t *value,
               std::string *) override {
    *value = 1;
    return true;
  }
  bool get_resources(int, pluto::swtcon::DrmResources *out,
                     std::string *) override {
    out->crtcs = {20};
    out->connectors = {10};
    return true;
  }
  bool get_connector(int, std::uint32_t connector_id,
                     pluto::swtcon::DrmConnectorInfo *out,
                     std::string *) override {
    out->connector_id = connector_id;
    out->encoder_id = 30;
    out->connected = true;
    pluto::swtcon::DrmModeInfo mode{};
    mode.hdisplay = kDrmWidth;
    mode.vdisplay = kDrmHeight;
    out->modes = {mode};
    out->properties = {{55, "DPMS", 0}};
    out->encoders = {30};
    return true;
  }
  bool get_encoder(int, std::uint32_t encoder_id,
                   pluto::swtcon::DrmEncoderInfo *out, std::string *) override {
    out->encoder_id = encoder_id;
    out->crtc_id = 20;
    out->possible_crtcs = 1;
    return true;
  }
  bool get_plane_ids(int, std::vector<std::uint32_t> *out,
                     std::string *) override {
    *out = {40};
    return true;
  }
  bool get_plane(int, std::uint32_t plane_id, pluto::swtcon::DrmPlaneInfo *out,
                 std::string *) override {
    out->plane_id = plane_id;
    out->possible_crtcs = 1;
    out->properties = {{60, "type", 1},   {61, "FB_ID", 0},  {62, "CRTC_ID", 0},
                       {63, "CRTC_X", 0}, {64, "CRTC_Y", 0}, {65, "CRTC_W", 0},
                       {66, "CRTC_H", 0}, {67, "SRC_X", 0},  {68, "SRC_Y", 0},
                       {69, "SRC_W", 0},  {70, "SRC_H", 0}};
    return true;
  }
  bool create_dumb(int, std::uint32_t, std::uint32_t, std::uint32_t,
                   pluto::swtcon::DrmDumbCreateResult *out,
                   std::string *) override {
    ++created_;
    out->handle = 1000 + created_;
    out->pitch = kDrmWidth * sizeof(std::uint16_t);
    out->size = kDrmPhaseBytes;
    return true;
  }
  bool add_fb(int, std::uint32_t, std::uint32_t, std::uint8_t, std::uint8_t,
              std::uint32_t, std::uint32_t handle, std::uint32_t *fb_id,
              std::string *) override {
    *fb_id = 2000 + created_;
    fb_to_handle_[*fb_id] = handle;
    return true;
  }
  bool map_dumb(int, std::uint32_t handle, std::uint64_t *offset,
                std::string *) override {
    *offset = handle;
    return true;
  }
  void *mmap_dumb(int, std::uint64_t offset, std::uint64_t size,
                  std::string *) override {
    std::vector<std::uint8_t> &map =
        handle_to_map_[static_cast<std::uint32_t>(offset)];
    map.assign(static_cast<std::size_t>(size), 0);
    return map.data();
  }
  void munmap_dumb(void *, std::uint64_t) override {}
  bool rm_fb(int, std::uint32_t, std::string *) override { return true; }
  bool destroy_dumb(int, std::uint32_t, std::string *) override { return true; }
  bool set_crtc(int, std::uint32_t, std::uint32_t fb_id, std::uint32_t,
                const pluto::swtcon::DrmModeInfo &, std::string *) override {
    std::lock_guard<std::mutex> lock(mutex_);
    set_crtc_fb_ids_.push_back(fb_id);
    return true;
  }
  bool blank_crtc(int, std::uint32_t, std::string *) override { return true; }
  bool set_connector_property(int, std::uint32_t, std::uint32_t, std::uint64_t,
                              std::string *) override {
    return true;
  }
  bool atomic_commit(int, const pluto::swtcon::DrmAtomicRequest &request,
                     std::string *) override {
    const auto fb_id = static_cast<std::uint32_t>(request.values.back());
    Flip flip;
    flip.fb_id = fb_id;
    std::vector<std::uint16_t> snapshot;
    if (record_flips) {
      const auto handle = fb_to_handle_.find(fb_id);
      if (handle != fb_to_handle_.end()) {
        const auto map = handle_to_map_.find(handle->second);
        if (map != handle_to_map_.end()) {
          flip.blank = std::memcmp(map->second.data(), blank_.data(),
                                   kDrmPhaseBytes) == 0;
          if (!flip.blank && snapshot_content_planes) {
            // Copy the latched plane's bytes AT FLIP TIME: exactly what the
            // panel rescans on a vblank gap — the recharge-equivalence
            // oracle decodes these instead of ever calling presenter code.
            const auto *words =
                reinterpret_cast<const std::uint16_t *>(map->second.data());
            snapshot.assign(words, words + kDrmPhaseWords);
          }
        }
      }
    }
    std::unique_lock<std::mutex> lock(mutex_);
    if (fb_id != 2016u) {
      ++content_flip_count_;
    }
    if (fb_id != 2016u && hold_content_flip_number_ != 0 &&
        content_flip_count_ == hold_content_flip_number_) {
      hold_content_flip_number_ = 0;
      content_flip_blocked_ = true;
      content_flip_cv_.notify_all();
      content_flip_cv_.wait(lock, [this] { return release_content_flip_; });
      content_flip_blocked_ = false;
      release_content_flip_ = false;
    }
    if (record_flips) {
      flips_.push_back(flip);
    }
    if (!snapshot.empty()) {
      plane_snapshots_.push_back(std::move(snapshot));
    }
    const bool drop_event = fb_id != 2016u && drop_next_content_event_;
    if (drop_event) {
      drop_next_content_event_ = false;
      ++dropped_content_event_count_;
    }
    if ((request.flags & pluto::swtcon::kDrmModePageFlipEventFlag) != 0 &&
        !drop_event) {
      pluto::swtcon::DrmFlipEvent event;
      event.user_data = request.user_data;
      if (fb_id != 2016u && corrupt_content_flip_number_ != 0 &&
          content_flip_count_ == corrupt_content_flip_number_) {
        event.user_data ^= 0x4000000000000000ull;
        corrupt_content_flip_number_ = 0;
      }
      sequence_ += sequence_step.load(std::memory_order_relaxed);
      event.sequence = sequence_;
      pending_events_.push_back(event);
    }
    return true;
  }
  bool read_flip_events(int, std::vector<pluto::swtcon::DrmFlipEvent> *out,
                        std::string *) override {
    std::lock_guard<std::mutex> lock(mutex_);
    out->insert(out->end(), pending_events_.begin(), pending_events_.end());
    pending_events_.clear();
    return true;
  }

  std::vector<Flip> flips() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return flips_;
  }
  std::vector<Flip> content_flips() const {
    std::vector<Flip> out;
    for (const Flip &flip : flips()) {
      if (flip.fb_id != 2016u) { // buffer 15 = HOLD
        out.push_back(flip);
      }
    }
    return out;
  }
  std::vector<std::uint32_t> set_crtc_fb_ids() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return set_crtc_fb_ids_;
  }
  std::size_t open_card_calls() const {
    return open_card_calls_.load(std::memory_order_relaxed);
  }
  // Latched CONTENT (non-blank) planes in flip order (requires
  // record_flips + snapshot_content_planes).
  std::vector<std::vector<std::uint16_t>> plane_snapshots() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return plane_snapshots_;
  }
  void clear_plane_snapshots() {
    std::lock_guard<std::mutex> lock(mutex_);
    plane_snapshots_.clear();
  }

  // Deterministic completion-fence hook: stop the scan thread after it takes
  // the next content ScanReadySlot but before the atomic commit can produce
  // its latch event.
  void hold_next_content_flip() {
    std::lock_guard<std::mutex> lock(mutex_);
    hold_content_flip_number_ = content_flip_count_ + 1;
    content_flip_blocked_ = false;
    release_content_flip_ = false;
  }
  void hold_content_flip_number(std::size_t one_based_number) {
    std::lock_guard<std::mutex> lock(mutex_);
    hold_content_flip_number_ = one_based_number;
    content_flip_blocked_ = false;
    release_content_flip_ = false;
  }
  bool wait_until_content_flip_blocked(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return content_flip_cv_.wait_for(lock, timeout,
                                     [this] { return content_flip_blocked_; });
  }
  void release_held_content_flip() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      release_content_flip_ = true;
    }
    content_flip_cv_.notify_all();
  }

  // Simulate a successful atomic commit whose page-flip event is lost. The
  // engine has built/completed the phase and the scan has taken its slot, but
  // ScanReadySlot must remain unacknowledged forever. close() may not persist
  // that build-ahead state as an optical handoff.
  void drop_next_content_event() {
    std::lock_guard<std::mutex> lock(mutex_);
    drop_next_content_event_ = true;
  }
  void corrupt_content_flip_number(std::size_t one_based_number) {
    std::lock_guard<std::mutex> lock(mutex_);
    corrupt_content_flip_number_ = one_based_number;
  }
  std::size_t content_flip_count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return content_flip_count_;
  }
  std::size_t dropped_content_event_count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return dropped_content_event_count_;
  }
  bool drop_next_content_event_pending() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return drop_next_content_event_;
  }

  // Scripting for the livelock regression: >= 2 makes EVERY latch show a
  // hardware vblank gap (jittery scan); record_flips=false drops the
  // per-flip 1.24 MB blank memcmp so the mock never throttles a fast scan.
  // snapshot_content_planes copies every non-blank latched plane for the
  // recharge-equivalence oracle. sequence_step is atomic so a test may
  // raise it mid-run (anomaly injection above a learned cadence baseline);
  // the others are set before the presenter opens and never written again.
  std::atomic<std::uint32_t> sequence_step{1};
  bool record_flips = true;
  bool snapshot_content_planes = false;

private:
  std::atomic<std::size_t> open_card_calls_{0};
  int created_ = 0;
  std::map<std::uint32_t, std::uint32_t> fb_to_handle_;
  std::map<std::uint32_t, std::vector<std::uint8_t>> handle_to_map_;
  std::vector<std::uint16_t> blank_;
  mutable std::mutex mutex_;
  std::condition_variable content_flip_cv_;
  std::size_t content_flip_count_ = 0;
  std::size_t hold_content_flip_number_ = 0;
  bool content_flip_blocked_ = false;
  bool release_content_flip_ = false;
  bool drop_next_content_event_ = false;
  std::size_t dropped_content_event_count_ = 0;
  std::size_t corrupt_content_flip_number_ = 0;
  std::vector<Flip> flips_;
  std::vector<std::vector<std::uint16_t>> plane_snapshots_;
  std::vector<std::uint32_t> set_crtc_fb_ids_;
  std::vector<pluto::swtcon::DrmFlipEvent> pending_events_;
  std::uint32_t sequence_ = 100;
};

} // namespace

TEST(Gallery3DrmPresenterTest,
     HandoffNamespaceContentionReturnsBeforeAnyDrmAccessOrModeset) {
  const std::string eink = write_synth_eink(3, "handoff_lease_before_drm");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_lease_before_drm_" +
                              std::to_string(::getpid()) + ".bin";
  ASSERT_TRUE(discard_handoff_path(handoff));

  pluto::GlassHandoffLease owner;
  ASSERT_TRUE(pluto::glass_handoff_acquire_lease(handoff, &owner));

  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));

  PlutoStatus open_status = kPlutoStatusInternal;
  std::size_t open_card_calls = 0;
  std::vector<std::uint32_t> set_crtc_fb_ids;
  {
    Presenter blocked("flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
                      ",eink=" + eink + ",scan_period_ns=2000000");
    open_status = blocked.open_status();
    open_card_calls = drm_raw->open_card_calls();
    set_crtc_fb_ids = drm_raw->set_crtc_fb_ids();
    blocked.close_now();
  }

  // A failed pre-DRM open leaves the injected interface in the one-shot test
  // slot. Reset it explicitly so this assertion cannot affect the next test.
  pluto::swtcon::set_drm_interface_for_testing(nullptr);
  owner = pluto::GlassHandoffLease{};
  const bool artifacts_removed = discard_handoff_path(handoff);
  std::remove(eink.c_str());

  EXPECT_EQ(open_status, kPlutoStatusAgain);
  EXPECT_EQ(open_card_calls, 0u);
  EXPECT_TRUE(set_crtc_fb_ids.empty());
  EXPECT_TRUE(artifacts_removed);
  EXPECT_FALSE(std::filesystem::exists(handoff));
  EXPECT_FALSE(std::filesystem::exists(handoff + ".lease"));
}

TEST(Gallery3DrmPresenterTest,
     ExactColorFastReserveSurvivesTruthSaturationAndStaysBounded) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }

  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
  Presenter p(installed_color_options(/*include_all_blobs=*/true,
                                      /*exact_color=*/true,
                                      /*dry_run=*/false) +
              ",scan_period_ns=2000000");
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);

  // The six reserve counters were appended at byte 280. A caller compiled
  // against the immediately previous append-only ABI must still receive its
  // known prefix without the implementation overwriting its unknown tail.
  constexpr std::size_t kLegacyStatsSize =
      offsetof(PlutoGallery3DrmDebugStats, color_fast_obligations);
  alignas(PlutoGallery3DrmDebugStats)
      std::byte legacy_storage[sizeof(PlutoGallery3DrmDebugStats) + 16u];
  auto *legacy_stats =
      ::new (static_cast<void *>(legacy_storage)) PlutoGallery3DrmDebugStats{};
  legacy_stats->struct_size = kLegacyStatsSize;
  std::memset(legacy_storage + kLegacyStatsSize, 0xa5,
              sizeof(legacy_storage) - kLegacyStatsSize);
  ASSERT_EQ(pluto_gallery3_drm_presenter_debug_stats(p.raw(), legacy_stats),
            kPlutoStatusOk);
  EXPECT_EQ(legacy_stats->struct_size, kLegacyStatsSize);
  for (std::size_t index = kLegacyStatsSize; index < sizeof(legacy_storage);
       ++index) {
    EXPECT_EQ(std::to_integer<unsigned int>(legacy_storage[index]), 0xa5u)
        << "index=" << index;
  }
  const auto ready_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(20);
  while (!p.ops()->ready(p.raw(), kPlutoRefreshFull) &&
         std::chrono::steady_clock::now() < ready_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshFull));

  // One disjoint mapped operation per rect fills the ordinary 64-obligation
  // lane. Hold its first real scan so none can retire while admission and
  // bounded-accounting are observed.
  std::vector<PlutoRect> truth_damage;
  truth_damage.reserve(64);
  for (int index = 0; index < 64; ++index) {
    truth_damage.push_back(
        {32 + (index % 8) * 96, 32 + (index / 8) * 96, 8, 8});
  }
  PlutoPresentRequest truth{};
  truth.struct_size = sizeof(truth);
  truth.surface.pixels = p.frame()->data();
  truth.surface.stride_bytes = kLogicalStrideBytes;
  truth.surface.width = kLogicalWidth;
  truth.surface.height = kLogicalHeight;
  truth.surface.format = kPlutoPixelFormatRgb565;
  truth.damage = truth_damage.data();
  truth.damage_count = truth_damage.size();
  truth.refresh_class = kPlutoRefreshFull;
  truth.flags = kPlutoPresentFlagPenTruth;
  truth.frame_id = 1;

  drm_raw->hold_next_content_flip();
  const PlutoStatus truth_status = p.ops()->present(p.raw(), &truth);
  if (truth_status != kPlutoStatusOk) {
    drm_raw->release_held_content_flip();
    EXPECT_EQ(truth_status, kPlutoStatusOk);
    return;
  }
  const bool scan_blocked = drm_raw->wait_until_content_flip_blocked(
      std::chrono::milliseconds(10000));
  if (!scan_blocked) {
    drm_raw->release_held_content_flip();
    EXPECT_TRUE(scan_blocked) << "mapped saturation plane never reached scan";
    return;
  }

  PlutoGallery3DrmDebugStats saturated = p.stats();
  EXPECT_EQ(saturated.color_truth_obligations, 64u);
  EXPECT_EQ(saturated.color_fast_obligations, 0u);
  EXPECT_EQ(saturated.color_truth_obligation_peak, 64u);
  EXPECT_FALSE(p.ops()->ready(p.raw(), kPlutoRefreshFull));
  EXPECT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshFast));

  // This disjoint nib update would have returned Again under the shared cap.
  // It now consumes exactly one Fast-reserve slot while further mapped truth
  // remains backpressured.
  const PlutoRect nib{800, 1200, 16, 16};
  fill_rgb565(p.frame(), 0x0000);
  const PlutoStatus fast_status =
      p.present_once(kPlutoRefreshFast, nib, 2, kPlutoPresentFlagInkPriority);
  const PlutoStatus further_truth_status =
      p.present_once(kPlutoRefreshFull, nib, 3, kPlutoPresentFlagPenTruth);

  // A maximal second Fast batch would exceed 64 normal + 64 reserved
  // obligations and must decline before doing any preprocessing.
  truth.refresh_class = kPlutoRefreshFast;
  truth.flags = kPlutoPresentFlagInkPriority;
  truth.frame_id = 4;
  const PlutoStatus overflow_fast_status = p.ops()->present(p.raw(), &truth);
  const PlutoGallery3DrmDebugStats reserved = p.stats();

  EXPECT_EQ(fast_status, kPlutoStatusOk);
  EXPECT_EQ(further_truth_status, kPlutoStatusAgain);
  EXPECT_EQ(overflow_fast_status, kPlutoStatusAgain);
  EXPECT_EQ(reserved.color_truth_obligations, 64u);
  EXPECT_EQ(reserved.color_fast_obligations, 1u);
  EXPECT_EQ(reserved.color_fast_obligation_peak, 1u);
  EXPECT_EQ(reserved.color_fast_reserve_uses, 1u);
  EXPECT_EQ(reserved.color_fast_reserve_declines, 1u);
  EXPECT_EQ(reserved.color_queue_peak, 65u);

  drm_raw->release_held_content_flip();
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
  const PlutoGallery3DrmDebugStats idle = p.stats();
  EXPECT_EQ(idle.color_truth_obligations, 0u);
  EXPECT_EQ(idle.color_fast_obligations, 0u);
  EXPECT_EQ(idle.color_faults, 0u);
}

TEST(Gallery3DrmPresenterTest,
     PhysicalHoverDefersSameTileRawTruthWhileDisjointAndStartedTruthRun) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }

  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
  Presenter p(installed_color_options(/*include_all_blobs=*/true,
                                      /*exact_color=*/true,
                                      /*dry_run=*/false) +
              ",scan_period_ns=2000000");
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  ASSERT_GE(p.ops()->struct_size, offsetof(PlutoPresenterOps, set_pen_focus) +
                                      sizeof(p.ops()->set_pen_focus));
  ASSERT_NE(p.ops()->set_pen_focus, nullptr);
  const auto ready_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(20);
  while (!p.ops()->ready(p.raw(), kPlutoRefreshFull) &&
         std::chrono::steady_clock::now() < ready_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshFull));

  PlutoPenFocus malformed{};
  malformed.struct_size = sizeof(malformed) - 1u;
  EXPECT_EQ(p.ops()->set_pen_focus(p.raw(), &malformed),
            kPlutoStatusInvalidArgument);
  malformed.struct_size = sizeof(malformed);
  malformed.flags = kPlutoPenFocusContact;
  EXPECT_EQ(p.ops()->set_pen_focus(p.raw(), &malformed),
            kPlutoStatusInvalidArgument);

  // Hover at the bottom-right pixel of engine tile (0,0). The held truth at
  // (0,0) does not intersect the exact 1px focus, but shares its mapped 32px
  // ownership tile and therefore must not be prepared. Tile (2,2) is disjoint
  // and continues immediately.
  const PlutoPenFocus hover{
      sizeof(PlutoPenFocus), {31, 31, 1, 1}, kPlutoPenFocusInRange, 1};
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &hover), kPlutoStatusOk);
  fill_rgb565(p.frame(), 0xf800);
  ASSERT_EQ(p.present_once(kPlutoRefreshFull, PlutoRect{0, 0, 1, 1}, 1,
                           kPlutoPresentFlagPenTruth),
            kPlutoStatusOk);
  ASSERT_EQ(p.present_once(kPlutoRefreshFull, PlutoRect{64, 64, 8, 8}, 2,
                           kPlutoPresentFlagPenTruth),
            kPlutoStatusOk);

  const auto held_deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(20);
  PlutoGallery3DrmDebugStats initially_held{};
  do {
    initially_held = p.stats();
    if (initially_held.color_pen_focus_deferred_current == 1u) {
      break;
    }
    std::this_thread::yield();
  } while (std::chrono::steady_clock::now() < held_deadline);
  EXPECT_EQ(initially_held.color_pen_focus_deferred_current, 1u);
  EXPECT_GE(initially_held.color_pen_focus_truth_deferrals, 1u);

  // Contact is a real focus-geometry edge and starts a fresh quiet window.
  // It remains metadata-only: the queued app truth is neither discarded nor
  // released immediately.
  const PlutoPenFocus contact{
      sizeof(PlutoPenFocus),
      {31, 31, 1, 1},
      static_cast<std::uint32_t>(kPlutoPenFocusInRange) |
          static_cast<std::uint32_t>(kPlutoPenFocusContact),
      2};
  const auto contact_at = std::chrono::steady_clock::now();
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &contact), kPlutoStatusOk);
  EXPECT_EQ(p.ops()->wait_idle(p.raw(), 0), kPlutoStatusTimeout);

  const auto disjoint_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  bool disjoint_completed = false;
  while (std::chrono::steady_clock::now() < disjoint_deadline) {
    const auto callbacks = p.log().snapshot();
    disjoint_completed =
        std::find(callbacks.begin(), callbacks.end(), 2u) != callbacks.end();
    if (disjoint_completed) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  ASSERT_TRUE(disjoint_completed)
      << "disjoint mapped truth stalled behind physical hover";
  const auto held_callbacks = p.log().snapshot();
  PlutoGallery3DrmDebugStats held = p.stats();
  EXPECT_GE(held.color_pen_focus_truth_deferrals, 1u);
  EXPECT_GE(held.color_pen_focus_disjoint_bypasses, 1u);
  EXPECT_TRUE(std::find(held_callbacks.begin(), held_callbacks.end(), 2u) !=
              held_callbacks.end());

  // Exact fidelity chases after one stationary quiet window without pen-up.
  const auto chase_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (p.stats().mapped_admissions < 2u &&
         std::chrono::steady_clock::now() < chase_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  const auto chase_elapsed =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - contact_at);
  EXPECT_GE(chase_elapsed.count(), 12);
  EXPECT_GE(p.stats().mapped_admissions, 2u);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
  EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 2);

  const PlutoPenFocus clear{sizeof(PlutoPenFocus), {}, kPlutoPenFocusNone, 3};
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &clear), kPlutoStatusOk);
  const auto clear_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (p.stats().color_pen_focus_clears < 1u &&
         std::chrono::steady_clock::now() < clear_deadline) {
    std::this_thread::yield();
  }

  // Once mapped truth has started emitting, later proximity cannot discard or
  // preempt it. Hold its first content flip to make this ordering
  // deterministic.
  drm_raw->hold_next_content_flip();
  fill_rgb565(p.frame(), 0x07e0);
  ASSERT_EQ(p.present_once(kPlutoRefreshFull, PlutoRect{0, 0, 8, 8}, 3,
                           kPlutoPresentFlagPenTruth),
            kPlutoStatusOk);
  const bool started = drm_raw->wait_until_content_flip_blocked(
      std::chrono::milliseconds(10000));
  if (!started) {
    drm_raw->release_held_content_flip();
    EXPECT_TRUE(started) << "mapped truth never emitted its first plane";
    return;
  }
  const PlutoPenFocus late_hover{
      sizeof(PlutoPenFocus), {1, 1, 1, 1}, kPlutoPenFocusInRange, 4};
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &late_hover), kPlutoStatusOk);
  drm_raw->release_held_content_flip();
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
  const auto callbacks = p.log().snapshot();
  EXPECT_TRUE(std::find(callbacks.begin(), callbacks.end(), 3u) !=
              callbacks.end());
  EXPECT_EQ(p.stats().mapped_discarded, 0u);
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &clear), kPlutoStatusOk);
  const auto final_clear_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  PlutoGallery3DrmDebugStats final = p.stats();
  while (final.color_pen_focus_clears < 2u &&
         std::chrono::steady_clock::now() < final_clear_deadline) {
    std::this_thread::yield();
    final = p.stats();
  }
  EXPECT_EQ(final.color_pen_focus_updates, 3u);
  EXPECT_EQ(final.color_pen_focus_clears, 2u);
  EXPECT_EQ(final.color_faults, 0u);
}

TEST(Gallery3DrmPresenterTest,
     MovingFocusRenewsQuietWindowButIdenticalSynsDoNotStarveTruth) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }

  Presenter p(installed_color_options());
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);

  PlutoPenFocus focus{
      sizeof(PlutoPenFocus), {1, 1, 1, 1}, kPlutoPenFocusInRange, 1};
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &focus), kPlutoStatusOk);
  fill_rgb565(p.frame(), 0xf800);
  ASSERT_EQ(p.present_once(kPlutoRefreshFull, {0, 0, 1, 1}, 1,
                           kPlutoPresentFlagPenTruth),
            kPlutoStatusOk);

  const auto armed_deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(20);
  while (p.stats().color_pen_focus_deferred_current == 0u &&
         std::chrono::steady_clock::now() < armed_deadline) {
    std::this_thread::yield();
  }
  ASSERT_EQ(p.stats().color_pen_focus_deferred_current, 1u);

  // Raw focus geometry changes continuously while its 32px collision ROI
  // stays on the same tile. Full fidelity must not start underneath the nib.
  for (std::uint64_t sequence = 2; sequence <= 32; ++sequence) {
    focus.rect.x = static_cast<int32_t>(1 + (sequence % 20));
    focus.sequence = sequence;
    ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &focus), kPlutoStatusOk);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    EXPECT_EQ(p.stats().mapped_admissions, 0u);
  }

  // Repeated stationary SYNs are not motion. They must not renew the quiet
  // window forever: exact truth chases while proximity remains active.
  const auto stationary_at = std::chrono::steady_clock::now();
  const auto stationary_deadline =
      stationary_at + std::chrono::milliseconds(120);
  while (p.stats().mapped_admissions == 0u &&
         std::chrono::steady_clock::now() < stationary_deadline) {
    ++focus.sequence;
    ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &focus), kPlutoStatusOk);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  const auto stationary_elapsed =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - stationary_at);
  EXPECT_GE(stationary_elapsed.count(), 12);
  EXPECT_LT(stationary_elapsed.count(), 120);
  EXPECT_GE(p.stats().mapped_admissions, 1u);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
}

TEST(Gallery3DrmPresenterTest,
     PartialFastCoverageOfOlderTruthCannotDeadlockPendingLane) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }

  Presenter p(installed_color_options());
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);

  // Queue A and overlapping wider B behind focus, then a newer Fast that
  // wholly covers A but only partially covers B. The Fast batch cannot safely
  // bypass both older truths. A pending-Fast dependency on A would therefore
  // make neither side runnable forever; ordinary FIFO truth must proceed once
  // the stationary focus quiet window expires.
  const PlutoPenFocus focus{
      sizeof(PlutoPenFocus), {1, 1, 1, 1}, kPlutoPenFocusInRange, 1};
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &focus), kPlutoStatusOk);
  const PlutoRect a{0, 0, 8, 8};
  const PlutoRect b{0, 0, 16, 8};
  fill_rgb565(p.frame(), 0xf800);
  ASSERT_EQ(p.present_once(kPlutoRefreshFull, a, 1, kPlutoPresentFlagPenTruth),
            kPlutoStatusOk);
  fill_rgb565(p.frame(), 0x07e0);
  ASSERT_EQ(p.present_once(kPlutoRefreshFull, b, 2, kPlutoPresentFlagPenTruth),
            kPlutoStatusOk);
  fill_rgb565(p.frame(), 0x0000);
  ASSERT_EQ(
      p.present_once(kPlutoRefreshFast, a, 3, kPlutoPresentFlagInkPriority),
      kPlutoStatusOk);

  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 5000), kPlutoStatusOk);
  const auto callbacks = p.log().snapshot();
  EXPECT_TRUE(std::find(callbacks.begin(), callbacks.end(), 1u) !=
              callbacks.end());
  EXPECT_TRUE(std::find(callbacks.begin(), callbacks.end(), 2u) !=
              callbacks.end());
  EXPECT_TRUE(std::find(callbacks.begin(), callbacks.end(), 3u) !=
              callbacks.end());
  const PlutoGallery3DrmDebugStats stats = p.stats();
  EXPECT_EQ(stats.color_truth_obligations, 0u);
  EXPECT_EQ(stats.color_fast_obligations, 0u);
  EXPECT_EQ(stats.color_faults, 0u);
}

TEST(Gallery3DrmPresenterTest,
     PenFocusMailboxIsCoherentAndContendedPublishP99IsBounded) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }

  Presenter p(installed_color_options());
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);

  constexpr int kThreads = 4;
  constexpr int kPublishesPerThread = 2000;
  std::array<std::vector<std::uint64_t>, kThreads> elapsed_ns;
  std::array<std::thread, kThreads> threads;
  std::atomic<bool> failed{false};
  for (int thread = 0; thread < kThreads; ++thread) {
    elapsed_ns[thread].reserve(kPublishesPerThread);
    threads[thread] = std::thread([&, thread] {
      for (int index = 0; index < kPublishesPerThread; ++index) {
        const PlutoPenFocus focus{
            sizeof(PlutoPenFocus),
            {1 + ((thread * 7 + index) % 24), 1 + ((thread * 11 + index) % 24),
             1, 1},
            kPlutoPenFocusInRange,
            static_cast<std::uint64_t>(thread * kPublishesPerThread + index +
                                       1)};
        const auto begin = std::chrono::steady_clock::now();
        if (p.ops()->set_pen_focus(p.raw(), &focus) != kPlutoStatusOk) {
          failed.store(true, std::memory_order_release);
        }
        elapsed_ns[thread].push_back(static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - begin)
                .count()));
      }
    });
  }
  for (std::thread &thread : threads) {
    thread.join();
  }
  EXPECT_TRUE(!failed.load(std::memory_order_acquire));

  std::vector<std::uint64_t> all_elapsed;
  all_elapsed.reserve(kThreads * kPublishesPerThread);
  for (const auto &thread_elapsed : elapsed_ns) {
    all_elapsed.insert(all_elapsed.end(), thread_elapsed.begin(),
                       thread_elapsed.end());
  }
  std::sort(all_elapsed.begin(), all_elapsed.end());
  const std::uint64_t p99_ns = all_elapsed[all_elapsed.size() * 99u / 100u];
  std::fprintf(stderr, "pen_focus_mailbox_contended p99_ns=%llu samples=%zu\n",
               static_cast<unsigned long long>(p99_ns), all_elapsed.size());
  EXPECT_LT(p99_ns, 5'000'000u);

  // A post-join final publication must be coherent and latest. Its 1px raw
  // rect expands to tile (0,0), so disjoint pixels in that tile are held.
  const PlutoPenFocus final_focus{
      sizeof(PlutoPenFocus), {31, 31, 1, 1}, kPlutoPenFocusInRange, 100'000};
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &final_focus), kPlutoStatusOk);
  fill_rgb565(p.frame(), 0x07e0);
  ASSERT_EQ(p.present_once(kPlutoRefreshFull, {0, 0, 1, 1}, 9,
                           kPlutoPresentFlagPenTruth),
            kPlutoStatusOk);
  const auto held_deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(20);
  while (p.stats().color_pen_focus_deferred_current == 0u &&
         std::chrono::steady_clock::now() < held_deadline) {
    std::this_thread::yield();
  }
  EXPECT_EQ(p.stats().color_pen_focus_deferred_current, 1u);
  const PlutoPenFocus clear{
      sizeof(PlutoPenFocus), {}, kPlutoPenFocusNone, 100'001};
  ASSERT_EQ(p.ops()->set_pen_focus(p.raw(), &clear), kPlutoStatusOk);
  ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
  EXPECT_EQ(p.stats().color_faults, 0u);
}

TEST(Gallery3DrmPresenterTest,
     ExactColorSafeFastWaitsForTerminalLatchAndUnknownFailsClosed) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }
  const std::string options =
      installed_color_options(/*include_all_blobs=*/true,
                              /*exact_color=*/true, /*dry_run=*/false) +
      ",scan_period_ns=2000000";
  const PlutoRect region{64, 96, 32, 32};

  {
    auto drm = std::make_unique<RecordingDrm>();
    RecordingDrm *drm_raw = drm.get();
    pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
    Presenter p(options);
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!p.ops()->ready(p.raw(), kPlutoRefreshFast) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshFast));

    // Proven mode 7 is ten drive planes plus one terminal HOLD plane.
    drm_raw->hold_content_flip_number(drm_raw->content_flip_count() + 11u);
    fill_rgb565(p.frame(), 0x0000);
    ASSERT_EQ(p.present_once(kPlutoRefreshFast, region, 1,
                             kPlutoPresentFlagInkPriority),
              kPlutoStatusOk);
    const bool terminal_blocked = drm_raw->wait_until_content_flip_blocked(
        std::chrono::milliseconds(10000));
    if (!terminal_blocked) {
      drm_raw->release_held_content_flip();
      EXPECT_TRUE(terminal_blocked) << "mode-7 terminal flip never arrived";
      return;
    }
    // While the first tip fence is still live, unrelated trailing truth must
    // pass the regional dependency gate. The old panel-wide gate left
    // mapped_admissions at zero until pen-up.
    const PlutoRect trailing_region{320, 400, 32, 32};
    fill_rgb565(p.frame(), 0xf800);
    ASSERT_EQ(p.present_once(kPlutoRefreshFull, trailing_region, 2,
                             kPlutoPresentFlagPenTruth),
              kPlutoStatusOk);
    const auto admission_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (p.stats().mapped_admissions == 0 &&
           std::chrono::steady_clock::now() < admission_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    EXPECT_GT(p.stats().mapped_admissions, 0u);

    // The scan thread has already taken A's slot before this mock blocks its
    // flip, so the engine may build one mapped phase behind it. A newer Fast
    // draw-back must not discard that now-scanned token; it parks until the
    // real mapped terminal instead of inventing an optical midpoint.
    fill_rgb565(p.frame(), 0x0000);
    ASSERT_EQ(p.present_once(kPlutoRefreshFast, trailing_region, 3,
                             kPlutoPresentFlagInkPriority),
              kPlutoStatusOk);
    EXPECT_EQ(p.stats().mapped_discarded, 0u);
    const auto superseded_callbacks = p.log().snapshot();
    EXPECT_TRUE(std::find(superseded_callbacks.begin(),
                          superseded_callbacks.end(),
                          2u) == superseded_callbacks.end());
    EXPECT_EQ(p.ops()->wait_idle(p.raw(), 0), kPlutoStatusTimeout);

    // Admit another update over the same tip while A's terminal scan is
    // pending. Hold B's first drive after releasing A: A must complete while
    // B is still live, otherwise continuous hover/contact becomes an
    // accidental wait-for-pen-up gate.
    fill_rgb565(p.frame(), 0xffff);
    ASSERT_EQ(p.present_once(kPlutoRefreshFast, region, 4,
                             kPlutoPresentFlagInkPriority),
              kPlutoStatusOk);
    drm_raw->hold_next_content_flip();
    drm_raw->release_held_content_flip();
    ASSERT_TRUE(drm_raw->wait_until_content_flip_blocked(
        std::chrono::milliseconds(10000)))
        << "newer Fast first drive flip never arrived";
    const auto callback_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    bool older_completed = false;
    while (std::chrono::steady_clock::now() < callback_deadline) {
      const auto callbacks = p.log().snapshot();
      older_completed =
          std::find(callbacks.begin(), callbacks.end(), 1u) != callbacks.end();
      if (older_completed) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    EXPECT_TRUE(older_completed)
        << "latched Fast waited for newer overlapping input to stop";
    EXPECT_EQ(p.ops()->wait_idle(p.raw(), 0), kPlutoStatusTimeout);
    drm_raw->release_held_content_flip();
    ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
    EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 4);
    std::uint16_t a = 0;
    std::uint16_t b = 0;
    ASSERT_TRUE(pluto::swtcon::debug_color_history_for_testing(
        p.raw(), region.x, region.y, &a, &b));
    EXPECT_EQ(a, static_cast<std::uint16_t>(0x80u | 28u));
    EXPECT_EQ(b, 0u);
  }
}

TEST(Gallery3DrmPresenterTest,
     ExactColorFaultDiscardsWarmCandidateAndNextOpenColdClears) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    return;
  }
  const PlutoRect region{64, 96, 32, 32};

  const std::string fault_handoff =
      std::filesystem::temp_directory_path().string() +
      "/pluto_color_fault_handoff_" + std::to_string(::getpid()) + ".bin";
  discard_handoff_path(fault_handoff);
  {
    auto seed_drm = std::make_unique<RecordingDrm>();
    pluto::swtcon::set_drm_interface_for_testing(std::move(seed_drm));
    Presenter seed(
        installed_color_handoff_options(fault_handoff, /*dry_run=*/false) +
        ",scan_period_ns=2000000");
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(), kPlutoStatusOk);
  }
  ASSERT_TRUE(std::filesystem::exists(fault_handoff));

  {
    auto drm = std::make_unique<RecordingDrm>();
    RecordingDrm *drm_raw = drm.get();
    pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
    Presenter p(installed_color_handoff_options(fault_handoff,
                                                /*dry_run=*/false) +
                ",scan_period_ns=2000000");
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);
    ASSERT_EQ(p.confirm_incoming_handoff(), kPlutoStatusOk);
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!p.ops()->ready(p.raw(), kPlutoRefreshFast) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshFast));

    std::atomic<std::size_t> fatal_callbacks{0};
    pluto::FrameRendererConfig renderer_config{};
    renderer_config.width = kLogicalWidth;
    renderer_config.height = kLogicalHeight;
    renderer_config.format = kPlutoPixelFormatRgb565;
    renderer_config.presenter_ops = p.ops();
    renderer_config.presenter = p.raw();
    renderer_config.start_presenter_thread = true;
    renderer_config.enable_auto_ghostbuster = false;
    renderer_config.on_presenter_device_lost = [&fatal_callbacks] {
      fatal_callbacks.fetch_add(1, std::memory_order_acq_rel);
    };
    pluto::FrameRenderer renderer(renderer_config);
    ASSERT_TRUE(renderer.valid());

    drm_raw->corrupt_content_flip_number(drm_raw->content_flip_count() + 11u);
    fill_rgb565(p.frame(), 0x0000);
    ASSERT_EQ(p.present_once(kPlutoRefreshFast, region, 2,
                             kPlutoPresentFlagInkPriority),
              kPlutoStatusOk);
    const auto fatal_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (fatal_callbacks.load(std::memory_order_acquire) == 0u &&
           std::chrono::steady_clock::now() < fatal_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u)
        << "the renderer health poll must surface an asynchronous color "
           "fault without waiting for another present";
    EXPECT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusDeviceLost);
    EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 0);
    std::uint16_t a = 0;
    std::uint16_t b = 0;
    EXPECT_FALSE(pluto::swtcon::debug_color_history_for_testing(
        p.raw(), region.x, region.y, &a, &b))
        << "unknown terminal evidence must invalidate A/B, never seed it";
    EXPECT_EQ(p.stats().color_faults, 1u);
    EXPECT_NE(p.stage_handoff({}, 20), kPlutoStatusOk);
  }
  EXPECT_FALSE(std::filesystem::exists(fault_handoff))
      << "a color fault must never recreate the consumed warm seed";

  {
    auto drm = std::make_unique<RecordingDrm>();
    RecordingDrm *drm_raw = drm.get();
    pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
    Presenter recovery(
        installed_color_handoff_options(fault_handoff, /*dry_run=*/false) +
        ",scan_period_ns=2000000");
    ASSERT_EQ(recovery.open_status(), kPlutoStatusOk);
    PlutoHandoffPayload candidate{};
    candidate.struct_size = sizeof(candidate);
    EXPECT_EQ(recovery.ops()->get_handoff(recovery.raw(), &candidate),
              kPlutoStatusAgain)
        << "the faulted candidate must not be admissible on the next open";
    ASSERT_EQ(recovery.ops()->wait_idle(recovery.raw(), 30000), kPlutoStatusOk);
    EXPECT_EQ(recovery.stats().cold_clear_mode, 2)
        << "missing faulted state must take the balanced color cold rail";
    EXPECT_EQ(recovery.stats().color_faults, 0u);
    EXPECT_GT(drm_raw->content_flip_count(), 0u)
        << "the RecordingDrm must observe the replacement cold-clear scans";
  }
  EXPECT_FALSE(std::filesystem::exists(fault_handoff));
  discard_handoff_path(fault_handoff);
}

// Re-pin of the Stage-0 DU-hold + sequencer-reset INTENTS on the new
// machinery: the scan always parks on the always-blank HOLD slot (buffer
// 15) whenever nothing is active, and content planes flip in deterministic
// build-slot order 0,1,2,... — two short cold-clear rails first, then the
// present's waveform phases.
TEST(Gallery3DrmPresenterTest, ScanParksOnBlankHoldAndSlotsRotateInOrder) {
  const std::string eink = write_synth_eink(3, "hold");
  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));

  {
    // 2 ms scan period keeps the wall clock short while staying far above
    // build cost; flip events on.
    Presenter p("flip_interval_ms=0,eink=" + eink + ",scan_period_ns=2000000");
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);

    // Modeset enable: exactly one legacy set_crtc, showing the HOLD fb.
    const std::vector<std::uint32_t> enables = drm_raw->set_crtc_fb_ids();
    ASSERT_EQ(enables.size(), 1u);
    EXPECT_EQ(enables[0], 2016u);

    // One partial present (black square on the white glass).
    for (int y = 8; y < 72; ++y) {
      for (int x = 8; x < 72; ++x) {
        store_rgb565(p.frame(), x, y, 0x0000);
      }
    }
    p.present(kPlutoRefreshFast, PlutoRect{8, 8, 64, 64}, 1);

    // The synthetic table lacks mode 7, so each Fast rail falls back to its
    // one-phase mode-1 record and is emitted as 3 onset-staggered bands.
    // Black + white = 6 blank planes, then the present's 3 mode-2 phases.
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (drm_raw->content_flips().size() < 9 &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    const std::vector<RecordingDrm::Flip> content = drm_raw->content_flips();
    ASSERT_EQ(content.size(), 9u);
    for (std::size_t i = 0; i < 9; ++i) {
      EXPECT_EQ(content[i].fb_id, 2001u + i) << "content flip " << i;
    }
    // The fallback mode-1 record is all-hold in this fixture: both rail
    // passes are byte-blank; the user present's push codes are not.
    for (std::size_t i = 0; i < 6; ++i) {
      EXPECT_TRUE(content[i].blank) << "cold-clear plane " << i;
    }
    for (std::size_t i = 6; i < 9; ++i) {
      EXPECT_FALSE(content[i].blank) << "present plane " << i;
    }

    // Judged-blank parking: with nothing active, every further flip is the
    // HOLD fb and its bytes are the blank scaffold.
    const std::size_t settled_flip_count = drm_raw->flips().size();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    const std::vector<RecordingDrm::Flip> flips = drm_raw->flips();
    ASSERT_GT(flips.size(), settled_flip_count);
    for (std::size_t i = settled_flip_count; i < flips.size(); ++i) {
      EXPECT_EQ(flips[i].fb_id, 2016u) << "flip " << i;
      EXPECT_TRUE(flips[i].blank) << "flip " << i;
    }

    // Appended debug-stats fields are live.
    const PlutoGallery3DrmDebugStats stats = p.stats();
    EXPECT_GT(stats.admissions, 0u);
    EXPECT_GT(stats.neutral_frames, 0u); // HOLD parking counted
    EXPECT_EQ(stats.double_scans, 0u);
    EXPECT_EQ(stats.hold_rescans, 0u); // consecutive latches: no gaps
    EXPECT_GT(stats.active_px_peak, 0u);
  }

  std::remove(eink.c_str());
}

// Rotation/detach uses wait_idle as its final optical fence. Hold the scan
// thread after it consumes the user's final ready slot but before the DRM
// commit/latch event: PixelEngine bookkeeping and the completion callback may
// finish, yet wait_idle must remain blocked until that exact slot is latched.
TEST(Gallery3DrmPresenterTest,
     WaitIdleFencesFinalReadySlotUntilLatchAcknowledgement) {
  const std::string eink = write_synth_eink(1, "ready_slot_fence");
  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));

  {
    Presenter p("flip_interval_ms=0,stats_log_s=0,handoff=0,eink=" + eink +
                ",scan_period_ns=2000000");
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);

    // Clear the cold-start gate and leave the engine/scan pipeline idle.
    fill_rgb565(p.frame(), 0x0000);
    const PlutoRect damage{8, 8, 32, 32};
    p.present(kPlutoRefreshFast, damage, 1);
    const int callbacks_before = p.log().calls.load(std::memory_order_acquire);

    drm_raw->hold_next_content_flip();
    fill_rgb565(p.frame(), 0xffff);
    PlutoStatus present_status = kPlutoStatusAgain;
    const auto present_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (present_status == kPlutoStatusAgain &&
           std::chrono::steady_clock::now() < present_deadline) {
      present_status = p.present_once(kPlutoRefreshFast, damage, 2);
      if (present_status == kPlutoStatusAgain) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    }
    ASSERT_EQ(present_status, kPlutoStatusOk);

    const bool scan_blocked = drm_raw->wait_until_content_flip_blocked(
        std::chrono::milliseconds(10000));
    if (!scan_blocked) {
      drm_raw->release_held_content_flip();
      EXPECT_TRUE(scan_blocked) << "final content slot was never consumed";
      std::remove(eink.c_str());
      return;
    }

    const auto completion_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (p.log().calls.load(std::memory_order_acquire) == callbacks_before &&
           std::chrono::steady_clock::now() < completion_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const bool bookkeeping_complete =
        p.log().calls.load(std::memory_order_acquire) > callbacks_before;
    if (!bookkeeping_complete) {
      drm_raw->release_held_content_flip();
      EXPECT_TRUE(bookkeeping_complete)
          << "one-phase user frame did not finish before scan latch";
      std::remove(eink.c_str());
      return;
    }

    auto waiter = std::async(std::launch::async, [&p] {
      return p.ops()->wait_idle(p.raw(), 30000);
    });
    EXPECT_TRUE(waiter.wait_for(std::chrono::milliseconds(50)) ==
                std::future_status::timeout)
        << "wait_idle returned while the final ready slot was held pre-latch";

    drm_raw->release_held_content_flip();
    ASSERT_TRUE(waiter.wait_for(std::chrono::seconds(10)) ==
                std::future_status::ready);
    EXPECT_EQ(waiter.get(), kPlutoStatusOk);
  }

  std::remove(eink.c_str());
}

// Cold clear uses the internal settle sentinel frame_id 0, so it has no user
// pending-frame record. Pin its sixth and final one-phase/onset-band content
// flip before latch: wait_idle must block from open, remain blocked after the
// engine marks cold clear terminal, and finish only when that slot latches.
TEST(Gallery3DrmPresenterTest, WaitIdleIncludesColdClearThroughItsFinalLatch) {
  const std::string eink = write_synth_eink(1, "cold_clear_idle_fence");
  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  // Synthetic mode-1 fallback: black and white each emit three staggered
  // one-phase bands. Hold the final white band deterministically.
  drm_raw->hold_content_flip_number(6);
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));

  {
    Presenter p("flip_interval_ms=0,stats_log_s=0,handoff=0,eink=" + eink +
                ",scan_period_ns=2000000");
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);

    auto waiter = std::async(std::launch::async, [&p] {
      return p.ops()->wait_idle(p.raw(), 30000);
    });
    EXPECT_TRUE(waiter.wait_for(std::chrono::milliseconds(50)) ==
                std::future_status::timeout)
        << "wait_idle returned while internal cold clear was active";

    const bool final_flip_blocked = drm_raw->wait_until_content_flip_blocked(
        std::chrono::milliseconds(10000));
    if (!final_flip_blocked) {
      drm_raw->release_held_content_flip();
      EXPECT_TRUE(final_flip_blocked)
          << "final cold-clear ready slot was never consumed";
      std::remove(eink.c_str());
      return;
    }

    // The engine owns the cold-clear terminal transition and can reach it
    // while the scan thread is blocked in the final commit. Admission-ready
    // proves that internal state is done; the outstanding latch must still
    // keep the optical idle fence closed.
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!p.ops()->ready(p.raw(), kPlutoRefreshFast) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const bool cold_clear_terminal = p.ops()->ready(p.raw(), kPlutoRefreshFast);
    if (!cold_clear_terminal) {
      drm_raw->release_held_content_flip();
      EXPECT_TRUE(cold_clear_terminal)
          << "cold clear did not reach terminal engine state";
      std::remove(eink.c_str());
      return;
    }
    EXPECT_TRUE(waiter.wait_for(std::chrono::milliseconds(50)) ==
                std::future_status::timeout)
        << "wait_idle returned before final cold-clear latch acknowledgement";

    drm_raw->release_held_content_flip();
    ASSERT_TRUE(waiter.wait_for(std::chrono::seconds(10)) ==
                std::future_status::ready);
    EXPECT_EQ(waiter.get(), kPlutoStatusOk);
  }

  std::remove(eink.c_str());
}

namespace {

// The livelock waveform: mode 0 (INIT, the cold clear) is a REAL 4-phase
// drive record — the device INIT is a long drive sequence, and only a
// multi-phase clear makes band overlap observable in active_px_peak (a
// 1-phase record completes each band within its own build). Mode 2 shares
// the record; mode 1 is all-hold.
std::string write_livelock_eink() {
  const int nmode = 3;
  const int ntemp = 2;
  const int phases = 4;
  std::vector<std::uint8_t> hold(swtcon_synth::kCells, 0);
  std::vector<std::uint8_t> drive_codes(static_cast<std::size_t>(phases) *
                                        swtcon_synth::kCells);
  for (int phase = 0; phase < phases; ++phase) {
    for (int cell = 0; cell < swtcon_synth::kCells; ++cell) {
      drive_codes[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
                  cell] = static_cast<std::uint8_t>((cell + phase) % 7);
    }
  }
  const std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(hold),
      swtcon_synth::record_from_codes(drive_codes)};
  // mode 0 -> drive, mode 1 -> hold, mode 2 -> drive (both temp bins).
  const std::vector<std::size_t> record_for = {1, 1, 0, 0, 1, 1};
  const std::vector<std::uint8_t> file =
      swtcon_synth::wrap_eink(swtcon_synth::build_container(
          nmode, ntemp, {0, 20}, records, record_for));
  const std::string path = "/tmp/pluto_swtcon_presenter_" +
                           std::to_string(::getpid()) + "_livelock.eink";
  std::ofstream out(path, std::ios::binary);
  EXPECT_TRUE(out.good());
  out.write(reinterpret_cast<const char *>(file.data()),
            static_cast<std::streamsize>(file.size()));
  return path;
}

} // namespace

// LIVELOCK REGRESSION (device session 2026-07-08): the DRM vblank sequence
// free-runs at the hardware rate while flips ride software deadlines, so
// EVERY latch can show a sequence gap >= 2 from scheduling jitter alone.
// On device this fed a livelock: each gap queued a double-scan recharge
// that read the full 1.24 MB write-combined dumb buffer back on the engine
// thread (tens of ms), builds starved, the scan flipped HOLD, the next gap
// queued another recharge — completions stayed 0 forever while
// dc_saturations climbed past 164 M. This test scripts that condition on
// the host: gaps on every latch, a scan period (0.5 ms) far below the
// build cost of a full-field cold clear so builds overrun the period the
// way they did on device (HOLD flips + pauses between publishes). Pinned:
//   - the cold clear completes and one user frame completes, both within
//     a bounded wait (the device showed completions=0 forever);
//   - dc_saturations stays 0 — HOLD-gap rescans are exempt at the scan
//     and content recharges charge the per-tile build-time impulse
//     summaries; the summary path has no plane-read hook to call, so the
//     O(1)-per-gap recharge bound holds structurally;
//   - the full-field FORCE-IDENTITY clear is sweep-bounded: bands snap to
//     the 32 px tile grid (544/576/576 rows), and a new band waits for
//     busy-pixel headroom, so active_px_peak during bring-up is one band
//     (<= 576 x 954 px), never the whole field (device: 1,617,984);
//   - jitter lands in hold_rescans; double_scans counts only content
//     rescans.
TEST(Gallery3DrmPresenterTest, JitteryVblankColdClearNeverLivelocks) {
  const std::string eink = write_livelock_eink();
  auto drm = std::make_unique<RecordingDrm>();
  drm->sequence_step = 2;    // gap >= 2 on EVERY latch
  drm->record_flips = false; // no 1.24 MB memcmp per flip at a 2 kHz scan
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));

  {
    Presenter p("flip_interval_ms=0,eink=" + eink + ",scan_period_ns=500000");
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);

    // Bounded bring-up: the admission gate must open despite the
    // sustained gap storm.
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!p.ops()->ready(p.raw(), kPlutoRefreshUi) &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshUi))
        << "cold clear never completed under vblank jitter (livelock)";

    // Cold-clear sweep bound: never more than one band active at once.
    PlutoGallery3DrmDebugStats stats = p.stats();
    EXPECT_LE(stats.active_px_peak, 576u * 954u);
    EXPECT_LT(stats.active_px_peak,
              static_cast<std::uint64_t>(kLogicalWidth) * kLogicalHeight);
    EXPECT_EQ(stats.dc_saturations, 0u);

    // One user frame under the same jitter: completes exactly once.
    fill_rgb565(p.frame(), 0x0000);
    p.present(kPlutoRefreshUi, Presenter::kFullScreen, 7);
    EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 1);
    EXPECT_EQ(p.log().last_frame_id.load(std::memory_order_acquire), 7u);

    stats = p.stats();
    EXPECT_EQ(stats.updates_completed, 1u); // completions = 1
    EXPECT_EQ(stats.dc_saturations, 0u);
    // The uniform step-2 gap IS this device's steady cadence: the detector
    // learns it as the baseline and reports NO rescans at all — false
    // steady-state rescans were what saturated the stress ledger on device
    // (double_scans == builds) and mass-promoted settles into GC16 flashes.
    EXPECT_EQ(stats.hold_rescans, 0u);
    EXPECT_EQ(stats.double_scans, 0u);
  }

  std::remove(eink.c_str());
}

namespace {

// Recharge-equivalence waveform: mode 0 is all-hold and remains unused;
// mode 1 (Text — NOT in
// the balanced-mode mask, so no completion-time clear_stress wipes the
// rescan account) a 3-phase drive record with mixed-sign codes; mode 2
// shares the hold record.
std::string write_recharge_eink() {
  const int nmode = 3;
  const int ntemp = 2;
  const int phases = 3;
  std::vector<std::uint8_t> hold(swtcon_synth::kCells, 0);
  std::vector<std::uint8_t> drive_codes(static_cast<std::size_t>(phases) *
                                        swtcon_synth::kCells);
  for (int phase = 0; phase < phases; ++phase) {
    for (int cell = 0; cell < swtcon_synth::kCells; ++cell) {
      drive_codes[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
                  cell] = static_cast<std::uint8_t>((cell + phase) % 7);
    }
  }
  const std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(hold),
      swtcon_synth::record_from_codes(drive_codes)};
  // mode 0 -> hold, mode 1 -> drive, mode 2 -> hold (both temp bins).
  const std::vector<std::size_t> record_for = {0, 0, 1, 1, 0, 0};
  const std::vector<std::uint8_t> file =
      swtcon_synth::wrap_eink(swtcon_synth::build_container(
          nmode, ntemp, {0, 20}, records, record_for));
  const std::string path = "/tmp/pluto_swtcon_presenter_" +
                           std::to_string(::getpid()) + "_recharge.eink";
  std::ofstream out(path, std::ios::binary);
  EXPECT_TRUE(out.good());
  out.write(reinterpret_cast<const char *>(file.data()),
            static_cast<std::streamsize>(file.size()));
  return path;
}

} // namespace

// IMPULSE-SUMMARY EXACTNESS (double-scan recharge, device livelock
// fix): the DC-ledger delta of a content-plane double scan must equal the
// plane's exact per-tile signed impulse — what the DELETED plane-reading
// recharge computed. The oracle recomputes it INDEPENDENTLY: the mock
// snapshots every latched non-blank plane's bytes at flip time, and the
// test decodes them with the on-wire 3-bit code layout (the old path's
// exact read) + DcLedgerConfig::impulse_map. The cold clear runs at
// sequence_step=2, which the detector learns as this device's steady
// cadence; the drive phase then runs at step 3 — one gap ABOVE the
// baseline on every latch, so EVERY content plane is rescanned exactly
// once:
//   sum over planes of per-tile decoded impulse  ==  final rescan_dc
//   k_dscan per driven tile per plane            ==  stress delta
// The summary path has no plane-read hook (the plane-reading recharge and
// its slot targets are deleted), so agreement here proves the build-time
// summaries carry the exact impulse the panel physically re-drove.
TEST(Gallery3DrmPresenterTest, DoubleScanRechargeChargesExactPlaneImpulse) {
  using pluto::swtcon::kFirstDataRow;
  using pluto::swtcon::kFirstDataWord;
  const std::string eink = write_recharge_eink();
  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  drm->sequence_step = 2; // steady cadence: learned as the baseline
  drm->snapshot_content_planes = true;
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));

  {
    Presenter p("flip_interval_ms=0,eink=" + eink + ",scan_period_ns=5000000");
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!p.ops()->ready(p.raw(), kPlutoRefreshText) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshText));

    // Baseline after the fast-rail cold clear. `ready()` may become true just
    // before the last cold-clear flip event is handed from the scan thread to
    // the engine thread. Wait for several identical engine-thread snapshots
    // so no late cold-clear recharge can cross the baseline/clear boundary.
    // The uniform step-2 cadence is learned rather than treated as a double
    // scan, so the stable baseline must still contain no rescan charge.
    std::vector<std::int32_t> rescan0;
    std::vector<std::uint16_t> stress0;
    std::uint32_t tile_cols = 0;
    std::vector<std::int32_t> previous_rescan;
    std::vector<std::uint16_t> previous_stress;
    std::uint64_t previous_double_scans = 0;
    bool have_previous = false;
    int stable_snapshots = 0;
    PlutoGallery3DrmDebugStats stats0{};
    const auto baseline_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (stable_snapshots < 3 &&
           std::chrono::steady_clock::now() < baseline_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      ASSERT_TRUE(pluto::swtcon::debug_dc_for_testing(p.raw(), &rescan0,
                                                      &stress0, &tile_cols));
      stats0 = p.stats();
      if (have_previous && rescan0 == previous_rescan &&
          stress0 == previous_stress &&
          stats0.double_scans == previous_double_scans) {
        ++stable_snapshots;
      } else {
        stable_snapshots = 0;
      }
      previous_rescan = rescan0;
      previous_stress = stress0;
      previous_double_scans = stats0.double_scans;
      have_previous = true;
    }
    ASSERT_EQ(stable_snapshots, 3)
        << "cold-clear scan/accounting state did not stabilize";
    ASSERT_GT(tile_cols, 0u);
    for (std::size_t tile = 0; tile < rescan0.size(); ++tile) {
      ASSERT_EQ(rescan0[tile], 0) << "tile " << tile;
    }
    drm_raw->clear_plane_snapshots();

    // Anomaly injection: raise the step ABOVE the learned cadence so every
    // drive-phase latch shows one genuine extra scan.
    drm_raw->sequence_step = 3;

    // One known present: a tile-aligned black square, Text class (mode 1).
    for (int y = 64; y < 128; ++y) {
      for (int x = 64; x < 128; ++x) {
        store_rgb565(p.frame(), x, y, 0x0000);
      }
    }
    p.present(kPlutoRefreshText, PlutoRect{64, 64, 64, 64}, 11);
    EXPECT_EQ(p.log().calls.load(std::memory_order_acquire), 1);

    // wait_idle can return before the LAST built plane's scan flip: wait
    // for all drive phases to latch, then let the scan park (no further
    // content flip is possible with the engine idle).
    const auto flip_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (drm_raw->plane_snapshots().size() < 3 &&
           std::chrono::steady_clock::now() < flip_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    // Independent expectation from the SNAPSHOTTED PLANES (never the
    // presenter's summaries): per tile, the signed impulse sum of every
    // non-hold code on every latched content plane — exactly the per-pixel
    // charge walk of the deleted plane-reading recharge, aggregated.
    const pluto::swtcon::DcLedgerConfig dc_defaults{};
    const std::vector<std::vector<std::uint16_t>> planes =
        drm_raw->plane_snapshots();
    ASSERT_GE(planes.size(), 3u); // one per drive phase
    std::vector<std::int64_t> expected_rescan(rescan0.size(), 0);
    std::vector<std::uint64_t> expected_dscan_stress(rescan0.size(), 0);
    std::vector<std::uint8_t> plane_driven(rescan0.size(), 0);
    for (const std::vector<std::uint16_t> &plane : planes) {
      std::fill(plane_driven.begin(), plane_driven.end(),
                static_cast<std::uint8_t>(0));
      for (int row = 0; row < kLogicalHeight; ++row) {
        const std::uint16_t *window =
            plane.data() +
            static_cast<std::size_t>(row + kFirstDataRow) * kDrmWidth +
            kFirstDataWord;
        for (int x = 0; x < kLogicalWidth; ++x) {
          const std::uint8_t code = static_cast<std::uint8_t>(
              (window[x / 4] >> (9 - 3 * (x % 4))) & 0x7);
          if (code == 0) {
            continue; // hold ops are impulse-free
          }
          const std::size_t tile =
              (static_cast<std::size_t>(row) / 32) * tile_cols +
              static_cast<std::size_t>(x) / 32;
          expected_rescan[tile] += dc_defaults.impulse_map[code];
          plane_driven[tile] = 1;
        }
      }
      for (std::size_t tile = 0; tile < plane_driven.size(); ++tile) {
        if (plane_driven[tile] != 0) {
          expected_dscan_stress[tile] += dc_defaults.k_dscan;
        }
      }
    }
    std::size_t nonzero_tiles = 0;
    for (const std::int64_t value : expected_rescan) {
      nonzero_tiles += value != 0 ? 1u : 0u;
    }
    ASSERT_GT(nonzero_tiles, 0u) << "oracle decoded no drive impulse";

    // The final gap event lands one scan period after the last content
    // latch; poll the engine-thread snapshot until the ledger converges.
    std::vector<std::int32_t> rescan;
    std::vector<std::uint16_t> stress;
    const auto converge_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(15);
    bool match = false;
    while (!match && std::chrono::steady_clock::now() < converge_deadline) {
      ASSERT_TRUE(pluto::swtcon::debug_dc_for_testing(p.raw(), &rescan, &stress,
                                                      &tile_cols));
      match = true;
      for (std::size_t tile = 0; tile < rescan.size(); ++tile) {
        if (rescan[tile] != expected_rescan[tile]) {
          match = false;
          break;
        }
      }
      if (!match) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
    }
    for (std::size_t tile = 0; tile < rescan.size(); ++tile) {
      ASSERT_EQ(rescan[tile], expected_rescan[tile])
          << "rescan account diverged from the plane impulse at tile " << tile;
    }

    // Driven tiles take k_dscan x extra stress. Pauses also charge active
    // tiles (k_pause), so require exact equality only on a pause-free run.
    const PlutoGallery3DrmDebugStats stats1 = p.stats();
    EXPECT_GT(stats1.double_scans, stats0.double_scans);
    EXPECT_EQ(stats1.dc_saturations, 0u);
    for (std::size_t tile = 0; tile < stress.size(); ++tile) {
      const std::uint64_t delta = stress[tile] - stress0[tile];
      if (stats1.pauses == stats0.pauses) {
        EXPECT_EQ(delta, expected_dscan_stress[tile]) << "tile " << tile;
      } else {
        EXPECT_GE(delta, expected_dscan_stress[tile]) << "tile " << tile;
      }
    }
  }

  std::remove(eink.c_str());
}

// Warm glass handoff (include/pluto/glass_handoff.h): a clean close dumps
// the settled glass plane; the next open seeds the engine from it and skips
// the INIT cold clear entirely — the app-switch flash killer. Glass truth
// must carry across the process swap and the chain count must advance.
TEST(Gallery3DrmPresenterTest,
     WarmGlassHandoffRejectsScanTimingAndSimulatorBackendMismatch) {
  const std::string eink = write_synth_eink(3, "handoff_route_identity");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_route_identity_" +
                              std::to_string(::getpid()) + ".bin";
  discard_handoff_path(handoff);

  const auto seed_dry_run = [&](int flip_interval_ms) {
    Presenter seed(
        "dry_run=1,flip_interval_ms=" + std::to_string(flip_interval_ms) +
        ",stats_log_s=0,handoff=" + handoff + ",eink=" + eink);
    if (seed.open_status() != kPlutoStatusOk ||
        seed.ops()->wait_idle(seed.raw(), 30000) != kPlutoStatusOk ||
        seed.stage_handoff() != kPlutoStatusOk) {
      return false;
    }
    seed.close_now();
    return std::filesystem::exists(handoff);
  };

  ASSERT_TRUE(seed_dry_run(2));
  {
    Presenter timing_mismatch(
        "dry_run=1,flip_interval_ms=3,stats_log_s=0,handoff=" + handoff +
        ",eink=" + eink);
    ASSERT_EQ(timing_mismatch.open_status(), kPlutoStatusOk);
    PlutoHandoffPayload payload{};
    payload.struct_size = sizeof(payload);
    EXPECT_EQ(
        timing_mismatch.ops()->get_handoff(timing_mismatch.raw(), &payload),
        kPlutoStatusAgain);
    ASSERT_EQ(timing_mismatch.ops()->wait_idle(timing_mismatch.raw(), 30000),
              kPlutoStatusOk);
    EXPECT_GE(timing_mismatch.stats().cold_clear_mode, 0);
  }
  EXPECT_FALSE(std::filesystem::exists(handoff));

  ASSERT_TRUE(seed_dry_run(2));
  {
    auto drm = std::make_unique<RecordingDrm>();
    pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
    Presenter backend_mismatch(
        "flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
        ",eink=" + eink + ",scan_period_ns=2000000");
    ASSERT_EQ(backend_mismatch.open_status(), kPlutoStatusOk);
    PlutoHandoffPayload payload{};
    payload.struct_size = sizeof(payload);
    EXPECT_EQ(
        backend_mismatch.ops()->get_handoff(backend_mismatch.raw(), &payload),
        kPlutoStatusAgain);
    ASSERT_EQ(backend_mismatch.ops()->wait_idle(backend_mismatch.raw(), 30000),
              kPlutoStatusOk);
    EXPECT_GE(backend_mismatch.stats().cold_clear_mode, 0);
  }
  EXPECT_FALSE(std::filesystem::exists(handoff));
  discard_handoff_path(handoff);
  std::remove(eink.c_str());
}

TEST(Gallery3DrmPresenterTest,
     WarmGlassHandoffChainCapConsumesLastLinkThenForcesColdClear) {
  const std::string eink = write_synth_eink(3, "handoff_chain_lifecycle");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_chain_lifecycle_" +
                              std::to_string(::getpid()) + ".bin";
  discard_handoff_path(handoff);
  const std::string options =
      "dry_run=1,flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
      ",eink=" + eink;

  // The original cold owner publishes chain 0. Seven independent warm owners
  // then consume and advance it through the last admissible chain, 7.
  {
    Presenter seed(options);
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(), kPlutoStatusOk);
  }
  for (std::uint32_t hop = 0; hop + 1u < pluto::kGlassHandoffMaxChain; ++hop) {
    ASSERT_TRUE(std::filesystem::exists(handoff)) << "hop " << hop;
    Presenter owner(options);
    ASSERT_EQ(owner.open_status(), kPlutoStatusOk);
    ASSERT_EQ(owner.confirm_incoming_handoff(), kPlutoStatusOk);
    ASSERT_EQ(owner.ops()->wait_idle(owner.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(owner.stage_handoff(), kPlutoStatusOk) << "hop " << hop;
  }

  {
    Presenter capped(options);
    ASSERT_EQ(capped.open_status(), kPlutoStatusOk);
    ASSERT_EQ(capped.confirm_incoming_handoff(), kPlutoStatusOk);
    ASSERT_EQ(capped.ops()->wait_idle(capped.raw(), 30000), kPlutoStatusOk);
    EXPECT_EQ(capped.stage_handoff(), kPlutoStatusAgain)
        << "chain 7 may be consumed but must never publish chain 8";
  }
  EXPECT_FALSE(std::filesystem::exists(handoff))
      << "the consumed last link must not survive as a reusable seed";

  {
    Presenter recovery(options);
    ASSERT_EQ(recovery.open_status(), kPlutoStatusOk);
    PlutoHandoffPayload payload{};
    payload.struct_size = sizeof(payload);
    EXPECT_EQ(recovery.ops()->get_handoff(recovery.raw(), &payload),
              kPlutoStatusAgain);
    ASSERT_EQ(recovery.ops()->wait_idle(recovery.raw(), 30000), kPlutoStatusOk);
    EXPECT_EQ(recovery.stats().cold_clear_mode, 1)
        << "the synthetic monochrome table has no Fast mode 7, so the "
           "ordinary cold fallback selects its first available rail, mode 1";
  }

  discard_handoff_path(handoff);
  std::remove(eink.c_str());
}

TEST(Gallery3DrmPresenterTest,
     WarmGlassHandoffLostFirstAdmissionClaimForcesColdRestart) {
  const std::string eink = write_synth_eink(3, "handoff_lost_claim");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_lost_claim_" +
                              std::to_string(::getpid()) + ".bin";
  discard_handoff_path(handoff);
  const std::string options =
      "dry_run=1,flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
      ",eink=" + eink;

  {
    Presenter seed(options);
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(), kPlutoStatusOk);
  }
  ASSERT_TRUE(std::filesystem::exists(handoff));

  {
    Presenter incoming(options);
    ASSERT_EQ(incoming.open_status(), kPlutoStatusOk);
    ASSERT_EQ(incoming.confirm_incoming_handoff(), kPlutoStatusOk);
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!incoming.ops()->ready(incoming.raw(), kPlutoRefreshText) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(incoming.ops()->ready(incoming.raw(), kPlutoRefreshText));

    // Simulate another consumer/replacer winning after validation but before
    // this process's first user admission. No imported-state panel write may
    // escape; the presenter becomes device-lost and the supervisor's next
    // open must take the ordinary cold path.
    ASSERT_TRUE(std::filesystem::remove(handoff));
    fill_rgb565(incoming.frame(), 0x0000);
    EXPECT_EQ(
        incoming.present_once(kPlutoRefreshText, PlutoRect{0, 0, 32, 32}, 1),
        kPlutoStatusDeviceLost);
    EXPECT_EQ(incoming.ops()->wait_idle(incoming.raw(), 0),
              kPlutoStatusDeviceLost);
    EXPECT_EQ(incoming.log().calls.load(std::memory_order_acquire), 0);
  }
  EXPECT_FALSE(std::filesystem::exists(handoff));

  {
    Presenter recovery(options);
    ASSERT_EQ(recovery.open_status(), kPlutoStatusOk);
    PlutoHandoffPayload payload{};
    payload.struct_size = sizeof(payload);
    EXPECT_EQ(recovery.ops()->get_handoff(recovery.raw(), &payload),
              kPlutoStatusAgain);
    ASSERT_EQ(recovery.ops()->wait_idle(recovery.raw(), 30000), kPlutoStatusOk);
    EXPECT_GE(recovery.stats().cold_clear_mode, 0);
  }
  discard_handoff_path(handoff);
  std::remove(eink.c_str());
}

TEST(Gallery3DrmPresenterTest,
     ExactColorLostFirstAdmissionClaimNeverWritesImportedStateToPanel) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    PLUTO_SKIP_EXACT_COLOR_FIXTURES();
  }
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_exact_color_lost_claim_" +
                              std::to_string(::getpid()) + ".bin";
  discard_handoff_path(handoff);
  const std::string options =
      installed_color_handoff_options(handoff, /*dry_run=*/false) +
      ",scan_period_ns=2000000";

  {
    auto seed_drm = std::make_unique<RecordingDrm>();
    pluto::swtcon::set_drm_interface_for_testing(std::move(seed_drm));
    Presenter seed(options);
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(), kPlutoStatusOk);
  }
  ASSERT_TRUE(std::filesystem::exists(handoff));

  {
    auto drm = std::make_unique<RecordingDrm>();
    RecordingDrm *drm_raw = drm.get();
    pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
    Presenter incoming(options);
    ASSERT_EQ(incoming.open_status(), kPlutoStatusOk);
    ASSERT_EQ(incoming.confirm_incoming_handoff(), kPlutoStatusOk);
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!incoming.ops()->ready(incoming.raw(), kPlutoRefreshText) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(incoming.ops()->ready(incoming.raw(), kPlutoRefreshText));
    ASSERT_EQ(drm_raw->content_flip_count(), 0u)
        << "accepted warm state must not run a cold/content rail";

    ASSERT_TRUE(std::filesystem::remove(handoff));
    fill_rgb565(incoming.frame(), 0x001f);
    EXPECT_EQ(
        incoming.present_once(kPlutoRefreshText, PlutoRect{64, 96, 32, 32}, 1),
        kPlutoStatusDeviceLost);
    EXPECT_EQ(incoming.ops()->wait_idle(incoming.raw(), 0),
              kPlutoStatusDeviceLost);
    EXPECT_EQ(drm_raw->content_flip_count(), 0u);
    EXPECT_TRUE(drm_raw->content_flips().empty());
    for (const std::uint32_t fb_id : drm_raw->set_crtc_fb_ids()) {
      EXPECT_EQ(fb_id, 2016u) << "only the blank HOLD plane may be latched";
    }
    EXPECT_EQ(incoming.log().calls.load(std::memory_order_acquire), 0);
  }
  EXPECT_FALSE(std::filesystem::exists(handoff));

  discard_handoff_path(handoff);
}

TEST(Gallery3DrmPresenterTest, WarmGlassHandoffSkipsColdClearAndSeedsGlass) {
  const std::string eink = write_synth_eink(3, "handoff");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_" + std::to_string(::getpid()) +
                              ".bin";
  std::remove(handoff.c_str());
  const std::string options = "dry_run=1,flip_interval_ms=0,stats_log_s=0," +
                              std::string("handoff=") + handoff +
                              ",eink=" + eink;

  // Session A: cold boot (no file) -> INIT cold clear runs; drive the panel
  // black; clean close writes the dump.
  {
    Presenter a(options);
    ASSERT_EQ(a.open_status(), kPlutoStatusOk);
    fill_rgb565(a.frame(), 0x0000);
    a.present(kPlutoRefreshText, Presenter::kFullScreen, 1);
    ASSERT_EQ(a.ops()->wait_idle(a.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(a.stage_handoff(), kPlutoStatusOk);
  }
  {
    std::FILE *file = std::fopen(handoff.c_str(), "rb");
    ASSERT_TRUE(file != nullptr) << "clean close must write the dump";
    std::fclose(file);
  }

  // Session B: seeded open — the engine's glass plane must show session A's
  // BLACK panel (a cold clear would have reset it to initial white 0x1e),
  // and the presenter must become ready without a cold clear.
  {
    Presenter b(options);
    ASSERT_EQ(b.open_status(), kPlutoStatusOk);
    ASSERT_EQ(b.confirm_incoming_handoff(), kPlutoStatusOk);
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!b.ops()->ready(b.raw(), kPlutoRefreshText) &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(b.ops()->ready(b.raw(), kPlutoRefreshText));

    std::vector<std::uint8_t> glass;
    int width = 0;
    int height = 0;
    int stride = 0;
    ASSERT_TRUE(pluto::swtcon::debug_glass_for_testing(b.raw(), &glass, &width,
                                                       &height, &stride));
    ASSERT_EQ(width, kLogicalWidth);
    EXPECT_EQ(glass[0], 0u) << "seeded glass must carry session A's black";
    EXPECT_EQ(glass[static_cast<std::size_t>(height / 2) *
                        static_cast<std::size_t>(stride) +
                    static_cast<std::size_t>(width / 2)],
              0u);
    // (The black glass above is the cold-clear discriminator: an INIT
    // clear would have driven the panel back to white 0x1e.)

    // Drive white and close cleanly: the rewritten dump chains +1.
    ASSERT_TRUE(std::filesystem::exists(handoff));
    fill_rgb565(b.frame(), 0xffff);
    ASSERT_EQ(b.present_once(kPlutoRefreshText, Presenter::kFullScreen, 2),
              kPlutoStatusOk);
    EXPECT_FALSE(std::filesystem::exists(handoff))
        << "the consumed candidate must be unlinked before the first "
           "accepted admission returns";
    ASSERT_EQ(b.ops()->wait_idle(b.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(b.stage_handoff(), kPlutoStatusOk);
  }
  {
    Presenter c(options);
    ASSERT_EQ(c.open_status(), kPlutoStatusOk);
    ASSERT_EQ(c.confirm_incoming_handoff(), kPlutoStatusOk);
    std::vector<std::uint8_t> glass;
    int width = 0;
    int height = 0;
    int stride = 0;
    ASSERT_TRUE(pluto::swtcon::debug_glass_for_testing(c.raw(), &glass, &width,
                                                       &height, &stride));
    EXPECT_EQ(glass[0], 30u) << "session B's white must be in the bundle";
  }
  std::remove(handoff.c_str());
  std::remove(eink.c_str());
}

// get_handoff() lends the renderer a presenter-owned pointer. Even if the
// renderer takes longer than the cold-clear decision timeout to decode it,
// that pointer remains immutable and readable until confirm_handoff() (or
// close) ends the loan.
TEST(Gallery3DrmPresenterTest,
     IncomingRendererPayloadSurvivesConfirmationTimeout) {
  const std::string eink = write_synth_eink(3, "handoff_payload_lease");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_payload_lease_" +
                              std::to_string(::getpid()) + ".bin";
  std::remove(handoff.c_str());
  const std::string options =
      "dry_run=1,flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
      ",eink=" + eink;
  constexpr std::array<std::uint8_t, 12> kRendererPayload{
      0x52, 0x47, 0x42, 0x35, 0x36, 0x2d, 0x41, 0x2f, 0x42, 0xa5, 0x5a, 0xff};
  {
    Presenter seed(options);
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(kRendererPayload), kPlutoStatusOk);
  }

  {
    Presenter incoming(options);
    ASSERT_EQ(incoming.open_status(), kPlutoStatusOk);
    PlutoHandoffPayload payload{};
    payload.struct_size = sizeof(payload);
    ASSERT_EQ(incoming.ops()->get_handoff(incoming.raw(), &payload),
              kPlutoStatusOk);
    ASSERT_EQ(payload.byte_count, kRendererPayload.size());
    ASSERT_TRUE(payload.bytes != nullptr);

    // Do not confirm. Readiness proves the 2 s decision timeout expired and
    // the conservative cold clear completed while the payload loan remained
    // outstanding.
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!incoming.ops()->ready(incoming.raw(), kPlutoRefreshText) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(incoming.ops()->ready(incoming.raw(), kPlutoRefreshText));
    EXPECT_TRUE(std::equal(kRendererPayload.begin(), kRendererPayload.end(),
                           payload.bytes));
    EXPECT_EQ(incoming.ops()->confirm_handoff(incoming.raw(), true),
              kPlutoStatusAgain);
  }
  EXPECT_FALSE(std::filesystem::exists(handoff));
  std::remove(eink.c_str());
}

// This is intentionally not a same-process reopen. Session A and session B
// are separate fork children with independent heaps, threads, presenter
// instances, PixelEngines, color workers, and renderers. A third child builds
// the same non-trivial A/B history and applies the successor directly to its
// still-live state: it never reads or imports A's bundle. Exact equality of the
// resulting core sections and decision-bearing renderer mirrors therefore
// proves that importing the A/B plane, engine ledgers, and renderer debt
// together produces the same ordinary color successor as uninterrupted live
// execution, including when warm-resume paint bounds under-report the frame.
TEST(Gallery3DrmPresenterTest,
     ExactColorHandoffAcrossProcessesMatchesLiveUninterruptedSuccessor) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    PLUTO_SKIP_EXACT_COLOR_FIXTURES();
  }

  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      ("pluto-exact-color-process-" + std::to_string(::getpid()));
  std::filesystem::remove_all(root);
  ASSERT_TRUE(std::filesystem::create_directories(root));
  const std::string handoff = (root / "warm.bundle").string();
  const std::string reference_handoff = (root / "reference.bundle").string();
  const std::string outgoing_result = (root / "outgoing.result").string();
  const std::string incoming_result = (root / "incoming.result").string();
  const std::string reference_result = (root / "reference.result").string();

  ASSERT_TRUE(run_exact_color_child([&] {
    return run_exact_color_process(ExactColorProcessMode::kOutgoing, handoff,
                                   outgoing_result);
  }));
  ExactColorProcessOutcome outgoing;
  ASSERT_TRUE(read_exact_color_outcome(outgoing_result, &outgoing));
  EXPECT_EQ(outgoing.cold_clear_mode, 2);
  EXPECT_EQ(outgoing.color_faults, 0u);
  EXPECT_EQ(outgoing.bundle_written, 1u);

  RawExactColorBundle outgoing_bundle;
  ASSERT_TRUE(load_raw_exact_color_bundle(handoff, &outgoing_bundle));
  const std::span<const std::uint8_t> outgoing_history =
      outgoing_bundle.section(pluto::GlassHandoffSection::kXochitlHistory);
  ExactColorHistoryPair history_pair;
  ASSERT_TRUE(
      read_exact_color_history_pair(outgoing_history, kExactColorHistoryProbeA,
                                    kExactColorHistoryProbeB, &history_pair));
  EXPECT_EQ(history_pair.a0, 28u);
  EXPECT_EQ(history_pair.b0, 864u);
  EXPECT_EQ(history_pair.a1, static_cast<std::uint16_t>(0x80u | 28u));
  EXPECT_EQ(history_pair.b1, 0u);
  EXPECT_EQ(history_pair.a0 & 31u, history_pair.a1 & 31u);
  EXPECT_TRUE(history_pair.a0 != history_pair.a1 ||
              history_pair.b0 != history_pair.b1);
  const std::size_t guard_offset = static_cast<std::size_t>(kLogicalWidth) * 4u;
  ASSERT_GE(outgoing_history.size(), guard_offset + 4u);
  const std::uint16_t outgoing_guard_a = static_cast<std::uint16_t>(
      outgoing_history[guard_offset] |
      static_cast<std::uint16_t>(outgoing_history[guard_offset + 1u]) << 8u);
  const std::uint16_t outgoing_guard_b = static_cast<std::uint16_t>(
      outgoing_history[guard_offset + 2u] |
      static_cast<std::uint16_t>(outgoing_history[guard_offset + 3u]) << 8u);

  pluto::RendererHandoffState outgoing_renderer;
  ASSERT_TRUE(pluto::renderer_handoff_decode(
      outgoing_bundle.section(pluto::GlassHandoffSection::kRenderer),
      outgoing_bundle.renderer_configuration_hash, &outgoing_renderer));
  ASSERT_EQ(outgoing_renderer.width, static_cast<std::uint32_t>(kLogicalWidth));
  ASSERT_EQ(outgoing_renderer.height,
            static_cast<std::uint32_t>(kLogicalHeight));
  ASSERT_EQ(outgoing_renderer.retained_frame.size(),
            static_cast<std::size_t>(kLogicalWidth) * kLogicalHeight * 2u);
  const std::size_t same_luma_offset =
      (static_cast<std::size_t>(192) * kLogicalWidth + 64u) * 2u;
  EXPECT_EQ(outgoing_renderer.retained_frame[same_luma_offset], 0x3bu);
  EXPECT_EQ(outgoing_renderer.retained_frame[same_luma_offset + 1u], 0x02u);
  EXPECT_TRUE(std::any_of(outgoing_renderer.frame_ledger.chroma_bits.begin(),
                          outgoing_renderer.frame_ledger.chroma_bits.end(),
                          [](std::uint8_t byte) { return byte != 0u; }));
  EXPECT_TRUE(std::any_of(outgoing_renderer.auto_ghostbuster.ghost.debt.begin(),
                          outgoing_renderer.auto_ghostbuster.ghost.debt.end(),
                          [](std::uint16_t debt) { return debt != 0u; }));
  ASSERT_TRUE(run_exact_color_child([&] {
    return run_exact_color_process(ExactColorProcessMode::kIncoming, handoff,
                                   incoming_result, history_pair);
  }));
  ExactColorProcessOutcome incoming;
  ASSERT_TRUE(read_exact_color_outcome(incoming_result, &incoming));
  EXPECT_EQ(incoming.cold_clear_mode, -1)
      << "accepted correlated state must skip the INIT/cold-clear rail";
  EXPECT_EQ(incoming.color_faults, 0u);
  EXPECT_EQ(incoming.reset_rejected_before_resume, 1u);
  EXPECT_EQ(incoming.seed_present_before_resume, 1u);
  EXPECT_EQ(incoming.seed_unlinked_on_first_admission, 1u);
  EXPECT_EQ(incoming.bundle_written, 1u);
  EXPECT_EQ(incoming.imported_a0, history_pair.a0);
  EXPECT_EQ(incoming.imported_b0, history_pair.b0);
  EXPECT_EQ(incoming.imported_a1, history_pair.a1);
  EXPECT_EQ(incoming.imported_b1, history_pair.b1);
  EXPECT_EQ(incoming.imported_guard_a, outgoing_guard_a);
  EXPECT_EQ(incoming.imported_guard_b, outgoing_guard_b);

  ASSERT_TRUE(!std::filesystem::exists(reference_handoff));
  ASSERT_TRUE(run_exact_color_child([&] {
    return run_exact_color_process(ExactColorProcessMode::kUninterruptedOracle,
                                   reference_handoff, reference_result);
  }));
  ExactColorProcessOutcome reference;
  ASSERT_TRUE(read_exact_color_outcome(reference_result, &reference));
  EXPECT_EQ(reference.cold_clear_mode, 2)
      << "the oracle must build its history from a real cold start, not import "
         "the bundle under test";
  EXPECT_EQ(reference.color_faults, 0u);
  EXPECT_EQ(reference.seed_present_before_resume, 0u);
  EXPECT_EQ(reference.seed_unlinked_on_first_admission, 0u);
  EXPECT_EQ(reference.bundle_written, 1u);

  // Warm resume deliberately supplied a false 1x1 paint hint while changing
  // two disjoint color regions. The first seeded pass must find exactly the
  // same dirty decision and optical successor as the truly uninterrupted
  // live-state oracle supplied with honest bounds.
  EXPECT_EQ(incoming.resume_damage_count, reference.resume_damage_count);
  EXPECT_EQ(incoming.resume_glass_hash, reference.resume_glass_hash);
  EXPECT_EQ(incoming.resume_dc_hash, reference.resume_dc_hash);
  EXPECT_EQ(incoming.resume_stress_hash, reference.resume_stress_hash);
  EXPECT_TRUE(incoming.resume_a == reference.resume_a);
  EXPECT_TRUE(incoming.resume_b == reference.resume_b);

  RawExactColorBundle incoming_bundle;
  RawExactColorBundle reference_bundle;
  ASSERT_TRUE(load_raw_exact_color_bundle(handoff, &incoming_bundle));
  ASSERT_TRUE(
      load_raw_exact_color_bundle(reference_handoff, &reference_bundle));
  const auto sections_equal = [&](pluto::GlassHandoffSection section) {
    const std::span<const std::uint8_t> actual =
        incoming_bundle.section(section);
    const std::span<const std::uint8_t> expected =
        reference_bundle.section(section);
    return actual.size() == expected.size() &&
           std::equal(actual.begin(), actual.end(), expected.begin());
  };
  EXPECT_TRUE(sections_equal(pluto::GlassHandoffSection::kEngineDc));
  EXPECT_TRUE(sections_equal(pluto::GlassHandoffSection::kEngineStress));
  EXPECT_TRUE(sections_equal(pluto::GlassHandoffSection::kEngineRescan));
  EXPECT_TRUE(sections_equal(pluto::GlassHandoffSection::kXochitlHistory));

  pluto::RendererHandoffState incoming_renderer;
  pluto::RendererHandoffState reference_renderer;
  ASSERT_TRUE(pluto::renderer_handoff_decode(
      incoming_bundle.section(pluto::GlassHandoffSection::kRenderer),
      incoming_bundle.renderer_configuration_hash, &incoming_renderer));
  ASSERT_TRUE(pluto::renderer_handoff_decode(
      reference_bundle.section(pluto::GlassHandoffSection::kRenderer),
      reference_bundle.renderer_configuration_hash, &reference_renderer));
  EXPECT_TRUE(incoming_renderer.retained_frame ==
              reference_renderer.retained_frame);
  EXPECT_TRUE(incoming_renderer.frame_ledger.levels ==
              reference_renderer.frame_ledger.levels);
  EXPECT_TRUE(incoming_renderer.frame_ledger.chroma_bits ==
              reference_renderer.frame_ledger.chroma_bits);
  EXPECT_TRUE(incoming_renderer.chroma_pending.pending ==
              reference_renderer.chroma_pending.pending);
  EXPECT_TRUE(incoming_renderer.ghost_ledger.owed ==
              reference_renderer.ghost_ledger.owed);
  EXPECT_TRUE(incoming_renderer.stress_ledger.stress ==
              reference_renderer.stress_ledger.stress);
  EXPECT_TRUE(sections_equal(pluto::GlassHandoffSection::kRenderer))
      << "every canonical decision-bearing renderer field must match the "
         "uninterrupted successor, not just retained pixels";

  std::filesystem::remove_all(root);
}

TEST(Gallery3DrmPresenterTest,
     ExactColorHandoffRefusesPendingMappedWorkAndRemovesSeed) {
  const std::filesystem::path eink(PLUTO_SWTCON_EINK_FIXTURE);
  const std::filesystem::path directory = eink.parent_path();
  if (!std::filesystem::exists(eink) ||
      !std::filesystem::exists(directory / "ct33_std.bin") ||
      !std::filesystem::exists(directory / "ct33_best.bin") ||
      !std::filesystem::exists(directory / "ct33_pen.bin") ||
      !std::filesystem::exists(directory / "ct33_fast.bin")) {
    PLUTO_SKIP_EXACT_COLOR_FIXTURES();
  }
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_color_pending_handoff_" +
                              std::to_string(::getpid()) + ".bin";
  discard_handoff_path(handoff);
  std::string options = installed_color_handoff_options(handoff);
  const std::size_t flip = options.find("flip_interval_ms=0");
  ASSERT_NE(flip, std::string::npos);
  options.replace(flip, std::strlen("flip_interval_ms=0"),
                  "flip_interval_ms=20");
  {
    Presenter seed(options);
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(), kPlutoStatusOk);
  }
  ASSERT_TRUE(std::filesystem::exists(handoff));

  {
    Presenter incoming(options);
    ASSERT_EQ(incoming.open_status(), kPlutoStatusOk);
    ASSERT_EQ(incoming.confirm_incoming_handoff(), kPlutoStatusOk);
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!incoming.ops()->ready(incoming.raw(), kPlutoRefreshFull) &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(incoming.ops()->ready(incoming.raw(), kPlutoRefreshFull));
    fill_rgb565(incoming.frame(), 0xf800u);
    ASSERT_EQ(
        incoming.present_once(kPlutoRefreshFull, PlutoRect{64, 64, 96, 96}, 91),
        kPlutoStatusOk);
    EXPECT_NE(incoming.stage_handoff({}, 0), kPlutoStatusOk)
        << "mapped preprocessing/engine/scan work must refuse staging";
    incoming.close_now();
  }
  EXPECT_FALSE(std::filesystem::exists(handoff))
      << "interrupted exact-color work must not recreate its consumed seed";
  discard_handoff_path(handoff);
}

// A close that interrupts accepted work must invalidate the consumed seed.
// PixelEngine advances its logical planes while building, so persisting them
// merely because cold-clear completed would let the next process skip its
// clear against phases that never reached the panel.
TEST(Gallery3DrmPresenterTest,
     WarmGlassHandoffIsRemovedWhenCloseInterruptsPendingWork) {
  const std::string eink = write_synth_eink(20, "handoff_pending_close");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_pending_" +
                              std::to_string(::getpid()) + ".bin";
  std::remove(handoff.c_str());
  const std::string options =
      "dry_run=1,flip_interval_ms=20,stats_log_s=0,handoff=" + handoff +
      ",eink=" + eink;
  {
    Presenter seed(options);
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(), kPlutoStatusOk);
  }

  {
    Presenter p(options);
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);
    ASSERT_EQ(p.confirm_incoming_handoff(), kPlutoStatusOk);
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!p.ops()->ready(p.raw(), kPlutoRefreshText) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshText));
    fill_rgb565(p.frame(), 0x0000);
    ASSERT_EQ(p.present_once(kPlutoRefreshText, Presenter::kFullScreen, 1),
              kPlutoStatusOk);
    p.close_now();
  }
  EXPECT_FALSE(std::filesystem::exists(handoff))
      << "interrupted work must not recreate the consumed handoff seed";
  std::remove(handoff.c_str());
  std::remove(eink.c_str());
}

// Engine completion is build completion, not optical completion. Simulate a
// successful DRM commit whose flip event never arrives: queues and engine are
// idle, but ScanReadySlot remains unacknowledged, so close must fail closed
// instead of saving the build-ahead prev plane.
TEST(Gallery3DrmPresenterTest,
     WarmGlassHandoffRequiresFinalScanLatchAcknowledgement) {
  const std::string eink = write_synth_eink(1, "handoff_latch_close");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_latch_" +
                              std::to_string(::getpid()) + ".bin";
  std::remove(handoff.c_str());
  {
    auto seed_drm = std::make_unique<RecordingDrm>();
    pluto::swtcon::set_drm_interface_for_testing(std::move(seed_drm));
    Presenter seed("flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
                   ",eink=" + eink + ",scan_period_ns=2000000");
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(), kPlutoStatusOk);
  }

  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
  {
    Presenter p("flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
                ",eink=" + eink + ",scan_period_ns=2000000");
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);
    ASSERT_EQ(p.confirm_incoming_handoff(), kPlutoStatusOk);
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!p.ops()->ready(p.raw(), kPlutoRefreshText) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshText));

    // Snapshot after initialization/cold-clear handling. A pre-existing
    // content flip must not satisfy the post-present wait below, and the
    // scripted loss must be observed as consumed rather than merely armed.
    const std::size_t baseline_content_flips = drm_raw->content_flip_count();
    const std::size_t baseline_dropped_events =
        drm_raw->dropped_content_event_count();
    drm_raw->drop_next_content_event();
    ASSERT_TRUE(drm_raw->drop_next_content_event_pending());
    fill_rgb565(p.frame(), 0x0000);
    ASSERT_EQ(p.present_once(kPlutoRefreshText, PlutoRect{8, 8, 32, 32}, 7),
              kPlutoStatusOk);
    const auto completion_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (
        (p.log().calls.load(std::memory_order_acquire) == 0 ||
         drm_raw->content_flip_count() <= baseline_content_flips ||
         drm_raw->dropped_content_event_count() <= baseline_dropped_events) &&
        std::chrono::steady_clock::now() < completion_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_EQ(p.log().calls.load(std::memory_order_acquire), 1);
    ASSERT_GT(drm_raw->content_flip_count(), baseline_content_flips);
    ASSERT_EQ(drm_raw->dropped_content_event_count(),
              baseline_dropped_events + 1);
    ASSERT_TRUE(!drm_raw->drop_next_content_event_pending());
    EXPECT_EQ(p.ops()->wait_idle(p.raw(), 0), kPlutoStatusTimeout);
    EXPECT_NE(p.stage_handoff({}, 20), kPlutoStatusOk);
    p.close_now();
  }
  EXPECT_FALSE(std::filesystem::exists(handoff))
      << "an unacknowledged final phase is not safe handoff state";
  std::remove(handoff.c_str());
  std::remove(eink.c_str());
}

// Engine/queue/latch idleness still is not enough for a warm handoff. A
// sparse pen-priority update may preempt an in-flight quality pass, complete
// the changed pixel, and leave same-target pixels' prev values estimated.
// close() must reject that idle but optically inexact plane.
TEST(Gallery3DrmPresenterTest,
     WarmGlassHandoffRejectsIdleSparsePenPreemptionEstimate) {
  const std::string eink = write_synth_eink(8, "handoff_prev_est_close");
  const std::string handoff = std::filesystem::temp_directory_path().string() +
                              "/pluto_handoff_prev_est_" +
                              std::to_string(::getpid()) + ".bin";
  std::remove(handoff.c_str());
  {
    auto seed_drm = std::make_unique<RecordingDrm>();
    pluto::swtcon::set_drm_interface_for_testing(std::move(seed_drm));
    Presenter seed("flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
                   ",eink=" + eink + ",scan_period_ns=2000000");
    ASSERT_EQ(seed.open_status(), kPlutoStatusOk);
    ASSERT_EQ(seed.ops()->wait_idle(seed.raw(), 30000), kPlutoStatusOk);
    ASSERT_EQ(seed.stage_handoff(), kPlutoStatusOk);
  }

  auto drm = std::make_unique<RecordingDrm>();
  RecordingDrm *drm_raw = drm.get();
  pluto::swtcon::set_drm_interface_for_testing(std::move(drm));
  {
    Presenter p("flip_interval_ms=0,stats_log_s=0,handoff=" + handoff +
                ",eink=" + eink + ",scan_period_ns=2000000");
    ASSERT_EQ(p.open_status(), kPlutoStatusOk);
    ASSERT_EQ(p.confirm_incoming_handoff(), kPlutoStatusOk);
    const auto ready_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!p.ops()->ready(p.raw(), kPlutoRefreshFull) &&
           std::chrono::steady_clock::now() < ready_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(p.ops()->ready(p.raw(), kPlutoRefreshFull));

    const PlutoRect stroke{32, 32, 32, 32};
    fill_rgb565(p.frame(), 0x0000);
    drm_raw->hold_next_content_flip();
    ASSERT_EQ(p.present_once(kPlutoRefreshFull, stroke, 10), kPlutoStatusOk);
    const bool quality_phase_blocked = drm_raw->wait_until_content_flip_blocked(
        std::chrono::milliseconds(10000));
    if (!quality_phase_blocked) {
      drm_raw->release_held_content_flip();
      EXPECT_TRUE(quality_phase_blocked)
          << "in-flight quality phase was never consumed";
      p.close_now();
      std::remove(handoff.c_str());
      std::remove(eink.c_str());
      return;
    }

    // Same black target everywhere except one white pixel: the differing
    // pixel defeats value-equal absorption and triggers cross-mode preempt;
    // only that pixel gets a replacement waveform to clear its estimate.
    store_rgb565(p.frame(), stroke.x, stroke.y, 0xffff);
    const PlutoStatus preview_status = p.present_once(
        kPlutoRefreshText, stroke, 11, kPlutoPresentFlagInkPriority);
    if (preview_status != kPlutoStatusOk) {
      drm_raw->release_held_content_flip();
      EXPECT_EQ(preview_status, kPlutoStatusOk);
      p.close_now();
      std::remove(handoff.c_str());
      std::remove(eink.c_str());
      return;
    }

    const auto preempt_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (p.stats().pen_cross_mode_preemptions == 0 &&
           std::chrono::steady_clock::now() < preempt_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const bool preempted = p.stats().pen_cross_mode_preemptions == 1;
    drm_raw->release_held_content_flip();
    if (!preempted) {
      EXPECT_TRUE(preempted) << "sparse preview did not preempt quality";
      p.close_now();
      std::remove(handoff.c_str());
      std::remove(eink.c_str());
      return;
    }

    ASSERT_EQ(p.ops()->wait_idle(p.raw(), 30000), kPlutoStatusOk);
    EXPECT_NE(p.stage_handoff(), kPlutoStatusOk);
    p.close_now();
  }
  EXPECT_FALSE(std::filesystem::exists(handoff))
      << "idle estimated pixels must invalidate warm handoff";
  std::remove(handoff.c_str());
  std::remove(eink.c_str());
}
