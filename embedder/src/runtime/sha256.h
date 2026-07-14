#ifndef PLUTO_RUNTIME_SHA256_H_
#define PLUTO_RUNTIME_SHA256_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>

namespace pluto {

inline constexpr std::size_t kSha256DigestBytes = 32;

// Returns the SHA-256 digest of bytes. The implementation is self-contained so
// target builds do not acquire an OpenSSL or other crypto-library dependency.
std::array<std::uint8_t, kSha256DigestBytes>
sha256(std::span<const std::uint8_t> bytes);

// Returns the digest as exactly 64 lowercase hexadecimal characters.
std::string sha256_hex(std::span<const std::uint8_t> bytes);

} // namespace pluto

#endif // PLUTO_RUNTIME_SHA256_H_
