#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "presenter/png_encoder.h"

namespace {

uint32_t read_be32(const uint8_t *bytes) {
  return (static_cast<uint32_t>(bytes[0]) << 24u) |
         (static_cast<uint32_t>(bytes[1]) << 16u) |
         (static_cast<uint32_t>(bytes[2]) << 8u) |
         static_cast<uint32_t>(bytes[3]);
}

std::vector<uint8_t> decode_stored_rgba(const std::vector<uint8_t> &png,
                                        uint32_t *width, uint32_t *height,
                                        size_t *deflate_blocks = nullptr) {
  static constexpr uint8_t kSignature[] = {0x89, 'P',  'N',  'G',
                                           '\r', '\n', 0x1a, '\n'};
  if (png.size() < sizeof(kSignature) ||
      std::memcmp(png.data(), kSignature, sizeof(kSignature)) != 0) {
    return {};
  }

  std::vector<uint8_t> zlib;
  size_t offset = sizeof(kSignature);
  while (offset + 12u <= png.size()) {
    const uint32_t length = read_be32(png.data() + offset);
    if (offset + 12u + length > png.size()) {
      return {};
    }
    const uint8_t *type = png.data() + offset + 4u;
    const uint8_t *data = type + 4u;
    if (std::memcmp(type, "IHDR", 4) == 0 && length == 13u) {
      *width = read_be32(data);
      *height = read_be32(data + 4u);
    } else if (std::memcmp(type, "IDAT", 4) == 0) {
      zlib.insert(zlib.end(), data, data + length);
    }
    offset += 12u + length;
  }
  if (zlib.size() < 6u || zlib[0] != 0x78u) {
    return {};
  }

  std::vector<uint8_t> raw;
  size_t z = 2u;
  size_t blocks = 0;
  bool final = false;
  while (!final) {
    if (z + 5u > zlib.size() - 4u) {
      return {};
    }
    const uint8_t header = zlib[z++];
    final = (header & 1u) != 0;
    if ((header & 0xfeu) != 0u) {
      return {};
    }
    const uint16_t length = static_cast<uint16_t>(zlib[z]) |
                            (static_cast<uint16_t>(zlib[z + 1u]) << 8u);
    const uint16_t inverse = static_cast<uint16_t>(zlib[z + 2u]) |
                             (static_cast<uint16_t>(zlib[z + 3u]) << 8u);
    z += 4u;
    if (static_cast<uint16_t>(~length) != inverse ||
        z + length > zlib.size() - 4u) {
      return {};
    }
    raw.insert(raw.end(), zlib.begin() + static_cast<std::ptrdiff_t>(z),
               zlib.begin() + static_cast<std::ptrdiff_t>(z + length));
    z += length;
    ++blocks;
  }
  if (deflate_blocks != nullptr) {
    *deflate_blocks = blocks;
  }

  const size_t row_bytes = 1u + static_cast<size_t>(*width) * 4u;
  if (*width == 0 || *height == 0 || raw.size() != row_bytes * *height) {
    return {};
  }
  std::vector<uint8_t> rgba;
  rgba.reserve(static_cast<size_t>(*width) * *height * 4u);
  for (uint32_t y = 0; y < *height; ++y) {
    const size_t row = static_cast<size_t>(y) * row_bytes;
    if (raw[row] != 0u) {
      return {};
    }
    rgba.insert(rgba.end(), raw.begin() + static_cast<std::ptrdiff_t>(row + 1u),
                raw.begin() + static_cast<std::ptrdiff_t>(row + row_bytes));
  }
  return rgba;
}

void expect_bytes(const std::vector<uint8_t> &actual,
                  const std::vector<uint8_t> &expected) {
  ASSERT_EQ(actual.size(), expected.size());
  for (size_t i = 0; i < expected.size(); ++i) {
    EXPECT_EQ(actual[i], expected[i]) << "byte " << i;
  }
}

TEST(PngEncoderTest, PreservesDynamicRgb565SurfaceAndPaddedStride) {
  // 3x2 is deliberately not a device profile size. Each row has two bytes of
  // padding so the encoder must honor the live stride metadata.
  const std::vector<uint8_t> pixels = {
      0x00, 0xf8, 0xe0, 0x07, 0x1f, 0x00, 0xaa, 0xbb,
      0x00, 0x00, 0xff, 0xff, 0x10, 0x84, 0xcc, 0xdd,
  };
  std::vector<uint8_t> png;
  ASSERT_TRUE(
      pluto::encode_png(pixels.data(), 3, 2, 8, kPlutoPixelFormatRgb565, &png));

  uint32_t width = 0;
  uint32_t height = 0;
  const std::vector<uint8_t> rgba = decode_stored_rgba(png, &width, &height);
  EXPECT_EQ(width, 3u);
  EXPECT_EQ(height, 2u);
  expect_bytes(rgba, {
                         255, 0, 0, 255, 0,   255, 0,   255, 0,   0,   255, 255,
                         0,   0, 0, 255, 255, 255, 255, 255, 132, 130, 132, 255,
                     });
}

TEST(PngEncoderTest, EncodesGray8AndXrgb8888) {
  const std::vector<uint8_t> gray = {0, 127, 255};
  std::vector<uint8_t> png;
  ASSERT_TRUE(
      pluto::encode_png(gray.data(), 3, 1, 3, kPlutoPixelFormatGray8, &png));
  uint32_t width = 0;
  uint32_t height = 0;
  expect_bytes(decode_stored_rgba(png, &width, &height),
               {0, 0, 0, 255, 127, 127, 127, 255, 255, 255, 255, 255});

  const std::vector<uint8_t> xrgb = {0, 11, 22, 33, 0, 44, 55, 66};
  ASSERT_TRUE(
      pluto::encode_png(xrgb.data(), 2, 1, 8, kPlutoPixelFormatXrgb8888, &png));
  expect_bytes(decode_stored_rgba(png, &width, &height),
               {11, 22, 33, 255, 44, 55, 66, 255});
}

TEST(PngEncoderTest, SplitsLargeDynamicRowsIntoStoredDeflateBlocks) {
  constexpr int32_t kWidth = 20'000;
  const std::vector<uint8_t> gray(static_cast<size_t>(kWidth), 42u);
  std::vector<uint8_t> png;
  ASSERT_TRUE(pluto::encode_png(gray.data(), kWidth, 1, gray.size(),
                                kPlutoPixelFormatGray8, &png));
  uint32_t width = 0;
  uint32_t height = 0;
  size_t blocks = 0;
  const std::vector<uint8_t> rgba =
      decode_stored_rgba(png, &width, &height, &blocks);
  EXPECT_EQ(width, static_cast<uint32_t>(kWidth));
  EXPECT_EQ(height, 1u);
  EXPECT_GT(blocks, 1u);
  EXPECT_EQ(rgba.size(), static_cast<size_t>(kWidth) * 4u);
}

TEST(PngEncoderTest, RejectsInvalidSurfacesAndClearsOutput) {
  const uint8_t pixel[] = {0, 0};
  std::vector<uint8_t> png = {1, 2, 3};
  std::string error;
  EXPECT_FALSE(
      pluto::encode_png(pixel, 1, 1, 1, kPlutoPixelFormatRgb565, &png, &error));
  EXPECT_TRUE(png.empty());
  EXPECT_FALSE(error.empty());

  png = {1};
  EXPECT_FALSE(pluto::encode_png(nullptr, 1, 1, 2, kPlutoPixelFormatRgb565,
                                 &png, &error));
  EXPECT_TRUE(png.empty());
  EXPECT_FALSE(
      pluto::encode_png(pixel, 0, 1, 2, kPlutoPixelFormatRgb565, &png, &error));
  EXPECT_FALSE(pluto::encode_png(pixel, 1, -1, 2, kPlutoPixelFormatRgb565, &png,
                                 &error));
}

} // namespace
