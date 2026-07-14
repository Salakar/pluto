#include "compositor/backing_store_pool.h"

#include "gtest/gtest.h"

namespace {

TEST(BackingStorePool, CreatesAlignedRgb565Software2Stores) {
  pluto::BackingStorePool pool(1, kPlutoPixelFormatRgb565);
  FlutterBackingStoreConfig config{};
  config.struct_size = sizeof(config);
  config.size = FlutterSize{13, 7};
  FlutterBackingStore store{};

  ASSERT_TRUE(pool.create(&config, &store));
  EXPECT_EQ(store.type, kFlutterBackingStoreTypeSoftware2);
  EXPECT_EQ(store.software2.pixel_format, kFlutterSoftwarePixelFormatRGB565);
  EXPECT_EQ(store.software2.row_bytes % 64, 0u);
  EXPECT_EQ(pool.active_count(), 1u);
  EXPECT_EQ(pool.allocated_count(), 1u);
}

TEST(BackingStorePool, CollectReusesSlots) {
  pluto::BackingStorePool pool(1, kPlutoPixelFormatGray8);
  FlutterBackingStoreConfig config{};
  config.struct_size = sizeof(config);
  config.size = FlutterSize{16, 16};
  FlutterBackingStore first{};
  FlutterBackingStore second{};

  ASSERT_TRUE(pool.create(&config, &first));
  const void* first_allocation = first.software2.allocation;
  ASSERT_TRUE(pool.collect(&first));
  EXPECT_EQ(pool.active_count(), 0u);
  ASSERT_TRUE(pool.create(&config, &second));
  EXPECT_TRUE(second.software2.allocation == first_allocation);
  EXPECT_EQ(pool.allocated_count(), 1u);
}

}  // namespace
