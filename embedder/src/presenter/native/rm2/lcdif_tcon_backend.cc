#include "presenter/native/rm2/lcdif_tcon_backend.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "presenter/native/rm2/rm2_scan_encoder.h"
#include "presenter/native/rm2/rm2_waveform_program.h"

namespace pluto::native::rm2 {
namespace {

constexpr std::string_view kDriverName = "lcdif_tcon";
constexpr std::size_t kBytesPerPixel = 2;
constexpr std::size_t kMaximumDamageRects = 64;
constexpr std::uint32_t kKnownPresentFlags =
    kPlutoPresentFlagInkPriority | kPlutoPresentFlagPreDithered |
    kPlutoPresentFlagSettle | kPlutoPresentFlagSparkle |
    kPlutoPresentFlagSparkleDevelop | kPlutoPresentFlagPixelResetBlack |
    kPlutoPresentFlagPixelResetWhite | kPlutoPresentFlagPixelResetRestore |
    kPlutoPresentFlagRequiredSettle | kPlutoPresentFlagPenTruth |
    kPlutoPresentSparklePhaseMask;

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
       Rm2TemperatureReader temperature_reader)
      : profile_(profile),
        device_(device == nullptr ? std::make_unique<MxsLcdifDevice>()
                                  : std::move(device)),
        temperature_reader_(temperature_reader
                                ? std::move(temperature_reader)
                                : read_rm2_panel_temperature_millidegrees) {}

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
    const PlutoStatus status = device_->open(profile);
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (status == kPlutoStatusOk) {
      probed_ = true;
    } else if (status == kPlutoStatusDeviceLost ||
               status == kPlutoStatusInternal) {
      lost_ = true;
      ++hardware_faults_;
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
    const std::optional<int> temperature = temperature_reader_(&error);
    std::vector<std::uint8_t> init_codes;
    Rm2WaveformSelection selection;
    if (!temperature.has_value() ||
        !waveforms_.select(kPlutoRefreshFast, *temperature, &selection) ||
        !waveforms_.select(kPlutoRefreshUi, *temperature, &selection) ||
        !waveforms_.select(kPlutoRefreshText, *temperature, &selection) ||
        !waveforms_.select(kPlutoRefreshFull, *temperature, &selection) ||
        !waveforms_.init_pan_codes(*temperature, &init_codes)) {
      waveforms_.clear();
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
        mark_lost();
        device_->close();
        waveforms_.clear();
        return kPlutoStatusInternal;
      }
    }
    if (!run_init_clear(init_codes)) {
      mark_lost();
      device_->close();
      waveforms_.clear();
      return kPlutoStatusDeviceLost;
    }

    try {
      settled_levels_.assign(kRm2PanelWidth * kRm2PanelHeight, 15);
      mirror_.assign(kRm2PanelWidth * kRm2PanelHeight, 0xffffU);
    } catch (const std::bad_alloc &) {
      mark_lost();
      device_->close();
      waveforms_.clear();
      return kPlutoStatusInternal;
    }
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      callback_ = config.on_complete;
      callback_user_data_ = config.user_data;
      accepting_ = true;
      started_ = true;
      stopping_ = false;
    }
    try {
      worker_ = std::thread([this] { worker_main(); });
    } catch (...) {
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
      return kPlutoStatusUnsupported;
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
    return {
        .state = lost_ ? NativeBackendHealthState::kDeviceLost
                       : (outstanding_ ? NativeBackendHealthState::kBusy
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
  bool run_init_clear(const std::vector<std::uint8_t> &codes) {
    if (codes.empty() || !fill_rm2_scan_slot(device_->slot(0), 0) ||
        !fill_rm2_scan_slot(device_->slot(1), 0x5555U) ||
        !fill_rm2_scan_slot(device_->slot(2), 0xaaaaU)) {
      return false;
    }
    if (device_->unblank(codes.front()) != kPlutoStatusOk ||
        !pan_with_deadline(kRm2IdleSlot)) {
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
    const std::optional<int> temperature = temperature_reader_(nullptr);
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
        const std::uint8_t new_level = rgb565_to_rm2_level(pixel);
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
  Rm2WaveformProgram waveforms_;

  mutable std::mutex state_mutex_;
  mutable std::mutex frame_mutex_;
  std::mutex admission_mutex_;
  std::condition_variable work_cv_;
  std::condition_variable idle_cv_;
  std::thread worker_;
  std::optional<Job> pending_job_;
  std::vector<std::uint8_t> settled_levels_;
  std::vector<std::uint16_t> mirror_;
  PlutoPresentCompleteCallback callback_ = nullptr;
  void *callback_user_data_ = nullptr;
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
    Rm2TemperatureReader temperature_reader)
    : impl_(std::make_unique<Impl>(profile, std::move(device),
                                   std::move(temperature_reader))) {}

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
PlutoStatus LcdifTconDisplayBackend::stage_handoff(const PlutoHandoffPayload *,
                                                   std::uint32_t) {
  return kPlutoStatusUnsupported;
}
PlutoStatus LcdifTconDisplayBackend::get_handoff(PlutoHandoffPayload *) {
  return kPlutoStatusUnsupported;
}
PlutoStatus LcdifTconDisplayBackend::confirm_handoff(bool) {
  return kPlutoStatusUnsupported;
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
