#include "fb_observer_internal.h"

#include <errno.h>
#include <string.h>

struct payload_spec {
  enum pluto_fb_observer_payload_kind kind;
  uint16_t size;
  bool immediate_u32;
};

static struct payload_spec
payload_spec_for_request(enum pluto_fb_observer_profile profile,
                         unsigned long request) {
  const uint32_t request32 = (uint32_t)request;
  struct payload_spec spec = {
      .kind = PLUTO_FB_OBSERVER_PAYLOAD_NONE,
      .size = 0,
      .immediate_u32 = false,
  };

  if (profile == PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_1) {
    if (request32 == PLUTO_MXCFB_SEND_UPDATE) {
      spec.kind = PLUTO_FB_OBSERVER_PAYLOAD_MXCFB_UPDATE;
      spec.size = (uint16_t)sizeof(struct pluto_mxcfb_update_data_arm);
      return spec;
    }
    if (request32 == PLUTO_MXCFB_WAIT_FOR_UPDATE_COMPLETE) {
      spec.kind = PLUTO_FB_OBSERVER_PAYLOAD_MXCFB_MARKER;
      spec.size = (uint16_t)sizeof(struct pluto_mxcfb_update_marker_data_arm);
      return spec;
    }
  }

  switch (request32) {
  case PLUTO_FBIOGET_VSCREENINFO:
  case PLUTO_FBIOPUT_VSCREENINFO:
  case PLUTO_FBIOPAN_DISPLAY:
    spec.kind = PLUTO_FB_OBSERVER_PAYLOAD_FB_VAR;
    spec.size = (uint16_t)sizeof(struct pluto_fb_var_screeninfo_arm);
    return spec;
  case PLUTO_FBIOGET_FSCREENINFO:
    spec.kind = PLUTO_FB_OBSERVER_PAYLOAD_FB_FIX;
    spec.size = (uint16_t)sizeof(struct pluto_fb_fix_screeninfo_arm);
    return spec;
  case PLUTO_FBIOBLANK:
    spec.kind = PLUTO_FB_OBSERVER_PAYLOAD_U32;
    spec.size = (uint16_t)sizeof(uint32_t);
    spec.immediate_u32 = true;
    return spec;
  case PLUTO_FBIO_WAITFORVSYNC:
    spec.kind = PLUTO_FB_OBSERVER_PAYLOAD_U32;
    spec.size = (uint16_t)sizeof(uint32_t);
    return spec;
  default:
    return spec;
  }
}

static uint64_t runtime_now(struct pluto_fb_observer_runtime *runtime) {
  return runtime->now == NULL ? 0 : runtime->now(runtime->callback_context);
}

static uint32_t runtime_tid(struct pluto_fb_observer_runtime *runtime) {
  return runtime->thread_id == NULL
             ? 0
             : runtime->thread_id(runtime->callback_context);
}

static bool snapshot_argument(struct pluto_fb_observer_runtime *runtime,
                              const struct payload_spec *spec,
                              uintptr_t argument, void *destination) {
  if (spec->size == 0) {
    return false;
  }
  if (spec->immediate_u32) {
    const uint32_t value = (uint32_t)argument;
    memcpy(destination, &value, sizeof(value));
    return true;
  }
  if (argument == 0 || runtime->copy_from_self == NULL) {
    return false;
  }
  return runtime->copy_from_self(runtime->callback_context, destination,
                                 (const void *)argument,
                                 spec->size) == spec->size;
}

void pluto_fb_observer_writer_bind(struct pluto_fb_observer_writer *writer,
                                   struct pluto_fb_observer_file_header *header,
                                   struct pluto_fb_observer_record *records,
                                   uint32_t capacity) {
  writer->header = header;
  writer->records = records;
  writer->capacity = capacity;
}

bool pluto_fb_observer_writer_append(
    struct pluto_fb_observer_writer *writer,
    const struct pluto_fb_observer_record *record) {
  if (writer == NULL || writer->header == NULL || writer->records == NULL ||
      writer->capacity == 0) {
    return false;
  }

  const uint32_t index =
      __atomic_fetch_add(&writer->header->next_index, 1u, __ATOMIC_RELAXED);
  if (index >= writer->capacity) {
    __atomic_fetch_add(&writer->header->dropped_records, 1u, __ATOMIC_RELAXED);
    return false;
  }

  struct pluto_fb_observer_record committed = *record;
  committed.commit_sequence = 0;
  committed.sequence = index + 1u;
  writer->records[index] = committed;
  __atomic_store_n(&writer->records[index].commit_sequence, committed.sequence,
                   __ATOMIC_RELEASE);
  return true;
}

bool pluto_fb_observer_request_is_observed(
    enum pluto_fb_observer_profile profile, unsigned long request) {
  return payload_spec_for_request(profile, request).kind !=
         PLUTO_FB_OBSERVER_PAYLOAD_NONE;
}

int pluto_fb_observer_dispatch_ioctl(struct pluto_fb_observer_runtime *runtime,
                                     int fd, unsigned long request,
                                     uintptr_t argument) {
  if (runtime == NULL || runtime->real_ioctl == NULL) {
    errno = ENOSYS;
    return -1;
  }

  const struct payload_spec spec =
      payload_spec_for_request(runtime->profile, request);
  if (spec.kind == PLUTO_FB_OBSERVER_PAYLOAD_NONE) {
    return runtime->real_ioctl(runtime->callback_context, fd, request,
                               argument);
  }

  const int caller_errno = errno;
  struct pluto_fb_observer_record record;
  memset(&record, 0, sizeof(record));
  record.record_type = PLUTO_FB_OBSERVER_RECORD_IOCTL;
  record.payload_kind = (uint16_t)spec.kind;
  record.thread_id = runtime_tid(runtime);
  record.fd = fd;
  record.request = (uint32_t)request;
  record.entry_monotonic_ns = runtime_now(runtime);
  record.payload_size = (uint16_t)(spec.size * 2u);
  record.pre_size = spec.size;
  record.post_size = spec.size;
  record.flags = PLUTO_FB_OBSERVER_FLAG_DEVICE_MATCH;

  if (snapshot_argument(runtime, &spec, argument, record.payload)) {
    record.flags |= PLUTO_FB_OBSERVER_FLAG_PRE_VALID;
  }

  /* Observation callbacks may set errno; the real ioctl sees the caller's. */
  errno = caller_errno;
  const int result =
      runtime->real_ioctl(runtime->callback_context, fd, request, argument);
  const int ioctl_errno = errno;

  if (snapshot_argument(runtime, &spec, argument, record.payload + spec.size)) {
    record.flags |= PLUTO_FB_OBSERVER_FLAG_POST_VALID;
  }
  record.exit_monotonic_ns = runtime_now(runtime);
  record.result = result;
  record.error_number = ioctl_errno;
  if (result < 0) {
    record.flags |= PLUTO_FB_OBSERVER_FLAG_REAL_FAILED;
  }
  (void)pluto_fb_observer_writer_append(&runtime->writer, &record);

  errno = ioctl_errno;
  return result;
}

void pluto_fb_observer_record_open(struct pluto_fb_observer_runtime *runtime,
                                   int fd, int open_flags, uint16_t flags) {
  if (runtime == NULL || fd < 0) {
    return;
  }
  struct pluto_fb_observer_record record;
  memset(&record, 0, sizeof(record));
  record.record_type = PLUTO_FB_OBSERVER_RECORD_OPEN;
  record.thread_id = runtime_tid(runtime);
  record.fd = fd;
  record.request = (uint32_t)open_flags;
  record.entry_monotonic_ns = runtime_now(runtime);
  record.exit_monotonic_ns = record.entry_monotonic_ns;
  record.flags = flags;
  (void)pluto_fb_observer_writer_append(&runtime->writer, &record);
}

void pluto_fb_observer_record_mapping(
    struct pluto_fb_observer_runtime *runtime,
    enum pluto_fb_observer_record_type record_type, int fd, uintptr_t address,
    uint64_t length, int64_t offset, int result, int error_number,
    uint16_t flags) {
  if (runtime == NULL) {
    return;
  }
  struct pluto_fb_observer_record record;
  memset(&record, 0, sizeof(record));
  record.record_type = (uint16_t)record_type;
  record.thread_id = runtime_tid(runtime);
  record.fd = fd;
  record.entry_monotonic_ns = runtime_now(runtime);
  record.exit_monotonic_ns = record.entry_monotonic_ns;
  record.result = result;
  record.error_number = error_number;
  record.flags = flags;
  record.map_address = (uint64_t)address;
  record.map_length = length;
  record.map_offset = offset;
  (void)pluto_fb_observer_writer_append(&runtime->writer, &record);
}
