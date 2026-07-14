#include <fcntl.h>
#include <gtest/gtest.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "pluto/presenter.h"
#include "presenter/qtfb/qtfb_client.h"
#include "presenter/qtfb/qtfb_presenter.h"
#include "presenter/qtfb/qtfb_proto.h"

namespace {

constexpr int kWidth = pluto::qtfb::kPanelWidth;
constexpr int kHeight = pluto::qtfb::kPanelHeight;
constexpr int kLegacyWidth = pluto::qtfb::kRm2Width;
constexpr int kLegacyHeight = pluto::qtfb::kRm2Height;
constexpr int kBytesPerPixel = pluto::qtfb::kRgb565BytesPerPixel;
constexpr size_t kStride = static_cast<size_t>(kWidth) * kBytesPerPixel;
constexpr size_t kFrameSize = kStride * static_cast<size_t>(kHeight);
constexpr size_t kLegacyStride =
    static_cast<size_t>(kLegacyWidth) * kBytesPerPixel;
constexpr size_t kLegacyFrameSize =
    kLegacyStride * static_cast<size_t>(kLegacyHeight);

// Public ABI pins: InkPriority keeps its historical bit and the pen-truth
// opt-in occupies the first free bit above RequiredSettle, outside the
// sparkle phase field.
static_assert(kPlutoPresentFlagInkPriority == (1u << 0));
static_assert(kPlutoPresentFlagPenTruth == (1u << 17));
static_assert((kPlutoPresentFlagPenTruth & kPlutoPresentSparklePhaseMask) == 0);

#if defined(__APPLE__)
constexpr int kFakeSocketType = SOCK_STREAM;
constexpr const char *kFakeTransportOption = "transport=stream";
#else
constexpr int kFakeSocketType = SOCK_SEQPACKET;
constexpr const char *kFakeTransportOption = "";
#endif

bool send_full(int fd, const void *data, size_t size) {
  const auto *bytes = static_cast<const uint8_t *>(data);
  size_t offset = 0;
  while (offset < size) {
    const ssize_t sent = send(fd, bytes + offset, size - offset, 0);
    if (sent <= 0) {
      return false;
    }
    offset += static_cast<size_t>(sent);
  }
  return true;
}

ssize_t recv_full(int fd, void *data, size_t size) {
  auto *bytes = static_cast<uint8_t *>(data);
  size_t offset = 0;
  while (offset < size) {
    const ssize_t received = recv(fd, bytes + offset, size - offset, 0);
    if (received <= 0) {
      return received;
    }
    offset += static_cast<size_t>(received);
  }
  return static_cast<ssize_t>(offset);
}

pluto::qtfb::FBKey next_key() {
  static std::atomic<int> counter{0};
  return 600000000 + static_cast<int>((getpid() % 100000) * 100) + counter++;
}

std::vector<uint8_t> patterned_frame(int width = kWidth, int height = kHeight) {
  const size_t stride = static_cast<size_t>(width) * kBytesPerPixel;
  std::vector<uint8_t> frame(stride * static_cast<size_t>(height));
  for (size_t i = 0; i < frame.size(); ++i) {
    frame[i] = static_cast<uint8_t>((i * 17u + 3u) & 0xffu);
  }
  return frame;
}

PlutoPresentRequest make_request_for_geometry(
    const std::vector<uint8_t> &frame, const std::vector<PlutoRect> &damage,
    PlutoRefreshClass refresh_class, uint64_t frame_id, int width, int height) {
  PlutoPresentRequest request{};
  request.struct_size = sizeof(request);
  request.surface.pixels = frame.data();
  request.surface.stride_bytes = static_cast<size_t>(width) * kBytesPerPixel;
  request.surface.width = width;
  request.surface.height = height;
  request.surface.format = kPlutoPixelFormatRgb565;
  request.damage = damage.data();
  request.damage_count = damage.size();
  request.refresh_class = refresh_class;
  request.flags = kPlutoPresentFlagPreDithered;
  request.frame_id = frame_id;
  return request;
}

PlutoPresentRequest make_request(const std::vector<uint8_t> &frame,
                                 const std::vector<PlutoRect> &damage,
                                 PlutoRefreshClass refresh_class,
                                 uint64_t frame_id) {
  return make_request_for_geometry(frame, damage, refresh_class, frame_id,
                                   kWidth, kHeight);
}

class TempSocketDir final {
public:
  TempSocketDir() {
    char pattern[] = "/tmp/pluto-qtfb-test-XXXXXX";
    char *dir = mkdtemp(pattern);
    if (dir != nullptr) {
      dir_ = dir;
      socket_path_ = dir_ + "/qtfb.sock";
    }
  }

  TempSocketDir(const TempSocketDir &) = delete;
  TempSocketDir &operator=(const TempSocketDir &) = delete;

  ~TempSocketDir() {
    if (!socket_path_.empty()) {
      unlink(socket_path_.c_str());
    }
    if (!dir_.empty()) {
      rmdir(dir_.c_str());
    }
  }

  const std::string &socket_path() const { return socket_path_; }
  bool valid() const { return !socket_path_.empty(); }

private:
  std::string dir_;
  std::string socket_path_;
};

class FakeQtfbServer final {
public:
  explicit FakeQtfbServer(pluto::qtfb::FBKey key, bool read_updates = true)
      : key_(key), read_updates_(read_updates) {}

  FakeQtfbServer(const FakeQtfbServer &) = delete;
  FakeQtfbServer &operator=(const FakeQtfbServer &) = delete;

  ~FakeQtfbServer() { stop(); }

  bool start() {
    if (!temp_dir_.valid()) {
      return false;
    }
    listen_fd_ = socket(AF_UNIX, kFakeSocketType, 0);
    if (listen_fd_ < 0) {
      return false;
    }
    if (!read_updates_) {
      int bytes = 512;
      (void)setsockopt(listen_fd_, SOL_SOCKET, SO_RCVBUF, &bytes,
                       sizeof(bytes));
    }

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (temp_dir_.socket_path().size() >= sizeof(addr.sun_path)) {
      return false;
    }
    std::strncpy(addr.sun_path, temp_dir_.socket_path().c_str(),
                 sizeof(addr.sun_path) - 1);
    unlink(temp_dir_.socket_path().c_str());
    if (bind(listen_fd_, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) !=
        0) {
      return false;
    }
    if (listen(listen_fd_, 1) != 0) {
      return false;
    }
    thread_ = std::thread(&FakeQtfbServer::run, this);
    return true;
  }

  void stop() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stop_ = true;
    }
    cv_.notify_all();
    close_client();
    if (listen_fd_ >= 0) {
      shutdown(listen_fd_, SHUT_RDWR);
      close(listen_fd_);
      listen_fd_ = -1;
    }
    if (thread_.joinable()) {
      thread_.join();
    }
    if (shm_ != nullptr) {
      munmap(shm_, shm_size_);
      shm_ = nullptr;
    }
    if (shm_fd_ >= 0) {
      close(shm_fd_);
      shm_fd_ = -1;
    }
    if (!shm_name_.empty()) {
      shm_unlink(shm_name_.c_str());
      shm_name_.clear();
    }
  }

  void close_client() {
    int fd = -1;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      fd = client_fd_;
      client_fd_ = -1;
    }
    if (fd >= 0) {
      shutdown(fd, SHUT_RDWR);
      close(fd);
    }
  }

  bool wait_for_handshake() {
    std::unique_lock<std::mutex> lock(mutex_);
    return cv_.wait_for(lock, std::chrono::seconds(2), [this] {
      return handshake_seen_ || stop_;
    }) && handshake_seen_;
  }

  bool wait_for_updates(size_t count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return cv_.wait_for(lock, std::chrono::seconds(2), [this, count] {
      return updates_.size() >= count || stop_;
    }) && updates_.size() >= count;
  }

  void clear_updates() {
    std::lock_guard<std::mutex> lock(mutex_);
    updates_.clear();
  }

  pluto::qtfb::ClientMessage init_message() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return init_message_;
  }

  std::vector<pluto::qtfb::UpdateRegionMessageContents> updates() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return updates_;
  }

  bool send_user_input(const pluto::qtfb::UserInputContents &input) {
    pluto::qtfb::ServerMessage message{};
    message.type = pluto::qtfb::kMessageUserInput;
    message.userInput = input;
    std::lock_guard<std::mutex> lock(mutex_);
    return client_fd_ >= 0 && send_full(client_fd_, &message, sizeof(message));
  }

  const uint8_t *framebuffer() const { return shm_; }
  const std::string &socket_path() const { return temp_dir_.socket_path(); }

private:
  void run() {
    const int accepted = accept(listen_fd_, nullptr, nullptr);
    if (accepted < 0) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      client_fd_ = accepted;
    }
    if (!read_updates_) {
      int bytes = 512;
      (void)setsockopt(accepted, SOL_SOCKET, SO_RCVBUF, &bytes, sizeof(bytes));
    }

    pluto::qtfb::ClientMessage init{};
    const ssize_t init_size = recv_full(accepted, &init, sizeof(init));
    if (init_size != static_cast<ssize_t>(sizeof(init))) {
      return;
    }

    int width = 0;
    int height = 0;
    std::uint8_t framebuffer_type = 0;
    if (init.type == pluto::qtfb::kMessageCustomInitialize) {
      width = init.customInit.width;
      height = init.customInit.height;
      framebuffer_type = init.customInit.framebufferType;
    } else if (init.type == pluto::qtfb::kMessageInitialize) {
      framebuffer_type = init.init.framebufferType;
      switch (framebuffer_type) {
      case pluto::qtfb::kFbFmtRm2fb:
        width = pluto::qtfb::kRm2Width;
        height = pluto::qtfb::kRm2Height;
        break;
      case pluto::qtfb::kFbFmtRmppRgb565:
        width = pluto::qtfb::kRmppWidth;
        height = pluto::qtfb::kRmppHeight;
        break;
      case pluto::qtfb::kFbFmtRmppmRgb565:
        width = pluto::qtfb::kRmppmWidth;
        height = pluto::qtfb::kRmppmHeight;
        break;
      default:
        return;
      }
    } else {
      return;
    }
    if (width <= 0 || height <= 0 ||
        (framebuffer_type != pluto::qtfb::kFbFmtRm2fb &&
         framebuffer_type != pluto::qtfb::kFbFmtRmppRgb565 &&
         framebuffer_type != pluto::qtfb::kFbFmtRmppmRgb565)) {
      return;
    }
    shm_size_ = static_cast<size_t>(width) * static_cast<size_t>(height) *
                kBytesPerPixel;

    shm_name_ = pluto::QtfbClient::shm_name(key_);
    shm_unlink(shm_name_.c_str());
    shm_fd_ = shm_open(shm_name_.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
    if (shm_fd_ < 0) {
      return;
    }
    if (ftruncate(shm_fd_, static_cast<off_t>(shm_size_)) != 0) {
      return;
    }
    void *mapped = mmap(nullptr, shm_size_, PROT_READ | PROT_WRITE, MAP_SHARED,
                        shm_fd_, 0);
    if (mapped == MAP_FAILED) {
      return;
    }
    shm_ = static_cast<uint8_t *>(mapped);
    std::memset(shm_, 0, shm_size_);

    pluto::qtfb::ServerMessage response{};
    response.type = pluto::qtfb::kMessageInitialize;
    response.init.shmKeyDefined = static_cast<int>(key_);
    response.init.shmSize = shm_size_;
    if (!send_full(accepted, &response, sizeof(response))) {
      return;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      init_message_ = init;
      handshake_seen_ = true;
    }
    cv_.notify_all();

    if (!read_updates_) {
      std::unique_lock<std::mutex> lock(mutex_);
      cv_.wait(lock, [this] { return stop_; });
      return;
    }

    for (;;) {
      pluto::qtfb::ClientMessage message{};
      const ssize_t size = recv_full(accepted, &message, sizeof(message));
      if (size <= 0) {
        return;
      }
      if (size == static_cast<ssize_t>(sizeof(message)) &&
          message.type == pluto::qtfb::kMessageUpdate) {
        {
          std::lock_guard<std::mutex> lock(mutex_);
          updates_.push_back(message.update);
        }
        cv_.notify_all();
      }
    }
  }

  TempSocketDir temp_dir_;
  pluto::qtfb::FBKey key_;
  bool read_updates_ = true;
  size_t shm_size_ = 0;
  int listen_fd_ = -1;
  int client_fd_ = -1;
  int shm_fd_ = -1;
  uint8_t *shm_ = nullptr;
  std::string shm_name_;
  std::thread thread_;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  bool stop_ = false;
  bool handshake_seen_ = false;
  pluto::qtfb::ClientMessage init_message_{};
  std::vector<pluto::qtfb::UpdateRegionMessageContents> updates_;
};

class PresenterHandle final {
public:
  PresenterHandle(const PlutoPresenterOps *ops, PlutoPresenter *presenter)
      : ops_(ops), presenter_(presenter) {}
  PresenterHandle(const PresenterHandle &) = delete;
  PresenterHandle &operator=(const PresenterHandle &) = delete;
  ~PresenterHandle() {
    if (ops_ != nullptr && presenter_ != nullptr) {
      ops_->close(presenter_);
    }
  }

  PlutoPresenter *get() const { return presenter_; }

private:
  const PlutoPresenterOps *ops_ = nullptr;
  PlutoPresenter *presenter_ = nullptr;
};

PresenterHandle open_presenter(const PlutoPresenterOps *ops,
                               FakeQtfbServer *server, pluto::qtfb::FBKey key,
                               const char *extra_options = nullptr) {
  std::string options =
      "socket=" + server->socket_path() + ",key=" + std::to_string(key);
  if (kFakeTransportOption[0] != '\0') {
    options += ",";
    options += kFakeTransportOption;
  }
  if (extra_options != nullptr && *extra_options != '\0') {
    options += ",";
    options += extra_options;
  }
  PlutoPresenterConfig config{};
  config.struct_size = sizeof(config);
  config.backend_name = "qtfb";
  config.options = options.c_str();
  PlutoPresenter *presenter = nullptr;
  EXPECT_EQ(ops->open(&config, &presenter), kPlutoStatusOk);
  EXPECT_TRUE(presenter != nullptr);
  EXPECT_TRUE(server->wait_for_handshake());
  return PresenterHandle(ops, presenter);
}

} // namespace

TEST(QtfbProtocolTest, CanonicalNativeWireLayoutMatchesAppLoad) {
  EXPECT_EQ(sizeof(pluto::qtfb::FBKey), static_cast<size_t>(4));
  EXPECT_EQ(sizeof(pluto::qtfb::InitMessageContents), static_cast<size_t>(8));
  EXPECT_EQ(sizeof(pluto::qtfb::CustomInitMessageContents),
            static_cast<size_t>(12));
  EXPECT_EQ(sizeof(pluto::qtfb::UpdateRegionMessageContents),
            static_cast<size_t>(20));
  EXPECT_EQ(sizeof(pluto::qtfb::UserInputContents), static_cast<size_t>(20));
  EXPECT_EQ(sizeof(pluto::qtfb::ClientMessage), static_cast<size_t>(24));
  EXPECT_EQ(offsetof(pluto::qtfb::ClientMessage, init), static_cast<size_t>(4));
  EXPECT_EQ(offsetof(pluto::qtfb::ClientMessage, update),
            static_cast<size_t>(4));

  if (sizeof(size_t) == 4) {
    EXPECT_EQ(sizeof(pluto::qtfb::ServerMessage), static_cast<size_t>(24));
    EXPECT_EQ(offsetof(pluto::qtfb::ServerMessage, init),
              static_cast<size_t>(4));
  } else {
    ASSERT_EQ(sizeof(size_t), static_cast<size_t>(8));
    EXPECT_EQ(sizeof(pluto::qtfb::ServerMessage), static_cast<size_t>(32));
    EXPECT_EQ(offsetof(pluto::qtfb::ServerMessage, init),
              static_cast<size_t>(8));
  }
  EXPECT_EQ(offsetof(pluto::qtfb::ServerMessage, userInput),
            offsetof(pluto::qtfb::ServerMessage, init));

  EXPECT_EQ(static_cast<int>(pluto::qtfb::kFbFmtRm2fb), 0);
  EXPECT_EQ(static_cast<int>(pluto::qtfb::kFbFmtRmppRgb565), 3);
  EXPECT_EQ(static_cast<int>(pluto::qtfb::kFbFmtRmppmRgb565), 6);
  EXPECT_EQ(static_cast<int>(pluto::qtfb::kMessageTerminate), 3);
  EXPECT_EQ(static_cast<int>(pluto::qtfb::kMessageUserInput), 4);
  EXPECT_EQ(static_cast<int>(pluto::qtfb::kMessageSetRefreshMode), 5);
  EXPECT_EQ(static_cast<int>(pluto::qtfb::kMessageRequestFullRefresh), 6);
  EXPECT_EQ(static_cast<int>(pluto::qtfb::kRefreshModeUi), 4);
}

TEST(QtfbPresenterTest, RegistersAndInitializesWithCustomMoveSurface) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());

  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  EXPECT_EQ(std::string(ops->name), std::string("qtfb"));
  auto presenter = open_presenter(ops, &server, key);

  const pluto::qtfb::ClientMessage init = server.init_message();
  EXPECT_EQ(static_cast<int>(init.type),
            static_cast<int>(pluto::qtfb::kMessageCustomInitialize));
  EXPECT_EQ(init.customInit.framebufferKey, key);
  EXPECT_EQ(static_cast<int>(init.customInit.framebufferType),
            static_cast<int>(pluto::qtfb::kFbFmtRmppmRgb565));
  EXPECT_EQ(static_cast<int>(init.customInit.width), kWidth);
  EXPECT_EQ(static_cast<int>(init.customInit.height), kHeight);

  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  EXPECT_EQ(ops->info(presenter.get(), &info), kPlutoStatusOk);
  EXPECT_EQ(info.width, kWidth);
  EXPECT_EQ(info.height, kHeight);
  EXPECT_EQ(info.dpi, 264);
  EXPECT_EQ(info.preferred_format, kPlutoPixelFormatRgb565);
  EXPECT_FALSE(info.controls_refresh_class);
  EXPECT_TRUE(info.wants_pre_dithered);
  // Settled color is delegated to xochitl's own quantizer under qtfb.
  EXPECT_TRUE(info.is_color);
  EXPECT_TRUE(info.backend_quantizes_color);
  EXPECT_TRUE(info.supports_overlap_supersession);
  EXPECT_EQ(info.rect_alignment, 8);
}

TEST(QtfbPresenterTest, LegacyProfileUsesDefaultRm2SurfaceAndCoalescesDamage) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());

  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key, "profile=legacy");

  const pluto::qtfb::ClientMessage init = server.init_message();
  EXPECT_EQ(static_cast<int>(init.type),
            static_cast<int>(pluto::qtfb::kMessageInitialize));
  EXPECT_EQ(init.init.framebufferKey, key);
  EXPECT_EQ(static_cast<int>(init.init.framebufferType),
            static_cast<int>(pluto::qtfb::kFbFmtRm2fb));

  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  ASSERT_EQ(ops->info(presenter.get(), &info), kPlutoStatusOk);
  EXPECT_EQ(info.width, kLegacyWidth);
  EXPECT_EQ(info.height, kLegacyHeight);
  EXPECT_EQ(info.dpi, 226);
  EXPECT_EQ(info.preferred_format, kPlutoPixelFormatRgb565);
  EXPECT_FALSE(info.is_color);
  EXPECT_FALSE(info.backend_quantizes_color);

  std::vector<uint8_t> frame = patterned_frame(kLegacyWidth, kLegacyHeight);
  ASSERT_EQ(frame.size(), kLegacyFrameSize);
  const std::vector<PlutoRect> damage{{8, 16, 8, 4}, {40, 48, 5, 6}};
  PlutoPresentRequest request = make_request_for_geometry(
      frame, damage, kPlutoRefreshFast, 1, kLegacyWidth, kLegacyHeight);
  ASSERT_EQ(ops->present(presenter.get(), &request), kPlutoStatusOk);
  ASSERT_TRUE(server.wait_for_updates(1));

  const std::vector<pluto::qtfb::UpdateRegionMessageContents> updates =
      server.updates();
  ASSERT_EQ(updates.size(), static_cast<size_t>(1));
  EXPECT_EQ(updates[0].type, pluto::qtfb::kUpdatePartial);
  EXPECT_EQ(updates[0].x, 8);
  EXPECT_EQ(updates[0].y, 16);
  EXPECT_EQ(updates[0].w, 37);
  EXPECT_EQ(updates[0].h, 38);

  ASSERT_TRUE(server.framebuffer() != nullptr);
  const size_t first = static_cast<size_t>(damage[0].y) * kLegacyStride +
                       static_cast<size_t>(damage[0].x) * kBytesPerPixel;
  const size_t second = static_cast<size_t>(damage[1].y) * kLegacyStride +
                        static_cast<size_t>(damage[1].x) * kBytesPerPixel;
  EXPECT_EQ(server.framebuffer()[first], frame[first]);
  EXPECT_EQ(server.framebuffer()[first + 1], frame[first + 1]);
  EXPECT_EQ(server.framebuffer()[second], frame[second]);
  EXPECT_EQ(server.framebuffer()[second + 1], frame[second + 1]);

  // The bounding update covers the gap, but Pluto copies only actual damage.
  const size_t gap = static_cast<size_t>(24) * kLegacyStride +
                     static_cast<size_t>(24) * kBytesPerPixel;
  EXPECT_EQ(server.framebuffer()[gap], 0u);
  EXPECT_EQ(server.framebuffer()[gap + 1], 0u);

  std::vector<uint8_t> move_frame(kFrameSize, 0x44);
  const std::vector<PlutoRect> move_damage{{0, 0, kWidth, kHeight}};
  PlutoPresentRequest wrong_geometry =
      make_request(move_frame, move_damage, kPlutoRefreshUi, 2);
  EXPECT_EQ(ops->present(presenter.get(), &wrong_geometry),
            kPlutoStatusInvalidArgument);
}

TEST(QtfbPresenterTest, InputHookReceivesCanonicalPacketWithoutBlocking) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());

  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  pluto::qtfb::UserInputContents received{};
  EXPECT_EQ(pluto::qtfb_receive_user_input(nullptr, &received),
            kPlutoStatusInvalidArgument);
  EXPECT_EQ(pluto::qtfb_receive_user_input(presenter.get(), nullptr),
            kPlutoStatusInvalidArgument);
  EXPECT_EQ(pluto::qtfb_receive_user_input(presenter.get(), &received),
            kPlutoStatusAgain);

  const pluto::qtfb::UserInputContents expected{pluto::qtfb::kInputPenUpdate, 2,
                                                123, 456, 789};
  ASSERT_TRUE(server.send_user_input(expected));
  PlutoStatus status = kPlutoStatusAgain;
  for (int attempt = 0; attempt < 50 && status == kPlutoStatusAgain;
       ++attempt) {
    status = pluto::qtfb_receive_user_input(presenter.get(), &received);
    if (status == kPlutoStatusAgain) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  ASSERT_EQ(status, kPlutoStatusOk);
  EXPECT_EQ(received.inputType, expected.inputType);
  EXPECT_EQ(received.devId, expected.devId);
  EXPECT_EQ(received.x, expected.x);
  EXPECT_EQ(received.y, expected.y);
  EXPECT_EQ(received.d, expected.d);
}

TEST(QtfbPresenterTest, FullFramePresentCopiesBytesAndSendsUpdateAll) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  std::vector<uint8_t> frame = patterned_frame();
  const std::vector<PlutoRect> damage{{0, 0, kWidth, kHeight}};
  PlutoPresentRequest request = make_request(frame, damage, kPlutoRefreshUi, 1);
  ASSERT_EQ(ops->present(presenter.get(), &request), kPlutoStatusOk);
  ASSERT_TRUE(server.wait_for_updates(1));

  const std::vector<pluto::qtfb::UpdateRegionMessageContents> updates =
      server.updates();
  ASSERT_EQ(updates.size(), static_cast<size_t>(1));
  EXPECT_EQ(updates[0].type, pluto::qtfb::kUpdateAll);
  ASSERT_TRUE(server.framebuffer() != nullptr);
  EXPECT_EQ(std::memcmp(server.framebuffer(), frame.data(), frame.size()), 0);

  frame[0] ^= 0xffu;
  EXPECT_TRUE(server.framebuffer()[0] != frame[0]);

  std::vector<uint8_t> snapshot(kFrameSize);
  PlutoSurface out{};
  out.pixels = snapshot.data();
  out.stride_bytes = kStride;
  out.width = kWidth;
  out.height = kHeight;
  out.format = kPlutoPixelFormatRgb565;
  EXPECT_EQ(ops->snapshot(presenter.get(), &out), kPlutoStatusOk);
  EXPECT_EQ(std::memcmp(snapshot.data(), server.framebuffer(), kFrameSize), 0);
}

TEST(QtfbPresenterTest, PartialPresentUpdatesOnlyRectAndSendsCoords) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  std::vector<uint8_t> base(kFrameSize, 0x11);
  const std::vector<PlutoRect> full{{0, 0, kWidth, kHeight}};
  PlutoPresentRequest full_request =
      make_request(base, full, kPlutoRefreshUi, 1);
  ASSERT_EQ(ops->present(presenter.get(), &full_request), kPlutoStatusOk);
  ASSERT_TRUE(server.wait_for_updates(1));
  server.clear_updates();

  std::vector<uint8_t> next = base;
  const PlutoRect rect{16, 24, 12, 5};
  for (int y = 0; y < rect.height; ++y) {
    for (int x = 0; x < rect.width; ++x) {
      const size_t offset = static_cast<size_t>(rect.y + y) * kStride +
                            static_cast<size_t>(rect.x + x) * kBytesPerPixel;
      next[offset] = 0x22;
      next[offset + 1] = 0x33;
    }
  }

  const std::vector<PlutoRect> damage{rect};
  PlutoPresentRequest partial_request =
      make_request(next, damage, kPlutoRefreshFast, 2);
  ASSERT_EQ(ops->present(presenter.get(), &partial_request), kPlutoStatusOk);
  ASSERT_TRUE(server.wait_for_updates(1));

  const std::vector<pluto::qtfb::UpdateRegionMessageContents> updates =
      server.updates();
  ASSERT_EQ(updates.size(), static_cast<size_t>(1));
  EXPECT_EQ(updates[0].type, pluto::qtfb::kUpdatePartial);
  EXPECT_EQ(updates[0].x, rect.x);
  EXPECT_EQ(updates[0].y, rect.y);
  EXPECT_EQ(updates[0].w, rect.width);
  EXPECT_EQ(updates[0].h, rect.height);

  bool framebuffer_matches = true;
  for (int y = 0; y < kHeight && framebuffer_matches; ++y) {
    for (int x = 0; x < kWidth && framebuffer_matches; ++x) {
      const bool inside = x >= rect.x && y >= rect.y &&
                          x < rect.x + rect.width && y < rect.y + rect.height;
      const size_t offset = static_cast<size_t>(y) * kStride +
                            static_cast<size_t>(x) * kBytesPerPixel;
      const uint8_t *expected = inside ? next.data() : base.data();
      framebuffer_matches =
          server.framebuffer()[offset] == expected[offset] &&
          server.framebuffer()[offset + 1] == expected[offset + 1];
    }
  }
  EXPECT_TRUE(framebuffer_matches);
}

TEST(QtfbPresenterTest, SparkleDevelopIsAcceptedNoOp) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  std::vector<uint8_t> base(kFrameSize, 0x11);
  const std::vector<PlutoRect> full{{0, 0, kWidth, kHeight}};
  PlutoPresentRequest seed = make_request(base, full, kPlutoRefreshUi, 1);
  ASSERT_EQ(ops->present(presenter.get(), &seed), kPlutoStatusOk);
  ASSERT_TRUE(server.wait_for_updates(1));
  server.clear_updates();

  std::vector<uint8_t> changed(kFrameSize, 0xee);
  const std::vector<PlutoRect> damage{{16, 24, 64, 64}};
  PlutoPresentRequest sparkle =
      make_request(changed, damage, kPlutoRefreshFast, 2);
  sparkle.flags |= kPlutoPresentFlagSparkle | kPlutoPresentFlagSparkleDevelop;
  ASSERT_EQ(ops->present(presenter.get(), &sparkle), kPlutoStatusOk);

  EXPECT_TRUE(server.updates().empty());
  ASSERT_TRUE(server.framebuffer() != nullptr);
  EXPECT_EQ(std::memcmp(server.framebuffer(), base.data(), base.size()), 0);
}

TEST(QtfbPresenterTest, FullRefreshClassPromotesPartialDamageToUpdateAll) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  std::vector<uint8_t> frame(kFrameSize, 0);
  const PlutoRect rect{8, 8, 8, 8};
  const std::vector<PlutoRect> damage{rect};
  PlutoPresentRequest request =
      make_request(frame, damage, kPlutoRefreshFull, 1);
  ASSERT_EQ(ops->present(presenter.get(), &request), kPlutoStatusOk);
  ASSERT_TRUE(server.wait_for_updates(1));
  const std::vector<pluto::qtfb::UpdateRegionMessageContents> updates =
      server.updates();
  ASSERT_EQ(updates.size(), static_cast<size_t>(1));
  EXPECT_EQ(updates[0].type, pluto::qtfb::kUpdateAll);
}

TEST(QtfbPresenterTest, PenTruthFullKeepsAppDamageRegional) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  std::vector<uint8_t> frame = patterned_frame();
  const PlutoRect rect{16, 24, 32, 16};
  const std::vector<PlutoRect> damage{rect};
  PlutoPresentRequest request =
      make_request(frame, damage, kPlutoRefreshFull, 1);
  request.flags |= kPlutoPresentFlagPenTruth;
  ASSERT_EQ(ops->present(presenter.get(), &request), kPlutoStatusOk);
  ASSERT_TRUE(server.wait_for_updates(1));

  const std::vector<pluto::qtfb::UpdateRegionMessageContents> updates =
      server.updates();
  ASSERT_EQ(updates.size(), static_cast<size_t>(1));
  EXPECT_EQ(updates[0].type, pluto::qtfb::kUpdatePartial);
  EXPECT_EQ(updates[0].x, rect.x);
  EXPECT_EQ(updates[0].y, rect.y);
  EXPECT_EQ(updates[0].w, rect.width);
  EXPECT_EQ(updates[0].h, rect.height);

  ASSERT_TRUE(server.framebuffer() != nullptr);
  const size_t inside = static_cast<size_t>(rect.y) * kStride +
                        static_cast<size_t>(rect.x) * kBytesPerPixel;
  EXPECT_EQ(server.framebuffer()[inside], frame[inside]);
  EXPECT_EQ(server.framebuffer()[inside + 1], frame[inside + 1]);
  // A regional truth chase copies no unrelated surface pixels.
  EXPECT_EQ(server.framebuffer()[0], 0u);
  EXPECT_EQ(server.framebuffer()[1], 0u);
}

TEST(QtfbPresenterTest, LaterFastPresentCannotShortenOutstandingFullIdleFence) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  std::vector<uint8_t> frame(kFrameSize, 0x44);
  const std::vector<PlutoRect> damage{{16, 24, 32, 16}};
  PlutoPresentRequest truth = make_request(frame, damage, kPlutoRefreshFull, 1);
  truth.flags |= kPlutoPresentFlagPenTruth;
  ASSERT_EQ(ops->present(presenter.get(), &truth), kPlutoStatusOk);

  frame[static_cast<size_t>(damage[0].y) * kStride +
        static_cast<size_t>(damage[0].x) * kBytesPerPixel] ^= 0xffu;
  PlutoPresentRequest preview =
      make_request(frame, damage, kPlutoRefreshFast, 2);
  preview.flags |= kPlutoPresentFlagInkPriority;
  ASSERT_EQ(ops->present(presenter.get(), &preview), kPlutoStatusOk);

  // Fast's nominal fence is 260 ms while Full's is 1500 ms. The later Fast
  // request must not make a 300 ms wait report idle while Full is outstanding.
  EXPECT_EQ(ops->wait_idle(presenter.get(), 300), kPlutoStatusTimeout);
}

TEST(QtfbPresenterTest, SyntheticIdleFenceExpiresNormally) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  std::vector<uint8_t> frame(kFrameSize, 0x55);
  const std::vector<PlutoRect> damage{{8, 8, 16, 16}};
  PlutoPresentRequest request =
      make_request(frame, damage, kPlutoRefreshFast, 1);
  ASSERT_EQ(ops->present(presenter.get(), &request), kPlutoStatusOk);

  EXPECT_EQ(ops->wait_idle(presenter.get(), 0), kPlutoStatusTimeout);
  EXPECT_EQ(ops->wait_idle(presenter.get(), 400), kPlutoStatusOk);
  EXPECT_EQ(ops->wait_idle(presenter.get(), 0), kPlutoStatusOk);
}

TEST(QtfbPresenterTest, PartiallyAcceptedFullRequestStillArmsFullIdleFence) {
  const auto key = next_key();
  FakeQtfbServer server(key, false);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key, "send_buffer=512");

  std::vector<uint8_t> frame(kFrameSize, 0x66);
  // The server deliberately stops reading after the handshake. One large
  // regional request therefore accepts an initial prefix of update packets and
  // deterministically reaches backpressure later in the same present() call.
  std::vector<PlutoRect> damage(200000, PlutoRect{8, 8, 1, 1});
  PlutoPresentRequest truth = make_request(frame, damage, kPlutoRefreshFull, 1);
  truth.flags |= kPlutoPresentFlagPenTruth;
  ASSERT_EQ(ops->present(presenter.get(), &truth), kPlutoStatusAgain);

  // Although the whole request was declined for retry, xochitl already owns
  // its accepted prefix. That prefix needs Full's 1500 ms synthetic fence, not
  // an immediate idle report (or a previous Fast request's 260 ms deadline).
  EXPECT_EQ(ops->wait_idle(presenter.get(), 300), kPlutoStatusTimeout);
}

TEST(QtfbPresenterTest, DeviceLossWhenServerClosesConnection) {
  const auto key = next_key();
  FakeQtfbServer server(key);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key);

  server.close_client();
  std::vector<uint8_t> frame(kFrameSize, 0x44);
  const std::vector<PlutoRect> damage{{0, 0, 8, 8}};
  PlutoStatus status = kPlutoStatusOk;
  for (int attempt = 0; attempt < 50; ++attempt) {
    PlutoPresentRequest request = make_request(
        frame, damage, kPlutoRefreshUi, static_cast<uint64_t>(attempt + 1));
    status = ops->present(presenter.get(), &request);
    if (status == kPlutoStatusDeviceLost) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  EXPECT_EQ(status, kPlutoStatusDeviceLost);
}

TEST(QtfbPresenterTest, BackpressureReturnsAgain) {
  const auto key = next_key();
  FakeQtfbServer server(key, false);
  ASSERT_TRUE(server.start());
  const PlutoPresenterOps *ops = pluto_presenter_by_name("qtfb");
  ASSERT_TRUE(ops != nullptr);
  auto presenter = open_presenter(ops, &server, key, "send_buffer=512");

  std::vector<uint8_t> frame(kFrameSize, 0x55);
  const std::vector<PlutoRect> damage{{0, 0, 1, 1}};
  bool saw_again = false;
  PlutoStatus status = kPlutoStatusOk;
  for (int i = 0; i < 200000; ++i) {
    PlutoPresentRequest request = make_request(frame, damage, kPlutoRefreshFast,
                                               static_cast<uint64_t>(i + 1));
    status = ops->present(presenter.get(), &request);
    if (status == kPlutoStatusAgain) {
      saw_again = true;
      break;
    }
    if (status != kPlutoStatusOk) {
      break;
    }
  }
  EXPECT_TRUE(saw_again);
  EXPECT_EQ(status, kPlutoStatusAgain);
  EXPECT_FALSE(ops->ready(presenter.get(), kPlutoRefreshFast));
}
