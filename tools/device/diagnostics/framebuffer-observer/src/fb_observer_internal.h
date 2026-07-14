#ifndef PLUTO_FB_OBSERVER_INTERNAL_H_
#define PLUTO_FB_OBSERVER_INTERNAL_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "pluto_fb_observer_schema.h"

struct pluto_fb_observer_writer {
  struct pluto_fb_observer_file_header *header;
  struct pluto_fb_observer_record *records;
  uint32_t capacity;
};

typedef int (*pluto_fb_observer_real_ioctl_fn)(void *context, int fd,
                                               unsigned long request,
                                               uintptr_t argument);
typedef size_t (*pluto_fb_observer_copy_fn)(void *context, void *destination,
                                            const void *source, size_t size);
typedef uint64_t (*pluto_fb_observer_now_fn)(void *context);
typedef uint32_t (*pluto_fb_observer_tid_fn)(void *context);

struct pluto_fb_observer_runtime {
  struct pluto_fb_observer_writer writer;
  enum pluto_fb_observer_profile profile;
  pluto_fb_observer_real_ioctl_fn real_ioctl;
  pluto_fb_observer_copy_fn copy_from_self;
  pluto_fb_observer_now_fn now;
  pluto_fb_observer_tid_fn thread_id;
  void *callback_context;
};

void pluto_fb_observer_writer_bind(struct pluto_fb_observer_writer *writer,
                                   struct pluto_fb_observer_file_header *header,
                                   struct pluto_fb_observer_record *records,
                                   uint32_t capacity);

bool pluto_fb_observer_writer_append(
    struct pluto_fb_observer_writer *writer,
    const struct pluto_fb_observer_record *record);

bool pluto_fb_observer_request_is_observed(
    enum pluto_fb_observer_profile profile, unsigned long request);

int pluto_fb_observer_dispatch_ioctl(struct pluto_fb_observer_runtime *runtime,
                                     int fd, unsigned long request,
                                     uintptr_t argument);

void pluto_fb_observer_record_open(struct pluto_fb_observer_runtime *runtime,
                                   int fd, int open_flags, uint16_t flags);

void pluto_fb_observer_record_mapping(
    struct pluto_fb_observer_runtime *runtime,
    enum pluto_fb_observer_record_type record_type, int fd, uintptr_t address,
    uint64_t length, int64_t offset, int result, int error_number,
    uint16_t flags);

#endif /* PLUTO_FB_OBSERVER_INTERNAL_H_ */
