#ifndef PLUTO_PRESENTER_SWTCON_DRM_SWTCON_DEVICE_H_
#define PLUTO_PRESENTER_SWTCON_DRM_SWTCON_DEVICE_H_

#include "pluto/presenter.h"
#include "presenter/swtcon/swtcon_constants.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pluto::swtcon {

struct DrmModeInfo {
  std::uint32_t clock = 0;
  std::uint16_t hdisplay = 0;
  std::uint16_t hsync_start = 0;
  std::uint16_t hsync_end = 0;
  std::uint16_t htotal = 0;
  std::uint16_t hskew = 0;
  std::uint16_t vdisplay = 0;
  std::uint16_t vsync_start = 0;
  std::uint16_t vsync_end = 0;
  std::uint16_t vtotal = 0;
  std::uint16_t vscan = 0;
  std::uint32_t vrefresh = 0;
  std::uint32_t flags = 0;
  std::uint32_t type = 0;
  char name[32] = {};
};

struct DrmPropertyValue {
  std::uint32_t id = 0;
  std::string name;
  std::uint64_t value = 0;
};

struct DrmResources {
  std::vector<std::uint32_t> crtcs;
  std::vector<std::uint32_t> connectors;
};

struct DrmConnectorInfo {
  std::uint32_t connector_id = 0;
  std::uint32_t encoder_id = 0;
  bool connected = false;
  std::vector<DrmModeInfo> modes;
  std::vector<DrmPropertyValue> properties;
  std::vector<std::uint32_t> encoders;
};

struct DrmEncoderInfo {
  std::uint32_t encoder_id = 0;
  std::uint32_t crtc_id = 0;
  std::uint32_t possible_crtcs = 0;
};

struct DrmPlaneInfo {
  std::uint32_t plane_id = 0;
  std::uint32_t possible_crtcs = 0;
  std::vector<DrmPropertyValue> properties;
};

struct DrmDumbCreateResult {
  std::uint32_t handle = 0;
  std::uint32_t pitch = 0;
  std::uint64_t size = 0;
};

struct DrmMappedBuffer {
  std::uint32_t handle = 0;
  std::uint32_t fb_id = 0;
  std::uint32_t pitch = 0;
  std::uint64_t size = 0;
  void *map = nullptr;
};

struct DrmPlaneAtomicPropertyIds {
  std::uint32_t fb_id = 0;
  std::uint32_t crtc_id = 0;
  std::uint32_t crtc_x = 0;
  std::uint32_t crtc_y = 0;
  std::uint32_t crtc_w = 0;
  std::uint32_t crtc_h = 0;
  std::uint32_t src_x = 0;
  std::uint32_t src_y = 0;
  std::uint32_t src_w = 0;
  std::uint32_t src_h = 0;

  bool complete() const {
    return fb_id != 0 && crtc_id != 0 && crtc_x != 0 && crtc_y != 0 &&
           crtc_w != 0 && crtc_h != 0 && src_x != 0 && src_y != 0 &&
           src_w != 0 && src_h != 0;
  }
};

struct DrmAtomicRequest {
  std::uint32_t flags = 0;
  // Opaque cookie returned in the flip-completion event when
  // kDrmModePageFlipEventFlag is set (the ScanLoop stamps its scan seq).
  std::uint64_t user_data = 0;
  std::vector<std::uint32_t> objects;
  std::vector<std::uint32_t> property_counts;
  std::vector<std::uint32_t> properties;
  std::vector<std::uint64_t> values;
};

// DRM_MODE_PAGE_FLIP_EVENT: request a flip-completion event on the card fd.
inline constexpr std::uint32_t kDrmModePageFlipEventFlag = 0x01;

// One DRM_EVENT_FLIP_COMPLETE, drained via read_flip_events(). `sequence`
// is the hardware vblank count at completion — the ScanLoop's double-scan
// detector keys off gaps in it.
struct DrmFlipEvent {
  std::uint64_t user_data = 0;
  std::uint32_t sequence = 0;
  std::uint32_t tv_sec = 0;
  std::uint32_t tv_usec = 0;
};

class DrmInterface {
public:
  virtual ~DrmInterface() = default;

  virtual int open_card(const std::string &path, std::string *error) = 0;
  virtual void close_fd(int fd) = 0;
  virtual bool set_client_cap(int fd, std::uint64_t capability,
                              std::uint64_t value, std::string *error) = 0;
  virtual bool get_cap(int fd, std::uint64_t capability, std::uint64_t *value,
                       std::string *error) = 0;
  virtual bool get_resources(int fd, DrmResources *out, std::string *error) = 0;
  virtual bool get_connector(int fd, std::uint32_t connector_id,
                             DrmConnectorInfo *out, std::string *error) = 0;
  virtual bool get_encoder(int fd, std::uint32_t encoder_id,
                           DrmEncoderInfo *out, std::string *error) = 0;
  virtual bool get_plane_ids(int fd, std::vector<std::uint32_t> *out,
                             std::string *error) = 0;
  virtual bool get_plane(int fd, std::uint32_t plane_id, DrmPlaneInfo *out,
                         std::string *error) = 0;
  virtual bool create_dumb(int fd, std::uint32_t width, std::uint32_t height,
                           std::uint32_t bpp, DrmDumbCreateResult *out,
                           std::string *error) = 0;
  virtual bool add_fb(int fd, std::uint32_t width, std::uint32_t height,
                      std::uint8_t depth, std::uint8_t bpp, std::uint32_t pitch,
                      std::uint32_t handle, std::uint32_t *fb_id,
                      std::string *error) = 0;
  virtual bool map_dumb(int fd, std::uint32_t handle, std::uint64_t *offset,
                        std::string *error) = 0;
  virtual void *mmap_dumb(int fd, std::uint64_t offset, std::uint64_t size,
                          std::string *error) = 0;
  virtual void munmap_dumb(void *address, std::uint64_t size) = 0;
  virtual bool rm_fb(int fd, std::uint32_t fb_id, std::string *error) = 0;
  virtual bool destroy_dumb(int fd, std::uint32_t handle,
                            std::string *error) = 0;
  virtual bool set_crtc(int fd, std::uint32_t crtc_id, std::uint32_t fb_id,
                        std::uint32_t connector_id, const DrmModeInfo &mode,
                        std::string *error) = 0;
  virtual bool blank_crtc(int fd, std::uint32_t crtc_id,
                          std::string *error) = 0;
  virtual bool set_connector_property(int fd, std::uint32_t connector_id,
                                      std::uint32_t property_id,
                                      std::uint64_t value,
                                      std::string *error) = 0;
  virtual bool atomic_commit(int fd, const DrmAtomicRequest &request,
                             std::string *error) = 0;
  // Non-blocking drain of pending DRM events on `fd`; appends every
  // DRM_EVENT_FLIP_COMPLETE to `out`. Default: no events (mocks that
  // predate the scan loop keep working; the real interface overrides).
  virtual bool read_flip_events(int fd, std::vector<DrmFlipEvent> *out,
                                std::string *error) {
    (void)fd;
    (void)out;
    (void)error;
    return true;
  }
};

std::unique_ptr<DrmInterface> make_real_drm_interface();

class DrmSwtconDevice final {
public:
  struct Config {
    std::string card_path = "/dev/dri/card0";
  };

  explicit DrmSwtconDevice(std::unique_ptr<DrmInterface> drm);
  DrmSwtconDevice(const DrmSwtconDevice &) = delete;
  DrmSwtconDevice &operator=(const DrmSwtconDevice &) = delete;
  ~DrmSwtconDevice();

  PlutoStatus open(const Config &config);
  void close();

  PlutoStatus set_crtc(std::size_t buffer_index);
  PlutoStatus blank();
  PlutoStatus set_dpms_on();
  PlutoStatus atomic_flip(std::size_t buffer_index);
  // FB_ID-only atomic flip requesting a flip-completion event stamped with
  // `user_data` (ScanLoop scan seq).
  PlutoStatus atomic_flip_event(std::size_t buffer_index,
                                  std::uint64_t user_data);
  // Non-blocking drain of flip-completion events (appends to `out`).
  bool drain_flip_events(std::vector<DrmFlipEvent> *out);

  PlutoStatus copy_phase_to_buffer(std::size_t buffer_index,
                                     const std::uint16_t *tight_words);

  bool is_open() const { return fd_ >= 0; }
  int fd() const { return fd_; }
  std::uint32_t connector_id() const { return connector_id_; }
  std::uint32_t crtc_id() const { return crtc_id_; }
  std::uint32_t plane_id() const { return plane_id_; }
  std::uint32_t dpms_property_id() const { return dpms_property_id_; }
  std::uint32_t fb_id_property_id() const { return plane_property_ids_.fb_id; }
  const DrmPlaneAtomicPropertyIds &plane_property_ids() const {
    return plane_property_ids_;
  }
  const DrmModeInfo &mode() const { return mode_; }
  const std::vector<DrmMappedBuffer> &buffers() const { return buffers_; }
  const std::string &last_error() const { return last_error_; }

private:
  bool fail(const std::string &message);
  void clear_error();
  PlutoStatus flip_request(std::size_t buffer_index, std::uint32_t flags,
                             std::uint64_t user_data);
  bool discover_pipe();
  bool create_buffers();
  bool choose_crtc_for_connector(const DrmConnectorInfo &connector,
                                 std::uint32_t *crtc_id,
                                 std::size_t *crtc_index);
  static DrmPlaneAtomicPropertyIds
  plane_property_ids(const std::vector<DrmPropertyValue> &props);
  static std::uint32_t property_id(const std::vector<DrmPropertyValue> &props,
                                   const char *name);
  static std::uint64_t
  property_value(const std::vector<DrmPropertyValue> &props, const char *name,
                 std::uint64_t fallback);

  std::unique_ptr<DrmInterface> drm_;
  int fd_ = -1;
  DrmResources resources_;
  std::uint32_t connector_id_ = 0;
  std::uint32_t crtc_id_ = 0;
  std::size_t crtc_index_ = 0;
  std::uint32_t plane_id_ = 0;
  std::uint32_t dpms_property_id_ = 0;
  DrmPlaneAtomicPropertyIds plane_property_ids_;
  DrmModeInfo mode_{};
  std::vector<DrmMappedBuffer> buffers_;
  std::string last_error_;

  // Reused atomic-flip request (scan thread, one per ~11.76 ms tick): the
  // plane id, property id list and all values except FB_ID are fixed once the
  // pipe is discovered, so the request is built lazily on the first flip and
  // then only its FB_ID value + flags + user_data change per flip — no
  // per-frame heap churn on the SCHED_FIFO scan thread. Reset by close().
  DrmAtomicRequest flip_request_;
  bool flip_request_ready_ = false;
};

} // namespace pluto::swtcon

#endif // PLUTO_PRESENTER_SWTCON_DRM_SWTCON_DEVICE_H_
