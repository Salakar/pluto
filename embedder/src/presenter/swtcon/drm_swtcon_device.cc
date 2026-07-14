#include "presenter/swtcon/drm_swtcon_device.h"

#include <algorithm>
#include <cerrno>
#include <cstring>

#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>

namespace pluto::swtcon {
namespace {

constexpr std::uint64_t kDrmClientCapUniversalPlanes = 2;
constexpr std::uint64_t kDrmClientCapAtomic = 3;
constexpr std::uint64_t kDrmCapDumbBuffer = 1;
constexpr std::uint64_t kDrmCapAtomicKms = 0x12;

constexpr unsigned long kDrmIoctlModeCreateDumb = 0xc02064b2UL;
constexpr unsigned long kDrmIoctlModeMapDumb = 0xc01064b3UL;
constexpr unsigned long kDrmIoctlModeDestroyDumb = 0xc00464b4UL;
constexpr unsigned long kDrmIoctlModeAtomic = 0xc03864bcUL;

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

std::string errno_message(const char *what) {
  return std::string(what) + ": " + std::strerror(errno);
}

void set_error(std::string *error, const std::string &message) {
  if (error != nullptr) {
    *error = message;
  }
}

struct RawModeInfo {
  std::uint32_t clock;
  std::uint16_t hdisplay;
  std::uint16_t hsync_start;
  std::uint16_t hsync_end;
  std::uint16_t htotal;
  std::uint16_t hskew;
  std::uint16_t vdisplay;
  std::uint16_t vsync_start;
  std::uint16_t vsync_end;
  std::uint16_t vtotal;
  std::uint16_t vscan;
  std::uint32_t vrefresh;
  std::uint32_t flags;
  std::uint32_t type;
  char name[32];
};

static_assert(sizeof(RawModeInfo) == sizeof(DrmModeInfo));

struct RawModeRes {
  int count_fbs;
  std::uint32_t *fbs;
  int count_crtcs;
  std::uint32_t *crtcs;
  int count_connectors;
  std::uint32_t *connectors;
  int count_encoders;
  std::uint32_t *encoders;
  std::uint32_t min_width;
  std::uint32_t max_width;
  std::uint32_t min_height;
  std::uint32_t max_height;
};

struct RawConnector {
  std::uint32_t connector_id;
  std::uint32_t encoder_id;
  std::uint32_t connector_type;
  std::uint32_t connector_type_id;
  std::uint32_t connection;
  std::uint32_t mm_width;
  std::uint32_t mm_height;
  std::uint32_t subpixel;
  int count_modes;
  RawModeInfo *modes;
  int count_props;
  std::uint32_t *props;
  std::uint64_t *prop_values;
  int count_encoders;
  std::uint32_t *encoders;
};

struct RawEncoder {
  std::uint32_t encoder_id;
  std::uint32_t encoder_type;
  std::uint32_t crtc_id;
  std::uint32_t possible_crtcs;
  std::uint32_t possible_clones;
};

struct RawPlaneRes {
  std::uint32_t count_planes;
  std::uint32_t *planes;
};

struct RawPlane {
  std::uint32_t count_formats;
  std::uint32_t *formats;
  std::uint32_t plane_id;
  std::uint32_t crtc_id;
  std::uint32_t fb_id;
  std::uint32_t possible_crtcs;
  std::uint32_t gamma_size;
};

struct RawObjectProperties {
  std::uint32_t count_props;
  std::uint32_t *props;
  std::uint64_t *prop_values;
};

struct RawPropertyRes {
  std::uint32_t prop_id;
  std::uint32_t flags;
  char name[32];
  int count_values;
  std::uint64_t *values;
  int count_enums;
  void *enums;
  int count_blobs;
  std::uint32_t *blob_ids;
};

struct RawCreateDumb {
  std::uint32_t height;
  std::uint32_t width;
  std::uint32_t bpp;
  std::uint32_t flags;
  std::uint32_t handle;
  std::uint32_t pitch;
  std::uint64_t size;
};

struct RawMapDumb {
  std::uint32_t handle;
  std::uint32_t pad;
  std::uint64_t offset;
};

struct RawDestroyDumb {
  std::uint32_t handle;
};

struct RawModeAtomic {
  std::uint32_t flags;
  std::uint32_t count_objs;
  std::uint64_t objs_ptr;
  std::uint64_t count_props_ptr;
  std::uint64_t props_ptr;
  std::uint64_t prop_values_ptr;
  std::uint64_t reserved;
  std::uint64_t user_data;
};

static_assert(sizeof(RawModeAtomic) == 0x38);

// Kernel drm_event / drm_event_vblank wire layout (uapi/drm/drm.h; defined
// locally like the other raw structs so the host build needs no libdrm
// headers).
constexpr std::uint32_t kDrmEventFlipComplete = 0x02;

struct RawDrmEvent {
  std::uint32_t type;
  std::uint32_t length;
};

struct RawDrmEventVblank {
  RawDrmEvent base;
  std::uint64_t user_data;
  std::uint32_t tv_sec;
  std::uint32_t tv_usec;
  std::uint32_t sequence;
  std::uint32_t crtc_id;
};

static_assert(sizeof(RawDrmEventVblank) == 32);

DrmModeInfo to_mode_info(const RawModeInfo &raw) {
  DrmModeInfo out{};
  std::memcpy(&out, &raw, sizeof(out));
  return out;
}

RawModeInfo to_raw_mode_info(const DrmModeInfo &mode) {
  RawModeInfo out{};
  std::memcpy(&out, &mode, sizeof(out));
  return out;
}

template <typename T>
bool load_symbol(void *handle, const char *name, T *out, std::string *error) {
  dlerror();
  void *symbol = dlsym(handle, name);
  const char *dlsym_error = dlerror();
  if (dlsym_error != nullptr || symbol == nullptr) {
    set_error(error, std::string("libdrm missing symbol ") + name);
    return false;
  }
  *out = reinterpret_cast<T>(symbol);
  return true;
}

class RealDrmInterface final : public DrmInterface {
public:
  ~RealDrmInterface() override {
    if (libdrm_ != nullptr) {
      dlclose(libdrm_);
      libdrm_ = nullptr;
    }
  }

  int open_card(const std::string &path, std::string *error) override {
    const int fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
    if (fd < 0) {
      set_error(error, errno_message(("open " + path).c_str()));
    }
    return fd;
  }

  void close_fd(int fd) override {
    if (fd >= 0) {
      ::close(fd);
    }
  }

  bool set_client_cap(int fd, std::uint64_t capability, std::uint64_t value,
                      std::string *error) override {
    if (!ensure_loaded(error)) {
      return false;
    }
    if (drm_set_client_cap_(fd, capability, value) != 0) {
      set_error(error, errno_message("drmSetClientCap"));
      return false;
    }
    return true;
  }

  bool get_cap(int fd, std::uint64_t capability, std::uint64_t *value,
               std::string *error) override {
    if (value == nullptr) {
      set_error(error, "null DRM cap output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    if (drm_get_cap_(fd, capability, value) != 0) {
      set_error(error, errno_message("drmGetCap"));
      return false;
    }
    return true;
  }

  bool get_resources(int fd, DrmResources *out, std::string *error) override {
    if (out == nullptr) {
      set_error(error, "null DRM resources output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    RawModeRes *raw = drm_mode_get_resources_(fd);
    if (raw == nullptr) {
      set_error(error, errno_message("drmModeGetResources"));
      return false;
    }
    out->crtcs.assign(raw->crtcs, raw->crtcs + raw->count_crtcs);
    out->connectors.assign(raw->connectors,
                           raw->connectors + raw->count_connectors);
    drm_mode_free_resources_(raw);
    return true;
  }

  bool get_connector(int fd, std::uint32_t connector_id, DrmConnectorInfo *out,
                     std::string *error) override {
    if (out == nullptr) {
      set_error(error, "null DRM connector output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    RawConnector *raw = drm_mode_get_connector_(fd, connector_id);
    if (raw == nullptr) {
      set_error(error, errno_message("drmModeGetConnector"));
      return false;
    }
    out->connector_id = raw->connector_id;
    out->encoder_id = raw->encoder_id;
    out->connected = raw->connection == 1;
    out->modes.clear();
    for (int i = 0; i < raw->count_modes; ++i) {
      out->modes.push_back(to_mode_info(raw->modes[i]));
    }
    out->encoders.assign(raw->encoders, raw->encoders + raw->count_encoders);
    out->properties.clear();
    for (int i = 0; i < raw->count_props; ++i) {
      DrmPropertyValue prop{};
      prop.id = raw->props[i];
      prop.value = raw->prop_values[i];
      read_property_name(fd, prop.id, &prop.name);
      out->properties.push_back(std::move(prop));
    }
    drm_mode_free_connector_(raw);
    return true;
  }

  bool get_encoder(int fd, std::uint32_t encoder_id, DrmEncoderInfo *out,
                   std::string *error) override {
    if (out == nullptr) {
      set_error(error, "null DRM encoder output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    RawEncoder *raw = drm_mode_get_encoder_(fd, encoder_id);
    if (raw == nullptr) {
      set_error(error, errno_message("drmModeGetEncoder"));
      return false;
    }
    out->encoder_id = raw->encoder_id;
    out->crtc_id = raw->crtc_id;
    out->possible_crtcs = raw->possible_crtcs;
    drm_mode_free_encoder_(raw);
    return true;
  }

  bool get_plane_ids(int fd, std::vector<std::uint32_t> *out,
                     std::string *error) override {
    if (out == nullptr) {
      set_error(error, "null DRM plane id output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    RawPlaneRes *raw = drm_mode_get_plane_resources_(fd);
    if (raw == nullptr) {
      set_error(error, errno_message("drmModeGetPlaneResources"));
      return false;
    }
    out->assign(raw->planes, raw->planes + raw->count_planes);
    drm_mode_free_plane_resources_(raw);
    return true;
  }

  bool get_plane(int fd, std::uint32_t plane_id, DrmPlaneInfo *out,
                 std::string *error) override {
    if (out == nullptr) {
      set_error(error, "null DRM plane output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    RawPlane *raw = drm_mode_get_plane_(fd, plane_id);
    if (raw == nullptr) {
      set_error(error, errno_message("drmModeGetPlane"));
      return false;
    }
    out->plane_id = raw->plane_id;
    out->possible_crtcs = raw->possible_crtcs;
    out->properties.clear();
    RawObjectProperties *props =
        drm_mode_object_get_properties_(fd, plane_id, 0xeeeeeeeeU);
    if (props != nullptr) {
      for (std::uint32_t i = 0; i < props->count_props; ++i) {
        DrmPropertyValue prop{};
        prop.id = props->props[i];
        prop.value = props->prop_values[i];
        read_property_name(fd, prop.id, &prop.name);
        out->properties.push_back(std::move(prop));
      }
      drm_mode_free_object_properties_(props);
    }
    drm_mode_free_plane_(raw);
    return true;
  }

  bool create_dumb(int fd, std::uint32_t width, std::uint32_t height,
                   std::uint32_t bpp, DrmDumbCreateResult *out,
                   std::string *error) override {
    if (out == nullptr) {
      set_error(error, "null dumb create output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    RawCreateDumb create{};
    create.width = width;
    create.height = height;
    create.bpp = bpp;
    if (drm_ioctl_(fd, kDrmIoctlModeCreateDumb, &create) != 0) {
      set_error(error, errno_message("DRM_IOCTL_MODE_CREATE_DUMB"));
      return false;
    }
    out->handle = create.handle;
    out->pitch = create.pitch;
    out->size = create.size;
    return true;
  }

  bool add_fb(int fd, std::uint32_t width, std::uint32_t height,
              std::uint8_t depth, std::uint8_t bpp, std::uint32_t pitch,
              std::uint32_t handle, std::uint32_t *fb_id,
              std::string *error) override {
    if (fb_id == nullptr) {
      set_error(error, "null FB id output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    if (drm_mode_add_fb_(fd, width, height, depth, bpp, pitch, handle, fb_id) !=
        0) {
      set_error(error, errno_message("drmModeAddFB"));
      return false;
    }
    return true;
  }

  bool map_dumb(int fd, std::uint32_t handle, std::uint64_t *offset,
                std::string *error) override {
    if (offset == nullptr) {
      set_error(error, "null dumb map output");
      return false;
    }
    if (!ensure_loaded(error)) {
      return false;
    }
    RawMapDumb map{};
    map.handle = handle;
    if (drm_ioctl_(fd, kDrmIoctlModeMapDumb, &map) != 0) {
      set_error(error, errno_message("DRM_IOCTL_MODE_MAP_DUMB"));
      return false;
    }
    *offset = map.offset;
    return true;
  }

  void *mmap_dumb(int fd, std::uint64_t offset, std::uint64_t size,
                  std::string *error) override {
    void *mapped =
        ::mmap(nullptr, static_cast<std::size_t>(size), PROT_READ | PROT_WRITE,
               MAP_SHARED, fd, static_cast<off_t>(offset));
    if (mapped == MAP_FAILED) {
      set_error(error, errno_message("mmap dumb buffer"));
      return nullptr;
    }
    return mapped;
  }

  void munmap_dumb(void *address, std::uint64_t size) override {
    if (address != nullptr) {
      ::munmap(address, static_cast<std::size_t>(size));
    }
  }

  bool rm_fb(int fd, std::uint32_t fb_id, std::string *error) override {
    if (!ensure_loaded(error)) {
      return false;
    }
    if (drm_mode_rm_fb_(fd, fb_id) != 0) {
      set_error(error, errno_message("drmModeRmFB"));
      return false;
    }
    return true;
  }

  bool destroy_dumb(int fd, std::uint32_t handle, std::string *error) override {
    if (!ensure_loaded(error)) {
      return false;
    }
    RawDestroyDumb destroy{};
    destroy.handle = handle;
    if (drm_ioctl_(fd, kDrmIoctlModeDestroyDumb, &destroy) != 0) {
      set_error(error, errno_message("DRM_IOCTL_MODE_DESTROY_DUMB"));
      return false;
    }
    return true;
  }

  bool set_crtc(int fd, std::uint32_t crtc_id, std::uint32_t fb_id,
                std::uint32_t connector_id, const DrmModeInfo &mode,
                std::string *error) override {
    if (!ensure_loaded(error)) {
      return false;
    }
    std::uint32_t connector = connector_id;
    RawModeInfo raw_mode = to_raw_mode_info(mode);
    if (drm_mode_set_crtc_(fd, crtc_id, fb_id, 0, 0, &connector, 1,
                           &raw_mode) != 0) {
      set_error(error, errno_message("drmModeSetCrtc"));
      return false;
    }
    return true;
  }

  bool blank_crtc(int fd, std::uint32_t crtc_id, std::string *error) override {
    if (!ensure_loaded(error)) {
      return false;
    }
    if (drm_mode_set_crtc_(fd, crtc_id, 0, 0, 0, nullptr, 0, nullptr) != 0) {
      set_error(error, errno_message("drmModeSetCrtc blank"));
      return false;
    }
    return true;
  }

  bool set_connector_property(int fd, std::uint32_t connector_id,
                              std::uint32_t property_id, std::uint64_t value,
                              std::string *error) override {
    if (!ensure_loaded(error)) {
      return false;
    }
    if (drm_mode_connector_set_property_(fd, connector_id, property_id,
                                         value) != 0) {
      set_error(error, errno_message("drmModeConnectorSetProperty"));
      return false;
    }
    return true;
  }

  bool atomic_commit(int fd, const DrmAtomicRequest &request,
                     std::string *error) override {
    if (!ensure_loaded(error)) {
      return false;
    }
    if (request.objects.empty() ||
        request.objects.size() != request.property_counts.size() ||
        request.properties.size() != request.values.size()) {
      set_error(error, "invalid DRM atomic request");
      return false;
    }
    std::size_t expected_props = 0;
    for (std::uint32_t count : request.property_counts) {
      expected_props += count;
    }
    if (expected_props != request.properties.size()) {
      set_error(error, "DRM atomic property count mismatch");
      return false;
    }

    RawModeAtomic raw{};
    raw.flags = request.flags;
    raw.user_data = request.user_data;
    raw.count_objs = static_cast<std::uint32_t>(request.objects.size());
    raw.objs_ptr = reinterpret_cast<std::uintptr_t>(request.objects.data());
    raw.count_props_ptr =
        reinterpret_cast<std::uintptr_t>(request.property_counts.data());
    raw.props_ptr = reinterpret_cast<std::uintptr_t>(request.properties.data());
    raw.prop_values_ptr =
        reinterpret_cast<std::uintptr_t>(request.values.data());
    if (drm_ioctl_(fd, kDrmIoctlModeAtomic, &raw) != 0) {
      set_error(error, errno_message("DRM_IOCTL_MODE_ATOMIC"));
      return false;
    }
    return true;
  }

  bool read_flip_events(int fd, std::vector<DrmFlipEvent> *out,
                        std::string *error) override {
    if (out == nullptr) {
      set_error(error, "null DRM event sink");
      return false;
    }
    // Non-blocking drain: poll(0) gates each read so an empty queue never
    // blocks the scan thread.
    for (;;) {
      struct pollfd pfd {};
      pfd.fd = fd;
      pfd.events = POLLIN;
      const int ready = ::poll(&pfd, 1, 0);
      if (ready < 0) {
        if (errno == EINTR) {
          continue;
        }
        set_error(error, errno_message("poll(DRM fd)"));
        return false;
      }
      if (ready == 0 || (pfd.revents & POLLIN) == 0) {
        return true;
      }
      std::uint8_t buffer[1024];
      const ssize_t bytes = ::read(fd, buffer, sizeof(buffer));
      if (bytes < 0) {
        if (errno == EINTR) {
          continue;
        }
        if (errno == EAGAIN) {
          return true;
        }
        set_error(error, errno_message("read(DRM fd)"));
        return false;
      }
      if (bytes == 0) {
        return true;
      }
      // Kernel event stream: struct drm_event {u32 type; u32 length;}
      // followed by per-type payload. DRM_EVENT_FLIP_COMPLETE (0x02)
      // carries struct drm_event_vblank.
      std::size_t offset = 0;
      while (offset + sizeof(RawDrmEvent) <= static_cast<std::size_t>(bytes)) {
        RawDrmEvent header{};
        std::memcpy(&header, buffer + offset, sizeof(header));
        if (header.length < sizeof(RawDrmEvent) ||
            offset + header.length > static_cast<std::size_t>(bytes)) {
          break;
        }
        if (header.type == kDrmEventFlipComplete &&
            header.length >= sizeof(RawDrmEventVblank)) {
          RawDrmEventVblank vblank{};
          std::memcpy(&vblank, buffer + offset, sizeof(vblank));
          DrmFlipEvent event;
          event.user_data = vblank.user_data;
          event.sequence = vblank.sequence;
          event.tv_sec = vblank.tv_sec;
          event.tv_usec = vblank.tv_usec;
          out->push_back(event);
        }
        offset += header.length;
      }
    }
  }

private:
  using DrmSetClientCapFn = int (*)(int, std::uint64_t, std::uint64_t);
  using DrmGetCapFn = int (*)(int, std::uint64_t, std::uint64_t *);
  using DrmIoctlFn = int (*)(int, unsigned long, void *);
  using DrmModeGetResourcesFn = RawModeRes *(*)(int);
  using DrmModeFreeResourcesFn = void (*)(RawModeRes *);
  using DrmModeGetConnectorFn = RawConnector *(*)(int, std::uint32_t);
  using DrmModeFreeConnectorFn = void (*)(RawConnector *);
  using DrmModeGetEncoderFn = RawEncoder *(*)(int, std::uint32_t);
  using DrmModeFreeEncoderFn = void (*)(RawEncoder *);
  using DrmModeGetPlaneResourcesFn = RawPlaneRes *(*)(int);
  using DrmModeFreePlaneResourcesFn = void (*)(RawPlaneRes *);
  using DrmModeGetPlaneFn = RawPlane *(*)(int, std::uint32_t);
  using DrmModeFreePlaneFn = void (*)(RawPlane *);
  using DrmModeObjectGetPropertiesFn = RawObjectProperties *(*)(int,
                                                                std::uint32_t,
                                                                std::uint32_t);
  using DrmModeFreeObjectPropertiesFn = void (*)(RawObjectProperties *);
  using DrmModeGetPropertyFn = RawPropertyRes *(*)(int, std::uint32_t);
  using DrmModeFreePropertyFn = void (*)(RawPropertyRes *);
  using DrmModeAddFbFn = int (*)(int, std::uint32_t, std::uint32_t,
                                 std::uint8_t, std::uint8_t, std::uint32_t,
                                 std::uint32_t, std::uint32_t *);
  using DrmModeRmFbFn = int (*)(int, std::uint32_t);
  using DrmModeSetCrtcFn = int (*)(int, std::uint32_t, std::uint32_t,
                                   std::uint32_t, std::uint32_t,
                                   std::uint32_t *, int, RawModeInfo *);
  using DrmModeConnectorSetPropertyFn = int (*)(int, std::uint32_t,
                                                std::uint32_t, std::uint64_t);

  bool ensure_loaded(std::string *error) {
    if (loaded_) {
      return true;
    }
    libdrm_ = dlopen("libdrm.so.2", RTLD_NOW | RTLD_LOCAL);
    if (libdrm_ == nullptr) {
      libdrm_ = dlopen("libdrm.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (libdrm_ == nullptr) {
      set_error(error, "unable to load libdrm.so.2");
      return false;
    }

    if (!load_symbol(libdrm_, "drmSetClientCap", &drm_set_client_cap_, error) ||
        !load_symbol(libdrm_, "drmGetCap", &drm_get_cap_, error) ||
        !load_symbol(libdrm_, "drmIoctl", &drm_ioctl_, error) ||
        !load_symbol(libdrm_, "drmModeGetResources", &drm_mode_get_resources_,
                     error) ||
        !load_symbol(libdrm_, "drmModeFreeResources", &drm_mode_free_resources_,
                     error) ||
        !load_symbol(libdrm_, "drmModeGetConnector", &drm_mode_get_connector_,
                     error) ||
        !load_symbol(libdrm_, "drmModeFreeConnector", &drm_mode_free_connector_,
                     error) ||
        !load_symbol(libdrm_, "drmModeGetEncoder", &drm_mode_get_encoder_,
                     error) ||
        !load_symbol(libdrm_, "drmModeFreeEncoder", &drm_mode_free_encoder_,
                     error) ||
        !load_symbol(libdrm_, "drmModeGetPlaneResources",
                     &drm_mode_get_plane_resources_, error) ||
        !load_symbol(libdrm_, "drmModeFreePlaneResources",
                     &drm_mode_free_plane_resources_, error) ||
        !load_symbol(libdrm_, "drmModeGetPlane", &drm_mode_get_plane_, error) ||
        !load_symbol(libdrm_, "drmModeFreePlane", &drm_mode_free_plane_,
                     error) ||
        !load_symbol(libdrm_, "drmModeObjectGetProperties",
                     &drm_mode_object_get_properties_, error) ||
        !load_symbol(libdrm_, "drmModeFreeObjectProperties",
                     &drm_mode_free_object_properties_, error) ||
        !load_symbol(libdrm_, "drmModeGetProperty", &drm_mode_get_property_,
                     error) ||
        !load_symbol(libdrm_, "drmModeFreeProperty", &drm_mode_free_property_,
                     error) ||
        !load_symbol(libdrm_, "drmModeAddFB", &drm_mode_add_fb_, error) ||
        !load_symbol(libdrm_, "drmModeRmFB", &drm_mode_rm_fb_, error) ||
        !load_symbol(libdrm_, "drmModeSetCrtc", &drm_mode_set_crtc_, error) ||
        !load_symbol(libdrm_, "drmModeConnectorSetProperty",
                     &drm_mode_connector_set_property_, error)) {
      return false;
    }
    loaded_ = true;
    return true;
  }

  void read_property_name(int fd, std::uint32_t id, std::string *out) {
    if (out == nullptr) {
      return;
    }
    RawPropertyRes *raw = drm_mode_get_property_(fd, id);
    if (raw == nullptr) {
      out->clear();
      return;
    }
    raw->name[sizeof(raw->name) - 1] = '\0';
    *out = raw->name;
    drm_mode_free_property_(raw);
  }

  bool loaded_ = false;
  void *libdrm_ = nullptr;
  DrmSetClientCapFn drm_set_client_cap_ = nullptr;
  DrmGetCapFn drm_get_cap_ = nullptr;
  DrmIoctlFn drm_ioctl_ = nullptr;
  DrmModeGetResourcesFn drm_mode_get_resources_ = nullptr;
  DrmModeFreeResourcesFn drm_mode_free_resources_ = nullptr;
  DrmModeGetConnectorFn drm_mode_get_connector_ = nullptr;
  DrmModeFreeConnectorFn drm_mode_free_connector_ = nullptr;
  DrmModeGetEncoderFn drm_mode_get_encoder_ = nullptr;
  DrmModeFreeEncoderFn drm_mode_free_encoder_ = nullptr;
  DrmModeGetPlaneResourcesFn drm_mode_get_plane_resources_ = nullptr;
  DrmModeFreePlaneResourcesFn drm_mode_free_plane_resources_ = nullptr;
  DrmModeGetPlaneFn drm_mode_get_plane_ = nullptr;
  DrmModeFreePlaneFn drm_mode_free_plane_ = nullptr;
  DrmModeObjectGetPropertiesFn drm_mode_object_get_properties_ = nullptr;
  DrmModeFreeObjectPropertiesFn drm_mode_free_object_properties_ = nullptr;
  DrmModeGetPropertyFn drm_mode_get_property_ = nullptr;
  DrmModeFreePropertyFn drm_mode_free_property_ = nullptr;
  DrmModeAddFbFn drm_mode_add_fb_ = nullptr;
  DrmModeRmFbFn drm_mode_rm_fb_ = nullptr;
  DrmModeSetCrtcFn drm_mode_set_crtc_ = nullptr;
  DrmModeConnectorSetPropertyFn drm_mode_connector_set_property_ = nullptr;
};

} // namespace

std::unique_ptr<DrmInterface> make_real_drm_interface() {
  return std::make_unique<RealDrmInterface>();
}

DrmSwtconDevice::DrmSwtconDevice(std::unique_ptr<DrmInterface> drm)
    : drm_(std::move(drm)) {}

DrmSwtconDevice::~DrmSwtconDevice() { close(); }

PlutoStatus DrmSwtconDevice::open(const Config &config) {
  close();
  clear_error();
  if (drm_ == nullptr) {
    fail("missing DRM interface");
    return kPlutoStatusInternal;
  }

  std::string error;
  fd_ = drm_->open_card(config.card_path, &error);
  if (fd_ < 0) {
    fail(error);
    return kPlutoStatusDeviceLost;
  }

  if (!drm_->set_client_cap(fd_, kDrmClientCapUniversalPlanes, 1, &error) ||
      !drm_->set_client_cap(fd_, kDrmClientCapAtomic, 1, &error)) {
    fail(error);
    close();
    return kPlutoStatusDeviceLost;
  }

  std::uint64_t cap = 0;
  if (!drm_->get_cap(fd_, kDrmCapDumbBuffer, &cap, &error) || cap == 0) {
    fail(cap == 0 ? "DRM device does not support dumb buffers" : error);
    close();
    return kPlutoStatusDeviceLost;
  }
  cap = 0;
  if (!drm_->get_cap(fd_, kDrmCapAtomicKms, &cap, &error) || cap == 0) {
    fail(cap == 0 ? "DRM device does not support atomic KMS" : error);
    close();
    return kPlutoStatusDeviceLost;
  }

  if (!discover_pipe() || !create_buffers()) {
    close();
    return kPlutoStatusDeviceLost;
  }
  clear_error();
  return kPlutoStatusOk;
}

void DrmSwtconDevice::close() {
  if (drm_ != nullptr && fd_ >= 0) {
    for (auto it = buffers_.rbegin(); it != buffers_.rend(); ++it) {
      if (it->map != nullptr) {
        drm_->munmap_dumb(it->map, it->size);
        it->map = nullptr;
      }
      std::string ignored;
      if (it->fb_id != 0) {
        (void)drm_->rm_fb(fd_, it->fb_id, &ignored);
      }
      if (it->handle != 0) {
        (void)drm_->destroy_dumb(fd_, it->handle, &ignored);
      }
    }
    buffers_.clear();
    drm_->close_fd(fd_);
  }
  fd_ = -1;
  resources_ = {};
  connector_id_ = 0;
  crtc_id_ = 0;
  crtc_index_ = 0;
  plane_id_ = 0;
  dpms_property_id_ = 0;
  plane_property_ids_ = {};
  mode_ = {};
  flip_request_ready_ = false;
}

PlutoStatus DrmSwtconDevice::set_crtc(std::size_t buffer_index) {
  if (fd_ < 0 || buffer_index >= buffers_.size()) {
    return kPlutoStatusInvalidArgument;
  }
  std::string error;
  if (!drm_->set_crtc(fd_, crtc_id_, buffers_[buffer_index].fb_id,
                      connector_id_, mode_, &error)) {
    fail(error);
    return kPlutoStatusDeviceLost;
  }
  clear_error();
  return kPlutoStatusOk;
}

PlutoStatus DrmSwtconDevice::blank() {
  if (fd_ < 0) {
    return kPlutoStatusInvalidArgument;
  }
  std::string error;
  if (!drm_->blank_crtc(fd_, crtc_id_, &error)) {
    fail(error);
    return kPlutoStatusDeviceLost;
  }
  clear_error();
  return kPlutoStatusOk;
}

PlutoStatus DrmSwtconDevice::set_dpms_on() {
  if (fd_ < 0) {
    return kPlutoStatusInvalidArgument;
  }
  if (dpms_property_id_ == 0) {
    fail("selected DRM connector has no DPMS property");
    return kPlutoStatusUnsupported;
  }
  std::string error;
  if (!drm_->set_connector_property(fd_, connector_id_, dpms_property_id_, 0,
                                    &error)) {
    fail(error);
    return kPlutoStatusDeviceLost;
  }
  clear_error();
  return kPlutoStatusOk;
}

PlutoStatus DrmSwtconDevice::atomic_flip(std::size_t buffer_index) {
  return flip_request(buffer_index, 0, 0);
}

PlutoStatus DrmSwtconDevice::atomic_flip_event(std::size_t buffer_index,
                                                 std::uint64_t user_data) {
  return flip_request(buffer_index, kDrmModePageFlipEventFlag, user_data);
}

bool DrmSwtconDevice::drain_flip_events(std::vector<DrmFlipEvent> *out) {
  if (fd_ < 0 || out == nullptr) {
    return false;
  }
  std::string error;
  if (!drm_->read_flip_events(fd_, out, &error)) {
    fail(error);
    return false;
  }
  clear_error();
  return true;
}

PlutoStatus DrmSwtconDevice::flip_request(std::size_t buffer_index,
                                            std::uint32_t flags,
                                            std::uint64_t user_data) {
  if (fd_ < 0 || buffer_index >= buffers_.size()) {
    return kPlutoStatusInvalidArgument;
  }
  if (!plane_property_ids_.complete()) {
    fail("selected DRM primary plane is missing required atomic properties");
    return kPlutoStatusUnsupported;
  }

  // Build the constant part of the request once (pipe/plane fixed after
  // discovery); afterwards only FB_ID + flags + user_data vary per flip, so
  // the scan thread allocates nothing per tick. FB_ID is the last property in
  // the fixed order below, i.e. values.back().
  if (!flip_request_ready_) {
    flip_request_.objects = {plane_id_};
    flip_request_.property_counts = {10};
    flip_request_.properties = {
        plane_property_ids_.crtc_id, plane_property_ids_.crtc_x,
        plane_property_ids_.crtc_y,  plane_property_ids_.crtc_w,
        plane_property_ids_.crtc_h,  plane_property_ids_.src_x,
        plane_property_ids_.src_y,   plane_property_ids_.src_w,
        plane_property_ids_.src_h,   plane_property_ids_.fb_id,
    };
    flip_request_.values = {
        crtc_id_,
        0,
        0,
        kDrmWidth,
        kDrmHeight,
        0,
        0,
        static_cast<std::uint64_t>(kDrmWidth) << 16,
        static_cast<std::uint64_t>(kDrmHeight) << 16,
        0,  // FB_ID placeholder, set per flip below
    };
    flip_request_ready_ = true;
  }
  flip_request_.flags = flags;
  flip_request_.user_data = user_data;
  flip_request_.values.back() = buffers_[buffer_index].fb_id;

  std::string error;
  if (!drm_->atomic_commit(fd_, flip_request_, &error)) {
    fail(error);
    return kPlutoStatusDeviceLost;
  }
  clear_error();
  return kPlutoStatusOk;
}

PlutoStatus
DrmSwtconDevice::copy_phase_to_buffer(std::size_t buffer_index,
                                      const std::uint16_t *tight_words) {
  if (buffer_index >= buffers_.size() || tight_words == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  DrmMappedBuffer &buffer = buffers_[buffer_index];
  if (buffer.map == nullptr ||
      buffer.pitch < kDrmWidth * sizeof(std::uint16_t)) {
    fail("invalid mapped DRM dumb buffer");
    return kPlutoStatusDeviceLost;
  }
  auto *dst = static_cast<std::uint8_t *>(buffer.map);
  for (int y = 0; y < kDrmHeight; ++y) {
    std::memcpy(dst + static_cast<std::size_t>(y) * buffer.pitch,
                tight_words + static_cast<std::size_t>(y) * kDrmWidth,
                static_cast<std::size_t>(kDrmWidth) * sizeof(std::uint16_t));
  }
  clear_error();
  return kPlutoStatusOk;
}

bool DrmSwtconDevice::fail(const std::string &message) {
  last_error_ = message.empty() ? "DRM SWTCON error" : message;
  return false;
}

void DrmSwtconDevice::clear_error() { last_error_.clear(); }

bool DrmSwtconDevice::discover_pipe() {
  std::string error;
  if (!drm_->get_resources(fd_, &resources_, &error)) {
    return fail(error);
  }
  if (resources_.crtcs.empty() || resources_.connectors.empty()) {
    return fail("DRM resources have no usable CRTC/connector");
  }

  DrmConnectorInfo selected_connector{};
  bool found_connector = false;
  for (std::uint32_t connector_id : resources_.connectors) {
    DrmConnectorInfo connector{};
    if (!drm_->get_connector(fd_, connector_id, &connector, &error)) {
      return fail(error);
    }
    if (!connector.connected || connector.modes.empty()) {
      continue;
    }
    std::uint32_t chosen_crtc = 0;
    std::size_t chosen_index = 0;
    if (!choose_crtc_for_connector(connector, &chosen_crtc, &chosen_index)) {
      continue;
    }
    const DrmModeInfo &first_mode = connector.modes.front();
    if (first_mode.hdisplay != kDrmWidth || first_mode.vdisplay != kDrmHeight) {
      return fail(
          "DRM error: size mismatch " + std::to_string(first_mode.hdisplay) +
          "x" + std::to_string(first_mode.vdisplay) + " (expected " +
          std::to_string(kDrmWidth) + "x" + std::to_string(kDrmHeight) + ")");
    }
    selected_connector = std::move(connector);
    connector_id_ = selected_connector.connector_id;
    crtc_id_ = chosen_crtc;
    crtc_index_ = chosen_index;
    mode_ = first_mode;
    dpms_property_id_ = property_id(selected_connector.properties, "DPMS");
    found_connector = true;
    break;
  }
  if (!found_connector) {
    return fail("no connected 365x1700 DRM connector found");
  }

  std::vector<std::uint32_t> plane_ids;
  if (!drm_->get_plane_ids(fd_, &plane_ids, &error)) {
    return fail(error);
  }
  // Fallback: on this panel the single primary plane reports possible_crtcs=0
  // (verified on-device + in paper-codex display-info), yet xochitl uses it.
  // Prefer a possible_crtcs match, but accept any type==1 primary plane.
  std::uint32_t fallback_plane_id = 0;
  DrmPlaneAtomicPropertyIds fallback_property_ids;
  for (std::uint32_t id : plane_ids) {
    DrmPlaneInfo plane{};
    if (!drm_->get_plane(fd_, id, &plane, &error)) {
      return fail(error);
    }
    const bool can_use_crtc =
        (plane.possible_crtcs &
         (1U << static_cast<unsigned int>(crtc_index_))) != 0;
    const std::uint64_t type = property_value(plane.properties, "type", 0);
    if (type != 1) {
      continue;
    }
    if (can_use_crtc) {
      plane_id_ = plane.plane_id;
      plane_property_ids_ = plane_property_ids(plane.properties);
      break;
    }
    if (fallback_plane_id == 0) {
      fallback_plane_id = plane.plane_id;
      fallback_property_ids = plane_property_ids(plane.properties);
    }
  }
  if (plane_id_ == 0 && fallback_plane_id != 0) {
    plane_id_ = fallback_plane_id;
    plane_property_ids_ = fallback_property_ids;
  }
  if (plane_id_ == 0) {
    return fail("no primary DRM plane found for selected CRTC");
  }
  if (!plane_property_ids_.complete()) {
    return fail(
        "primary DRM plane is missing FB_ID/CRTC/SRC atomic properties");
  }
  return true;
}

bool DrmSwtconDevice::create_buffers() {
  std::string error;
  buffers_.reserve(kDrmBufferCount);
  for (int i = 0; i < kDrmBufferCount; ++i) {
    DrmDumbCreateResult create{};
    if (!drm_->create_dumb(fd_, kDrmWidth, kDrmHeight, kDrmBitsPerPixel,
                           &create, &error)) {
      return fail(error);
    }
    if (create.size < kDrmPhaseBytes ||
        create.pitch < kDrmWidth * sizeof(std::uint16_t)) {
      return fail("DRM dumb buffer is smaller than 365x1700 RG16 payload");
    }

    DrmMappedBuffer buffer{};
    buffer.handle = create.handle;
    buffer.pitch = create.pitch;
    buffer.size = create.size;
    if (!drm_->add_fb(fd_, kDrmWidth, kDrmHeight, kDrmDepth, kDrmBitsPerPixel,
                      create.pitch, create.handle, &buffer.fb_id, &error)) {
      (void)drm_->destroy_dumb(fd_, create.handle, &error);
      return fail(error);
    }
    std::uint64_t offset = 0;
    if (!drm_->map_dumb(fd_, create.handle, &offset, &error)) {
      (void)drm_->rm_fb(fd_, buffer.fb_id, &error);
      (void)drm_->destroy_dumb(fd_, create.handle, &error);
      return fail(error);
    }
    buffer.map = drm_->mmap_dumb(fd_, offset, create.size, &error);
    if (buffer.map == nullptr) {
      (void)drm_->rm_fb(fd_, buffer.fb_id, &error);
      (void)drm_->destroy_dumb(fd_, create.handle, &error);
      return fail(error);
    }
    std::memset(buffer.map, 0, static_cast<std::size_t>(buffer.size));
    buffers_.push_back(buffer);
  }
  return true;
}

bool DrmSwtconDevice::choose_crtc_for_connector(
    const DrmConnectorInfo &connector, std::uint32_t *crtc_id,
    std::size_t *crtc_index) {
  std::string error;
  if (connector.encoder_id != 0) {
    DrmEncoderInfo encoder{};
    if (!drm_->get_encoder(fd_, connector.encoder_id, &encoder, &error)) {
      return false;
    }
    if (encoder.crtc_id != 0) {
      const auto found = std::find(resources_.crtcs.begin(),
                                   resources_.crtcs.end(), encoder.crtc_id);
      if (found != resources_.crtcs.end()) {
        *crtc_id = encoder.crtc_id;
        *crtc_index =
            static_cast<std::size_t>(found - resources_.crtcs.begin());
        return true;
      }
    }
  }

  for (std::uint32_t encoder_id : connector.encoders) {
    DrmEncoderInfo encoder{};
    if (!drm_->get_encoder(fd_, encoder_id, &encoder, &error)) {
      continue;
    }
    for (std::size_t i = 0; i < resources_.crtcs.size(); ++i) {
      if ((encoder.possible_crtcs & (1U << static_cast<unsigned int>(i))) !=
          0) {
        *crtc_id = resources_.crtcs[i];
        *crtc_index = i;
        return true;
      }
    }
  }
  return false;
}

DrmPlaneAtomicPropertyIds DrmSwtconDevice::plane_property_ids(
    const std::vector<DrmPropertyValue> &props) {
  DrmPlaneAtomicPropertyIds ids;
  ids.fb_id = property_id(props, "FB_ID");
  ids.crtc_id = property_id(props, "CRTC_ID");
  ids.crtc_x = property_id(props, "CRTC_X");
  ids.crtc_y = property_id(props, "CRTC_Y");
  ids.crtc_w = property_id(props, "CRTC_W");
  ids.crtc_h = property_id(props, "CRTC_H");
  ids.src_x = property_id(props, "SRC_X");
  ids.src_y = property_id(props, "SRC_Y");
  ids.src_w = property_id(props, "SRC_W");
  ids.src_h = property_id(props, "SRC_H");
  return ids;
}

std::uint32_t
DrmSwtconDevice::property_id(const std::vector<DrmPropertyValue> &props,
                             const char *name) {
  for (const DrmPropertyValue &prop : props) {
    if (prop.name == name) {
      return prop.id;
    }
  }
  return 0;
}

std::uint64_t
DrmSwtconDevice::property_value(const std::vector<DrmPropertyValue> &props,
                                const char *name, std::uint64_t fallback) {
  for (const DrmPropertyValue &prop : props) {
    if (prop.name == name) {
      return prop.value;
    }
  }
  return fallback;
}

} // namespace pluto::swtcon
