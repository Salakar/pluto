#include "presenter/swtcon/admission_mailbox.h"

#include <cstring>

namespace pluto::swtcon {
namespace {

std::size_t round_up_pow2(std::size_t value) {
  std::size_t pow2 = 1;
  while (pow2 < value) {
    pow2 <<= 1;
  }
  return pow2;
}

// Header-only records: the legacy PEN sentinel carries no payload;
// guard-null drives next := prev and ignores levels by contract
// (pixel_engine.h kAdmitFlagGuardNull); sparkle top-off passes compute their
// targets engine-side from prev + the R2 mask;
// large-lane markers only preserve cross-lane admission order (the payload
// rides in the presenter's large-admission lane).
bool header_only(const AdmitRequest& request) {
  return (request.flags & (kAdmitFlagPen | kAdmitFlagGuardNull |
                           kAdmitFlagSparkle | kAdmitFlagLargeLane)) != 0;
}

}  // namespace

bool AdmissionMailbox::configure(const AdmissionMailboxConfig& config) {
  if (config.capacity == 0 || config.payload_capacity == 0) {
    return false;
  }
  capacity_ = round_up_pow2(config.capacity);
  mask_ = capacity_ - 1;
  payload_capacity_ = config.payload_capacity;
  slots_ = std::vector<Slot>(capacity_);
  payload_arena_.assign(capacity_ * payload_capacity_, 0);
  for (std::size_t i = 0; i < capacity_; ++i) {
    // Vyukov stamp protocol: slot i is writable when sequence == ticket i.
    slots_[i].sequence.store(i, std::memory_order_relaxed);
  }
  enqueue_pos_.store(0, std::memory_order_relaxed);
  dequeue_pos_.store(0, std::memory_order_relaxed);
  pushes_.store(0, std::memory_order_relaxed);
  full_rejects_.store(0, std::memory_order_relaxed);
  pops_ = 0;
  configured_ = true;
  return true;
}

PlutoStatus AdmissionMailbox::push(const AdmitRequest& request) {
  if (!configured_ || request.fast_coverage != nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  const bool with_payload = !header_only(request);
  std::size_t payload_bytes = 0;
  if (with_payload) {
    if (request.levels == nullptr || request.rect.width <= 0 ||
        request.rect.height <= 0) {
      return kPlutoStatusInvalidArgument;
    }
    payload_bytes = static_cast<std::size_t>(request.rect.width) *
                    static_cast<std::size_t>(request.rect.height);
    if (payload_bytes > payload_capacity_) {
      // Producers split to tile granularity (the ring record is one tile's
      // payload); an oversized rect is a producer bug, not backpressure.
      return kPlutoStatusInvalidArgument;
    }
  }

  // Claim a slot (multi-producer CAS on the enqueue ticket).
  std::size_t pos = enqueue_pos_.load(std::memory_order_relaxed);
  Slot* slot = nullptr;
  for (;;) {
    slot = &slots_[pos & mask_];
    const std::size_t seq = slot->sequence.load(std::memory_order_acquire);
    const std::intptr_t dif = static_cast<std::intptr_t>(seq) -
                              static_cast<std::intptr_t>(pos);
    if (dif == 0) {
      if (enqueue_pos_.compare_exchange_weak(pos, pos + 1,
                                             std::memory_order_relaxed)) {
        break;
      }
    } else if (dif < 0) {
      // The slot still holds an unconsumed record from one lap ago: full.
      full_rejects_.fetch_add(1, std::memory_order_relaxed);
      return kPlutoStatusAgain;
    } else {
      pos = enqueue_pos_.load(std::memory_order_relaxed);
    }
  }

  RecordHeader& header = slot->header;
  header.rect = request.rect;
  header.mode = request.mode;
  header.temp_bin = request.temp_bin;
  header.flags = request.flags;
  header.frame_id = request.frame_id;
  header.payload_bytes = static_cast<std::uint32_t>(payload_bytes);
  if (with_payload) {
    std::uint8_t* dst =
        payload_arena_.data() + (pos & mask_) * payload_capacity_;
    const std::size_t width = static_cast<std::size_t>(request.rect.width);
    const std::size_t src_stride =
        request.levels_stride != 0 ? request.levels_stride : width;
    if (src_stride == width) {
      // Tight source (the common tile shape): both sides are contiguous, so
      // the whole payload copies in one memcpy instead of rect.height tiny
      // strided ones (a 32x32 tile: 1 x 1024 B vs 32 x 32 B).
      std::memcpy(dst, request.levels, payload_bytes);
    } else {
      for (std::int32_t y = 0; y < request.rect.height; ++y) {
        std::memcpy(dst + static_cast<std::size_t>(y) * width,
                    request.levels + static_cast<std::size_t>(y) * src_stride,
                    width);
      }
    }
  }
  // Publish: consumer's acquire load of sequence sees header + payload.
  slot->sequence.store(pos + 1, std::memory_order_release);
  pushes_.fetch_add(1, std::memory_order_relaxed);
  return kPlutoStatusOk;
}

bool AdmissionMailbox::pop(AdmissionMailboxRecord* out) {
  if (!configured_ || out == nullptr) {
    return false;
  }
  // Single consumer: no CAS needed on the dequeue ticket.
  const std::size_t pos = dequeue_pos_.load(std::memory_order_relaxed);
  Slot& slot = slots_[pos & mask_];
  const std::size_t seq = slot.sequence.load(std::memory_order_acquire);
  if (static_cast<std::intptr_t>(seq) - static_cast<std::intptr_t>(pos + 1) <
      0) {
    return false;  // empty
  }

  const RecordHeader& header = slot.header;
  out->request.rect = header.rect;
  out->request.mode = header.mode;
  out->request.temp_bin = header.temp_bin;
  out->request.flags = header.flags;
  out->request.frame_id = header.frame_id;
  out->request.fast_coverage.reset();
  out->request.levels_stride = 0;  // payload is tightly packed
  if (header.payload_bytes > 0) {
    out->payload.assign(
        payload_arena_.data() + (pos & mask_) * payload_capacity_,
        payload_arena_.data() + (pos & mask_) * payload_capacity_ +
            header.payload_bytes);
    out->request.levels = out->payload.data();
  } else {
    out->payload.clear();
    out->request.levels = nullptr;
  }

  // Release the slot to producers one lap ahead.
  slot.sequence.store(pos + capacity_, std::memory_order_release);
  dequeue_pos_.store(pos + 1, std::memory_order_relaxed);
  ++pops_;
  return true;
}

std::size_t AdmissionMailbox::size_approx() const {
  const std::size_t head = dequeue_pos_.load(std::memory_order_relaxed);
  const std::size_t tail = enqueue_pos_.load(std::memory_order_relaxed);
  return tail >= head ? tail - head : 0;
}

AdmissionMailboxStats AdmissionMailbox::stats() const {
  AdmissionMailboxStats out;
  out.pushes = pushes_.load(std::memory_order_relaxed);
  out.full_rejects = full_rejects_.load(std::memory_order_relaxed);
  out.pops = pops_;
  return out;
}

}  // namespace pluto::swtcon
