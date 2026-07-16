#include "presenter/native/mxcfb/mxcfb_backend.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <sys/stat.h>
#if defined(__linux__)
#include <sys/vfs.h>
#endif
#include <unistd.h>

#include "generated/rm1_rgb565_optical_lut.h"

namespace pluto::native::mxcfb {
namespace {

constexpr std::string_view kDriverName = "mxcfb_epdc";
constexpr std::size_t kBytesPerPixel = 2;
constexpr std::size_t kMaximumDamageRects = 64;
constexpr std::byte kSafeInitialByte{0xff};
constexpr std::uint32_t kHandoffTilePixels = 32;
constexpr std::size_t kMaximumRendererHandoffBytes = 32u << 20;
constexpr std::uint8_t kPaperWhiteOpticalLevel = 30;
constexpr std::string_view kHandoffPipelineTag =
    "pluto-rm1-mxcfb-warm-handoff-presenter-payload";
constexpr std::uint32_t kKnownPresentFlags =
    kPlutoPresentFlagInkPriority | kPlutoPresentFlagPreDithered |
    kPlutoPresentFlagSettle | kPlutoPresentFlagSparkle |
    kPlutoPresentFlagSparkleDevelop | kPlutoPresentFlagPixelResetBlack |
    kPlutoPresentFlagPixelResetWhite | kPlutoPresentFlagPixelResetRestore |
    kPlutoPresentFlagRequiredSettle | kPlutoPresentFlagPenTruth |
    kPlutoPresentSparklePhaseMask;

enum class HandoffDecision : std::uint8_t {
  kNone,
  kPending,
  kAccepted,
  kRejected,
};

std::uint16_t load_rgb565(const std::uint8_t *pixel) {
  return static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(pixel[0]) |
      (static_cast<std::uint16_t>(pixel[1]) << 8u));
}

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
  if (out == nullptr || profile.id != "rm1" ||
      profile.display_driver != NativeDisplayDriverKind::kMxcfbEpdc ||
      profile.target_slice != DeviceTargetSlice::kLinuxArm ||
      profile.panel.width <= 0 || profile.panel.height <= 0 ||
      profile.panel.source_pixel_format != "rgb565" || profile.panel.color ||
      !profile.runtime.display.virtual_width.has_value() ||
      !profile.runtime.display.virtual_height.has_value() ||
      !profile.runtime.display.stride_bytes.has_value() ||
      !profile.runtime.display.mapping_bytes.has_value() ||
      *profile.runtime.display.virtual_width % 8u != 0 ||
      *profile.runtime.display.virtual_height <
          static_cast<std::uint32_t>(profile.panel.height) ||
      profile.runtime.firmware_build.empty() ||
      profile.runtime.kernel_release.empty() ||
      profile.runtime.waveform.accepted_sources.empty()) {
    return false;
  }

  HandoffFingerprint waveform;
  waveform.add_string("rm1-mxcfb-observed-update-policy");
  waveform.add_u32(uapi::kWaveformModeDirect);
  waveform.add_u32(uapi::kWaveformModeQuality);
  waveform.add_u32(uapi::kUpdateModePartial);
  waveform.add_u32(
      static_cast<std::uint32_t>(uapi::kTemperatureRemarkableDraw));
  waveform.add_u32(static_cast<std::uint32_t>(uapi::kTemperatureUseAmbient));
  for (const GeneratedWaveformSourceProfile &source :
       profile.runtime.waveform.accepted_sources) {
    waveform.add_string(source.path);
    waveform.add_string(source.sha256);
    waveform.add_string(source.panel_signature);
  }

  const GeneratedDisplayContract &display = profile.runtime.display;
  HandoffFingerprint pipeline;
  pipeline.add_string(kHandoffPipelineTag);
  pipeline.add_u64(kRm1Rgb565OpticalLevelLut.size());
  pipeline.add_u64(glass_handoff_crc64(kRm1Rgb565OpticalLevelLut));
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
  pipeline.add_u32(display.damage_alignment_pixels);
  pipeline.add_u32(static_cast<std::uint32_t>(sizeof(uapi::UpdateData)));
  pipeline.add_u64(uapi::kSendUpdate);
  pipeline.add_u64(uapi::kWaitForUpdateComplete);
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
      .width = static_cast<std::uint32_t>(profile.panel.width),
      .height = static_cast<std::uint32_t>(profile.panel.height),
      .pixel_format = static_cast<std::uint32_t>(kPlutoPixelFormatRgb565),
      .engine_stride = *display.virtual_width,
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

std::uint32_t process_marker_epoch() {
  // MXCFB markers are driver-global and can survive the fd that submitted
  // them when a wait times out. Do not restart every presenter process at the
  // same marker. Mix two independent host clocks, the process identity, and a
  // process-local sequence so clean restarts do not deterministically alias
  // the ordinary low marker epoch left by an earlier fault. Pluto reserves
  // the high half of the marker space for entropy-seeded process epochs.
  static std::atomic<std::uint64_t> sequence{1};
  std::uint64_t mixed = static_cast<std::uint64_t>(
      std::chrono::steady_clock::now().time_since_epoch().count());
  mixed ^= static_cast<std::uint64_t>(
               std::chrono::system_clock::now().time_since_epoch().count()) +
           0x9e3779b97f4a7c15ULL;
  mixed ^= static_cast<std::uint64_t>(::getpid()) << 32U;
  mixed ^= sequence.fetch_add(1, std::memory_order_relaxed);
  mixed = (mixed ^ (mixed >> 30U)) * 0xbf58476d1ce4e5b9ULL;
  mixed = (mixed ^ (mixed >> 27U)) * 0x94d049bb133111ebULL;
  mixed ^= mixed >> 31U;
  return static_cast<std::uint32_t>(mixed ^ (mixed >> 32U)) | 0x80000000U;
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

bool rect_valid(const PlutoRect &rect, std::uint32_t width,
                std::uint32_t height) {
  if (rect.x < 0 || rect.y < 0 || rect.width <= 0 || rect.height <= 0) {
    return false;
  }
  const std::uint32_t x = static_cast<std::uint32_t>(rect.x);
  const std::uint32_t y = static_cast<std::uint32_t>(rect.y);
  const std::uint32_t rect_width = static_cast<std::uint32_t>(rect.width);
  const std::uint32_t rect_height = static_cast<std::uint32_t>(rect.height);
  return x <= width && y <= height && rect_width <= width - x &&
         rect_height <= height - y;
}

uapi::UpdateRegion bounding_region(const PlutoRect *damage,
                                   std::size_t damage_count) {
  std::int32_t left = damage[0].x;
  std::int32_t top = damage[0].y;
  std::int32_t right = damage[0].x + damage[0].width;
  std::int32_t bottom = damage[0].y + damage[0].height;
  for (std::size_t index = 1; index < damage_count; ++index) {
    left = std::min(left, damage[index].x);
    top = std::min(top, damage[index].y);
    right = std::max(right, damage[index].x + damage[index].width);
    bottom = std::max(bottom, damage[index].y + damage[index].height);
  }
  return {
      .top = static_cast<std::uint32_t>(top),
      .left = static_cast<std::uint32_t>(left),
      .width = static_cast<std::uint32_t>(right - left),
      .height = static_cast<std::uint32_t>(bottom - top),
  };
}

std::uint64_t requested_damage_pixels(const PlutoPresentRequest &request) {
  std::array<std::int32_t, kMaximumDamageRects * 2> x_edges{};
  std::size_t x_count = 0;
  for (std::size_t index = 0; index < request.damage_count; ++index) {
    const PlutoRect &rect = request.damage[index];
    x_edges[x_count++] = rect.x;
    x_edges[x_count++] = rect.x + rect.width;
  }

  std::sort(x_edges.begin(), x_edges.begin() + x_count);
  const auto unique_end =
      std::unique(x_edges.begin(), x_edges.begin() + x_count);
  x_count = static_cast<std::size_t>(unique_end - x_edges.begin());

  std::array<std::pair<std::int32_t, std::int32_t>, kMaximumDamageRects>
      y_intervals{};
  std::uint64_t pixels = 0;
  for (std::size_t x_index = 1; x_index < x_count; ++x_index) {
    const std::int32_t left = x_edges[x_index - 1];
    const std::int32_t right = x_edges[x_index];
    std::size_t y_count = 0;
    for (std::size_t rect_index = 0; rect_index < request.damage_count;
         ++rect_index) {
      const PlutoRect &rect = request.damage[rect_index];
      if (rect.x < right && rect.x + rect.width > left) {
        y_intervals[y_count++] = {rect.y, rect.y + rect.height};
      }
    }
    if (y_count == 0) {
      continue;
    }
    std::sort(y_intervals.begin(), y_intervals.begin() + y_count);
    std::int32_t run_top = y_intervals[0].first;
    std::int32_t run_bottom = y_intervals[0].second;
    std::uint64_t covered_y = 0;
    for (std::size_t y_index = 1; y_index < y_count; ++y_index) {
      const auto [top, bottom] = y_intervals[y_index];
      if (top > run_bottom) {
        covered_y += static_cast<std::uint64_t>(run_bottom - run_top);
        run_top = top;
        run_bottom = bottom;
      } else {
        run_bottom = std::max(run_bottom, bottom);
      }
    }
    covered_y += static_cast<std::uint64_t>(run_bottom - run_top);
    pixels += static_cast<std::uint64_t>(right - left) * covered_y;
  }
  return pixels;
}

std::uint64_t update_region_pixels(const uapi::UpdateRegion &region) {
  return static_cast<std::uint64_t>(region.width) * region.height;
}

void apply_stock_update_policy(PlutoRefreshClass refresh_class,
                               uapi::UpdateData *update) {
  update->update_mode = uapi::kUpdateModePartial;
  switch (refresh_class) {
  case kPlutoRefreshFast:
    update->waveform_mode = uapi::kWaveformModeDirect;
    update->temperature = uapi::kTemperatureRemarkableDraw;
    return;
  case kPlutoRefreshUi:
  case kPlutoRefreshText:
  case kPlutoRefreshFull:
    update->waveform_mode = uapi::kWaveformModeQuality;
    update->temperature = uapi::kTemperatureUseAmbient;
    return;
  }
}

} // namespace

bool build_mxcfb_handoff_identity_for_testing(
    const GeneratedDeviceProfile &profile, GlassHandoffIdentity *out) {
  return build_handoff_identity(profile, out);
}

class MxcfbDisplayBackend::Impl final {
public:
  Impl(const GeneratedDeviceProfile &profile,
       std::unique_ptr<MxcfbDevice> device, std::uint32_t first_marker,
       MxcfbHandoffOptions handoff)
      : profile_(profile),
        device_(device == nullptr ? std::make_unique<MxcfbDevice>()
                                  : std::move(device)),
        handoff_path_(std::move(handoff.path)),
        handoff_now_(handoff.now_for_testing == nullptr
                         ? glass_handoff_now
                         : handoff.now_for_testing),
        next_marker_(first_marker == 0 ? process_marker_epoch()
                                       : first_marker) {
    const bool production_route =
        production_handoff_path_is_secure(handoff_path_);
    handoff_route_enabled_ =
        !handoff_path_.empty() &&
        (handoff.allow_insecure_path_for_testing || production_route) &&
        build_handoff_identity(profile_, &handoff_identity_);
    if (!handoff_path_.empty() && !handoff_route_enabled_) {
      std::fprintf(stderr,
                   "mxcfb: warm handoff disabled for insecure or incompatible "
                   "route\n");
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
      if (started_ || stopping_ || suspended_ || lost_) {
        return lost_ ? kPlutoStatusDeviceLost : kPlutoStatusInvalidArgument;
      }
      if (&profile != &profile_) {
        return kPlutoStatusUnsupported;
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
        (config.options != nullptr && config.options[0] != '\0')) {
      return kPlutoStatusInvalidArgument;
    }

    std::lock_guard<std::mutex> admission_lock(admission_mutex_);
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (!probed_ || started_ || stopping_ || suspended_ || lost_) {
        return lost_ ? kPlutoStatusDeviceLost : kPlutoStatusInvalidArgument;
      }
    }

    const PlutoStatus initialization_status = device_->initialize();
    if (initialization_status != kPlutoStatusOk) {
      device_->close();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }

    const MxcfbFramebufferInfo &framebuffer_info = device_->framebuffer_info();
    const std::span<std::byte> framebuffer = device_->framebuffer();
    const std::size_t required_mapping =
        static_cast<std::size_t>(framebuffer_info.stride_bytes) *
        framebuffer_info.virtual_height;
    if (framebuffer_info.width !=
            static_cast<std::uint32_t>(profile_.panel.width) ||
        framebuffer_info.height !=
            static_cast<std::uint32_t>(profile_.panel.height) ||
        framebuffer_info.stride_bytes < tight_stride() ||
        framebuffer.size() < required_mapping) {
      device_->close();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }

    bool handoff_pending = false;
    const PlutoStatus handoff_status =
        prepare_incoming_handoff(&handoff_pending);
    if (handoff_status != kPlutoStatusOk) {
      device_->close();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }
    if (!handoff_pending && cold_initialize() != kPlutoStatusOk) {
      device_->close();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }

    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      callback_ = config.on_complete;
      callback_user_data_ = config.user_data;
      accepting_ = !handoff_pending;
      stopping_ = false;
      started_ = true;
    }
    try {
      worker_ = std::thread([this] { completion_worker(); });
    } catch (...) {
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        accepting_ = false;
        started_ = false;
        lost_ = true;
        ++hardware_faults_;
      }
      if (handoff_route_enabled_ && handoff_lease_.valid()) {
        (void)discard_handoff_locked();
      }
      clear_incoming_handoff_locked(HandoffDecision::kRejected);
      handoff_lease_ = GlassHandoffLease{};
      device_->close();
      return kPlutoStatusInternal;
    }
    return kPlutoStatusOk;
  }

  PlutoStatus info(PlutoDisplayInfo *out_info) const {
    if (out_info == nullptr || out_info->struct_size != sizeof(*out_info)) {
      return kPlutoStatusInvalidArgument;
    }
    PlutoDisplayInfo info{};
    info.struct_size = sizeof(info);
    info.width = profile_.panel.width;
    info.height = profile_.panel.height;
    info.dpi = profile_.panel.dpi;
    info.preferred_format = kPlutoPixelFormatRgb565;
    info.is_color = false;
    info.controls_refresh_class = true;
    info.reports_completion = true;
    info.wants_pre_dithered = false;
    info.rect_alignment = static_cast<std::int32_t>(
        profile_.runtime.display.damage_alignment_pixels);
    info.max_inflight_updates = 1;
    // The stock trace proves these two exact ioctl tuples but carries no action
    // labels. This candidate maps the direct tuple to Fast and the quality
    // tuple to UI/Text/Full; real-panel camera acceptance decides the policy.
    info.nominal_latency_ms[0] = 250;
    info.nominal_latency_ms[1] = 500;
    info.nominal_latency_ms[2] = 500;
    info.nominal_latency_ms[3] = 2000;
    info.backend_quantizes_color = false;
    info.supports_overlap_supersession = false;
    *out_info = info;
    return kPlutoStatusOk;
  }

  PlutoStatus submit(const PlutoPresentRequest *request) {
    if (request == nullptr ||
        request->struct_size != sizeof(PlutoPresentRequest)) {
      return kPlutoStatusInvalidArgument;
    }
    const PlutoStatus validation = validate_request(*request);
    if (validation != kPlutoStatusOk) {
      return validation;
    }
    if ((request->flags & kPlutoPresentFlagSparkle) != 0) {
      // RM1 has no sparse white top-off primitive. The presenter ABI requires
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
    std::uint32_t marker = 0;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (lost_) {
        return kPlutoStatusDeviceLost;
      }
      if (!started_ || !accepting_) {
        return kPlutoStatusAgain;
      }
      if (outstanding_) {
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
      outstanding_ = true;
      marker = allocate_marker_locked();
    }

    uapi::UpdateData update{};
    update.update_region =
        bounding_region(request->damage, request->damage_count);
    update.update_marker = marker;
    apply_stock_update_policy(request->refresh_class, &update);

    PlutoStatus send_status = kPlutoStatusInternal;
    {
      std::lock_guard<std::mutex> frame_lock(frame_mutex_);
      copy_damage_to_framebuffer(*request);
      std::atomic_thread_fence(std::memory_order_release);
      send_status = device_->send_update(&update);
      if (send_status == kPlutoStatusInvalidArgument ||
          send_status == kPlutoStatusUnsupported) {
        // The app request was already validated and this update was built
        // entirely by the backend. A kernel-side contract rejection is a
        // backend/device fault, never an argument error attributable to the
        // caller.
        send_status = kPlutoStatusInternal;
      }
      if (send_status == kPlutoStatusOk) {
        copy_damage_to_mirror(*request);
      } else {
        // SEND_UPDATE did not accept the frame. Restore the authoritative
        // mirror immediately so a later full-screen update cannot expose
        // bytes from a request for which the caller received an error.
        restore_damage_from_mirror(*request);
      }
    }
    if (send_status != kPlutoStatusOk) {
      finish_failed_admission(send_status);
      return send_status;
    }
    record_damage_telemetry(*request, update.update_region);

    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      pending_job_ = CompletionJob{
          .frame_id = request->frame_id,
          .marker = marker,
      };
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
    const auto done = [this] { return !outstanding_; };
    if (lost_) {
      return kPlutoStatusDeviceLost;
    }
    if (done()) {
      return kPlutoStatusOk;
    }
    if (timeout_ms == 0) {
      return kPlutoStatusTimeout;
    }
    const bool completed =
        idle_cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                          [this, &done] { return done() || lost_; });
    if (lost_) {
      return kPlutoStatusDeviceLost;
    }
    return completed && done() ? kPlutoStatusOk : kPlutoStatusTimeout;
  }

  PlutoStatus snapshot(PlutoSurface *out_surface) const {
    if (out_surface == nullptr || out_surface->pixels == nullptr ||
        out_surface->width != profile_.panel.width ||
        out_surface->height != profile_.panel.height ||
        out_surface->format != kPlutoPixelFormatRgb565 ||
        out_surface->stride_bytes < tight_stride()) {
      return kPlutoStatusInvalidArgument;
    }
    std::lock_guard<std::mutex> frame_lock(frame_mutex_);
    if (mirror_.size() != frame_size()) {
      return kPlutoStatusDeviceLost;
    }
    auto *output = const_cast<std::uint8_t *>(out_surface->pixels);
    for (int y = 0; y < profile_.panel.height; ++y) {
      std::memcpy(output +
                      static_cast<std::size_t>(y) * out_surface->stride_bytes,
                  mirror_.data() + static_cast<std::size_t>(y) * tight_stride(),
                  tight_stride());
    }
    return kPlutoStatusOk;
  }

  PlutoStatus set_pen_focus(const PlutoPenFocus *focus) const {
    if (focus == nullptr || focus->struct_size != sizeof(PlutoPenFocus) ||
        (focus->flags & ~(kPlutoPenFocusInRange | kPlutoPenFocusContact)) !=
            0 ||
        ((focus->flags & kPlutoPenFocusContact) != 0 &&
         (focus->flags & kPlutoPenFocusInRange) == 0) ||
        ((focus->flags & kPlutoPenFocusInRange) != 0 &&
         !rect_valid(focus->rect,
                     static_cast<std::uint32_t>(profile_.panel.width),
                     static_cast<std::uint32_t>(profile_.panel.height)))) {
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
      if (!pack_handoff_core_locked(&bundle)) {
        discard_handoff_locked();
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
                 "mxcfb: warm handoff saved chain=%u renderer_bytes=%zu\n",
                 bundle.chain, bundle.renderer_payload.size());
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

    {
      std::lock_guard<std::mutex> frame_lock(frame_mutex_);
      if (incoming_mirror_.size() != frame_size() ||
          !framebuffer_matches_locked(incoming_mirror_)) {
        discard_handoff_locked();
        clear_incoming_handoff_locked(HandoffDecision::kRejected);
        device_->close();
        mark_lost();
        return kPlutoStatusDeviceLost;
      }
      mirror_ = std::move(incoming_mirror_);
    }
    if (device_->unblank() != kPlutoStatusOk) {
      discard_handoff_locked();
      clear_incoming_handoff_locked(HandoffDecision::kRejected);
      device_->close();
      mark_lost();
      return kPlutoStatusDeviceLost;
    }
    incoming_renderer_payload_.clear();
    incoming_renderer_info_ = {};
    handoff_decision_ = HandoffDecision::kAccepted;
    warm_handoff_accepted_ = true;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      accepting_ = true;
    }
    std::fprintf(stderr, "mxcfb: warm handoff accepted; cold clear skipped\n");
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

  PlutoStatus resume() const { return kPlutoStatusUnsupported; }

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

  MxcfbDamageTelemetry damage_telemetry() const {
    std::lock_guard<std::mutex> lock(state_mutex_);
    return damage_telemetry_;
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
    log_damage_telemetry_once();
    device_->close();
    {
      std::lock_guard<std::mutex> admission_lock(admission_mutex_);
      if (handoff_route_enabled_ && handoff_lease_.valid() && !handoff_saved_ &&
          !discard_handoff_locked()) {
        std::fprintf(stderr,
                     "mxcfb: unsafe close could not invalidate warm handoff\n");
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
    idle_cv_.notify_all();
  }

private:
  struct CompletionJob {
    std::uint64_t frame_id;
    std::uint32_t marker;
  };

  std::size_t tight_stride() const {
    return static_cast<std::size_t>(profile_.panel.width) * kBytesPerPixel;
  }

  std::size_t frame_size() const {
    return tight_stride() * static_cast<std::size_t>(profile_.panel.height);
  }

  PlutoStatus cold_initialize() {
    try {
      std::lock_guard<std::mutex> frame_lock(frame_mutex_);
      mirror_.assign(frame_size(), static_cast<std::uint8_t>(kSafeInitialByte));
      std::span<std::byte> framebuffer = device_->framebuffer();
      if (framebuffer.empty()) {
        return kPlutoStatusDeviceLost;
      }
      // Cold ownership is the only path that overwrites the inherited plane.
      // Initialize visible and hidden virtual pages before unblank/update so a
      // later full request can never expose stale stock or rejected-handoff
      // bytes.
      std::fill(framebuffer.begin(), framebuffer.end(), kSafeInitialByte);
      std::atomic_thread_fence(std::memory_order_release);
    } catch (const std::bad_alloc &) {
      return kPlutoStatusInternal;
    }

    if (device_->unblank() != kPlutoStatusOk) {
      return kPlutoStatusDeviceLost;
    }
    uapi::UpdateData initial_update{};
    initial_update.update_region = {
        .top = 0,
        .left = 0,
        .width = static_cast<std::uint32_t>(profile_.panel.width),
        .height = static_cast<std::uint32_t>(profile_.panel.height),
    };
    apply_stock_update_policy(kPlutoRefreshFull, &initial_update);
    initial_update.update_marker = allocate_marker_locked();
    if (device_->send_update(&initial_update) != kPlutoStatusOk ||
        device_->wait_for_update_complete(initial_update.update_marker,
                                          nullptr) != kPlutoStatusOk) {
      return kPlutoStatusDeviceLost;
    }
    handoff_chain_next_ = 0;
    handoff_unlinked_ = true;
    warm_handoff_accepted_ = false;
    return kPlutoStatusOk;
  }

  bool renderer_info_valid(const GlassHandoffRendererInfo &info,
                           std::size_t payload_bytes) const {
    return info.width == static_cast<std::uint32_t>(profile_.panel.width) &&
           info.height == static_cast<std::uint32_t>(profile_.panel.height) &&
           info.pixel_format ==
               static_cast<std::uint32_t>(kPlutoPixelFormatRgb565) &&
           (info.rotation == 0 || info.rotation == 90 || info.rotation == 180 ||
            info.rotation == 270) &&
           info.configuration_hash != 0 && payload_bytes != 0 &&
           payload_bytes <= kMaximumRendererHandoffBytes;
  }

  bool unpack_handoff_core(const GlassHandoffBundle &bundle,
                           std::vector<std::uint8_t> *out_mirror) const {
    if (out_mirror == nullptr || bundle.identity != handoff_identity_ ||
        bundle.core.engine_temperature_bin != 0 ||
        bundle.core.admission_temperature_bin != 0 ||
        bundle.presenter_payload.size() != frame_size()) {
      return false;
    }
    const std::size_t storage_stride = handoff_identity_.engine_stride;
    const std::size_t height = handoff_identity_.height;
    if (storage_stride > std::numeric_limits<std::size_t>::max() / height) {
      return false;
    }
    const std::size_t plane = storage_stride * height;
    const std::size_t tile_cols =
        (handoff_identity_.width + handoff_identity_.tile_px - 1u) /
        handoff_identity_.tile_px;
    const std::size_t tile_rows =
        (handoff_identity_.height + handoff_identity_.tile_px - 1u) /
        handoff_identity_.tile_px;
    if (tile_cols > std::numeric_limits<std::size_t>::max() / tile_rows ||
        bundle.core.engine_levels.size() != plane ||
        bundle.core.engine_dc.size() != plane ||
        bundle.core.engine_stress.size() != tile_cols * tile_rows ||
        bundle.core.engine_rescan.size() != tile_cols * tile_rows ||
        !bundle.core.xochitl_history_ab.empty() ||
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

    const std::size_t width = static_cast<std::size_t>(profile_.panel.width);
    for (std::size_t y = 0; y < height; ++y) {
      const std::size_t level_row = y * storage_stride;
      const std::size_t mirror_row = y * tight_stride();
      for (std::size_t x = 0; x < width; ++x) {
        const std::size_t pixel = mirror_row + x * kBytesPerPixel;
        if (bundle.core.engine_levels[level_row + x] !=
            kRm1Rgb565OpticalLevelLut[load_rgb565(
                bundle.presenter_payload.data() + pixel)]) {
          return false;
        }
      }
      for (std::size_t x = width; x < storage_stride; ++x) {
        if (bundle.core.engine_levels[level_row + x] !=
            kPaperWhiteOpticalLevel) {
          return false;
        }
      }
    }
    try {
      *out_mirror = bundle.presenter_payload;
    } catch (const std::bad_alloc &) {
      return false;
    }
    return true;
  }

  bool
  framebuffer_matches_locked(const std::vector<std::uint8_t> &candidate) const {
    if (candidate.size() != frame_size()) {
      return false;
    }
    const std::span<std::byte> framebuffer = device_->framebuffer();
    const std::size_t framebuffer_stride =
        device_->framebuffer_info().stride_bytes;
    if (framebuffer_stride < tight_stride() ||
        framebuffer.size() < framebuffer_stride * static_cast<std::size_t>(
                                                      profile_.panel.height)) {
      return false;
    }
    for (int y = 0; y < profile_.panel.height; ++y) {
      if (std::memcmp(framebuffer.data() +
                          static_cast<std::size_t>(y) * framebuffer_stride,
                      candidate.data() +
                          static_cast<std::size_t>(y) * tight_stride(),
                      tight_stride()) != 0) {
        return false;
      }
    }
    return true;
  }

  bool pack_handoff_core_locked(GlassHandoffBundle *bundle) const {
    if (bundle == nullptr || mirror_.size() != frame_size() ||
        !framebuffer_matches_locked(mirror_)) {
      return false;
    }
    const std::size_t storage_stride = handoff_identity_.engine_stride;
    const std::size_t height = handoff_identity_.height;
    if (storage_stride > std::numeric_limits<std::size_t>::max() / height) {
      return false;
    }
    const std::size_t plane = storage_stride * height;
    const std::size_t tile_cols =
        (handoff_identity_.width + handoff_identity_.tile_px - 1u) /
        handoff_identity_.tile_px;
    const std::size_t tile_rows =
        (handoff_identity_.height + handoff_identity_.tile_px - 1u) /
        handoff_identity_.tile_px;
    if (tile_cols > std::numeric_limits<std::size_t>::max() / tile_rows) {
      return false;
    }
    bundle->core.engine_temperature_bin = 0;
    bundle->core.admission_temperature_bin = 0;
    bundle->core.engine_levels.assign(plane, kPaperWhiteOpticalLevel);
    bundle->core.engine_dc.assign(plane, 0);
    bundle->core.engine_stress.assign(tile_cols * tile_rows, 0);
    bundle->core.engine_rescan.assign(tile_cols * tile_rows, 0);
    bundle->core.xochitl_history_ab.clear();
    bundle->presenter_payload = mirror_;
    const std::size_t width = static_cast<std::size_t>(profile_.panel.width);
    for (std::size_t y = 0; y < height; ++y) {
      const std::size_t source_row = y * tight_stride();
      const std::size_t destination_row = y * storage_stride;
      for (std::size_t x = 0; x < width; ++x) {
        const std::size_t source = source_row + x * kBytesPerPixel;
        const std::size_t destination = destination_row + x;
        bundle->core.engine_levels[destination] =
            kRm1Rgb565OpticalLevelLut[load_rgb565(mirror_.data() + source)];
      }
    }
    return true;
  }

  void clear_incoming_handoff_locked(HandoffDecision decision) {
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
    std::vector<std::uint8_t> candidate_mirror;
    const bool candidate_valid =
        reject == GlassHandoffReject::kNone &&
        renderer_info_valid(candidate.renderer,
                            candidate.renderer_payload.size()) &&
        unpack_handoff_core(candidate, &candidate_mirror) &&
        framebuffer_matches_locked(candidate_mirror);
    if (!candidate_valid) {
      std::fprintf(stderr, "mxcfb: warm handoff rejected: %s\n",
                   reject == GlassHandoffReject::kNone
                       ? glass_handoff_reject_name(GlassHandoffReject::kState)
                       : glass_handoff_reject_name(reject));
      if (!discard_handoff_locked()) {
        return kPlutoStatusDeviceLost;
      }
      clear_incoming_handoff_locked(HandoffDecision::kRejected);
      return kPlutoStatusOk;
    }

    incoming_mirror_ = std::move(candidate_mirror);
    incoming_renderer_payload_ = std::move(candidate.renderer_payload);
    incoming_renderer_info_ = candidate.renderer;
    incoming_handoff_claim_ = candidate.claim;
    handoff_chain_next_ = candidate.chain + 1u;
    handoff_unlinked_ = false;
    handoff_decision_ = HandoffDecision::kPending;
    *out_pending = true;
    std::fprintf(stderr,
                 "mxcfb: warm handoff candidate validated chain=%u "
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
      std::fprintf(stderr,
                   "mxcfb: warm handoff claim lost before first admission\n");
      handoff_unlinked_ = true;
      incoming_handoff_claim_ = {};
      mark_lost();
      return kPlutoStatusDeviceLost;
    }
    handoff_unlinked_ = true;
    incoming_handoff_claim_ = {};
    handoff_saved_ = false;
    std::fprintf(stderr, "mxcfb: warm handoff consumed\n");
    return kPlutoStatusOk;
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
        surface.stride_bytes < tight_stride() || request.damage == nullptr ||
        request.damage_count == 0 ||
        request.damage_count > kMaximumDamageRects) {
      return kPlutoStatusInvalidArgument;
    }
    const std::size_t height = static_cast<std::size_t>(surface.height);
    if (height > 1 &&
        surface.stride_bytes >
            (std::numeric_limits<std::size_t>::max() - tight_stride()) /
                (height - 1)) {
      return kPlutoStatusInvalidArgument;
    }
    for (std::size_t index = 0; index < request.damage_count; ++index) {
      if (!rect_valid(request.damage[index],
                      static_cast<std::uint32_t>(profile_.panel.width),
                      static_cast<std::uint32_t>(profile_.panel.height))) {
        return kPlutoStatusInvalidArgument;
      }
    }
    return kPlutoStatusOk;
  }

  void copy_damage_to_framebuffer(const PlutoPresentRequest &request) {
    std::span<std::byte> framebuffer = device_->framebuffer();
    const std::size_t framebuffer_stride =
        device_->framebuffer_info().stride_bytes;
    for (std::size_t index = 0; index < request.damage_count; ++index) {
      const PlutoRect &rect = request.damage[index];
      const std::size_t row_bytes =
          static_cast<std::size_t>(rect.width) * kBytesPerPixel;
      for (int row = 0; row < rect.height; ++row) {
        const std::size_t source_offset =
            static_cast<std::size_t>(rect.y + row) *
                request.surface.stride_bytes +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        const std::size_t destination_offset =
            static_cast<std::size_t>(rect.y + row) * framebuffer_stride +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        std::memcpy(framebuffer.data() + destination_offset,
                    request.surface.pixels + source_offset, row_bytes);
      }
    }
  }

  void copy_damage_to_mirror(const PlutoPresentRequest &request) {
    for (std::size_t index = 0; index < request.damage_count; ++index) {
      const PlutoRect &rect = request.damage[index];
      const std::size_t row_bytes =
          static_cast<std::size_t>(rect.width) * kBytesPerPixel;
      for (int row = 0; row < rect.height; ++row) {
        const std::size_t source_offset =
            static_cast<std::size_t>(rect.y + row) *
                request.surface.stride_bytes +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        const std::size_t destination_offset =
            static_cast<std::size_t>(rect.y + row) * tight_stride() +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        std::memcpy(mirror_.data() + destination_offset,
                    request.surface.pixels + source_offset, row_bytes);
      }
    }
  }

  void restore_damage_from_mirror(const PlutoPresentRequest &request) {
    std::span<std::byte> framebuffer = device_->framebuffer();
    const std::size_t framebuffer_stride =
        device_->framebuffer_info().stride_bytes;
    for (std::size_t index = 0; index < request.damage_count; ++index) {
      const PlutoRect &rect = request.damage[index];
      const std::size_t row_bytes =
          static_cast<std::size_t>(rect.width) * kBytesPerPixel;
      for (int row = 0; row < rect.height; ++row) {
        const std::size_t mirror_offset =
            static_cast<std::size_t>(rect.y + row) * tight_stride() +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        const std::size_t framebuffer_offset =
            static_cast<std::size_t>(rect.y + row) * framebuffer_stride +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        std::memcpy(framebuffer.data() + framebuffer_offset,
                    mirror_.data() + mirror_offset, row_bytes);
      }
    }
    std::atomic_thread_fence(std::memory_order_release);
  }

  void record_damage_telemetry(const PlutoPresentRequest &request,
                               const uapi::UpdateRegion &region) {
    const std::uint64_t requested = requested_damage_pixels(request);
    const std::uint64_t driven = update_region_pixels(region);
    const std::uint64_t panel_pixels =
        static_cast<std::uint64_t>(profile_.panel.width) *
        static_cast<std::uint64_t>(profile_.panel.height);
    const bool full_quality = request.refresh_class == kPlutoRefreshFull;
    const bool regional_full = full_quality && driven < panel_pixels;
    const bool newly_regional_full =
        regional_full && (request.flags & kPlutoPresentFlagPenTruth) == 0;
    const std::uint64_t amplification_milli =
        requested == 0 ? 0 : driven * 1000u / requested;

    std::lock_guard<std::mutex> lock(state_mutex_);
    ++damage_telemetry_.accepted_updates;
    damage_telemetry_.requested_pixels += requested;
    damage_telemetry_.driven_pixels += driven;
    if (driven > requested) {
      ++damage_telemetry_.amplified_updates;
    }
    if (full_quality) {
      ++damage_telemetry_.full_quality_updates;
    }
    if (regional_full) {
      ++damage_telemetry_.regional_full_quality_updates;
    }
    if (newly_regional_full) {
      damage_telemetry_.legacy_full_screen_pixels_avoided +=
          panel_pixels - driven;
    }
    damage_telemetry_.max_amplification_milli = std::max(
        damage_telemetry_.max_amplification_milli, amplification_milli);
  }

  void log_damage_telemetry_once() {
    MxcfbDamageTelemetry telemetry;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (damage_telemetry_logged_ || damage_telemetry_.accepted_updates == 0) {
        return;
      }
      damage_telemetry_logged_ = true;
      telemetry = damage_telemetry_;
    }
    std::fprintf(
        stderr,
        "mxcfb: damage telemetry updates=%llu requested_px=%llu "
        "driven_px=%llu amplified=%llu full=%llu regional_full=%llu "
        "legacy_full_px_avoided=%llu max_amp_milli=%llu\n",
        static_cast<unsigned long long>(telemetry.accepted_updates),
        static_cast<unsigned long long>(telemetry.requested_pixels),
        static_cast<unsigned long long>(telemetry.driven_pixels),
        static_cast<unsigned long long>(telemetry.amplified_updates),
        static_cast<unsigned long long>(telemetry.full_quality_updates),
        static_cast<unsigned long long>(
            telemetry.regional_full_quality_updates),
        static_cast<unsigned long long>(
            telemetry.legacy_full_screen_pixels_avoided),
        static_cast<unsigned long long>(telemetry.max_amplification_milli));
  }

  std::uint32_t allocate_marker_locked() {
    const std::uint32_t marker = next_marker_;
    ++next_marker_;
    if (next_marker_ == 0) {
      next_marker_ = 1;
    }
    return marker;
  }

  void finish_failed_admission(PlutoStatus status) {
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      outstanding_ = false;
      if (status == kPlutoStatusDeviceLost || status == kPlutoStatusInternal ||
          status == kPlutoStatusTimeout) {
        lost_ = true;
        accepting_ = false;
        stopping_ = true;
        ++hardware_faults_;
      }
    }
    work_cv_.notify_all();
    idle_cv_.notify_all();
  }

  void mark_lost() {
    std::lock_guard<std::mutex> lock(state_mutex_);
    lost_ = true;
    accepting_ = false;
    ++hardware_faults_;
  }

  void completion_worker() {
    while (true) {
      CompletionJob job{};
      {
        std::unique_lock<std::mutex> lock(state_mutex_);
        work_cv_.wait(lock, [this] {
          return pending_job_.has_value() || stopping_ || lost_;
        });
        if (!pending_job_.has_value()) {
          if (stopping_ || lost_) {
            return;
          }
          continue;
        }
        job = *pending_job_;
        pending_job_.reset();
      }

      bool collision = false;
      const PlutoStatus status =
          device_->wait_for_update_complete(job.marker, &collision);
      PlutoPresentCompleteCallback callback = nullptr;
      void *callback_user_data = nullptr;
      if (status == kPlutoStatusOk) {
        std::lock_guard<std::mutex> lock(state_mutex_);
        callback = callback_;
        callback_user_data = callback_user_data_;
      }
      if (callback != nullptr) {
        callback(job.frame_id, callback_user_data);
      }

      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        outstanding_ = false;
        if (status == kPlutoStatusOk) {
          ++completed_jobs_;
        } else {
          lost_ = true;
          accepting_ = false;
          stopping_ = true;
          ++hardware_faults_;
        }
      }
      idle_cv_.notify_all();
      if (status != kPlutoStatusOk) {
        work_cv_.notify_all();
        return;
      }
    }
  }

  const GeneratedDeviceProfile &profile_;
  std::unique_ptr<MxcfbDevice> device_;
  std::string handoff_path_;
  GlassHandoffClock (*handoff_now_)() = glass_handoff_now;
  GlassHandoffIdentity handoff_identity_{};
  GlassHandoffLease handoff_lease_{};
  GlassHandoffClaim incoming_handoff_claim_{};
  GlassHandoffRendererInfo incoming_renderer_info_{};

  mutable std::mutex admission_mutex_;
  mutable std::mutex state_mutex_;
  mutable std::mutex frame_mutex_;
  std::condition_variable work_cv_;
  std::condition_variable idle_cv_;
  std::thread worker_;
  std::optional<CompletionJob> pending_job_;
  std::vector<std::uint8_t> mirror_;
  std::vector<std::uint8_t> incoming_renderer_payload_;
  std::vector<std::uint8_t> incoming_mirror_;

  PlutoPresentCompleteCallback callback_ = nullptr;
  void *callback_user_data_ = nullptr;
  std::uint32_t next_marker_ = 1;
  std::uint32_t handoff_chain_next_ = 0;
  std::uint64_t completed_jobs_ = 0;
  std::uint64_t hardware_faults_ = 0;
  MxcfbDamageTelemetry damage_telemetry_{};
  HandoffDecision handoff_decision_ = HandoffDecision::kNone;
  bool handoff_route_enabled_ = false;
  bool handoff_unlinked_ = true;
  bool handoff_saved_ = false;
  bool warm_handoff_accepted_ = false;
  bool probed_ = false;
  bool started_ = false;
  bool accepting_ = false;
  bool stopping_ = false;
  bool suspended_ = false;
  bool lost_ = false;
  bool outstanding_ = false;
  bool damage_telemetry_logged_ = false;
};

MxcfbDisplayBackend::MxcfbDisplayBackend(const GeneratedDeviceProfile &profile,
                                         std::unique_ptr<MxcfbDevice> device,
                                         std::uint32_t first_marker,
                                         MxcfbHandoffOptions handoff)
    : impl_(std::make_unique<Impl>(profile, std::move(device), first_marker,
                                   std::move(handoff))) {}

MxcfbDisplayBackend::~MxcfbDisplayBackend() = default;

std::string_view MxcfbDisplayBackend::driver_name() const {
  return impl_->driver_name();
}

PlutoStatus MxcfbDisplayBackend::probe(const GeneratedDeviceProfile &profile) {
  return impl_->probe(profile);
}

PlutoStatus MxcfbDisplayBackend::start(const PlutoPresenterConfig &config) {
  return impl_->start(config);
}

PlutoStatus MxcfbDisplayBackend::info(PlutoDisplayInfo *out_info) {
  return impl_->info(out_info);
}

PlutoStatus MxcfbDisplayBackend::submit(const PlutoPresentRequest *request) {
  return impl_->submit(request);
}

bool MxcfbDisplayBackend::ready(PlutoRefreshClass refresh_class) {
  return impl_->ready(refresh_class);
}

PlutoStatus MxcfbDisplayBackend::wait_idle(std::uint32_t timeout_ms) {
  return impl_->wait_idle(timeout_ms);
}

PlutoStatus MxcfbDisplayBackend::snapshot(PlutoSurface *out_surface) {
  return impl_->snapshot(out_surface);
}

PlutoStatus MxcfbDisplayBackend::set_pen_focus(const PlutoPenFocus *focus) {
  return impl_->set_pen_focus(focus);
}

PlutoStatus
MxcfbDisplayBackend::stage_handoff(const PlutoHandoffPayload *payload,
                                   std::uint32_t timeout_ms) {
  return impl_->stage_handoff(payload, timeout_ms);
}

PlutoStatus MxcfbDisplayBackend::get_handoff(PlutoHandoffPayload *out_payload) {
  return impl_->get_handoff(out_payload);
}

PlutoStatus MxcfbDisplayBackend::confirm_handoff(bool accepted) {
  return impl_->confirm_handoff(accepted);
}

PlutoStatus MxcfbDisplayBackend::suspend(std::uint32_t timeout_ms) {
  return impl_->suspend(timeout_ms);
}

PlutoStatus MxcfbDisplayBackend::resume() { return impl_->resume(); }

NativeBackendHealth MxcfbDisplayBackend::health() const {
  return impl_->health();
}

MxcfbDamageTelemetry MxcfbDisplayBackend::damage_telemetry() const {
  return impl_->damage_telemetry();
}

void MxcfbDisplayBackend::stop() { impl_->stop(); }

} // namespace pluto::native::mxcfb
