#include "runtime/sha256.h"

#include <array>
#include <bit>
#include <cstddef>

namespace pluto {
namespace {

constexpr std::array<std::uint32_t, 64> kRoundConstants = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

void compress(const std::uint8_t *block, std::array<std::uint32_t, 8> *state) {
  std::array<std::uint32_t, 64> words{};
  for (std::size_t index = 0; index < 16; ++index) {
    const std::size_t offset = index * 4;
    words[index] = (static_cast<std::uint32_t>(block[offset]) << 24u) |
                   (static_cast<std::uint32_t>(block[offset + 1]) << 16u) |
                   (static_cast<std::uint32_t>(block[offset + 2]) << 8u) |
                   static_cast<std::uint32_t>(block[offset + 3]);
  }
  for (std::size_t index = 16; index < words.size(); ++index) {
    const std::uint32_t s0 = std::rotr(words[index - 15], 7) ^
                             std::rotr(words[index - 15], 18) ^
                             (words[index - 15] >> 3u);
    const std::uint32_t s1 = std::rotr(words[index - 2], 17) ^
                             std::rotr(words[index - 2], 19) ^
                             (words[index - 2] >> 10u);
    words[index] = words[index - 16] + s0 + words[index - 7] + s1;
  }

  std::uint32_t a = (*state)[0];
  std::uint32_t b = (*state)[1];
  std::uint32_t c = (*state)[2];
  std::uint32_t d = (*state)[3];
  std::uint32_t e = (*state)[4];
  std::uint32_t f = (*state)[5];
  std::uint32_t g = (*state)[6];
  std::uint32_t h = (*state)[7];
  for (std::size_t index = 0; index < words.size(); ++index) {
    const std::uint32_t sigma1 =
        std::rotr(e, 6) ^ std::rotr(e, 11) ^ std::rotr(e, 25);
    const std::uint32_t choose = (e & f) ^ ((~e) & g);
    const std::uint32_t temporary1 =
        h + sigma1 + choose + kRoundConstants[index] + words[index];
    const std::uint32_t sigma0 =
        std::rotr(a, 2) ^ std::rotr(a, 13) ^ std::rotr(a, 22);
    const std::uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    const std::uint32_t temporary2 = sigma0 + majority;
    h = g;
    g = f;
    f = e;
    e = d + temporary1;
    d = c;
    c = b;
    b = a;
    a = temporary1 + temporary2;
  }
  (*state)[0] += a;
  (*state)[1] += b;
  (*state)[2] += c;
  (*state)[3] += d;
  (*state)[4] += e;
  (*state)[5] += f;
  (*state)[6] += g;
  (*state)[7] += h;
}

} // namespace

std::array<std::uint8_t, kSha256DigestBytes>
sha256(std::span<const std::uint8_t> bytes) {
  std::array<std::uint32_t, 8> state = {
      0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
      0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
  };

  std::size_t offset = 0;
  while (bytes.size() - offset >= 64) {
    compress(bytes.data() + offset, &state);
    offset += 64;
  }

  std::array<std::uint8_t, 128> tail{};
  const std::size_t remaining = bytes.size() - offset;
  for (std::size_t index = 0; index < remaining; ++index) {
    tail[index] = bytes[offset + index];
  }
  tail[remaining] = 0x80u;
  const std::size_t padded_size = remaining < 56 ? 64 : 128;
  const std::uint64_t bit_length =
      static_cast<std::uint64_t>(bytes.size()) * 8u;
  for (std::size_t index = 0; index < 8; ++index) {
    tail[padded_size - 1 - index] =
        static_cast<std::uint8_t>(bit_length >> (index * 8u));
  }
  compress(tail.data(), &state);
  if (padded_size == 128) {
    compress(tail.data() + 64, &state);
  }

  std::array<std::uint8_t, kSha256DigestBytes> digest{};
  for (std::size_t word = 0; word < state.size(); ++word) {
    for (std::size_t byte = 0; byte < 4; ++byte) {
      digest[word * 4 + byte] = static_cast<std::uint8_t>(
          state[word] >> static_cast<unsigned>((3 - byte) * 8));
    }
  }
  return digest;
}

std::string sha256_hex(std::span<const std::uint8_t> bytes) {
  constexpr char kHex[] = "0123456789abcdef";
  const auto digest = sha256(bytes);
  std::string result;
  result.resize(digest.size() * 2);
  for (std::size_t index = 0; index < digest.size(); ++index) {
    result[index * 2] = kHex[digest[index] >> 4u];
    result[index * 2 + 1] = kHex[digest[index] & 0x0fu];
  }
  return result;
}

} // namespace pluto
