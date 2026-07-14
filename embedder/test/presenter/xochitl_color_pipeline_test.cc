#include "presenter/swtcon/xochitl_color_pipeline.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <map>
#include <span>
#include <string>
#include <vector>

#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "swtcon_eink_synth.h"

namespace pluto::swtcon {
namespace {

std::vector<std::uint8_t>
make_color_eink(int phases = 1, bool mode2_cannot_reach_white = false) {
  constexpr int kModes = 8;
  constexpr int kTemps = 9;
  std::vector<std::uint8_t> codes(
      static_cast<std::size_t>(phases) * kWaveformMatrixCells, 0u);
  std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(codes)};
  std::vector<std::size_t> record_for(static_cast<std::size_t>(kModes) * kTemps,
                                      0u);
  if (mode2_cannot_reach_white) {
    // Make black drivable from white, while leaving white unreachable from
    // black. The legal target map must therefore reject white as the startup
    // endpoint even though the record is structurally valid.
    codes[30u] = 1u;
    records.push_back(swtcon_synth::record_from_codes(codes));
    for (int bin = 0; bin < kTemps; ++bin) {
      record_for[static_cast<std::size_t>(2 * kTemps + bin)] = 1u;
    }
  }
  return swtcon_synth::wrap_eink(swtcon_synth::build_container(
      kModes, kTemps, {0, 5, 10, 15, 20, 25, 30, 35, 40}, records, record_for));
}

std::vector<std::uint8_t> make_ct33() {
  std::vector<std::uint8_t> blob(Ct33Frontend::kBlobBytes, 255u);
  const std::size_t white =
      (Ct33Frontend::kCubeCells - 1u) * Ct33Frontend::kThresholdSlots;
  std::fill_n(blob.begin() + static_cast<std::ptrdiff_t>(white),
              Ct33Frontend::kThresholdSlots - 1, 0u);
  return blob;
}

std::map<std::string, std::vector<std::uint8_t>> make_blobs() {
  const std::vector<std::uint8_t> blob = make_ct33();
  return {{"std", blob}, {"best", blob}, {"pen", blob}, {"fast", blob}};
}

struct ColorPipelineHarness {
  ColorPipelineHarness() {
    EXPECT_TRUE(table.parse(make_color_eink(), &error)) << error;
    surface.assign(static_cast<std::size_t>(kLogicalWidth) * kLogicalHeight *
                       kRgb565BytesPerPixel,
                   0xffu);
  }

  XochitlColorPipeline::BuildResult
  build(XochitlHistoryState::Mode mode,
        XochitlHistoryState::InclusiveRect update = {0, 0, 0, 0},
        std::span<const std::uint8_t> lane_mask = {},
        std::size_t lane_mask_stride = 0) {
    return pipeline.preprocess_rgb565(
        surface, static_cast<std::size_t>(kLogicalWidth) * 2u, update, mode,
        /*temperature_bin=*/4, /*temperature_celsius=*/25.0f, lane_mask,
        lane_mask_stride);
  }

  WaveformTable table;
  XochitlColorPipeline pipeline;
  std::vector<std::uint8_t> surface;
  std::string error;
};

TEST(XochitlColorPipelineTest, CapabilityRequiresEveryBlobAndEveryExactRecord) {
  ColorPipelineHarness h;
  auto blobs = make_blobs();
  blobs.erase("pen");
  EXPECT_FALSE(h.pipeline.configure(&h.table, blobs, &h.error));
  EXPECT_FALSE(h.pipeline.color_capable());
  EXPECT_FALSE(h.error.empty());

  blobs = make_blobs();
  blobs["best"].pop_back();
  EXPECT_FALSE(h.pipeline.configure(&h.table, blobs, &h.error));
  EXPECT_FALSE(h.pipeline.color_capable());

  EXPECT_TRUE(h.pipeline.configure(&h.table, make_blobs(), &h.error))
      << h.error;
  EXPECT_TRUE(h.pipeline.color_capable());

  WaveformTable two_bin;
  ASSERT_TRUE(two_bin.parse(swtcon_synth::make_synthetic_eink(1), &h.error));
  EXPECT_FALSE(h.pipeline.configure(&two_bin, make_blobs(), &h.error));
  EXPECT_FALSE(h.pipeline.color_capable());
}

TEST(XochitlColorPipelineTest,
     CapabilityRequiresSafeStartupAndAtMostByteSizedPhaseCounts) {
  ColorPipelineHarness h;

  WaveformTable unsafe_startup;
  ASSERT_TRUE(unsafe_startup.parse(make_color_eink(1, true), &h.error))
      << h.error;
  EXPECT_FALSE(h.pipeline.configure(&unsafe_startup, make_blobs(), &h.error));
  EXPECT_FALSE(h.pipeline.color_capable());

  WaveformTable max_phases;
  ASSERT_TRUE(max_phases.parse(make_color_eink(255), &h.error)) << h.error;
  EXPECT_TRUE(h.pipeline.configure(&max_phases, make_blobs(), &h.error))
      << h.error;

  WaveformTable too_many_phases;
  ASSERT_TRUE(too_many_phases.parse(make_color_eink(256), &h.error)) << h.error;
  EXPECT_FALSE(h.pipeline.configure(&too_many_phases, make_blobs(), &h.error));
  EXPECT_FALSE(h.pipeline.color_capable());
}

TEST(XochitlColorPipelineTest,
     FastUsesCt33PlaneWithoutLegacySelectorSubstitution) {
  ColorPipelineHarness h;
  ASSERT_TRUE(h.pipeline.configure(&h.table, make_blobs(), &h.error))
      << h.error;

  const auto fast = h.build(XochitlHistoryState::Mode::kFast);
  ASSERT_TRUE(fast);
  ASSERT_EQ(fast.operation->raw().size(), 16u);
  for (const std::uint8_t raw : fast.operation->raw()) {
    EXPECT_EQ(raw, 0x87u); // ct33 white state 7 + exact-white marker
  }

  const auto legacy = h.build(XochitlHistoryState::Mode::kFull);
  ASSERT_TRUE(legacy);
  for (const std::uint8_t raw : legacy.operation->raw()) {
    EXPECT_EQ(raw, 0x8bu); // selector ff chooses white luma state 11
  }

  std::fill(h.surface.begin(), h.surface.end(), 0u);
  const auto black = h.build(XochitlHistoryState::Mode::kFast);
  ASSERT_TRUE(black);
  for (const std::uint8_t raw : black.operation->raw()) {
    EXPECT_EQ(raw, 0u);
  }
}

TEST(XochitlColorPipelineTest, BottomRightGuardsAreOwnedPaddedAndHistorySafe) {
  ColorPipelineHarness h;
  ASSERT_TRUE(h.pipeline.configure(&h.table, make_blobs(), &h.error))
      << h.error;
  ASSERT_TRUE(h.pipeline.initialize_white_history());
  constexpr XochitlHistoryState::InclusiveRect kLastPixel{
      kLogicalWidth - 1, kLogicalHeight - 1, kLogicalWidth - 1,
      kLogicalHeight - 1};
  const auto built = h.build(XochitlHistoryState::Mode::kFull, kLastPixel);
  ASSERT_TRUE(built);
  EXPECT_EQ(built.operation->width(), 8);
  EXPECT_EQ(built.operation->height(), 2);
  const auto execution = built.operation->execution();
  EXPECT_EQ(execution.left, kLogicalWidth - 1);
  EXPECT_EQ(execution.top, kLogicalHeight - 1);
  EXPECT_EQ(execution.right, 960);
  EXPECT_EQ(execution.bottom, 1696);
  EXPECT_EQ(built.operation->raw().size(), 16u);

  const auto prepared = h.pipeline.prepare(*built.operation);
  ASSERT_TRUE(prepared);
  EXPECT_TRUE(prepared.operation->execution() == built.operation->execution());
  EXPECT_EQ(static_cast<int>(h.pipeline.history().commit(*prepared.operation)),
            static_cast<int>(XochitlHistoryState::FinalizeStatus::kCommitted));
  EXPECT_TRUE(h.pipeline.history().pixel(960, 1696).has_value());
}

TEST(XochitlColorPipelineTest,
     MaskValidationCanonicalizationAndFastRejectionAreFailClosed) {
  ColorPipelineHarness h;
  ASSERT_TRUE(h.pipeline.configure(&h.table, make_blobs(), &h.error))
      << h.error;
  constexpr XochitlHistoryState::InclusiveRect update{16, 20, 23, 21};
  std::array<std::uint8_t, 16> empty_mask{};

  EXPECT_EQ(static_cast<int>(
                h.build(XochitlHistoryState::Mode::kFull, update, empty_mask, 8)
                    .error),
            static_cast<int>(XochitlColorPipeline::BuildError::kInvalidMask));
  EXPECT_EQ(static_cast<int>(h.build(XochitlHistoryState::Mode::kFull, update,
                                     std::span(empty_mask).first(15), 8)
                                 .error),
            static_cast<int>(XochitlColorPipeline::BuildError::kInvalidMask));
  empty_mask[0] = 1u;
  EXPECT_EQ(static_cast<int>(
                h.build(XochitlHistoryState::Mode::kFull, update, empty_mask, 7)
                    .error),
            static_cast<int>(XochitlColorPipeline::BuildError::kInvalidMask));
  EXPECT_EQ(static_cast<int>(
                h.build(XochitlHistoryState::Mode::kFast, update, empty_mask, 8)
                    .error),
            static_cast<int>(XochitlColorPipeline::BuildError::kInvalidMask));

  std::array<std::uint8_t, 16> sparse_mask{};
  sparse_mask[0] = 2u;
  sparse_mask[15] = 0xffu;
  const auto sparse =
      h.build(XochitlHistoryState::Mode::kFull, update, sparse_mask, 8);
  ASSERT_TRUE(sparse);
  ASSERT_TRUE(sparse.operation->masked());
  ASSERT_EQ(sparse.operation->lane_mask().size(), sparse_mask.size());
  for (std::size_t lane = 0; lane < sparse_mask.size(); ++lane) {
    EXPECT_EQ(sparse.operation->lane_mask()[lane],
              sparse_mask[lane] == 0u ? 0u : 1u);
  }

  std::array<std::uint8_t, 16> dense_mask{};
  dense_mask.fill(0x80u);
  const auto dense =
      h.build(XochitlHistoryState::Mode::kText, update, dense_mask, 8);
  ASSERT_TRUE(dense);
  EXPECT_FALSE(dense.operation->masked());
  EXPECT_TRUE(dense.operation->lane_mask().empty());
}

TEST(XochitlColorPipelineTest,
     SparseMasksPreserveRightAndBottomHistoryGuardSelection) {
  ColorPipelineHarness h;
  ASSERT_TRUE(h.pipeline.configure(&h.table, make_blobs(), &h.error))
      << h.error;
  ASSERT_TRUE(h.pipeline.initialize_white_history());
  std::fill(h.surface.begin(), h.surface.end(), 0u);

  constexpr XochitlHistoryState::InclusiveRect right_update{
      kLogicalWidth - 2, 80, kLogicalWidth - 1, 80};
  std::array<std::uint8_t, 16> right_mask{};
  for (std::size_t lane = 1; lane < 8u; ++lane) {
    right_mask[lane] = 0xa5u;
  }
  const auto right =
      h.build(XochitlHistoryState::Mode::kFull, right_update, right_mask, 8);
  ASSERT_TRUE(right);
  EXPECT_TRUE(right.operation->execution() ==
              (XochitlHistoryState::InclusiveRect{
                  kLogicalWidth - 2, 80,
                  XochitlHistoryState::kPackedDriveWidth - 1, 81}));
  ASSERT_EQ(right.operation->lane_mask().size(), right_mask.size());
  for (std::size_t lane = 0; lane < right_mask.size(); ++lane) {
    EXPECT_EQ(right.operation->lane_mask()[lane],
              lane >= 1u && lane < 8u ? 1u : 0u);
  }
  const auto right_prepared = h.pipeline.prepare(*right.operation);
  ASSERT_TRUE(right_prepared);
  ASSERT_EQ(
      static_cast<int>(h.pipeline.history().commit(*right_prepared.operation)),
      static_cast<int>(XochitlHistoryState::FinalizeStatus::kCommitted));
  EXPECT_TRUE(*h.pipeline.history().pixel(kLogicalWidth - 2, 80) ==
              (XochitlHistoryState::HistoryPixel{30, 0}));
  EXPECT_TRUE(*h.pipeline.history().pixel(kLogicalWidth - 1, 81) ==
              (XochitlHistoryState::HistoryPixel{30, 0}));
  for (std::int32_t x = kLogicalWidth - 1;
       x < XochitlHistoryState::kPackedDriveWidth; ++x) {
    const std::size_t lane = static_cast<std::size_t>(x - (kLogicalWidth - 2));
    EXPECT_TRUE(*h.pipeline.history().pixel(x, 80) ==
                (XochitlHistoryState::HistoryPixel{
                    right_prepared.operation->lanes()[lane].a2,
                    right_prepared.operation->lanes()[lane].b2}));
  }

  constexpr XochitlHistoryState::InclusiveRect bottom_update{
      104, kLogicalHeight - 1, 104, kLogicalHeight - 1};
  std::array<std::uint8_t, 16> bottom_mask{};
  bottom_mask[0] = 3u;
  bottom_mask[8] = 9u;
  const auto bottom =
      h.build(XochitlHistoryState::Mode::kText, bottom_update, bottom_mask, 8);
  ASSERT_TRUE(bottom);
  EXPECT_TRUE(bottom.operation->execution() ==
              (XochitlHistoryState::InclusiveRect{104, kLogicalHeight - 1, 111,
                                                  kLogicalHeight}));
  ASSERT_EQ(bottom.operation->lane_mask().size(), bottom_mask.size());
  EXPECT_EQ(bottom.operation->lane_mask()[0], 1u);
  EXPECT_EQ(bottom.operation->lane_mask()[8], 1u);
  const auto bottom_prepared = h.pipeline.prepare(*bottom.operation);
  ASSERT_TRUE(bottom_prepared);
  ASSERT_EQ(
      static_cast<int>(h.pipeline.history().commit(*bottom_prepared.operation)),
      static_cast<int>(XochitlHistoryState::FinalizeStatus::kCommitted));
  EXPECT_TRUE(*h.pipeline.history().pixel(105, kLogicalHeight - 1) ==
              (XochitlHistoryState::HistoryPixel{30, 0}));
  EXPECT_TRUE(*h.pipeline.history().pixel(104, kLogicalHeight - 1) ==
              (XochitlHistoryState::HistoryPixel{
                  bottom_prepared.operation->lanes()[0].a2,
                  bottom_prepared.operation->lanes()[0].b2}));
  EXPECT_TRUE(*h.pipeline.history().pixel(104, kLogicalHeight) ==
              (XochitlHistoryState::HistoryPixel{
                  bottom_prepared.operation->lanes()[8].a2,
                  bottom_prepared.operation->lanes()[8].b2}));
}

TEST(XochitlColorPipelineTest, VisibleExecutionPaddingUsesRealNeighborPixels) {
  ColorPipelineHarness h;
  ASSERT_TRUE(h.pipeline.configure(&h.table, make_blobs(), &h.error))
      << h.error;
  std::fill(h.surface.begin(), h.surface.end(), 0u);
  const std::size_t white_neighbor =
      static_cast<std::size_t>(1) * kLogicalWidth * kRgb565BytesPerPixel +
      static_cast<std::size_t>(2) * kRgb565BytesPerPixel;
  h.surface[white_neighbor] = 0xffu;
  h.surface[white_neighbor + 1] = 0xffu;

  const auto built = h.build(XochitlHistoryState::Mode::kFast, {1, 1, 1, 1});
  ASSERT_TRUE(built);
  ASSERT_EQ(built.operation->width(), 8);
  ASSERT_EQ(built.operation->height(), 2);
  EXPECT_EQ(built.operation->raw()[0], 0u);
  EXPECT_EQ(built.operation->raw()[1], 0x87u);
}

TEST(XochitlColorPipelineTest, PayloadOwnsPixelsAndCannotCrossReconfigure) {
  ColorPipelineHarness h;
  ASSERT_TRUE(h.pipeline.configure(&h.table, make_blobs(), &h.error))
      << h.error;
  ASSERT_TRUE(h.pipeline.initialize_white_history());
  std::fill(h.surface.begin(), h.surface.end(), 0u);
  const auto built = h.build(XochitlHistoryState::Mode::kFast);
  ASSERT_TRUE(built);
  std::fill(h.surface.begin(), h.surface.end(), 0xffu);
  for (const std::uint8_t raw : built.operation->raw()) {
    EXPECT_EQ(raw, 0u);
  }

  h.pipeline.clear();
  EXPECT_EQ(
      static_cast<int>(h.pipeline.prepare(*built.operation).error),
      static_cast<int>(XochitlHistoryState::PrepareError::kInvalidHistory));
}

TEST(XochitlColorPipelineTest, DrawBackRecolorAndErasePrepareFromNewestCommit) {
  ColorPipelineHarness h;
  ASSERT_TRUE(h.pipeline.configure(&h.table, make_blobs(), &h.error))
      << h.error;
  ASSERT_TRUE(h.pipeline.initialize_white_history());
  constexpr XochitlHistoryState::InclusiveRect kRegion{24, 40, 31, 47};

  std::fill(h.surface.begin(), h.surface.end(), 0u);
  auto dark = h.build(XochitlHistoryState::Mode::kFull, kRegion);
  ASSERT_TRUE(dark);
  auto dark_prepared = h.pipeline.prepare(*dark.operation);
  ASSERT_TRUE(dark_prepared);
  ASSERT_EQ(
      static_cast<int>(h.pipeline.history().commit(*dark_prepared.operation)),
      static_cast<int>(XochitlHistoryState::FinalizeStatus::kCommitted));

  std::fill(h.surface.begin(), h.surface.end(), 0xffu);
  auto erase = h.build(XochitlHistoryState::Mode::kFull, kRegion);
  ASSERT_TRUE(erase);
  auto erase_prepared = h.pipeline.prepare(*erase.operation);
  ASSERT_TRUE(erase_prepared);
  EXPECT_NE(erase_prepared.operation->lanes()[0].transition,
            dark_prepared.operation->lanes()[0].transition);
  EXPECT_EQ(
      static_cast<int>(h.pipeline.history().commit(*erase_prepared.operation)),
      static_cast<int>(XochitlHistoryState::FinalizeStatus::kCommitted));
}

TEST(XochitlColorPipelineTest,
     FullPanelParallelConversionMatchesScalarSnapshotContract) {
  ColorPipelineHarness h;
  const auto blobs = make_blobs();
  ASSERT_TRUE(h.pipeline.configure(&h.table, blobs, &h.error)) << h.error;
  for (std::int32_t y = 0; y < kLogicalHeight; ++y) {
    for (std::int32_t x = 0; x < kLogicalWidth; ++x) {
      const std::uint16_t pixel =
          static_cast<std::uint16_t>((static_cast<std::uint32_t>(x) * 40503u +
                                      static_cast<std::uint32_t>(y) * 17539u) &
                                     0xffffu);
      const std::size_t offset =
          (static_cast<std::size_t>(y) * kLogicalWidth + x) * 2u;
      h.surface[offset] = static_cast<std::uint8_t>(pixel);
      h.surface[offset + 1u] = static_cast<std::uint8_t>(pixel >> 8u);
    }
  }

  constexpr XochitlHistoryState::InclusiveRect kFull{0, 0, kLogicalWidth - 1,
                                                     kLogicalHeight - 1};
  const auto actual = h.build(XochitlHistoryState::Mode::kFull, kFull);
  ASSERT_TRUE(actual);
  ASSERT_EQ(actual.operation->width(), 960);
  ASSERT_EQ(actual.operation->height(), kLogicalHeight);

  XochitlSelector16 selector;
  const auto selected = selector.build(
      {.bytes = h.surface,
       .stride_bytes = static_cast<std::size_t>(kLogicalWidth) * 2u,
       .width = kLogicalWidth,
       .height = kLogicalHeight,
       .format = XochitlSelector16::SourceFormat::kRgb565LittleEndian,
       .right_padding = XochitlSelector16::RightPadding::kReplicateLogicalEdge},
      {kFull.left, kFull.top, kFull.right, kFull.bottom});
  ASSERT_TRUE(selected);
  ASSERT_EQ(selected.mask->width(), actual.operation->width());
  ASSERT_EQ(selected.mask->height(), actual.operation->height());

  const std::size_t width = static_cast<std::size_t>(actual.operation->width());
  const std::size_t height =
      static_cast<std::size_t>(actual.operation->height());
  std::vector<std::uint8_t> compact_rgb(width * height * 2u);
  for (std::size_t row = 0; row < height; ++row) {
    const std::uint8_t *source_row =
        h.surface.data() + row * static_cast<std::size_t>(kLogicalWidth) * 2u;
    std::uint8_t *compact_row = compact_rgb.data() + row * width * 2u;
    std::memcpy(compact_row, source_row,
                static_cast<std::size_t>(kLogicalWidth) * 2u);
    for (std::size_t x = kLogicalWidth; x < width; ++x) {
      compact_row[x * 2u] = compact_row[(kLogicalWidth - 1u) * 2u];
      compact_row[x * 2u + 1u] = compact_row[(kLogicalWidth - 1u) * 2u + 1u];
    }
  }
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blobs.at("best"), &h.error)) << h.error;
  std::vector<std::uint8_t> expected(width * height);
  ASSERT_TRUE(frontend.convert_rgb565_le(
      compact_rgb.data(), width * 2u, 0, 0, static_cast<std::int32_t>(width),
      static_cast<std::int32_t>(height), expected.data(), width,
      selected.mask->bytes().data(), selected.mask->stride()));
  ASSERT_EQ(actual.operation->raw().size(), expected.size());
  const auto mismatch =
      std::mismatch(actual.operation->raw().begin(),
                    actual.operation->raw().end(), expected.begin());
  const std::size_t mismatch_index = static_cast<std::size_t>(
      std::distance(actual.operation->raw().begin(), mismatch.first));
  EXPECT_EQ(mismatch_index, actual.operation->raw().size());
}

} // namespace
} // namespace pluto::swtcon
