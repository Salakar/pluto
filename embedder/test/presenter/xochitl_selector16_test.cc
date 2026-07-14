#include "presenter/swtcon/xochitl_selector16.h"

#include "presenter/swtcon/xochitl_parallel.h"

#include "xochitl_selector16_reference.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <span>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#include <gtest/gtest.h>

namespace pluto::swtcon {
namespace {

namespace reference = xochitl_selector16_reference;

constexpr std::uint32_t kBlack = 0xff000000u;
constexpr std::uint32_t kWhite = 0xffffffffu;
constexpr std::uint32_t kMidGray = 0xff808080u;

TEST(XochitlParallel, CpuCapAndMeasuredThresholdSelectOneTwoOrThreeStripes) {
  using xochitl_parallel::compute_stripes_for_logical_cpus;
  using xochitl_parallel::compute_stripes_for_work_items;
  constexpr std::size_t threshold =
      xochitl_parallel::kParallelWorkItemThreshold;

  EXPECT_EQ(compute_stripes_for_logical_cpus(0), 1u);
  EXPECT_EQ(compute_stripes_for_logical_cpus(1), 1u);
  EXPECT_EQ(compute_stripes_for_logical_cpus(2), 2u);
  EXPECT_EQ(compute_stripes_for_logical_cpus(3), 3u);
  EXPECT_EQ(compute_stripes_for_logical_cpus(64), 3u);
  EXPECT_EQ(compute_stripes_for_work_items(threshold - 1u, 64), 1u);
  EXPECT_EQ(compute_stripes_for_work_items(threshold, 1), 1u);
  EXPECT_EQ(compute_stripes_for_work_items(threshold, 2), 2u);
  EXPECT_EQ(compute_stripes_for_work_items(threshold, 3), 3u);
}

TEST(XochitlParallel, PartialThreadCreationFailureCompletesEveryStripeOnce) {
  std::array<std::atomic<unsigned int>, 3> runs{};
  std::size_t launches = 0;
  const auto launcher = [&](std::thread *worker, auto &&work) {
    if (launches++ == 1u) {
      throw std::system_error(
          std::make_error_code(std::errc::resource_unavailable_try_again));
    }
    *worker = std::thread(std::forward<decltype(work)>(work));
  };

  xochitl_parallel::run_compute_stripes(
      3u, [&](std::size_t stripe) { ++runs[stripe]; }, launcher);
  for (const auto &run_count : runs) {
    EXPECT_EQ(run_count.load(), 1u);
  }
}

TEST(XochitlParallel, WorkerPolicyFailureFallsBackToCallerExactlyOnce) {
  std::array<std::atomic<unsigned int>, 3> runs{};
  const std::thread::id caller = std::this_thread::get_id();
  std::atomic<unsigned int> caller_runs = 0;
  const auto work = [&](std::size_t stripe) {
    ++runs[stripe];
    if (std::this_thread::get_id() == caller) {
      ++caller_runs;
    }
  };

  xochitl_parallel::run_compute_stripes(
      3u, work, xochitl_parallel::ThreadLauncher{},
      [](std::thread::native_handle_type, std::size_t) { return false; });
  for (const auto &run_count : runs) {
    EXPECT_EQ(run_count.load(), 1u);
  }
  EXPECT_EQ(caller_runs.load(), 3u);
}

TEST(XochitlParallel, ParentPolicyConfigurationPrecedesWorkerPixelWork) {
  const std::thread::id caller = std::this_thread::get_id();
  std::array<std::atomic<bool>, 2> configured{};
  std::array<std::atomic<bool>, 2> worker_started{};
  std::atomic<unsigned int> bootstraps = 0;
  std::atomic<unsigned int> configuration_observed_early_work = 0;
  std::atomic<unsigned int> worker_runs_before_policy = 0;
  std::atomic<unsigned int> configuration_off_caller = 0;
  const auto configure = [&](std::thread::native_handle_type,
                             std::size_t stripe) {
    if (std::this_thread::get_id() != caller) {
      ++configuration_off_caller;
    }
    // Yield long enough that an ungated normal worker would enter pixel work.
    // The held start mutex makes the assertion deterministic.
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    if (worker_started[stripe]) {
      ++configuration_observed_early_work;
    }
    configured[stripe] = true;
    ++bootstraps;
    return true;
  };
  const auto work = [&](std::size_t stripe) {
    if (std::this_thread::get_id() != caller) {
      worker_started[stripe] = true;
      if (!configured[stripe]) {
        ++worker_runs_before_policy;
      }
    }
  };

  xochitl_parallel::run_compute_stripes(
      3u, work, xochitl_parallel::ThreadLauncher{}, configure);
  EXPECT_EQ(bootstraps.load(), 2u);
  EXPECT_EQ(configuration_off_caller.load(), 0u);
  EXPECT_EQ(configuration_observed_early_work.load(), 0u);
  EXPECT_EQ(worker_runs_before_policy.load(), 0u);
}

struct ArgbSurface {
  explicit ArgbSurface(std::uint32_t fill = kMidGray, std::size_t row_guard = 0,
                       std::size_t leading_guard = 0)
      : stride(static_cast<std::size_t>(XochitlSelector16::kLogicalWidth) * 4u +
               row_guard),
        leading(leading_guard),
        storage(leading +
                    stride * static_cast<std::size_t>(
                                 XochitlSelector16::kPanelHeight - 1) +
                    static_cast<std::size_t>(XochitlSelector16::kLogicalWidth) *
                        4u,
                0xa5u) {
    for (int y = 0; y < XochitlSelector16::kPanelHeight; ++y) {
      for (int x = 0; x < XochitlSelector16::kLogicalWidth; ++x) {
        set(x, y, fill);
      }
    }
  }

  void set(int x, int y, std::uint32_t pixel) {
    std::uint8_t *destination = storage.data() + leading +
                                static_cast<std::size_t>(y) * stride +
                                static_cast<std::size_t>(x) * 4u;
    destination[0] = static_cast<std::uint8_t>(pixel);
    destination[1] = static_cast<std::uint8_t>(pixel >> 8);
    destination[2] = static_cast<std::uint8_t>(pixel >> 16);
    destination[3] = static_cast<std::uint8_t>(pixel >> 24);
  }

  std::uint32_t get(int x, int y) const {
    const std::uint8_t *source = storage.data() + leading +
                                 static_cast<std::size_t>(y) * stride +
                                 static_cast<std::size_t>(x) * 4u;
    return static_cast<std::uint32_t>(source[0]) |
           (static_cast<std::uint32_t>(source[1]) << 8) |
           (static_cast<std::uint32_t>(source[2]) << 16) |
           (static_cast<std::uint32_t>(source[3]) << 24);
  }

  XochitlSelector16::SourceView
  view(XochitlSelector16::RightPadding padding =
           XochitlSelector16::RightPadding::kReplicateLogicalEdge) const {
    const std::size_t size = storage.size() - leading;
    return {.bytes =
                std::span<const std::uint8_t>(storage.data() + leading, size),
            .stride_bytes = stride,
            .width = XochitlSelector16::kLogicalWidth,
            .height = XochitlSelector16::kPanelHeight,
            .format = XochitlSelector16::SourceFormat::kArgb8888LittleEndian,
            .right_padding = padding};
  }

  std::size_t stride = 0;
  std::size_t leading = 0;
  std::vector<std::uint8_t> storage;
};

struct Rgb565Surface {
  explicit Rgb565Surface(std::uint16_t fill = 0xffffu)
      : stride(static_cast<std::size_t>(XochitlSelector16::kLogicalWidth) * 2u),
        bytes(stride * XochitlSelector16::kPanelHeight) {
    for (int y = 0; y < XochitlSelector16::kPanelHeight; ++y) {
      for (int x = 0; x < XochitlSelector16::kLogicalWidth; ++x) {
        set(x, y, fill);
      }
    }
  }

  void set(int x, int y, std::uint16_t pixel) {
    std::uint8_t *destination = bytes.data() +
                                static_cast<std::size_t>(y) * stride +
                                static_cast<std::size_t>(x) * 2u;
    destination[0] = static_cast<std::uint8_t>(pixel);
    destination[1] = static_cast<std::uint8_t>(pixel >> 8);
  }

  XochitlSelector16::SourceView
  view(XochitlSelector16::RightPadding padding =
           XochitlSelector16::RightPadding::kReplicateLogicalEdge) const {
    return {.bytes = bytes,
            .stride_bytes = stride,
            .width = XochitlSelector16::kLogicalWidth,
            .height = XochitlSelector16::kPanelHeight,
            .format = XochitlSelector16::SourceFormat::kRgb565LittleEndian,
            .right_padding = padding};
  }

  std::size_t stride = 0;
  std::vector<std::uint8_t> bytes;
};

std::uint32_t expand_rgb565(std::uint16_t packed) {
  const std::uint8_t red5 = static_cast<std::uint8_t>(packed >> 11);
  const std::uint8_t green6 = static_cast<std::uint8_t>((packed >> 5) & 63u);
  const std::uint8_t blue5 = static_cast<std::uint8_t>(packed & 31u);
  return kBlack |
         (static_cast<std::uint32_t>((red5 << 3) | (red5 >> 2)) << 16) |
         (static_cast<std::uint32_t>((green6 << 2) | (green6 >> 4)) << 8) |
         static_cast<std::uint32_t>((blue5 << 3) | (blue5 >> 2));
}

std::uint64_t fnv1a64(std::span<const std::uint8_t> bytes) {
  std::uint64_t hash = 1469598103934665603ull;
  for (const std::uint8_t byte : bytes) {
    hash ^= byte;
    hash *= 1099511628211ull;
  }
  return hash;
}

std::vector<std::uint32_t>
make_reference_frame(const ArgbSurface &surface,
                     XochitlSelector16::RightPadding padding) {
  std::vector<std::uint32_t> frame(
      static_cast<std::size_t>(reference::kPanelWidth) *
      reference::kPanelHeight);
  for (int y = 0; y < reference::kPanelHeight; ++y) {
    std::uint32_t *row =
        frame.data() + static_cast<std::size_t>(y) * reference::kPanelWidth;
    for (int x = 0; x < XochitlSelector16::kLogicalWidth; ++x) {
      row[x] = surface.get(x, y);
    }
    const std::uint32_t pad = padding == XochitlSelector16::RightPadding::kWhite
                                  ? kWhite
                                  : row[XochitlSelector16::kLogicalWidth - 1];
    std::fill(row + XochitlSelector16::kLogicalWidth,
              row + reference::kPanelWidth, pad);
  }
  return frame;
}

reference::InclusiveRect reference_rect(XochitlSelector16::InclusiveRect rect) {
  return {.left = rect.left,
          .top = rect.top,
          .right = rect.right,
          .bottom = rect.bottom};
}

void require_reference_ok(reference::StageError error) {
  ASSERT_EQ(static_cast<int>(error),
            static_cast<int>(reference::StageError::kNone));
}

void run_reference_staged(std::span<const std::uint32_t> argb,
                          XochitlSelector16::InclusiveRect update,
                          reference::Scratch *scratch) {
  const reference::WorkerPlan plan =
      reference::make_worker_plan(reference_rect(update));
  ASSERT_TRUE(scratch != nullptr);
  ASSERT_TRUE(!plan.stripes.empty());
  if (plan.divisor == 1u) {
    require_reference_ok(
        reference::run_worker(argb, reference_rect(update), 0, 1, scratch));
    return;
  }
  for (const reference::Stripe &stripe : plan.stripes) {
    require_reference_ok(reference::run_coarse_stage(argb, stripe, scratch));
  }
  for (const reference::Stripe &stripe : plan.stripes) {
    require_reference_ok(reference::run_classify_stage(argb, stripe, scratch));
  }
  for (const reference::Stripe &stripe : plan.stripes) {
    require_reference_ok(reference::run_resolve_stage(argb, stripe, scratch));
  }
}

std::vector<std::uint8_t>
extract_reference(const reference::Scratch &scratch,
                  const XochitlSelector16::SelectorMask &mask) {
  const XochitlSelector16::InclusiveRect execution = mask.execution();
  std::vector<std::uint8_t> output(static_cast<std::size_t>(mask.width()) *
                                   mask.height());
  for (int y = execution.top; y <= execution.bottom; ++y) {
    for (int x = execution.left; x <= execution.right; ++x) {
      output[static_cast<std::size_t>(y - execution.top) * mask.stride() +
             static_cast<std::size_t>(x - execution.left)] =
          scratch.selector_at(x, y);
    }
  }
  return output;
}

void expect_bytes_equal(std::span<const std::uint8_t> actual,
                        std::span<const std::uint8_t> expected) {
  ASSERT_EQ(actual.size(), expected.size());
  const auto mismatch = std::mismatch(actual.begin(), actual.end(),
                                      expected.begin(), expected.end());
  if (mismatch.first != actual.end()) {
    const std::size_t offset =
        static_cast<std::size_t>(mismatch.first - actual.begin());
    EXPECT_EQ(static_cast<unsigned>(*mismatch.first),
              static_cast<unsigned>(*mismatch.second))
        << "first mismatch at byte " << offset;
  }
}

std::uint8_t mask_at(const XochitlSelector16::SelectorMask &mask, int x,
                     int y) {
  const XochitlSelector16::InclusiveRect execution = mask.execution();
  return mask
      .bytes()[static_cast<std::size_t>(y - execution.top) * mask.stride() +
               static_cast<std::size_t>(x - execution.left)];
}

void expect_rect_equal(XochitlSelector16::InclusiveRect actual,
                       XochitlSelector16::InclusiveRect expected) {
  EXPECT_EQ(actual.left, expected.left);
  EXPECT_EQ(actual.top, expected.top);
  EXPECT_EQ(actual.right, expected.right);
  EXPECT_EQ(actual.bottom, expected.bottom);
}

TEST(XochitlSelector16, SmallArgbRouteIsExactToIndependentStockWorker) {
  // Odd leading address and row stride prove alignment-safe ARGB loads.
  ArgbSurface surface(kMidGray, 3, 1);
  const XochitlSelector16::InclusiveRect update{21, 37, 83, 59};
  for (int y = 31; y < 64; ++y) {
    for (int x = 15; x < 96; ++x) {
      const int selector = (x * 5 + y * 7) % 9;
      const std::uint32_t pixel =
          selector == 0   ? kBlack
          : selector == 1 ? kWhite
          : selector == 2 ? 0x00ffffffu
          : selector == 3 ? 0xff0f0f0fu
          : selector == 4 ? 0xfff0f0f0u
          : selector == 5 ? 0xff103070u
                          : static_cast<std::uint32_t>(
                                0xff000000u | ((x + y) & 0xff) * 0x010101u);
      surface.set(x, y, pixel);
    }
  }

  XochitlSelector16 selector;
  const XochitlSelector16::BuildResult result =
      selector.build(surface.view(), update);
  ASSERT_TRUE(result);
  expect_rect_equal(result.mask->execution(), {16, 32, 95, 63});

  const std::vector<std::uint32_t> frame = make_reference_frame(
      surface, XochitlSelector16::RightPadding::kReplicateLogicalEdge);
  reference::Scratch scratch;
  run_reference_staged(frame, update, &scratch);
  const std::vector<std::uint8_t> expected =
      extract_reference(scratch, *result.mask);
  expect_bytes_equal(result.mask->bytes(), expected);
}

TEST(XochitlSelector16, Rgb565ExpansionMatchesEquivalentArgbExactly) {
  Rgb565Surface rgb;
  ArgbSurface argb(kWhite);
  const XochitlSelector16::InclusiveRect update{400, 700, 479, 723};
  for (int y = 688; y < 736; ++y) {
    for (int x = 384; x < 496; ++x) {
      const std::uint16_t packed = static_cast<std::uint16_t>(
          (x * 6151u + y * 7919u + (x ^ y) * 31u) & 0xffffu);
      rgb.set(x, y, packed);
      argb.set(x, y, expand_rgb565(packed));
    }
  }

  XochitlSelector16 rgb_selector;
  XochitlSelector16 argb_selector;
  const auto rgb_result = rgb_selector.build(rgb.view(), update);
  const auto argb_result = argb_selector.build(argb.view(), update);
  ASSERT_TRUE(rgb_result);
  ASSERT_TRUE(argb_result);
  expect_rect_equal(rgb_result.mask->execution(),
                    argb_result.mask->execution());
  expect_bytes_equal(rgb_result.mask->bytes(), argb_result.mask->bytes());
}

TEST(XochitlSelector16,
     EveryRgb565ValueMatchesArgbAcrossOneTwoAndThreeCpuPlans) {
  Rgb565Surface rgb;
  ArgbSurface argb(kWhite);
  constexpr int kWidth = 256;
  constexpr int kHeight = 256;
  const XochitlSelector16::InclusiveRect update{0, 0, kWidth - 1,
                                                 kHeight - 1};
  for (std::uint32_t index = 0; index < 65536u; ++index) {
    // Odd multiplication is a permutation of all RGB565 values. It makes
    // neighbouring pixels pseudo-random while preserving exhaustive coverage.
    const std::uint16_t packed =
        static_cast<std::uint16_t>(index * 40503u + 17u);
    const int x = static_cast<int>(index & 255u);
    const int y = static_cast<int>(index >> 8u);
    rgb.set(x, y, packed);
    argb.set(x, y, expand_rgb565(packed));
  }

  XochitlSelector16 argb_reference(1);
  const auto expected = argb_reference.build(argb.view(), update);
  ASSERT_TRUE(expected);
  for (const unsigned int cpus : {1u, 2u, 3u}) {
    XochitlSelector16 selector(cpus);
    const auto actual = selector.build(rgb.view(), update);
    ASSERT_TRUE(actual);
    expect_bytes_equal(actual.mask->bytes(), expected.mask->bytes());
    EXPECT_EQ(fnv1a64(actual.mask->bytes()), 18334859166678057859ull);
  }
}

TEST(XochitlSelector16, Rgb565RightPaddingMatchesArgbForBothContracts) {
  Rgb565Surface rgb;
  ArgbSurface argb(kWhite);
  const XochitlSelector16::InclusiveRect corner{938, 1664, 953, 1695};
  for (int y = corner.top; y <= corner.bottom; ++y) {
    for (int x = corner.left; x <= corner.right; ++x) {
      const std::uint16_t packed = static_cast<std::uint16_t>(
          (static_cast<std::uint32_t>(x) * 40503u +
           static_cast<std::uint32_t>(y) * 7919u) &
          0xffffu);
      rgb.set(x, y, packed);
      argb.set(x, y, expand_rgb565(packed));
    }
  }
  for (const auto padding :
       {XochitlSelector16::RightPadding::kReplicateLogicalEdge,
        XochitlSelector16::RightPadding::kWhite}) {
    XochitlSelector16 rgb_selector(2);
    XochitlSelector16 argb_selector(2);
    const auto actual = rgb_selector.build(rgb.view(padding), corner);
    const auto expected = argb_selector.build(argb.view(padding), corner);
    ASSERT_TRUE(actual);
    ASSERT_TRUE(expected);
    expect_bytes_equal(actual.mask->bytes(), expected.mask->bytes());
  }
}

TEST(XochitlSelector16,
     LargeRouteUsesDeterministicGlobalStagesAndMatchesStagedReference) {
  ArgbSurface surface;
  const XochitlSelector16::InclusiveRect update{33, 95, 174, 224};
  for (int y = 80; y < 240; ++y) {
    for (int x = 16; x < 192; ++x) {
      const int value = (x * 13 + y * 17) & 255;
      std::uint32_t pixel =
          0xff000000u | static_cast<std::uint32_t>(value * 0x010101u);
      if ((x + 3 * y) % 37 == 0) {
        pixel = 0xff2040a0u;
      } else if ((x + y) % 29 == 0) {
        pixel = kBlack;
      } else if ((x - y) % 31 == 0) {
        pixel = kWhite;
      }
      surface.set(x, y, pixel);
    }
  }

  const std::vector<std::uint32_t> frame = make_reference_frame(
      surface, XochitlSelector16::RightPadding::kReplicateLogicalEdge);
  reference::Scratch scratch;
  run_reference_staged(frame, update, &scratch);

  XochitlSelector16 selector;
  const auto first = selector.build(surface.view(), update);
  ASSERT_TRUE(first);
  const std::vector<std::uint8_t> expected =
      extract_reference(scratch, *first.mask);
  expect_bytes_equal(first.mask->bytes(), expected);

  run_reference_staged(frame, update, &scratch);
  const auto second = selector.build(surface.view(), update);
  ASSERT_TRUE(second);
  expect_bytes_equal(second.mask->bytes(), expected);
  expect_bytes_equal(second.mask->bytes(),
                     extract_reference(scratch, *second.mask));
}

TEST(XochitlSelector16, OneTwoAndThreeCpuPlansProduceIdenticalBroadMask) {
  ArgbSurface surface;
  const XochitlSelector16::InclusiveRect update{16, 32, 527, 543};
  for (int y = update.top; y <= update.bottom; ++y) {
    for (int x = update.left; x <= update.right; ++x) {
      const std::uint32_t mix = static_cast<std::uint32_t>(
          x * 2246822519u + y * 3266489917u + (x ^ y) * 668265263u);
      std::uint32_t pixel =
          0xff000000u | ((mix >> 8u) & 0x00ffffffu);
      if (mix % 31u == 0u) {
        pixel = kBlack;
      } else if (mix % 37u == 0u) {
        pixel = kWhite;
      }
      surface.set(x, y, pixel);
    }
  }

  XochitlSelector16 one_cpu(1);
  XochitlSelector16 two_cpu(2);
  XochitlSelector16 three_cpu(3);
  const auto one = one_cpu.build(surface.view(), update);
  const auto two = two_cpu.build(surface.view(), update);
  const auto three = three_cpu.build(surface.view(), update);
  ASSERT_TRUE(one);
  ASSERT_TRUE(two);
  ASSERT_TRUE(three);
  expect_bytes_equal(two.mask->bytes(), one.mask->bytes());
  expect_bytes_equal(three.mask->bytes(), one.mask->bytes());
}

TEST(XochitlSelector16, OutsideOperationCoarseHaloPersistsUntilReset) {
  ArgbSurface surface;
  const XochitlSelector16::InclusiveRect seed{0, 16, 15, 31};
  const XochitlSelector16::InclusiveRect classify{0, 0, 15, 15};
  for (int y = 16; y < 20; ++y) {
    for (int x = 0; x < 16; ++x) {
      surface.set(x, y, kWhite);
    }
  }

  XochitlSelector16 retained;
  ASSERT_TRUE(retained.build(surface.view(), seed));
  for (int y = 0; y < 12; ++y) {
    for (int x = 0; x < 16; ++x) {
      surface.set(x, y, kBlack);
    }
  }
  const auto retained_result = retained.build(surface.view(), classify);
  ASSERT_TRUE(retained_result);

  XochitlSelector16 fresh;
  const auto fresh_result = fresh.build(surface.view(), classify);
  ASSERT_TRUE(fresh_result);
  EXPECT_EQ(static_cast<unsigned>(mask_at(*retained_result.mask, 8, 12)),
            0xffu);
  EXPECT_EQ(static_cast<unsigned>(mask_at(*fresh_result.mask, 8, 12)), 0u);

  retained.reset();
  const auto reset_result = retained.build(surface.view(), classify);
  ASSERT_TRUE(reset_result);
  expect_bytes_equal(reset_result.mask->bytes(), fresh_result.mask->bytes());
}

TEST(XochitlSelector16,
     RightAndBottomGuardUsesExplicitWhiteOrReplicatedPaddingSafely) {
  ArgbSurface surface;
  const XochitlSelector16::InclusiveRect corner{953, 1695, 953, 1695};
  surface.set(953, 1695, 0xff802010u);

  XochitlSelector16 replicate_selector;
  XochitlSelector16 white_selector;
  const auto replicated = replicate_selector.build(
      surface.view(XochitlSelector16::RightPadding::kReplicateLogicalEdge),
      corner);
  const auto white = white_selector.build(
      surface.view(XochitlSelector16::RightPadding::kWhite), corner);
  ASSERT_TRUE(replicated);
  ASSERT_TRUE(white);
  expect_rect_equal(replicated.mask->execution(), {944, 1680, 959, 1695});
  EXPECT_EQ(static_cast<unsigned>(mask_at(*replicated.mask, 959, 1695)), 0u);
  EXPECT_EQ(static_cast<unsigned>(mask_at(*white.mask, 959, 1695)), 0xffu);

  for (const auto padding :
       {XochitlSelector16::RightPadding::kReplicateLogicalEdge,
        XochitlSelector16::RightPadding::kWhite}) {
    const std::vector<std::uint32_t> frame =
        make_reference_frame(surface, padding);
    reference::Scratch scratch;
    run_reference_staged(frame, corner, &scratch);
    XochitlSelector16 selector;
    const auto production = selector.build(surface.view(padding), corner);
    ASSERT_TRUE(production);
    expect_bytes_equal(production.mask->bytes(),
                       extract_reference(scratch, *production.mask));
  }
}

TEST(XochitlSelector16, ThirtyRowEmptyFirstStripeMatchesStagedReference) {
  ArgbSurface surface;
  for (int y = 0; y < 32; ++y) {
    for (int x = 0; x < 16; ++x) {
      surface.set(x, y, ((x + y) & 1) == 0 ? 0xff303030u : 0xffd0d0d0u);
    }
  }
  const XochitlSelector16::InclusiveRect update{0, 0, 15, 29};
  XochitlSelector16 selector;
  const auto result = selector.build(surface.view(), update);
  ASSERT_TRUE(result);

  const std::vector<std::uint32_t> frame = make_reference_frame(
      surface, XochitlSelector16::RightPadding::kReplicateLogicalEdge);
  reference::Scratch scratch;
  run_reference_staged(frame, update, &scratch);
  expect_bytes_equal(result.mask->bytes(),
                     extract_reference(scratch, *result.mask));
}

TEST(XochitlSelector16, ReturnedMaskRemainsImmutableAcrossLaterBuilds) {
  ArgbSurface surface;
  const XochitlSelector16::InclusiveRect update{128, 256, 159, 287};
  XochitlSelector16 selector;
  const auto first = selector.build(surface.view(), update);
  ASSERT_TRUE(first);
  const std::vector<std::uint8_t> snapshot(first.mask->bytes().begin(),
                                           first.mask->bytes().end());

  for (int y = 256; y < 288; ++y) {
    for (int x = 128; x < 160; ++x) {
      surface.set(x, y, kWhite);
    }
  }
  const auto second = selector.build(surface.view(), update);
  ASSERT_TRUE(second);
  expect_bytes_equal(first.mask->bytes(), snapshot);
  EXPECT_TRUE(!std::equal(second.mask->bytes().begin(),
                          second.mask->bytes().end(), snapshot.begin()));
}

TEST(XochitlSelector16, ConcurrentCallersAreSerializedAndDeterministic) {
  ArgbSurface surface;
  const XochitlSelector16::InclusiveRect update{200, 400, 327, 527};
  for (int y = 384; y < 544; ++y) {
    for (int x = 192; x < 336; ++x) {
      surface.set(x, y, ((x * 11 + y * 3) & 16) != 0 ? kBlack : 0xff507090u);
    }
  }

  XochitlSelector16 selector;
  std::vector<XochitlSelector16::BuildResult> results(6);
  std::vector<std::thread> callers;
  for (std::size_t index = 0; index < results.size(); ++index) {
    callers.emplace_back([&, index] {
      results[index] = selector.build(surface.view(), update);
    });
  }
  for (std::thread &caller : callers) {
    caller.join();
  }
  ASSERT_TRUE(results[0]);
  for (std::size_t index = 1; index < results.size(); ++index) {
    ASSERT_TRUE(results[index]);
    expect_bytes_equal(results[index].mask->bytes(), results[0].mask->bytes());
  }
}

TEST(XochitlSelector16, InvalidViewsAndGeometryFailWithoutPublishingMask) {
  ArgbSurface surface;
  XochitlSelector16 selector;
  const XochitlSelector16::InclusiveRect valid{0, 0, 0, 0};

  auto bad = selector.build(surface.view(), {-1, 0, 0, 0});
  EXPECT_EQ(static_cast<int>(bad.error),
            static_cast<int>(XochitlSelector16::BuildError::kInvalidGeometry));
  EXPECT_TRUE(bad.mask == nullptr);

  XochitlSelector16::SourceView view = surface.view();
  view.width = 953;
  bad = selector.build(view, valid);
  EXPECT_EQ(
      static_cast<int>(bad.error),
      static_cast<int>(XochitlSelector16::BuildError::kInvalidSourceGeometry));

  view = surface.view();
  view.format = static_cast<XochitlSelector16::SourceFormat>(0xff);
  bad = selector.build(view, valid);
  EXPECT_EQ(
      static_cast<int>(bad.error),
      static_cast<int>(XochitlSelector16::BuildError::kUnsupportedFormat));

  view = surface.view();
  view.right_padding = static_cast<XochitlSelector16::RightPadding>(0xff);
  bad = selector.build(view, valid);
  EXPECT_EQ(
      static_cast<int>(bad.error),
      static_cast<int>(XochitlSelector16::BuildError::kUnsupportedPadding));

  view = surface.view();
  view.stride_bytes = 1;
  bad = selector.build(view, valid);
  EXPECT_EQ(static_cast<int>(bad.error),
            static_cast<int>(XochitlSelector16::BuildError::kInvalidStride));

  view = surface.view();
  view.bytes = view.bytes.first(1);
  bad = selector.build(view, valid);
  EXPECT_EQ(static_cast<int>(bad.error),
            static_cast<int>(XochitlSelector16::BuildError::kBufferTooSmall));
  EXPECT_TRUE(bad.mask == nullptr);
}

} // namespace
} // namespace pluto::swtcon
