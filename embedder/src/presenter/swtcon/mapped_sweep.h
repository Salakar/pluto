#ifndef PLUTO_PRESENTER_SWTCON_MAPPED_SWEEP_H_
#define PLUTO_PRESENTER_SWTCON_MAPPED_SWEEP_H_

#include <cstdint>

#include "presenter/swtcon/drive_pixel_op.h"

// Standalone sweep kernel for an already-mapped source->drive plane.
//
// Unlike PixelEngine's grayscale sweep, this kernel does not own or mutate a
// logical source/target history.  Its immutable transition words are produced
// by the Xochitl-compatible mapper and remain stable for the complete waveform
// record.  Completion is reported through fnum/terminal only; the owner may
// commit logical history after the scan fence that resolves that operation.

namespace pluto::swtcon {

inline constexpr std::uint8_t kMappedSweepIdle = 0xff;

// API name retained for the standalone mapper tests.  Both sweep paths share
// the exact same representation, so mapped rows can enter RowEmitter without
// an O(width) adapter copy.
using MappedPixelOp = DrivePixelOp;

struct MappedSweepArgs {
  // One immutable 10-bit word per lane in mapper orientation:
  //   bits 9..5 = logical source, bits 4..0 = selected drive state.
  // The waveform record uses decoder orientation [drive][source]; the kernel
  // performs that transpose while gathering each phase code.
  const std::uint16_t* transitions = nullptr;

  // Per-lane phase cursor.  0..phase_count-1 is active; 0xff is idle.
  std::uint8_t* fnum = nullptr;
  // Per-lane signed DC ledger, maintained with saturating charge.
  std::int8_t* dc = nullptr;
  // Per-call completion marks.  Every lane in the segment is overwritten:
  // one exactly when that active lane finishes this call, zero otherwise.
  std::uint8_t* terminal = nullptr;

  int x0 = 0;
  int count = 0;

  // Complete phase-major waveform record:
  //   codes[phase * 1024 + drive * 32 + source].
  const std::uint8_t* codes = nullptr;
  // Legal production records contain 1..255 phases (0xff is the idle cursor).
  int phase_count = 0;
  // Eight signed impulses, indexed by (code & 7).  Entry zero is charged too;
  // the summary deliberately excludes hold code zero, matching the presenter
  // ledger/summary split.
  const std::int8_t* impulse_map = nullptr;
  // Non-negative symmetric clamp for the DC plane.
  std::int8_t dc_cap = 0;
};

struct MappedSweepResult {
  std::uint32_t emitted = 0;
  std::uint32_t completed = 0;
  std::uint32_t saturations = 0;
  std::int32_t impulse = 0;
  bool drove = false;
};

// Allocation-free scalar reference.  `ops` has capacity for at least `count`
// entries.  Active lanes append exactly one op in ascending x order, including
// identity transitions and code-zero holds.
MappedSweepResult mapped_sweep_scalar(const MappedSweepArgs& args,
                                      MappedPixelOp* ops);

#if defined(__ARM_NEON) && defined(__aarch64__)
// AArch64 fast path; byte-identical to mapped_sweep_scalar for all outputs.
MappedSweepResult mapped_sweep_neon(const MappedSweepArgs& args,
                                    MappedPixelOp* ops);
#endif

inline MappedSweepResult mapped_sweep(const MappedSweepArgs& args,
                                      MappedPixelOp* ops) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  return mapped_sweep_neon(args, ops);
#else
  return mapped_sweep_scalar(args, ops);
#endif
}

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_MAPPED_SWEEP_H_
