#include "input/pen_ring.h"

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <mutex>

namespace pluto {
namespace {

std::atomic<void (*)(void*)> g_wakeup_fn{nullptr};
std::atomic<void*> g_wakeup_ctx{nullptr};

constexpr size_t word_count_for(size_t bytes) {
  return (bytes + sizeof(uint64_t) - 1) / sizeof(uint64_t);
}

template <typename Record>
Record* records_after(pluto_pen_ring_header* header) {
  return reinterpret_cast<Record*>(reinterpret_cast<uint8_t*>(header) +
                                   sizeof(pluto_pen_ring_header));
}

template <typename Record>
const Record* records_after(const pluto_pen_ring_header* header) {
  return reinterpret_cast<const Record*>(reinterpret_cast<const uint8_t*>(header) +
                                         sizeof(pluto_pen_ring_header));
}

}  // namespace

template <typename Record>
SpscRing<Record>::SpscRing(uint32_t record_size, uint32_t capacity) {
  const size_t bytes = sizeof(pluto_pen_ring_header) +
                       static_cast<size_t>(record_size) * capacity;
  storage_words_.assign(word_count_for(bytes), 0);
  pluto_pen_ring_header* h = header();
  h->magic = PLUTO_PEN_RING_MAGIC;
  h->version = PLUTO_PEN_RING_VERSION;
  h->record_size = record_size;
  h->capacity = capacity;
  h->write_index.store(0, std::memory_order_relaxed);
  h->dropped.store(0, std::memory_order_relaxed);
  std::memset(h->pad, 0, sizeof(h->pad));
}

template <typename Record>
pluto_pen_ring_header* SpscRing<Record>::header() {
  return reinterpret_cast<pluto_pen_ring_header*>(storage_words_.data());
}

template <typename Record>
const pluto_pen_ring_header* SpscRing<Record>::header() const {
  return reinterpret_cast<const pluto_pen_ring_header*>(storage_words_.data());
}

template <typename Record>
Record* SpscRing<Record>::records() {
  return records_after<Record>(header());
}

template <typename Record>
const Record* SpscRing<Record>::records() const {
  return records_after<Record>(header());
}

template <typename Record>
void SpscRing<Record>::reset() {
  pluto_pen_ring_header* h = header();
  h->write_index.store(0, std::memory_order_release);
  h->dropped.store(0, std::memory_order_release);
  const size_t bytes = static_cast<size_t>(h->record_size) * h->capacity;
  std::memset(records(), 0, bytes);
}

template <typename Record>
void SpscRing<Record>::push(const Record& record) {
  pluto_pen_ring_header* h = header();
  const uint64_t write_index = h->write_index.load(std::memory_order_relaxed);
  const uint32_t slot = static_cast<uint32_t>(write_index & (h->capacity - 1u));
  records()[slot] = record;
  h->write_index.store(write_index + 1u, std::memory_order_release);
  if (write_index + 1u > h->capacity) {
    h->dropped.store(write_index + 1u - h->capacity, std::memory_order_release);
  }
}

template <typename Record>
std::vector<Record> SpscRing<Record>::read_from(uint64_t* cursor) const {
  const pluto_pen_ring_header* h = header();
  uint64_t write_index = h->write_index.load(std::memory_order_acquire);
  if (write_index > *cursor && write_index - *cursor > h->capacity) {
    *cursor = write_index - h->capacity;
  }

  std::vector<Record> out;
  while (*cursor < write_index) {
    const uint32_t slot = static_cast<uint32_t>(*cursor & (h->capacity - 1u));
    out.push_back(records()[slot]);
    ++(*cursor);
    const uint64_t after = h->write_index.load(std::memory_order_acquire);
    if (after - *cursor > h->capacity) {
      write_index = after;
      *cursor = write_index - h->capacity;
      out.clear();
    } else {
      write_index = after;
    }
  }
  return out;
}

void notify_ring_wakeup() {
  void (*fn)(void*) = g_wakeup_fn.load(std::memory_order_acquire);
  void* ctx = g_wakeup_ctx.load(std::memory_order_acquire);
  if (fn != nullptr) {
    fn(ctx);
  }
}

void set_ring_wakeup(void (*fn)(void*), void* ctx) {
  g_wakeup_ctx.store(ctx, std::memory_order_release);
  g_wakeup_fn.store(fn, std::memory_order_release);
}

SpscRing<pluto_pen_ring_record>& global_pen_ring_storage() {
  static SpscRing<pluto_pen_ring_record> ring(PLUTO_PEN_RING_RECORD_SIZE,
                                                PLUTO_PEN_RING_DEFAULT_CAPACITY);
  return ring;
}

SpscRing<pluto_touch_ring_record>& global_touch_ring_storage() {
  static SpscRing<pluto_touch_ring_record> ring(
      PLUTO_TOUCH_RING_RECORD_SIZE, PLUTO_TOUCH_RING_DEFAULT_CAPACITY);
  return ring;
}

template class SpscRing<pluto_pen_ring_record>;
template class SpscRing<pluto_touch_ring_record>;

}  // namespace pluto

extern "C" {

const pluto_pen_ring_header* pluto_pen_ring(void) {
  return pluto::global_pen_ring_storage().header();
}

const pluto_pen_ring_header* pluto_touch_ring(void) {
  return pluto::global_touch_ring_storage().header();
}

void pluto_ring_set_wakeup(void (*fn)(void*), void* ctx) {
  pluto::set_ring_wakeup(fn, ctx);
}

}  // extern "C"
