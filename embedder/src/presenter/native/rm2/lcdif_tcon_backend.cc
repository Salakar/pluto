#include "presenter/native/rm2/lcdif_tcon_backend.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <sys/stat.h>
#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#include <sys/vfs.h>
#endif
#include <unistd.h>

#include "presenter/native/rm2/rm2_scan_encoder.h"
#include "presenter/native/rm2/rm2_waveform_program.h"

namespace pluto::native::rm2 {
namespace {

constexpr std::string_view kDriverName = "lcdif_tcon";
constexpr std::size_t kBytesPerPixel = 2;
constexpr std::size_t kMaximumDamageRects = 64;
constexpr std::uint32_t kHandoffTilePixels = 32;
constexpr std::uint32_t kHandoffEngineStride =
    (kRm2PanelWidth + 7u) & ~std::uint32_t{7};
constexpr std::size_t kMaximumRendererHandoffBytes = 32u << 20;
constexpr std::string_view kHandoffPipelineTag = "pluto-rm2-lcdif-warm-handoff";
constexpr std::uint32_t kKnownPresentFlags =
    kPlutoPresentFlagInkPriority | kPlutoPresentFlagPreDithered |
    kPlutoPresentFlagSettle | kPlutoPresentFlagSparkle |
    kPlutoPresentFlagSparkleDevelop | kPlutoPresentFlagPixelResetBlack |
    kPlutoPresentFlagPixelResetWhite | kPlutoPresentFlagPixelResetRestore |
    kPlutoPresentFlagRequiredSettle | kPlutoPresentFlagPenTruth |
    kPlutoPresentSparklePhaseMask;
constexpr std::size_t kEncodeHistogramBuckets = 20'000;
constexpr int kMaximumBurstTemperatureMillidegrees = 45'000;

static_assert(kHandoffEngineStride == 1408u);

bool configure_present_worker() noexcept {
#if defined(__linux__) && defined(__arm__)
  (void)pthread_setname_np(pthread_self(), "rm2-present");
  sched_param policy{};
  policy.sched_priority = 60;
  const int policy_error =
      pthread_setschedparam(pthread_self(), SCHED_FIFO, &policy);
  cpu_set_t affinity;
  CPU_ZERO(&affinity);
  CPU_SET(0, &affinity);
  const int affinity_error = sched_setaffinity(0, sizeof(affinity), &affinity);
  return policy_error == 0 && affinity_error == 0;
#elif defined(__linux__)
  (void)pthread_setname_np(pthread_self(), "rm2-present");
  return true;
#else
  return true;
#endif
}

Rm2CpuFrequencyLeasePaths
cpu_frequency_paths(const GeneratedDeviceProfile &profile,
                    const Rm2HandoffOptions &options) {
  if (options.allow_insecure_path_for_testing &&
      options.cpu_frequency_paths_for_testing.has_value()) {
    return *options.cpu_frequency_paths_for_testing;
  }
#if defined(__linux__) && defined(__arm__)
  if (profile.id == "rm2" &&
      profile.display_driver == NativeDisplayDriverKind::kLcdifTcon &&
      profile.target_slice == DeviceTargetSlice::kLinuxArm &&
      profile.panel.width == static_cast<int>(kRm2PanelWidth) &&
      profile.panel.height == static_cast<int>(kRm2PanelHeight) &&
      !profile.panel.color) {
    return {
        .policy_path = kRm2CpuPolicyPath,
        .receipt_path = kRm2CpuReceiptPath,
        .lock_path = kRm2CpuLockPath,
        .cpu_thermal_type_path = kRm2CpuThermalTypePath,
        .cpu_temperature_path = kRm2CpuTemperaturePath,
    };
  }
#else
  (void)profile;
#endif
  return {};
}

enum class HandoffDecision : std::uint8_t {
  kNone,
  kPending,
  kAccepted,
  kRejected,
};

class HandoffFingerprint final {
public:
  void add_u32(std::uint32_t value) {
    std::array<std::uint8_t, 4> bytes{};
    for (unsigned shift = 0; shift < 32; shift += 8) {
      bytes[shift / 8] = static_cast<std::uint8_t>(value >> shift);
    }
    add(bytes);
  }

  void add_u64(std::uint64_t value) {
    std::array<std::uint8_t, 8> bytes{};
    for (unsigned shift = 0; shift < 64; shift += 8) {
      bytes[shift / 8] = static_cast<std::uint8_t>(value >> shift);
    }
    add(bytes);
  }

  void add_bool(bool value) { add_u32(value ? 1u : 0u); }

  void add_string(std::string_view value) {
    add_u64(value.size());
    add(std::span<const std::uint8_t>(
        reinterpret_cast<const std::uint8_t *>(value.data()), value.size()));
  }

  template <typename T> void add_optional(const std::optional<T> &value) {
    add_bool(value.has_value());
    if (value.has_value()) {
      add_u64(static_cast<std::uint64_t>(*value));
    }
  }

  std::uint64_t value() const { return value_; }

private:
  void add(std::span<const std::uint8_t> bytes) {
    value_ = glass_handoff_crc64(bytes, value_);
  }

  std::uint64_t value_ = 0;
};

bool production_handoff_path_is_secure(const std::string &path) {
  if (path != kGlassHandoffDefaultPath) {
    return false;
  }
#if defined(__linux__)
  constexpr const char *kDirectory = "/run/pluto";
  constexpr long kTmpfsMagic = 0x01021994;
  struct stat directory_stat {};
  struct statfs filesystem_stat {};
  return ::lstat(kDirectory, &directory_stat) == 0 &&
         S_ISDIR(directory_stat.st_mode) &&
         directory_stat.st_uid == ::geteuid() &&
         (directory_stat.st_mode & 0022) == 0 &&
         ::statfs(kDirectory, &filesystem_stat) == 0 &&
         static_cast<long>(filesystem_stat.f_type) == kTmpfsMagic;
#else
  return false;
#endif
}

std::uint64_t
waveform_descriptor_bytes(const GeneratedWaveformProfile &waveform) {
  std::uint64_t bytes = 0;
  for (const GeneratedWaveformSourceProfile &source :
       waveform.accepted_sources) {
    const std::array<std::string_view, 3> fields{source.path, source.sha256,
                                                 source.panel_signature};
    for (const std::string_view field : fields) {
      if (field.size() > std::numeric_limits<std::uint64_t>::max() - bytes) {
        return 0;
      }
      bytes += field.size();
    }
  }
  return bytes;
}

bool build_handoff_identity(const GeneratedDeviceProfile &profile,
                            GlassHandoffIdentity *out) {
  const GeneratedDisplayContract &display = profile.runtime.display;
  if (out == nullptr || profile.id != "rm2" ||
      profile.display_driver != NativeDisplayDriverKind::kLcdifTcon ||
      profile.target_slice != DeviceTargetSlice::kLinuxArm ||
      profile.panel.width != static_cast<int>(kRm2PanelWidth) ||
      profile.panel.height != static_cast<int>(kRm2PanelHeight) ||
      profile.panel.source_pixel_format != "rgb565" || profile.panel.color ||
      profile.runtime.firmware_build.empty() ||
      profile.runtime.kernel_release.empty() ||
      profile.runtime.waveform.accepted_sources.size() != 1 ||
      display.scanout_width != kRm2ScanoutWidth ||
      display.scanout_height != kRm2ScanoutHeight ||
      display.virtual_width != kRm2ScanoutWidth ||
      display.virtual_height != kRm2ScanoutHeight * kRm2MappedSlots ||
      display.stride_bytes != kRm2ScanoutStrideBytes ||
      display.buffer_slots != kRm2MappedSlots ||
      display.slot_bytes != kRm2SlotBytes ||
      !display.phase_interval_nanoseconds.has_value()) {
    return false;
  }

  HandoffFingerprint waveform;
  waveform.add_string("rm2-wbf-exact-profile");
  for (const GeneratedWaveformSourceProfile &source :
       profile.runtime.waveform.accepted_sources) {
    waveform.add_string(source.path);
    waveform.add_string(source.sha256);
    waveform.add_string(source.panel_signature);
  }

  HandoffFingerprint pipeline;
  pipeline.add_string(kHandoffPipelineTag);
  pipeline.add_string("physical-panel-row-major-u4-padded");
  pipeline.add_string("logical-tight-rgb565le");
  pipeline.add_string("canonical-idle-hold");
  pipeline.add_string(profile.id);
  pipeline.add_string(profile.wire_model);
  pipeline.add_string(profile.codename);
  pipeline.add_string(profile.tested_os);
  pipeline.add_string(profile.panel.signature);
  pipeline.add_string(profile.panel.source_pixel_format);
  pipeline.add_u32(static_cast<std::uint32_t>(profile.panel.width));
  pipeline.add_u32(static_cast<std::uint32_t>(profile.panel.height));
  pipeline.add_u32(static_cast<std::uint32_t>(profile.panel.dpi));
  pipeline.add_bool(profile.panel.color);
  pipeline.add_string(profile.runtime.firmware_build);
  pipeline.add_string(profile.runtime.kernel_release);
  pipeline.add_string(profile.runtime.display_device);
  pipeline.add_u32(display.scanout_width);
  pipeline.add_u32(display.scanout_height);
  pipeline.add_optional(display.virtual_width);
  pipeline.add_optional(display.virtual_height);
  pipeline.add_optional(display.stride_bytes);
  pipeline.add_optional(display.mapping_bytes);
  pipeline.add_u32(display.bits_per_pixel);
  pipeline.add_optional(display.rotation);
  pipeline.add_optional(display.buffer_slots);
  pipeline.add_optional(display.slot_bytes);
  pipeline.add_u32(display.damage_alignment_pixels);
  pipeline.add_optional(display.phase_interval_nanoseconds);
  pipeline.add_u32(kHandoffEngineStride);
  pipeline.add_u32(kHandoffTilePixels);
  for (const std::string_view value : profile.architectures) {
    pipeline.add_string(value);
  }
  for (const std::string_view value : profile.board_tokens) {
    pipeline.add_string(value);
  }
  for (const std::string_view value : profile.compatible_tokens) {
    pipeline.add_string(value);
  }

  const std::uint64_t waveform_bytes =
      waveform_descriptor_bytes(profile.runtime.waveform);
  if (waveform.value() == 0 || waveform_bytes == 0 || pipeline.value() == 0) {
    return false;
  }
  *out = {
      .flags = kGlassHandoffFlagNone,
      .profile = GlassHandoffProfile::kMonochrome,
      .width = static_cast<std::uint32_t>(kRm2PanelWidth),
      .height = static_cast<std::uint32_t>(kRm2PanelHeight),
      .pixel_format = static_cast<std::uint32_t>(kPlutoPixelFormatRgb565),
      .engine_stride = kHandoffEngineStride,
      .tile_px = kHandoffTilePixels,
      .history_stride = 0,
      .history_rows = 0,
      .history_pixel_bytes = 0,
      .waveform_hash = waveform.value(),
      .waveform_bytes = waveform_bytes,
      .ct33_hash = 0,
      .ct33_bytes = 0,
      .pipeline_hash = pipeline.value(),
  };
  return true;
}

bool refresh_class_valid(PlutoRefreshClass refresh_class) {
  switch (refresh_class) {
  case kPlutoRefreshFast:
  case kPlutoRefreshUi:
  case kPlutoRefreshText:
  case kPlutoRefreshFull:
    return true;
  }
  return false;
}

bool rect_valid(const PlutoRect &rect) {
  if (rect.x < 0 || rect.y < 0 || rect.width <= 0 || rect.height <= 0) {
    return false;
  }
  const std::uint32_t x = static_cast<std::uint32_t>(rect.x);
  const std::uint32_t y = static_cast<std::uint32_t>(rect.y);
  const std::uint32_t width = static_cast<std::uint32_t>(rect.width);
  const std::uint32_t height = static_cast<std::uint32_t>(rect.height);
  return x <= kRm2PanelWidth && y <= kRm2PanelHeight &&
         width <= kRm2PanelWidth - x && height <= kRm2PanelHeight - y;
}

std::uint64_t rect_union_area(std::span<const PlutoRect> rectangles) {
  struct Interval {
    std::int32_t begin = 0;
    std::int32_t end = 0;
  };
  std::array<std::int32_t, kMaximumDamageRects * 2U> x_edges{};
  std::size_t x_count = 0;
  for (const PlutoRect &rect : rectangles) {
    x_edges[x_count++] = rect.x;
    x_edges[x_count++] = rect.x + rect.width;
  }
  std::sort(x_edges.begin(),
            x_edges.begin() + static_cast<std::ptrdiff_t>(x_count));
  const auto unique_end = std::unique(
      x_edges.begin(), x_edges.begin() + static_cast<std::ptrdiff_t>(x_count));
  x_count = static_cast<std::size_t>(unique_end - x_edges.begin());

  std::uint64_t area = 0;
  std::array<Interval, kMaximumDamageRects> intervals{};
  for (std::size_t edge = 1; edge < x_count; ++edge) {
    const std::int32_t x_begin = x_edges[edge - 1U];
    const std::int32_t x_end = x_edges[edge];
    std::size_t interval_count = 0;
    for (const PlutoRect &rect : rectangles) {
      if (rect.x <= x_begin && rect.x + rect.width >= x_end) {
        intervals[interval_count++] = {
            .begin = rect.y,
            .end = rect.y + rect.height,
        };
      }
    }
    std::sort(intervals.begin(),
              intervals.begin() + static_cast<std::ptrdiff_t>(interval_count),
              [](const Interval &left, const Interval &right) {
                return left.begin < right.begin ||
                       (left.begin == right.begin && left.end < right.end);
              });
    std::int32_t covered_y = 0;
    if (interval_count != 0) {
      std::int32_t merged_begin = intervals[0].begin;
      std::int32_t merged_end = intervals[0].end;
      for (std::size_t index = 1; index < interval_count; ++index) {
        if (intervals[index].begin > merged_end) {
          covered_y += merged_end - merged_begin;
          merged_begin = intervals[index].begin;
          merged_end = intervals[index].end;
        } else {
          merged_end = std::max(merged_end, intervals[index].end);
        }
      }
      covered_y += merged_end - merged_begin;
    }
    area += static_cast<std::uint64_t>(x_end - x_begin) *
            static_cast<std::uint64_t>(covered_y);
  }
  return area;
}

bool parse_waveform_option(const char *options, std::string_view key,
                           std::string *out_path) {
  if (options == nullptr || out_path == nullptr || key.empty()) {
    return false;
  }
  const std::string_view value(options);
  const std::string prefix = std::string(key) + "=";
  if (!value.starts_with(prefix) || value.size() == prefix.size() ||
      value.find(',') != std::string_view::npos) {
    return false;
  }
  *out_path = std::string(value.substr(prefix.size()));
  return true;
}

} // namespace

std::uint64_t rm2_damage_union_area(std::span<const PlutoRect> rectangles) {
  return rect_union_area(rectangles);
}

class LcdifTconDisplayBackend::Impl final {
public:
  struct JobRegion {
    Rm2PanelRect panel_rect;
    std::size_t pixel_offset = 0;
  };

  struct Job {
    std::uint64_t frame_id = 0;
    std::array<JobRegion, kMaximumDamageRects> regions{};
    std::size_t region_count = 0;
    std::vector<std::uint8_t> transition_keys;
    std::vector<std::uint16_t> target_pixels;
    Rm2WaveformSelection waveform;
    bool suppress_unchanged = true;
  };

  Impl(const GeneratedDeviceProfile &profile,
       std::unique_ptr<MxsLcdifDevice> device,
       Rm2TemperatureReader temperature_reader,
       Rm2PowerReadyReader power_ready_reader, Rm2HandoffOptions handoff)
      : profile_(profile),
        device_(device == nullptr ? std::make_unique<MxsLcdifDevice>()
                                  : std::move(device)),
        temperature_reader_(temperature_reader
                                ? std::move(temperature_reader)
                                : read_rm2_panel_temperature_millidegrees),
        power_ready_reader_(
            power_ready_reader
                ? std::move(power_ready_reader)
                : [](std::string
                         *error) { return read_rm2_panel_power_ready(error); }),
        pan_worker_(
            [this](std::uint32_t slot, std::chrono::nanoseconds *out_duration) {
              return device_->pan(slot, out_duration) == kPlutoStatusOk;
            }),
        cpu_frequency_lease_(cpu_frequency_paths(profile, handoff)),
        cpu_frequency_debounce_(handoff.cpu_frequency_debounce_for_testing),
        phase_encode_delay_for_testing_(handoff.phase_encode_delay_for_testing),
        handoff_path_(std::move(handoff.path)),
        handoff_now_(handoff.now_for_testing == nullptr
                         ? glass_handoff_now
                         : handoff.now_for_testing) {
    const bool production_route =
        production_handoff_path_is_secure(handoff_path_);
    handoff_route_enabled_ =
        !handoff_path_.empty() &&
        (handoff.allow_insecure_path_for_testing || production_route) &&
        build_handoff_identity(profile_, &handoff_identity_);
    if (!handoff_path_.empty() && !handoff_route_enabled_) {
      std::fprintf(stderr, "lcdif_tcon: warm handoff disabled for insecure or "
                           "incompatible route\n");
      handoff_path_.clear();
    }
    handoff_unlinked_ = !handoff_route_enabled_;
  }

  ~Impl() { stop(); }

  std::string_view driver_name() const { return kDriverName; }

  PlutoStatus probe(const GeneratedDeviceProfile &profile) {
    std::lock_guard<std::mutex> admission_lock(admission_mutex_);
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (&profile != &profile_ || started_ || stopping_ || lost_) {
        return lost_ ? kPlutoStatusDeviceLost : kPlutoStatusUnsupported;
      }
      if (probed_) {
        return kPlutoStatusOk;
      }
    }
    if (handoff_route_enabled_ && !handoff_lease_.valid() &&
        !glass_handoff_acquire_lease(handoff_path_, &handoff_lease_)) {
      return kPlutoStatusAgain;
    }
    const PlutoStatus status = device_->open(profile);
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (status == kPlutoStatusOk) {
      probed_ = true;
    } else {
      handoff_lease_ = GlassHandoffLease{};
      if (status == kPlutoStatusDeviceLost || status == kPlutoStatusInternal) {
        lost_ = true;
        ++hardware_faults_;
      }
    }
    return status;
  }

  PlutoStatus start(const PlutoPresenterConfig &config) {
    if (config.struct_size != sizeof(PlutoPresenterConfig) ||
        (config.backend_name != nullptr &&
         std::string_view(config.backend_name) != "native") ||
        !profile_.runtime.waveform_option_key.has_value()) {
      return kPlutoStatusInvalidArgument;
    }
    std::string waveform_path;
    if (!parse_waveform_option(config.options,
                               *profile_.runtime.waveform_option_key,
                               &waveform_path)) {
      return kPlutoStatusInvalidArgument;
    }

    std::lock_guard<std::mutex> admission_lock(admission_mutex_);
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (!probed_ || started_ || stopping_ || suspended_ || lost_) {
        return lost_ ? kPlutoStatusDeviceLost : kPlutoStatusInvalidArgument;
      }
    }

    std::string error;
    if (!waveforms_.open(profile_, waveform_path, &error)) {
      return kPlutoStatusUnsupported;
    }
    if (!phase_encoder_.ready() || !pan_worker_.ready()) {
      waveforms_.clear();
      return kPlutoStatusInternal;
    }
    try {
      reusable_job_.transition_keys.reserve(kRm2PanelWidth * kRm2PanelHeight);
      reusable_job_.target_pixels.reserve(kRm2PanelWidth * kRm2PanelHeight);
    } catch (const std::bad_alloc &) {
      waveforms_.clear();
      return kPlutoStatusInternal;
    }

    std::string frequency_error;
    if (!acquire_cpu_frequency_floor(&frequency_error)) {
      std::fprintf(stderr,
                   "lcdif_tcon: RM2 frequency guard acquire failed: "
                   "%s\n",
                   frequency_error.c_str());
      waveforms_.clear();
      device_->close();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }

    PlutoStatus status = device_->initialize();
    if (status != kPlutoStatusOk) {
      if (!release_cpu_frequency_floor(&frequency_error)) {
        std::fprintf(stderr,
                     "lcdif_tcon: RM2 frequency guard restore failed after "
                     "initialize: %s\n",
                     frequency_error.c_str());
        status = kPlutoStatusDeviceLost;
      }
      waveforms_.clear();
      observe_fault(status);
      return status;
    }
    for (std::uint32_t slot = 0; slot < kRm2MappedSlots; ++slot) {
      if (!fill_rm2_scan_slot(device_->slot(slot), 0)) {
        return fail_powered_start(kPlutoStatusInternal);
      }
    }
    if (device_->validate_safe_idle_scan() != kPlutoStatusOk) {
      return fail_powered_start(kPlutoStatusDeviceLost);
    }
    bool handoff_pending = false;
    const PlutoStatus handoff_status =
        prepare_incoming_handoff(&handoff_pending);
    if (handoff_status != kPlutoStatusOk) {
      return fail_powered_start(kPlutoStatusDeviceLost);
    }
    if (!handoff_pending && cold_initialize() != kPlutoStatusOk) {
      return fail_powered_start(kPlutoStatusDeviceLost);
    }
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      callback_ = config.on_complete;
      callback_user_data_ = config.user_data;
      accepting_ = !handoff_pending;
      started_ = true;
      stopping_ = false;
      worker_started_ = false;
      worker_configured_ = false;
      telemetry_emitted_ = false;
      telemetry_active_ = false;
    }
    try {
      worker_ = std::thread([this] { worker_main(); });
    } catch (...) {
      if (handoff_route_enabled_ && handoff_lease_.valid()) {
        (void)discard_handoff_locked();
      }
      clear_incoming_handoff_locked(HandoffDecision::kRejected);
      handoff_lease_ = GlassHandoffLease{};
      if (!release_cpu_frequency_floor(&frequency_error)) {
        std::fprintf(stderr,
                     "lcdif_tcon: RM2 frequency guard restore failed after "
                     "worker creation: %s\n",
                     frequency_error.c_str());
      }
      mark_lost();
      device_->close();
      waveforms_.clear();
      return kPlutoStatusInternal;
    }
    {
      std::unique_lock<std::mutex> lock(state_mutex_);
      worker_start_cv_.wait(lock, [this] { return worker_started_; });
      if (!worker_configured_) {
        lock.unlock();
        if (worker_.joinable()) {
          worker_.join();
        }
        if (handoff_route_enabled_ && handoff_lease_.valid()) {
          (void)discard_handoff_locked();
        }
        clear_incoming_handoff_locked(HandoffDecision::kRejected);
        handoff_lease_ = GlassHandoffLease{};
        if (!release_cpu_frequency_floor(&frequency_error)) {
          std::fprintf(stderr,
                       "lcdif_tcon: RM2 frequency guard restore failed after "
                       "worker setup: %s\n",
                       frequency_error.c_str());
        }
        (void)device_->blank_powerdown();
        device_->close();
        waveforms_.clear();
        std::lock_guard<std::mutex> failed_lock(state_mutex_);
        accepting_ = false;
        started_ = false;
        lost_ = true;
        ++hardware_faults_;
        return kPlutoStatusInternal;
      }
      telemetry_active_ = true;
      arm_cpu_frequency_release_locked();
    }
    work_cv_.notify_one();
    return kPlutoStatusOk;
  }

  PlutoStatus info(PlutoDisplayInfo *out_info) const {
    if (out_info == nullptr || out_info->struct_size != sizeof(*out_info)) {
      return kPlutoStatusInvalidArgument;
    }
    PlutoDisplayInfo result{};
    result.struct_size = sizeof(result);
    result.width = profile_.panel.width;
    result.height = profile_.panel.height;
    result.dpi = profile_.panel.dpi;
    result.preferred_format = kPlutoPixelFormatRgb565;
    result.is_color = false;
    result.controls_refresh_class = true;
    result.reports_completion = true;
    result.wants_pre_dithered = false;
    result.rect_alignment = 8;
    result.max_inflight_updates = 1;
    result.nominal_latency_ms[0] = 150;
    result.nominal_latency_ms[1] = 500;
    result.nominal_latency_ms[2] = 500;
    result.nominal_latency_ms[3] = 500;
    result.backend_quantizes_color = true;
    result.supports_overlap_supersession = false;
    *out_info = result;
    return kPlutoStatusOk;
  }

  PlutoStatus submit(const PlutoPresentRequest *request) {
    if (request == nullptr || request->struct_size != sizeof(*request)) {
      return kPlutoStatusInvalidArgument;
    }
    const PlutoStatus validation = validate_request(*request);
    if (validation != kPlutoStatusOk) {
      return validation;
    }
    if ((request->flags & kPlutoPresentFlagSparkle) != 0) {
      // RM2 has no sparse white top-off primitive. The presenter ABI requires
      // unsupported Sparkle maintenance to complete as an accepted no-op.
      // RegionScheduler installs its provisional inflight entry before this
      // call, so a synchronous callback is race-safe.
      std::lock_guard<std::mutex> admission_lock(admission_mutex_);
      PlutoPresentCompleteCallback callback = nullptr;
      void *callback_user_data = nullptr;
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (lost_) {
          return kPlutoStatusDeviceLost;
        }
        if (!started_ || !accepting_ || outstanding_) {
          return kPlutoStatusAgain;
        }
      }
      if (consume_handoff_before_admission_locked() != kPlutoStatusOk) {
        return kPlutoStatusDeviceLost;
      }
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (lost_ || !started_ || !accepting_ || outstanding_) {
          return lost_ ? kPlutoStatusDeviceLost : kPlutoStatusAgain;
        }
        callback = callback_;
        callback_user_data = callback_user_data_;
        ++completed_jobs_;
      }
      if (callback != nullptr) {
        callback(request->frame_id, callback_user_data);
      }
      return kPlutoStatusOk;
    }

    std::lock_guard<std::mutex> admission_lock(admission_mutex_);
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (lost_) {
        return kPlutoStatusDeviceLost;
      }
      if (!started_ || !accepting_ || outstanding_) {
        return kPlutoStatusAgain;
      }
    }
    if (consume_handoff_before_admission_locked() != kPlutoStatusOk) {
      return kPlutoStatusDeviceLost;
    }
    Job job;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (lost_ || !started_ || !accepting_ || outstanding_) {
        return lost_ ? kPlutoStatusDeviceLost : kPlutoStatusAgain;
      }
      outstanding_ = true;
      cpu_frequency_release_armed_ = false;
      job = std::move(reusable_job_);
    }
    work_cv_.notify_one();
    std::string frequency_error;
    if (!acquire_cpu_frequency_floor(&frequency_error)) {
      std::fprintf(stderr,
                   "lcdif_tcon: RM2 frequency guard acquire failed "
                   "before admission: %s\n",
                   frequency_error.c_str());
      (void)device_->blank_powerdown();
      finish_failed_admission(kPlutoStatusDeviceLost, std::move(job));
      return kPlutoStatusDeviceLost;
    }
    try {
      if (!build_job(*request, &job)) {
        (void)device_->blank_powerdown();
        if (!release_cpu_frequency_floor(&frequency_error)) {
          std::fprintf(stderr,
                       "lcdif_tcon: RM2 frequency guard restore failed after "
                       "admission: %s\n",
                       frequency_error.c_str());
        }
        finish_failed_admission(kPlutoStatusDeviceLost, std::move(job));
        return kPlutoStatusDeviceLost;
      }
    } catch (const std::bad_alloc &) {
      (void)device_->blank_powerdown();
      if (!release_cpu_frequency_floor(&frequency_error)) {
        std::fprintf(stderr,
                     "lcdif_tcon: RM2 frequency guard restore failed after "
                     "allocation failure: %s\n",
                     frequency_error.c_str());
      }
      finish_failed_admission(kPlutoStatusInternal, std::move(job));
      return kPlutoStatusInternal;
    }
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      pending_job_ = std::move(job);
    }
    work_cv_.notify_one();
    return kPlutoStatusOk;
  }

  bool ready(PlutoRefreshClass refresh_class) const {
    if (!refresh_class_valid(refresh_class)) {
      return false;
    }
    std::lock_guard<std::mutex> lock(state_mutex_);
    return started_ && accepting_ && !stopping_ && !suspended_ && !lost_ &&
           !outstanding_;
  }

  PlutoStatus wait_idle(std::uint32_t timeout_ms) {
    std::unique_lock<std::mutex> lock(state_mutex_);
    if (lost_) {
      return kPlutoStatusDeviceLost;
    }
    if (!outstanding_) {
      return kPlutoStatusOk;
    }
    if (timeout_ms == 0) {
      return kPlutoStatusTimeout;
    }
    const bool finished =
        idle_cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                          [this] { return !outstanding_ || lost_; });
    if (lost_) {
      return kPlutoStatusDeviceLost;
    }
    return finished && !outstanding_ ? kPlutoStatusOk : kPlutoStatusTimeout;
  }

  PlutoStatus snapshot(PlutoSurface *out_surface) const {
    if (out_surface == nullptr || out_surface->pixels == nullptr ||
        out_surface->width != profile_.panel.width ||
        out_surface->height != profile_.panel.height ||
        out_surface->format != kPlutoPixelFormatRgb565 ||
        out_surface->stride_bytes < kRm2PanelWidth * kBytesPerPixel) {
      return kPlutoStatusInvalidArgument;
    }
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (mirror_.size() != kRm2PanelWidth * kRm2PanelHeight) {
      return kPlutoStatusDeviceLost;
    }
    auto *output = const_cast<std::uint8_t *>(out_surface->pixels);
    for (std::size_t row = 0; row < kRm2PanelHeight; ++row) {
      std::memcpy(output + row * out_surface->stride_bytes,
                  mirror_.data() + row * kRm2PanelWidth,
                  kRm2PanelWidth * kBytesPerPixel);
    }
    return kPlutoStatusOk;
  }

  PlutoStatus set_pen_focus(const PlutoPenFocus *focus) const {
    if (focus == nullptr || focus->struct_size != sizeof(*focus) ||
        (focus->flags & ~(kPlutoPenFocusInRange | kPlutoPenFocusContact)) !=
            0 ||
        ((focus->flags & kPlutoPenFocusContact) != 0 &&
         (focus->flags & kPlutoPenFocusInRange) == 0) ||
        ((focus->flags & kPlutoPenFocusInRange) != 0 &&
         !rect_valid(focus->rect))) {
      return kPlutoStatusInvalidArgument;
    }
    return kPlutoStatusOk;
  }

  PlutoStatus stage_handoff(const PlutoHandoffPayload *payload,
                            std::uint32_t timeout_ms) {
    if (!handoff_route_enabled_) {
      return kPlutoStatusUnsupported;
    }
    if (payload == nullptr ||
        payload->struct_size != sizeof(PlutoHandoffPayload) ||
        payload->bytes == nullptr || payload->byte_count == 0 ||
        payload->byte_count > kMaximumRendererHandoffBytes ||
        payload->width != profile_.panel.width ||
        payload->height != profile_.panel.height ||
        payload->pixel_format != kPlutoPixelFormatRgb565 ||
        payload->configuration_hash == 0 ||
        (payload->rotation != 0 && payload->rotation != 90 &&
         payload->rotation != 180 && payload->rotation != 270)) {
      return kPlutoStatusInvalidArgument;
    }

    std::lock_guard<std::mutex> admission_lock(admission_mutex_);
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (lost_) {
        return kPlutoStatusDeviceLost;
      }
      if (!started_ || stopping_ || handoff_saved_) {
        return kPlutoStatusAgain;
      }
      accepting_ = false;
    }
    const PlutoStatus idle_status = wait_idle(timeout_ms);
    if (idle_status != kPlutoStatusOk) {
      return idle_status == kPlutoStatusDeviceLost ? idle_status
                                                   : kPlutoStatusAgain;
    }
    if (device_->validate_safe_idle_scan() != kPlutoStatusOk) {
      (void)discard_handoff_locked();
      (void)device_->blank_powerdown();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }
    if (handoff_chain_next_ >= kGlassHandoffMaxChain) {
      if (discard_handoff_locked()) {
        return kPlutoStatusAgain;
      }
      mark_lost();
      return kPlutoStatusDeviceLost;
    }

    GlassHandoffBundle bundle;
    bundle.identity = handoff_identity_;
    bundle.renderer = {
        .width = static_cast<std::uint32_t>(payload->width),
        .height = static_cast<std::uint32_t>(payload->height),
        .rotation = payload->rotation,
        .pixel_format = static_cast<std::uint32_t>(payload->pixel_format),
        .configuration_hash = payload->configuration_hash,
    };
    bundle.written = handoff_now_();
    bundle.chain = handoff_chain_next_;
    try {
      bundle.renderer_payload.assign(payload->bytes,
                                     payload->bytes + payload->byte_count);
      std::lock_guard<std::mutex> frame_lock(frame_mutex_);
      if (!pack_handoff_state_locked(&bundle)) {
        (void)discard_handoff_locked();
        (void)device_->blank_powerdown();
        mark_lost();
        return kPlutoStatusDeviceLost;
      }
    } catch (const std::bad_alloc &) {
      if (discard_handoff_locked()) {
        return kPlutoStatusAgain;
      }
      mark_lost();
      return kPlutoStatusDeviceLost;
    }

    if (!glass_handoff_save(handoff_lease_, handoff_path_, bundle)) {
      if (discard_handoff_locked()) {
        return kPlutoStatusAgain;
      }
      mark_lost();
      return kPlutoStatusDeviceLost;
    }
    handoff_saved_ = true;
    handoff_unlinked_ = false;
    incoming_handoff_claim_ = {};
    incoming_renderer_payload_.clear();
    incoming_renderer_info_ = {};
    handoff_decision_ = HandoffDecision::kNone;
    std::fprintf(stderr,
                 "lcdif_tcon: warm handoff saved chain=%u renderer_bytes=%zu "
                 "presenter_bytes=%zu\n",
                 bundle.chain, bundle.renderer_payload.size(),
                 bundle.presenter_payload.size());
    return kPlutoStatusOk;
  }

  PlutoStatus get_handoff(PlutoHandoffPayload *out_payload) {
    if (!handoff_route_enabled_) {
      return kPlutoStatusUnsupported;
    }
    if (out_payload == nullptr ||
        out_payload->struct_size != sizeof(PlutoHandoffPayload)) {
      return kPlutoStatusInvalidArgument;
    }
    std::lock_guard<std::mutex> admission_lock(admission_mutex_);
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (lost_) {
      return kPlutoStatusDeviceLost;
    }
    if (!started_ || stopping_ ||
        handoff_decision_ != HandoffDecision::kPending ||
        incoming_renderer_payload_.empty()) {
      return kPlutoStatusAgain;
    }
    *out_payload = {
        .struct_size = sizeof(PlutoHandoffPayload),
        .bytes = incoming_renderer_payload_.data(),
        .byte_count = incoming_renderer_payload_.size(),
        .width = static_cast<std::int32_t>(incoming_renderer_info_.width),
        .height = static_cast<std::int32_t>(incoming_renderer_info_.height),
        .rotation = incoming_renderer_info_.rotation,
        .pixel_format =
            static_cast<PlutoPixelFormat>(incoming_renderer_info_.pixel_format),
        .configuration_hash = incoming_renderer_info_.configuration_hash,
    };
    return kPlutoStatusOk;
  }

  PlutoStatus confirm_handoff(bool accepted) {
    if (!handoff_route_enabled_) {
      return kPlutoStatusUnsupported;
    }
    std::lock_guard<std::mutex> admission_lock(admission_mutex_);
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (lost_) {
        return kPlutoStatusDeviceLost;
      }
      if (!started_ || stopping_ ||
          handoff_decision_ != HandoffDecision::kPending) {
        return kPlutoStatusAgain;
      }
    }

    if (!accepted) {
      if (!discard_handoff_locked()) {
        mark_lost();
        return kPlutoStatusDeviceLost;
      }
      clear_incoming_handoff_locked(HandoffDecision::kRejected);
      if (cold_initialize() != kPlutoStatusOk) {
        device_->close();
        mark_lost();
        return kPlutoStatusDeviceLost;
      }
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        accepting_ = true;
      }
      return kPlutoStatusOk;
    }

    if (device_->validate_safe_idle_scan() != kPlutoStatusOk) {
      (void)discard_handoff_locked();
      clear_incoming_handoff_locked(HandoffDecision::kRejected);
      (void)device_->blank_powerdown();
      device_->close();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }
    {
      std::lock_guard<std::mutex> frame_lock(frame_mutex_);
      if (incoming_settled_levels_.size() != kRm2PanelWidth * kRm2PanelHeight ||
          incoming_mirror_.size() != kRm2PanelWidth * kRm2PanelHeight) {
        (void)discard_handoff_locked();
        clear_incoming_handoff_locked(HandoffDecision::kRejected);
        (void)device_->blank_powerdown();
        device_->close();
        mark_lost();
        return kPlutoStatusDeviceLost;
      }
      settled_levels_ = std::move(incoming_settled_levels_);
      mirror_ = std::move(incoming_mirror_);
    }
    incoming_renderer_payload_.clear();
    incoming_renderer_info_ = {};
    handoff_decision_ = HandoffDecision::kAccepted;
    warm_handoff_accepted_ = true;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      accepting_ = true;
    }
    std::fprintf(stderr, "lcdif_tcon: warm handoff accepted; INIT skipped\n");
    return kPlutoStatusOk;
  }

  PlutoStatus suspend(std::uint32_t timeout_ms) {
    {
      std::lock_guard<std::mutex> admission_lock(admission_mutex_);
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (lost_) {
        return kPlutoStatusDeviceLost;
      }
      accepting_ = false;
    }
    const PlutoStatus idle_status = wait_idle(timeout_ms);
    if (idle_status != kPlutoStatusOk) {
      return idle_status;
    }
    stop();
    std::lock_guard<std::mutex> lock(state_mutex_);
    suspended_ = true;
    return kPlutoStatusOk;
  }

  NativeBackendHealth health() const {
    std::lock_guard<std::mutex> lock(state_mutex_);
    const bool busy = outstanding_ || (started_ && !accepting_);
    return {
        .state = lost_ ? NativeBackendHealthState::kDeviceLost
                       : (busy ? NativeBackendHealthState::kBusy
                               : NativeBackendHealthState::kReady),
        .queue_depth = outstanding_ ? 1U : 0U,
        .completed_jobs = completed_jobs_,
        .hardware_faults = hardware_faults_,
    };
  }

  void stop() {
    {
      std::lock_guard<std::mutex> admission_lock(admission_mutex_);
      std::lock_guard<std::mutex> lock(state_mutex_);
      accepting_ = false;
      stopping_ = true;
    }
    work_cv_.notify_all();
    if (worker_.joinable()) {
      worker_.join();
    }
    std::string frequency_error;
    if (!release_cpu_frequency_floor(&frequency_error)) {
      std::fprintf(stderr,
                   "lcdif_tcon: RM2 frequency guard restore failed during "
                   "stop: %s\n",
                   frequency_error.c_str());
      (void)device_->blank_powerdown();
      mark_lost();
    }
    device_->close();
    waveforms_.clear();
    {
      std::lock_guard<std::mutex> admission_lock(admission_mutex_);
      if (handoff_route_enabled_ && handoff_lease_.valid() && !handoff_saved_ &&
          !discard_handoff_locked()) {
        std::fprintf(stderr,
                     "lcdif_tcon: unsafe close could not invalidate warm "
                     "handoff\n");
      }
      handoff_lease_ = GlassHandoffLease{};
      clear_incoming_handoff_locked(HandoffDecision::kNone);
      warm_handoff_accepted_ = false;
      handoff_saved_ = false;
      std::lock_guard<std::mutex> lock(state_mutex_);
      pending_job_.reset();
      outstanding_ = false;
      started_ = false;
      probed_ = false;
      stopping_ = false;
    }
    if (telemetry_active_) {
      emit_telemetry();
      telemetry_active_ = false;
    }
    idle_cv_.notify_all();
  }

private:
  bool acquire_cpu_frequency_floor(std::string *error) {
    std::lock_guard<std::mutex> lock(cpu_frequency_mutex_);
    return cpu_frequency_lease_.acquire(error);
  }

  bool release_cpu_frequency_floor(std::string *error) noexcept {
    std::lock_guard<std::mutex> lock(cpu_frequency_mutex_);
    return cpu_frequency_lease_.release(error);
  }

  bool cpu_frequency_floor_active() const noexcept {
    std::lock_guard<std::mutex> lock(cpu_frequency_mutex_);
    return !cpu_frequency_lease_.enabled() || cpu_frequency_lease_.active();
  }

  void arm_cpu_frequency_release_locked() {
    if (!cpu_frequency_lease_.enabled()) {
      cpu_frequency_release_armed_ = false;
      return;
    }
    cpu_frequency_release_deadline_ =
        std::chrono::steady_clock::now() + cpu_frequency_debounce_;
    cpu_frequency_release_armed_ = true;
  }

  std::optional<int> read_powered_temperature(std::string *error) {
    if (device_->is_blanked()) {
      if (device_->unblank(kRm2IdleSlot) != kPlutoStatusOk ||
          !pan_with_deadline(kRm2IdleSlot)) {
        (void)device_->blank_powerdown();
        return std::nullopt;
      }
    }
    // FB_BLANK_UNBLANK synchronously enables the LCDIF supply through the
    // vendor kernel's SY7636A regulator path. The independent MFD attributes
    // must then agree before and after the signed temperature register read.
    if (!power_ready_reader_(error)) {
      (void)device_->blank_powerdown();
      return std::nullopt;
    }
    const std::optional<int> temperature = temperature_reader_(error);
    if (!temperature.has_value() ||
        !waveforms_.temperature_supported(*temperature) ||
        !power_ready_reader_(error)) {
      (void)device_->blank_powerdown();
      return std::nullopt;
    }
    return temperature;
  }

  PlutoStatus cold_initialize() {
    std::vector<std::uint8_t> cold_levels;
    std::vector<std::uint16_t> cold_mirror;
    try {
      cold_levels.assign(kRm2PanelWidth * kRm2PanelHeight, 15);
      cold_mirror.assign(kRm2PanelWidth * kRm2PanelHeight, 0xffffU);
    } catch (const std::bad_alloc &) {
      return kPlutoStatusInternal;
    }

    std::string error;
    const std::optional<int> temperature = read_powered_temperature(&error);
    std::vector<std::uint8_t> init_codes;
    Rm2WaveformSelection selection;
    if (!temperature.has_value() ||
        *temperature >= kMaximumBurstTemperatureMillidegrees ||
        !waveforms_.select(kPlutoRefreshFast, *temperature, &selection) ||
        !waveforms_.select(kPlutoRefreshUi, *temperature, &selection) ||
        !waveforms_.select(kPlutoRefreshText, *temperature, &selection) ||
        !waveforms_.select(kPlutoRefreshFull, *temperature, &selection) ||
        !waveforms_.init_pan_codes(*temperature, &init_codes) ||
        !run_init_clear(init_codes)) {
      (void)device_->blank_powerdown();
      return kPlutoStatusDeviceLost;
    }
    {
      std::lock_guard<std::mutex> frame_lock(frame_mutex_);
      settled_levels_ = std::move(cold_levels);
      mirror_ = std::move(cold_mirror);
    }
    handoff_chain_next_ = 0;
    handoff_unlinked_ = true;
    warm_handoff_accepted_ = false;
    return kPlutoStatusOk;
  }

  bool renderer_info_valid(const GlassHandoffRendererInfo &info,
                           std::size_t payload_bytes) const {
    return info.width == static_cast<std::uint32_t>(kRm2PanelWidth) &&
           info.height == static_cast<std::uint32_t>(kRm2PanelHeight) &&
           info.pixel_format ==
               static_cast<std::uint32_t>(kPlutoPixelFormatRgb565) &&
           (info.rotation == 0 || info.rotation == 90 || info.rotation == 180 ||
            info.rotation == 270) &&
           info.configuration_hash != 0 && payload_bytes != 0 &&
           payload_bytes <= kMaximumRendererHandoffBytes;
  }

  bool unpack_handoff_state(const GlassHandoffBundle &bundle,
                            std::vector<std::uint8_t> *out_settled_levels,
                            std::vector<std::uint16_t> *out_mirror) const {
    if (out_settled_levels == nullptr || out_mirror == nullptr ||
        bundle.identity != handoff_identity_ ||
        bundle.core.engine_temperature_bin != 0 ||
        bundle.core.admission_temperature_bin != 0) {
      return false;
    }
    constexpr std::size_t kPhysicalPixels = kRm2PanelWidth * kRm2PanelHeight;
    constexpr std::size_t kPhysicalPlane =
        static_cast<std::size_t>(kHandoffEngineStride) * kRm2PanelHeight;
    constexpr std::size_t kTileColumns =
        (kRm2PanelWidth + kHandoffTilePixels - 1u) / kHandoffTilePixels;
    constexpr std::size_t kTileRows =
        (kRm2PanelHeight + kHandoffTilePixels - 1u) / kHandoffTilePixels;
    constexpr std::size_t kTiles = kTileColumns * kTileRows;
    constexpr std::size_t kPresenterBytes = kPhysicalPixels * kBytesPerPixel;
    if (bundle.core.engine_levels.size() != kPhysicalPlane ||
        bundle.core.engine_dc.size() != kPhysicalPlane ||
        bundle.core.engine_stress.size() != kTiles ||
        bundle.core.engine_rescan.size() != kTiles ||
        !bundle.core.xochitl_history_ab.empty() ||
        bundle.presenter_payload.size() != kPresenterBytes ||
        std::any_of(bundle.core.engine_dc.begin(), bundle.core.engine_dc.end(),
                    [](std::int8_t value) { return value != 0; }) ||
        std::any_of(bundle.core.engine_stress.begin(),
                    bundle.core.engine_stress.end(),
                    [](std::uint16_t value) { return value != 0; }) ||
        std::any_of(bundle.core.engine_rescan.begin(),
                    bundle.core.engine_rescan.end(),
                    [](std::int32_t value) { return value != 0; })) {
      return false;
    }

    try {
      out_settled_levels->assign(kPhysicalPixels, 0);
      out_mirror->resize(kPhysicalPixels);
    } catch (const std::bad_alloc &) {
      out_settled_levels->clear();
      out_mirror->clear();
      return false;
    }
    for (std::size_t panel_row = 0; panel_row < kRm2PanelHeight; ++panel_row) {
      const std::size_t source_row =
          panel_row * static_cast<std::size_t>(kHandoffEngineStride);
      for (std::size_t x = 0; x < kRm2PanelWidth; ++x) {
        const std::uint8_t level = bundle.core.engine_levels[source_row + x];
        if (level > 15u) {
          return false;
        }
        (*out_settled_levels)[x * kRm2PanelHeight + panel_row] = level;
      }
      for (std::size_t x = kRm2PanelWidth; x < kHandoffEngineStride; ++x) {
        if (bundle.core.engine_levels[source_row + x] != 0) {
          return false;
        }
      }
    }
    for (std::size_t index = 0; index < kPhysicalPixels; ++index) {
      const std::size_t source = index * kBytesPerPixel;
      (*out_mirror)[index] = static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(bundle.presenter_payload[source]) |
          static_cast<std::uint16_t>(bundle.presenter_payload[source + 1u])
              << 8u);
    }
    return true;
  }

  bool pack_handoff_state_locked(GlassHandoffBundle *bundle) const {
    constexpr std::size_t kPhysicalPixels = kRm2PanelWidth * kRm2PanelHeight;
    constexpr std::size_t kPhysicalPlane =
        static_cast<std::size_t>(kHandoffEngineStride) * kRm2PanelHeight;
    constexpr std::size_t kTileColumns =
        (kRm2PanelWidth + kHandoffTilePixels - 1u) / kHandoffTilePixels;
    constexpr std::size_t kTileRows =
        (kRm2PanelHeight + kHandoffTilePixels - 1u) / kHandoffTilePixels;
    constexpr std::size_t kTiles = kTileColumns * kTileRows;
    if (bundle == nullptr || settled_levels_.size() != kPhysicalPixels ||
        mirror_.size() != kPhysicalPixels) {
      return false;
    }
    bundle->core.engine_temperature_bin = 0;
    bundle->core.admission_temperature_bin = 0;
    bundle->core.engine_levels.assign(kPhysicalPlane, 0);
    bundle->core.engine_dc.assign(kPhysicalPlane, 0);
    bundle->core.engine_stress.assign(kTiles, 0);
    bundle->core.engine_rescan.assign(kTiles, 0);
    bundle->core.xochitl_history_ab.clear();
    bundle->presenter_payload.resize(kPhysicalPixels * kBytesPerPixel);
    for (std::size_t panel_row = 0; panel_row < kRm2PanelHeight; ++panel_row) {
      const std::size_t destination_row =
          panel_row * static_cast<std::size_t>(kHandoffEngineStride);
      for (std::size_t x = 0; x < kRm2PanelWidth; ++x) {
        const std::uint8_t level =
            settled_levels_[x * kRm2PanelHeight + panel_row];
        if (level > 15u) {
          return false;
        }
        bundle->core.engine_levels[destination_row + x] = level;
      }
    }
    for (std::size_t index = 0; index < kPhysicalPixels; ++index) {
      const std::uint16_t pixel = mirror_[index];
      const std::size_t destination = index * kBytesPerPixel;
      bundle->presenter_payload[destination] = static_cast<std::uint8_t>(pixel);
      bundle->presenter_payload[destination + 1u] =
          static_cast<std::uint8_t>(pixel >> 8u);
    }
    return true;
  }

  void clear_incoming_handoff_locked(HandoffDecision decision) {
    incoming_settled_levels_.clear();
    incoming_mirror_.clear();
    incoming_renderer_payload_.clear();
    incoming_renderer_info_ = {};
    incoming_handoff_claim_ = {};
    handoff_decision_ = decision;
    if (decision != HandoffDecision::kAccepted) {
      warm_handoff_accepted_ = false;
    }
  }

  bool discard_handoff_locked() {
    if (!handoff_route_enabled_) {
      handoff_unlinked_ = true;
      return true;
    }
    if (!handoff_lease_.valid() ||
        !glass_handoff_discard(handoff_lease_, handoff_path_)) {
      return false;
    }
    handoff_unlinked_ = true;
    incoming_handoff_claim_ = {};
    handoff_saved_ = false;
    return true;
  }

  PlutoStatus prepare_incoming_handoff(bool *out_pending) {
    if (out_pending == nullptr) {
      return kPlutoStatusInvalidArgument;
    }
    *out_pending = false;
    clear_incoming_handoff_locked(HandoffDecision::kNone);
    handoff_chain_next_ = 0;
    if (!handoff_route_enabled_) {
      return kPlutoStatusOk;
    }
    if (!handoff_lease_.valid()) {
      return kPlutoStatusDeviceLost;
    }

    GlassHandoffBundle candidate;
    const GlassHandoffReject reject =
        glass_handoff_load(handoff_lease_, handoff_path_, handoff_identity_,
                           handoff_now_(), &candidate);
    if (reject == GlassHandoffReject::kMissing) {
      handoff_unlinked_ = true;
      return kPlutoStatusOk;
    }
    std::vector<std::uint8_t> candidate_settled_levels;
    std::vector<std::uint16_t> candidate_mirror;
    const bool candidate_valid =
        reject == GlassHandoffReject::kNone &&
        renderer_info_valid(candidate.renderer,
                            candidate.renderer_payload.size()) &&
        unpack_handoff_state(candidate, &candidate_settled_levels,
                             &candidate_mirror);
    if (!candidate_valid) {
      std::fprintf(stderr, "lcdif_tcon: warm handoff rejected: %s\n",
                   reject == GlassHandoffReject::kNone
                       ? glass_handoff_reject_name(GlassHandoffReject::kState)
                       : glass_handoff_reject_name(reject));
      if (!discard_handoff_locked()) {
        return kPlutoStatusDeviceLost;
      }
      clear_incoming_handoff_locked(HandoffDecision::kRejected);
      return kPlutoStatusOk;
    }

    incoming_settled_levels_ = std::move(candidate_settled_levels);
    incoming_mirror_ = std::move(candidate_mirror);
    incoming_renderer_payload_ = std::move(candidate.renderer_payload);
    incoming_renderer_info_ = candidate.renderer;
    incoming_handoff_claim_ = candidate.claim;
    handoff_chain_next_ = candidate.chain + 1u;
    handoff_unlinked_ = false;
    handoff_decision_ = HandoffDecision::kPending;
    *out_pending = true;
    std::fprintf(stderr,
                 "lcdif_tcon: warm handoff candidate validated chain=%u "
                 "renderer_bytes=%zu\n",
                 candidate.chain, incoming_renderer_payload_.size());
    return kPlutoStatusOk;
  }

  PlutoStatus consume_handoff_before_admission_locked() {
    if (handoff_unlinked_) {
      return kPlutoStatusOk;
    }
    if (!warm_handoff_accepted_ ||
        handoff_decision_ != HandoffDecision::kAccepted ||
        !glass_handoff_claim(handoff_lease_, handoff_path_,
                             incoming_handoff_claim_)) {
      std::fprintf(stderr, "lcdif_tcon: warm handoff claim lost before first "
                           "admission\n");
      handoff_unlinked_ = true;
      incoming_handoff_claim_ = {};
      (void)device_->blank_powerdown();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }
    handoff_unlinked_ = true;
    incoming_handoff_claim_ = {};
    handoff_saved_ = false;
    std::fprintf(stderr, "lcdif_tcon: warm handoff consumed\n");
    return kPlutoStatusOk;
  }

  PlutoStatus fail_powered_start(PlutoStatus status) {
    (void)device_->blank_powerdown();
    std::string frequency_error;
    if (!release_cpu_frequency_floor(&frequency_error)) {
      std::fprintf(stderr,
                   "lcdif_tcon: RM2 frequency guard restore failed during "
                   "start rollback: %s\n",
                   frequency_error.c_str());
      status = kPlutoStatusDeviceLost;
    }
    mark_lost();
    device_->close();
    waveforms_.clear();
    return status;
  }

  bool run_init_clear(const std::vector<std::uint8_t> &codes) {
    if (codes.empty() || device_->is_blanked() ||
        !fill_rm2_scan_slot(device_->slot(0), 0) ||
        !fill_rm2_scan_slot(device_->slot(1), 0x5555U) ||
        !fill_rm2_scan_slot(device_->slot(2), 0xaaaaU)) {
      return false;
    }
    if (!pan_with_deadline(codes.front()) || !pan_with_deadline(kRm2IdleSlot)) {
      return false;
    }
    for (std::size_t phase = 1; phase < codes.size(); ++phase) {
      if (!pan_with_deadline(codes[phase])) {
        return false;
      }
    }
    if (!pan_with_deadline(kRm2IdleSlot) ||
        device_->blank_powerdown() != kPlutoStatusOk) {
      return false;
    }
    return fill_rm2_scan_slot(device_->slot(0), 0) &&
           fill_rm2_scan_slot(device_->slot(1), 0) &&
           fill_rm2_scan_slot(device_->slot(2), 0);
  }

  void record_encode_duration(std::chrono::steady_clock::duration duration) {
    const auto nanoseconds =
        std::chrono::duration_cast<std::chrono::nanoseconds>(duration).count();
    const std::uint64_t microseconds =
        nanoseconds <= 0
            ? 0U
            : (static_cast<std::uint64_t>(nanoseconds) + 999U) / 1000U;
    const std::size_t bucket = static_cast<std::size_t>(
        std::min<std::uint64_t>(microseconds, kEncodeHistogramBuckets - 1U));
    ++encode_histogram_[bucket];
    encode_max_us_ = std::max(encode_max_us_, microseconds);
  }

  std::uint64_t encode_percentile(std::uint64_t percentile) const {
    if (presented_phases_ == 0) {
      return 0;
    }
    const std::uint64_t target = (presented_phases_ * percentile + 99U) / 100U;
    std::uint64_t observed = 0;
    for (std::size_t bucket = 0; bucket < encode_histogram_.size(); ++bucket) {
      observed += encode_histogram_[bucket];
      if (observed >= target) {
        return bucket;
      }
    }
    return encode_histogram_.size() - 1U;
  }

  void emit_telemetry() {
    if (telemetry_emitted_) {
      return;
    }
    telemetry_emitted_ = true;
    std::fprintf(
        stderr,
        "lcdif_tcon: telemetry jobs=%llu phases=%llu encode_p50_us=%llu "
        "encode_p95_us=%llu encode_p99_us=%llu encode_max_us=%llu "
        "missed_deadlines=%llu underflows=%llu safe_holds=%llu "
        "hardware_faults=%llu\n",
        static_cast<unsigned long long>(completed_jobs_),
        static_cast<unsigned long long>(presented_phases_),
        static_cast<unsigned long long>(encode_percentile(50)),
        static_cast<unsigned long long>(encode_percentile(95)),
        static_cast<unsigned long long>(encode_percentile(99)),
        static_cast<unsigned long long>(encode_max_us_),
        static_cast<unsigned long long>(missed_deadlines_),
        static_cast<unsigned long long>(underflows_),
        static_cast<unsigned long long>(safe_holds_),
        static_cast<unsigned long long>(hardware_faults_));
    std::fprintf(
        stderr,
        "lcdif_tcon: damage jobs=%llu requested_pixels=%llu "
        "encoded_pixels=%llu amplification_max_milli=%llu "
        "buffer_growths=%llu\n",
        static_cast<unsigned long long>(damage_jobs_),
        static_cast<unsigned long long>(damage_requested_pixels_),
        static_cast<unsigned long long>(damage_encoded_pixels_),
        static_cast<unsigned long long>(damage_amplification_max_milli_),
        static_cast<unsigned long long>(job_buffer_growths_));
  }

  bool accept_pan_result(std::uint32_t slot, const Rm2PanResult &result) {
    if (!result.operation_ok) {
      return false;
    }
    const std::chrono::nanoseconds interval(
        *profile_.runtime.display.phase_interval_nanoseconds);
    const std::chrono::nanoseconds limit = interval + interval / 20;
    if (result.duration > limit) {
      ++underflows_;
      ++missed_deadlines_;
      return false;
    }
    if (slot == kRm2IdleSlot) {
      ++safe_holds_;
    }
    return true;
  }

  bool pan_with_deadline(std::uint32_t slot) {
    Rm2PanResult result;
    result.operation_ok =
        device_->pan(slot, &result.duration) == kPlutoStatusOk;
    return accept_pan_result(slot, result);
  }

  PlutoStatus validate_request(const PlutoPresentRequest &request) const {
    const PlutoSurface &surface = request.surface;
    if (!refresh_class_valid(request.refresh_class) ||
        (request.flags & ~kKnownPresentFlags) != 0 ||
        ((request.flags & kPlutoPresentFlagSparkleDevelop) != 0 &&
         (request.flags & kPlutoPresentFlagSparkle) == 0) ||
        surface.pixels == nullptr || surface.width != profile_.panel.width ||
        surface.height != profile_.panel.height ||
        surface.format != kPlutoPixelFormatRgb565 ||
        surface.stride_bytes < kRm2PanelWidth * kBytesPerPixel ||
        request.damage == nullptr || request.damage_count == 0 ||
        request.damage_count > kMaximumDamageRects) {
      return kPlutoStatusInvalidArgument;
    }
    if (surface.height > 1 &&
        surface.stride_bytes >
            (std::numeric_limits<std::size_t>::max() -
             kRm2PanelWidth * kBytesPerPixel) /
                static_cast<std::size_t>(surface.height - 1)) {
      return kPlutoStatusInvalidArgument;
    }
    for (std::size_t index = 0; index < request.damage_count; ++index) {
      if (!rect_valid(request.damage[index])) {
        return kPlutoStatusInvalidArgument;
      }
    }
    return kPlutoStatusOk;
  }

  static Rm2PanelRect panel_rect_for_damage(const PlutoRect &damage) {
    constexpr std::int32_t kMaximumColumn =
        static_cast<std::int32_t>(kRm2PanelWidth - 1);
    constexpr std::int32_t kMaximumRow =
        static_cast<std::int32_t>(kRm2PanelHeight - 1);
    const std::int32_t user_right = damage.x + damage.width - 1;
    const std::int32_t user_bottom = damage.y + damage.height - 1;
    return {
        .row_min = static_cast<std::uint16_t>((kMaximumRow - user_bottom) &
                                              ~std::int32_t{7}),
        .row_max = static_cast<std::uint16_t>(
            std::min(kMaximumRow, (kMaximumRow - damage.y) | 7)),
        .column_min = static_cast<std::uint16_t>(kMaximumColumn - user_right),
        .column_max = static_cast<std::uint16_t>(kMaximumColumn - damage.x),
    };
  }

  static bool panel_rects_overlap(const Rm2PanelRect &left,
                                  const Rm2PanelRect &right) {
    return left.row_min <= right.row_max && right.row_min <= left.row_max &&
           left.column_min <= right.column_max &&
           right.column_min <= left.column_max;
  }

  static Rm2PanelRect union_panel_rects(const Rm2PanelRect &left,
                                        const Rm2PanelRect &right) {
    return {
        .row_min = std::min(left.row_min, right.row_min),
        .row_max = std::max(left.row_max, right.row_max),
        .column_min = std::min(left.column_min, right.column_min),
        .column_max = std::max(left.column_max, right.column_max),
    };
  }

  bool build_job(const PlutoPresentRequest &request, Job *job) {
    if (job == nullptr) {
      return false;
    }
    job->frame_id = request.frame_id;
    job->region_count = 0;
    job->suppress_unchanged = request.refresh_class != kPlutoRefreshFull;
    const std::uint64_t requested_pixels = rm2_damage_union_area(
        std::span<const PlutoRect>(request.damage, request.damage_count));
    for (std::size_t index = 0; index < request.damage_count; ++index) {
      const PlutoRect &damage = request.damage[index];
      Rm2PanelRect candidate = panel_rect_for_damage(damage);
      for (std::size_t region = 0; region < job->region_count;) {
        if (!panel_rects_overlap(candidate, job->regions[region].panel_rect)) {
          ++region;
          continue;
        }
        candidate =
            union_panel_rects(candidate, job->regions[region].panel_rect);
        job->regions[region] = job->regions[job->region_count - 1U];
        --job->region_count;
        region = 0;
      }
      job->regions[job->region_count++].panel_rect = candidate;
    }
    std::sort(
        job->regions.begin(),
        job->regions.begin() + static_cast<std::ptrdiff_t>(job->region_count),
        [](const JobRegion &left, const JobRegion &right) {
          return left.panel_rect.column_min < right.panel_rect.column_min ||
                 (left.panel_rect.column_min == right.panel_rect.column_min &&
                  left.panel_rect.row_min < right.panel_rect.row_min);
        });

    const std::optional<int> temperature = read_powered_temperature(nullptr);
    if (!temperature || *temperature >= kMaximumBurstTemperatureMillidegrees ||
        !waveforms_.select(request.refresh_class, *temperature,
                           &job->waveform)) {
      return false;
    }
    std::size_t pixels = 0;
    for (std::size_t index = 0; index < job->region_count; ++index) {
      JobRegion &region = job->regions[index];
      region.pixel_offset = pixels;
      pixels +=
          region.panel_rect.row_count() * region.panel_rect.column_count();
    }
    ++damage_jobs_;
    damage_requested_pixels_ += requested_pixels;
    damage_encoded_pixels_ += pixels;
    damage_amplification_max_milli_ = std::max(
        damage_amplification_max_milli_,
        requested_pixels == 0 ? std::uint64_t{0}
                              : (static_cast<std::uint64_t>(pixels) * 1000U +
                                 requested_pixels - 1U) /
                                    requested_pixels);
    if (job->transition_keys.capacity() < pixels ||
        job->target_pixels.capacity() < pixels) {
      ++job_buffer_growths_;
    }
    job->transition_keys.resize(pixels);
    job->target_pixels.resize(pixels);
    for (std::size_t region_index = 0; region_index < job->region_count;
         ++region_index) {
      const JobRegion &region = job->regions[region_index];
      const Rm2PanelRect &panel_rect = region.panel_rect;
      for (std::uint32_t column = panel_rect.column_min;
           column <= panel_rect.column_max; ++column) {
        const std::size_t column_offset =
            region.pixel_offset +
            static_cast<std::size_t>(column - panel_rect.column_min) *
                panel_rect.row_count();
        for (std::uint32_t row = panel_rect.row_min; row <= panel_rect.row_max;
             ++row) {
          const std::size_t user_x = kRm2PanelWidth - 1U - column;
          const std::size_t user_y = kRm2PanelHeight - 1U - row;
          const std::size_t source_offset =
              user_y * request.surface.stride_bytes + user_x * kBytesPerPixel;
          const std::uint16_t pixel =
              static_cast<std::uint16_t>(
                  request.surface.pixels[source_offset]) |
              static_cast<std::uint16_t>(
                  request.surface.pixels[source_offset + 1])
                  << 8U;
          const std::size_t offset =
              column_offset +
              static_cast<std::size_t>(row - panel_rect.row_min);
          const std::size_t state_offset =
              (kRm2PanelWidth - 1U - column) * kRm2PanelHeight + row;
          const std::uint8_t old_level = settled_levels_[state_offset] & 0x0fU;
          const std::uint8_t quantized_level = rgb565_to_rm2_level(pixel);
          const std::uint8_t new_level =
              request.refresh_class == kPlutoRefreshFast
                  ? rm2_fast_level(quantized_level)
                  : quantized_level;
          job->target_pixels[offset] = pixel;
          job->transition_keys[offset] =
              static_cast<std::uint8_t>((new_level << 4U) | old_level);
        }
      }
    }
    return true;
  }

  void worker_main() {
    const bool configured = configure_present_worker();
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      worker_configured_ = configured;
      worker_started_ = true;
    }
    worker_start_cv_.notify_one();
    if (!configured) {
      return;
    }
    for (;;) {
      Job job;
      bool release_frequency_floor = false;
      {
        std::unique_lock<std::mutex> lock(state_mutex_);
        for (;;) {
          if (stopping_ && !pending_job_.has_value()) {
            lock.unlock();
            std::string error;
            if (!release_cpu_frequency_floor(&error)) {
              std::fprintf(stderr,
                           "lcdif_tcon: RM2 frequency guard restore failed "
                           "at worker exit: %s\n",
                           error.c_str());
              (void)device_->blank_powerdown();
              mark_lost();
            }
            return;
          }
          if (pending_job_.has_value()) {
            job = std::move(*pending_job_);
            pending_job_.reset();
            break;
          }
          if (cpu_frequency_release_armed_) {
            const bool interrupted = work_cv_.wait_until(
                lock, cpu_frequency_release_deadline_, [this] {
                  return stopping_ || pending_job_.has_value() ||
                         !cpu_frequency_release_armed_;
                });
            if (!interrupted && !outstanding_ && cpu_frequency_release_armed_) {
              cpu_frequency_release_armed_ = false;
              release_frequency_floor = true;
              break;
            }
            continue;
          }
          work_cv_.wait(lock, [this] {
            return stopping_ || pending_job_.has_value() ||
                   cpu_frequency_release_armed_;
          });
        }
      }

      if (release_frequency_floor) {
        std::string error;
        if (!release_cpu_frequency_floor(&error)) {
          std::fprintf(stderr,
                       "lcdif_tcon: RM2 frequency guard debounced restore "
                       "failed: %s\n",
                       error.c_str());
          (void)device_->blank_powerdown();
          mark_lost();
          idle_cv_.notify_all();
        }
        continue;
      }

      PlutoStatus status = execute(job);
      if (status != kPlutoStatusOk) {
        std::string error;
        if (!release_cpu_frequency_floor(&error)) {
          std::fprintf(stderr,
                       "lcdif_tcon: RM2 frequency guard restore failed after "
                       "presentation fault: %s\n",
                       error.c_str());
        }
        status = kPlutoStatusDeviceLost;
      }
      PlutoPresentCompleteCallback callback = nullptr;
      void *callback_data = nullptr;
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (status == kPlutoStatusOk) {
          ++completed_jobs_;
          callback = callback_;
          callback_data = callback_user_data_;
        } else {
          lost_ = true;
          accepting_ = false;
          ++hardware_faults_;
          outstanding_ = false;
        }
      }
      if (callback != nullptr) {
        try {
          callback(job.frame_id, callback_data);
        } catch (...) {
          // The C ABI requires a non-throwing callback. Contain a foreign C++
          // callback violation so the scan worker and ownership state live.
        }
      }
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        reusable_job_ = std::move(job);
        if (status == kPlutoStatusOk) {
          outstanding_ = false;
          arm_cpu_frequency_release_locked();
        }
      }
      work_cv_.notify_one();
      idle_cv_.notify_all();
    }
  }

  bool clear_job_phase_cells(std::span<std::byte> slot, const Job &job) const {
    for (std::size_t index = 0; index < job.region_count; ++index) {
      if (!clear_rm2_phase_cells(slot, job.regions[index].panel_rect)) {
        return false;
      }
    }
    return true;
  }

  PlutoStatus execute(const Job &job) {
    if (!cpu_frequency_floor_active()) {
      std::fprintf(stderr,
                   "lcdif_tcon: RM2 frequency guard inactive before phase 0\n");
      (void)device_->blank_powerdown();
      return kPlutoStatusDeviceLost;
    }
    const std::span<const std::uint8_t> drive_lut =
        job.suppress_unchanged ? job.waveform.partial_drive_lut
                               : job.waveform.drive_lut;
    if (drive_lut.size() !=
        static_cast<std::size_t>(job.waveform.phase_count) * 16U * 16U) {
      (void)device_->blank_powerdown();
      return kPlutoStatusInternal;
    }
    const std::chrono::nanoseconds phase_interval(
        *profile_.runtime.display.phase_interval_nanoseconds);
    const std::chrono::nanoseconds cadence_deadline =
        phase_interval + phase_interval / 20;

    std::array<Rm2PhaseRegion, kMaximumDamageRects> phase_regions{};
    for (std::size_t index = 0; index < job.region_count; ++index) {
      phase_regions[index] = {
          .rect = job.regions[index].panel_rect,
          .transition_offset = job.regions[index].pixel_offset,
      };
    }
    const auto encode_phase = [&](std::uint32_t phase,
                                  std::uint32_t slot_index) {
      const auto encode_begin = std::chrono::steady_clock::now();
      const std::span<const std::uint8_t> phase_lut = drive_lut.subspan(
          static_cast<std::size_t>(phase) * 16U * 16U, 16U * 16U);
      const bool encoded = phase_encoder_.encode_regions(
          device_->slot(slot_index),
          std::span<const Rm2PhaseRegion>(phase_regions.data(),
                                          job.region_count),
          job.transition_keys, phase_lut);
      if (phase_encode_delay_for_testing_ > std::chrono::nanoseconds::zero()) {
        std::this_thread::sleep_for(phase_encode_delay_for_testing_);
      }
      const auto encode_duration =
          std::chrono::steady_clock::now() - encode_begin;
      record_encode_duration(encode_duration);
      if (!encoded) {
        return kPlutoStatusInternal;
      }
      if (encode_duration > phase_interval) {
        ++missed_deadlines_;
        ++underflows_;
        return kPlutoStatusDeviceLost;
      }
      return kPlutoStatusOk;
    };

    if (device_->is_blanked()) {
      (void)device_->blank_powerdown();
      return kPlutoStatusDeviceLost;
    }
    PlutoStatus encode_status = encode_phase(0, 0);
    if (encode_status != kPlutoStatusOk) {
      (void)device_->blank_powerdown();
      return encode_status;
    }

    // Job construction and RGB quantization leave the continuously scanning
    // idle slot at an arbitrary point in its frame. Wait for one explicit
    // idle boundary before phase zero, then issue every subsequent pan at the
    // completion boundary of its predecessor.
    if (!pan_with_deadline(kRm2IdleSlot)) {
      (void)device_->blank_powerdown();
      return kPlutoStatusDeviceLost;
    }

    auto pan_begin = std::chrono::steady_clock::now();
    if (!pan_worker_.begin(0)) {
      (void)device_->blank_powerdown();
      return kPlutoStatusDeviceLost;
    }
    for (std::uint32_t phase = 0; phase < job.waveform.phase_count; ++phase) {
      PlutoStatus next_encode_status = kPlutoStatusOk;
      if (phase + 1U < job.waveform.phase_count) {
        next_encode_status =
            encode_phase(phase + 1U, (phase + 1U) % kRm2ActiveSlots);
      }

      Rm2PanResult pan_result;
      if (!pan_worker_.finish(&pan_result) ||
          !accept_pan_result(phase % kRm2ActiveSlots, pan_result)) {
        (void)device_->blank_powerdown();
        return kPlutoStatusDeviceLost;
      }
      ++presented_phases_;
      const auto boundary = std::chrono::steady_clock::now();
      const auto cadence = boundary - pan_begin;
      if (cadence > cadence_deadline) {
        ++missed_deadlines_;
        if (cadence > phase_interval * 2) {
          ++underflows_;
        }
        (void)device_->blank_powerdown();
        return kPlutoStatusDeviceLost;
      }
      if (next_encode_status != kPlutoStatusOk) {
        (void)device_->blank_powerdown();
        return next_encode_status;
      }
      if (phase + 1U < job.waveform.phase_count) {
        pan_begin = std::chrono::steady_clock::now();
        if (!pan_worker_.begin((phase + 1U) % kRm2ActiveSlots)) {
          (void)device_->blank_powerdown();
          return kPlutoStatusDeviceLost;
        }
      }
    }
    if (!pan_with_deadline(kRm2IdleSlot)) {
      (void)device_->blank_powerdown();
      return kPlutoStatusDeviceLost;
    }
    for (std::uint32_t slot = 0; slot < kRm2ActiveSlots; ++slot) {
      if (!clear_job_phase_cells(device_->slot(slot), job)) {
        (void)device_->blank_powerdown();
        return kPlutoStatusInternal;
      }
    }
    commit(job);
    return kPlutoStatusOk;
  }

  void commit(const Job &job) {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    for (std::size_t region_index = 0; region_index < job.region_count;
         ++region_index) {
      const JobRegion &region = job.regions[region_index];
      const Rm2PanelRect &panel_rect = region.panel_rect;
      const std::size_t rows = panel_rect.row_count();
      for (std::uint32_t column = panel_rect.column_min;
           column <= panel_rect.column_max; ++column) {
        const std::size_t target_base =
            region.pixel_offset +
            static_cast<std::size_t>(column - panel_rect.column_min) * rows;
        const std::size_t state_base =
            (kRm2PanelWidth - 1U - column) * kRm2PanelHeight;
        for (std::uint32_t row = panel_rect.row_min; row <= panel_rect.row_max;
             ++row) {
          const std::size_t target_offset =
              target_base + static_cast<std::size_t>(row - panel_rect.row_min);
          settled_levels_[state_base + row] = static_cast<std::uint8_t>(
              job.transition_keys[target_offset] >> 4U);
          const std::size_t user_x = kRm2PanelWidth - 1U - column;
          const std::size_t user_y = kRm2PanelHeight - 1U - row;
          mirror_[user_y * kRm2PanelWidth + user_x] =
              job.target_pixels[target_offset];
        }
      }
    }
  }

  void finish_failed_admission(PlutoStatus status, Job &&job) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    reusable_job_ = std::move(job);
    outstanding_ = false;
    if (status == kPlutoStatusDeviceLost || status == kPlutoStatusInternal) {
      lost_ = true;
      accepting_ = false;
      ++hardware_faults_;
    }
    idle_cv_.notify_all();
  }

  void observe_fault(PlutoStatus status) {
    if (status == kPlutoStatusDeviceLost || status == kPlutoStatusInternal) {
      mark_lost();
    }
  }

  void mark_lost() {
    std::lock_guard<std::mutex> lock(state_mutex_);
    lost_ = true;
    accepting_ = false;
    ++hardware_faults_;
  }

  const GeneratedDeviceProfile &profile_;
  std::unique_ptr<MxsLcdifDevice> device_;
  Rm2TemperatureReader temperature_reader_;
  Rm2PowerReadyReader power_ready_reader_;
  Rm2WaveformProgram waveforms_;
  Rm2PhaseEncoder phase_encoder_;
  Rm2PanWorker pan_worker_;
  Rm2CpuFrequencyBurstLease cpu_frequency_lease_;
  std::chrono::milliseconds cpu_frequency_debounce_{50};
  std::chrono::nanoseconds phase_encode_delay_for_testing_{};
  std::string handoff_path_;
  GlassHandoffClock (*handoff_now_)() = glass_handoff_now;
  GlassHandoffIdentity handoff_identity_{};
  GlassHandoffLease handoff_lease_{};
  GlassHandoffClaim incoming_handoff_claim_{};
  GlassHandoffRendererInfo incoming_renderer_info_{};

  mutable std::mutex state_mutex_;
  mutable std::mutex frame_mutex_;
  mutable std::mutex cpu_frequency_mutex_;
  std::mutex admission_mutex_;
  std::condition_variable work_cv_;
  std::condition_variable idle_cv_;
  std::condition_variable worker_start_cv_;
  std::thread worker_;
  std::optional<Job> pending_job_;
  Job reusable_job_;
  std::vector<std::uint8_t> settled_levels_;
  std::vector<std::uint16_t> mirror_;
  std::vector<std::uint8_t> incoming_renderer_payload_;
  std::vector<std::uint8_t> incoming_settled_levels_;
  std::vector<std::uint16_t> incoming_mirror_;
  std::array<std::uint64_t, kEncodeHistogramBuckets> encode_histogram_{};
  PlutoPresentCompleteCallback callback_ = nullptr;
  void *callback_user_data_ = nullptr;
  std::uint32_t handoff_chain_next_ = 0;
  HandoffDecision handoff_decision_ = HandoffDecision::kNone;
  bool handoff_route_enabled_ = false;
  bool handoff_unlinked_ = true;
  bool handoff_saved_ = false;
  bool warm_handoff_accepted_ = false;
  bool probed_ = false;
  bool started_ = false;
  bool accepting_ = false;
  bool outstanding_ = false;
  bool stopping_ = false;
  bool suspended_ = false;
  bool lost_ = false;
  bool worker_started_ = false;
  bool worker_configured_ = false;
  bool telemetry_active_ = false;
  bool telemetry_emitted_ = false;
  bool cpu_frequency_release_armed_ = false;
  std::chrono::steady_clock::time_point cpu_frequency_release_deadline_{};
  std::uint64_t completed_jobs_ = 0;
  std::uint64_t hardware_faults_ = 0;
  std::uint64_t presented_phases_ = 0;
  std::uint64_t missed_deadlines_ = 0;
  std::uint64_t underflows_ = 0;
  std::uint64_t safe_holds_ = 0;
  std::uint64_t encode_max_us_ = 0;
  std::uint64_t job_buffer_growths_ = 0;
  std::uint64_t damage_jobs_ = 0;
  std::uint64_t damage_requested_pixels_ = 0;
  std::uint64_t damage_encoded_pixels_ = 0;
  std::uint64_t damage_amplification_max_milli_ = 0;
};

LcdifTconDisplayBackend::LcdifTconDisplayBackend(
    const GeneratedDeviceProfile &profile,
    std::unique_ptr<MxsLcdifDevice> device,
    Rm2TemperatureReader temperature_reader,
    Rm2PowerReadyReader power_ready_reader, Rm2HandoffOptions handoff)
    : impl_(std::make_unique<Impl>(
          profile, std::move(device), std::move(temperature_reader),
          std::move(power_ready_reader), std::move(handoff))) {}

LcdifTconDisplayBackend::~LcdifTconDisplayBackend() = default;

std::string_view LcdifTconDisplayBackend::driver_name() const {
  return impl_->driver_name();
}
PlutoStatus
LcdifTconDisplayBackend::probe(const GeneratedDeviceProfile &profile) {
  return impl_->probe(profile);
}
PlutoStatus LcdifTconDisplayBackend::start(const PlutoPresenterConfig &config) {
  return impl_->start(config);
}
PlutoStatus LcdifTconDisplayBackend::info(PlutoDisplayInfo *out_info) {
  return impl_->info(out_info);
}
PlutoStatus
LcdifTconDisplayBackend::submit(const PlutoPresentRequest *request) {
  return impl_->submit(request);
}
bool LcdifTconDisplayBackend::ready(PlutoRefreshClass refresh_class) {
  return impl_->ready(refresh_class);
}
PlutoStatus LcdifTconDisplayBackend::wait_idle(std::uint32_t timeout_ms) {
  return impl_->wait_idle(timeout_ms);
}
PlutoStatus LcdifTconDisplayBackend::snapshot(PlutoSurface *out_surface) {
  return impl_->snapshot(out_surface);
}
PlutoStatus LcdifTconDisplayBackend::set_pen_focus(const PlutoPenFocus *focus) {
  return impl_->set_pen_focus(focus);
}
PlutoStatus
LcdifTconDisplayBackend::stage_handoff(const PlutoHandoffPayload *payload,
                                       std::uint32_t timeout_ms) {
  return impl_->stage_handoff(payload, timeout_ms);
}
PlutoStatus
LcdifTconDisplayBackend::get_handoff(PlutoHandoffPayload *out_payload) {
  return impl_->get_handoff(out_payload);
}
PlutoStatus LcdifTconDisplayBackend::confirm_handoff(bool accepted) {
  return impl_->confirm_handoff(accepted);
}
PlutoStatus LcdifTconDisplayBackend::suspend(std::uint32_t timeout_ms) {
  return impl_->suspend(timeout_ms);
}
PlutoStatus LcdifTconDisplayBackend::resume() {
  return kPlutoStatusUnsupported;
}
NativeBackendHealth LcdifTconDisplayBackend::health() const {
  return impl_->health();
}
void LcdifTconDisplayBackend::stop() { impl_->stop(); }

} // namespace pluto::native::rm2
