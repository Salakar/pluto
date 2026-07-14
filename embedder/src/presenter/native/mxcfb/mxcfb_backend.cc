#include "presenter/native/mxcfb/mxcfb_backend.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace pluto::native::mxcfb {
namespace {

constexpr std::string_view kDriverName = "mxcfb_epdc";
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

} // namespace

class MxcfbDisplayBackend::Impl final {
public:
  Impl(const GeneratedDeviceProfile &profile,
       std::unique_ptr<MxcfbDevice> device, std::uint32_t first_marker)
      : profile_(profile),
        device_(device == nullptr ? std::make_unique<MxcfbDevice>()
                                  : std::move(device)),
        next_marker_(first_marker == 0 ? 1 : first_marker) {}

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

    const MxcfbFramebufferInfo &framebuffer_info = device_->framebuffer_info();
    const std::span<std::byte> framebuffer = device_->framebuffer();
    const std::size_t tight_stride = this->tight_stride();
    const std::size_t required_mapping =
        static_cast<std::size_t>(framebuffer_info.stride_bytes) *
        framebuffer_info.virtual_height;
    if (framebuffer_info.width !=
            static_cast<std::uint32_t>(profile_.panel.width) ||
        framebuffer_info.height !=
            static_cast<std::uint32_t>(profile_.panel.height) ||
        framebuffer_info.stride_bytes < tight_stride ||
        framebuffer.size() < required_mapping) {
      mark_lost();
      return kPlutoStatusUnsupported;
    }

    try {
      std::lock_guard<std::mutex> frame_lock(frame_mutex_);
      mirror_.resize(tight_stride *
                     static_cast<std::size_t>(profile_.panel.height));
      for (int y = 0; y < profile_.panel.height; ++y) {
        std::memcpy(mirror_.data() + static_cast<std::size_t>(y) * tight_stride,
                    framebuffer.data() + static_cast<std::size_t>(y) *
                                             framebuffer_info.stride_bytes,
                    tight_stride);
      }
    } catch (const std::bad_alloc &) {
      mark_lost();
      return kPlutoStatusInternal;
    }

    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      callback_ = config.on_complete;
      callback_user_data_ = config.user_data;
      accepting_ = true;
      stopping_ = false;
      started_ = true;
    }
    try {
      worker_ = std::thread([this] { completion_worker(); });
    } catch (...) {
      std::lock_guard<std::mutex> lock(state_mutex_);
      accepting_ = false;
      started_ = false;
      lost_ = true;
      ++hardware_faults_;
      return kPlutoStatusInternal;
    }
    return kPlutoStatusOk;
  }

  PlutoStatus info(PlutoDisplayInfo *out_info) const {
    if (out_info == nullptr || out_info->struct_size < sizeof(*out_info)) {
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
    // Until the stock trace/camera oracle pins individual RM1 modes, every
    // regional class uses AUTO and therefore shares one conservative fence.
    // Full retains a pessimistic whole-panel budget.
    info.nominal_latency_ms[0] = 500;
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
        request->struct_size < sizeof(PlutoPresentRequest)) {
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
      outstanding_ = true;
      marker = allocate_marker_locked();
    }

    uapi::UpdateData update{};
    update.update_region =
        bounding_region(request->damage, request->damage_count);
    update.waveform_mode = uapi::kWaveformModeAuto;
    update.update_mode = uapi::kUpdateModePartial;
    update.update_marker = marker;
    update.temperature = uapi::kTemperatureUseAmbient;
    if (request->refresh_class == kPlutoRefreshFull) {
      update.update_region = {
          .top = 0,
          .left = 0,
          .width = static_cast<std::uint32_t>(profile_.panel.width),
          .height = static_cast<std::uint32_t>(profile_.panel.height),
      };
      update.update_mode = uapi::kUpdateModeFull;
    }

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
    if (focus == nullptr || focus->struct_size < sizeof(PlutoPenFocus) ||
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

  mutable std::mutex admission_mutex_;
  mutable std::mutex state_mutex_;
  mutable std::mutex frame_mutex_;
  std::condition_variable work_cv_;
  std::condition_variable idle_cv_;
  std::thread worker_;
  std::optional<CompletionJob> pending_job_;
  std::vector<std::uint8_t> mirror_;

  PlutoPresentCompleteCallback callback_ = nullptr;
  void *callback_user_data_ = nullptr;
  std::uint32_t next_marker_ = 1;
  std::uint64_t completed_jobs_ = 0;
  std::uint64_t hardware_faults_ = 0;
  bool probed_ = false;
  bool started_ = false;
  bool accepting_ = false;
  bool stopping_ = false;
  bool suspended_ = false;
  bool lost_ = false;
  bool outstanding_ = false;
};

MxcfbDisplayBackend::MxcfbDisplayBackend(const GeneratedDeviceProfile &profile,
                                         std::unique_ptr<MxcfbDevice> device,
                                         std::uint32_t first_marker)
    : impl_(std::make_unique<Impl>(profile, std::move(device), first_marker)) {}

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

PlutoStatus MxcfbDisplayBackend::stage_handoff(const PlutoHandoffPayload *,
                                               std::uint32_t) {
  return kPlutoStatusUnsupported;
}

PlutoStatus MxcfbDisplayBackend::get_handoff(PlutoHandoffPayload *) {
  return kPlutoStatusUnsupported;
}

PlutoStatus MxcfbDisplayBackend::confirm_handoff(bool) {
  return kPlutoStatusUnsupported;
}

PlutoStatus MxcfbDisplayBackend::suspend(std::uint32_t timeout_ms) {
  return impl_->suspend(timeout_ms);
}

PlutoStatus MxcfbDisplayBackend::resume() { return impl_->resume(); }

NativeBackendHealth MxcfbDisplayBackend::health() const {
  return impl_->health();
}

void MxcfbDisplayBackend::stop() { impl_->stop(); }

} // namespace pluto::native::mxcfb
