#ifndef PLUTO_PRESENTER_SWTCON_ADMISSION_MAILBOX_H_
#define PLUTO_PRESENTER_SWTCON_ADMISSION_MAILBOX_H_

#include "pluto/presenter.h"
#include "presenter/swtcon/pixel_engine.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pluto::swtcon {

// One drained admission: `request` mirrors the producer's AdmitRequest with
// `levels` re-pointed at this record's own tightly-packed `payload`
// (levels_stride = 0). Header-only records (PEN / guard-null) carry
// levels = nullptr. The record owns its payload storage and is reused
// across pop() calls (no steady-state allocation).
struct AdmissionMailboxRecord {
  AdmitRequest request{};
  std::vector<std::uint8_t> payload;
};

struct AdmissionMailboxConfig {
  // Ring capacity in records, rounded UP to a power of two
  // (bench-calibrated; retired by the zero-copy endgame).
  std::size_t capacity = 2048;
  // Per-record levels payload bound. Default = one 32x32 tile (1024 B).
  // Larger admissions are producer-split.
  std::size_t payload_capacity = 1024;
};

struct AdmissionMailboxStats {
  std::uint64_t pushes = 0;
  std::uint64_t pops = 0;
  std::uint64_t full_rejects = 0;  // kPlutoStatusAgain returns
};

// AdmissionMailbox: bounded MPSC payload ring between presenter producers
// and the engine consumer. Records carry a 5-bit level payload copied at
// push(); legacy PEN records are header-only. Pen-correlated app damage
// uses ordinary payload records. The ONLY backpressure signal is
// kPlutoStatusAgain on ring-full; push() never blocks and never allocates.
//
// Lock-free bounded ring (Vyukov bounded-queue shape, reduced to MPSC):
// producers claim slots by CAS on the enqueue ticket; each slot carries a
// sequence stamp that publishes the payload copy with release/acquire
// ordering; the single consumer needs no CAS.
//
// Thread ownership: push() from any producer thread; pop(), stats() and
// accessors from the engine thread only. configure() must complete before
// any concurrent use.
class AdmissionMailbox final {
 public:
  AdmissionMailbox() = default;
  AdmissionMailbox(const AdmissionMailbox&) = delete;
  AdmissionMailbox& operator=(const AdmissionMailbox&) = delete;

  bool configure(const AdmissionMailboxConfig& config);
  bool configured() const { return configured_; }
  std::size_t capacity() const { return capacity_; }
  std::size_t payload_capacity() const { return payload_capacity_; }

  // Producer side. Copies request.levels (rect.height rows of rect.width
  // bytes, pitch levels_stride or tight) into the claimed slot. Returns:
  //   kPlutoStatusOk              enqueued
  //   kPlutoStatusAgain           ring full (the only backpressure path)
  //   kPlutoStatusInvalidArgument bad rect / missing levels / payload
  //                                 larger than payload_capacity()
  PlutoStatus push(const AdmitRequest& request);

  // Consumer side (engine thread): drains the oldest record into `out`
  // (payload copied out before the slot is released to producers).
  // Returns false when the ring is empty.
  bool pop(AdmissionMailboxRecord* out);

  // Approximate occupancy (exact when producers are quiescent).
  std::size_t size_approx() const;

  // Engine-thread snapshot; producer counters are relaxed atomics.
  AdmissionMailboxStats stats() const;

 private:
  struct RecordHeader {
    PlutoRect rect{};
    std::int32_t mode = 0;
    std::int32_t temp_bin = -1;
    std::uint32_t flags = 0;
    std::uint64_t frame_id = 0;
    std::uint32_t payload_bytes = 0;
  };

  struct Slot {
    std::atomic<std::size_t> sequence{0};
    RecordHeader header{};
    // Payload lives in payload_arena_ at index * payload_capacity_.
  };

  bool configured_ = false;
  std::size_t capacity_ = 0;
  std::size_t mask_ = 0;
  std::size_t payload_capacity_ = 0;
  std::vector<Slot> slots_;
  std::vector<std::uint8_t> payload_arena_;

  alignas(64) std::atomic<std::size_t> enqueue_pos_{0};
  alignas(64) std::atomic<std::size_t> dequeue_pos_{0};

  std::atomic<std::uint64_t> pushes_{0};
  std::atomic<std::uint64_t> full_rejects_{0};
  std::uint64_t pops_ = 0;  // consumer-thread private
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_ADMISSION_MAILBOX_H_
