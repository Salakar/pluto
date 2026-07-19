// Exact-area RM1 damage-policy comparison. The executable performs no device
// I/O; it can run beside stock Xochitl to report the panel pixels selected by
// the legacy and regional-Full policies for representative damage shapes.

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string_view>
#include <utility>

namespace {

constexpr std::uint64_t kPanelWidth = 1404;
constexpr std::uint64_t kPanelHeight = 1872;
constexpr std::uint64_t kPanelPixels = kPanelWidth * kPanelHeight;
constexpr std::size_t kMaximumDamageRects = 64;

struct Rect final {
  std::uint32_t x;
  std::uint32_t y;
  std::uint32_t width;
  std::uint32_t height;
};

struct Scenario final {
  std::string_view name;
  bool full_quality;
  const Rect *damage;
  std::size_t damage_count;
};

std::uint64_t requested_pixels(const Scenario &scenario) {
  std::array<std::uint32_t, kMaximumDamageRects * 2> x_edges{};
  std::size_t x_count = 0;
  for (std::size_t index = 0; index < scenario.damage_count; ++index) {
    const Rect &rect = scenario.damage[index];
    x_edges[x_count++] = rect.x;
    x_edges[x_count++] = rect.x + rect.width;
  }
  std::sort(x_edges.begin(), x_edges.begin() + x_count);
  const auto unique_end =
      std::unique(x_edges.begin(), x_edges.begin() + x_count);
  x_count = static_cast<std::size_t>(unique_end - x_edges.begin());

  std::array<std::pair<std::uint32_t, std::uint32_t>, kMaximumDamageRects>
      y_intervals{};
  std::uint64_t pixels = 0;
  for (std::size_t x_index = 1; x_index < x_count; ++x_index) {
    const std::uint32_t left = x_edges[x_index - 1];
    const std::uint32_t right = x_edges[x_index];
    std::size_t y_count = 0;
    for (std::size_t rect_index = 0; rect_index < scenario.damage_count;
         ++rect_index) {
      const Rect &rect = scenario.damage[rect_index];
      if (rect.x < right && rect.x + rect.width > left) {
        y_intervals[y_count++] = {rect.y, rect.y + rect.height};
      }
    }
    if (y_count == 0) {
      continue;
    }
    std::sort(y_intervals.begin(), y_intervals.begin() + y_count);
    std::uint32_t run_top = y_intervals[0].first;
    std::uint32_t run_bottom = y_intervals[0].second;
    std::uint64_t covered_y = 0;
    for (std::size_t y_index = 1; y_index < y_count; ++y_index) {
      const auto [top, bottom] = y_intervals[y_index];
      if (top > run_bottom) {
        covered_y += run_bottom - run_top;
        run_top = top;
        run_bottom = bottom;
      } else {
        run_bottom = std::max(run_bottom, bottom);
      }
    }
    covered_y += run_bottom - run_top;
    pixels += static_cast<std::uint64_t>(right - left) * covered_y;
  }
  return pixels;
}

std::uint64_t bounding_pixels(const Scenario &scenario) {
  std::uint32_t left = scenario.damage[0].x;
  std::uint32_t top = scenario.damage[0].y;
  std::uint32_t right = left + scenario.damage[0].width;
  std::uint32_t bottom = top + scenario.damage[0].height;
  for (std::size_t index = 1; index < scenario.damage_count; ++index) {
    const Rect &rect = scenario.damage[index];
    left = std::min(left, rect.x);
    top = std::min(top, rect.y);
    right = std::max(right, rect.x + rect.width);
    bottom = std::max(bottom, rect.y + rect.height);
  }
  return static_cast<std::uint64_t>(right - left) * (bottom - top);
}

std::uint64_t ratio_milli(std::uint64_t driven, std::uint64_t requested) {
  return requested == 0 ? 0 : driven * 1000u / requested;
}

} // namespace

int main() {
  constexpr std::array<Rect, 1> full{{{0, 0, 1404, 1872}}};
  constexpr std::array<Rect, 1> medium{{{351, 468, 702, 936}}};
  constexpr std::array<Rect, 1> sparse{{{654, 888, 96, 96}}};
  constexpr std::array<Rect, 4> clustered{{
      {400, 600, 32, 32},
      {496, 600, 32, 32},
      {400, 696, 32, 32},
      {496, 696, 32, 32},
  }};
  constexpr std::array<Rect, 4> far{{
      {0, 0, 32, 32},
      {1372, 0, 32, 32},
      {0, 1840, 32, 32},
      {1372, 1840, 32, 32},
  }};
  constexpr std::array<Rect, 3> overlap{{
      {4, 5, 12, 11},
      {9, 9, 15, 13},
      {4, 5, 12, 11},
  }};
  const std::array<Scenario, 6> scenarios{{
      {"full_screen", true, full.data(), full.size()},
      {"medium_full_quality", true, medium.data(), medium.size()},
      {"sparse_full_quality", true, sparse.data(), sparse.size()},
      {"multi_rect_clustered_ui", false, clustered.data(), clustered.size()},
      {"multi_rect_far_ui", false, far.data(), far.size()},
      {"multi_rect_overlap_ui", false, overlap.data(), overlap.size()},
  }};

  std::uint64_t legacy_total = 0;
  std::uint64_t regional_total = 0;
  std::uint64_t requested_total = 0;
  std::printf("rm1_damage_context panel_width=%llu panel_height=%llu "
              "panel_pixels=%llu scenarios=%zu\n",
              static_cast<unsigned long long>(kPanelWidth),
              static_cast<unsigned long long>(kPanelHeight),
              static_cast<unsigned long long>(kPanelPixels), scenarios.size());
  for (const Scenario &scenario : scenarios) {
    const std::uint64_t requested = requested_pixels(scenario);
    const std::uint64_t regional = bounding_pixels(scenario);
    const std::uint64_t legacy =
        scenario.full_quality ? kPanelPixels : regional;
    if (requested == 0 || regional < requested || legacy < regional) {
      std::fprintf(stderr, "invalid scenario geometry: %.*s\n",
                   static_cast<int>(scenario.name.size()),
                   scenario.name.data());
      return 1;
    }
    requested_total += requested;
    legacy_total += legacy;
    regional_total += regional;
    std::printf(
        "rm1_damage_case name=%.*s class=%s rects=%zu requested_px=%llu "
        "legacy_driven_px=%llu legacy_amp_milli=%llu "
        "regional_driven_px=%llu regional_amp_milli=%llu pixels_avoided=%llu"
        "\n",
        static_cast<int>(scenario.name.size()), scenario.name.data(),
        scenario.full_quality ? "full" : "ui", scenario.damage_count,
        static_cast<unsigned long long>(requested),
        static_cast<unsigned long long>(legacy),
        static_cast<unsigned long long>(ratio_milli(legacy, requested)),
        static_cast<unsigned long long>(regional),
        static_cast<unsigned long long>(ratio_milli(regional, requested)),
        static_cast<unsigned long long>(legacy - regional));
  }
  std::printf("rm1_damage_summary requested_px=%llu legacy_driven_px=%llu "
              "regional_driven_px=%llu pixels_avoided=%llu\n",
              static_cast<unsigned long long>(requested_total),
              static_cast<unsigned long long>(legacy_total),
              static_cast<unsigned long long>(regional_total),
              static_cast<unsigned long long>(legacy_total - regional_total));
  return 0;
}
