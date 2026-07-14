#include "presenter/host_preview.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "presenter/png_encoder.h"

struct PlutoPresenter {
  std::mutex mutex;
  std::string name = "null";
  std::filesystem::path output_dir = std::filesystem::temp_directory_path();
  std::string prefix = "pluto-frame";
  PlutoDisplayInfo info{};
  PlutoPresentCompleteCallback on_complete = nullptr;
  void *user_data = nullptr;
  std::vector<uint8_t> frame;
  PlutoPixelFormat format = kPlutoPixelFormatRgb565;
  int32_t width = 954;
  int32_t height = 1696;
  size_t stride = 954u * 2u;
  uint64_t saved_count = 0;
  bool write_png = false;
  // Completion delivery is deferred to this worker so on_complete never runs
  // on the present() stack: callers may re-enter the pipeline from it
  // (presenter.h:96-99), which deadlocks a non-recursive caller mutex.
  std::mutex completion_mutex;
  std::condition_variable completion_cv;
  std::deque<uint64_t> completion_queue;
  bool completion_stop = false;
  std::thread completion_thread;
};

namespace {

size_t bytes_per_pixel(PlutoPixelFormat format) {
  switch (format) {
  case kPlutoPixelFormatGray8:
    return 1;
  case kPlutoPixelFormatRgb565:
    return 2;
  case kPlutoPixelFormatXrgb8888:
    return 4;
  }
  return 0;
}

bool write_png_rgba(const std::filesystem::path &path, const uint8_t *pixels,
                    int32_t width, int32_t height, size_t stride,
                    PlutoPixelFormat format) {
  std::vector<uint8_t> png;
  if (!pluto::encode_png(pixels, width, height, stride, format, &png)) {
    return false;
  }
  std::ofstream file(path, std::ios::binary);
  if (!file) {
    return false;
  }
  file.write(reinterpret_cast<const char *>(png.data()),
             static_cast<std::streamsize>(png.size()));
  return file.good();
}

void run_completion_loop(PlutoPresenter *presenter) {
  std::unique_lock<std::mutex> lock(presenter->completion_mutex);
  for (;;) {
    presenter->completion_cv.wait(lock, [presenter] {
      return presenter->completion_stop || !presenter->completion_queue.empty();
    });
    if (presenter->completion_queue.empty()) {
      return; // stop requested and fully drained
    }
    const uint64_t frame_id = presenter->completion_queue.front();
    lock.unlock();
    presenter->on_complete(frame_id, presenter->user_data);
    lock.lock();
    // Popped only after delivery so an empty queue in wait_idle means every
    // completion has been handed to the callback.
    presenter->completion_queue.pop_front();
    if (presenter->completion_queue.empty()) {
      presenter->completion_cv.notify_all();
    }
  }
}

void post_completion(PlutoPresenter *presenter, uint64_t frame_id) {
  if (presenter->on_complete == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(presenter->completion_mutex);
    presenter->completion_queue.push_back(frame_id);
  }
  presenter->completion_cv.notify_all();
}

std::string option_value(const char *options, const char *key) {
  if (options == nullptr) {
    return {};
  }
  const std::string input(options);
  const std::string needle = std::string(key) + "=";
  size_t pos = input.find(needle);
  if (pos == std::string::npos) {
    return {};
  }
  pos += needle.size();
  const size_t end = input.find(',', pos);
  return input.substr(pos,
                      end == std::string::npos ? std::string::npos : end - pos);
}

PlutoDisplayInfo default_info(PlutoPixelFormat format) {
  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  info.width = 954;
  info.height = 1696;
  info.dpi = 264;
  info.preferred_format = format;
  info.is_color = true;
  info.controls_refresh_class = true;
  info.reports_completion = true;
  info.wants_pre_dithered = true;
  // The host preview quantizes nothing itself; leaving this false makes the
  // renderer run its own Gallery-3 palette pass, so preview output shows
  // device-ish color limits instead of full sRGB.
  info.backend_quantizes_color = false;
  info.rect_alignment = 1;
  info.max_inflight_updates = 0;
  info.nominal_latency_ms[0] = 0;
  info.nominal_latency_ms[1] = 0;
  info.nominal_latency_ms[2] = 0;
  info.nominal_latency_ms[3] = 0;
  return info;
}

PlutoStatus open_common(const PlutoPresenterConfig *config,
                        PlutoPresenter **out_presenter, bool write_png,
                        const char *name) {
  if (out_presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  auto *presenter = new PlutoPresenter();
  presenter->name = name;
  presenter->write_png = write_png;
  presenter->info = default_info(kPlutoPixelFormatRgb565);
  presenter->on_complete = config == nullptr ? nullptr : config->on_complete;
  presenter->user_data = config == nullptr ? nullptr : config->user_data;
  if (config != nullptr) {
    const std::string dir = option_value(config->options, "dir");
    const std::string prefix = option_value(config->options, "prefix");
    if (!dir.empty()) {
      presenter->output_dir = dir;
    }
    if (!prefix.empty()) {
      presenter->prefix = prefix;
    }
  }
  if (write_png) {
    std::error_code ec;
    std::filesystem::create_directories(presenter->output_dir, ec);
    if (ec) {
      delete presenter;
      return kPlutoStatusInternal;
    }
  }
  if (presenter->on_complete != nullptr) {
    presenter->completion_thread = std::thread(run_completion_loop, presenter);
  }
  *out_presenter = presenter;
  return kPlutoStatusOk;
}

PlutoStatus host_open(const PlutoPresenterConfig *config,
                      PlutoPresenter **out_presenter) {
  return open_common(config, out_presenter, true, "host-headless");
}

PlutoStatus null_open(const PlutoPresenterConfig *config,
                      PlutoPresenter **out_presenter) {
  return open_common(config, out_presenter, false, "null");
}

void close_presenter(PlutoPresenter *presenter) {
  if (presenter == nullptr) {
    return;
  }
  if (presenter->completion_thread.joinable()) {
    {
      std::lock_guard<std::mutex> lock(presenter->completion_mutex);
      presenter->completion_stop = true;
    }
    presenter->completion_cv.notify_all();
    presenter->completion_thread.join();
  }
  delete presenter;
}

PlutoStatus presenter_info(PlutoPresenter *presenter,
                           PlutoDisplayInfo *out_info) {
  if (presenter == nullptr || out_info == nullptr ||
      out_info->struct_size < sizeof(PlutoDisplayInfo)) {
    return kPlutoStatusInvalidArgument;
  }
  std::lock_guard<std::mutex> lock(presenter->mutex);
  *out_info = presenter->info;
  return kPlutoStatusOk;
}

bool rect_valid(const PlutoRect &rect, int32_t width, int32_t height) {
  return rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
         rect.x + rect.width <= width && rect.y + rect.height <= height;
}

PlutoStatus copy_damage(PlutoPresenter *presenter,
                        const PlutoPresentRequest *request) {
  const PlutoSurface &surface = request->surface;
  if (surface.pixels == nullptr || surface.width <= 0 || surface.height <= 0 ||
      request->damage == nullptr || request->damage_count == 0 ||
      surface.stride_bytes < static_cast<size_t>(surface.width) *
                                 bytes_per_pixel(surface.format)) {
    return kPlutoStatusInvalidArgument;
  }
  for (size_t i = 0; i < request->damage_count; ++i) {
    if (!rect_valid(request->damage[i], surface.width, surface.height)) {
      return kPlutoStatusInvalidArgument;
    }
  }

  const size_t bpp = bytes_per_pixel(surface.format);
  const size_t frame_stride = static_cast<size_t>(surface.width) * bpp;
  const size_t frame_size = frame_stride * static_cast<size_t>(surface.height);
  if (presenter->frame.size() != frame_size ||
      presenter->format != surface.format ||
      presenter->width != surface.width ||
      presenter->height != surface.height) {
    presenter->frame.assign(frame_size, 0);
    presenter->format = surface.format;
    presenter->width = surface.width;
    presenter->height = surface.height;
    presenter->stride = frame_stride;
  }

  for (size_t i = 0; i < request->damage_count; ++i) {
    const PlutoRect &rect = request->damage[i];
    const size_t row_bytes = static_cast<size_t>(rect.width) * bpp;
    for (int32_t y = 0; y < rect.height; ++y) {
      const size_t src_offset =
          static_cast<size_t>(rect.y + y) * surface.stride_bytes +
          static_cast<size_t>(rect.x) * bpp;
      const size_t dst_offset = static_cast<size_t>(rect.y + y) * frame_stride +
                                static_cast<size_t>(rect.x) * bpp;
      std::memcpy(presenter->frame.data() + dst_offset,
                  surface.pixels + src_offset, row_bytes);
    }
  }
  return kPlutoStatusOk;
}

PlutoStatus presenter_present(PlutoPresenter *presenter,
                              const PlutoPresentRequest *request) {
  if (presenter == nullptr || request == nullptr ||
      request->struct_size < sizeof(PlutoPresentRequest)) {
    return kPlutoStatusInvalidArgument;
  }
  if ((request->flags & kPlutoPresentFlagSparkle) != 0) {
    // Sparkle top-off passes are per-pixel drive maintenance with no
    // content of their own; a preview surface has no ghost to repair, so
    // the correct optical approximation is a completed no-op. Copying the
    // surface here would double-present content and break replay
    // determinism (pass counts are wall-clock paced).
    post_completion(presenter, request->frame_id);
    return kPlutoStatusOk;
  }
  if (!presenter->write_png && presenter->name == "null") {
    post_completion(presenter, request->frame_id);
    return kPlutoStatusOk;
  }
  {
    std::lock_guard<std::mutex> lock(presenter->mutex);
    PlutoStatus status = copy_damage(presenter, request);
    if (status != kPlutoStatusOk) {
      return status;
    }
    if (presenter->write_png) {
      char filename[128];
      std::snprintf(filename, sizeof(filename), "%s-%06llu.png",
                    presenter->prefix.c_str(),
                    static_cast<unsigned long long>(++presenter->saved_count));
      if (!write_png_rgba(presenter->output_dir / filename,
                          presenter->frame.data(), presenter->width,
                          presenter->height, presenter->stride,
                          presenter->format)) {
        return kPlutoStatusInternal;
      }
    }
  }
  post_completion(presenter, request->frame_id);
  return kPlutoStatusOk;
}

bool presenter_ready(PlutoPresenter *, PlutoRefreshClass) { return true; }

PlutoStatus presenter_wait_idle(PlutoPresenter *presenter,
                                uint32_t timeout_ms) {
  if (presenter == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  if (!presenter->completion_thread.joinable()) {
    return kPlutoStatusOk;
  }
  // Completions are deferred; idle means the worker delivered them all.
  // timeout_ms == 0 is a non-blocking poll, matching qtfb.
  std::unique_lock<std::mutex> lock(presenter->completion_mutex);
  const bool idle = presenter->completion_cv.wait_for(
      lock, std::chrono::milliseconds(timeout_ms),
      [presenter] { return presenter->completion_queue.empty(); });
  return idle ? kPlutoStatusOk : kPlutoStatusTimeout;
}

PlutoStatus presenter_snapshot(PlutoPresenter *presenter,
                               PlutoSurface *out_surface) {
  if (presenter == nullptr || out_surface == nullptr ||
      out_surface->pixels == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  std::lock_guard<std::mutex> lock(presenter->mutex);
  if (out_surface->width != presenter->width ||
      out_surface->height != presenter->height ||
      out_surface->format != presenter->format ||
      out_surface->stride_bytes < presenter->stride) {
    return kPlutoStatusInvalidArgument;
  }
  const size_t size =
      presenter->stride * static_cast<size_t>(presenter->height);
  std::memcpy(const_cast<uint8_t *>(out_surface->pixels),
              presenter->frame.data(), std::min(size, presenter->frame.size()));
  return kPlutoStatusOk;
}

const PlutoPresenterOps k_host_ops{
    sizeof(PlutoPresenterOps),
    "host-headless",
    host_open,
    close_presenter,
    presenter_info,
    presenter_present,
    presenter_ready,
    presenter_wait_idle,
    presenter_snapshot,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};

const PlutoPresenterOps k_null_ops{
    sizeof(PlutoPresenterOps),
    "null",
    null_open,
    close_presenter,
    presenter_info,
    presenter_present,
    presenter_ready,
    presenter_wait_idle,
    presenter_snapshot,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};

} // namespace

extern "C" {

const PlutoPresenterOps *pluto_host_preview_presenter_ops(void) {
  return &k_host_ops;
}

const PlutoPresenterOps *pluto_null_presenter_ops(void) { return &k_null_ops; }

const PlutoPresenterOps *pluto_presenter_by_name(const char *name) {
  if (name == nullptr || std::strcmp(name, "host-headless") == 0 ||
      std::strcmp(name, "host-png") == 0 ||
      std::strcmp(name, "host-preview") == 0) {
    return &k_host_ops;
  }
  if (std::strcmp(name, "null") == 0) {
    return &k_null_ops;
  }
  return nullptr;
}

const PlutoPresenterOps *pluto_presenter_probe(void) { return &k_host_ops; }

} // extern "C"
