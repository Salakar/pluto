#include "input/pen_ring.h"
#include "pluto/pen_ring.h"

#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>

namespace {

void wakeup_counter(void *ctx) {
  auto *count = static_cast<std::atomic<int> *>(ctx);
  count->fetch_add(1);
}

} // namespace

TEST(PlutoPenRingTest, PublicAbiMatchesDoc04Layout) {
  EXPECT_EQ(sizeof(pluto_pen_ring_record), 40u);
  EXPECT_EQ(sizeof(pluto_touch_ring_record), 32u);
  EXPECT_EQ(sizeof(pluto_pen_ring_header), 64u);
  EXPECT_EQ(PLUTO_PEN_RING_RECORD_SIZE, 40u);
  EXPECT_EQ(PLUTO_TOUCH_RING_RECORD_SIZE, 32u);

  const pluto_pen_ring_header *header = pluto_pen_ring();
  ASSERT_TRUE(header != nullptr);
  EXPECT_EQ(header->magic, PLUTO_PEN_RING_MAGIC);
  EXPECT_EQ(header->record_size, PLUTO_PEN_RING_RECORD_SIZE);
  EXPECT_EQ(header->capacity, PLUTO_PEN_RING_DEFAULT_CAPACITY);
  EXPECT_EQ(header->reserved, 0u);
  EXPECT_EQ(offsetof(pluto_pen_ring_header, record_size), 4u);
  EXPECT_EQ(offsetof(pluto_pen_ring_header, capacity), 8u);
  EXPECT_EQ(offsetof(pluto_pen_ring_header, write_index), 16u);

  const auto *records = reinterpret_cast<const pluto_pen_ring_record *>(
      reinterpret_cast<const uint8_t *>(header) +
      sizeof(pluto_pen_ring_header));
  ASSERT_TRUE(records != nullptr);
}

TEST(PlutoPenRingTest, SpscRingPublishesAndAccountsOverwriteHeadroom) {
  pluto::SpscRing<pluto_pen_ring_record> ring(PLUTO_PEN_RING_RECORD_SIZE, 4);
  for (uint32_t i = 0; i < 6; ++i) {
    pluto_pen_ring_record record{};
    record.seq = i;
    record.ts_us = 100 + i;
    ring.push(record);
  }

  EXPECT_EQ(ring.header()->write_index.load(std::memory_order_acquire), 6u);
  EXPECT_EQ(ring.header()->dropped.load(std::memory_order_acquire), 2u);

  uint64_t cursor = 0;
  const std::vector<pluto_pen_ring_record> records = ring.read_from(&cursor);
  ASSERT_EQ(records.size(), 4u);
  EXPECT_EQ(records[0].seq, 2u);
  EXPECT_EQ(records[3].seq, 5u);
  EXPECT_EQ(cursor, 6u);
}

TEST(PlutoPenRingTest, WakeupHookIsCallableFromNativeEdge) {
  std::atomic<int> count{0};
  pluto_ring_set_wakeup(&wakeup_counter, &count);
  pluto::notify_ring_wakeup();
  EXPECT_EQ(count.load(), 1);
  pluto_ring_set_wakeup(nullptr, nullptr);
}
