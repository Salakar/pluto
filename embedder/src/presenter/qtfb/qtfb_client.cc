#include "presenter/qtfb/qtfb_client.h"

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <limits>

#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace pluto {
namespace {

bool parse_uint(const char *value, unsigned int *out) {
  if (value == nullptr || *value == '\0' || out == nullptr) {
    return false;
  }
  char *end = nullptr;
  errno = 0;
  const unsigned long parsed = std::strtoul(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' ||
      parsed > std::numeric_limits<unsigned int>::max()) {
    return false;
  }
  *out = static_cast<unsigned int>(parsed);
  return true;
}

bool is_rgb565_format(std::uint8_t format) {
  return format == qtfb::kFbFmtRm2fb || format == qtfb::kFbFmtRmppRgb565 ||
         format == qtfb::kFbFmtRmppmRgb565;
}

bool matches_default_geometry(const QtfbClient::Config &config) {
  switch (config.framebuffer_type) {
  case qtfb::kFbFmtRm2fb:
    return config.width == qtfb::kRm2Width && config.height == qtfb::kRm2Height;
  case qtfb::kFbFmtRmppRgb565:
    return config.width == qtfb::kRmppWidth &&
           config.height == qtfb::kRmppHeight;
  case qtfb::kFbFmtRmppmRgb565:
    return config.width == qtfb::kRmppmWidth &&
           config.height == qtfb::kRmppmHeight;
  default:
    return false;
  }
}

PlutoStatus errno_to_status(int error) {
  switch (error) {
  case EAGAIN:
#if EWOULDBLOCK != EAGAIN
  case EWOULDBLOCK:
#endif
    return kPlutoStatusAgain;
  case ECONNRESET:
  case ENOTCONN:
  case EPIPE:
  case ECONNREFUSED:
  case ENOENT:
    return kPlutoStatusDeviceLost;
  default:
    return kPlutoStatusInternal;
  }
}

bool set_close_on_exec(int fd) {
  const int flags = fcntl(fd, F_GETFD, 0);
  return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

bool set_non_blocking(int fd) {
  const int flags = fcntl(fd, F_GETFL, 0);
  return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

ssize_t send_no_signal(int fd, const void *data, std::size_t size) {
  int flags = 0;
#ifdef MSG_NOSIGNAL
  flags |= MSG_NOSIGNAL;
#endif
  return send(fd, data, size, flags);
}

bool disable_sigpipe(int fd) {
#ifdef SO_NOSIGPIPE
  int enabled = 1;
  return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) ==
         0;
#else
  (void)fd;
  return true;
#endif
}

PlutoStatus send_packet(int fd, const void *data, std::size_t size) {
  const auto *bytes = static_cast<const std::uint8_t *>(data);
  std::size_t offset = 0;
  for (;;) {
    const ssize_t sent = send_no_signal(fd, bytes + offset, size - offset);
    if (sent > 0) {
      offset += static_cast<std::size_t>(sent);
      if (offset == size) {
        return kPlutoStatusOk;
      }
      continue;
    }
    if (sent == 0) {
      return kPlutoStatusDeviceLost;
    }
    if (errno == EINTR) {
      continue;
    }
    return errno_to_status(errno);
  }
}

PlutoStatus recv_packet(int fd, void *data, std::size_t size) {
  auto *bytes = static_cast<std::uint8_t *>(data);
  std::size_t offset = 0;
  while (offset < size) {
    const ssize_t received = recv(fd, bytes + offset, size - offset, 0);
    if (received > 0) {
      offset += static_cast<std::size_t>(received);
      if (offset == size) {
        return kPlutoStatusOk;
      }
      continue;
    }
    if (received == 0) {
      return offset == 0 ? kPlutoStatusDeviceLost : kPlutoStatusInternal;
    }
    if (errno == EINTR) {
      continue;
    }
    return errno_to_status(errno);
  }
  return kPlutoStatusOk;
}

int qtfb_socket_type(bool stream_transport) {
  return stream_transport ? SOCK_STREAM : SOCK_SEQPACKET;
}

} // namespace

QtfbClient::~QtfbClient() { close(); }

qtfb::FBKey QtfbClient::framebuffer_key_from_env() {
  unsigned int key = qtfb::kDefaultFramebuffer;
  parse_uint(std::getenv("QTFB_KEY"), &key);
  if (key >
      static_cast<unsigned int>(std::numeric_limits<qtfb::FBKey>::max())) {
    return qtfb::kDefaultFramebuffer;
  }
  return static_cast<qtfb::FBKey>(key);
}

std::string QtfbClient::socket_path_from_env() {
  const char *path = std::getenv("PLUTO_QTFB_SOCKET");
  if (path == nullptr || *path == '\0') {
    path = std::getenv("QTFB_SOCKET");
  }
  return (path == nullptr || *path == '\0')
             ? std::string(qtfb::kDefaultSocketPath)
             : std::string(path);
}

std::string QtfbClient::shm_name(qtfb::FBKey key) {
  return std::string("/qtfb_") + std::to_string(key);
}

PlutoStatus QtfbClient::open(const Config &config) {
  close();
  device_lost_ = false;

  if (config.socket_path.empty() || config.width <= 0 || config.height <= 0 ||
      config.width > std::numeric_limits<std::uint16_t>::max() ||
      config.height > std::numeric_limits<std::uint16_t>::max() ||
      !is_rgb565_format(config.framebuffer_type) ||
      (!config.custom_resolution && !matches_default_geometry(config))) {
    return kPlutoStatusInvalidArgument;
  }

  const int fd = socket(AF_UNIX, qtfb_socket_type(config.stream_transport), 0);
  if (fd < 0) {
    return errno_to_status(errno);
  }
  socket_fd_ = fd;
  (void)set_close_on_exec(socket_fd_);
  (void)disable_sigpipe(socket_fd_);
  if (config.send_buffer_bytes > 0) {
    const int bytes = config.send_buffer_bytes;
    (void)setsockopt(socket_fd_, SOL_SOCKET, SO_SNDBUF, &bytes, sizeof(bytes));
  }

  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (config.socket_path.size() >= sizeof(addr.sun_path)) {
    close();
    return kPlutoStatusInvalidArgument;
  }
  std::strncpy(addr.sun_path, config.socket_path.c_str(),
               sizeof(addr.sun_path) - 1);
  if (connect(socket_fd_, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) !=
      0) {
    const int error = errno;
    close();
    return errno_to_status(error);
  }

  qtfb::ClientMessage init{};
  if (config.custom_resolution) {
    init.type = qtfb::kMessageCustomInitialize;
    init.customInit.framebufferKey = config.framebuffer_key;
    init.customInit.framebufferType = config.framebuffer_type;
    init.customInit.width = static_cast<std::uint16_t>(config.width);
    init.customInit.height = static_cast<std::uint16_t>(config.height);
  } else {
    init.type = qtfb::kMessageInitialize;
    init.init.framebufferKey = config.framebuffer_key;
    init.init.framebufferType = config.framebuffer_type;
  }
  PlutoStatus status = send_packet(socket_fd_, &init, sizeof(init));
  if (status != kPlutoStatusOk) {
    if (status == kPlutoStatusDeviceLost) {
      mark_device_lost();
    }
    close();
    return status;
  }
  qtfb::ServerMessage response{};
  status = recv_packet(socket_fd_, &response, sizeof(response));
  if (status != kPlutoStatusOk) {
    if (status == kPlutoStatusDeviceLost) {
      mark_device_lost();
    }
    close();
    return status;
  }
  if (response.type != qtfb::kMessageInitialize) {
    close();
    return kPlutoStatusInternal;
  }

  const qtfb::FBKey shm_key =
      static_cast<qtfb::FBKey>(response.init.shmKeyDefined);
  const std::string name = shm_name(shm_key);
  shm_fd_ = shm_open(name.c_str(), O_RDWR, 0);
  if (shm_fd_ < 0) {
    const int error = errno;
    close();
    return errno_to_status(error);
  }
  (void)set_close_on_exec(shm_fd_);

  const std::size_t min_stride =
      static_cast<std::size_t>(config.width) * qtfb::kRgb565BytesPerPixel;
  const std::size_t min_size =
      min_stride * static_cast<std::size_t>(config.height);
  if (response.init.shmSize < min_size) {
    close();
    return kPlutoStatusInternal;
  }
  if (response.init.shmSize % static_cast<std::size_t>(config.height) == 0) {
    stride_bytes_ =
        response.init.shmSize / static_cast<std::size_t>(config.height);
    if (stride_bytes_ < min_stride) {
      close();
      return kPlutoStatusInternal;
    }
  } else {
    stride_bytes_ = min_stride;
  }

  void *mapped = mmap(nullptr, response.init.shmSize, PROT_READ | PROT_WRITE,
                      MAP_SHARED, shm_fd_, 0);
  if (mapped == MAP_FAILED) {
    const int error = errno;
    close();
    return errno_to_status(error);
  }

  framebuffer_ = static_cast<std::uint8_t *>(mapped);
  framebuffer_size_ = response.init.shmSize;
  width_ = config.width;
  height_ = config.height;
  stream_transport_ = config.stream_transport;

  if (!set_non_blocking(socket_fd_)) {
    close();
    return kPlutoStatusInternal;
  }
  return kPlutoStatusOk;
}

void QtfbClient::close() {
  if (framebuffer_ != nullptr) {
    munmap(framebuffer_, framebuffer_size_);
    framebuffer_ = nullptr;
  }
  framebuffer_size_ = 0;
  stride_bytes_ = 0;
  width_ = 0;
  height_ = 0;
  stream_transport_ = false;
  receive_buffer_size_ = 0;
  receive_buffer_.fill(0);

  if (shm_fd_ >= 0) {
    ::close(shm_fd_);
    shm_fd_ = -1;
  }
  if (socket_fd_ >= 0) {
    ::close(socket_fd_);
    socket_fd_ = -1;
  }
}

bool QtfbClient::ready() const {
  if (!is_open() || device_lost_) {
    return false;
  }

  pollfd pfd{};
  pfd.fd = socket_fd_;
  pfd.events = POLLOUT;
  const int rc = poll(&pfd, 1, 0);
  if (rc == 0) {
    return false;
  }
  if (rc < 0) {
    if (errno == EINTR) {
      return true;
    }
    mark_device_lost();
    return false;
  }
  if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
    mark_device_lost();
    return false;
  }
  return (pfd.revents & POLLOUT) != 0;
}

PlutoStatus QtfbClient::send_complete_update() {
  qtfb::UpdateRegionMessageContents update{};
  update.type = qtfb::kUpdateAll;
  return send_update(update);
}

PlutoStatus QtfbClient::send_partial_update(int x, int y, int width,
                                            int height) {
  qtfb::UpdateRegionMessageContents update{};
  update.type = qtfb::kUpdatePartial;
  update.x = x;
  update.y = y;
  update.w = width;
  update.h = height;
  return send_update(update);
}

PlutoStatus
QtfbClient::send_update(const qtfb::UpdateRegionMessageContents &update) {
  if (!is_open()) {
    return device_lost_ ? kPlutoStatusDeviceLost : kPlutoStatusInternal;
  }
  if (device_lost_) {
    return kPlutoStatusDeviceLost;
  }

  qtfb::ClientMessage message{};
  message.type = qtfb::kMessageUpdate;
  message.update = update;
  const PlutoStatus status = send_packet(socket_fd_, &message, sizeof(message));
  if (status == kPlutoStatusDeviceLost) {
    mark_device_lost();
  }
  return status;
}

PlutoStatus
QtfbClient::receive_server_message(qtfb::ServerMessage *out_message) {
  if (out_message == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  if (!is_open()) {
    return device_lost_ ? kPlutoStatusDeviceLost : kPlutoStatusInternal;
  }
  if (device_lost_) {
    return kPlutoStatusDeviceLost;
  }

  for (;;) {
    std::uint8_t *destination = receive_buffer_.data();
    std::size_t capacity = receive_buffer_.size();
    if (stream_transport_) {
      destination += receive_buffer_size_;
      capacity -= receive_buffer_size_;
    }

    const ssize_t received =
        recv(socket_fd_, destination, capacity, MSG_DONTWAIT);
    if (received > 0) {
      if (!stream_transport_) {
        if (static_cast<std::size_t>(received) != receive_buffer_.size()) {
          return kPlutoStatusInternal;
        }
        receive_buffer_size_ = receive_buffer_.size();
      } else {
        receive_buffer_size_ += static_cast<std::size_t>(received);
        if (receive_buffer_size_ < receive_buffer_.size()) {
          return kPlutoStatusAgain;
        }
      }
      std::memcpy(out_message, receive_buffer_.data(), receive_buffer_.size());
      receive_buffer_size_ = 0;
      return kPlutoStatusOk;
    }
    if (received == 0) {
      mark_device_lost();
      return kPlutoStatusDeviceLost;
    }
    if (errno == EINTR) {
      continue;
    }
    const PlutoStatus status = errno_to_status(errno);
    if (status == kPlutoStatusDeviceLost) {
      mark_device_lost();
    }
    return status;
  }
}

PlutoStatus QtfbClient::receive_user_input(qtfb::UserInputContents *out_input) {
  if (out_input == nullptr) {
    return kPlutoStatusInvalidArgument;
  }
  qtfb::ServerMessage message{};
  const PlutoStatus status = receive_server_message(&message);
  if (status != kPlutoStatusOk) {
    return status;
  }
  if (message.type == qtfb::kMessageTerminate) {
    mark_device_lost();
    return kPlutoStatusDeviceLost;
  }
  if (message.type != qtfb::kMessageUserInput) {
    return kPlutoStatusUnsupported;
  }
  *out_input = message.userInput;
  return kPlutoStatusOk;
}

} // namespace pluto
