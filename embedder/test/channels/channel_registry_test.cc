#include "channels/channel_registry.h"

#include "gtest/gtest.h"

namespace {

FlutterPlatformMessage message_for(const char* channel,
                                   const std::vector<uint8_t>& payload) {
  FlutterPlatformMessage message{};
  message.struct_size = sizeof(message);
  message.channel = channel;
  message.message = payload.empty() ? nullptr : payload.data();
  message.message_size = payload.size();
  message.response_handle = reinterpret_cast<const FlutterPlatformMessageResponseHandle*>(1);
  return message;
}

TEST(ChannelRegistry, UnknownChannelsAreAnswered) {
  pluto::ChannelRegistry registry;
  int responses = 0;
  std::vector<uint8_t> last;
  std::vector<uint8_t> empty;
  FlutterPlatformMessage message = message_for("unknown/channel", empty);

  registry.handle_message(message, [&](const pluto::PlatformResponse& response) {
    ++responses;
    last = response;
  });

  EXPECT_EQ(responses, 1);
  EXPECT_TRUE(last.empty());
}

TEST(ChannelRegistry, HandlerThatForgetsStillGetsAResponse) {
  pluto::ChannelRegistry registry;
  registry.register_channel(
      "forgetful",
      [](const FlutterPlatformMessage&, const pluto::PlatformResponder&) {});
  int responses = 0;
  std::vector<uint8_t> empty;
  FlutterPlatformMessage message = message_for("forgetful", empty);

  registry.handle_message(message, [&](const pluto::PlatformResponse&) {
    ++responses;
  });

  EXPECT_EQ(responses, 1);
}

TEST(ChannelRegistry, PlutoStubsReturnTypedErrors) {
  pluto::ChannelRegistry registry;
  pluto::register_pluto_channels(&registry);
  const std::vector<uint8_t> payload =
      pluto::StandardMethodCodec::encode_method_call(
          pluto::MethodCall{"setFrontlight", int64_t{100}});
  FlutterPlatformMessage message = message_for("pluto/settings", payload);
  std::vector<uint8_t> response;

  registry.handle_message(message, [&](const pluto::PlatformResponse& data) {
    response = data;
  });

  ASSERT_TRUE(!response.empty());
  EXPECT_EQ(response[0], 1);
}

TEST(ChannelRegistry, DeviceOrientationIsStateful) {
  pluto::ChannelRegistry registry;
  pluto::register_pluto_channels(&registry);
  pluto::ChannelContext context;
  context.rotation = 0;
  context.set_rotation = [&context](int32_t rotation) { context.rotation = rotation; };
  registry.set_context(context);

  const std::vector<uint8_t> payload =
      pluto::StandardMethodCodec::encode_method_call(
          pluto::MethodCall{"setOrientation", int64_t{90}});
  FlutterPlatformMessage message = message_for("pluto/device", payload);
  std::vector<uint8_t> response;
  registry.handle_message(message, [&](const pluto::PlatformResponse& data) {
    response = data;
  });

  ASSERT_TRUE(!response.empty());
  EXPECT_EQ(response[0], 0);
  EXPECT_EQ(context.rotation, 90);
}

TEST(ChannelRegistry, FullRefreshUsesLiveRendererCallback) {
  pluto::ChannelRegistry registry;
  pluto::register_pluto_channels(&registry);
  bool requested = false;
  pluto::ChannelContext context;
  context.request_full_refresh = [&requested] {
    requested = true;
    return true;
  };
  registry.set_context(std::move(context));

  const std::vector<uint8_t> payload =
      pluto::StandardMethodCodec::encode_method_call(
          pluto::MethodCall{"requestFullRefresh", {}});
  FlutterPlatformMessage message = message_for("pluto/refresh", payload);
  std::vector<uint8_t> response;
  registry.handle_message(message, [&](const pluto::PlatformResponse& data) {
    response = data;
  });

  ASSERT_TRUE(!response.empty());
  EXPECT_EQ(response[0], 0);
  EXPECT_TRUE(requested);
}

TEST(ChannelRegistry, GhostControlUsesStockModeNames) {
  pluto::ChannelRegistry registry;
  pluto::register_pluto_channels(&registry);
  std::string requested;
  pluto::ChannelContext context;
  context.request_ghost_control = [&requested](const std::string& mode) {
    requested = mode;
    return true;
  };
  registry.set_context(std::move(context));

  const std::vector<uint8_t> payload =
      pluto::StandardMethodCodec::encode_method_call(
          pluto::MethodCall{"requestGhostControl", "bleachNow"});
  FlutterPlatformMessage message = message_for("pluto/refresh", payload);
  std::vector<uint8_t> response;
  registry.handle_message(message, [&](const pluto::PlatformResponse& data) {
    response = data;
  });

  ASSERT_TRUE(!response.empty());
  EXPECT_EQ(response[0], 0);
  EXPECT_EQ(requested, "bleachNow");
}

}  // namespace
