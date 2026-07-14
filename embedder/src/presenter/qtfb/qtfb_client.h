#ifndef PLUTO_PRESENTER_QTFB_QTFB_CLIENT_H_
#define PLUTO_PRESENTER_QTFB_QTFB_CLIENT_H_

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

#include "pluto/presenter.h"
#include "presenter/qtfb/qtfb_proto.h"

namespace pluto {

class QtfbClient final {
public:
  struct Config {
    std::string socket_path = qtfb::kDefaultSocketPath;
    qtfb::FBKey framebuffer_key = qtfb::kDefaultFramebuffer;
    int width = qtfb::kPanelWidth;
    int height = qtfb::kPanelHeight;
    std::uint8_t framebuffer_type = qtfb::kFbFmtRmppmRgb565;
    bool custom_resolution = true;
    int send_buffer_bytes = 0;
    bool stream_transport = false;
  };

  QtfbClient() = default;
  QtfbClient(const QtfbClient &) = delete;
  QtfbClient &operator=(const QtfbClient &) = delete;
  ~QtfbClient();

  static qtfb::FBKey framebuffer_key_from_env();
  static std::string socket_path_from_env();
  static std::string shm_name(qtfb::FBKey key);

  PlutoStatus open(const Config &config);
  void close();

  bool is_open() const { return socket_fd_ >= 0 && framebuffer_ != nullptr; }
  bool device_lost() const { return device_lost_; }
  bool ready() const;

  std::uint8_t *framebuffer() const { return framebuffer_; }
  std::size_t framebuffer_size() const { return framebuffer_size_; }
  std::size_t stride_bytes() const { return stride_bytes_; }

  PlutoStatus send_complete_update();
  PlutoStatus send_partial_update(int x, int y, int width, int height);
  // Polls one canonical server packet without blocking. Returns Again when no
  // input is queued and Unsupported after consuming a non-input packet.
  PlutoStatus receive_user_input(qtfb::UserInputContents *out_input);

private:
  PlutoStatus send_update(const qtfb::UpdateRegionMessageContents &update);
  PlutoStatus receive_server_message(qtfb::ServerMessage *out_message);
  void mark_device_lost() const { device_lost_ = true; }

  int socket_fd_ = -1;
  int shm_fd_ = -1;
  std::uint8_t *framebuffer_ = nullptr;
  std::size_t framebuffer_size_ = 0;
  std::size_t stride_bytes_ = 0;
  int width_ = 0;
  int height_ = 0;
  bool stream_transport_ = false;
  std::array<std::uint8_t, sizeof(qtfb::ServerMessage)> receive_buffer_{};
  std::size_t receive_buffer_size_ = 0;
  mutable std::atomic_bool device_lost_{false};
};

} // namespace pluto

#endif // PLUTO_PRESENTER_QTFB_QTFB_CLIENT_H_
