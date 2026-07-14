#include "xochitl_selector16_reference.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace pluto::swtcon::xochitl_selector16_reference {
namespace {

constexpr std::uint32_t kOpaqueBlack = 0xff000000u;
constexpr std::uint32_t kOpaqueWhite = 0xffffffffu;

bool valid_update(const InclusiveRect &rect) {
  return rect.left >= 0 && rect.top >= 0 && rect.right >= rect.left &&
         rect.bottom >= rect.top && rect.right < kPanelWidth &&
         rect.bottom < kPanelHeight;
}

bool valid_stripe(const Stripe &stripe) {
  if (stripe.empty()) {
    return true;
  }
  return stripe.left >= 0 && stripe.top >= 0 && stripe.right < kPanelWidth &&
         stripe.bottom < kPanelHeight && (stripe.left & 15) == 0 &&
         (stripe.top & 15) == 0 && ((stripe.right + 1) & 15) == 0 &&
         ((stripe.bottom + 1) & 15) == 0;
}

bool argb_large_enough(std::span<const std::uint32_t> argb) {
  return argb.size() >= static_cast<std::size_t>(kPanelWidth) * kPanelHeight;
}

std::size_t panel_index(std::int32_t x, std::int32_t y) {
  return static_cast<std::size_t>(y) * kPanelWidth +
         static_cast<std::size_t>(x);
}

std::size_t coarse_index(std::int32_t x, std::int32_t y) {
  return static_cast<std::size_t>(y) * kCoarseWidth +
         static_cast<std::size_t>(x);
}

bool special_luma(std::uint32_t pixel) {
  return pixel == kOpaqueBlack || pixel == kOpaqueWhite;
}

bool rgb_is_gray(std::uint32_t pixel) {
  const std::uint8_t blue = static_cast<std::uint8_t>(pixel);
  const std::uint8_t green = static_cast<std::uint8_t>(pixel >> 8);
  const std::uint8_t red = static_cast<std::uint8_t>(pixel >> 16);
  return blue == green && blue == red;
}

Stripe worker_stripe(InclusiveRect update, std::uint32_t worker_index,
                     std::uint32_t divisor) {
  const std::int32_t x_begin = update.left & ~15;
  const std::int32_t x_end = (update.right + 16) & ~15;
  const std::int32_t all_y_begin = update.top & ~15;
  const std::int32_t all_y_end = (update.bottom + 16) & ~15;
  const std::uint32_t height =
      static_cast<std::uint32_t>(all_y_end - all_y_begin);
  const std::uint32_t begin_offset =
      static_cast<std::uint32_t>(worker_index * height / divisor);
  const std::uint32_t end_offset =
      static_cast<std::uint32_t>((worker_index + 1u) * height / divisor);
  const std::int32_t y_begin =
      (all_y_begin + static_cast<std::int32_t>(begin_offset)) & ~15;
  const std::int32_t y_end =
      (all_y_begin + static_cast<std::int32_t>(end_offset)) & ~15;
  return {
      .left = x_begin, .top = y_begin, .right = x_end - 1, .bottom = y_end - 1};
}

StageError validate_stage(std::span<const std::uint32_t> argb,
                          const Stripe &stripe, const Scratch *scratch) {
  if (scratch == nullptr || !valid_stripe(stripe)) {
    return StageError::kInvalidGeometry;
  }
  if (!argb_large_enough(argb)) {
    return StageError::kArgbTooSmall;
  }
  return StageError::kNone;
}

} // namespace

Scratch::Scratch()
    : coarse(static_cast<std::size_t>(kCoarseWidth) * kCoarseHeight, 0),
      selector(static_cast<std::size_t>(kPanelWidth) * kPanelHeight, 0) {}

std::uint8_t &Scratch::coarse_at(std::int32_t x, std::int32_t y) {
  return coarse[coarse_index(x, y)];
}

const std::uint8_t &Scratch::coarse_at(std::int32_t x, std::int32_t y) const {
  return coarse[coarse_index(x, y)];
}

std::uint8_t &Scratch::selector_at(std::int32_t x, std::int32_t y) {
  return selector[panel_index(x, y)];
}

const std::uint8_t &Scratch::selector_at(std::int32_t x, std::int32_t y) const {
  return selector[panel_index(x, y)];
}

WorkerPlan make_worker_plan(InclusiveRect update) {
  WorkerPlan plan;
  if (!valid_update(update)) {
    return plan;
  }
  plan.divisor = update.bottom - update.top > 28 ? 3u : 1u;
  plan.stripes.reserve(plan.divisor);
  for (std::uint32_t index = 0; index < plan.divisor; ++index) {
    plan.stripes.push_back(worker_stripe(update, index, plan.divisor));
  }
  return plan;
}

StageError run_coarse_stage(std::span<const std::uint32_t> argb,
                            const Stripe &stripe, Scratch *scratch) {
  const StageError error = validate_stage(argb, stripe, scratch);
  if (error != StageError::kNone || stripe.empty()) {
    return error;
  }

  const std::int32_t coarse_left = stripe.left >> 2;
  const std::int32_t coarse_top = stripe.top >> 2;
  const std::int32_t coarse_right = (stripe.right + 1) >> 2;
  const std::int32_t coarse_bottom = (stripe.bottom + 1) >> 2;
  for (std::int32_t y = coarse_top; y < coarse_bottom; ++y) {
    for (std::int32_t x = coarse_left; x < coarse_right; ++x) {
      scratch->coarse_at(x, y) = 0;
    }
  }

  for (std::int32_t y = stripe.top; y <= stripe.bottom; ++y) {
    for (std::int32_t x = stripe.left; x <= stripe.right; ++x) {
      const std::uint32_t pixel = argb[panel_index(x, y)];
      if (!rgb_is_gray(pixel)) {
        continue;
      }
      const std::uint8_t value = static_cast<std::uint8_t>(pixel);
      std::uint8_t flags = 0;
      if (value >= 240u) {
        flags |= 1u;
      }
      if (value <= 15u) {
        flags |= 2u;
      }
      scratch->coarse_at(x >> 2, y >> 2) |= flags;
    }
  }
  return StageError::kNone;
}

StageError run_classify_stage(std::span<const std::uint32_t> argb,
                              const Stripe &stripe, Scratch *scratch) {
  const StageError error = validate_stage(argb, stripe, scratch);
  if (error != StageError::kNone || stripe.empty()) {
    return error;
  }

  const std::int32_t left = std::max(stripe.left, 4);
  const std::int32_t top = std::max(stripe.top, 4);
  const std::int32_t right = std::min(stripe.right, kPanelWidth - 5);
  const std::int32_t bottom = std::min(stripe.bottom, kPanelHeight - 5);
  if (left > right || top > bottom) {
    return StageError::kNone;
  }

  for (std::int32_t y = top; y <= bottom; ++y) {
    for (std::int32_t x = left; x <= right; ++x) {
      const std::uint32_t pixel = argb[panel_index(x, y)];
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
            for (std::int32_t dx = -1; dx <= 1; ++dx) {
              flags |= scratch->coarse_at(coarse_x + dx, coarse_y + dy);
            }
          }
          pixel_class = flags == 3u ? 0u : 3u;
        }
      }
      scratch->selector_at(x, y) = pixel_class;
    }
  }
  return StageError::kNone;
}

StageError run_resolve_stage(std::span<const std::uint32_t> argb,
                             const Stripe &stripe, Scratch *scratch) {
  const StageError error = validate_stage(argb, stripe, scratch);
  if (error != StageError::kNone || stripe.empty()) {
    return error;
  }

  for (std::int32_t block_y = stripe.top; block_y <= stripe.bottom;
       block_y += 16) {
    for (std::int32_t block_x = stripe.left; block_x <= stripe.right;
         block_x += 16) {
      std::uint32_t class_three_count = 0;
      bool has_class_four = false;
      for (std::int32_t y = block_y; y < block_y + 16; ++y) {
        for (std::int32_t x = block_x; x < block_x + 16; ++x) {
          const std::uint8_t pixel_class = scratch->selector_at(x, y);
          class_three_count += pixel_class == 3u ? 1u : 0u;
          has_class_four = has_class_four || pixel_class == 4u;
        }
      }
      const std::uint8_t block_default =
          !has_class_four && class_three_count <= 15u ? 0xffu : 0x00u;

      for (std::int32_t y = block_y; y < block_y + 16; ++y) {
        for (std::int32_t x = block_x; x < block_x + 16; ++x) {
          std::uint8_t resolved = block_default;
          if (special_luma(argb[panel_index(x, y)])) {
            if (x == 0 || special_luma(argb[panel_index(x - 1, y)])) {
              resolved = 0xffu;
            }
          }
          scratch->selector_at(x, y) = resolved;
        }
      }
    }
  }
  return StageError::kNone;
}

StageError run_worker(std::span<const std::uint32_t> argb, InclusiveRect update,
                      std::uint32_t worker_index, std::uint32_t divisor,
                      Scratch *scratch) {
  if (!valid_update(update)) {
    return StageError::kInvalidGeometry;
  }
  if (divisor == 0u || worker_index >= divisor) {
    return StageError::kInvalidWorker;
  }
  const Stripe stripe = worker_stripe(update, worker_index, divisor);
  StageError error = run_coarse_stage(argb, stripe, scratch);
  if (error != StageError::kNone) {
    return error;
  }
  error = run_classify_stage(argb, stripe, scratch);
  if (error != StageError::kNone) {
    return error;
  }
  return run_resolve_stage(argb, stripe, scratch);
}

} // namespace pluto::swtcon::xochitl_selector16_reference
