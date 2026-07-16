#include <gtest/gtest.h>

#include <cstdint>

#include "renderer/frame_ledger.h"
#include "renderer/kernels.h"

namespace {

using pluto::FrameLedger;
using pluto::FrameLedgerConfig;
using pluto::FrameLedgerState;
using pluto::TileStats;

} // namespace

TEST(FrameLedgerTest, PanelGeometryDefaults) {
  FrameLedger ledger((FrameLedgerConfig()));
  ASSERT_TRUE(ledger.valid());
  // Panel constants: 954x1696, padded stride 960, 30x53 = 1590 tiles of
  // 32x32.
  EXPECT_EQ(ledger.width(), 954u);
  EXPECT_EQ(ledger.height(), 1696u);
  EXPECT_EQ(ledger.tile_px(), 32u);
  EXPECT_EQ(ledger.stride(), size_t{960});
  EXPECT_EQ(ledger.tile_cols(), 30u);
  EXPECT_EQ(ledger.tile_rows(), 53u);
  EXPECT_EQ(ledger.tile_count(), 1590u);
  EXPECT_EQ(ledger.chroma_stride(), size_t{120});
  EXPECT_EQ(ledger.l_cur_size(), size_t{960} * 1696u);
  EXPECT_EQ(sizeof(TileStats), size_t{32});
}

TEST(FrameLedgerTest, ArbitrarySizesComputeTileGrid) {
  FrameLedgerConfig config;
  config.width = 73;
  config.height = 59;
  config.tile_px = 16;
  FrameLedger ledger(config);
  ASSERT_TRUE(ledger.valid());
  EXPECT_EQ(ledger.tile_cols(), 5u);
  EXPECT_EQ(ledger.tile_rows(), 4u);
  EXPECT_EQ(ledger.stride(), size_t{80});
  EXPECT_EQ(ledger.chroma_stride(), size_t{10});
  EXPECT_EQ(ledger.tile_index(2, 3), 17u);
}

TEST(FrameLedgerTest, RejectsUnusableGeometry) {
  FrameLedger ledger;
  EXPECT_FALSE(ledger.valid());

  FrameLedgerConfig zero_width;
  zero_width.width = 0;
  EXPECT_FALSE(ledger.configure(zero_width));
  EXPECT_FALSE(ledger.valid());

  FrameLedgerConfig zero_height;
  zero_height.height = 0;
  EXPECT_FALSE(ledger.configure(zero_height));

  FrameLedgerConfig odd_tile;
  odd_tile.tile_px = 12; // not a multiple of 8
  EXPECT_FALSE(ledger.configure(odd_tile));

  FrameLedgerConfig huge_tile;
  huge_tile.tile_px = 128; // > kMaxTilePx
  EXPECT_FALSE(ledger.configure(huge_tile));

  // Recovers when handed a usable geometry again.
  EXPECT_TRUE(ledger.configure(FrameLedgerConfig()));
  EXPECT_TRUE(ledger.valid());
}

TEST(FrameLedgerTest, ConfigureInvalidatesAndFillLevelsOverwrites) {
  FrameLedgerConfig config;
  config.width = 32;
  config.height = 32;
  config.tile_px = 16;
  FrameLedger ledger(config);
  ASSERT_TRUE(ledger.valid());
  for (size_t i = 0; i < ledger.l_cur_size(); ++i) {
    ASSERT_EQ(ledger.l_cur()[i], pluto::kInvalidLevel5) << "i=" << i;
  }

  ledger.fill_levels(pluto::kWhiteLevel5);
  for (size_t i = 0; i < ledger.l_cur_size(); ++i) {
    ASSERT_EQ(ledger.l_cur()[i], pluto::kWhiteLevel5) << "i=" << i;
  }

  ledger.l_cur()[5] = 4;
  ledger.chroma_bits()[0] = 0xff;
  ledger.stats()[0].changed_px = 7;
  ledger.row_hash_cur()[0] = 123u;
  ledger.invalidate();
  EXPECT_EQ(ledger.l_cur()[5], pluto::kInvalidLevel5);
  EXPECT_EQ(ledger.chroma_bits()[0], 0);
  EXPECT_EQ(ledger.stats()[0].changed_px, 0);
  EXPECT_EQ(ledger.row_hash_cur()[0], 0u);
}

TEST(FrameLedgerTest, ChromaBitAccessorIsLsbFirst) {
  FrameLedgerConfig config;
  config.width = 16;
  config.height = 8;
  config.tile_px = 8;
  FrameLedger ledger(config);
  ASSERT_TRUE(ledger.valid());
  // Row 2, byte 1, bit 3 => pixel x = 11, y = 2.
  ledger.chroma_bits()[2 * ledger.chroma_stride() + 1] = 1u << 3;
  EXPECT_TRUE(ledger.chroma_at(11, 2));
  EXPECT_FALSE(ledger.chroma_at(10, 2));
  EXPECT_FALSE(ledger.chroma_at(11, 1));
}

TEST(FrameLedgerTest, BeginPassAdvancesEpochAndCarriesRowHashes) {
  FrameLedgerConfig config;
  config.width = 16;
  config.height = 4;
  config.tile_px = 8;
  FrameLedger ledger(config);
  ASSERT_TRUE(ledger.valid());
  EXPECT_EQ(ledger.epoch(), 0u);

  EXPECT_EQ(ledger.begin_pass(), 1u);
  ledger.row_hash_cur()[2] = 0xabcd1234u;

  EXPECT_EQ(ledger.begin_pass(), 2u);
  // Carried forward into the new current buffer, and visible as prev.
  EXPECT_EQ(ledger.row_hash_cur()[2], 0xabcd1234u);
  EXPECT_EQ(ledger.row_hash_prev()[2], 0xabcd1234u);

  ledger.row_hash_cur()[2] = 0x5555aaaau;
  EXPECT_EQ(ledger.row_hash_prev()[2], 0xabcd1234u);

  EXPECT_EQ(ledger.begin_pass(), 3u);
  EXPECT_EQ(ledger.row_hash_prev()[2], 0x5555aaaau);
  EXPECT_EQ(ledger.row_hash_cur()[2], 0x5555aaaau);
}

TEST(FrameLedgerTest, PersistentStateRoundTripsEveryMirrorTransactionally) {
  FrameLedgerConfig config;
  config.width = 16;
  config.height = 16;
  config.tile_px = 8;
  FrameLedger source(config);
  ASSERT_TRUE(source.valid());
  ASSERT_EQ(source.begin_pass(), 1u);
  source.row_hash_cur()[3] = 0x11111111u;
  ASSERT_EQ(source.begin_pass(), 2u);
  source.row_hash_cur()[3] = 0x22222222u;
  for (size_t i = 0; i < source.l_cur_size(); ++i) {
    source.l_cur()[i] = static_cast<uint8_t>((i % 16u) * 2u);
  }
  source.chroma_bits()[source.chroma_stride() + 1] = 0xa5u;
  source.row_sample_slot(8)[4] = 12u;
  source.mark_row_sample(8);
  source.stats()[1].changed_px = 7;
  source.stats()[1].level_hist_lo = 3;
  source.stats()[1].motion_class = pluto::kMotionTranslating;
  source.stats()[1].changed_chroma = 1;
  source.stats()[1].dirty = PlutoRect{8, 0, 7, 1};
  source.stats()[1].epoch = source.epoch();

  FrameLedgerState expected;
  ASSERT_TRUE(source.export_state(&expected));
  FrameLedger destination(config);
  ASSERT_TRUE(destination.import_state(expected));

  FrameLedgerState actual;
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_EQ(actual.epoch, expected.epoch);
  EXPECT_EQ(actual.cur_hash, expected.cur_hash);
  EXPECT_TRUE(actual.levels == expected.levels);
  EXPECT_TRUE(actual.chroma_bits == expected.chroma_bits);
  EXPECT_TRUE(actual.row_hash == expected.row_hash);
  EXPECT_TRUE(actual.row_samples == expected.row_samples);
  EXPECT_TRUE(actual.row_sample_epoch == expected.row_sample_epoch);
  ASSERT_EQ(actual.stats.size(), expected.stats.size());
  EXPECT_EQ(actual.stats[1].changed_px, 7u);
  EXPECT_EQ(actual.stats[1].changed_chroma, 1u);
  EXPECT_EQ(actual.stats[1].dirty.x, 8);

  const std::vector<uint8_t> before = actual.levels;
  FrameLedgerState corrupt = expected;
  corrupt.levels[0] = 42u;
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = expected;
  corrupt.row_hash[0].pop_back();
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = expected;
  corrupt.config.width += 1;
  EXPECT_FALSE(destination.import_state(corrupt));
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_TRUE(actual.levels == before) << "failed imports mutated live state";
}
