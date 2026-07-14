#include <gtest/gtest.h>

#include <cstdint>
#include <span>
#include <string>
#include <vector>

#include "runtime/sha256.h"

namespace {

TEST(Sha256Test, MatchesPublishedEmptyAndAbcVectors) {
  const std::vector<uint8_t> empty;
  EXPECT_EQ(pluto::sha256_hex(std::span<const uint8_t>(empty)),
            "e3b0c44298fc1c149afbf4c8996fb924"
            "27ae41e4649b934ca495991b7852b855");

  const std::string abc = "abc";
  const auto bytes = std::span<const uint8_t>(
      reinterpret_cast<const uint8_t *>(abc.data()), abc.size());
  EXPECT_EQ(pluto::sha256_hex(bytes), "ba7816bf8f01cfea414140de5dae2223"
                                      "b00361a396177a9cb410ff61f20015ad");
}

TEST(Sha256Test, HandlesASecondPaddingBlock) {
  const std::vector<uint8_t> bytes(56u, static_cast<uint8_t>('a'));
  EXPECT_EQ(pluto::sha256_hex(std::span<const uint8_t>(bytes)),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f"
            "590ce20f1bde7090ef7970686ec6738a");
}

} // namespace
