#ifndef PLUTO_PEN_RING_H_
#define PLUTO_PEN_RING_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#include <atomic>
#define PLUTO_RING_ATOMIC_U64 std::atomic<uint64_t>
#else
#include <stdatomic.h>
#define PLUTO_RING_ATOMIC_U64 _Atomic uint64_t
#endif

#define PLUTO_PEN_RING_MAGIC 0x52544C50u
#define PLUTO_PEN_RING_RECORD_SIZE 40u
#define PLUTO_TOUCH_RING_RECORD_SIZE 32u
#define PLUTO_PEN_RING_DEFAULT_CAPACITY 4096u
#define PLUTO_TOUCH_RING_DEFAULT_CAPACITY 4096u

typedef enum PlutoPenRingFlag {
  kPlutoPenRingFlagContact = 1u << 0,
  kPlutoPenRingFlagInRange = 1u << 1,
  kPlutoPenRingFlagEraser = 1u << 2,
  kPlutoPenRingFlagButtonStylus = 1u << 3,
  kPlutoPenRingFlagButtonStylus2 = 1u << 4,
  kPlutoPenRingFlagResync = 1u << 5,
  kPlutoPenRingFlagDeviceLost = 1u << 6,
  kPlutoPenRingFlagOrientationValid = 1u << 7,
} PlutoPenRingFlag;

typedef enum PlutoTouchRingPhase {
  kPlutoTouchRingPhaseBegan = 0,
  kPlutoTouchRingPhaseMoved = 1,
  kPlutoTouchRingPhaseEnded = 2,
  kPlutoTouchRingPhaseCancelled = 3,
} PlutoTouchRingPhase;

typedef enum PlutoTouchRingClassification {
  kPlutoTouchRingClassificationFinger = 0,
  kPlutoTouchRingClassificationPalm = 1,
  kPlutoTouchRingClassificationPenSuppressed = 2,
  kPlutoTouchRingClassificationHoldoffSuppressed = 3,
} PlutoTouchRingClassification;

#if defined(_MSC_VER)
#pragma pack(push, 1)
#define PLUTO_PACKED
#else
#define PLUTO_PACKED __attribute__((packed))
#endif

typedef struct PLUTO_PACKED pluto_pen_ring_record {
  uint64_t ts_us;
  uint32_t seq;
  uint16_t flags;
  uint16_t raw_x;
  uint16_t raw_y;
  uint16_t raw_pressure;
  uint16_t raw_distance;
  int16_t tilt_x_cdeg;
  int16_t tilt_y_cdeg;
  uint16_t orientation_tag;
  float x_logical;
  float y_logical;
  uint32_t reserved;
} pluto_pen_ring_record;

typedef struct PLUTO_PACKED pluto_touch_ring_record {
  uint64_t ts_us;
  uint32_t seq;
  uint8_t slot;
  uint8_t phase;
  uint8_t classification;
  uint8_t touch_major;
  uint16_t tracking_id;
  uint16_t raw_x;
  uint16_t raw_y;
  uint8_t pressure;
  uint8_t distance;
  float x_logical;
  float y_logical;
} pluto_touch_ring_record;

#if defined(_MSC_VER)
#pragma pack(pop)
#else
#undef PLUTO_PACKED
#endif

typedef struct pluto_pen_ring_header {
  uint32_t magic;
  uint32_t record_size;
  uint32_t capacity;
  uint32_t reserved;
  PLUTO_RING_ATOMIC_U64 write_index;
  PLUTO_RING_ATOMIC_U64 dropped;
  uint8_t pad[32];
} pluto_pen_ring_header;

#ifdef __cplusplus
extern "C" {
#endif

const pluto_pen_ring_header *pluto_pen_ring(void);
const pluto_pen_ring_header *pluto_touch_ring(void);
void pluto_ring_set_wakeup(void (*fn)(void *), void *ctx);

#ifdef __cplusplus
} // extern "C"

static_assert(sizeof(pluto_pen_ring_record) == PLUTO_PEN_RING_RECORD_SIZE,
              "pluto_pen_ring_record must stay ABI-compatible");
static_assert(sizeof(pluto_touch_ring_record) == PLUTO_TOUCH_RING_RECORD_SIZE,
              "pluto_touch_ring_record must stay ABI-compatible");
static_assert(sizeof(pluto_pen_ring_header) == 64,
              "pluto_pen_ring_header must stay one cache line");
static_assert(offsetof(pluto_pen_ring_header, magic) == 0,
              "pluto_pen_ring_header magic offset changed");
static_assert(offsetof(pluto_pen_ring_header, record_size) == 4,
              "pluto_pen_ring_header record_size offset changed");
static_assert(offsetof(pluto_pen_ring_header, capacity) == 8,
              "pluto_pen_ring_header capacity offset changed");
static_assert(offsetof(pluto_pen_ring_header, reserved) == 12,
              "pluto_pen_ring_header reserved offset changed");
static_assert(offsetof(pluto_pen_ring_header, write_index) == 16,
              "pluto_pen_ring_header write_index offset changed");
static_assert(offsetof(pluto_pen_ring_header, dropped) == 24,
              "pluto_pen_ring_header dropped offset changed");
#endif

#undef PLUTO_RING_ATOMIC_U64

#endif // PLUTO_PEN_RING_H_
