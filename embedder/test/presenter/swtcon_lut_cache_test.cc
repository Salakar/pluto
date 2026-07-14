#include <gtest/gtest.h>

#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "presenter/swtcon/lut_cache.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "swtcon_eink_synth.h"

namespace {

using pluto::swtcon::kGrayStates;
using pluto::swtcon::kWaveformMatrixCells;
using pluto::swtcon::LutCache;
using pluto::swtcon::LutRecord;
using pluto::swtcon::WaveformTable;

WaveformTable parse_synthetic(int phases = 3) {
  WaveformTable table;
  std::string error;
  const bool ok =
      table.parse(swtcon_synth::make_synthetic_eink(phases), &error);
  EXPECT_TRUE(ok) << error;
  return table;
}

std::string fixture_path() {
#ifdef PLUTO_SWTCON_EINK_FIXTURE
  return PLUTO_SWTCON_EINK_FIXTURE;
#else
  return {};
#endif
}

TEST(LutCacheTest, ExpansionMatchesWaveformTableCodeAcrossAllCells) {
  const WaveformTable table = parse_synthetic(3);
  LutCache cache(&table);

  // Golden cross-check of the decoder-native orientation: for every phase
  // and every (prev, next) pair, LutRecord::code must equal the decoder's
  // WaveformTable::code (which indexes dst*32+src itself).
  for (int bin = 0; bin < table.temp_count(); ++bin) {
    const LutRecord* record = cache.get(2, bin);
    ASSERT_NE(record, nullptr);
    ASSERT_EQ(record->phase_count, table.phase_count(2, bin));
    for (int phase = 0; phase < record->phase_count; ++phase) {
      for (int prev = 0; prev < kGrayStates; ++prev) {
        for (int next = 0; next < kGrayStates; ++next) {
          const std::uint8_t expected =
              table.code(2, bin, static_cast<std::uint8_t>(prev),
                         static_cast<std::uint8_t>(next), phase);
          const std::uint8_t actual =
              record->code(phase, static_cast<std::uint8_t>(prev),
                           static_cast<std::uint8_t>(next));
          ASSERT_EQ(actual, expected) << "bin=" << bin << " phase=" << phase
                                      << " prev=" << prev << " next=" << next;
        }
      }
    }
  }
}

TEST(LutCacheTest, NonholdCountAndImpulseBoundMetadata) {
  const WaveformTable table = parse_synthetic(3);
  LutCache cache(&table);

  // Synthetic mode 2: code(cell, phase) = (cell + phase) % 7 — per phase,
  // cells where (cell + phase) % 7 == 0 hold; the rest drive.
  const LutRecord* mode2 = cache.get(2, 0);
  ASSERT_NE(mode2, nullptr);
  for (int phase = 0; phase < mode2->phase_count; ++phase) {
    std::uint16_t holds = 0;
    for (int cell = 0; cell < kWaveformMatrixCells; ++cell) {
      if (swtcon_synth::synthetic_mode2_code(cell, phase) == 0) {
        ++holds;
      }
    }
    EXPECT_EQ(mode2->nonhold_count[static_cast<std::size_t>(phase)],
              kWaveformMatrixCells - holds)
        << "phase=" << phase;
    EXPECT_EQ(mode2->impulse_bound[static_cast<std::size_t>(phase)], 1)
        << "phase=" << phase;
  }

  // Synthetic modes 0/1 share an all-hold record: zero cost, zero impulse.
  const LutRecord* hold = cache.get(0, 0);
  ASSERT_NE(hold, nullptr);
  ASSERT_EQ(hold->phase_count, 1);
  EXPECT_EQ(hold->nonhold_count[0], 0);
  EXPECT_EQ(hold->impulse_bound[0], 0);
}

TEST(LutCacheTest, MissingRecordReturnsNull) {
  const WaveformTable table = parse_synthetic(3);
  LutCache cache(&table);
  EXPECT_EQ(cache.get(99, 0), nullptr);
  EXPECT_EQ(cache.get(2, 99), nullptr);
  EXPECT_EQ(cache.pin(99, 0), nullptr);
  EXPECT_EQ(cache.peek(2, 0), nullptr);  // peek never expands
}

TEST(LutCacheTest, LruEvictsOldestUnpinnedAtCapacity) {
  const WaveformTable table = parse_synthetic(3);
  LutCache::Config config;
  config.capacity = 2;
  LutCache cache(&table, config);

  ASSERT_NE(cache.get(0, 0), nullptr);  // t1
  ASSERT_NE(cache.get(1, 0), nullptr);  // t2
  EXPECT_EQ(cache.resident_count(), 2u);

  // Touch (0,0) so (1,0) becomes LRU, then force an eviction.
  ASSERT_NE(cache.get(0, 0), nullptr);  // t3
  ASSERT_NE(cache.get(2, 0), nullptr);  // evicts (1,0)
  EXPECT_EQ(cache.resident_count(), 2u);
  EXPECT_TRUE(cache.resident(0, 0));
  EXPECT_FALSE(cache.resident(1, 0));
  EXPECT_TRUE(cache.resident(2, 0));
  EXPECT_EQ(cache.evictions(), 1u);
}

TEST(LutCacheTest, PinnedRecordsAreNeverEvicted) {
  const WaveformTable table = parse_synthetic(3);
  LutCache::Config config;
  config.capacity = 1;
  LutCache cache(&table, config);

  const LutRecord* pinned = cache.pin(2, 0);
  ASSERT_NE(pinned, nullptr);
  EXPECT_EQ(cache.pin_refcount(2, 0), 1);

  // At capacity with everything pinned: the cache grows past capacity
  // rather than evicting the pinned record or failing the expansion.
  const LutRecord* other = cache.get(2, 1);
  ASSERT_NE(other, nullptr);
  EXPECT_TRUE(cache.resident(2, 0));
  EXPECT_TRUE(cache.resident(2, 1));
  EXPECT_EQ(cache.resident_count(), 2u);

  // The pinned record survives further pressure; unpinned LRU goes first.
  ASSERT_NE(cache.get(0, 0), nullptr);
  EXPECT_TRUE(cache.resident(2, 0));
  EXPECT_FALSE(cache.resident(2, 1));

  // Refcount semantics: pin twice, unpin once — still protected.
  ASSERT_NE(cache.pin(2, 0), nullptr);
  EXPECT_EQ(cache.pin_refcount(2, 0), 2);
  cache.unpin(2, 0);
  EXPECT_EQ(cache.pin_refcount(2, 0), 1);
  ASSERT_NE(cache.get(1, 0), nullptr);
  EXPECT_TRUE(cache.resident(2, 0));

  // Fully unpinned records become evictable again.
  cache.unpin(2, 0);
  EXPECT_EQ(cache.pin_refcount(2, 0), 0);
  ASSERT_NE(cache.get(2, 1), nullptr);
  EXPECT_FALSE(cache.resident(2, 0));
}

TEST(LutCacheTest, RealPanelEinkGoldenSamples) {
  const std::string path = fixture_path();
  std::vector<std::uint8_t> bytes;
  {
    std::ifstream in(path, std::ios::binary);
    if (in) {
      bytes.assign(std::istreambuf_iterator<char>(in),
                   std::istreambuf_iterator<char>());
    }
  }
  if (bytes.empty()) {
    const std::string message =
        "panel .eink golden fixture missing: " + path +
        " — the LutCache golden cross-check DID NOT RUN (see "
        "SwtconWaveformTest.DecodesRealPanelEinkGolden for how to obtain "
        "the fixture).";
#ifdef GTEST_SKIP
    GTEST_SKIP() << message;
#else
    std::cerr << "[  SKIPPED ] LutCacheTest.RealPanelEinkGoldenSamples: "
              << message << "\n";
    return;
#endif
  }

  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(bytes, &error)) << error;

  LutCache cache(&table);
  // Proven mode set {Fast/Ui->7, Text->1, Full->2} across a cool, the
  // 25 C, and the warmest bin; every phase, sampled (prev, next) grid.
  const int modes[] = {1, 2, 7};
  const int bins[] = {0, table.temp_bin(25.0f), table.temp_count() - 1};
  for (const int mode : modes) {
    for (const int bin : bins) {
      const LutRecord* record = cache.get(mode, bin);
      ASSERT_NE(record, nullptr) << "mode=" << mode << " bin=" << bin;
      ASSERT_EQ(record->phase_count, table.phase_count(mode, bin));
      for (int phase = 0; phase < record->phase_count; ++phase) {
        for (int prev = 0; prev < kGrayStates; prev += 3) {
          for (int next = 0; next < kGrayStates; next += 3) {
            ASSERT_EQ(record->code(phase, static_cast<std::uint8_t>(prev),
                                   static_cast<std::uint8_t>(next)),
                      table.code(mode, bin, static_cast<std::uint8_t>(prev),
                                 static_cast<std::uint8_t>(next), phase))
                << "mode=" << mode << " bin=" << bin << " phase=" << phase
                << " prev=" << prev << " next=" << next;
          }
        }
      }
      // The cache never holds more than its capacity of unpinned records.
      EXPECT_LE(cache.resident_count(), 4u);
    }
  }
}

}  // namespace
