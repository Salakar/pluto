#ifndef PLUTO_PRESENTER_SWTCON_DRIVE_PIXEL_OP_H_
#define PLUTO_PRESENTER_SWTCON_DRIVE_PIXEL_OP_H_

#include <cstdint>

namespace pluto::swtcon {

// One wire-facing drive deposit.  The explicit reserved byte keeps the
// representation deterministic for the AArch64 packed emitter and lets the
// grayscale and Xochitl-mapped sweep paths share the row sink without a copy.
struct DrivePixelOp {
  std::uint16_t x = 0;
  std::uint8_t code = 0;
  std::uint8_t reserved = 0;
};

static_assert(sizeof(DrivePixelOp) == 4);
static_assert(alignof(DrivePixelOp) == 2);

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_DRIVE_PIXEL_OP_H_
