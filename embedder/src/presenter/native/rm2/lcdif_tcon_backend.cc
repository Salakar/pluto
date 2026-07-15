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
constexpr std::string_view kHandoffPipelineTag =
    "pluto-rm2-lcdif-warm-handoff-v1";
constexpr std::uint32_t kKnownPresentFlags =
    kPlutoPresentFlagInkPriority | kPlutoPresentFlagPreDithered |
    kPlutoPresentFlagSettle | kPlutoPresentFlagSparkle |
    kPlutoPresentFlagSparkleDevelop | kPlutoPresentFlagPixelResetBlack |
    kPlutoPresentFlagPixelResetWhite | kPlutoPresentFlagPixelResetRestore |
    kPlutoPresentFlagRequiredSettle | kPlutoPresentFlagPenTruth |
    kPlutoPresentSparklePhaseMask;

static_assert(kHandoffEngineStride == 1408u);

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
  waveform.add_string("rm2-wbf-exact-profile-v1");
  for (const GeneratedWaveformSourceProfile &source :
       profile.runtime.waveform.accepted_sources) {
    waveform.add_string(source.path);
    waveform.add_string(source.sha256);
    waveform.add_string(source.panel_signature);
  }

  HandoffFingerprint pipeline;
  pipeline.add_string(kHandoffPipelineTag);
  pipeline.add_string("physical-panel-row-major-u4-padded-v1");
  pipeline.add_string("logical-tight-rgb565le-v1");
  pipeline.add_string("canonical-idle-hold-v1");
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

PlutoRect bounding_rect(const PlutoRect *damage, std::size_t damage_count) {
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
      .x = left,
      .y = top,
      .width = right - left,
      .height = bottom - top,
  };
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

class LcdifTconDisplayBackend::Impl final {
public:
  struct Job {
    std::uint64_t frame_id = 0;
    Rm2PanelRect panel_rect;
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
    if (config.struct_size < sizeof(PlutoPresenterConfig) ||
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

    PlutoStatus status = device_->initialize();
    if (status != kPlutoStatusOk) {
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
    }
    try {
      worker_ = std::thread([this] { worker_main(); });
    } catch (...) {
      if (handoff_route_enabled_ && handoff_lease_.valid()) {
        (void)discard_handoff_locked();
      }
      clear_incoming_handoff_locked(HandoffDecision::kRejected);
      handoff_lease_ = GlassHandoffLease{};
      mark_lost();
      device_->close();
      waveforms_.clear();
      return kPlutoStatusInternal;
    }
    return kPlutoStatusOk;
  }

  PlutoStatus info(PlutoDisplayInfo *out_info) const {
    if (out_info == nullptr || out_info->struct_size < sizeof(*out_info)) {
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
    if (request == nullptr || request->struct_size < sizeof(*request)) {
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
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (lost_ || !started_ || !accepting_ || outstanding_) {
        return lost_ ? kPlutoStatusDeviceLost : kPlutoStatusAgain;
      }
      outstanding_ = true;
    }

    std::optional<Job> job;
    try {
      job = build_job(*request);
    } catch (const std::bad_alloc &) {
      (void)device_->blank_powerdown();
      finish_failed_admission(kPlutoStatusInternal);
      return kPlutoStatusInternal;
    }
    if (!job.has_value()) {
      (void)device_->blank_powerdown();
      finish_failed_admission(kPlutoStatusDeviceLost);
      return kPlutoStatusDeviceLost;
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
    if (focus == nullptr || focus->struct_size < sizeof(*focus) ||
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
        payload->struct_size < sizeof(PlutoHandoffPayload) ||
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
        out_payload->struct_size < sizeof(PlutoHandoffPayload)) {
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
    idle_cv_.notify_all();
  }

private:
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

  bool pan_with_deadline(std::uint32_t slot) {
    std::chrono::nanoseconds duration;
    if (device_->pan(slot, &duration) != kPlutoStatusOk) {
      return false;
    }
    const std::chrono::nanoseconds interval(
        *profile_.runtime.display.phase_interval_nanoseconds);
    const auto limit =
        std::max(std::chrono::duration_cast<std::chrono::nanoseconds>(
                     std::chrono::milliseconds(50)),
                 interval * 4);
    return duration <= limit;
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

  std::optional<Job> build_job(const PlutoPresentRequest &request) {
    PlutoRect damage = bounding_rect(request.damage, request.damage_count);
    const bool regional_full = request.refresh_class == kPlutoRefreshFull &&
                               (request.flags & kPlutoPresentFlagPenTruth) != 0;
    if (request.refresh_class == kPlutoRefreshFull && !regional_full) {
      damage = {
          .x = 0,
          .y = 0,
          .width = static_cast<std::int32_t>(kRm2PanelWidth),
          .height = static_cast<std::int32_t>(kRm2PanelHeight),
      };
    }

    constexpr std::int32_t kMaximumColumn =
        static_cast<std::int32_t>(kRm2PanelWidth - 1);
    constexpr std::int32_t kMaximumRow =
        static_cast<std::int32_t>(kRm2PanelHeight - 1);
    const std::int32_t user_right = damage.x + damage.width - 1;
    const std::int32_t user_bottom = damage.y + damage.height - 1;
    Rm2PanelRect panel_rect{
        .row_min = static_cast<std::uint16_t>((kMaximumRow - user_bottom) &
                                              ~std::int32_t{7}),
        .row_max = static_cast<std::uint16_t>(
            std::min(kMaximumRow, (kMaximumRow - damage.y) | 7)),
        .column_min = static_cast<std::uint16_t>(kMaximumColumn - user_right),
        .column_max = static_cast<std::uint16_t>(kMaximumColumn - damage.x),
    };

    Job job;
    job.frame_id = request.frame_id;
    job.panel_rect = panel_rect;
    job.suppress_unchanged =
        request.refresh_class != kPlutoRefreshFull || regional_full;
    const std::optional<int> temperature = read_powered_temperature(nullptr);
    if (!temperature || !waveforms_.select(request.refresh_class, *temperature,
                                           &job.waveform)) {
      return std::nullopt;
    }
    const std::size_t pixels =
        panel_rect.row_count() * panel_rect.column_count();
    job.transition_keys.resize(pixels);
    job.target_pixels.resize(pixels);
    for (std::uint32_t column = panel_rect.column_min;
         column <= panel_rect.column_max; ++column) {
      const std::size_t column_offset =
          static_cast<std::size_t>(column - panel_rect.column_min) *
          panel_rect.row_count();
      for (std::uint32_t row = panel_rect.row_min; row <= panel_rect.row_max;
           ++row) {
        const std::size_t user_x = kRm2PanelWidth - 1U - column;
        const std::size_t user_y = kRm2PanelHeight - 1U - row;
        const std::size_t source_offset =
            user_y * request.surface.stride_bytes + user_x * kBytesPerPixel;
        const std::uint16_t pixel =
            static_cast<std::uint16_t>(request.surface.pixels[source_offset]) |
            static_cast<std::uint16_t>(
                request.surface.pixels[source_offset + 1])
                << 8U;
        const std::size_t offset =
            column_offset + static_cast<std::size_t>(row - panel_rect.row_min);
        const std::size_t state_offset =
            (kRm2PanelWidth - 1U - column) * kRm2PanelHeight + row;
        const std::uint8_t old_level = settled_levels_[state_offset] & 0x0fU;
        const std::uint8_t quantized_level = rgb565_to_rm2_level(pixel);
        const std::uint8_t new_level =
            request.refresh_class == kPlutoRefreshFast
                ? rm2_fast_level(quantized_level)
                : quantized_level;
        job.target_pixels[offset] = pixel;
        job.transition_keys[offset] =
            static_cast<std::uint8_t>((new_level << 4U) | old_level);
      }
    }
    return job;
  }

  void worker_main() {
    for (;;) {
      Job job;
      {
        std::unique_lock<std::mutex> lock(state_mutex_);
        work_cv_.wait(lock,
                      [this] { return stopping_ || pending_job_.has_value(); });
        if (stopping_ && !pending_job_.has_value()) {
          return;
        }
        job = std::move(*pending_job_);
        pending_job_.reset();
      }

      const PlutoStatus status = execute(job);
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
      if (status == kPlutoStatusOk) {
        std::lock_guard<std::mutex> lock(state_mutex_);
        outstanding_ = false;
      }
      idle_cv_.notify_all();
    }
  }

  PlutoStatus execute(const Job &job) {
    const std::span<const std::uint8_t> drive_lut =
        job.suppress_unchanged ? job.waveform.partial_drive_lut
                               : job.waveform.drive_lut;
    if (drive_lut.size() !=
        static_cast<std::size_t>(job.waveform.phase_count) * 16U * 16U) {
      (void)device_->blank_powerdown();
      return kPlutoStatusInternal;
    }
    std::optional<std::uint32_t> previous_slot;
    for (std::uint32_t phase = 0; phase < job.waveform.phase_count; ++phase) {
      const std::uint32_t slot_index = phase % kRm2ActiveSlots;
      std::span<std::byte> slot = device_->slot(slot_index);
      const std::span<const std::uint8_t> phase_lut = drive_lut.subspan(
          static_cast<std::size_t>(phase) * 16U * 16U, 16U * 16U);
      if (!encode_rm2_phase(slot, job.panel_rect, job.transition_keys,
                            phase_lut)) {
        (void)device_->blank_powerdown();
        return kPlutoStatusInternal;
      }

      if (device_->is_blanked()) {
        if (device_->unblank(slot_index) != kPlutoStatusOk ||
            !pan_with_deadline(kRm2IdleSlot)) {
          (void)device_->blank_powerdown();
          return kPlutoStatusDeviceLost;
        }
        if (!clear_rm2_phase_cells(slot, job.panel_rect)) {
          (void)device_->blank_powerdown();
          return kPlutoStatusInternal;
        }
      } else if (!pan_with_deadline(slot_index)) {
        (void)device_->blank_powerdown();
        return kPlutoStatusDeviceLost;
      }

      if (previous_slot.has_value() &&
          !clear_rm2_phase_cells(device_->slot(*previous_slot),
                                 job.panel_rect)) {
        (void)device_->blank_powerdown();
        return kPlutoStatusInternal;
      }
      previous_slot = device_->is_blanked()
                          ? std::optional<std::uint32_t>{}
                          : std::optional<std::uint32_t>{slot_index};
    }
    if (!pan_with_deadline(kRm2IdleSlot)) {
      (void)device_->blank_powerdown();
      return kPlutoStatusDeviceLost;
    }
    if (previous_slot.has_value() &&
        !clear_rm2_phase_cells(device_->slot(*previous_slot), job.panel_rect)) {
      (void)device_->blank_powerdown();
      return kPlutoStatusInternal;
    }
    commit(job);
    return kPlutoStatusOk;
  }

  void commit(const Job &job) {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    const std::size_t rows = job.panel_rect.row_count();
    for (std::uint32_t column = job.panel_rect.column_min;
         column <= job.panel_rect.column_max; ++column) {
      const std::size_t target_base =
          static_cast<std::size_t>(column - job.panel_rect.column_min) * rows;
      const std::size_t state_base =
          (kRm2PanelWidth - 1U - column) * kRm2PanelHeight;
      for (std::uint32_t row = job.panel_rect.row_min;
           row <= job.panel_rect.row_max; ++row) {
        const std::size_t target_offset =
            target_base +
            static_cast<std::size_t>(row - job.panel_rect.row_min);
        settled_levels_[state_base + row] =
            static_cast<std::uint8_t>(job.transition_keys[target_offset] >> 4U);
        const std::size_t user_x = kRm2PanelWidth - 1U - column;
        const std::size_t user_y = kRm2PanelHeight - 1U - row;
        mirror_[user_y * kRm2PanelWidth + user_x] =
            job.target_pixels[target_offset];
      }
    }
  }

  void finish_failed_admission(PlutoStatus status) {
    std::lock_guard<std::mutex> lock(state_mutex_);
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
  std::string handoff_path_;
  GlassHandoffClock (*handoff_now_)() = glass_handoff_now;
  GlassHandoffIdentity handoff_identity_{};
  GlassHandoffLease handoff_lease_{};
  GlassHandoffClaim incoming_handoff_claim_{};
  GlassHandoffRendererInfo incoming_renderer_info_{};

  mutable std::mutex state_mutex_;
  mutable std::mutex frame_mutex_;
  std::mutex admission_mutex_;
  std::condition_variable work_cv_;
  std::condition_variable idle_cv_;
  std::thread worker_;
  std::optional<Job> pending_job_;
  std::vector<std::uint8_t> settled_levels_;
  std::vector<std::uint16_t> mirror_;
  std::vector<std::uint8_t> incoming_renderer_payload_;
  std::vector<std::uint8_t> incoming_settled_levels_;
  std::vector<std::uint16_t> incoming_mirror_;
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
  std::uint64_t completed_jobs_ = 0;
  std::uint64_t hardware_faults_ = 0;
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
