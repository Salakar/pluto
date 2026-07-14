#include "presenter/qtfb/qtfb_presenter.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

#include "presenter/qtfb/qtfb_client.h"

namespace pluto {
namespace {

constexpr std::size_t kBytesPerPixel = qtfb::kRgb565BytesPerPixel;

struct QtfbProfile {
  int width;
  int height;
  int dpi;
  std::uint8_t framebuffer_type;
  bool custom_resolution;
  bool is_color;
  bool backend_quantizes_color;
  bool coalesce_damage;
};

constexpr QtfbProfile kMoveProfile{
    qtfb::kRmppmWidth,
    qtfb::kRmppmHeight,
    264,
    qtfb::kFbFmtRmppmRgb565,
    true,
    true,
    true,
    false,
};

constexpr QtfbProfile kLegacyProfile{
    qtfb::kRm2Width,
    qtfb::kRm2Height,
    226,
    qtfb::kFbFmtRm2fb,
    false,
    false,
    false,
    true,
};

std::string option_value(const char *options, const char *key) {
  if (options == nullptr || key == nullptr) {
    return {};
  }
  const std::string input(options);
  const std::string needle = std::string(key) + "=";
  std::size_t pos = input.find(needle);
  while (pos != std::string::npos && pos != 0 && input[pos - 1] != ',') {
    pos = input.find(needle, pos + 1);
  }
  if (pos == std::string::npos) {
    return {};
  }
  pos += needle.size();
  const std::size_t end = input.find(',', pos);
  return input.substr(pos,
                      end == std::string::npos ? std::string::npos : end - pos);
}

bool parse_unsigned(const std::string &value, unsigned int *out) {
  if (value.empty() || out == nullptr) {
    return false;
  }
  char *end = nullptr;
  errno = 0;
  const unsigned long parsed = std::strtoul(value.c_str(), &end, 10);
  if (errno != 0 || end == value.c_str() || *end != '\0' ||
      parsed > std::numeric_limits<unsigned int>::max()) {
    return false;
  }
  *out = static_cast<unsigned int>(parsed);
  return true;
}

bool parse_int(const std::string &value, int *out) {
  if (value.empty() || out == nullptr) {
    return false;
  }
  char *end = nullptr;
  errno = 0;
  const long parsed = std::strtol(value.c_str(), &end, 10);
  if (errno != 0 || end == value.c_str() || *end != '\0' ||
      parsed < std::numeric_limits<int>::min() ||
      parsed > std::numeric_limits<int>::max()) {
    return false;
  }
  *out = static_cast<int>(parsed);
  return true;
}

bool rect_valid(const PlutoRect &rect, int width, int height) {
  return rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
         rect.x <= width && rect.y <= height && rect.width <= width - rect.x &&
         rect.height <= height - rect.y;
}

bool is_full_rect(const PlutoRect &rect, int width, int height) {
  return rect.x == 0 && rect.y == 0 && rect.width == width &&
         rect.height == height;
}

PlutoRect bounding_rect(const PlutoRect *rects, std::size_t count) {
  int left = rects[0].x;
  int top = rects[0].y;
  int right = rects[0].x + rects[0].width;
  int bottom = rects[0].y + rects[0].height;
  for (std::size_t i = 1; i < count; ++i) {
    left = std::min(left, rects[i].x);
    top = std::min(top, rects[i].y);
    right = std::max(right, rects[i].x + rects[i].width);
    bottom = std::max(bottom, rects[i].y + rects[i].height);
  }
  return PlutoRect{left, top, right - left, bottom - top};
}

int nominal_latency_ms(PlutoRefreshClass refresh_class) {
  switch (refresh_class) {
  case kPlutoRefreshFast:
    return 260;
  case kPlutoRefreshUi:
    return 450;
  case kPlutoRefreshText:
    return 800;
  case kPlutoRefreshFull:
    return 1500;
  }
  return 800;
}

PlutoDisplayInfo make_info(const QtfbProfile &profile) {
  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  info.width = profile.width;
  info.height = profile.height;
  info.dpi = profile.dpi;
  info.preferred_format = kPlutoPixelFormatRgb565;
  info.is_color = profile.is_color;
  // qtfb exposes only ALL/PARTIAL damage. xochitl still chooses waveforms; this
  // flips true only if AppLoad/qtfb later forwards a real refresh-class hint.
  info.controls_refresh_class = false;
  info.reports_completion = false;
  info.wants_pre_dithered = true;
  // Move frames land in xochitl's color SWTCON and are quantized downstream.
  // Legacy qtfb surfaces are grayscale, so the renderer supplies final tones.
  info.backend_quantizes_color = profile.backend_quantizes_color;
  // Xochitl owns the downstream update-region ledger and replaces overlap by
  // the newest submitted content/class. Pluto may therefore send pen truth
  // immediately; nominal fences remain bookkeeping, not a conflict delay.
  info.supports_overlap_supersession = true;
  info.rect_alignment = 8;
  info.max_inflight_updates = 0;
  info.nominal_latency_ms[0] = nominal_latency_ms(kPlutoRefreshFast);
  info.nominal_latency_ms[1] = nominal_latency_ms(kPlutoRefreshUi);
  info.nominal_latency_ms[2] = nominal_latency_ms(kPlutoRefreshText);
  info.nominal_latency_ms[3] = nominal_latency_ms(kPlutoRefreshFull);
  return info;
}

class QtfbPresenter final {
public:
  PlutoStatus open(const PlutoPresenterConfig *config) {
    if (config != nullptr &&
        config->struct_size < sizeof(PlutoPresenterConfig)) {
      return kPlutoStatusInvalidArgument;
    }

    QtfbClient::Config client_config;
    client_config.socket_path = QtfbClient::socket_path_from_env();
    client_config.framebuffer_key = QtfbClient::framebuffer_key_from_env();
    profile_ = kMoveProfile;
    if (config != nullptr) {
      const std::string socket = option_value(config->options, "socket");
      const std::string ctrl = option_value(config->options, "ctrl");
      const std::string key = option_value(config->options, "key");
      const std::string profile = option_value(config->options, "profile");
      const std::string send_buffer =
          option_value(config->options, "send_buffer");
      const std::string transport = option_value(config->options, "transport");
      if (!socket.empty()) {
        client_config.socket_path = socket;
      } else if (!ctrl.empty()) {
        client_config.socket_path = ctrl;
      }
      unsigned int parsed_framebuffer_key = 0;
      if (!key.empty() && (!parse_unsigned(key, &parsed_framebuffer_key) ||
                           parsed_framebuffer_key >
                               static_cast<unsigned int>(
                                   std::numeric_limits<qtfb::FBKey>::max()))) {
        return kPlutoStatusInvalidArgument;
      }
      if (!key.empty()) {
        client_config.framebuffer_key =
            static_cast<qtfb::FBKey>(parsed_framebuffer_key);
      }
      if (profile == "legacy") {
        profile_ = kLegacyProfile;
      } else if (!profile.empty() && profile != "move") {
        return kPlutoStatusInvalidArgument;
      }
      if (!send_buffer.empty() &&
          !parse_int(send_buffer, &client_config.send_buffer_bytes)) {
        return kPlutoStatusInvalidArgument;
      }
      if (transport == "stream") {
        client_config.stream_transport = true;
      } else if (!transport.empty() && transport != "seqpacket") {
        return kPlutoStatusInvalidArgument;
      }
    }

    client_config.width = profile_.width;
    client_config.height = profile_.height;
    client_config.framebuffer_type = profile_.framebuffer_type;
    client_config.custom_resolution = profile_.custom_resolution;

    PlutoStatus status = client_.open(client_config);
    if (status != kPlutoStatusOk) {
      return status;
    }
    frame_.assign(frame_size(), 0);
    info_ = make_info(profile_);
    return kPlutoStatusOk;
  }

  void close() {
    std::lock_guard<std::mutex> lock(mutex_);
    client_.close();
    frame_.clear();
  }

  PlutoStatus info(PlutoDisplayInfo *out_info) {
    if (out_info == nullptr ||
        out_info->struct_size < sizeof(PlutoDisplayInfo)) {
      return kPlutoStatusInvalidArgument;
    }
    *out_info = info_;
    return kPlutoStatusOk;
  }

  bool ready(PlutoRefreshClass) const { return client_.ready(); }

  PlutoStatus present(const PlutoPresentRequest *request) {
    if (request == nullptr ||
        request->struct_size < sizeof(PlutoPresentRequest)) {
      return kPlutoStatusInvalidArgument;
    }
    const PlutoStatus validation = validate_request(*request);
    if (validation != kPlutoStatusOk) {
      return validation;
    }
    if (!client_.ready()) {
      return client_.device_lost() ? kPlutoStatusDeviceLost : kPlutoStatusAgain;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (client_.device_lost()) {
      return kPlutoStatusDeviceLost;
    }
    if ((request->flags & kPlutoPresentFlagSparkle) != 0) {
      // qtfb carries only framebuffer bytes plus ALL/PARTIAL. It cannot
      // express the sparse per-pixel phase mask, so copying this rect would
      // turn one nominal 1/256 maintenance pass into a full black-square
      // update every 350 ms. The presenter ABI requires unsupported sparkle
      // maintenance to complete as an accepted no-op.
      return kPlutoStatusOk;
    }
    copy_damage(*request);

    PlutoStatus status = kPlutoStatusOk;
    bool sent_any = false;
    if (should_send_complete(*request)) {
      status = client_.send_complete_update();
      sent_any = status == kPlutoStatusOk;
    } else if (profile_.coalesce_damage && request->damage_count > 1) {
      const PlutoRect damage =
          bounding_rect(request->damage, request->damage_count);
      status = client_.send_partial_update(damage.x, damage.y, damage.width,
                                           damage.height);
      sent_any = status == kPlutoStatusOk;
    } else {
      for (std::size_t i = 0; i < request->damage_count; ++i) {
        const PlutoRect &rect = request->damage[i];
        status = client_.send_partial_update(rect.x, rect.y, rect.width,
                                             rect.height);
        if (status != kPlutoStatusOk) {
          break;
        }
        sent_any = true;
      }
    }
    if (sent_any) {
      const auto request_idle_after =
          std::chrono::steady_clock::now() +
          std::chrono::milliseconds(nominal_latency_ms(request->refresh_class));
      // qtfb has no real optical completion signal, so this deadline is the
      // fence for every accepted update still developing downstream. Arm it
      // even when a later rect in this request hits backpressure: the earlier
      // packets are already owned by xochitl. Pen overlap supersession may
      // legally submit a short Fast preview while an earlier Full truth request
      // is outstanding; the later request must extend the fence when necessary,
      // never shorten it.
      idle_after_ = std::max(idle_after_, request_idle_after);
    }
    return status;
  }

  PlutoStatus wait_idle(std::uint32_t timeout_ms) {
    const auto now = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point until;
    {
      // idle_after_ is written by present() under mutex_; sample it under the
      // same lock instead of racing the write.
      std::lock_guard<std::mutex> lock(mutex_);
      until = idle_after_;
    }
    if (now >= until) {
      return kPlutoStatusOk;
    }
    const auto wait = until - now;
    const auto timeout = std::chrono::milliseconds(timeout_ms);
    if (wait > timeout) {
      if (timeout_ms > 0) {
        std::this_thread::sleep_for(timeout);
      }
      return kPlutoStatusTimeout;
    }
    std::this_thread::sleep_for(wait);
    return kPlutoStatusOk;
  }

  PlutoStatus snapshot(PlutoSurface *out_surface) {
    if (out_surface == nullptr || out_surface->pixels == nullptr ||
        out_surface->width != profile_.width ||
        out_surface->height != profile_.height ||
        out_surface->format != kPlutoPixelFormatRgb565 ||
        out_surface->stride_bytes < tight_stride()) {
      return kPlutoStatusInvalidArgument;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (frame_.size() != frame_size()) {
      return kPlutoStatusDeviceLost;
    }
    auto *out = const_cast<std::uint8_t *>(out_surface->pixels);
    for (int y = 0; y < profile_.height; ++y) {
      std::memcpy(out + static_cast<std::size_t>(y) * out_surface->stride_bytes,
                  frame_.data() + static_cast<std::size_t>(y) * tight_stride(),
                  tight_stride());
    }
    return kPlutoStatusOk;
  }

  PlutoStatus receive_user_input(qtfb::UserInputContents *out_input) {
    return client_.receive_user_input(out_input);
  }

private:
  std::size_t tight_stride() const {
    return static_cast<std::size_t>(profile_.width) * kBytesPerPixel;
  }

  std::size_t frame_size() const {
    return tight_stride() * static_cast<std::size_t>(profile_.height);
  }

  PlutoStatus validate_request(const PlutoPresentRequest &request) const {
    const PlutoSurface &surface = request.surface;
    if (surface.pixels == nullptr || surface.width != profile_.width ||
        surface.height != profile_.height ||
        surface.format != kPlutoPixelFormatRgb565 ||
        surface.stride_bytes < tight_stride() || request.damage == nullptr ||
        request.damage_count == 0) {
      return kPlutoStatusInvalidArgument;
    }
    for (std::size_t i = 0; i < request.damage_count; ++i) {
      if (!rect_valid(request.damage[i], profile_.width, profile_.height)) {
        return kPlutoStatusInvalidArgument;
      }
    }
    return kPlutoStatusOk;
  }

  bool should_send_complete(const PlutoPresentRequest &request) const {
    // Ordinary Full retains the historical qtfb UPDATE_ALL mapping. A pen
    // truth chase is different: Full selects fidelity, while the explicitly
    // correlated app-damage rectangles remain regional. Hints alone never
    // reach this path; the renderer must have supplied actual damage.
    const bool regional_pen_truth =
        (request.flags & kPlutoPresentFlagPenTruth) != 0;
    if (request.refresh_class == kPlutoRefreshFull && !regional_pen_truth) {
      return true;
    }
    return request.damage_count == 1 &&
           is_full_rect(request.damage[0], profile_.width, profile_.height);
  }

  void copy_damage(const PlutoPresentRequest &request) {
    const PlutoSurface &surface = request.surface;
    std::uint8_t *shm = client_.framebuffer();
    const std::size_t shm_stride = client_.stride_bytes();

    for (std::size_t i = 0; i < request.damage_count; ++i) {
      const PlutoRect &rect = request.damage[i];
      const std::size_t row_bytes =
          static_cast<std::size_t>(rect.width) * kBytesPerPixel;
      for (int y = 0; y < rect.height; ++y) {
        const std::size_t src_offset =
            static_cast<std::size_t>(rect.y + y) * surface.stride_bytes +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        const std::size_t tight_offset =
            static_cast<std::size_t>(rect.y + y) * tight_stride() +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        const std::size_t shm_offset =
            static_cast<std::size_t>(rect.y + y) * shm_stride +
            static_cast<std::size_t>(rect.x) * kBytesPerPixel;
        std::memcpy(frame_.data() + tight_offset, surface.pixels + src_offset,
                    row_bytes);
        std::memcpy(shm + shm_offset, surface.pixels + src_offset, row_bytes);
      }
    }
  }

  mutable std::mutex mutex_;
  QtfbClient client_;
  QtfbProfile profile_ = kMoveProfile;
  PlutoDisplayInfo info_{};
  std::vector<std::uint8_t> frame_;
  std::chrono::steady_clock::time_point idle_after_{};
};

PlutoStatus qtfb_open(const PlutoPresenterConfig *config,
                      PlutoPresenter **out_presenter) {
  if (out_presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  *out_presenter = nullptr;
  auto *presenter = new (std::nothrow) QtfbPresenter();
  if (presenter == nullptr) {
    return kPlutoStatusInternal;
  }
  try {
    const PlutoStatus status = presenter->open(config);
    if (status != kPlutoStatusOk) {
      delete presenter;
      return status;
    }
  } catch (...) {
    delete presenter;
    return kPlutoStatusInternal;
  }
  *out_presenter = reinterpret_cast<PlutoPresenter *>(presenter);
  return kPlutoStatusOk;
}

void qtfb_close(PlutoPresenter *presenter) {
  auto *qtfb = reinterpret_cast<QtfbPresenter *>(presenter);
  delete qtfb;
}

PlutoStatus qtfb_info(PlutoPresenter *presenter, PlutoDisplayInfo *out_info) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<QtfbPresenter *>(presenter)->info(out_info);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

PlutoStatus qtfb_present(PlutoPresenter *presenter,
                         const PlutoPresentRequest *request) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<QtfbPresenter *>(presenter)->present(request);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

bool qtfb_ready(PlutoPresenter *presenter, PlutoRefreshClass refresh_class) {
  if (presenter == nullptr) {
    return false;
  }
  try {
    return reinterpret_cast<QtfbPresenter *>(presenter)->ready(refresh_class);
  } catch (...) {
    return false;
  }
}

PlutoStatus qtfb_wait_idle(PlutoPresenter *presenter,
                           std::uint32_t timeout_ms) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<QtfbPresenter *>(presenter)->wait_idle(timeout_ms);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

PlutoStatus qtfb_snapshot(PlutoPresenter *presenter,
                          PlutoSurface *out_surface) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<QtfbPresenter *>(presenter)->snapshot(out_surface);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

const PlutoPresenterOps kQtfbOps{
    sizeof(PlutoPresenterOps),
    "qtfb",
    qtfb_open,
    qtfb_close,
    qtfb_info,
    qtfb_present,
    qtfb_ready,
    qtfb_wait_idle,
    qtfb_snapshot,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};

} // namespace

PlutoStatus qtfb_receive_user_input(PlutoPresenter *presenter,
                                    qtfb::UserInputContents *out_input) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  try {
    return reinterpret_cast<QtfbPresenter *>(presenter)->receive_user_input(
        out_input);
  } catch (...) {
    return kPlutoStatusInternal;
  }
}

} // namespace pluto

extern "C" {

const PlutoPresenterOps *pluto_qtfb_presenter_ops(void) {
  return &pluto::kQtfbOps;
}

} // extern "C"
