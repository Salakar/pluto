// RM2 preparation hot-path A/B. This isolates the two table substitutions
// used by the production backend: exhaustive RGB565 -> gray4 codegen and
// open-time expansion of WBF even-state transitions. Host timings establish
// relative wins only; release acceptance still measures the ARMv7 tablet.

#include "presenter/native/rm2/rm2_scan_encoder.h"
#include "presenter/native/rm2/wbf_decoder.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "wbf_synth.h"

namespace {

using pluto::native::rm2::encode_rm2_phase;
using pluto::native::rm2::fill_rm2_scan_slot;
using pluto::native::rm2::kRm2PanelHeight;
using pluto::native::rm2::kRm2PanelWidth;
using pluto::native::rm2::kRm2SlotBytes;
using pluto::native::rm2::rgb565_to_rm2_level;
using pluto::native::rm2::Rm2PanelRect;
using pluto::native::rm2::WbfDecoder;

constexpr std::size_t kPanelPixels = 1404U * 1872U;
constexpr int kIterations = 24;

std::uint8_t arithmetic_level(std::uint16_t pixel) {
  const std::uint32_t red5 = (pixel >> 11U) & 0x1fU;
  const std::uint32_t green6 = (pixel >> 5U) & 0x3fU;
  const std::uint32_t blue5 = pixel & 0x1fU;
  const std::uint32_t red8 = (red5 << 3U) | (red5 >> 2U);
  const std::uint32_t green8 = (green6 << 2U) | (green6 >> 4U);
  const std::uint32_t blue8 = (blue5 << 3U) | (blue5 >> 2U);
  const std::uint32_t luma =
      (77U * red8 + 150U * green8 + 29U * blue8 + 128U) >> 8U;
  return static_cast<std::uint8_t>((luma * 15U + 127U) / 255U);
}

struct Timing {
  double p50_us = 0;
  double p95_us = 0;
};

Timing timing(std::vector<double> samples) {
  std::sort(samples.begin(), samples.end());
  return {
      .p50_us = samples[samples.size() / 2U],
      .p95_us = samples[(samples.size() * 95U) / 100U],
  };
}

template <typename Function> Timing measure(Function function) {
  std::vector<double> samples;
  samples.reserve(kIterations - 4);
  for (int iteration = 0; iteration < kIterations; ++iteration) {
    const auto begin = std::chrono::steady_clock::now();
    function();
    const auto end = std::chrono::steady_clock::now();
    if (iteration >= 4) {
      samples.push_back(
          std::chrono::duration<double, std::micro>(end - begin).count());
    }
  }
  return timing(std::move(samples));
}

} // namespace

int main() {
  for (std::uint32_t pixel = 0; pixel <= 0xffffU; ++pixel) {
    if (arithmetic_level(static_cast<std::uint16_t>(pixel)) !=
        rgb565_to_rm2_level(static_cast<std::uint16_t>(pixel))) {
      std::fprintf(stderr, "RGB565 LUT mismatch at %u\n", pixel);
      return 1;
    }
  }

  std::vector<std::uint16_t> pixels(kPanelPixels);
  std::vector<std::uint8_t> output(kPanelPixels);
  std::uint32_t random = 0x52f6a19dU;
  for (std::uint16_t &pixel : pixels) {
    random = random * 1664525U + 1013904223U;
    pixel = static_cast<std::uint16_t>(random >> 8U);
  }
  std::uint64_t checksum = 0;
  const Timing arithmetic = measure([&] {
    for (std::size_t index = 0; index < pixels.size(); ++index) {
      output[index] = arithmetic_level(pixels[index]);
    }
    checksum += output[random % output.size()];
  });
  const Timing generated = measure([&] {
    for (std::size_t index = 0; index < pixels.size(); ++index) {
      output[index] = rgb565_to_rm2_level(pixels[index]);
    }
    checksum += output[random % output.size()];
  });

  const auto fixture = pluto::native::rm2::test::make_synthetic_wbf();
  WbfDecoder waveform;
  std::string error;
  if (!waveform.open(fixture.bytes, fixture.expected, &error)) {
    std::fprintf(stderr, "synthetic WBF open failed: %s\n", error.c_str());
    return 1;
  }
  std::vector<std::uint8_t> transitions(kPanelPixels);
  for (std::uint8_t &transition : transitions) {
    random = random * 1664525U + 1013904223U;
    transition = static_cast<std::uint8_t>(random);
  }
  std::vector<std::uint8_t> expanded(16U * 16U);
  for (std::uint32_t next = 0; next < 16; ++next) {
    for (std::uint32_t previous = 0; previous < 16; ++previous) {
      if (!waveform.drive_code(1, 0, static_cast<std::uint8_t>(previous * 2U),
                               static_cast<std::uint8_t>(next * 2U), 0,
                               &expanded[next * 16U + previous])) {
        return 1;
      }
    }
  }

  const Timing decoded = measure([&] {
    std::uint64_t local = 0;
    for (const std::uint8_t transition : transitions) {
      std::uint8_t code = 0;
      (void)waveform.drive_code(
          1, 0, static_cast<std::uint8_t>((transition & 0x0fU) * 2U),
          static_cast<std::uint8_t>((transition >> 4U) * 2U), 0, &code);
      local += code;
    }
    checksum += local;
  });
  const Timing preexpanded = measure([&] {
    std::uint64_t local = 0;
    for (const std::uint8_t transition : transitions) {
      local += expanded[transition];
    }
    checksum += local;
  });
  std::vector<std::byte> slot(kRm2SlotBytes);
  if (!fill_rm2_scan_slot(slot, 0)) {
    return 1;
  }
  const Rm2PanelRect full_panel{
      .row_min = 0,
      .row_max = static_cast<std::uint16_t>(kRm2PanelHeight - 1U),
      .column_min = 0,
      .column_max = static_cast<std::uint16_t>(kRm2PanelWidth - 1U),
  };
  if (!encode_rm2_phase(slot, full_panel, transitions, expanded)) {
    return 1;
  }
  const Timing packed = measure([&] {
    (void)encode_rm2_phase(slot, full_panel, transitions, expanded);
    checksum += static_cast<std::uint8_t>(slot[random % slot.size()]);
  });

  std::printf("rm2 rgb565 full-panel arithmetic p50 %.1f us p95 %.1f us | "
              "generated p50 %.1f us p95 %.1f us | p50 %.2fx\n",
              arithmetic.p50_us, arithmetic.p95_us, generated.p50_us,
              generated.p95_us, arithmetic.p50_us / generated.p50_us);
  std::printf(
      "rm2 phase transition full-panel decoder p50 %.1f us p95 %.1f us | "
      "expanded p50 %.1f us p95 %.1f us | p50 %.2fx | checksum %llu\n",
      decoded.p50_us, decoded.p95_us, preexpanded.p50_us, preexpanded.p95_us,
      decoded.p50_us / preexpanded.p50_us,
      static_cast<unsigned long long>(checksum));
  std::printf("rm2 full-panel phase encode p50 %.1f us p95 %.1f us | "
              "11.763 ms scan budget %.2fx headroom\n",
              packed.p50_us, packed.p95_us, 11763.0 / packed.p95_us);
  return 0;
}
