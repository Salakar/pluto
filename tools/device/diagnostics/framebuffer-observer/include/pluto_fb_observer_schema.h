#ifndef PLUTO_FB_OBSERVER_SCHEMA_H_
#define PLUTO_FB_OBSERVER_SCHEMA_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Stable, little-endian trace schema for the diagnostic framebuffer observer.
 *
 * The observer only runs on little-endian ARMv7 devices, but the fixed-width
 * mirrors below intentionally compile on any host so their ABI can be tested
 * without an ARM emulator or a connected tablet.
 */
#define PLUTO_FB_OBSERVER_MAGIC "PFOBSV1\0"
#define PLUTO_FB_OBSERVER_SCHEMA_VERSION 1u
#define PLUTO_FB_OBSERVER_ENDIAN_TAG 0x01020304u
#define PLUTO_FB_OBSERVER_HEADER_SIZE 64u
#define PLUTO_FB_OBSERVER_RECORD_SIZE 416u
#define PLUTO_FB_OBSERVER_PAYLOAD_SIZE 320u

enum pluto_fb_observer_profile {
  PLUTO_FB_OBSERVER_PROFILE_UNKNOWN = 0,
  PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_1 = 1,
  PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_2 = 2,
};

enum pluto_fb_observer_record_type {
  PLUTO_FB_OBSERVER_RECORD_OPEN = 1,
  PLUTO_FB_OBSERVER_RECORD_MMAP = 2,
  PLUTO_FB_OBSERVER_RECORD_MUNMAP = 3,
  PLUTO_FB_OBSERVER_RECORD_IOCTL = 4,
  PLUTO_FB_OBSERVER_RECORD_PHASE_HASH = 5,
};

enum pluto_fb_observer_payload_kind {
  PLUTO_FB_OBSERVER_PAYLOAD_NONE = 0,
  PLUTO_FB_OBSERVER_PAYLOAD_MXCFB_UPDATE = 1,
  PLUTO_FB_OBSERVER_PAYLOAD_MXCFB_MARKER = 2,
  PLUTO_FB_OBSERVER_PAYLOAD_FB_VAR = 3,
  PLUTO_FB_OBSERVER_PAYLOAD_FB_FIX = 4,
  PLUTO_FB_OBSERVER_PAYLOAD_U32 = 5,
  PLUTO_FB_OBSERVER_PAYLOAD_PHASE_HASH = 6,
};

enum pluto_fb_observer_record_flags {
  PLUTO_FB_OBSERVER_FLAG_PRE_VALID = 1u << 0,
  PLUTO_FB_OBSERVER_FLAG_POST_VALID = 1u << 1,
  PLUTO_FB_OBSERVER_FLAG_REAL_FAILED = 1u << 2,
  PLUTO_FB_OBSERVER_FLAG_PATH_MATCH = 1u << 3,
  PLUTO_FB_OBSERVER_FLAG_DEVICE_MATCH = 1u << 4,
  PLUTO_FB_OBSERVER_FLAG_MAP_FAILED = 1u << 5,
};

/* ARM framebuffer ioctl values are part of the captured wire contract. */
#define PLUTO_MXCFB_SEND_UPDATE 0x4048462eu
#define PLUTO_MXCFB_WAIT_FOR_UPDATE_COMPLETE 0xc008462fu
#define PLUTO_FBIOGET_VSCREENINFO 0x00004600u
#define PLUTO_FBIOPUT_VSCREENINFO 0x00004601u
#define PLUTO_FBIOGET_FSCREENINFO 0x00004602u
#define PLUTO_FBIOPAN_DISPLAY 0x00004606u
#define PLUTO_FBIOBLANK 0x00004611u
#define PLUTO_FBIO_WAITFORVSYNC 0x40044620u

struct pluto_fb_observer_file_header {
  uint8_t magic[8];
  uint16_t schema_version;
  uint16_t header_size;
  uint16_t record_size;
  uint16_t flags;
  uint32_t capacity;
  uint32_t next_index;
  uint32_t dropped_records;
  uint32_t profile;
  uint64_t start_monotonic_ns;
  uint32_t process_id;
  uint32_t endian_tag;
  uint64_t reserved0;
  uint64_t reserved1;
};

/*
 * commit_sequence is written with release ordering after every other byte in
 * the slot. A decoder must ignore a slot unless commit_sequence == sequence
 * and both are non-zero.
 */
struct pluto_fb_observer_record {
  uint32_t commit_sequence;
  uint16_t record_type;
  uint16_t payload_kind;
  uint32_t sequence;
  uint32_t thread_id;
  int32_t fd;
  uint32_t request;
  uint64_t entry_monotonic_ns;
  uint64_t exit_monotonic_ns;
  int32_t result;
  int32_t error_number;
  uint16_t payload_size;
  uint16_t pre_size;
  uint16_t post_size;
  uint16_t flags;
  uint64_t map_address;
  uint64_t map_length;
  int64_t map_offset;
  uint8_t payload[PLUTO_FB_OBSERVER_PAYLOAD_SIZE];
  uint8_t reserved[16];
};

/* Fixed ARMv7 mirrors of the kernel-facing structures xochitl passes. */
struct pluto_mxcfb_rect_arm {
  uint32_t top;
  uint32_t left;
  uint32_t width;
  uint32_t height;
};

struct pluto_mxcfb_alt_buffer_data_arm {
  uint32_t phys_addr;
  uint32_t width;
  uint32_t height;
  struct pluto_mxcfb_rect_arm alt_update_region;
};

struct pluto_mxcfb_update_data_arm {
  struct pluto_mxcfb_rect_arm update_region;
  uint32_t waveform_mode;
  uint32_t update_mode;
  uint32_t update_marker;
  int32_t temp;
  uint32_t flags;
  int32_t dither_mode;
  uint32_t quant_bit;
  struct pluto_mxcfb_alt_buffer_data_arm alt_buffer_data;
};

struct pluto_mxcfb_update_marker_data_arm {
  uint32_t update_marker;
  uint32_t collision_test;
};

struct pluto_fb_bitfield_arm {
  uint32_t offset;
  uint32_t length;
  uint32_t msb_right;
};

struct pluto_fb_var_screeninfo_arm {
  uint32_t xres;
  uint32_t yres;
  uint32_t xres_virtual;
  uint32_t yres_virtual;
  uint32_t xoffset;
  uint32_t yoffset;
  uint32_t bits_per_pixel;
  uint32_t grayscale;
  struct pluto_fb_bitfield_arm red;
  struct pluto_fb_bitfield_arm green;
  struct pluto_fb_bitfield_arm blue;
  struct pluto_fb_bitfield_arm transp;
  uint32_t nonstd;
  uint32_t activate;
  uint32_t height;
  uint32_t width;
  uint32_t accel_flags;
  uint32_t pixclock;
  uint32_t left_margin;
  uint32_t right_margin;
  uint32_t upper_margin;
  uint32_t lower_margin;
  uint32_t hsync_len;
  uint32_t vsync_len;
  uint32_t sync;
  uint32_t vmode;
  uint32_t rotate;
  uint32_t colorspace;
  uint32_t reserved[4];
};

/* Linux's unsigned-long addresses are four bytes in the ARMv7 UAPI. */
struct pluto_fb_fix_screeninfo_arm {
  char id[16];
  uint32_t smem_start;
  uint32_t smem_len;
  uint32_t type;
  uint32_t type_aux;
  uint32_t visual;
  uint16_t xpanstep;
  uint16_t ypanstep;
  uint16_t ywrapstep;
  uint16_t alignment_padding;
  uint32_t line_length;
  uint32_t mmio_start;
  uint32_t mmio_len;
  uint32_t accel;
  uint16_t capabilities;
  uint16_t reserved[2];
  uint16_t trailing_padding;
};

#if defined(__cplusplus)
#define PLUTO_FB_STATIC_ASSERT(condition, message)                             \
  static_assert(condition, message)
#else
#define PLUTO_FB_STATIC_ASSERT(condition, message)                             \
  _Static_assert(condition, message)
#endif

PLUTO_FB_STATIC_ASSERT(sizeof(struct pluto_fb_observer_file_header) ==
                           PLUTO_FB_OBSERVER_HEADER_SIZE,
                       "trace header ABI changed");
PLUTO_FB_STATIC_ASSERT(sizeof(struct pluto_fb_observer_record) ==
                           PLUTO_FB_OBSERVER_RECORD_SIZE,
                       "trace record ABI changed");
PLUTO_FB_STATIC_ASSERT(2 * sizeof(struct pluto_fb_var_screeninfo_arm) ==
                           PLUTO_FB_OBSERVER_PAYLOAD_SIZE,
                       "largest pre/post payload no longer fits one record");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_fb_observer_record, payload) == 80,
                       "trace payload offset changed");
PLUTO_FB_STATIC_ASSERT(sizeof(struct pluto_mxcfb_update_data_arm) == 72,
                       "MXCFB update ABI must remain 72 bytes");
PLUTO_FB_STATIC_ASSERT(sizeof(struct pluto_mxcfb_update_marker_data_arm) == 8,
                       "MXCFB marker ABI must remain 8 bytes");
PLUTO_FB_STATIC_ASSERT(sizeof(struct pluto_fb_var_screeninfo_arm) == 160,
                       "ARM fb_var_screeninfo ABI must remain 160 bytes");
PLUTO_FB_STATIC_ASSERT(sizeof(struct pluto_fb_fix_screeninfo_arm) == 68,
                       "ARM fb_fix_screeninfo ABI must remain 68 bytes");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_mxcfb_update_data_arm,
                                waveform_mode) == 16,
                       "MXCFB waveform offset changed");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_mxcfb_update_data_arm,
                                update_mode) == 20,
                       "MXCFB update mode offset changed");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_mxcfb_update_data_arm,
                                update_marker) == 24,
                       "MXCFB marker offset changed");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_mxcfb_update_data_arm, temp) == 28,
                       "MXCFB temperature offset changed");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_mxcfb_update_data_arm, flags) ==
                           32,
                       "MXCFB flags offset changed");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_mxcfb_update_data_arm,
                                dither_mode) == 36,
                       "MXCFB dither offset changed");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_mxcfb_update_data_arm,
                                quant_bit) == 40,
                       "MXCFB quantization offset changed");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_mxcfb_update_data_arm,
                                alt_buffer_data) == 44,
                       "MXCFB alternate buffer offset changed");
PLUTO_FB_STATIC_ASSERT(offsetof(struct pluto_fb_fix_screeninfo_arm,
                                line_length) == 44,
                       "ARM fb_fix line-length offset changed");

#if defined(PLUTO_FB_OBSERVER_ARM_TARGET)
PLUTO_FB_STATIC_ASSERT(sizeof(void *) == 4,
                       "observer target must have 32-bit pointers");
PLUTO_FB_STATIC_ASSERT(sizeof(unsigned long) == 4,
                       "observer target must have 32-bit unsigned long");
#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__)
PLUTO_FB_STATIC_ASSERT(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
                       "trace writer requires a little-endian target");
#endif
#endif

#undef PLUTO_FB_STATIC_ASSERT

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* PLUTO_FB_OBSERVER_SCHEMA_H_ */
