#include "presenter/png_encoder.h"

#include <algorithm>
#include <array>
#include <limits>

namespace pluto {
namespace {

void set_error(std::string *error, const char *message) {
  if (error != nullptr) {
    *error = message;
  }
}

std::size_t bytes_per_pixel(PlutoPixelFormat format) {
  switch (format) {
  case kPlutoPixelFormatGray8:
    return 1;
  case kPlutoPixelFormatXrgb8888:
    return 4;
  case kPlutoPixelFormatRgb565:
    return 2;
  }
  return 0;
}

void rgba_from_pixel(PlutoPixelFormat format, const std::uint8_t *pixel,
                     std::uint8_t *out) {
  if (format == kPlutoPixelFormatGray8) {
    out[0] = pixel[0];
    out[1] = pixel[0];
    out[2] = pixel[0];
    out[3] = 255;
    return;
  }
  if (format == kPlutoPixelFormatXrgb8888) {
    out[0] = pixel[1];
    out[1] = pixel[2];
    out[2] = pixel[3];
    out[3] = 255;
    return;
  }
  const std::uint32_t value = static_cast<std::uint32_t>(pixel[0]) |
                              (static_cast<std::uint32_t>(pixel[1]) << 8u);
  const std::uint8_t r5 = static_cast<std::uint8_t>((value >> 11u) & 0x1fu);
  const std::uint8_t g6 = static_cast<std::uint8_t>((value >> 5u) & 0x3fu);
  const std::uint8_t b5 = static_cast<std::uint8_t>(value & 0x1fu);
  out[0] = static_cast<std::uint8_t>((r5 << 3u) | (r5 >> 2u));
  out[1] = static_cast<std::uint8_t>((g6 << 2u) | (g6 >> 4u));
  out[2] = static_cast<std::uint8_t>((b5 << 3u) | (b5 >> 2u));
  out[3] = 255;
}

std::uint32_t crc32_update(std::uint32_t crc, const std::uint8_t *data,
                           std::size_t size) {
  crc = ~crc;
  for (std::size_t i = 0; i < size; ++i) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1u) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
  }
  return ~crc;
}

std::uint32_t adler32(const std::uint8_t *data, std::size_t size) {
  std::uint32_t a = 1;
  std::uint32_t b = 0;
  for (std::size_t i = 0; i < size; ++i) {
    a = (a + data[i]) % 65521u;
    b = (b + a) % 65521u;
  }
  return (b << 16u) | a;
}

void append_be32(std::vector<std::uint8_t> *out, std::uint32_t value) {
  out->push_back(static_cast<std::uint8_t>((value >> 24u) & 0xffu));
  out->push_back(static_cast<std::uint8_t>((value >> 16u) & 0xffu));
  out->push_back(static_cast<std::uint8_t>((value >> 8u) & 0xffu));
  out->push_back(static_cast<std::uint8_t>(value & 0xffu));
}

void append_le16(std::vector<std::uint8_t> *out, std::uint16_t value) {
  out->push_back(static_cast<std::uint8_t>(value & 0xffu));
  out->push_back(static_cast<std::uint8_t>((value >> 8u) & 0xffu));
}

void append_chunk(std::vector<std::uint8_t> *png, const char type[4],
                  const std::vector<std::uint8_t> &data) {
  append_be32(png, static_cast<std::uint32_t>(data.size()));
  const std::size_t type_offset = png->size();
  png->insert(png->end(), type, type + 4);
  png->insert(png->end(), data.begin(), data.end());
  const std::uint32_t crc =
      crc32_update(0, png->data() + type_offset, png->size() - type_offset);
  append_be32(png, crc);
}

std::vector<std::uint8_t> zlib_store(const std::vector<std::uint8_t> &raw) {
  std::vector<std::uint8_t> out;
  out.reserve(raw.size() + raw.size() / 65535u * 5u + 16u);
  out.push_back(0x78);
  out.push_back(0x01);
  std::size_t offset = 0;
  while (offset < raw.size()) {
    const std::size_t remaining = raw.size() - offset;
    const std::uint16_t block =
        static_cast<std::uint16_t>(std::min<std::size_t>(remaining, 65535u));
    const bool final = offset + block == raw.size();
    out.push_back(final ? 0x01 : 0x00);
    append_le16(&out, block);
    append_le16(&out, static_cast<std::uint16_t>(~block));
    out.insert(out.end(), raw.begin() + static_cast<std::ptrdiff_t>(offset),
               raw.begin() + static_cast<std::ptrdiff_t>(offset + block));
    offset += block;
  }
  append_be32(&out, adler32(raw.data(), raw.size()));
  return out;
}

} // namespace

bool encode_png(const std::uint8_t *pixels, std::int32_t width,
                std::int32_t height, std::size_t stride,
                PlutoPixelFormat format, std::vector<std::uint8_t> *out,
                std::string *error) {
  if (out != nullptr) {
    out->clear();
  }
  if (out == nullptr || pixels == nullptr || width <= 0 || height <= 0) {
    set_error(error, "invalid PNG surface");
    return false;
  }
  const std::size_t bpp = bytes_per_pixel(format);
  if (bpp == 0 ||
      static_cast<std::size_t>(width) >
          std::numeric_limits<std::size_t>::max() / bpp ||
      stride < static_cast<std::size_t>(width) * bpp) {
    set_error(error, "invalid PNG pixel format or stride");
    return false;
  }
  if (static_cast<std::size_t>(height - 1) >
      std::numeric_limits<std::size_t>::max() / stride) {
    set_error(error, "PNG input stride overflows");
    return false;
  }
  const std::size_t row_bytes = 1u + static_cast<std::size_t>(width) * 4u;
  if (static_cast<std::size_t>(height) >
      std::numeric_limits<std::size_t>::max() / row_bytes) {
    set_error(error, "PNG dimensions overflow");
    return false;
  }

  std::vector<std::uint8_t> raw;
  raw.reserve(static_cast<std::size_t>(height) * row_bytes);
  for (std::int32_t y = 0; y < height; ++y) {
    raw.push_back(0);
    const std::uint8_t *row = pixels + static_cast<std::size_t>(y) * stride;
    for (std::int32_t x = 0; x < width; ++x) {
      std::array<std::uint8_t, 4> rgba{};
      rgba_from_pixel(format, row + static_cast<std::size_t>(x) * bpp,
                      rgba.data());
      raw.insert(raw.end(), rgba.begin(), rgba.end());
    }
  }

  std::vector<std::uint8_t> png{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
  std::vector<std::uint8_t> ihdr;
  append_be32(&ihdr, static_cast<std::uint32_t>(width));
  append_be32(&ihdr, static_cast<std::uint32_t>(height));
  ihdr.push_back(8);
  ihdr.push_back(6);
  ihdr.push_back(0);
  ihdr.push_back(0);
  ihdr.push_back(0);
  append_chunk(&png, "IHDR", ihdr);
  append_chunk(&png, "IDAT", zlib_store(raw));
  append_chunk(&png, "IEND", std::vector<std::uint8_t>{});
  *out = std::move(png);
  return true;
}

} // namespace pluto
