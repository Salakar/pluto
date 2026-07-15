#include "runtime/direct_control_server.h"

#include <gtest/gtest.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <optional>
#include <string>
#include <utility>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {

using pluto::DirectControlFailure;
using pluto::DirectControlServer;
using pluto::DirectControlServerConfig;
using pluto::DirectScreenshotCapture;
using pluto::DirectScreenshotSurface;
using pluto::DirectStrokeResult;

std::filesystem::path unique_run_dir() {
  static std::atomic<std::uint64_t> sequence{1};
  return std::filesystem::temp_directory_path() /
         ("pluto-direct-control-test-" + std::to_string(::getpid()) + "-" +
          std::to_string(sequence.fetch_add(1)));
}

std::string request(const std::string &socket_path, const std::string &json) {
  const int client = ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  EXPECT_GE(client, 0);
  if (client < 0) {
    return {};
  }
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  EXPECT_LT(socket_path.size(), sizeof(address.sun_path));
  std::memcpy(address.sun_path, socket_path.c_str(), socket_path.size() + 1);
  const socklen_t length = static_cast<socklen_t>(
      offsetof(sockaddr_un, sun_path) + socket_path.size() + 1);
  EXPECT_EQ(::connect(client, reinterpret_cast<sockaddr *>(&address), length),
            0);
  EXPECT_EQ(::send(client, json.data(), json.size(), MSG_NOSIGNAL),
            static_cast<ssize_t>(json.size()));
  char response[2048]{};
  const ssize_t received = ::recv(client, response, sizeof(response), 0);
  EXPECT_GT(received, 0);
  ::close(client);
  return received > 0
             ? std::string(response, static_cast<std::size_t>(received))
             : std::string();
}

DirectControlServerConfig config_for(const std::filesystem::path &run_dir) {
  DirectControlServerConfig config;
  config.run_dir = run_dir.string();
  config.screenshot =
      [](DirectScreenshotSurface, const std::optional<std::string> &,
         DirectScreenshotCapture *, DirectControlFailure *failure) {
        failure->code = "unused";
        failure->message = "not used by this test";
        return false;
      };
  return config;
}

TEST(DirectControlServerTest, DispatchesRootLocalInkStrokeAndReturnsIdentity) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  std::string received_app;
  config.draw_stroke = [&](const std::string &app_id,
                           DirectStrokeResult *result, DirectControlFailure *) {
    received_app = app_id;
    *result = DirectStrokeResult{
        .app_id = app_id,
        .pid = static_cast<std::int64_t>(::getpid()),
        .event_count = 24,
    };
    return true;
  };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string response = request(
      server.socket_path(),
      R"({"schema":1,"requestId":"stroke-1","action":"draw-stroke","appId":"dev.pluto.ink"})");
  EXPECT_EQ(received_app, "dev.pluto.ink");
  EXPECT_NE(response.find(R"("ok":true)"), std::string::npos) << response;
  EXPECT_NE(response.find(R"("appId":"dev.pluto.ink")"), std::string::npos)
      << response;
  EXPECT_NE(response.find(R"("eventCount":24)"), std::string::npos) << response;
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest, RejectsNullAppAndScreenshotOnlyFields) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  int calls = 0;
  config.draw_stroke = [&](const std::string &, DirectStrokeResult *,
                           DirectControlFailure *) {
    ++calls;
    return false;
  };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string null_app = request(
      server.socket_path(),
      R"({"schema":1,"requestId":"stroke-null","action":"draw-stroke","appId":null})");
  EXPECT_NE(null_app.find(R"("ok":false)"), std::string::npos) << null_app;
  EXPECT_NE(null_app.find("draw-stroke requires a concrete appId"),
            std::string::npos)
      << null_app;
  const std::string surface = request(
      server.socket_path(),
      R"({"schema":1,"requestId":"stroke-surface","action":"draw-stroke","appId":"dev.pluto.ink","surface":"logical"})");
  EXPECT_NE(surface.find(R"("ok":false)"), std::string::npos) << surface;
  EXPECT_NE(surface.find("does not accept a screenshot surface"),
            std::string::npos)
      << surface;
  EXPECT_EQ(calls, 0);
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest, FailsClosedWithoutAValidStrokeResult) {
  const std::filesystem::path unavailable_dir = unique_run_dir();
  DirectControlServer unavailable(config_for(unavailable_dir));
  std::string error;
  ASSERT_TRUE(unavailable.start(&error)) << error;
  const std::string unavailable_response = request(
      unavailable.socket_path(),
      R"({"schema":1,"requestId":"stroke-unavailable","action":"draw-stroke","appId":"dev.pluto.ink"})");
  EXPECT_NE(unavailable_response.find(R"("ok":false)"), std::string::npos)
      << unavailable_response;
  EXPECT_NE(unavailable_response.find("programmatic stroke is not available"),
            std::string::npos)
      << unavailable_response;
  unavailable.stop();
  std::filesystem::remove_all(unavailable_dir);

  const std::filesystem::path invalid_dir = unique_run_dir();
  DirectControlServerConfig invalid_config = config_for(invalid_dir);
  invalid_config.draw_stroke = [](const std::string &,
                                  DirectStrokeResult *result,
                                  DirectControlFailure *) {
    *result = DirectStrokeResult{
        .app_id = "dev.pluto.examples.counter",
        .pid = static_cast<std::int64_t>(::getpid()),
        .event_count = 24,
    };
    return true;
  };
  DirectControlServer invalid(std::move(invalid_config));
  ASSERT_TRUE(invalid.start(&error)) << error;
  const std::string invalid_response = request(
      invalid.socket_path(),
      R"({"schema":1,"requestId":"stroke-invalid","action":"draw-stroke","appId":"dev.pluto.ink"})");
  EXPECT_NE(invalid_response.find(R"("ok":false)"), std::string::npos)
      << invalid_response;
  EXPECT_NE(invalid_response.find("invalid metadata"), std::string::npos)
      << invalid_response;
  invalid.stop();
  std::filesystem::remove_all(invalid_dir);
}

} // namespace
