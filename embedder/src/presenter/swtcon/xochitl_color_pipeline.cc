#include "presenter/swtcon/xochitl_color_pipeline.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "presenter/swtcon/xochitl_delta_table.h"
#include "presenter/swtcon/xochitl_parallel.h"
#include "presenter/swtcon/xochitl_selector16.h"

namespace pluto::swtcon {
namespace {

constexpr std::array<std::pair<XochitlHistoryState::Mode, int>, 4>
    kRequiredModes{{
        {XochitlHistoryState::Mode::kText, 1},
        {XochitlHistoryState::Mode::kUi, 5},
        {XochitlHistoryState::Mode::kFull, 6},
        {XochitlHistoryState::Mode::kFast, 7},
    }};

bool byte_plane_fits(std::span<const std::uint8_t> bytes, std::size_t stride,
                     std::int32_t width, std::int32_t height) {
  if (width <= 0 || height <= 0 || stride < static_cast<std::size_t>(width)) {
    return false;
  }
  const std::size_t rows = static_cast<std::size_t>(height - 1);
  const std::size_t columns = static_cast<std::size_t>(width);
  if (rows > (std::numeric_limits<std::size_t>::max() - columns) / stride) {
    return false;
  }
  return bytes.size() >= rows * stride + columns;
}

bool convert_rgb565_parallel(const Ct33Frontend *frontend,
                             const std::uint8_t *source,
                             std::size_t source_stride, std::int32_t origin_x,
                             std::int32_t origin_y, std::int32_t width,
                             std::int32_t height, std::uint8_t *output,
                             std::size_t output_stride,
                             const std::uint8_t *selector,
                             std::size_t selector_stride) {
  const std::size_t pixels =
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
  const std::size_t stripe_count =
      xochitl_parallel::available_compute_stripes_for_work_items(pixels);
  // The measured 512x512 break-even keeps pen-sized ROIs serial while broad
  // and near-full quality updates retain parallel conversion.
  if (stripe_count == 1u || height < static_cast<std::int32_t>(stripe_count)) {
    return frontend->convert_rgb565_le(
        source, source_stride, origin_x, origin_y, width, height, output,
        output_stride, selector, selector_stride);
  }

  std::array<bool, xochitl_parallel::kMaxComputeStripes> converted{};
  const auto run_stripe = [&](std::size_t stripe) {
    const std::int32_t first_row = static_cast<std::int32_t>(
        stripe * static_cast<std::size_t>(height) / stripe_count);
    const std::int32_t last_row = static_cast<std::int32_t>(
        (stripe + 1u) * static_cast<std::size_t>(height) / stripe_count);
    const std::size_t source_offset =
        static_cast<std::size_t>(first_row) * source_stride;
    const std::size_t output_offset =
        static_cast<std::size_t>(first_row) * output_stride;
    const std::uint8_t *stripe_selector =
        selector == nullptr
            ? nullptr
            : selector + static_cast<std::size_t>(first_row) * selector_stride;
    converted[stripe] = frontend->convert_rgb565_le(
        source + source_offset, source_stride, origin_x, origin_y + first_row,
        width, last_row - first_row, output + output_offset, output_stride,
        stripe_selector, selector_stride);
  };

  xochitl_parallel::run_compute_stripes(stripe_count, run_stripe);
  for (std::size_t stripe = 0; stripe < stripe_count; ++stripe) {
    if (!converted[stripe]) {
      return false;
    }
  }
  return true;
}

} // namespace

XochitlColorPipeline::ImmutableOperation::ImmutableOperation(
    std::uint64_t configuration_generation, Mode mode, InclusiveRect requested,
    InclusiveRect execution, std::int32_t width, std::int32_t height,
    int temperature_bin, float temperature_celsius,
    std::vector<std::uint8_t> raw, std::vector<std::uint8_t> lane_mask)
    : configuration_generation_(configuration_generation), mode_(mode),
      requested_(requested), execution_(execution), width_(width),
      height_(height), temperature_bin_(temperature_bin),
      temperature_celsius_(temperature_celsius), raw_(std::move(raw)),
      lane_mask_(std::move(lane_mask)) {}

void XochitlColorPipeline::fail(std::string *error,
                                const std::string &message) {
  color_capable_ = false;
  waveform_ = nullptr;
  std_frontend_.clear();
  best_frontend_.clear();
  pen_frontend_.clear();
  fast_frontend_.clear();
  selector_.reset();
  history_.invalidate();
  if (error != nullptr) {
    *error = message;
  }
}

void XochitlColorPipeline::clear() {
  ++configuration_generation_;
  if (configuration_generation_ == 0) {
    configuration_generation_ = 1;
  }
  fail(nullptr, {});
  for (auto &by_bin : deltas_) {
    for (auto &delta : by_bin) {
      delta.fill(0);
    }
  }
}

int XochitlColorPipeline::delta_slot(Mode mode) {
  switch (mode) {
  case Mode::kText:
    return 0;
  case Mode::kUi:
    return 1;
  case Mode::kFull:
    return 2;
  case Mode::kFast:
  case Mode::kContent:
    return -1;
  }
  return -1;
}

Ct33Frontend *XochitlColorPipeline::frontend_for(Mode mode) {
  // Recovered selector 0x009ac424: signed render -1/5 -> fast, 1 -> pen,
  // 6 -> best, otherwise -> std. Production Fast uses the recovered -1
  // route; Content mode 2 is retained for exact mapped maintenance.
  switch (mode) {
  case Mode::kFast:
  case Mode::kUi:
    return &fast_frontend_;
  case Mode::kText:
    return &pen_frontend_;
  case Mode::kFull:
    return &best_frontend_;
  case Mode::kContent:
    return &std_frontend_;
  }
  return nullptr;
}

const Ct33Frontend *XochitlColorPipeline::frontend_for(Mode mode) const {
  return const_cast<XochitlColorPipeline *>(this)->frontend_for(mode);
}

bool XochitlColorPipeline::configure(
    const WaveformTable *waveform,
    const std::map<std::string, std::vector<std::uint8_t>> &ct33_blobs,
    std::string *error) {
  clear();
  if (waveform == nullptr || !waveform->valid()) {
    fail(error, "color pipeline requires a valid .eink table");
    return false;
  }
  if (waveform->temp_count() != static_cast<int>(kInstalledTemperatureBins)) {
    fail(error, "color pipeline requires the installed nine temperature bins");
    return false;
  }
  if (waveform->mode_count() <= 7) {
    fail(error, "color pipeline requires waveform modes 1, 5, 6, and 7");
    return false;
  }

  for (const auto &[mode, raw_mode] : kRequiredModes) {
    (void)mode;
    for (int bin = 0; bin < waveform->temp_count(); ++bin) {
      if (waveform->phase_count(raw_mode, bin) <= 0 ||
          waveform->phase_count(raw_mode, bin) > 255 ||
          waveform->phase_record_codes(raw_mode, bin).empty()) {
        fail(error, "color pipeline is missing a required mode/bin record");
        return false;
      }
    }
  }
  for (int bin = 0; bin < waveform->temp_count(); ++bin) {
    const int phases = waveform->phase_count(/*mode=*/2, bin);
    if (phases <= 0 || phases > 255 ||
        waveform->phase_record_codes(/*mode=*/2, bin).empty() ||
        build_legal_target_map(*waveform, /*mode=*/2, bin)[30] != 30) {
      fail(error,
           "color pipeline requires balanced startup mode 2 to reach white");
      return false;
    }
  }

  const auto configure_blob = [&](const char *name, Ct33Frontend *frontend) {
    const auto found = ct33_blobs.find(name);
    if (found == ct33_blobs.end()) {
      if (error != nullptr) {
        *error = std::string("missing required ct33 blob: ") + name;
      }
      return false;
    }
    std::string frontend_error;
    if (!frontend->configure(found->second, &frontend_error)) {
      if (error != nullptr) {
        *error =
            std::string("invalid ct33 blob ") + name + ": " + frontend_error;
      }
      return false;
    }
    return true;
  };
  if (!configure_blob("std", &std_frontend_) ||
      !configure_blob("best", &best_frontend_) ||
      !configure_blob("pen", &pen_frontend_) ||
      !configure_blob("fast", &fast_frontend_)) {
    const std::string message = error != nullptr ? *error : "invalid ct33";
    fail(error, message);
    return false;
  }

  for (const auto &[mode, raw_mode] : kRequiredModes) {
    const int slot = delta_slot(mode);
    if (slot < 0) {
      continue;
    }
    for (int bin = 0; bin < waveform->temp_count(); ++bin) {
      const XochitlDeltaTableResult delta =
          build_xochitl_delta_table(*waveform, raw_mode, bin);
      if (!delta) {
        fail(error, "exact Xochitl delta construction failed");
        return false;
      }
      deltas_[static_cast<std::size_t>(slot)][static_cast<std::size_t>(bin)] =
          delta.values;
    }
  }

  waveform_ = waveform;
  color_capable_ = true;
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

bool XochitlColorPipeline::valid_update(InclusiveRect update) {
  return update.left >= 0 && update.top >= 0 && update.right >= update.left &&
         update.bottom >= update.top && update.right < kLogicalWidth &&
         update.bottom < kLogicalHeight;
}

XochitlColorPipeline::InclusiveRect
XochitlColorPipeline::rounded_execution(InclusiveRect update) {
  const std::int32_t width = (update.right - update.left + 8) & ~7;
  const std::int32_t height = (update.bottom - update.top + 2) & ~1;
  return {update.left, update.top, update.left + width - 1,
          update.top + height - 1};
}

XochitlColorPipeline::BuildResult XochitlColorPipeline::preprocess_rgb565(
    std::span<const std::uint8_t> surface, std::size_t surface_stride,
    InclusiveRect update, Mode mode, int temperature_bin,
    float temperature_celsius, std::span<const std::uint8_t> lane_mask,
    std::size_t lane_mask_stride) {
  if (!color_capable_ || waveform_ == nullptr) {
    return {.error = BuildError::kNotConfigured};
  }
  Ct33Frontend *const frontend = frontend_for(mode);
  if (frontend == nullptr || mode == Mode::kContent) {
    return {.error = BuildError::kInvalidMode};
  }
  if (!valid_update(update)) {
    return {.error = BuildError::kInvalidGeometry};
  }
  if (temperature_bin < 0 ||
      temperature_bin >= static_cast<int>(kInstalledTemperatureBins) ||
      !std::isfinite(temperature_celsius)) {
    return {.error = BuildError::kInvalidGeometry};
  }
  const std::size_t logical_row_bytes =
      static_cast<std::size_t>(kLogicalWidth) * kRgb565BytesPerPixel;
  constexpr std::size_t kLastLogicalRow =
      static_cast<std::size_t>(kLogicalHeight - 1);
  if (surface.data() == nullptr || surface_stride < logical_row_bytes ||
      surface_stride >
          (std::numeric_limits<std::size_t>::max() - logical_row_bytes) /
              kLastLogicalRow) {
    return {.error = BuildError::kInvalidSurface};
  }
  const std::size_t required =
      kLastLogicalRow * surface_stride + logical_row_bytes;
  if (surface.size() < required) {
    return {.error = BuildError::kInvalidSurface};
  }

  const InclusiveRect execution = rounded_execution(update);
  const std::int32_t width = execution.right - execution.left + 1;
  const std::int32_t height = execution.bottom - execution.top + 1;
  const std::size_t pixels =
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
  std::vector<std::uint8_t> canonical_mask;
  if (!lane_mask.empty()) {
    if (mode == Mode::kFast ||
        lane_mask_stride < static_cast<std::size_t>(width) ||
        !byte_plane_fits(lane_mask, lane_mask_stride, width, height)) {
      return {.error = BuildError::kInvalidMask};
    }
    canonical_mask.resize(pixels);
    std::size_t selected = 0;
    for (std::int32_t y = 0; y < height; ++y) {
      const std::uint8_t *source =
          lane_mask.data() + static_cast<std::size_t>(y) * lane_mask_stride;
      std::uint8_t *destination =
          canonical_mask.data() + static_cast<std::size_t>(y) * width;
      for (std::int32_t x = 0; x < width; ++x) {
        destination[x] = source[x] != 0u ? 1u : 0u;
        selected += destination[x];
      }
    }
    if (selected == 0u) {
      return {.error = BuildError::kInvalidMask};
    }
    if (selected == pixels) {
      canonical_mask.clear();
    }
  }

  std::shared_ptr<const XochitlSelector16::SelectorMask> selector_mask;
  if (mode != Mode::kFast) {
    const XochitlSelector16::SourceView source{
        .bytes = surface,
        .stride_bytes = surface_stride,
        .width = kLogicalWidth,
        .height = kLogicalHeight,
        .format = XochitlSelector16::SourceFormat::kRgb565LittleEndian,
        .right_padding =
            XochitlSelector16::RightPadding::kReplicateLogicalEdge};
    const XochitlSelector16::InclusiveRect selector_update{
        update.left, update.top, update.right, update.bottom};
    XochitlSelector16::BuildResult built =
        selector_.build(source, selector_update);
    if (!built) {
      return {.error = BuildError::kSelectorFailed};
    }
    selector_mask = std::move(built.mask);
  }

  std::vector<std::uint8_t> raw(pixels);
  const auto mask_rect = selector_mask == nullptr
                             ? XochitlSelector16::InclusiveRect{}
                             : selector_mask->execution();
  const bool source_is_direct =
      execution.right < kLogicalWidth && execution.bottom < kLogicalHeight;
  const bool selector_is_direct =
      selector_mask == nullptr ||
      (mask_rect.left <= execution.left && mask_rect.top <= execution.top &&
       mask_rect.right >= execution.right &&
       mask_rect.bottom >= execution.bottom);
  if (source_is_direct && selector_is_direct) {
    const std::size_t source_offset =
        static_cast<std::size_t>(execution.top) * surface_stride +
        static_cast<std::size_t>(execution.left) * kRgb565BytesPerPixel;
    const std::uint8_t *selector_bytes = nullptr;
    std::size_t selector_stride = 0u;
    if (selector_mask != nullptr) {
      const std::size_t selector_offset =
          static_cast<std::size_t>(execution.top - mask_rect.top) *
              selector_mask->stride() +
          static_cast<std::size_t>(execution.left - mask_rect.left);
      selector_bytes = selector_mask->bytes().data() + selector_offset;
      selector_stride = selector_mask->stride();
    }
    if (!convert_rgb565_parallel(
            frontend, surface.data() + source_offset, surface_stride,
            execution.left, execution.top, width, height, raw.data(),
            static_cast<std::size_t>(width), selector_bytes, selector_stride)) {
      return {.error = BuildError::kConversionFailed};
    }
  } else {
    const std::int32_t visible_columns =
        std::min(width, kLogicalWidth - execution.left);
    const std::int32_t visible_rows =
        std::min(height, kLogicalHeight - execution.top);
    const bool selector_covers_visible_and_right_guard =
        selector_mask == nullptr ||
        (mask_rect.left <= execution.left && mask_rect.top <= execution.top &&
         mask_rect.right >= execution.right &&
         mask_rect.bottom >= execution.top + visible_rows - 1);
    if (selector_covers_visible_and_right_guard) {
      const std::size_t source_offset =
          static_cast<std::size_t>(execution.top) * surface_stride +
          static_cast<std::size_t>(execution.left) * kRgb565BytesPerPixel;
      const std::uint8_t *main_selector = nullptr;
      std::size_t selector_stride = 0u;
      if (selector_mask != nullptr) {
        main_selector =
            selector_mask->bytes().data() +
            static_cast<std::size_t>(execution.top - mask_rect.top) *
                selector_mask->stride() +
            static_cast<std::size_t>(execution.left - mask_rect.left);
        selector_stride = selector_mask->stride();
      }
      if (!convert_rgb565_parallel(frontend, surface.data() + source_offset,
                                   surface_stride, execution.left,
                                   execution.top, visible_columns, visible_rows,
                                   raw.data(), static_cast<std::size_t>(width),
                                   main_selector, selector_stride)) {
        return {.error = BuildError::kConversionFailed};
      }

      const std::int32_t right_guard = width - visible_columns;
      if (right_guard > 0) {
        std::vector<std::uint8_t> guard_rgb(
            static_cast<std::size_t>(right_guard) * visible_rows *
            kRgb565BytesPerPixel);
        const std::int32_t source_x = execution.left + visible_columns - 1;
        for (std::int32_t row = 0; row < visible_rows; ++row) {
          const std::uint8_t *edge =
              surface.data() +
              static_cast<std::size_t>(execution.top + row) * surface_stride +
              static_cast<std::size_t>(source_x) * kRgb565BytesPerPixel;
          std::uint8_t *guard_row =
              guard_rgb.data() + static_cast<std::size_t>(row) * right_guard *
                                     kRgb565BytesPerPixel;
          for (std::int32_t column = 0; column < right_guard; ++column) {
            guard_row[static_cast<std::size_t>(column) * 2u] = edge[0];
            guard_row[static_cast<std::size_t>(column) * 2u + 1u] = edge[1];
          }
        }
        const std::int32_t guard_x = execution.left + visible_columns;
        const std::uint8_t *guard_selector =
            selector_mask == nullptr
                ? nullptr
                : main_selector + static_cast<std::size_t>(visible_columns);
        if (!frontend->convert_rgb565_le(
                guard_rgb.data(), static_cast<std::size_t>(right_guard) * 2u,
                guard_x, execution.top, right_guard, visible_rows,
                raw.data() + visible_columns, static_cast<std::size_t>(width),
                guard_selector, selector_stride)) {
          return {.error = BuildError::kConversionFailed};
        }
      }

      const std::int32_t bottom_guard = height - visible_rows;
      if (bottom_guard > 0) {
        std::vector<std::uint8_t> guard_rgb(static_cast<std::size_t>(width) *
                                            bottom_guard *
                                            kRgb565BytesPerPixel);
        const std::int32_t source_y = kLogicalHeight - 1;
        for (std::int32_t row = 0; row < bottom_guard; ++row) {
          std::uint8_t *guard_row =
              guard_rgb.data() +
              static_cast<std::size_t>(row) * width * kRgb565BytesPerPixel;
          const std::uint8_t *source_row =
              surface.data() +
              static_cast<std::size_t>(source_y) * surface_stride +
              static_cast<std::size_t>(execution.left) * kRgb565BytesPerPixel;
          std::memcpy(guard_row, source_row,
                      static_cast<std::size_t>(visible_columns) *
                          kRgb565BytesPerPixel);
          const std::uint8_t edge_low =
              guard_row[(static_cast<std::size_t>(visible_columns) - 1u) * 2u];
          const std::uint8_t edge_high =
              guard_row[(static_cast<std::size_t>(visible_columns) - 1u) * 2u +
                        1u];
          for (std::int32_t column = visible_columns; column < width;
               ++column) {
            guard_row[static_cast<std::size_t>(column) * 2u] = edge_low;
            guard_row[static_cast<std::size_t>(column) * 2u + 1u] = edge_high;
          }
        }
        std::vector<std::uint8_t> guard_selector;
        const std::uint8_t *guard_selector_bytes = nullptr;
        if (selector_mask != nullptr) {
          guard_selector.resize(static_cast<std::size_t>(width) * bottom_guard);
          for (std::int32_t row = 0; row < bottom_guard; ++row) {
            const std::int32_t absolute_y = execution.top + visible_rows + row;
            const std::int32_t mask_y =
                std::clamp(absolute_y, mask_rect.top, mask_rect.bottom);
            const std::uint8_t *mask_row =
                selector_mask->bytes().data() +
                static_cast<std::size_t>(mask_y - mask_rect.top) *
                    selector_mask->stride() +
                static_cast<std::size_t>(execution.left - mask_rect.left);
            std::memcpy(guard_selector.data() +
                            static_cast<std::size_t>(row) * width,
                        mask_row, static_cast<std::size_t>(width));
          }
          guard_selector_bytes = guard_selector.data();
        }
        if (!frontend->convert_rgb565_le(
                guard_rgb.data(), static_cast<std::size_t>(width) * 2u,
                execution.left, execution.top + visible_rows, width,
                bottom_guard,
                raw.data() + static_cast<std::size_t>(visible_rows) * width,
                static_cast<std::size_t>(width), guard_selector_bytes,
                selector_mask == nullptr ? 0u
                                         : static_cast<std::size_t>(width))) {
          return {.error = BuildError::kConversionFailed};
        }
      }
    } else {
      // Execution may extend by at most seven columns and one row beyond the
      // authoritative logical surface. Snapshot whole visible row spans with
      // memcpy, then replicate only those tiny guard tails. This is byte-exact
      // to the former per-pixel clamp loop while avoiding millions of repeated
      // multiplies, clamps and bounds-dependent loads on broad updates.
      std::vector<std::uint8_t> compact_rgb(pixels * kRgb565BytesPerPixel);
      std::vector<std::uint8_t> compact_selector;
      if (selector_mask != nullptr) {
        compact_selector.resize(pixels);
      }
      for (std::int32_t row = 0; row < height; ++row) {
        const std::int32_t absolute_y = execution.top + row;
        const std::int32_t source_y = std::min(absolute_y, kLogicalHeight - 1);
        const std::uint8_t *source_row =
            surface.data() +
            static_cast<std::size_t>(source_y) * surface_stride +
            static_cast<std::size_t>(execution.left) * kRgb565BytesPerPixel;
        std::uint8_t *compact_row =
            compact_rgb.data() +
            static_cast<std::size_t>(row) * width * kRgb565BytesPerPixel;
        std::memcpy(compact_row, source_row,
                    static_cast<std::size_t>(visible_columns) *
                        kRgb565BytesPerPixel);
        const std::uint8_t edge_low =
            compact_row[(static_cast<std::size_t>(visible_columns) - 1u) * 2u];
        const std::uint8_t edge_high =
            compact_row[(static_cast<std::size_t>(visible_columns) - 1u) * 2u +
                        1u];
        for (std::int32_t column = visible_columns; column < width; ++column) {
          compact_row[static_cast<std::size_t>(column) * 2u] = edge_low;
          compact_row[static_cast<std::size_t>(column) * 2u + 1u] = edge_high;
        }

        if (selector_mask != nullptr) {
          const std::int32_t mask_y =
              std::clamp(absolute_y, mask_rect.top, mask_rect.bottom);
          const std::int32_t available_columns = std::max(
              1, std::min(width, mask_rect.right - execution.left + 1));
          const std::uint8_t *mask_row =
              selector_mask->bytes().data() +
              static_cast<std::size_t>(mask_y - mask_rect.top) *
                  selector_mask->stride() +
              static_cast<std::size_t>(execution.left - mask_rect.left);
          std::uint8_t *selector_row =
              compact_selector.data() + static_cast<std::size_t>(row) * width;
          std::memcpy(selector_row, mask_row,
                      static_cast<std::size_t>(available_columns));
          std::fill(selector_row + available_columns, selector_row + width,
                    selector_row[available_columns - 1]);
        }
      }

      const std::uint8_t *selector_bytes =
          compact_selector.empty() ? nullptr : compact_selector.data();
      const std::size_t selector_stride =
          compact_selector.empty() ? 0u : static_cast<std::size_t>(width);
      if (!convert_rgb565_parallel(frontend, compact_rgb.data(),
                                   static_cast<std::size_t>(width) * 2u,
                                   execution.left, execution.top, width, height,
                                   raw.data(), static_cast<std::size_t>(width),
                                   selector_bytes, selector_stride)) {
        return {.error = BuildError::kConversionFailed};
      }
    }
  }
  return {.operation =
              std::shared_ptr<const ImmutableOperation>(new ImmutableOperation(
                  configuration_generation_, mode, update, execution, width,
                  height, temperature_bin, temperature_celsius, std::move(raw),
                  std::move(canonical_mask)))};
}

XochitlColorPipeline::PrepareResult
XochitlColorPipeline::prepare(const ImmutableOperation &operation) {
  if (!color_capable_ || waveform_ == nullptr ||
      operation.configuration_generation_ != configuration_generation_) {
    return {.error = XochitlHistoryState::PrepareError::kInvalidHistory};
  }
  if (operation.mode_ == Mode::kFast) {
    if (!operation.lane_mask_.empty()) {
      return {.error = XochitlHistoryState::PrepareError::kInvalidMask};
    }
    return history_.prepare_fast_source(operation.requested_, operation.raw_,
                                        operation.raw_stride(),
                                        operation.temperature_celsius_);
  }
  const int slot = delta_slot(operation.mode_);
  if (slot < 0 || operation.temperature_bin_ < 0 ||
      operation.temperature_bin_ >=
          static_cast<int>(kInstalledTemperatureBins)) {
    return {.error = XochitlHistoryState::PrepareError::kInvalidMode};
  }
  return history_.prepare_legacy(
      operation.mode_, operation.requested_, operation.raw_,
      operation.raw_stride(),
      deltas_[static_cast<std::size_t>(slot)]
             [static_cast<std::size_t>(operation.temperature_bin_)],
      operation.lane_mask_);
}

std::size_t XochitlColorPipeline::owned_bytes() const {
  return std_frontend_.owned_bytes() + best_frontend_.owned_bytes() +
         pen_frontend_.owned_bytes() + fast_frontend_.owned_bytes() +
         history_.owned_plane_storage_bytes() +
         XochitlSelector16::scratch_storage_bytes() + sizeof(deltas_);
}

} // namespace pluto::swtcon
