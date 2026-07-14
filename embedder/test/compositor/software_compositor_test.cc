#include "compositor/software_compositor.h"

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "presenter/host_preview.h"
#include "gtest/gtest.h"

namespace {

FlutterLayer make_layer(const FlutterBackingStore *store, double width,
                        double height) {
  FlutterLayer layer{};
  layer.struct_size = sizeof(layer);
  layer.type = kFlutterLayerContentTypeBackingStore;
  layer.backing_store = store;
  layer.offset = FlutterPoint{0, 0};
  layer.size = FlutterSize{width, height};
  return layer;
}

TEST(SoftwareCompositor, DidUpdateFalseShortCircuits) {
  pluto::SoftwareCompositor compositor(kPlutoPixelFormatRgb565, nullptr);
  FlutterBackingStoreConfig config{};
  config.struct_size = sizeof(config);
  config.size = FlutterSize{8, 8};
  FlutterBackingStore store{};
  ASSERT_TRUE(compositor.create_backing_store(&config, &store));
  store.did_update = false;
  FlutterLayer layer = make_layer(&store, 8, 8);
  const FlutterLayer *layers[] = {&layer};
  FlutterPresentViewInfo info{};
  info.struct_size = sizeof(info);
  info.layers = layers;
  info.layers_count = 1;

  ASSERT_TRUE(compositor.present_view(&info));
  EXPECT_EQ(compositor.present_count(), 1u);
  EXPECT_EQ(compositor.idle_short_circuit_count(), 1u);
}

TEST(SoftwareCompositor, IdleFrameReleasesArmedSystemUiGate) {
  pluto::FrameRendererConfig renderer_config{};
  renderer_config.width = 8;
  renderer_config.height = 8;
  renderer_config.format = kPlutoPixelFormatRgb565;
  renderer_config.start_presenter_thread = false;
  pluto::FrameRenderer renderer(renderer_config);
  ASSERT_TRUE(renderer.valid());
  renderer.set_presentation_suspended(true);
  ASSERT_TRUE(renderer.arm_presentation_resume());

  pluto::SoftwareCompositor compositor(kPlutoPixelFormatRgb565, &renderer);
  FlutterBackingStoreConfig config{};
  config.struct_size = sizeof(config);
  config.size = FlutterSize{8, 8};
  FlutterBackingStore store{};
  ASSERT_TRUE(compositor.create_backing_store(&config, &store));
  store.did_update = false;
  FlutterLayer layer = make_layer(&store, 8, 8);
  const FlutterLayer *layers[] = {&layer};
  FlutterPresentViewInfo info{};
  info.struct_size = sizeof(info);
  info.layers = layers;
  info.layers_count = 1;

  ASSERT_TRUE(compositor.present_view(&info));
  EXPECT_FALSE(renderer.presentation_suspended());
  EXPECT_EQ(renderer.idle_frames(), 1u);
}

TEST(SoftwareCompositor, FrameRendererDiffsAndHonorsIdleGate) {
  pluto::FrameRendererConfig renderer_config{};
  renderer_config.width = 8;
  renderer_config.height = 8;
  renderer_config.format = kPlutoPixelFormatRgb565;
  renderer_config.start_presenter_thread = false;
  pluto::FrameRenderer renderer(renderer_config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint8_t> pixels(8 * 8 * 2, 0);
  pixels[0] = 0xff;
  pluto::PlutoFramePacket packet{};
  packet.pixels = pixels.data();
  packet.row_bytes = 16;
  packet.width = 8;
  packet.height = 8;
  packet.format = kPlutoPixelFormatRgb565;
  packet.did_update = true;

  ASSERT_TRUE(renderer.submit_frame(packet));
  EXPECT_EQ(renderer.diffed_frames(), 1u);
  EXPECT_EQ(renderer.last_damage_count(), 1u);

  packet.did_update = false;
  ASSERT_TRUE(renderer.submit_frame(packet));
  EXPECT_EQ(renderer.idle_frames(), 1u);
  EXPECT_EQ(renderer.last_damage_count(), 0u);
}

TEST(SoftwareCompositor, FrameRendererQuantizesThroughPresentBridge) {
  struct Capture {
    bool presented = false;
    uint32_t flags = 0;
    PlutoPixelFormat format = kPlutoPixelFormatXrgb8888;
    const void *surface_pixels = nullptr;
    std::vector<uint16_t> pixels;
    PlutoRect rect{};
  };
  static Capture capture;
  capture = Capture{};

  static PlutoPresenterOps ops{};
  ops.struct_size = sizeof(ops);
  ops.name = "capture-stub";
  ops.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
    PlutoDisplayInfo info{};
    info.struct_size = sizeof(info);
    info.width = 64;
    info.height = 64;
    info.dpi = 264;
    info.preferred_format = kPlutoPixelFormatRgb565;
    info.is_color = false; // mono panel: everything quantizes to gray
    info.wants_pre_dithered = true;
    info.backend_quantizes_color = false;
    info.rect_alignment = 8;
    for (int i = 0; i < 4; ++i) {
      info.nominal_latency_ms[i] = 0;
    }
    *out_info = info;
    return kPlutoStatusOk;
  };
  ops.present = [](PlutoPresenter *, const PlutoPresentRequest *request) {
    capture.presented = true;
    capture.flags = request->flags;
    capture.format = request->surface.format;
    capture.surface_pixels = request->surface.pixels;
    capture.rect = request->damage[0];
    const auto *px =
        reinterpret_cast<const uint16_t *>(request->surface.pixels);
    capture.pixels.assign(px, px + 64 * 64);
    return kPlutoStatusOk;
  };
  ops.ready = [](PlutoPresenter *, PlutoRefreshClass) { return true; };

  pluto::FrameRendererConfig renderer_config{};
  renderer_config.width = 64;
  renderer_config.height = 64;
  renderer_config.format = kPlutoPixelFormatRgb565;
  renderer_config.start_presenter_thread = false;
  renderer_config.presenter_ops = &ops;
  renderer_config.presenter =
      reinterpret_cast<PlutoPresenter *>(&capture); // opaque, unused
  pluto::FrameRenderer renderer(renderer_config);
  ASSERT_TRUE(renderer.valid());

  // A saturated color frame: every pixel is pure red, which no e-ink gray
  // pipeline may pass through unquantized.
  std::vector<uint16_t> pixels(64 * 64, 0xf800);
  pluto::PlutoFramePacket packet{};
  packet.pixels = pixels.data();
  packet.row_bytes = 64 * sizeof(uint16_t);
  packet.width = 64;
  packet.height = 64;
  packet.format = kPlutoPixelFormatRgb565;
  packet.did_update = true;

  ASSERT_TRUE(renderer.submit_frame(packet));
  ASSERT_TRUE(capture.presented);
  EXPECT_NE(capture.surface_pixels, pixels.data());
  EXPECT_TRUE((capture.flags & kPlutoPresentFlagPreDithered) != 0);
  EXPECT_EQ(capture.format, kPlutoPixelFormatRgb565);

  // Every presented pixel inside the damage rect must be a 16-level gray in
  // RGB565 (r == g == b) -- never the raw red the engine rasterized.
  auto is_gray16 = [](uint16_t value) {
    for (int level = 0; level < 256; level += 17) {
      const int r5 = level >> 3;
      const int g6 = level >> 2;
      const int b5 = level >> 3;
      if (value == static_cast<uint16_t>((r5 << 11) | (g6 << 5) | b5)) {
        return true;
      }
    }
    return false;
  };
  for (int32_t y = capture.rect.y; y < capture.rect.y + capture.rect.height;
       ++y) {
    for (int32_t x = capture.rect.x; x < capture.rect.x + capture.rect.width;
         ++x) {
      ASSERT_TRUE(is_gray16(capture.pixels[y * 64 + x]))
          << "x=" << x << " y=" << y << " px=" << capture.pixels[y * 64 + x];
    }
  }
}

TEST(SoftwareCompositor, FrameRendererWaitsForAdvertisedCompletion) {
  struct Capture {
    size_t present_count = 0;
    std::vector<uint64_t> frame_ids;
  };
  static Capture capture;
  capture = Capture{};

  static PlutoPresenterOps ops{};
  ops.struct_size = sizeof(ops);
  ops.name = "completion-stub";
  ops.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
    PlutoDisplayInfo info{};
    info.struct_size = sizeof(info);
    info.width = 8;
    info.height = 8;
    info.dpi = 264;
    info.preferred_format = kPlutoPixelFormatRgb565;
    info.is_color = false;
    info.reports_completion = true;
    info.rect_alignment = 8;
    for (int i = 0; i < 4; ++i) {
      info.nominal_latency_ms[i] = 0;
    }
    *out_info = info;
    return kPlutoStatusOk;
  };
  ops.present = [](PlutoPresenter *, const PlutoPresentRequest *request) {
    ++capture.present_count;
    capture.frame_ids.push_back(request->frame_id);
    return kPlutoStatusOk;
  };
  ops.ready = [](PlutoPresenter *, PlutoRefreshClass) { return true; };

  pluto::FrameRendererConfig renderer_config{};
  renderer_config.width = 8;
  renderer_config.height = 8;
  renderer_config.format = kPlutoPixelFormatRgb565;
  renderer_config.start_presenter_thread = false;
  renderer_config.enable_present_bridge = false;
  renderer_config.presenter_ops = &ops;
  renderer_config.presenter = reinterpret_cast<PlutoPresenter *>(&capture);
  pluto::FrameRenderer renderer(renderer_config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(8 * 8, 0);
  pluto::PlutoFramePacket packet{};
  packet.pixels = pixels.data();
  packet.row_bytes = 8 * sizeof(uint16_t);
  packet.width = 8;
  packet.height = 8;
  packet.format = kPlutoPixelFormatRgb565;
  packet.did_update = true;
  packet.presentation_time_ns = 1000;

  ASSERT_TRUE(renderer.submit_frame(packet));
  ASSERT_EQ(capture.present_count, 1u);
  ASSERT_EQ(capture.frame_ids[0], 1u);

  pixels[0] = 0xffff;
  packet.presentation_time_ns = 2000;
  ASSERT_TRUE(renderer.submit_frame(packet));
  EXPECT_EQ(capture.present_count, 1u);

  renderer.notify_present_complete(1);
  packet.presentation_time_ns = 3000;
  pixels[1] = 0xffff;
  ASSERT_TRUE(renderer.submit_frame(packet));
  EXPECT_TRUE(capture.present_count >= 2u);
}

TEST(SoftwareCompositor, FractionalPaintBoundsCoverPaintedPixels) {
  pluto::FrameRendererConfig renderer_config{};
  renderer_config.width = 96;
  renderer_config.height = 32;
  renderer_config.format = kPlutoPixelFormatRgb565;
  renderer_config.start_presenter_thread = false;
  pluto::FrameRenderer renderer(renderer_config);
  ASSERT_TRUE(renderer.valid());
  pluto::SoftwareCompositor compositor(kPlutoPixelFormatRgb565, &renderer);

  FlutterBackingStoreConfig config{};
  config.struct_size = sizeof(config);
  config.size = FlutterSize{96, 32};
  FlutterBackingStore store{};
  ASSERT_TRUE(compositor.create_backing_store(&config, &store));
  store.did_update = true;
  auto *pixels =
      static_cast<uint8_t *>(const_cast<void *>(store.software2.allocation));
  ASSERT_NE(pixels, nullptr);

  FlutterLayer layer = make_layer(&store, 96, 32);
  const FlutterLayer *layers[] = {&layer};
  FlutterPresentViewInfo info{};
  info.struct_size = sizeof(info);
  info.layers = layers;
  info.layers_count = 1;

  // First present seeds the retained snapshot (full-frame damage).
  ASSERT_TRUE(compositor.present_view(&info));
  ASSERT_EQ(renderer.last_damage_count(), 1u);

  // Change one pixel at x=64 (the third 32px damage tile) and report it via
  // a fractional paint region ending at x=64.5. Truncation shrinks the rect
  // to width 64 and the diff never scans the painted pixel; floor/ceil must
  // keep it covered.
  pixels[64 * 2] = 0xff;
  FlutterRect paint_rect{0.25, 0.0, 64.5, 1.5};
  FlutterRegion region{};
  region.struct_size = sizeof(region);
  region.rects_count = 1;
  region.rects = &paint_rect;
  FlutterBackingStorePresentInfo present_info{};
  present_info.struct_size = sizeof(present_info);
  present_info.paint_region = &region;
  layer.backing_store_present_info = &present_info;

  ASSERT_TRUE(compositor.present_view(&info));
  EXPECT_EQ(renderer.last_damage_count(), 1u);
}

TEST(CompletionQueue, DrainsInArrivalOrder) {
  pluto::CompletionQueue queue;
  uint64_t frame_id = 0;
  EXPECT_FALSE(queue.pop(&frame_id));
  // Exceeds RegionScheduler's maximum 512 in-flight requests, modelling one
  // PixelEngine boundary completing every subscriber before a renderer tick.
  for (uint64_t id = 1; id <= 513; ++id) {
    ASSERT_TRUE(queue.push(id));
  }
  for (uint64_t id = 1; id <= 513; ++id) {
    ASSERT_TRUE(queue.pop(&frame_id));
    EXPECT_EQ(frame_id, id);
  }
  EXPECT_FALSE(queue.pop(&frame_id));
}

TEST(CompletionQueue, ConcurrentProducersDrainExactlyOnceInOrder) {
  pluto::CompletionQueue queue;
  constexpr size_t k_producers = 4;
  constexpr uint64_t k_per_producer = 50;
  std::array<bool, k_producers> push_failed{};
  std::vector<std::thread> producers;
  for (size_t p = 0; p < k_producers; ++p) {
    producers.emplace_back([&queue, &push_failed, p] {
      for (uint64_t i = 0; i < k_per_producer; ++i) {
        // Disjoint id ranges encode each producer's submission order.
        if (!queue.push(static_cast<uint64_t>(p) * 1000u + i)) {
          push_failed[p] = true;
        }
      }
    });
  }

  // Drain concurrently with the producers, like the presenter-loop tick.
  std::vector<uint64_t> drained;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (drained.size() < k_producers * k_per_producer &&
         std::chrono::steady_clock::now() < deadline) {
    uint64_t frame_id = 0;
    if (queue.pop(&frame_id)) {
      drained.push_back(frame_id);
    } else {
      std::this_thread::yield();
    }
  }
  for (std::thread &producer : producers) {
    producer.join();
  }
  uint64_t frame_id = 0;
  while (queue.pop(&frame_id)) {
    drained.push_back(frame_id);
  }

  for (size_t p = 0; p < k_producers; ++p) {
    EXPECT_FALSE(push_failed[p]);
  }
  ASSERT_EQ(drained.size(), k_producers * k_per_producer);
  // Exactly once, and each producer's completions in its arrival order.
  std::array<uint64_t, k_producers> next_expected{};
  for (const uint64_t id : drained) {
    const size_t producer = static_cast<size_t>(id / 1000u);
    ASSERT_TRUE(producer < k_producers);
    EXPECT_EQ(id % 1000u, next_expected[producer]);
    ++next_expected[producer];
  }
}

TEST(SoftwareCompositor, SynchronousCompletionPresenterCannotDeadlock) {
  struct Ctx {
    pluto::FrameRenderer *renderer = nullptr;
    size_t presents = 0;
    std::vector<uint64_t> frame_ids;
  };
  static Ctx ctx;
  ctx = Ctx{};

  static PlutoPresenterOps ops{};
  ops.struct_size = sizeof(ops);
  ops.name = "sync-completion-stub";
  ops.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
    PlutoDisplayInfo info{};
    info.struct_size = sizeof(info);
    info.width = 8;
    info.height = 8;
    info.dpi = 264;
    info.preferred_format = kPlutoPixelFormatRgb565;
    info.is_color = false;
    info.reports_completion = true;
    info.rect_alignment = 8;
    for (int i = 0; i < 4; ++i) {
      info.nominal_latency_ms[i] = 0;
    }
    *out_info = info;
    return kPlutoStatusOk;
  };
  ops.present = [](PlutoPresenter *presenter,
                   const PlutoPresentRequest *request) {
    auto *c = reinterpret_cast<Ctx *>(presenter);
    ++c->presents;
    c->frame_ids.push_back(request->frame_id);
    // Completes synchronously on the present() stack. The completion
    // contract (presenter.h:96-99) requires this to be enqueue-only and
    // deadlock-free even though the pipeline mutex is held right now.
    c->renderer->notify_present_complete(request->frame_id);
    return kPlutoStatusOk;
  };
  ops.ready = [](PlutoPresenter *, PlutoRefreshClass) { return true; };

  pluto::FrameRendererConfig renderer_config{};
  renderer_config.width = 8;
  renderer_config.height = 8;
  renderer_config.format = kPlutoPixelFormatRgb565;
  renderer_config.start_presenter_thread = false;
  renderer_config.enable_present_bridge = false;
  renderer_config.presenter_ops = &ops;
  renderer_config.presenter = reinterpret_cast<PlutoPresenter *>(&ctx);
  auto renderer = std::make_unique<pluto::FrameRenderer>(renderer_config);
  ASSERT_TRUE(renderer->valid());
  ctx.renderer = renderer.get();

  static std::vector<uint16_t> pixels;
  pixels.assign(8 * 8, 0);
  std::promise<void> done;
  std::future<void> finished = done.get_future();
  std::thread worker([&renderer, &done] {
    pluto::PlutoFramePacket packet{};
    packet.pixels = pixels.data();
    packet.row_bytes = 8 * sizeof(uint16_t);
    packet.width = 8;
    packet.height = 8;
    packet.format = kPlutoPixelFormatRgb565;
    packet.did_update = true;
    packet.presentation_time_ns = 1000;
    renderer->submit_frame(packet);
    // Second frame: the tick drains the frame-1 completion first, so the
    // scheduler is free to present again within this call.
    pixels[0] = 0xffff;
    packet.presentation_time_ns = 2000;
    renderer->submit_frame(packet);
    done.set_value();
  });
  const bool completed =
      finished.wait_for(std::chrono::seconds(10)) == std::future_status::ready;
  if (completed) {
    worker.join();
  } else {
    // The worker is deadlocked holding the renderer mutex; leak both rather
    // than hanging the whole suite in join()/~FrameRenderer.
    worker.detach();
    (void)renderer.release();
  }
  ASSERT_TRUE(completed)
      << "submit_frame deadlocked on a synchronous-completion presenter";
  EXPECT_TRUE(ctx.presents >= 2u);
  ASSERT_TRUE(ctx.frame_ids.size() >= 2u);
  EXPECT_EQ(ctx.frame_ids[0], 1u);
  EXPECT_EQ(ctx.frame_ids[1], 2u);
}

struct DeferredCtx {
  const PlutoPresenterOps *ops = nullptr;
  PlutoPresenter *presenter = nullptr;
  std::atomic<std::thread::id> present_thread{};
  std::atomic<bool> present_on_stack{false};
  std::atomic<bool> completed_on_present_stack{false};
  std::mutex mutex;
  std::condition_variable cv;
  std::vector<uint64_t> completions;
  std::vector<uint16_t> pixels = std::vector<uint16_t>(8 * 8, 0);
};

PlutoStatus present_deferred_frame(DeferredCtx *ctx, uint64_t frame_id) {
  PlutoPresentRequest request{};
  request.struct_size = sizeof(request);
  request.surface =
      PlutoSurface{reinterpret_cast<const uint8_t *>(ctx->pixels.data()),
                     8 * sizeof(uint16_t), 8, 8, kPlutoPixelFormatRgb565};
  PlutoRect damage{0, 0, 8, 8};
  request.damage = &damage;
  request.damage_count = 1;
  request.refresh_class = kPlutoRefreshUi;
  request.frame_id = frame_id;
  ctx->present_thread.store(std::this_thread::get_id());
  ctx->present_on_stack.store(true);
  const PlutoStatus status = ctx->ops->present(ctx->presenter, &request);
  ctx->present_on_stack.store(false);
  return status;
}

void deferred_on_complete(uint64_t frame_id, void *user_data) {
  auto *ctx = static_cast<DeferredCtx *>(user_data);
  if (ctx->present_on_stack.load() &&
      std::this_thread::get_id() == ctx->present_thread.load()) {
    ctx->completed_on_present_stack.store(true);
  }
  if (frame_id < 3) {
    // Re-enter the presenter from the completion, as pipeline callers do.
    present_deferred_frame(ctx, frame_id + 1);
  }
  {
    std::lock_guard<std::mutex> lock(ctx->mutex);
    ctx->completions.push_back(frame_id);
  }
  ctx->cv.notify_all();
}

// Pins host_preview.cc's deferred completion delivery: on_complete must never
// fire on the present() stack (the pipeline re-enters and its non-recursive
// mutex would deadlock), and re-entrant presents from on_complete must
// complete, in order.
void run_deferred_completion_check(const PlutoPresenterOps *ops,
                                   const char *options) {
  DeferredCtx ctx;
  ctx.ops = ops;
  PlutoPresenterConfig config{};
  config.struct_size = sizeof(config);
  config.backend_name = ops->name;
  config.options = options;
  config.on_complete = &deferred_on_complete;
  config.user_data = &ctx;
  ASSERT_EQ(ops->open(&config, &ctx.presenter), kPlutoStatusOk);
  ASSERT_EQ(present_deferred_frame(&ctx, 1), kPlutoStatusOk);
  {
    std::unique_lock<std::mutex> lock(ctx.mutex);
    ASSERT_TRUE(ctx.cv.wait_for(lock, std::chrono::seconds(5), [&ctx] {
      return ctx.completions.size() == 3;
    }));
    ASSERT_EQ(ctx.completions.size(), 3u);
    EXPECT_EQ(ctx.completions[0], 1u);
    EXPECT_EQ(ctx.completions[1], 2u);
    EXPECT_EQ(ctx.completions[2], 3u);
  }
  EXPECT_FALSE(ctx.completed_on_present_stack.load());
  EXPECT_EQ(ops->wait_idle(ctx.presenter, 1000), kPlutoStatusOk);
  ops->close(ctx.presenter);
}

TEST(HostPreviewPresenter, NullPresenterDefersCompletionOffPresentStack) {
  run_deferred_completion_check(pluto_null_presenter_ops(), nullptr);
}

TEST(HostPreviewPresenter, HostPreviewDefersCompletionOffPresentStack) {
  const std::filesystem::path dir = std::filesystem::temp_directory_path() /
                                    "pluto-host-preview-completion-test";
  const std::string options = "dir=" + dir.string();
  run_deferred_completion_check(pluto_host_preview_presenter_ops(),
                                options.c_str());
}

TEST(SoftwareCompositor, FrameRendererMarksChromaTilesOnColorPanels) {
  static PlutoPresenterOps ops{};
  ops.struct_size = sizeof(ops);
  ops.name = "chroma-stub";
  ops.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
    PlutoDisplayInfo info{};
    info.struct_size = sizeof(info);
    info.width = 64;
    info.height = 64;
    info.dpi = 264;
    info.preferred_format = kPlutoPixelFormatRgb565;
    info.is_color = true;
    info.backend_quantizes_color = true;
    info.rect_alignment = 8;
    for (int i = 0; i < 4; ++i) {
      info.nominal_latency_ms[i] = 0;
    }
    *out_info = info;
    return kPlutoStatusOk;
  };
  ops.present = [](PlutoPresenter *, const PlutoPresentRequest *) {
    return kPlutoStatusOk;
  };
  ops.ready = [](PlutoPresenter *, PlutoRefreshClass) { return true; };

  pluto::FrameRendererConfig renderer_config{};
  renderer_config.width = 64;
  renderer_config.height = 64;
  renderer_config.format = kPlutoPixelFormatRgb565;
  renderer_config.start_presenter_thread = false;
  renderer_config.presenter_ops = &ops;
  renderer_config.presenter = reinterpret_cast<PlutoPresenter *>(&ops);
  pluto::FrameRenderer renderer(renderer_config);
  ASSERT_TRUE(renderer.valid());

  // With no valid prior raw mirror, even an achromatic first frame is a
  // conservative color erase of unknown handoff pigment and must establish
  // Full truth for every candidate tile.
  std::vector<uint16_t> pixels(64 * 64, 0x8410); // mid gray in RGB565
  pluto::PlutoFramePacket packet{};
  packet.pixels = pixels.data();
  packet.row_bytes = 64 * sizeof(uint16_t);
  packet.width = 64;
  packet.height = 64;
  packet.format = kPlutoPixelFormatRgb565;
  packet.did_update = true;
  ASSERT_TRUE(renderer.submit_frame(packet));
  EXPECT_EQ(renderer.chroma_marked_tiles(), 4u);
  const size_t unknown_prior_marks = renderer.chroma_marked_tiles();

  // Saturated red frame: the changed tiles must be marked chroma-bearing.
  std::fill(pixels.begin(), pixels.end(), static_cast<uint16_t>(0xf800));
  ASSERT_TRUE(renderer.submit_frame(packet));
  EXPECT_GT(renderer.chroma_marked_tiles(), unknown_prior_marks);
}

} // namespace
