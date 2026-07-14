#ifndef PLUTO_TEST_PRESENTER_XOCHITL_SELECTOR16_REFERENCE_H_
#define PLUTO_TEST_PRESENTER_XOCHITL_SELECTOR16_REFERENCE_H_

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

// TEST/RESEARCH-ONLY scalar transcription of the installed Xochitl 3.27.1.0
// selector-16 worker at 0x009abc50 and its routing in 0x00b87da0.  This file
// is compiled only into a production-disconnected reference-test executable.
// It is not a production colour selector or a capability gate.
namespace pluto::swtcon::xochitl_selector16_reference {

constexpr std::int32_t kPanelWidth = 960;
constexpr std::int32_t kPanelHeight = 1696;
constexpr std::int32_t kCoarseWidth = kPanelWidth / 4;
constexpr std::int32_t kCoarseHeight = kPanelHeight / 4;

struct InclusiveRect {
  std::int32_t left = 0;
  std::int32_t top = 0;
  std::int32_t right = -1;
  std::int32_t bottom = -1;
};

struct Stripe {
  std::int32_t left = 0;
  std::int32_t top = 0;
  std::int32_t right = -1;
  std::int32_t bottom = -1;

  bool empty() const { return right < left || bottom < top; }
};

enum class StageError : std::uint8_t {
  kNone = 0,
  kInvalidGeometry,
  kInvalidWorker,
  kArgbTooSmall,
};

// The stock object at process address 0x01a19068 owns two zero-initialized
// panel-sized allocations.  Both survive completed updates and are reused.
// coarse holds 4x4 RGB-extreme flags.  selector temporarily holds classes
// 0..4, then the resolve stage overwrites the worker stripe with 0x00/0xff.
struct Scratch {
  Scratch();

  std::uint8_t &coarse_at(std::int32_t x, std::int32_t y);
  const std::uint8_t &coarse_at(std::int32_t x, std::int32_t y) const;
  std::uint8_t &selector_at(std::int32_t x, std::int32_t y);
  const std::uint8_t &selector_at(std::int32_t x, std::int32_t y) const;

  std::vector<std::uint8_t> coarse;
  std::vector<std::uint8_t> selector;
};

struct WorkerPlan {
  std::uint32_t divisor = 1;
  std::vector<Stripe> stripes;
};

// 0x00b87da0 uses one direct worker for requested heights <=29 and queues
// three workers for heights >=30.  The returned stripes are the worker's
// exact outward-16-aligned intervals; a routed stripe can be empty.
WorkerPlan make_worker_plan(InclusiveRect update);

// Exact stage boundaries inside one 0x009abc50 invocation.  Exposing them is
// intentional: the stock three-thread queue has no barrier between stages.
// Calls on different stripes may therefore be interleaved to model concrete,
// legal schedules.  These functions read/write the shared Scratch live; they
// do not take a halo snapshot.
StageError run_coarse_stage(std::span<const std::uint32_t> argb,
                            const Stripe &stripe, Scratch *scratch);
StageError run_classify_stage(std::span<const std::uint32_t> argb,
                              const Stripe &stripe, Scratch *scratch);
StageError run_resolve_stage(std::span<const std::uint32_t> argb,
                             const Stripe &stripe, Scratch *scratch);

// One exact worker call: coarse -> classify -> resolve.  For divisor 1 this
// is the deterministic stock small-update path.  For divisor 3, calling the
// workers serially describes only that particular legal schedule, not a
// scheduler-independent result.
StageError run_worker(std::span<const std::uint32_t> argb, InclusiveRect update,
                      std::uint32_t worker_index, std::uint32_t divisor,
                      Scratch *scratch);

} // namespace pluto::swtcon::xochitl_selector16_reference

#endif // PLUTO_TEST_PRESENTER_XOCHITL_SELECTOR16_REFERENCE_H_
