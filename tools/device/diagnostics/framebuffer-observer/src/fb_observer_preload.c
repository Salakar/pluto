#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE

#if !defined(__linux__)
#error "the preload observer is Linux-only"
#endif

#include "fb_observer_internal.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#define PLUTO_FB_OBSERVER_DEFAULT_OUTPUT "/run/pluto-fb-observer.bin"
#define PLUTO_FB_OBSERVER_DEFAULT_CAPACITY 32768u
#define PLUTO_FB_OBSERVER_MAX_CAPACITY 131072u
#define PLUTO_FB_OBSERVER_TRACKED_FDS 4096
#define PLUTO_FB_OBSERVER_TRACKED_MAPPINGS 8
#define PLUTO_REMARKABLE_FB_MAJOR 29u
#define PLUTO_REMARKABLE_FB_MINOR 0u

#define PLUTO_EXPORT __attribute__((visibility("default")))

typedef int (*open_fn)(const char *path, int flags, ...);
typedef int (*close_fn)(int fd);
typedef int (*ioctl_fn)(int fd, unsigned long request, ...);
typedef void *(*mmap_fn)(void *address, size_t length, int protection,
                         int flags, int fd, off_t offset);
typedef void *(*mmap64_fn)(void *address, size_t length, int protection,
                           int flags, int fd, off64_t offset);
typedef int (*munmap_fn)(void *address, size_t length);

struct tracked_mapping {
  uintptr_t address;
  size_t length;
};

static open_fn g_real_open;
static open_fn g_real_open64;
static close_fn g_real_close;
static ioctl_fn g_real_ioctl;
static mmap_fn g_real_mmap;
static mmap64_fn g_real_mmap64;
static munmap_fn g_real_munmap;

static bool g_initializing = true;
static bool g_enabled;
static uint8_t g_framebuffer_fds[PLUTO_FB_OBSERVER_TRACKED_FDS];
static struct tracked_mapping
    g_framebuffer_mappings[PLUTO_FB_OBSERVER_TRACKED_MAPPINGS];
static void *g_trace_mapping;
static size_t g_trace_mapping_size;
static int g_trace_fd = -1;
static struct pluto_fb_observer_runtime g_runtime;

static void resolve_symbols(void) {
  g_real_open = (open_fn)dlsym(RTLD_NEXT, "open");
  g_real_open64 = (open_fn)dlsym(RTLD_NEXT, "open64");
  g_real_close = (close_fn)dlsym(RTLD_NEXT, "close");
  g_real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
  g_real_mmap = (mmap_fn)dlsym(RTLD_NEXT, "mmap");
  g_real_mmap64 = (mmap64_fn)dlsym(RTLD_NEXT, "mmap64");
  g_real_munmap = (munmap_fn)dlsym(RTLD_NEXT, "munmap");
}

static int direct_open(const char *path, int flags, mode_t mode,
                       bool has_mode) {
  (void)has_mode;
  return (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
}

static int call_open(open_fn function, const char *path, int flags, mode_t mode,
                     bool has_mode) {
  if (function == NULL) {
    return direct_open(path, flags, mode, has_mode);
  }
  return has_mode ? function(path, flags, mode) : function(path, flags);
}

static int call_close(int fd) {
  return g_real_close == NULL ? (int)syscall(SYS_close, fd) : g_real_close(fd);
}

static int call_ioctl(int fd, unsigned long request, uintptr_t argument) {
  return g_real_ioctl == NULL ? (int)syscall(SYS_ioctl, fd, request, argument)
                              : g_real_ioctl(fd, request, argument);
}

static void *direct_mmap(void *address, size_t length, int protection,
                         int flags, int fd, int64_t offset) {
#if defined(SYS_mmap2)
  const uint64_t page_size = 4096u;
  if (offset < 0 || ((uint64_t)offset % page_size) != 0 ||
      ((uint64_t)offset / page_size) > UINT32_MAX) {
    errno = EINVAL;
    return MAP_FAILED;
  }
  return (void *)syscall(SYS_mmap2, address, length, protection, flags, fd,
                         (unsigned long)((uint64_t)offset / page_size));
#elif defined(SYS_mmap)
  return (void *)syscall(SYS_mmap, address, length, protection, flags, fd,
                         (off_t)offset);
#else
#error "no mmap syscall is available"
#endif
}

static void *call_mmap(void *address, size_t length, int protection, int flags,
                       int fd, off_t offset) {
  return g_real_mmap == NULL
             ? direct_mmap(address, length, protection, flags, fd,
                           (int64_t)offset)
             : g_real_mmap(address, length, protection, flags, fd, offset);
}

static void *call_mmap64(void *address, size_t length, int protection,
                         int flags, int fd, off64_t offset) {
  return g_real_mmap64 == NULL
             ? direct_mmap(address, length, protection, flags, fd,
                           (int64_t)offset)
             : g_real_mmap64(address, length, protection, flags, fd, offset);
}

static int call_munmap(void *address, size_t length) {
  return g_real_munmap == NULL ? (int)syscall(SYS_munmap, address, length)
                               : g_real_munmap(address, length);
}

static uint64_t monotonic_now(void *context) {
  (void)context;
  struct timespec timestamp;
  if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) {
    return 0;
  }
  return (uint64_t)timestamp.tv_sec * 1000000000u + (uint64_t)timestamp.tv_nsec;
}

static uint32_t current_thread_id(void *context) {
  (void)context;
#if defined(SYS_gettid)
  return (uint32_t)syscall(SYS_gettid);
#else
  return (uint32_t)getpid();
#endif
}

static size_t safe_copy_from_self(void *context, void *destination,
                                  const void *source, size_t size) {
  (void)context;
  struct iovec local = {.iov_base = destination, .iov_len = size};
  struct iovec remote = {.iov_base = (void *)source, .iov_len = size};
  const ssize_t copied = process_vm_readv(getpid(), &local, 1, &remote, 1, 0);
  return copied < 0 ? 0 : (size_t)copied;
}

static int real_ioctl_adapter(void *context, int fd, unsigned long request,
                              uintptr_t argument) {
  (void)context;
  return call_ioctl(fd, request, argument);
}

static bool env_is_one(const char *name) {
  const char *value = getenv(name);
  return value != NULL && strcmp(value, "1") == 0;
}

static enum pluto_fb_observer_profile selected_profile(void) {
  const char *value = getenv("PLUTO_FB_OBSERVER_PROFILE");
  if (value == NULL) {
    return PLUTO_FB_OBSERVER_PROFILE_UNKNOWN;
  }
  if (strcmp(value, "remarkable1") == 0) {
    return PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_1;
  }
  if (strcmp(value, "remarkable2") == 0) {
    return PLUTO_FB_OBSERVER_PROFILE_REMARKABLE_2;
  }
  return PLUTO_FB_OBSERVER_PROFILE_UNKNOWN;
}

static bool process_is_xochitl(void) {
  char executable[PATH_MAX];
  const ssize_t length =
      readlink("/proc/self/exe", executable, sizeof(executable) - 1u);
  if (length <= 0 || (size_t)length >= sizeof(executable)) {
    return false;
  }
  executable[length] = '\0';
  const char *basename = strrchr(executable, '/');
  basename = basename == NULL ? executable : basename + 1;
  return strcmp(basename, "xochitl") == 0;
}

static uint32_t selected_capacity(void) {
  const char *value = getenv("PLUTO_FB_OBSERVER_CAPACITY");
  if (value == NULL || *value == '\0') {
    return PLUTO_FB_OBSERVER_DEFAULT_CAPACITY;
  }
  char *end = NULL;
  errno = 0;
  const unsigned long parsed = strtoul(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed == 0 ||
      parsed > PLUTO_FB_OBSERVER_MAX_CAPACITY) {
    return 0;
  }
  return (uint32_t)parsed;
}

static bool path_is_framebuffer(const char *path) {
  return path != NULL && strcmp(path, "/dev/fb0") == 0;
}

static void cache_framebuffer_fd(int fd, bool is_framebuffer) {
  if (fd < 0 || fd >= PLUTO_FB_OBSERVER_TRACKED_FDS) {
    return;
  }
  __atomic_store_n(&g_framebuffer_fds[fd], is_framebuffer ? 1u : 0u,
                   __ATOMIC_RELEASE);
}

static bool descriptor_is_framebuffer_device(int fd) {
  const int saved_errno = errno;
  struct stat status;
  const bool matches =
      fstat(fd, &status) == 0 && S_ISCHR(status.st_mode) &&
      (unsigned int)major(status.st_rdev) == PLUTO_REMARKABLE_FB_MAJOR &&
      (unsigned int)minor(status.st_rdev) == PLUTO_REMARKABLE_FB_MINOR;
  errno = saved_errno;
  return matches;
}

static bool fd_is_framebuffer(int fd) {
  if (fd < 0) {
    return false;
  }
  if (fd < PLUTO_FB_OBSERVER_TRACKED_FDS &&
      __atomic_load_n(&g_framebuffer_fds[fd], __ATOMIC_ACQUIRE) != 0) {
    return true;
  }

  const bool matches = descriptor_is_framebuffer_device(fd);
  if (matches) {
    cache_framebuffer_fd(fd, true);
  }
  return matches;
}

static void track_mapping(uintptr_t address, size_t length) {
  for (size_t index = 0; index < PLUTO_FB_OBSERVER_TRACKED_MAPPINGS; ++index) {
    uintptr_t expected = 0;
    if (__atomic_compare_exchange_n(&g_framebuffer_mappings[index].address,
                                    &expected, address, false, __ATOMIC_ACQ_REL,
                                    __ATOMIC_RELAXED)) {
      __atomic_store_n(&g_framebuffer_mappings[index].length, length,
                       __ATOMIC_RELEASE);
      return;
    }
  }
}

static bool mapping_is_tracked(uintptr_t address, size_t *length) {
  for (size_t index = 0; index < PLUTO_FB_OBSERVER_TRACKED_MAPPINGS; ++index) {
    if (__atomic_load_n(&g_framebuffer_mappings[index].address,
                        __ATOMIC_ACQUIRE) == address) {
      *length = __atomic_load_n(&g_framebuffer_mappings[index].length,
                                __ATOMIC_ACQUIRE);
      return true;
    }
  }
  return false;
}

static void untrack_mapping(uintptr_t address) {
  for (size_t index = 0; index < PLUTO_FB_OBSERVER_TRACKED_MAPPINGS; ++index) {
    if (__atomic_load_n(&g_framebuffer_mappings[index].address,
                        __ATOMIC_ACQUIRE) == address) {
      __atomic_store_n(&g_framebuffer_mappings[index].length, 0,
                       __ATOMIC_RELEASE);
      __atomic_store_n(&g_framebuffer_mappings[index].address, 0,
                       __ATOMIC_RELEASE);
      return;
    }
  }
}

static bool open_flags_have_mode(int flags) {
  if ((flags & O_CREAT) != 0) {
    return true;
  }
#if defined(O_TMPFILE)
  return (flags & O_TMPFILE) == O_TMPFILE;
#else
  return false;
#endif
}

static int interposed_open(open_fn function, const char *path, int flags,
                           va_list arguments) {
  const bool has_mode = open_flags_have_mode(flags);
  const mode_t mode = has_mode ? (mode_t)va_arg(arguments, int) : 0;
  const int fd = call_open(function, path, flags, mode, has_mode);
  const int open_errno = errno;
  if (g_enabled && !g_initializing && fd >= 0 && path_is_framebuffer(path) &&
      descriptor_is_framebuffer_device(fd)) {
    cache_framebuffer_fd(fd, true);
    pluto_fb_observer_record_open(&g_runtime, fd, flags,
                                  PLUTO_FB_OBSERVER_FLAG_PATH_MATCH |
                                      PLUTO_FB_OBSERVER_FLAG_DEVICE_MATCH);
  }
  errno = open_errno;
  return fd;
}

PLUTO_EXPORT int open(const char *path, int flags, ...) {
  va_list arguments;
  va_start(arguments, flags);
  const int result = interposed_open(g_real_open, path, flags, arguments);
  va_end(arguments);
  return result;
}

PLUTO_EXPORT int open64(const char *path, int flags, ...) {
  va_list arguments;
  va_start(arguments, flags);
  const int result =
      interposed_open(g_real_open64 == NULL ? g_real_open : g_real_open64, path,
                      flags, arguments);
  va_end(arguments);
  return result;
}

PLUTO_EXPORT int close(int fd) {
  const int result = call_close(fd);
  const int close_errno = errno;
  if (result == 0) {
    cache_framebuffer_fd(fd, false);
  }
  errno = close_errno;
  return result;
}

PLUTO_EXPORT int ioctl(int fd, unsigned long request, ...) {
  va_list arguments;
  va_start(arguments, request);
  const uintptr_t argument = va_arg(arguments, uintptr_t);
  va_end(arguments);

  if (!g_enabled || g_initializing ||
      !pluto_fb_observer_request_is_observed(g_runtime.profile, request) ||
      !fd_is_framebuffer(fd)) {
    return call_ioctl(fd, request, argument);
  }
  return pluto_fb_observer_dispatch_ioctl(&g_runtime, fd, request, argument);
}

static void record_successful_mmap(void *result, size_t length, int fd,
                                   int64_t offset, int mmap_errno) {
  if (!g_enabled || g_initializing || result == MAP_FAILED ||
      !fd_is_framebuffer(fd)) {
    return;
  }
  track_mapping((uintptr_t)result, length);
  pluto_fb_observer_record_mapping(&g_runtime, PLUTO_FB_OBSERVER_RECORD_MMAP,
                                   fd, (uintptr_t)result, (uint64_t)length,
                                   offset, 0, mmap_errno,
                                   PLUTO_FB_OBSERVER_FLAG_DEVICE_MATCH);
}

PLUTO_EXPORT void *mmap(void *address, size_t length, int protection, int flags,
                        int fd, off_t offset) {
  void *result = call_mmap(address, length, protection, flags, fd, offset);
  const int mmap_errno = errno;
  record_successful_mmap(result, length, fd, (int64_t)offset, mmap_errno);
  errno = mmap_errno;
  return result;
}

PLUTO_EXPORT void *mmap64(void *address, size_t length, int protection,
                          int flags, int fd, off64_t offset) {
  void *result = call_mmap64(address, length, protection, flags, fd, offset);
  const int mmap_errno = errno;
  record_successful_mmap(result, length, fd, (int64_t)offset, mmap_errno);
  errno = mmap_errno;
  return result;
}

PLUTO_EXPORT int munmap(void *address, size_t length) {
  size_t tracked_length = 0;
  const bool tracked = g_enabled && !g_initializing &&
                       mapping_is_tracked((uintptr_t)address, &tracked_length);
  const int result = call_munmap(address, length);
  const int munmap_errno = errno;
  if (tracked) {
    uint16_t flags = PLUTO_FB_OBSERVER_FLAG_DEVICE_MATCH;
    if (result < 0) {
      flags |= PLUTO_FB_OBSERVER_FLAG_REAL_FAILED;
    } else {
      untrack_mapping((uintptr_t)address);
    }
    pluto_fb_observer_record_mapping(
        &g_runtime, PLUTO_FB_OBSERVER_RECORD_MUNMAP, -1, (uintptr_t)address,
        (uint64_t)length, 0, result, munmap_errno, flags);
    (void)tracked_length;
  }
  errno = munmap_errno;
  return result;
}

static bool initialize_trace(enum pluto_fb_observer_profile profile) {
  const uint32_t capacity = selected_capacity();
  if (capacity == 0) {
    return false;
  }
  const char *output = getenv("PLUTO_FB_OBSERVER_OUTPUT");
  if (output == NULL || *output == '\0') {
    output = PLUTO_FB_OBSERVER_DEFAULT_OUTPUT;
  }

  const size_t mapping_size =
      sizeof(struct pluto_fb_observer_file_header) +
      (size_t)capacity * sizeof(struct pluto_fb_observer_record);
  const int fd = call_open(g_real_open, output,
                           O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600, true);
  if (fd < 0 || ftruncate(fd, (off_t)mapping_size) != 0) {
    if (fd >= 0) {
      (void)call_close(fd);
    }
    return false;
  }

  void *mapping =
      call_mmap(NULL, mapping_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (mapping == MAP_FAILED) {
    (void)call_close(fd);
    return false;
  }

  struct pluto_fb_observer_file_header *header = mapping;
  memset(mapping, 0, mapping_size);
  memcpy(header->magic, PLUTO_FB_OBSERVER_MAGIC, sizeof(header->magic));
  header->schema_version = PLUTO_FB_OBSERVER_SCHEMA_VERSION;
  header->header_size = PLUTO_FB_OBSERVER_HEADER_SIZE;
  header->record_size = PLUTO_FB_OBSERVER_RECORD_SIZE;
  header->capacity = capacity;
  header->profile = (uint32_t)profile;
  header->start_monotonic_ns = monotonic_now(NULL);
  header->process_id = (uint32_t)getpid();
  header->endian_tag = PLUTO_FB_OBSERVER_ENDIAN_TAG;

  g_trace_fd = fd;
  g_trace_mapping = mapping;
  g_trace_mapping_size = mapping_size;
  g_runtime.profile = profile;
  g_runtime.real_ioctl = real_ioctl_adapter;
  g_runtime.copy_from_self = safe_copy_from_self;
  g_runtime.now = monotonic_now;
  g_runtime.thread_id = current_thread_id;
  g_runtime.callback_context = NULL;
  pluto_fb_observer_writer_bind(
      &g_runtime.writer, header,
      (struct pluto_fb_observer_record *)((uint8_t *)mapping + sizeof(*header)),
      capacity);
  return true;
}

__attribute__((constructor)) static void pluto_fb_observer_initialize(void) {
  resolve_symbols();
  if (!env_is_one("PLUTO_FB_OBSERVER_ENABLE") || !process_is_xochitl()) {
    g_initializing = false;
    return;
  }
  const enum pluto_fb_observer_profile profile = selected_profile();
  if (profile != PLUTO_FB_OBSERVER_PROFILE_UNKNOWN &&
      initialize_trace(profile)) {
    g_enabled = true;
  }
  g_initializing = false;
}

__attribute__((destructor)) static void pluto_fb_observer_shutdown(void) {
  g_enabled = false;
  g_initializing = true;
  if (g_trace_mapping != NULL) {
    (void)msync(g_trace_mapping, g_trace_mapping_size, MS_SYNC);
    (void)call_munmap(g_trace_mapping, g_trace_mapping_size);
    g_trace_mapping = NULL;
  }
  if (g_trace_fd >= 0) {
    (void)call_close(g_trace_fd);
    g_trace_fd = -1;
  }
}
