#include <gtest/gtest.h>

#include "renderer/renderer_config.h"

namespace {

using pluto::RendererConfig;

}  // namespace

TEST(RendererConfigTest, DefaultsMatchDesignTable) {
  const RendererConfig config;
  EXPECT_EQ(config.tile_px, 32u);
  EXPECT_EQ(config.chroma_floor, 12);
  EXPECT_EQ(static_cast<int>(config.dither_mask),
            static_cast<int>(RendererConfig::DitherMask::kBlueNoise64));
}
