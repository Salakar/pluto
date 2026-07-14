#include "channels/event_channel.h"

#include <string>
#include <utility>
#include <vector>

#include "gtest/gtest.h"

namespace {

FlutterPlatformMessage message_for(const char* channel,
                                   const std::vector<uint8_t>& payload) {
  FlutterPlatformMessage message{};
  message.struct_size = sizeof(message);
  message.channel = channel;
  message.message = payload.empty() ? nullptr : payload.data();
  message.message_size = payload.size();
  message.response_handle =
      reinterpret_cast<const FlutterPlatformMessageResponseHandle*>(1);
  return message;
}

struct EventHarness {
  EventHarness() : channel("test/events") {
    channel.register_with(&registry);
    channel.set_sender([this](const std::string& name,
                              const std::vector<uint8_t>& message) {
      sent.emplace_back(name, message);
    });
  }

  // Returns the envelope status byte (0 success, 1 error).
  uint8_t invoke(const std::string& method,
                 pluto::StandardValue arguments = {}) {
    const std::vector<uint8_t> payload =
        pluto::StandardMethodCodec::encode_method_call(
            pluto::MethodCall{method, std::move(arguments)});
    FlutterPlatformMessage message = message_for("test/events", payload);
    std::vector<uint8_t> response;
    registry.handle_message(message,
                            [&response](const pluto::PlatformResponse& data) {
                              response = data;
                            });
    return response.empty() ? 255 : response[0];
  }

  pluto::ChannelRegistry registry;
  pluto::EventStreamChannel channel;
  std::vector<std::pair<std::string, std::vector<uint8_t>>> sent;
};

TEST(EventStreamChannel, EventsAreDroppedWithoutListener) {
  EventHarness harness;
  harness.channel.send_event(pluto::StandardValue(int64_t{7}));
  EXPECT_TRUE(harness.sent.empty());
  EXPECT_FALSE(harness.channel.has_listener());
}

TEST(EventStreamChannel, ListenEnablesSendsAndCancelStopsThem) {
  EventHarness harness;
  EXPECT_EQ(harness.invoke("listen"), 0);
  EXPECT_TRUE(harness.channel.has_listener());

  harness.channel.send_event(pluto::StandardValue(int64_t{42}));
  ASSERT_EQ(harness.sent.size(), 1u);
  EXPECT_EQ(harness.sent[0].first, "test/events");
  // Success envelope: status byte 0 then the encoded value.
  ASSERT_FALSE(harness.sent[0].second.empty());
  EXPECT_EQ(harness.sent[0].second[0], 0);
  const std::optional<pluto::StandardValue> value =
      pluto::StandardMessageCodec::decode(harness.sent[0].second.data() + 1,
                                            harness.sent[0].second.size() - 1);
  ASSERT_TRUE(value.has_value());
  ASSERT_NE(value->integer(), nullptr);
  EXPECT_EQ(*value->integer(), 42);

  EXPECT_EQ(harness.invoke("cancel"), 0);
  EXPECT_FALSE(harness.channel.has_listener());
  harness.channel.send_event(pluto::StandardValue(int64_t{43}));
  EXPECT_EQ(harness.sent.size(), 1u);
}

TEST(EventStreamChannel, ListenHandlerReceivesArguments) {
  EventHarness harness;
  pluto::StandardValue captured;
  harness.channel.set_listen_handler(
      [&captured](const pluto::StandardValue& args) { captured = args; });
  harness.invoke("listen",
                 pluto::make_map({{"periodMs", int64_t{25}}}));
  const pluto::StandardValue::Map* map = captured.map();
  ASSERT_NE(map, nullptr);
  ASSERT_EQ(map->size(), 1u);
  EXPECT_EQ(*(*map)[0].second.integer(), 25);
}

TEST(EventStreamChannel, ErrorsAreErrorEnvelopes) {
  EventHarness harness;
  harness.invoke("listen");
  harness.channel.send_error("unavailable", "gone");
  ASSERT_EQ(harness.sent.size(), 1u);
  ASSERT_FALSE(harness.sent[0].second.empty());
  EXPECT_EQ(harness.sent[0].second[0], 1);
}

TEST(EventStreamChannel, UnknownMethodIsAnError) {
  EventHarness harness;
  EXPECT_EQ(harness.invoke("bogus"), 1);
}

}  // namespace
