#include "channels/wpa_supplicant_client.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <utility>
#include <vector>

namespace pluto {
namespace {

namespace fs = std::filesystem;

std::atomic<unsigned long> g_client_counter{0};

class ScopedSocket {
 public:
  explicit ScopedSocket(int fd) : fd_(fd) {}
  ~ScopedSocket() {
    if (fd_ >= 0) {
      ::close(fd_);
    }
  }

  ScopedSocket(const ScopedSocket&) = delete;
  ScopedSocket& operator=(const ScopedSocket&) = delete;

  int get() const { return fd_; }

 private:
  int fd_ = -1;
};

class ScopedSocketPath {
 public:
  explicit ScopedSocketPath(std::string path) : path_(std::move(path)) {}
  ~ScopedSocketPath() {
    if (!path_.empty()) {
      ::unlink(path_.c_str());
    }
  }

  ScopedSocketPath(const ScopedSocketPath&) = delete;
  ScopedSocketPath& operator=(const ScopedSocketPath&) = delete;

 private:
  std::string path_;
};

bool set_socket_address(sockaddr_un* address, const std::string& path) {
  if (address == nullptr || path.empty() ||
      path.size() >= sizeof(address->sun_path)) {
    return false;
  }
  std::memset(address, 0, sizeof(*address));
  address->sun_family = AF_UNIX;
  std::memcpy(address->sun_path, path.c_str(), path.size() + 1);
#if defined(__APPLE__)
  address->sun_len = static_cast<unsigned char>(
      offsetof(sockaddr_un, sun_path) + path.size() + 1);
#endif
  return true;
}

socklen_t socket_address_length(const sockaddr_un& address) {
  return static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) +
                                std::strlen(address.sun_path) + 1);
}

}  // namespace

WpaSupplicantClient::WpaSupplicantClient(std::string control_directory,
                                         std::string interface_name)
    : control_directory_(std::move(control_directory)),
      interface_name_(std::move(interface_name)) {}

std::optional<std::string> WpaSupplicantClient::request(
    const std::string& command, std::chrono::milliseconds timeout) const {
  if (command.empty() || command.size() > 4096 || timeout.count() <= 0) {
    return std::nullopt;
  }

  const std::string server_path =
      (fs::path(control_directory_) / interface_name_).string();
  sockaddr_un server_address{};
  if (!set_socket_address(&server_address, server_path)) {
    return std::nullopt;
  }

  const int raw_socket = ::socket(AF_UNIX, SOCK_DGRAM, 0);
  if (raw_socket < 0) {
    return std::nullopt;
  }
  ScopedSocket socket(raw_socket);
  const int descriptor_flags = ::fcntl(socket.get(), F_GETFD);
  if (descriptor_flags >= 0) {
    ::fcntl(socket.get(), F_SETFD, descriptor_flags | FD_CLOEXEC);
  }

  const unsigned long sequence = g_client_counter.fetch_add(1);
  const std::string client_path =
      (fs::path("/tmp") / ("pluto-wpa-" + std::to_string(::getpid()) + "-" +
                           std::to_string(sequence)))
          .string();
  sockaddr_un client_address{};
  if (!set_socket_address(&client_address, client_path)) {
    return std::nullopt;
  }
  ::unlink(client_path.c_str());
  ScopedSocketPath cleanup(client_path);
  if (::bind(socket.get(), reinterpret_cast<const sockaddr*>(&client_address),
             socket_address_length(client_address)) != 0) {
    return std::nullopt;
  }
  ::chmod(client_path.c_str(), 0600);

  if (::connect(socket.get(),
                reinterpret_cast<const sockaddr*>(&server_address),
                socket_address_length(server_address)) != 0) {
    return std::nullopt;
  }
  const ssize_t sent = ::send(socket.get(), command.data(), command.size(), 0);
  if (sent < 0 || static_cast<size_t>(sent) != command.size()) {
    return std::nullopt;
  }

  pollfd descriptor{};
  descriptor.fd = socket.get();
  descriptor.events = POLLIN;
  int poll_result = 0;
  do {
    poll_result = ::poll(&descriptor, 1, static_cast<int>(timeout.count()));
  } while (poll_result < 0 && errno == EINTR);
  if (poll_result <= 0 || (descriptor.revents & POLLIN) == 0) {
    return std::nullopt;
  }

  std::vector<char> buffer(128 * 1024);
  ssize_t received = 0;
  do {
    received = ::recv(socket.get(), buffer.data(), buffer.size(), MSG_TRUNC);
  } while (received < 0 && errno == EINTR);
  if (received < 0 || static_cast<size_t>(received) > buffer.size()) {
    return std::nullopt;
  }
  return std::string(buffer.data(), static_cast<size_t>(received));
}

}  // namespace pluto
