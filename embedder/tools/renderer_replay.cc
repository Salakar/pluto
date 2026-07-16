// renderer_replay: single-pipeline replay harness for the renderer.
//
// Replays a PLUTO_RECORD_FRAMES stream (software_compositor.cc) through the
// FrameRenderer against the host_preview presenter, prints damage-rect
// efficiency (update count, damaged px, per class), and runs a determinism
// self-check: replaying the same stream twice must produce byte-identical
// final settled frames and identical damage totals (diffed frames + total
// damage rects fed to the scheduler). Exits nonzero on any mismatch (or
// infrastructure failure).
//
// The three representative stream generators (counter / scroll / color) live
// here, not as binary fixtures, so CI regenerates them on every run. They are
// recorded through the production FrameRenderer recorder, exercising the real
// capture path end to end.
//
// Usage:
//   renderer_replay generate <counter|scroll|color> <out.plfr>
//   renderer_replay replay <stream.plfr>
//   renderer_replay all [work-dir]   # generate all three, then replay each

#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "compositor/frame_recording.h"
#include "compositor/software_compositor.h"
#include "pluto/presenter.h"
#include "presenter/host_preview.h"
#include "renderer/quantize.h"

namespace {

using pluto::FrameRenderer;
using pluto::FrameRendererConfig;
using pluto::PlutoFramePacket;

constexpr uint32_t k_gen_width = 480;
constexpr uint32_t k_gen_height = 800;
constexpr uint16_t k_white = 0xffff;
constexpr uint16_t k_black = 0x0000;
constexpr uint16_t k_gray = 0x8410; // mid gray: exercises 16-level dither
constexpr uint16_t k_red = 0xf800;
constexpr uint16_t k_green = 0x07e0;
constexpr uint16_t k_blue = 0x001f;
constexpr uint16_t k_yellow = 0xffe0;

// Replay pacing / quiescence. The scheduler settles ghosted and chroma tiles
// settle_idle_ms (400 ms) after the last damage, possibly over several settle
// rounds, so "done" means the present count stayed flat for a full window.
constexpr auto k_frame_interval = std::chrono::milliseconds(12);
constexpr int k_quiesce_stable_ms = 1500;
constexpr int k_quiesce_timeout_ms = 30000;

struct StreamFrame {
  uint64_t time_ns = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  PlutoPixelFormat format = kPlutoPixelFormatRgb565;
  bool did_update = false;
  std::vector<PlutoRect> bounds;
  std::vector<uint8_t> payload; // tight rows (width*bpp); empty when idle
};

// ---- generators -----------------------------------------------------------

void fill_rect(std::vector<uint16_t> *canvas, const PlutoRect &rect,
               uint16_t color) {
  for (int32_t y = rect.y; y < rect.y + rect.height; ++y) {
    for (int32_t x = rect.x; x < rect.x + rect.width; ++x) {
      (*canvas)[static_cast<size_t>(y) * k_gen_width + static_cast<size_t>(x)] =
          color;
    }
  }
}

StreamFrame content_frame(const std::vector<uint16_t> &canvas,
                          std::vector<PlutoRect> bounds) {
  StreamFrame frame;
  frame.width = k_gen_width;
  frame.height = k_gen_height;
  frame.did_update = true;
  frame.bounds = std::move(bounds);
  const auto *bytes = reinterpret_cast<const uint8_t *>(canvas.data());
  frame.payload.assign(bytes, bytes + canvas.size() * sizeof(uint16_t));
  return frame;
}

StreamFrame idle_frame() {
  StreamFrame frame;
  frame.width = k_gen_width;
  frame.height = k_gen_height;
  frame.did_update = false;
  return frame;
}

// A different RGB565 value with identical luma and no chroma above the
// classifier floor: a raw byte-diff would see damage, the post-quantize diff
// cannot (deterministic search, same approach as frame_renderer_test.cc).
uint16_t equal_luma_achromatic_sibling(uint16_t base) {
  const uint8_t target = pluto::rgb565_luma8(base);
  for (uint32_t v = 0; v <= 0xffffu; ++v) {
    const auto value = static_cast<uint16_t>(v);
    if (value != base && pluto::rgb565_luma8(value) == target &&
        !pluto::rgb565_has_chroma(value)) {
      return value;
    }
  }
  return base;
}

// Counter-like app: static chrome, a small digit box redrawn every frame
// (black/gray segment bars keyed off the frame index, deliberately off the
// 8 px grid), idle gaps, and a gray watermark whose bytes churn sub-quantum
// every frame -- the phantom damage the post-quantize diff must swallow.
std::vector<StreamFrame> generate_counter() {
  std::vector<StreamFrame> frames;
  std::vector<uint16_t> canvas(k_gen_width * k_gen_height, k_white);
  const uint16_t gray_alt = equal_luma_achromatic_sibling(k_gray);
  const PlutoRect watermark{97, 561, 288, 96};
  fill_rect(&canvas, {0, 0, 480, 64}, k_black); // header chrome
  fill_rect(&canvas, {0, 64, 480, 8}, k_gray);  // divider
  frames.push_back(content_frame(canvas, {{0, 0, 480, 800}}));
  for (int i = 1; i <= 18; ++i) {
    const PlutoRect box{203, 387, 72, 72};
    fill_rect(&canvas, box, k_white);
    const uint16_t bar_color = (i % 3 == 0) ? k_gray : k_black;
    for (int bit = 0; bit < 6; ++bit) {
      if ((i >> bit) & 1) {
        fill_rect(&canvas, {207 + 11 * bit, 395, 8, 56}, bar_color);
      }
    }
    // Frame 1 draws the watermark for real; afterwards its bytes alternate
    // between equal-luma siblings (anti-aliasing-jitter shaped churn).
    fill_rect(&canvas, watermark, (i % 2 == 0) ? gray_alt : k_gray);
    frames.push_back(content_frame(canvas, {box, watermark}));
    if (i == 6 || i == 12) {
      frames.push_back(idle_frame());
    }
  }
  return frames;
}

// Scroll-like translation: a striped body region (black and mid-gray "text
// lines" on white) translating up 8 px per frame under a static header.
std::vector<StreamFrame> generate_scroll() {
  std::vector<StreamFrame> frames;
  std::vector<uint16_t> canvas(k_gen_width * k_gen_height, k_white);
  fill_rect(&canvas, {0, 0, 480, 80}, k_black); // header chrome
  const PlutoRect body{0, 80, 480, 720};
  for (int i = 0; i < 20; ++i) {
    const int32_t offset = i * 6; // off the 8 px grid on purpose
    for (int32_t y = body.y; y < body.y + body.height; ++y) {
      const int32_t line = y - body.y + offset;
      fill_rect(&canvas, {35, y, 411, 1}, k_white);
      if (line % 40 < 16) {
        const uint16_t color = ((line / 40) % 4 == 0) ? k_gray : k_black;
        // Row-distinctive stripe length (like real text): the row-hash scroll
        // detector's distinctive-row filter abstains on repeated rows, so
        // uniform stripes would (correctly) never vote.
        const int32_t stripe_w = 220 + ((line * 13) % 191);
        fill_rect(&canvas, {35, y, stripe_w, 1}, color);
      }
    }
    frames.push_back(
        content_frame(canvas, {i == 0 ? PlutoRect{0, 0, 480, 800} : body}));
  }
  return frames;
}

// Color content: saturated patches appearing (and one disappearing) on white
// while a small black square marches along the bottom -- sub-Full gray-crush
// plus chroma-settle-as-Full traffic.
std::vector<StreamFrame> generate_color() {
  std::vector<StreamFrame> frames;
  std::vector<uint16_t> canvas(k_gen_width * k_gen_height, k_white);
  frames.push_back(content_frame(canvas, {{0, 0, 480, 800}}));
  for (int i = 1; i <= 19; ++i) {
    std::vector<PlutoRect> bounds;
    const PlutoRect prev{21 * (i - 1) + 3, 683, 24, 24};
    const PlutoRect next{21 * i + 3, 683, 24, 24};
    if (i > 1) {
      fill_rect(&canvas, prev, k_white);
    }
    fill_rect(&canvas, next, k_black);
    bounds.push_back({prev.x, 683, next.x + next.width - prev.x, 24});
    switch (i) {
    case 2:
      fill_rect(&canvas, {67, 131, 64, 64}, k_red);
      bounds.push_back({67, 131, 64, 64});
      break;
    case 6:
      fill_rect(&canvas, {211, 131, 64, 64}, k_green);
      bounds.push_back({211, 131, 64, 64});
      break;
    case 10:
      fill_rect(&canvas, {355, 131, 64, 64}, k_blue);
      bounds.push_back({355, 131, 64, 64});
      break;
    case 14:
      fill_rect(&canvas, {163, 323, 96, 48}, k_yellow);
      bounds.push_back({163, 323, 96, 48});
      break;
    case 18:
      fill_rect(&canvas, {67, 131, 64, 64}, k_white); // red patch removed
      bounds.push_back({67, 131, 64, 64});
      break;
    default:
      break;
    }
    frames.push_back(content_frame(canvas, std::move(bounds)));
    if (i == 12) {
      frames.push_back(idle_frame());
    }
  }
  return frames;
}

// Typing: letters appear two per frame at a fixed cadence in a text area
// (10x16 px glyph blocks, 2 px spacing, spaces every sixth letter, wrapping
// onto new lines) — exercises Text-class word-box aggregation and repeated
// small-rect damage. Deterministic: glyph pattern is a pure function of the
// letter index.
std::vector<StreamFrame> generate_typing() {
  std::vector<StreamFrame> frames;
  std::vector<uint16_t> canvas(k_gen_width * k_gen_height, k_white);
  fill_rect(&canvas, {0, 0, 480, 64}, k_black); // header chrome
  frames.push_back(content_frame(canvas, {{0, 0, 480, 800}}));
  constexpr int32_t k_left = 41; // off the 8 px grid on purpose
  constexpr int32_t k_right = 441;
  constexpr int32_t k_top = 103;
  constexpr int32_t k_advance = 12; // glyph width 10 + 2 spacing
  constexpr int32_t k_line_step = 24;
  int32_t pen_x = k_left;
  int32_t pen_y = k_top;
  for (int frame = 0; frame < 24; ++frame) {
    std::vector<PlutoRect> bounds;
    for (int g = 0; g < 2; ++g) {
      const int letter = frame * 2 + g;
      if (letter % 6 == 5) { // word gap: advance without painting
        pen_x += k_advance;
      } else {
        if (pen_x + 10 > k_right) {
          pen_x = k_left;
          pen_y += k_line_step;
        }
        const PlutoRect glyph{pen_x, pen_y, 10, 16};
        fill_rect(&canvas, glyph, k_black);
        // Deterministic per-letter notches so glyphs differ.
        if (letter % 4 == 0) {
          fill_rect(&canvas, {pen_x + 2, pen_y + 2, 6, 4}, k_white);
        } else if (letter % 4 == 1) {
          fill_rect(&canvas, {pen_x + 2, pen_y + 10, 6, 4}, k_white);
        } else if (letter % 4 == 2) {
          fill_rect(&canvas, {pen_x + 2, pen_y + 6, 3, 6}, k_white);
        }
        bounds.push_back(glyph);
        pen_x += k_advance;
      }
    }
    if (bounds.empty()) {
      frames.push_back(idle_frame());
    } else {
      frames.push_back(content_frame(canvas, std::move(bounds)));
    }
  }
  frames.push_back(idle_frame());
  return frames;
}

std::vector<StreamFrame> generate_stream(const std::string &name) {
  if (name == "counter") {
    return generate_counter();
  }
  if (name == "typing") {
    return generate_typing();
  }
  if (name == "scroll") {
    return generate_scroll();
  }
  if (name == "color") {
    return generate_color();
  }
  return {};
}

// ---- stream file I/O ------------------------------------------------------

size_t bytes_per_pixel(PlutoPixelFormat format) {
  switch (format) {
  case kPlutoPixelFormatGray8:
    return 1;
  case kPlutoPixelFormatXrgb8888:
    return 4;
  case kPlutoPixelFormatRgb565:
    return 2;
  }
  return 0;
}

PlutoFramePacket packet_for(const StreamFrame &frame,
                            const std::vector<uint8_t> *payload) {
  PlutoFramePacket packet{};
  packet.pixels = payload->data();
  packet.row_bytes = frame.width * bytes_per_pixel(frame.format);
  packet.width = frame.width;
  packet.height = frame.height;
  packet.format = frame.format;
  packet.did_update = frame.did_update;
  packet.presentation_time_ns = frame.time_ns;
  packet.paint_bounds = frame.bounds.empty() ? nullptr : frame.bounds.data();
  packet.paint_bounds_count = frame.bounds.size();
  return packet;
}

// Records through the production FrameRenderer recorder (PLUTO_RECORD_FRAMES)
// so the on-disk stream is produced by the exact writer devices use.
bool write_stream(const std::vector<StreamFrame> &frames,
                  const std::string &path) {
  if (frames.empty() || frames.front().payload.empty()) {
    return false;
  }
  ::setenv("PLUTO_RECORD_FRAMES", path.c_str(), 1);
  FrameRendererConfig config{};
  config.width = frames.front().width;
  config.height = frames.front().height;
  config.format = frames.front().format;
  config.start_presenter_thread = false;
  config.enable_present_bridge = false;
  FrameRenderer renderer(config);
  ::unsetenv("PLUTO_RECORD_FRAMES");
  if (!renderer.valid()) {
    return false;
  }
  const std::vector<uint8_t> *last_payload = nullptr;
  for (const StreamFrame &frame : frames) {
    const std::vector<uint8_t> *payload =
        frame.did_update ? &frame.payload : last_payload;
    if (payload == nullptr ||
        !renderer.submit_frame(packet_for(frame, payload))) {
      return false;
    }
    if (frame.did_update) {
      last_payload = &frame.payload;
    }
  }
  renderer.shutdown();
  return true;
}

bool read_stream(const std::string &path, std::vector<StreamFrame> *out) {
  std::ifstream in(path, std::ios::binary);
  if (!in.good()) {
    std::fprintf(stderr, "renderer_replay: cannot open %s\n", path.c_str());
    return false;
  }
  const auto read_exact = [&in](void *data, size_t size) {
    in.read(reinterpret_cast<char *>(data), static_cast<std::streamsize>(size));
    return in.good();
  };
  uint32_t file_magic = 0;
  if (!read_exact(&file_magic, sizeof(file_magic)) ||
      file_magic != pluto::frame_recording::kFileMagic) {
    std::fprintf(stderr, "renderer_replay: %s is not a PLFR stream\n",
                 path.c_str());
    return false;
  }
  out->clear();
  for (;;) {
    uint32_t magic = 0;
    in.read(reinterpret_cast<char *>(&magic), sizeof(magic));
    if (in.eof() && in.gcount() == 0) {
      break;
    }
    uint32_t frame_bytes = 0;
    if (!in.good() || !read_exact(&frame_bytes, sizeof(frame_bytes)) ||
        magic != pluto::frame_recording::kFrameMagic ||
        frame_bytes < pluto::frame_recording::kMinimumFrameBytes ||
        frame_bytes > pluto::frame_recording::kMaximumFrameBytes) {
      std::fprintf(stderr, "renderer_replay: bad frame magic in %s\n",
                   path.c_str());
      return false;
    }

    uint32_t crc = pluto::frame_recording::kCrc32Initial;
    crc = pluto::frame_recording::crc32_update(crc, &magic, sizeof(magic));
    crc = pluto::frame_recording::crc32_update(crc, &frame_bytes,
                                               sizeof(frame_bytes));
    const auto read_crc = [&in, &crc](void *data, size_t size) {
      in.read(reinterpret_cast<char *>(data),
              static_cast<std::streamsize>(size));
      if (!in.good()) {
        return false;
      }
      crc = pluto::frame_recording::crc32_update(crc, data, size);
      return true;
    };
    const auto read_u32_crc = [&read_crc](uint32_t *value) {
      return read_crc(value, sizeof(*value));
    };
    const auto read_u64_crc = [&read_crc](uint64_t *value) {
      return read_crc(value, sizeof(*value));
    };

    StreamFrame frame;
    uint32_t format = 0;
    uint32_t did_update = 0;
    uint32_t bounds_count = 0;
    uint32_t payload_bytes = 0;
    if (!read_u64_crc(&frame.time_ns) || !read_u32_crc(&frame.width) ||
        !read_u32_crc(&frame.height) || !read_u32_crc(&format) ||
        !read_u32_crc(&did_update) || !read_u32_crc(&bounds_count) ||
        !read_u32_crc(&payload_bytes)) {
      std::fprintf(stderr, "renderer_replay: truncated frame in %s\n",
                   path.c_str());
      return false;
    }
    frame.format = static_cast<PlutoPixelFormat>(format);
    frame.did_update = did_update == 1u;
    const size_t bpp = bytes_per_pixel(frame.format);
    const uint64_t row_bytes = static_cast<uint64_t>(frame.width) * bpp;
    const bool payload_overflow =
        frame.height != 0 && row_bytes > UINT64_MAX / frame.height;
    const uint64_t expected_payload =
        payload_overflow ? UINT64_MAX : row_bytes * frame.height;
    const uint64_t expected_frame_bytes =
        pluto::frame_recording::kMinimumFrameBytes +
        static_cast<uint64_t>(bounds_count) * sizeof(PlutoRect) + payload_bytes;
    if (frame.width == 0 || frame.height == 0 || bpp == 0 || did_update > 1u ||
        payload_overflow ||
        payload_bytes != (frame.did_update ? expected_payload : 0u) ||
        expected_frame_bytes != frame_bytes) {
      std::fprintf(stderr, "renderer_replay: invalid frame layout in %s\n",
                   path.c_str());
      return false;
    }

    frame.bounds.resize(bounds_count);
    for (PlutoRect &rect : frame.bounds) {
      if (!read_crc(&rect, sizeof(rect))) {
        std::fprintf(stderr, "renderer_replay: truncated frame in %s\n",
                     path.c_str());
        return false;
      }
    }
    frame.payload.resize(payload_bytes);
    if (payload_bytes != 0 &&
        !read_crc(frame.payload.data(), frame.payload.size())) {
      std::fprintf(stderr, "renderer_replay: truncated frame in %s\n",
                   path.c_str());
      return false;
    }
    uint32_t checksum = 0;
    if (!read_exact(&checksum, sizeof(checksum)) ||
        checksum != pluto::frame_recording::crc32_finish(crc)) {
      std::fprintf(stderr, "renderer_replay: bad frame checksum in %s\n",
                   path.c_str());
      return false;
    }
    out->push_back(std::move(frame));
  }
  return !out->empty();
}

// ---- replay ----------------------------------------------------------------

struct PresentStats {
  size_t presents = 0;
  uint64_t damaged_px = 0;
  size_t class_presents[4] = {};
  uint64_t class_px[4] = {};
  uint64_t max_class_request_px[4] = {};
  size_t full_surface_class_presents[4] = {};
};

// Thin counting shim between FrameRenderer and the real host_preview
// presenter: tallies every present's damage rects, then delegates. Follows
// the opaque-pointer pattern of the compositor tests (frame_renderer_test).
struct Sink {
  const PlutoPresenterOps *inner_ops = nullptr;
  PlutoPresenter *inner = nullptr;
  std::atomic<FrameRenderer *> renderer{nullptr};
  std::mutex mutex;
  PresentStats stats;
};

PlutoStatus sink_open(const PlutoPresenterConfig *, PlutoPresenter **) {
  return kPlutoStatusUnsupported;
}

void sink_close(PlutoPresenter *) {}

PlutoStatus sink_info(PlutoPresenter *presenter, PlutoDisplayInfo *out_info) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  return sink->inner_ops->info(sink->inner, out_info);
}

PlutoStatus sink_present(PlutoPresenter *presenter,
                         const PlutoPresentRequest *request) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  if ((request->flags & kPlutoPresentFlagSparkle) != 0) {
    // Sparkle top-off passes are wall-clock-paced background maintenance:
    // counting them would (a) keep resetting the quiescence detector for
    // the whole 16-phase rotation and (b) make present counts run-to-run
    // nondeterministic. They are optically no-ops on the host preview.
    return sink->inner_ops->present(sink->inner, request);
  }
  {
    std::lock_guard<std::mutex> lock(sink->mutex);
    ++sink->stats.presents;
    ++sink->stats.class_presents[request->refresh_class];
    uint64_t request_px = 0;
    for (size_t i = 0; i < request->damage_count; ++i) {
      const uint64_t px = static_cast<uint64_t>(request->damage[i].width) *
                          static_cast<uint64_t>(request->damage[i].height);
      request_px += px;
      sink->stats.damaged_px += px;
      sink->stats.class_px[request->refresh_class] += px;
    }
    sink->stats.max_class_request_px[request->refresh_class] = std::max(
        sink->stats.max_class_request_px[request->refresh_class], request_px);
    const uint64_t surface_px = static_cast<uint64_t>(request->surface.width) *
                                static_cast<uint64_t>(request->surface.height);
    // Presenter ABI damage rects are disjoint. Their summed area therefore
    // detects a full-surface request even when it is expressed as many rects.
    if (request_px >= surface_px) {
      ++sink->stats.full_surface_class_presents[request->refresh_class];
    }
    if (std::getenv("PLUTO_REPLAY_LOG") != nullptr) {
      static const char *k_class_names[] = {"fast", "ui", "text", "full"};
      for (size_t i = 0; i < request->damage_count; ++i) {
        std::fprintf(stderr, "replay-present #%llu %s [%d,%d %dx%d]\n",
                     static_cast<unsigned long long>(request->frame_id),
                     k_class_names[request->refresh_class],
                     request->damage[i].x, request->damage[i].y,
                     request->damage[i].width, request->damage[i].height);
      }
    }
  }
  return sink->inner_ops->present(sink->inner, request);
}

bool sink_ready(PlutoPresenter *presenter, PlutoRefreshClass cls) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  return sink->inner_ops->ready(sink->inner, cls);
}

PlutoStatus sink_wait_idle(PlutoPresenter *presenter, uint32_t timeout_ms) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  return sink->inner_ops->wait_idle(sink->inner, timeout_ms);
}

PlutoStatus sink_snapshot(PlutoPresenter *presenter,
                          PlutoSurface *out_surface) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  return sink->inner_ops->snapshot(sink->inner, out_surface);
}

PlutoStatus sink_set_pen_focus(PlutoPresenter *presenter,
                               const PlutoPenFocus *focus) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  return sink->inner_ops->set_pen_focus(sink->inner, focus);
}

PlutoStatus sink_stage_handoff(PlutoPresenter *presenter,
                               const PlutoHandoffPayload *payload,
                               uint32_t timeout_ms) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  return sink->inner_ops->stage_handoff(sink->inner, payload, timeout_ms);
}

PlutoStatus sink_get_handoff(PlutoPresenter *presenter,
                             PlutoHandoffPayload *out_payload) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  return sink->inner_ops->get_handoff(sink->inner, out_payload);
}

PlutoStatus sink_confirm_handoff(PlutoPresenter *presenter, bool accepted) {
  auto *sink = reinterpret_cast<Sink *>(presenter);
  return sink->inner_ops->confirm_handoff(sink->inner, accepted);
}

const PlutoPresenterOps *sink_ops() {
  static const PlutoPresenterOps ops = [] {
    PlutoPresenterOps o{};
    o.struct_size = sizeof(o);
    o.name = "renderer-replay-sink";
    o.open = sink_open;
    o.close = sink_close;
    o.info = sink_info;
    o.present = sink_present;
    o.ready = sink_ready;
    o.wait_idle = sink_wait_idle;
    o.snapshot = sink_snapshot;
    o.set_pen_focus = sink_set_pen_focus;
    o.stage_handoff = sink_stage_handoff;
    o.get_handoff = sink_get_handoff;
    o.confirm_handoff = sink_confirm_handoff;
    return o;
  }();
  return &ops;
}

void sink_on_complete(uint64_t frame_id, void *user_data) {
  auto *sink = static_cast<Sink *>(user_data);
  if (FrameRenderer *renderer = sink->renderer.load()) {
    renderer->notify_present_complete(frame_id);
  }
}

struct RunResult {
  PresentStats stats;
  size_t diffed_frames = 0;
  size_t idle_frames = 0;
  // Deterministic damage total: the number of merged damage rects the frame
  // path fed to the scheduler, summed over all submitted frames. A pure
  // function of the stream (unlike present counts, which depend on
  // wall-clock coalescing), so the determinism check compares it exactly.
  size_t total_damage_rects = 0;
  // Verified scroll MOVEs from the row-hash detector. Damage-path state, so a
  // pure function of the stream like the damage totals.
  size_t scroll_moves = 0;
  std::vector<uint8_t> final_frame; // tight rows, presenter format
};

bool run_replay(const std::vector<StreamFrame> &frames, const char *label,
                RunResult *out) {
  const std::filesystem::path png_dir =
      std::filesystem::temp_directory_path() /
      (std::string("pluto-renderer-replay-") + label + "-" +
       std::to_string(static_cast<unsigned long>(::getpid())));

  Sink sink;
  sink.inner_ops = pluto_host_preview_presenter_ops();
  PlutoPresenterConfig open_config{};
  open_config.struct_size = sizeof(open_config);
  open_config.backend_name = "host-headless";
  const std::string options = "dir=" + png_dir.string() + ",prefix=replay";
  open_config.options = options.c_str();
  open_config.on_complete = sink_on_complete;
  open_config.user_data = &sink;
  if (sink.inner_ops->open(&open_config, &sink.inner) != kPlutoStatusOk) {
    std::fprintf(stderr, "renderer_replay: host_preview open failed\n");
    return false;
  }

  bool ok = true;
  {
    FrameRendererConfig config{};
    config.width = frames.front().width;
    config.height = frames.front().height;
    config.format = frames.front().format;
    config.presenter_ops = sink_ops();
    config.presenter = reinterpret_cast<PlutoPresenter *>(&sink);
    config.start_presenter_thread = true;
    FrameRenderer renderer(config);
    if (!renderer.valid()) {
      std::fprintf(stderr, "renderer_replay: %s renderer invalid\n", label);
      sink.inner_ops->close(sink.inner);
      return false;
    }
    sink.renderer.store(&renderer);

    out->total_damage_rects = 0;
    const std::vector<uint8_t> *last_payload = nullptr;
    for (const StreamFrame &frame : frames) {
      const std::vector<uint8_t> *payload =
          frame.did_update ? &frame.payload : last_payload;
      if (payload == nullptr) {
        continue; // idle frame before any content: nothing to carry
      }
      if (!renderer.submit_frame(packet_for(frame, payload))) {
        std::fprintf(stderr, "renderer_replay: %s submit_frame failed\n",
                     label);
        ok = false;
        break;
      }
      out->total_damage_rects += renderer.last_damage_count();
      if (frame.did_update) {
        last_payload = &frame.payload;
      }
      std::this_thread::sleep_for(k_frame_interval);
    }

    // Let the scheduler drain: settles fire 400 ms after the last damage and
    // may take several rounds; wait for a flat present count.
    int stable_ms = 0;
    int waited_ms = 0;
    size_t last_presents = 0;
    while (ok && stable_ms < k_quiesce_stable_ms &&
           waited_ms < k_quiesce_timeout_ms) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      waited_ms += 100;
      size_t presents = 0;
      {
        std::lock_guard<std::mutex> lock(sink.mutex);
        presents = sink.stats.presents;
      }
      stable_ms = presents == last_presents ? stable_ms + 100 : 0;
      last_presents = presents;
    }
    if (waited_ms >= k_quiesce_timeout_ms) {
      std::fprintf(stderr, "renderer_replay: %s did not quiesce\n", label);
      ok = false;
    }
    renderer.shutdown(); // no more scheduler ticks -> no more presents
    sink.inner_ops->wait_idle(sink.inner, 3000);
    sink.renderer.store(nullptr);

    out->diffed_frames = renderer.diffed_frames();
    out->idle_frames = renderer.idle_frames();
    out->scroll_moves = renderer.scroll_moves_detected();
    {
      std::lock_guard<std::mutex> lock(sink.mutex);
      out->stats = sink.stats;
    }
    if (ok) {
      const size_t bpp = bytes_per_pixel(frames.front().format);
      out->final_frame.assign(static_cast<size_t>(frames.front().width) * bpp *
                                  frames.front().height,
                              0);
      PlutoSurface surface{out->final_frame.data(), frames.front().width * bpp,
                           static_cast<int32_t>(frames.front().width),
                           static_cast<int32_t>(frames.front().height),
                           frames.front().format};
      if (sink.inner_ops->snapshot(sink.inner, &surface) != kPlutoStatusOk) {
        std::fprintf(stderr, "renderer_replay: %s snapshot failed\n", label);
        ok = false;
      }
    }
    sink.inner_ops->close(sink.inner); // joins the completion worker
  }

  std::error_code ec;
  std::filesystem::remove_all(png_dir, ec);
  return ok;
}

// ---- report + determinism check --------------------------------------------

void print_run_row(const char *label, const RunResult &run) {
  std::printf("  %-8s %8zu %12llu %6zu %6zu %6zu %6zu %8zu %8zu %6zu\n", label,
              run.stats.presents,
              static_cast<unsigned long long>(run.stats.damaged_px),
              run.stats.class_presents[0], run.stats.class_presents[1],
              run.stats.class_presents[2], run.stats.class_presents[3],
              run.diffed_frames, run.total_damage_rects, run.scroll_moves);
}

// Replays the stream twice and checks the determinism contract: byte-equal
// final settled frames and identical damage totals. When `dump_final` is
// non-empty, run1's settled final frame is written there raw (tight rows,
// presenter format) so settled output can be byte-compared across renderer
// changes.
bool replay_stream(const std::string &path, const std::string &dump_final) {
  std::vector<StreamFrame> frames;
  if (!read_stream(path, &frames)) {
    return false;
  }
  // A stale recorder env var would make the replay renderers clobber it.
  if (std::getenv("PLUTO_RECORD_FRAMES") != nullptr) {
    std::fprintf(
        stderr,
        "renderer_replay: ignoring PLUTO_RECORD_FRAMES during replay\n");
    ::unsetenv("PLUTO_RECORD_FRAMES");
  }

  RunResult run1;
  RunResult run2;
  if (!run_replay(frames, "run1", &run1) ||
      !run_replay(frames, "run2", &run2)) {
    return false;
  }

  std::printf("== %s (%zu frames, %ux%u) ==\n",
              std::filesystem::path(path).filename().string().c_str(),
              frames.size(), frames.front().width, frames.front().height);
  std::printf("  %-8s %8s %12s %6s %6s %6s %6s %8s %8s %6s\n", "run", "updates",
              "damaged_px", "fast", "ui", "text", "full", "diffed", "rects",
              "moves");
  print_run_row("run1", run1);
  print_run_row("run2", run2);

  // Per-stream policy gates (Stage-6 exit criteria). MOVE counts and damage
  // totals are pure functions of the stream; class present counts vary with
  // wall-clock coalescing, so the flash gates carry margin above the typical
  // observation while staying far below the pre-rewrite pathology.
  const std::string stream_name = std::filesystem::path(path).stem().string();
  bool gates_ok = true;
  const auto gate = [&](bool cond, const char *what) {
    if (!cond) {
      std::printf("  policy gate FAILED: %s\n", what);
      gates_ok = false;
    }
  };
  if (stream_name == "scroll") {
    gate(run1.scroll_moves >= 15 && run2.scroll_moves >= 15,
         "scroll MOVE detected on >= 15 of 19 translation frames");
    gate(run1.stats.class_presents[3] <= 6 && run2.stats.class_presents[3] <= 6,
         "scroll full flashes <= 6 (was 20 before the rewrite)");
  } else if (stream_name == "counter") {
    gate(run1.stats.class_presents[3] <= 2,
         "counter full flashes <= 2 (frame-0 structural flash + margin)");
  } else if (stream_name == "color") {
    // Five frames add/remove chromatic patches. A cold color surface has no
    // trustworthy previous RGB mirror, so the initial achromatic frame also
    // owes quality coverage in bounded regional batches. The number of
    // presenter calls depends on completion/coalescing wall time; count was a
    // flaky proxy for the real contract. Pin optical geometry instead: color
    // must receive Full truth, at most one cold-start Full may cover the whole
    // panel to establish unknown prior pigment, and total quality coverage
    // must remain bounded under repeated settle batches.
    const uint64_t panel_px =
        static_cast<uint64_t>(frames.front().width) * frames.front().height;
    gate(run1.stats.class_px[3] > 0 && run2.stats.class_px[3] > 0,
         "color stream must receive regional Full truth");
    gate(run1.stats.full_surface_class_presents[3] <= 1 &&
             run2.stats.full_surface_class_presents[3] <= 1,
         "color Full permits only one cold-start full-surface request");
    gate(run1.stats.class_px[3] <= panel_px * 3 &&
             run2.stats.class_px[3] <= panel_px * 3,
         "color Full damaged area <= 3 panel-equivalents");
  } else if (stream_name == "typing") {
    gate(run1.scroll_moves == 0 && run2.scroll_moves == 0,
         "typing must not claim scroll MOVEs");
    gate(run1.stats.class_presents[3] <= 2,
         "typing full flashes <= 2 (letters are Text-class damage)");
  }

  bool ok = true;
  if (run1.diffed_frames != run2.diffed_frames ||
      run1.total_damage_rects != run2.total_damage_rects) {
    std::printf(
        "  damage totals: MISMATCH (diffed %zu vs %zu, rects %zu vs %zu)\n",
        run1.diffed_frames, run2.diffed_frames, run1.total_damage_rects,
        run2.total_damage_rects);
    ok = false;
  }

  size_t mismatched = 0;
  size_t first_offset = 0;
  if (run1.final_frame.size() != run2.final_frame.size()) {
    mismatched = SIZE_MAX;
  } else {
    for (size_t i = 0; i < run1.final_frame.size(); ++i) {
      if (run1.final_frame[i] != run2.final_frame[i]) {
        if (mismatched == 0) {
          first_offset = i;
        }
        ++mismatched;
      }
    }
  }
  if (mismatched != 0) {
    const size_t bpp = bytes_per_pixel(frames.front().format);
    const size_t px_index = first_offset / bpp;
    std::printf(
        "  final frames: MISMATCH (%zu bytes differ; first at byte %zu, "
        "px (%zu,%zu))\n\n",
        mismatched, first_offset, px_index % frames.front().width,
        px_index / frames.front().width);
    return false;
  }
  if (!ok) {
    std::printf("\n");
    return false;
  }
  std::printf(
      "  determinism: final frames byte-equal (%zu bytes); damage totals "
      "identical (diffed %zu, rects %zu)\n\n",
      run1.final_frame.size(), run1.diffed_frames, run1.total_damage_rects);
  if (!dump_final.empty()) {
    std::ofstream out(dump_final, std::ios::binary);
    out.write(reinterpret_cast<const char *>(run1.final_frame.data()),
              static_cast<std::streamsize>(run1.final_frame.size()));
    if (!out) {
      std::fprintf(stderr, "renderer_replay: writing %s failed\n",
                   dump_final.c_str());
      return false;
    }
  }
  return gates_ok;
}

int usage() {
  std::fprintf(stderr,
               "usage: renderer_replay generate <counter|scroll|color|typing> "
               "<out.plfr>\n"
               "       renderer_replay replay <stream.plfr> [dump-final.raw]\n"
               "       renderer_replay all [work-dir]\n"
               "  (in `all` mode, run1 final frames are dumped to "
               "<work-dir>/<name>.final.raw)\n");
  return 2;
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    return usage();
  }
  const std::string mode = argv[1];
  if (mode == "generate" && argc == 4) {
    const std::vector<StreamFrame> frames = generate_stream(argv[2]);
    if (frames.empty()) {
      return usage();
    }
    if (!write_stream(frames, argv[3])) {
      std::fprintf(stderr, "renderer_replay: recording %s failed\n", argv[3]);
      return 1;
    }
    std::printf("recorded %zu frames -> %s\n", frames.size(), argv[3]);
    return 0;
  }
  if (mode == "replay" && (argc == 3 || argc == 4)) {
    return replay_stream(argv[2], argc == 4 ? argv[3] : "") ? 0 : 1;
  }
  if (mode == "all" && (argc == 2 || argc == 3)) {
    const std::filesystem::path dir =
        argc == 3 ? std::filesystem::path(argv[2])
                  : std::filesystem::temp_directory_path() /
                        ("pluto-renderer-replay-streams-" +
                         std::to_string(static_cast<long long>(::getpid())));
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    bool all_ok = true;
    for (const char *name : {"counter", "scroll", "color", "typing"}) {
      const std::string path = (dir / (std::string(name) + ".plfr")).string();
      if (!write_stream(generate_stream(name), path)) {
        std::fprintf(stderr, "renderer_replay: recording %s failed\n",
                     path.c_str());
        return 1;
      }
      const std::string dump =
          (dir / (std::string(name) + ".final.raw")).string();
      all_ok = replay_stream(path, dump) && all_ok;
    }
    return all_ok ? 0 : 1;
  }
  return usage();
}
