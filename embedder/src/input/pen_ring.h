#ifndef PLUTO_SRC_INPUT_PEN_RING_H_
#define PLUTO_SRC_INPUT_PEN_RING_H_

#include <atomic>
#include <cstdint>
#include <vector>

#include "pluto/pen_ring.h"

namespace pluto {

template <typename Record>
class SpscRing {
 public:
  SpscRing(uint32_t record_size, uint32_t capacity);

  SpscRing(const SpscRing&) = delete;
  SpscRing& operator=(const SpscRing&) = delete;

  pluto_pen_ring_header* header();
  const pluto_pen_ring_header* header() const;
  Record* records();
  const Record* records() const;

  void reset();
  void push(const Record& record);
  std::vector<Record> read_from(uint64_t* cursor) const;

 private:
  std::vector<uint64_t> storage_words_;
};

void notify_ring_wakeup();
SpscRing<pluto_pen_ring_record>& global_pen_ring_storage();
SpscRing<pluto_touch_ring_record>& global_touch_ring_storage();

}  // namespace pluto

#endif  // PLUTO_SRC_INPUT_PEN_RING_H_
