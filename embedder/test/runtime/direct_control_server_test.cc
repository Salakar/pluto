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
using pluto::DirectInkCanvasResult;
using pluto::DirectPointerResult;
using pluto::DirectScreenshotCapture;
using pluto::DirectScreenshotSurface;

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
  const std::int64_t pid = static_cast<std::int64_t>(::getpid());
  std::string received_app;
  std::int64_t received_pid = 0;
  config.draw_stroke = [&](const std::string &app_id, std::int64_t expected_pid,
                           DirectPointerResult *result,
                           DirectControlFailure *) {
    received_app = app_id;
    received_pid = expected_pid;
    *result = DirectPointerResult{
        .app_id = app_id,
        .pid = expected_pid,
        .event_count = 24,
    };
    return true;
  };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string response =
      request(server.socket_path(),
              "{\"requestId\":\"stroke-1\",\"action\":\"draw-"
              "stroke\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":" +
                  std::to_string(pid) + "}");
  EXPECT_EQ(received_app, "dev.pluto.ink");
  EXPECT_EQ(received_pid, pid);
  EXPECT_EQ(response, "{\"requestId\":\"stroke-1\",\"ok\":true,"
                      "\"result\":{\"appId\":\"dev.pluto.ink\",\"pid\":" +
                          std::to_string(pid) + ",\"eventCount\":24}}")
      << response;
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest,
     PreparesInkCanvasOnlyForTheRequestBoundForegroundPid) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  const std::int64_t pid = static_cast<std::int64_t>(::getpid());
  std::string received_app;
  std::int64_t received_pid = 0;
  config.prepare_ink_canvas =
      [&](const std::string &app_id, std::int64_t expected_pid,
          DirectInkCanvasResult *result, DirectControlFailure *) {
        received_app = app_id;
        received_pid = expected_pid;
        *result = DirectInkCanvasResult{
            .app_id = app_id,
            .pid = expected_pid,
            .action_count = 2,
            .canvas_ready = true,
        };
        return true;
      };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string response =
      request(server.socket_path(),
              "{\"requestId\":\"prepare-1\",\"action\":\"prepare-ink-"
              "canvas\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":" +
                  std::to_string(pid) + "}");
  EXPECT_EQ(received_app, "dev.pluto.ink");
  EXPECT_EQ(received_pid, pid);
  EXPECT_EQ(response, "{\"requestId\":\"prepare-1\",\"ok\":true,"
                      "\"result\":{\"appId\":\"dev.pluto.ink\",\"pid\":" +
                          std::to_string(pid) +
                          ",\"canvasReady\":true,\"actionCount\":2}}")
      << response;
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest, InkCanvasPreparationRejectsUnboundArguments) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  int calls = 0;
  config.prepare_ink_canvas = [&](const std::string &, std::int64_t,
                                  DirectInkCanvasResult *,
                                  DirectControlFailure *) {
    ++calls;
    return false;
  };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string missing_pid = request(
      server.socket_path(),
      R"({"requestId":"prepare-missing","action":"prepare-ink-canvas","appId":"dev.pluto.ink"})");
  EXPECT_NE(missing_pid.find("prepare-ink-canvas requires expectedPid"),
            std::string::npos)
      << missing_pid;
  const std::string null_app = request(
      server.socket_path(),
      R"({"requestId":"prepare-null","action":"prepare-ink-canvas","appId":null,"expectedPid":12})");
  EXPECT_NE(null_app.find("prepare-ink-canvas requires a concrete appId"),
            std::string::npos)
      << null_app;
  for (const std::string &pid :
       {"0", "-1", "1.5", "1e2", "9223372036854775808"}) {
    const std::string response = request(
        server.socket_path(),
        "{\"requestId\":\"prepare-bad-pid\",\"action\":\""
        "prepare-ink-canvas\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":" +
            pid + "}");
    EXPECT_NE(response.find("expectedPid must be a positive integer"),
              std::string::npos)
        << response;
  }
  const std::string surface = request(
      server.socket_path(),
      R"({"requestId":"prepare-surface","action":"prepare-ink-canvas","appId":"dev.pluto.ink","expectedPid":12,"surface":"logical"})");
  EXPECT_NE(surface.find("does not accept a screenshot surface"),
            std::string::npos)
      << surface;
  EXPECT_EQ(calls, 0);
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest, InkCanvasPreparationMetadataFailsClosed) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  const std::int64_t pid = static_cast<std::int64_t>(::getpid());
  config.prepare_ink_canvas =
      [](const std::string &app_id, std::int64_t expected_pid,
         DirectInkCanvasResult *result, DirectControlFailure *) {
        *result = DirectInkCanvasResult{
            .app_id = app_id,
            .pid = expected_pid + 1,
            .action_count = 3,
            .canvas_ready = false,
        };
        return true;
      };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string response = request(
      server.socket_path(),
      "{\"requestId\":\"prepare-invalid\",\"action\":\""
      "prepare-ink-canvas\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":" +
          std::to_string(pid) + "}");
  EXPECT_NE(response.find(R"("ok":false)"), std::string::npos) << response;
  EXPECT_NE(response.find("callback returned invalid metadata"),
            std::string::npos)
      << response;
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest,
     DispatchesBoundedSwitcherPreviewTapAndReturnsIdentity) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  std::string received_app;
  config.tap_switcher_preview = [&](const std::string &app_id,
                                    DirectPointerResult *result,
                                    DirectControlFailure *) {
    received_app = app_id;
    *result = DirectPointerResult{
        .app_id = app_id,
        .pid = static_cast<std::int64_t>(::getpid()),
        .event_count = 4,
    };
    return true;
  };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string response = request(
      server.socket_path(),
      R"({"requestId":"switch-1","action":"tap-switcher-preview","appId":"dev.pluto.launcher"})");
  EXPECT_EQ(received_app, "dev.pluto.launcher");
  EXPECT_EQ(response,
            "{\"requestId\":\"switch-1\",\"ok\":true,"
            "\"result\":{\"appId\":\"dev.pluto.launcher\",\"pid\":" +
                std::to_string(static_cast<std::int64_t>(::getpid())) +
                ",\"eventCount\":4}}")
      << response;
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest, RejectsSwitcherTapWithNonExactEventReceipt) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  config.tap_switcher_preview = [](const std::string &app_id,
                                   DirectPointerResult *result,
                                   DirectControlFailure *) {
    *result = DirectPointerResult{
        .app_id = app_id,
        .pid = static_cast<std::int64_t>(::getpid()),
        .event_count = 5,
    };
    return true;
  };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string response = request(
      server.socket_path(),
      R"({"requestId":"switch-invalid","action":"tap-switcher-preview","appId":"dev.pluto.launcher"})");
  EXPECT_NE(response.find(R"("ok":false)"), std::string::npos) << response;
  EXPECT_NE(response.find("tap-switcher-preview callback returned invalid "
                          "metadata"),
            std::string::npos)
      << response;
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest, InkStrokeRejectsUnboundArguments) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  int calls = 0;
  config.draw_stroke = [&](const std::string &, std::int64_t,
                           DirectPointerResult *, DirectControlFailure *) {
    ++calls;
    return false;
  };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string missing_pid = request(
      server.socket_path(),
      R"({"requestId":"stroke-missing","action":"draw-stroke","appId":"dev.pluto.ink"})");
  EXPECT_NE(missing_pid.find("draw-stroke requires expectedPid"),
            std::string::npos)
      << missing_pid;
  const std::string null_app = request(
      server.socket_path(),
      R"({"requestId":"stroke-null","action":"draw-stroke","appId":null,"expectedPid":12})");
  EXPECT_NE(null_app.find(R"("ok":false)"), std::string::npos) << null_app;
  EXPECT_NE(null_app.find("draw-stroke requires a concrete appId"),
            std::string::npos)
      << null_app;
  for (const std::string &pid :
       {"0", "-1", "1.5", "1e2", "9223372036854775808"}) {
    const std::string response =
        request(server.socket_path(),
                "{\"requestId\":\"stroke-bad-pid\",\"action\":\""
                "draw-stroke\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":" +
                    pid + "}");
    EXPECT_NE(response.find("expectedPid must be a positive integer"),
              std::string::npos)
        << response;
  }
  const std::string surface = request(
      server.socket_path(),
      R"({"requestId":"stroke-surface","action":"draw-stroke","appId":"dev.pluto.ink","expectedPid":12,"surface":"logical"})");
  EXPECT_NE(surface.find(R"("ok":false)"), std::string::npos) << surface;
  EXPECT_NE(surface.find("does not accept a screenshot surface"),
            std::string::npos)
      << surface;
  const std::string unknown = request(
      server.socket_path(),
      R"({"requestId":"stroke-unknown","action":"draw-stroke","appId":"dev.pluto.ink","expectedPid":12,"extra":true})");
  EXPECT_NE(unknown.find("request contains an unknown field"),
            std::string::npos)
      << unknown;
  const std::string versioned = request(
      server.socket_path(),
      R"({"schema":1,"requestId":"stroke-versioned","action":"draw-stroke","appId":"dev.pluto.ink","expectedPid":12})");
  EXPECT_NE(versioned.find("request contains an unknown field"),
            std::string::npos)
      << versioned;
  const std::string tap_null = request(
      server.socket_path(),
      R"({"requestId":"tap-null","action":"tap-switcher-preview","appId":null})");
  EXPECT_NE(tap_null.find(R"("ok":false)"), std::string::npos) << tap_null;
  EXPECT_NE(tap_null.find("tap-switcher-preview requires a concrete appId"),
            std::string::npos)
      << tap_null;
  EXPECT_EQ(calls, 0);
  server.stop();
  std::filesystem::remove_all(run_dir);
}

TEST(DirectControlServerTest, FailsClosedWithoutAValidStrokeResult) {
  const std::filesystem::path unavailable_dir = unique_run_dir();
  DirectControlServer unavailable(config_for(unavailable_dir));
  const std::int64_t pid = static_cast<std::int64_t>(::getpid());
  std::string error;
  ASSERT_TRUE(unavailable.start(&error)) << error;
  const std::string unavailable_response =
      request(unavailable.socket_path(),
              "{\"requestId\":\"stroke-unavailable\",\"action\":"
              "\"draw-stroke\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":" +
                  std::to_string(pid) + "}");
  EXPECT_NE(unavailable_response.find(R"("ok":false)"), std::string::npos)
      << unavailable_response;
  EXPECT_NE(unavailable_response.find("programmatic stroke is not available"),
            std::string::npos)
      << unavailable_response;
  unavailable.stop();
  std::filesystem::remove_all(unavailable_dir);

  const std::filesystem::path invalid_dir = unique_run_dir();
  DirectControlServerConfig invalid_config = config_for(invalid_dir);
  invalid_config.draw_stroke =
      [](const std::string &app_id, std::int64_t expected_pid,
         DirectPointerResult *result, DirectControlFailure *) {
        *result = DirectPointerResult{
            .app_id = app_id,
            .pid = expected_pid + 1,
            .event_count = 24,
        };
        return true;
      };
  DirectControlServer invalid(std::move(invalid_config));
  ASSERT_TRUE(invalid.start(&error)) << error;
  const std::string invalid_response =
      request(invalid.socket_path(),
              "{\"requestId\":\"stroke-invalid\",\"action\":\"draw-"
              "stroke\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":" +
                  std::to_string(pid) + "}");
  EXPECT_NE(invalid_response.find(R"("ok":false)"), std::string::npos)
      << invalid_response;
  EXPECT_NE(invalid_response.find("invalid metadata"), std::string::npos)
      << invalid_response;
  invalid.stop();
  std::filesystem::remove_all(invalid_dir);
}

TEST(DirectControlServerTest, InkStrokeRejectsARequestForAnotherProcess) {
  const std::filesystem::path run_dir = unique_run_dir();
  DirectControlServerConfig config = config_for(run_dir);
  int calls = 0;
  config.draw_stroke = [&](const std::string &, std::int64_t,
                           DirectPointerResult *, DirectControlFailure *) {
    ++calls;
    return true;
  };

  DirectControlServer server(std::move(config));
  std::string error;
  ASSERT_TRUE(server.start(&error)) << error;
  const std::string response = request(
      server.socket_path(),
      "{\"requestId\":\"stroke-wrong-pid\",\"action\":\""
      "draw-stroke\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":" +
          std::to_string(static_cast<std::int64_t>(::getpid()) + 1) + "}");
  EXPECT_NE(response.find(R"("ok":false)"), std::string::npos) << response;
  EXPECT_NE(response.find(R"("code":"wrong-pid")"), std::string::npos)
      << response;
  EXPECT_EQ(calls, 0);
  server.stop();
  std::filesystem::remove_all(run_dir);
}

} // namespace
