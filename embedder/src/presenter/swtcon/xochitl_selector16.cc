#include "presenter/swtcon/xochitl_selector16.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <system_error>
#include <utility>

#include "presenter/swtcon/xochitl_parallel.h"

namespace pluto::swtcon {
namespace {

constexpr std::uint32_t kOpaqueBlack = 0xff000000u;
constexpr std::uint32_t kOpaqueWhite = 0xffffffffu;
constexpr std::uint8_t kPixelClassMask = 0x07u;
constexpr std::uint8_t kSpecialLumaBit = 0x08u;
constexpr std::uint8_t kCoarseWhiteBit = 0x10u;
constexpr std::uint8_t kCoarseBlackBit = 0x20u;

std::uint32_t load_argb8888_le(const std::uint8_t *source) {
  return static_cast<std::uint32_t>(source[0]) |
         (static_cast<std::uint32_t>(source[1]) << 8) |
         (static_cast<std::uint32_t>(source[2]) << 16) |
         (static_cast<std::uint32_t>(source[3]) << 24);
}

std::uint32_t expand_rgb565_le(const std::uint8_t *source) {
  const std::uint16_t packed = static_cast<std::uint16_t>(source[0]) |
                               static_cast<std::uint16_t>(source[1] << 8);
  const std::uint8_t red5 = static_cast<std::uint8_t>(packed >> 11);
  const std::uint8_t green6 = static_cast<std::uint8_t>((packed >> 5) & 63u);
  const std::uint8_t blue5 = static_cast<std::uint8_t>(packed & 31u);
  const std::uint8_t red8 =
      static_cast<std::uint8_t>((red5 << 3) | (red5 >> 2));
  const std::uint8_t green8 =
      static_cast<std::uint8_t>((green6 << 2) | (green6 >> 4));
  const std::uint8_t blue8 =
      static_cast<std::uint8_t>((blue5 << 3) | (blue5 >> 2));
  return kOpaqueBlack | (static_cast<std::uint32_t>(red8) << 16) |
         (static_cast<std::uint32_t>(green8) << 8) | blue8;
}

std::uint16_t load_rgb565_le(const std::uint8_t *source) {
  return static_cast<std::uint16_t>(source[0]) |
         static_cast<std::uint16_t>(source[1] << 8);
}

std::uint16_t load_rgb565_at(const XochitlSelector16::SourceView &source,
                             std::int32_t x, std::int32_t y) {
  if (x >= XochitlSelector16::kLogicalWidth &&
      source.right_padding == XochitlSelector16::RightPadding::kWhite) {
    return 0xffffu;
  }
  const std::int32_t source_x =
      std::min(x, XochitlSelector16::kLogicalWidth - 1);
  const std::uint8_t *pixel =
      source.bytes.data() + static_cast<std::size_t>(y) * source.stride_bytes +
      static_cast<std::size_t>(source_x) * 2u;
  return load_rgb565_le(pixel);
}

bool rgb565_special_at(const XochitlSelector16::SourceView &source,
                       std::int32_t x, std::int32_t y) {
  const std::uint16_t packed = load_rgb565_at(source, x, y);
  return packed == 0u || packed == 0xffffu;
}

// Compact scratch encoding used only while the direct RGB565 path is between
// its coarse and resolve barriers. The low bits are the stock pixel class;
// the upper bits retain the two coarse flags and the exact black/white marker
// without materializing a 6.5 MB ARGB plane first.
std::uint8_t rgb565_info(std::uint16_t packed) {
  if (packed == 0u) {
    return static_cast<std::uint8_t>(2u | kSpecialLumaBit | kCoarseBlackBit);
  }
  if (packed == 0xffffu) {
    return static_cast<std::uint8_t>(1u | kSpecialLumaBit | kCoarseWhiteBit);
  }
  const std::uint8_t red5 = static_cast<std::uint8_t>(packed >> 11);
  const std::uint8_t green6 = static_cast<std::uint8_t>((packed >> 5) & 63u);
  const std::uint8_t blue5 = static_cast<std::uint8_t>(packed & 31u);
  const std::uint8_t red8 =
      static_cast<std::uint8_t>((red5 << 3) | (red5 >> 2));
  const std::uint8_t green8 =
      static_cast<std::uint8_t>((green6 << 2) | (green6 >> 4));
  const std::uint8_t blue8 =
      static_cast<std::uint8_t>((blue5 << 3) | (blue5 >> 2));
  if (red8 != green8 || red8 != blue8) {
    return 4u;
  }
  std::uint8_t info = 3u;
  info |= red8 >= 240u ? kCoarseWhiteBit : 0u;
  info |= red8 <= 15u ? kCoarseBlackBit : 0u;
  return info;
}

bool rgb_is_gray(std::uint32_t pixel) {
  const std::uint8_t blue = static_cast<std::uint8_t>(pixel);
  const std::uint8_t green = static_cast<std::uint8_t>(pixel >> 8);
  const std::uint8_t red = static_cast<std::uint8_t>(pixel >> 16);
  return blue == green && blue == red;
}

bool special_luma(std::uint32_t pixel) {
  return pixel == kOpaqueBlack || pixel == kOpaqueWhite;
}

} // namespace

XochitlSelector16::SelectorMask::SelectorMask(InclusiveRect execution,
                                              std::int32_t width,
                                              std::int32_t height,
                                              std::vector<std::uint8_t> bytes)
    : execution_(execution), width_(width), height_(height),
      stride_(static_cast<std::size_t>(width)), bytes_(std::move(bytes)) {}

XochitlSelector16::XochitlSelector16()
    : XochitlSelector16(std::thread::hardware_concurrency()) {}

XochitlSelector16::XochitlSelector16(unsigned int logical_cpus)
    : argb_(static_cast<std::size_t>(kPanelWidth) * kPanelHeight, kOpaqueWhite),
      coarse_(static_cast<std::size_t>(kCoarseWidth) * kCoarseHeight, 0),
      selector_(static_cast<std::size_t>(kPanelWidth) * kPanelHeight, 0) {
  const std::size_t desired_workers =
      xochitl_parallel::compute_stripes_for_logical_cpus(logical_cpus);
  compute_stripe_count_ = desired_workers;
  if (desired_workers <= 1u) {
    return;
  }
  std::size_t started = 0;
  try {
    for (; started < desired_workers; ++started) {
      workers_[started] =
          std::thread([this, started] { worker_loop(started); });
    }
    active_worker_count_ = desired_workers;
    parallel_available_ = true;
  } catch (const std::system_error &) {
    // Thread creation is an optimization, not a correctness requirement.
    // Wake and join any workers already created, then use the exact serial
    // staged path for this object's lifetime.
    {
      std::lock_guard lock(worker_mutex_);
      worker_stop_ = true;
    }
    worker_cv_.notify_all();
    for (std::size_t index = 0; index < started; ++index) {
      if (workers_[index].joinable()) {
        workers_[index].join();
      }
    }
    active_worker_count_ = 0;
    parallel_available_ = false;
  }
}

XochitlSelector16::~XochitlSelector16() {
  {
    std::lock_guard lock(worker_mutex_);
    worker_stop_ = true;
  }
  worker_cv_.notify_all();
  for (std::thread &worker : workers_) {
    if (worker.joinable()) {
      worker.join();
    }
  }
}

bool XochitlSelector16::valid_update(InclusiveRect update) {
  return update.left >= 0 && update.top >= 0 && update.right >= update.left &&
         update.bottom >= update.top && update.right < kLogicalWidth &&
         update.bottom < kPanelHeight;
}

XochitlSelector16::InclusiveRect
XochitlSelector16::rounded_execution(InclusiveRect update) {
  return InclusiveRect{
      .left = update.left & ~15,
      .top = update.top & ~15,
      .right = (update.right + 16) & ~15,
      .bottom = (update.bottom + 16) & ~15,
  };
}

std::array<XochitlSelector16::Stripe, XochitlSelector16::kWorkerCapacity>
XochitlSelector16::make_stripes(InclusiveRect update,
                                std::size_t stripe_count) {
  std::array<Stripe, kWorkerCapacity> stripes{};
  const InclusiveRect execution = rounded_execution(update);
  const std::uint32_t divisor = static_cast<std::uint32_t>(
      update.bottom - update.top > 28
          ? std::clamp<std::size_t>(stripe_count, 1u, kWorkerCapacity)
          : 1u);
  const std::int32_t y_begin = execution.top;
  const std::int32_t y_end = execution.bottom;
  const std::uint32_t height = static_cast<std::uint32_t>(y_end - y_begin);
  for (std::uint32_t index = 0; index < divisor; ++index) {
    const std::uint32_t begin_offset = index * height / divisor;
    const std::uint32_t end_offset = (index + 1u) * height / divisor;
    const std::int32_t stripe_begin =
        (y_begin + static_cast<std::int32_t>(begin_offset)) & ~15;
    const std::int32_t stripe_end =
        (y_begin + static_cast<std::int32_t>(end_offset)) & ~15;
    stripes[index] = Stripe{.left = execution.left,
                            .top = stripe_begin,
                            .right = execution.right - 1,
                            .bottom = stripe_end - 1};
  }
  return stripes;
}

std::size_t XochitlSelector16::panel_index(std::int32_t x, std::int32_t y) {
  return static_cast<std::size_t>(y) * kPanelWidth +
         static_cast<std::size_t>(x);
}

std::size_t XochitlSelector16::coarse_index(std::int32_t x, std::int32_t y) {
  return static_cast<std::size_t>(y) * kCoarseWidth +
         static_cast<std::size_t>(x);
}

XochitlSelector16::BuildError
XochitlSelector16::validate_source(const SourceView &source) const {
  if (source.width != kLogicalWidth || source.height != kPanelHeight) {
    return BuildError::kInvalidSourceGeometry;
  }

  std::size_t bytes_per_pixel = 0;
  switch (source.format) {
  case SourceFormat::kRgb565LittleEndian:
    bytes_per_pixel = 2;
    break;
  case SourceFormat::kArgb8888LittleEndian:
    bytes_per_pixel = 4;
    break;
  default:
    return BuildError::kUnsupportedFormat;
  }
  switch (source.right_padding) {
  case RightPadding::kReplicateLogicalEdge:
  case RightPadding::kWhite:
    break;
  default:
    return BuildError::kUnsupportedPadding;
  }

  const std::size_t row_bytes =
      static_cast<std::size_t>(kLogicalWidth) * bytes_per_pixel;
  if (source.stride_bytes < row_bytes) {
    return BuildError::kInvalidStride;
  }
  constexpr std::size_t kRowsBeforeLast =
      static_cast<std::size_t>(kPanelHeight - 1);
  if (source.stride_bytes >
      (std::numeric_limits<std::size_t>::max() - row_bytes) / kRowsBeforeLast) {
    return BuildError::kBufferTooSmall;
  }
  const std::size_t required =
      kRowsBeforeLast * source.stride_bytes + row_bytes;
  return source.bytes.size() < required ? BuildError::kBufferTooSmall
                                        : BuildError::kNone;
}

void XochitlSelector16::populate_argb(const SourceView &source,
                                      InclusiveRect execution) {
  const std::int32_t first_x = execution.left == 0 ? 0 : execution.left - 1;
  const std::int32_t last_logical_x =
      std::min(execution.right - 1, kLogicalWidth - 1);
  const std::size_t bytes_per_pixel =
      source.format == SourceFormat::kRgb565LittleEndian ? 2u : 4u;

  for (std::int32_t y = execution.top; y < execution.bottom; ++y) {
    const std::uint8_t *source_row =
        source.bytes.data() + static_cast<std::size_t>(y) * source.stride_bytes;
    std::uint32_t *destination_row =
        argb_.data() + static_cast<std::size_t>(y) * kPanelWidth;
    for (std::int32_t x = first_x; x <= last_logical_x; ++x) {
      const std::uint8_t *pixel =
          source_row + static_cast<std::size_t>(x) * bytes_per_pixel;
      destination_row[x] = source.format == SourceFormat::kRgb565LittleEndian
                               ? expand_rgb565_le(pixel)
                               : load_argb8888_le(pixel);
    }
    if (execution.right > kLogicalWidth) {
      const std::uint32_t padding = source.right_padding == RightPadding::kWhite
                                        ? kOpaqueWhite
                                        : destination_row[kLogicalWidth - 1];
      std::fill(destination_row + kLogicalWidth,
                destination_row + execution.right, padding);
    }
  }
}

void XochitlSelector16::run_coarse(const Stripe &stripe,
                                   const SourceView &source) {
  if (stripe.empty()) {
    return;
  }

  const std::int32_t coarse_left = stripe.left >> 2;
  const std::int32_t coarse_top = stripe.top >> 2;
  const std::int32_t coarse_right = (stripe.right + 1) >> 2;
  const std::int32_t coarse_bottom = (stripe.bottom + 1) >> 2;
  for (std::int32_t y = coarse_top; y < coarse_bottom; ++y) {
    std::fill(coarse_.begin() +
                  static_cast<std::ptrdiff_t>(coarse_index(coarse_left, y)),
              coarse_.begin() +
                  static_cast<std::ptrdiff_t>(coarse_index(coarse_right, y)),
              0);
  }

  const bool direct_rgb565 =
      source.format == SourceFormat::kRgb565LittleEndian;
  for (std::int32_t y = stripe.top; y <= stripe.bottom; ++y) {
    const std::uint32_t *source_row =
        argb_.data() + static_cast<std::size_t>(y) * kPanelWidth;
    const std::uint8_t *rgb565_row =
        direct_rgb565
            ? source.bytes.data() +
                  static_cast<std::size_t>(y) * source.stride_bytes
            : nullptr;
    const std::uint16_t rgb565_padding =
        direct_rgb565 && source.right_padding == RightPadding::kWhite
            ? 0xffffu
            : direct_rgb565
                  ? load_rgb565_le(rgb565_row +
                                   static_cast<std::size_t>(kLogicalWidth - 1) *
                                       2u)
                  : 0u;
    // RGB565 does not need the ARGB workspace. Reuse its byte storage for the
    // compact coarse->classify handoff instead of changing selector_ before
    // the stock classify clip has written that pixel (panel-edge scratch must
    // retain its prior value exactly).
    std::uint8_t *rgb565_info_row =
        reinterpret_cast<std::uint8_t *>(argb_.data()) +
        static_cast<std::size_t>(y) * kPanelWidth;
    std::uint8_t *coarse_row =
        coarse_.data() + static_cast<std::size_t>(y >> 2) * kCoarseWidth;
    for (std::int32_t x = stripe.left; x <= stripe.right; ++x) {
      if (direct_rgb565) {
        const std::uint16_t packed =
            x < kLogicalWidth
                ? load_rgb565_le(rgb565_row + static_cast<std::size_t>(x) * 2u)
                : rgb565_padding;
        const std::uint8_t info = rgb565_info(packed);
        rgb565_info_row[x] = info;
        std::uint8_t flags = 0;
        flags |= (info & kCoarseWhiteBit) != 0u ? 1u : 0u;
        flags |= (info & kCoarseBlackBit) != 0u ? 2u : 0u;
        coarse_row[x >> 2] |= flags;
        continue;
      }
      const std::uint32_t pixel = source_row[x];
      if (!rgb_is_gray(pixel)) {
        continue;
      }
      const std::uint8_t value = static_cast<std::uint8_t>(pixel);
      std::uint8_t flags = 0;
      flags |= value >= 240u ? 1u : 0u;
      flags |= value <= 15u ? 2u : 0u;
      coarse_row[x >> 2] |= flags;
    }
  }
}

void XochitlSelector16::run_classify(const Stripe &stripe,
                                     const SourceView &source) {
  if (stripe.empty()) {
    return;
  }
  const std::int32_t left = std::max(stripe.left, 4);
  const std::int32_t top = std::max(stripe.top, 4);
  const std::int32_t right = std::min(stripe.right, kPanelWidth - 5);
  const std::int32_t bottom = std::min(stripe.bottom, kPanelHeight - 5);
  if (left > right || top > bottom) {
    return;
  }

  const bool direct_rgb565 =
      source.format == SourceFormat::kRgb565LittleEndian;
  for (std::int32_t y = top; y <= bottom; ++y) {
    const std::uint32_t *source_row =
        argb_.data() + static_cast<std::size_t>(y) * kPanelWidth;
    std::uint8_t *selector_row =
        selector_.data() + static_cast<std::size_t>(y) * kPanelWidth;
    const std::uint8_t *rgb565_info_row =
        reinterpret_cast<const std::uint8_t *>(argb_.data()) +
        static_cast<std::size_t>(y) * kPanelWidth;
    for (std::int32_t x = left; x <= right; ++x) {
      if (direct_rgb565) {
        const std::uint8_t info = rgb565_info_row[x];
        std::uint8_t pixel_class =
            static_cast<std::uint8_t>(info & kPixelClassMask);
        if (pixel_class == 3u) {
          std::uint8_t flags = 0;
          const std::int32_t coarse_x = x >> 2;
          const std::int32_t coarse_y = y >> 2;
          for (std::int32_t dy = -1; dy <= 1; ++dy) {
            const std::uint8_t *coarse_row =
                coarse_.data() +
                static_cast<std::size_t>(coarse_y + dy) * kCoarseWidth;
            flags |= coarse_row[coarse_x - 1];
            flags |= coarse_row[coarse_x];
            flags |= coarse_row[coarse_x + 1];
          }
          pixel_class = flags == 3u ? 0u : 3u;
        }
        selector_row[x] = pixel_class;
        continue;
      }
      const std::uint32_t pixel = source_row[x];
      std::uint8_t pixel_class = 1;
      if (pixel == kOpaqueBlack) {
        pixel_class = 2;
      } else if (pixel != kOpaqueWhite) {
        if (!rgb_is_gray(pixel)) {
          pixel_class = 4;
        } else {
          std::uint8_t flags = 0;
          const std::int32_t coarse_x = x >> 2;
          const std::int32_t coarse_y = y >> 2;
          for (std::int32_t dy = -1; dy <= 1; ++dy) {
            const std::uint8_t *coarse_row =
                coarse_.data() +
                static_cast<std::size_t>(coarse_y + dy) * kCoarseWidth;
            flags |= coarse_row[coarse_x - 1];
            flags |= coarse_row[coarse_x];
            flags |= coarse_row[coarse_x + 1];
          }
          pixel_class = flags == 3u ? 0u : 3u;
        }
      }
      selector_row[x] = pixel_class;
    }
  }
}

void XochitlSelector16::run_resolve(const Stripe &stripe,
                                    const SourceView &source,
                                    InclusiveRect execution,
                                    std::uint8_t *output,
                                    std::size_t output_stride) {
  if (stripe.empty()) {
    return;
  }

  const bool direct_rgb565 =
      source.format == SourceFormat::kRgb565LittleEndian;
  for (std::int32_t block_y = stripe.top; block_y <= stripe.bottom;
       block_y += 16) {
    for (std::int32_t block_x = stripe.left; block_x <= stripe.right;
         block_x += 16) {
      std::uint32_t class_three_count = 0;
      bool has_class_four = false;
      for (std::int32_t y = block_y; y < block_y + 16; ++y) {
        const std::uint8_t *selector_row =
            selector_.data() + static_cast<std::size_t>(y) * kPanelWidth;
        for (std::int32_t x = block_x; x < block_x + 16; ++x) {
          const std::uint8_t pixel_class = static_cast<std::uint8_t>(
              selector_row[x] & kPixelClassMask);
          class_three_count += pixel_class == 3u ? 1u : 0u;
          has_class_four = has_class_four || pixel_class == 4u;
        }
      }
      const std::uint8_t block_default =
          !has_class_four && class_three_count <= 15u ? 0xffu : 0x00u;

      for (std::int32_t y = block_y; y < block_y + 16; ++y) {
        const std::uint32_t *source_row =
            argb_.data() + static_cast<std::size_t>(y) * kPanelWidth;
        const std::uint8_t *rgb565_info_row =
            reinterpret_cast<const std::uint8_t *>(argb_.data()) +
            static_cast<std::size_t>(y) * kPanelWidth;
        std::uint8_t *selector_row =
            selector_.data() + static_cast<std::size_t>(y) * kPanelWidth;
        std::uint8_t *output_row =
            output +
            static_cast<std::size_t>(y - execution.top) * output_stride;
        bool previous_special =
            direct_rgb565 &&
            (block_x == 0 || rgb565_special_at(source, block_x - 1, y));
        for (std::int32_t x = block_x; x < block_x + 16; ++x) {
          std::uint8_t resolved = block_default;
          if (direct_rgb565) {
            const bool current_special =
                (rgb565_info_row[x] & kSpecialLumaBit) != 0u;
            if (current_special && previous_special) {
              resolved = 0xffu;
            }
            previous_special = current_special;
          } else if (special_luma(source_row[x]) &&
                     (x == 0 || special_luma(source_row[x - 1]))) {
            resolved = 0xffu;
          }
          selector_row[x] = resolved;
          output_row[x - execution.left] = resolved;
        }
      }
    }
  }
}

void XochitlSelector16::run_stage_serial(
    Stage stage, const std::array<Stripe, kWorkerCapacity> &stripes,
    std::size_t count, const SourceView &source, InclusiveRect execution,
    std::uint8_t *output, std::size_t output_stride) {
  for (std::size_t index = 0; index < count; ++index) {
    switch (stage) {
    case Stage::kCoarse:
      run_coarse(stripes[index], source);
      break;
    case Stage::kClassify:
      run_classify(stripes[index], source);
      break;
    case Stage::kResolve:
      run_resolve(stripes[index], source, execution, output, output_stride);
      break;
    }
  }
}

void XochitlSelector16::run_parallel(
    const std::array<Stripe, kWorkerCapacity> &stripes,
    const SourceView &source, InclusiveRect execution, std::uint8_t *output,
    std::size_t output_stride) {
  {
    std::lock_guard lock(worker_mutex_);
    worker_stripes_ = stripes;
    worker_source_ = source;
    worker_execution_ = execution;
    worker_output_ = output;
    worker_output_stride_ = output_stride;
    worker_done_ = 0;
    worker_barrier_arrived_ = 0;
    ++worker_epoch_;
  }
  worker_cv_.notify_all();

  std::unique_lock lock(worker_mutex_);
  worker_done_cv_.wait(
      lock, [this] { return worker_done_ == active_worker_count_; });
}

void XochitlSelector16::worker_barrier() {
  std::unique_lock lock(worker_mutex_);
  const std::uint64_t observed_epoch = worker_barrier_epoch_;
  ++worker_barrier_arrived_;
  if (worker_barrier_arrived_ == active_worker_count_) {
    worker_barrier_arrived_ = 0;
    ++worker_barrier_epoch_;
    worker_cv_.notify_all();
    return;
  }
  worker_cv_.wait(lock, [this, observed_epoch] {
    return worker_stop_ || worker_barrier_epoch_ != observed_epoch;
  });
}

void XochitlSelector16::worker_loop(std::size_t worker_index) {
  std::uint64_t observed_epoch = 0;
  for (;;) {
    Stripe stripe;
    SourceView source;
    InclusiveRect execution;
    std::uint8_t *output = nullptr;
    std::size_t output_stride = 0;
    {
      std::unique_lock lock(worker_mutex_);
      worker_cv_.wait(lock, [this, observed_epoch] {
        return worker_stop_ || worker_epoch_ != observed_epoch;
      });
      if (worker_stop_) {
        return;
      }
      observed_epoch = worker_epoch_;
      stripe = worker_stripes_[worker_index];
      source = worker_source_;
      execution = worker_execution_;
      output = worker_output_;
      output_stride = worker_output_stride_;
    }

    run_coarse(stripe, source);
    worker_barrier();
    run_classify(stripe, source);
    worker_barrier();
    run_resolve(stripe, source, execution, output, output_stride);

    {
      std::lock_guard lock(worker_mutex_);
      ++worker_done_;
      if (worker_done_ == active_worker_count_) {
        worker_done_cv_.notify_one();
      }
    }
  }
}

XochitlSelector16::BuildResult XochitlSelector16::build(SourceView source,
                                                        InclusiveRect update) {
  if (!valid_update(update)) {
    return {.error = BuildError::kInvalidGeometry};
  }
  const BuildError source_error = validate_source(source);
  if (source_error != BuildError::kNone) {
    return {.error = source_error};
  }

  const InclusiveRect execution = rounded_execution(update);
  const std::int32_t width = execution.right - execution.left;
  const std::int32_t height = execution.bottom - execution.top;
  std::vector<std::uint8_t> output(static_cast<std::size_t>(width) *
                                   static_cast<std::size_t>(height));
  auto mutable_mask = std::shared_ptr<SelectorMask>(
      new SelectorMask(InclusiveRect{.left = execution.left,
                                     .top = execution.top,
                                     .right = execution.right - 1,
                                     .bottom = execution.bottom - 1},
                       width, height, std::move(output)));

  std::lock_guard operation_lock(build_mutex_);
  if (source.format != SourceFormat::kRgb565LittleEndian) {
    populate_argb(source, execution);
  }
  const std::size_t count =
      update.bottom - update.top > 28 ? compute_stripe_count_ : 1u;
  const std::array<Stripe, kWorkerCapacity> stripes =
      make_stripes(update, count);
  std::uint8_t *output_data = mutable_mask->bytes_.data();
  const std::size_t output_stride = mutable_mask->stride_;

  // The persistent workers amortize well for broad updates.  Below four
  // 128x128 blocks, the two barriers cost more than the scalar work in the
  // host release benchmark; keep the same CPU-capped stripe/stage order on
  // the caller. This affects execution placement only, never stage visibility.
  constexpr std::size_t kParallelPixelThreshold = 4u * 128u * 128u;
  const std::size_t execution_pixels =
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
  if (count > 1u && parallel_available_ && count == active_worker_count_ &&
      execution_pixels >= kParallelPixelThreshold) {
    run_parallel(stripes, source, execution, output_data, output_stride);
  } else {
    run_stage_serial(Stage::kCoarse, stripes, count, source, execution,
                     output_data, output_stride);
    run_stage_serial(Stage::kClassify, stripes, count, source, execution,
                     output_data, output_stride);
    run_stage_serial(Stage::kResolve, stripes, count, source, execution,
                     output_data, output_stride);
  }

  std::shared_ptr<const SelectorMask> immutable = std::move(mutable_mask);
  return {.error = BuildError::kNone, .mask = std::move(immutable)};
}

void XochitlSelector16::reset() {
  std::lock_guard lock(build_mutex_);
  std::fill(argb_.begin(), argb_.end(), kOpaqueWhite);
  std::fill(coarse_.begin(), coarse_.end(), 0);
  std::fill(selector_.begin(), selector_.end(), 0);
}

} // namespace pluto::swtcon
