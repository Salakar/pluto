#include "fb_observer_internal.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__,       \
              #condition);                                                     \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

struct fake_context {
  int call_count;
  int errno_seen;
  int expected_fd;
  unsigned long expected_request;
  uintptr_t expected_argument;
  int result;
  int result_errno;
  uint32_t marker_after_call;
  uint64_t now;
  uint32_t thread_id;
  struct pluto_mxcfb_update_data_arm argument_seen;
};

static int fake_ioctl(void *opaque, int fd, unsigned long request,
                      uintptr_t argument) {
  struct fake_context *context = opaque;
  ++context->call_count;
  context->errno_seen = errno;
  CHECK(fd == context->expected_fd);
  CHECK(request == context->expected_request);
  CHECK(argument == context->expected_argument);
  if (request == PLUTO_MXCFB_SEND_UPDATE) {
    memcpy(&context->argument_seen, (const void *)argument,
           sizeof(context->argument_seen));
    struct pluto_mxcfb_update_data_arm *update = (void *)argument;
    update->update_marker = context->marker_after_call;
  }
  errno = context->result_errno;
  return context->result;
}

static size_t noisy_copy(void *opaque, void *destination, const void *source,
                         size_t size) {
  (void)opaque;
  memcpy(destination, source, size);
  errno = ERANGE;
  return size;
}

static uint64_t noisy_now(void *opaque) {
  struct fake_context *context = opaque;
  context->now += 100;
  errno = ENOTTY;
  return context->now;
}

static uint32_t noisy_tid(void *opaque) {
  struct fake_context *context = opaque;
  errno = EDOM;
  return context->thread_id;
}

static struct pluto_fb_observer_runtime
make_runtime(struct fake_context *context,
             struct pluto_fb_observer_file_header *header,
             struct pluto_fb_observer_record *records, uint32_t capacity,
             enum pluto_fb_observer_profile profile) {
  struct pluto_fb_observer_runtime runtime;
  memset(&runtime, 0, sizeof(runtime));
  runtime.profile = profile;
  runtime.real_ioctl = fake_ioctl;
  runtime.copy_from_self = noisy_copy;
  runtime.now = noisy_now;
  runtime.thread_id = noisy_tid;
  runtime.callback_context = context;
  pluto_fb_observer_writer_bind(&runtime.writer, header, records, capacity);
  return runtime;
}

static void test_abi_layouts(void) {
  CHECK(sizeof(struct pluto_fb_observer_file_header) == 64);
  CHECK(sizeof(struct pluto_fb_observer_record) == 416);
  CHECK(offsetof(struct pluto_fb_observer_record, payload) == 80);
  CHECK(sizeof(struct pluto_mxcfb_update_data_arm) == 72);
  CHECK(sizeof(struct pluto_mxcfb_update_marker_data_arm) == 8);
  CHECK(sizeof(struct pluto_fb_var_screeninfo_arm) == 160);
  CHECK(sizeof(struct pluto_fb_fix_screeninfo_arm) == 68);
  CHECK(offsetof(struct pluto_mxcfb_update_data_arm, waveform_mode) == 16);
  CHECK(offsetof(struct pluto_mxcfb_update_data_arm, update_mode) == 20);
  CHECK(offsetof(struct pluto_mxcfb_update_data_arm, update_marker) == 24);
  CHECK(offsetof(struct pluto_mxcfb_update_data_arm, temp) == 28);
  CHECK(offsetof(struct pluto_mxcfb_update_data_arm, flags) == 32);
  CHECK(offsetof(struct pluto_mxcfb_update_data_arm, dither_mode) == 36);
  CHECK(offsetof(struct pluto_mxcfb_update_data_arm, quant_bit) == 40);
  CHECK(offsetof(struct pluto_mxcfb_update_data_arm, alt_buffer_data) == 44);
  CHECK(offsetof(struct pluto_fb_fix_screeninfo_arm, line_length) == 44);
}

static void test_ioctl_is_transparent_and_captures_pre_post(void) {
  struct pluto_fb_observer_file_header header;
  struct pluto_fb_observer_record records[2];
  struct fake_context context;
  struct pluto_mxcfb_update_data_arm update;
  memset(&header, 0, sizeof(header));
  memset(records, 0, sizeof(records));
  memset(&context, 0, sizeof(context));
  memset(&update, 0, sizeof(update));
  update.update_region.top = 11;
  update.update_region.left = 22;
  update.update_region.width = 333;
  update.update_region.height = 444;
  update.waveform_mode = 7;
  update.update_mode = 1;
  update.update_marker = 0x12345678u;
  update.temp = -5;
  update.flags = 0xa5a5u;
  update.dither_mode = -3;
  update.quant_bit = 9;

  context.expected_fd = 19;
  context.expected_request = PLUTO_MXCFB_SEND_UPDATE;
  context.expected_argument = (uintptr_t)&update;
  context.result = -17;
  context.result_errno = EIO;
  context.marker_after_call = 0xabcdef01u;
  context.now = 1000;
  context.thread_id = 4242;
  struct pluto_fb_observer_runtime runtime = make_runtime(
      &context, &header, records, 2, PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_1);

  errno = EAGAIN;
  const int result = pluto_fb_observer_dispatch_ioctl(
      &runtime, 19, PLUTO_MXCFB_SEND_UPDATE, (uintptr_t)&update);
  CHECK(result == -17);
  CHECK(errno == EIO);
  CHECK(context.call_count == 1);
  CHECK(context.errno_seen == EAGAIN);
  CHECK(context.argument_seen.update_marker == 0x12345678u);
  CHECK(context.argument_seen.update_region.width == 333);
  CHECK(update.update_marker == 0xabcdef01u);

  CHECK(header.next_index == 1);
  CHECK(header.dropped_records == 0);
  const struct pluto_fb_observer_record *record = &records[0];
  CHECK(record->commit_sequence == 1);
  CHECK(record->sequence == 1);
  CHECK(record->record_type == PLUTO_FB_OBSERVER_RECORD_IOCTL);
  CHECK(record->payload_kind == PLUTO_FB_OBSERVER_PAYLOAD_MXCFB_UPDATE);
  CHECK(record->thread_id == 4242);
  CHECK(record->fd == 19);
  CHECK(record->request == PLUTO_MXCFB_SEND_UPDATE);
  CHECK(record->entry_monotonic_ns == 1100);
  CHECK(record->exit_monotonic_ns == 1200);
  CHECK(record->result == -17);
  CHECK(record->error_number == EIO);
  CHECK(record->payload_size == 144);
  CHECK(record->pre_size == 72);
  CHECK(record->post_size == 72);
  CHECK((record->flags & PLUTO_FB_OBSERVER_FLAG_PRE_VALID) != 0);
  CHECK((record->flags & PLUTO_FB_OBSERVER_FLAG_POST_VALID) != 0);
  CHECK((record->flags & PLUTO_FB_OBSERVER_FLAG_REAL_FAILED) != 0);
  const struct pluto_mxcfb_update_data_arm *pre = (const void *)record->payload;
  const struct pluto_mxcfb_update_data_arm *post =
      (const void *)(record->payload + sizeof(*pre));
  CHECK(pre->update_marker == 0x12345678u);
  CHECK(post->update_marker == 0xabcdef01u);
}

static void test_unknown_ioctl_is_only_forwarded(void) {
  struct pluto_fb_observer_file_header header;
  struct pluto_fb_observer_record record;
  struct fake_context context;
  memset(&header, 0, sizeof(header));
  memset(&record, 0, sizeof(record));
  memset(&context, 0, sizeof(context));
  context.expected_fd = 8;
  context.expected_request = 0xdeadbeefu;
  context.expected_argument = 0x1234u;
  context.result = 77;
  context.result_errno = EINPROGRESS;
  struct pluto_fb_observer_runtime runtime = make_runtime(
      &context, &header, &record, 1, PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_1);

  errno = ENOENT;
  const int result =
      pluto_fb_observer_dispatch_ioctl(&runtime, 8, 0xdeadbeefu, 0x1234u);
  CHECK(result == 77);
  CHECK(errno == EINPROGRESS);
  CHECK(context.call_count == 1);
  CHECK(context.errno_seen == ENOENT);
  CHECK(header.next_index == 0);
  CHECK(record.commit_sequence == 0);
}

static void test_immediate_blank_argument_is_not_dereferenced(void) {
  struct pluto_fb_observer_file_header header;
  struct pluto_fb_observer_record record;
  struct fake_context context;
  memset(&header, 0, sizeof(header));
  memset(&record, 0, sizeof(record));
  memset(&context, 0, sizeof(context));
  context.expected_fd = 3;
  context.expected_request = PLUTO_FBIOBLANK;
  context.expected_argument = 4;
  context.result = 0;
  context.result_errno = 0;
  context.thread_id = 9;
  struct pluto_fb_observer_runtime runtime = make_runtime(
      &context, &header, &record, 1, PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_2);

  errno = 0;
  CHECK(pluto_fb_observer_dispatch_ioctl(&runtime, 3, PLUTO_FBIOBLANK, 4) == 0);
  CHECK(context.call_count == 1);
  CHECK(record.payload_kind == PLUTO_FB_OBSERVER_PAYLOAD_U32);
  CHECK(record.pre_size == 4);
  CHECK(record.post_size == 4);
  uint32_t pre = 0;
  uint32_t post = 0;
  memcpy(&pre, record.payload, sizeof(pre));
  memcpy(&post, record.payload + sizeof(pre), sizeof(post));
  CHECK(pre == 4);
  CHECK(post == 4);
}

static void test_maximum_fb_var_pre_post_fills_payload_exactly(void) {
  struct pluto_fb_observer_file_header header;
  struct pluto_fb_observer_record record;
  struct fake_context context;
  struct pluto_fb_var_screeninfo_arm variable_info;
  memset(&header, 0, sizeof(header));
  memset(&record, 0, sizeof(record));
  memset(&context, 0, sizeof(context));
  memset(&variable_info, 0, sizeof(variable_info));
  variable_info.xres = 1404;
  variable_info.yres = 1872;
  variable_info.bits_per_pixel = 16;
  context.expected_fd = 7;
  context.expected_request = PLUTO_FBIOGET_VSCREENINFO;
  context.expected_argument = (uintptr_t)&variable_info;
  context.result = 0;
  context.result_errno = 0;
  struct pluto_fb_observer_runtime runtime = make_runtime(
      &context, &header, &record, 1, PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_2);

  CHECK(pluto_fb_observer_dispatch_ioctl(&runtime, 7, PLUTO_FBIOGET_VSCREENINFO,
                                         (uintptr_t)&variable_info) == 0);
  CHECK(context.call_count == 1);
  CHECK(record.payload_kind == PLUTO_FB_OBSERVER_PAYLOAD_FB_VAR);
  CHECK(record.payload_size == PLUTO_FB_OBSERVER_PAYLOAD_SIZE);
  CHECK(record.pre_size == sizeof(variable_info));
  CHECK(record.post_size == sizeof(variable_info));
  const struct pluto_fb_var_screeninfo_arm *pre = (const void *)record.payload;
  const struct pluto_fb_var_screeninfo_arm *post =
      (const void *)(record.payload + sizeof(variable_info));
  CHECK(pre->xres == 1404);
  CHECK(pre->yres == 1872);
  CHECK(post->bits_per_pixel == 16);
}

static void test_unreadable_argument_does_not_change_kernel_result(void) {
  struct pluto_fb_observer_file_header header;
  struct pluto_fb_observer_record record;
  struct fake_context context;
  memset(&header, 0, sizeof(header));
  memset(&record, 0, sizeof(record));
  memset(&context, 0, sizeof(context));
  context.expected_fd = 7;
  context.expected_request = PLUTO_FBIOGET_FSCREENINFO;
  context.expected_argument = 0;
  context.result = -1;
  context.result_errno = EFAULT;
  struct pluto_fb_observer_runtime runtime = make_runtime(
      &context, &header, &record, 1, PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_2);

  errno = ENOMEM;
  CHECK(pluto_fb_observer_dispatch_ioctl(&runtime, 7, PLUTO_FBIOGET_FSCREENINFO,
                                         0) == -1);
  CHECK(context.call_count == 1);
  CHECK(context.errno_seen == ENOMEM);
  CHECK(errno == EFAULT);
  CHECK(record.payload_kind == PLUTO_FB_OBSERVER_PAYLOAD_FB_FIX);
  CHECK((record.flags & PLUTO_FB_OBSERVER_FLAG_PRE_VALID) == 0);
  CHECK((record.flags & PLUTO_FB_OBSERVER_FLAG_POST_VALID) == 0);
  CHECK((record.flags & PLUTO_FB_OBSERVER_FLAG_REAL_FAILED) != 0);
}

static void test_bounded_writer_counts_drops(void) {
  struct pluto_fb_observer_file_header header;
  struct pluto_fb_observer_record record;
  struct fake_context context;
  memset(&header, 0, sizeof(header));
  memset(&record, 0, sizeof(record));
  memset(&context, 0, sizeof(context));
  context.expected_fd = 5;
  context.expected_request = PLUTO_FBIOBLANK;
  context.expected_argument = 0;
  context.result = 0;
  struct pluto_fb_observer_runtime runtime = make_runtime(
      &context, &header, &record, 1, PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_2);

  CHECK(pluto_fb_observer_dispatch_ioctl(&runtime, 5, PLUTO_FBIOBLANK, 0) == 0);
  CHECK(pluto_fb_observer_dispatch_ioctl(&runtime, 5, PLUTO_FBIOBLANK, 0) == 0);
  CHECK(context.call_count == 2);
  CHECK(header.next_index == 2);
  CHECK(header.dropped_records == 1);
  CHECK(record.commit_sequence == 1);
  CHECK(record.sequence == 1);
}

int main(void) {
  test_abi_layouts();
  test_ioctl_is_transparent_and_captures_pre_post();
  test_unknown_ioctl_is_only_forwarded();
  test_immediate_blank_argument_is_not_dereferenced();
  test_maximum_fb_var_pre_post_fills_payload_exactly();
  test_unreadable_argument_does_not_change_kernel_result();
  test_bounded_writer_counts_drops();
  puts("framebuffer observer C tests: PASS");
  return 0;
}
