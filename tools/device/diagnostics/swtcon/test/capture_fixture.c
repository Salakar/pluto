#include <stddef.h>
#include <stdint.h>

struct ImageDesc {
  void* begin;
  void* end;
  void* capacity;
  int32_t left;
  int32_t top;
  int32_t right;
  int32_t bottom;
  uint64_t stride;
};

struct WaveRecord {
  uint8_t padding[0x30];
  void* delta;
};

_Static_assert(sizeof(struct ImageDesc) == 0x30, "image descriptor ABI");
_Static_assert(offsetof(struct WaveRecord, delta) == 0x30,
               "wave delta ABI");

__attribute__((section(".testdata"), aligned(16)))
static uint8_t ct33[64];
__attribute__((section(".testdata"), aligned(16)))
static int16_t delta[1024];
__attribute__((section(".testdata"), aligned(16)))
static uint16_t output[160];
__attribute__((section(".palette"), aligned(16)))
static uint8_t palettes[7][16] = {
    {30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 0, 30, 32, 32, 32, 32},
    {0, 14, 6, 22, 10, 18, 26, 30, 15, 19, 0, 30, 32, 32, 32, 32},
    {2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 30, 32, 32, 32, 32},
    {0, 32, 32, 32, 32, 32, 32, 30, 15, 19, 0, 30, 32, 32, 32, 32},
    {0, 32, 32, 32, 32, 32, 32, 30, 15, 19, 0, 30, 32, 32, 32, 32},
    {2, 13, 5, 21, 9, 17, 25, 28, 15, 19, 0, 30, 32, 32, 32, 32},
    {2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 28, 32, 32, 32, 32},
};
__attribute__((section(".testdata"), aligned(16)))
static struct ImageDesc source_desc;
__attribute__((section(".testdata"), aligned(16)))
static struct ImageDesc output_desc;
__attribute__((section(".testdata"), aligned(16)))
static struct WaveRecord wave;
__attribute__((section(".testdata"), aligned(16)))
static uint8_t node[0xc0];
__attribute__((section(".testdata"), aligned(16)))
static void* list_sentinel;

__attribute__((section(".abdesc"), aligned(8)))
struct ImageDesc ab_desc;
__attribute__((section(".abdata"), aligned(16)))
static uint8_t ab_plane[0x645240];

static inline uint8_t* context(void) { return node + 0x10; }

__attribute__((section(".postworker"), noinline))
static void postworker(void) {
  __asm__ volatile("" ::: "memory");
}

__attribute__((section(".mapper"), noinline))
static void mapper(void* raw_ctx,
                   const uint8_t* mode_palette,
                   uint32_t y_first,
                   uint32_t y_last,
                   void* barrier) {
  uint8_t* ctx = (uint8_t*)raw_ctx;
  struct ImageDesc* out = *(struct ImageDesc**)(ctx + 0x70);
  uint16_t* words = (uint16_t*)out->begin;
  const uint8_t* input = *(const uint8_t**)(ctx + 0x10);
  const int16_t* selected_delta =
      (const int16_t*)(*(struct WaveRecord**)(ctx + 0x58))->delta;

  for (uint32_t y = y_first; y <= y_last; ++y) {
    uint16_t* row = words + y * out->stride;
    row[0] = (uint16_t)((input[y * 8] << 5) | mode_palette[0]);
    row[1] = (uint16_t)((y_first << 8) | y_last);
    row[2] = (uint16_t)selected_delta[y];
    row[3] = barrier != NULL ? 1u : 0u;
  }
  ab_plane[0] = (uint8_t)(ab_plane[0] + 1u);
  ab_plane[1] = (uint8_t)(ab_plane[1] + 3u);
}

__attribute__((section(".preworker"), noinline))
static void preworker(void* list) {
  uint8_t* first_node = *(uint8_t**)list;
  *(void**)(first_node + 0x10 + 0x70) = &output_desc;
  mapper(first_node + 0x10, palettes[2], 0, 3, list);
  mapper(first_node + 0x10, palettes[2], 4, 7, list);
  postworker();
}

static void initialize_fixture(void) {
  for (uint32_t i = 0; i < sizeof(ct33); ++i) {
    ct33[i] = (uint8_t)(i & 7u);
  }
  for (uint32_t i = 0; i < 1024; ++i) {
    delta[i] = (int16_t)(i - 512);
  }

  source_desc.begin = ct33;
  source_desc.end = ct33 + sizeof(ct33);
  source_desc.capacity = source_desc.end;
  source_desc.left = 0;
  source_desc.top = 0;
  source_desc.right = 7;
  source_desc.bottom = 7;
  source_desc.stride = 8;

  output_desc.begin = output;
  output_desc.end = output + 160;
  output_desc.capacity = output_desc.end;
  output_desc.left = 0;
  output_desc.top = 0;
  output_desc.right = 7;
  output_desc.bottom = 7;
  output_desc.stride = 16;

  wave.delta = delta;
  ab_desc.begin = ab_plane;
  ab_desc.end = ab_plane + sizeof(ab_plane);
  ab_desc.capacity = ab_desc.end;
  ab_desc.left = 0;
  ab_desc.top = 0;
  ab_desc.right = 959;
  ab_desc.bottom = 1695;
  ab_desc.stride = 968;

  list_sentinel = node;
  *(void**)node = &list_sentinel;
  *(void**)(context() + 0x00) = &source_desc;
  *(void**)(context() + 0x10) = ct33;
  *(int32_t*)(context() + 0x18) = 0;
  *(int32_t*)(context() + 0x1c) = 0;
  *(int32_t*)(context() + 0x20) = 7;
  *(int32_t*)(context() + 0x24) = 7;
  *(uint64_t*)(context() + 0x28) = 8;
  *(uint64_t*)(context() + 0x30) = 8;
  *(int32_t*)(context() + 0x38) = 0;
  *(int32_t*)(context() + 0x3c) = 0;
  *(int32_t*)(context() + 0x40) = 7;
  *(int32_t*)(context() + 0x44) = 7;
  *(void**)(context() + 0x58) = &wave;
  *(int16_t*)(context() + 0x68) = 3;
  *(float*)(context() + 0x6c) = 25.0f;
  *(void**)(context() + 0x70) = NULL;
  *(int32_t*)(node + 0xb4) = 0;
}

__attribute__((noreturn)) static void exit_group(int status) {
  register uint64_t x0 __asm__("x0") = (uint64_t)status;
  register uint64_t x8 __asm__("x8") = 94;
  __asm__ volatile("svc 0" : : "r"(x0), "r"(x8) : "memory");
  __builtin_unreachable();
}

__attribute__((section(".text.start"), noreturn))
void _start(void) {
  initialize_fixture();
  /* The capture script must ignore this non-Content/UI operation. */
  preworker(&list_sentinel);
  *(void**)(context() + 0x70) = NULL;
  *(int16_t*)(context() + 0x68) = 2;
  preworker(&list_sentinel);
  exit_group(0);
}
