#include "channels/channel_registry.h"

#include "channels/json_codec.h"

namespace pluto {
namespace {

PlatformResponse lifecycle_response() {
  return PlatformResponse{};
}

PlatformResponse platform_response(ChannelRegistry* registry,
                                   const FlutterPlatformMessage& message) {
  std::optional<JsonMethodCall> call =
      json_method_decode(message.message, message.message_size);
  if (!call.has_value()) {
    return json_method_error("bad-args", "Malformed JSON platform call");
  }

  if (call->method == "SystemNavigator.pop") {
    if (registry->context().request_shutdown) {
      registry->context().request_shutdown();
    }
    return json_method_success(JsonValue());
  }
  if (call->method == "Clipboard.getData") {
    return json_method_success(
        JsonValue(JsonValue::Object{{"text", std::string()}}));
  }
  if (call->method == "Clipboard.setData" ||
      call->method == "System.initializationComplete" ||
      call->method.rfind("SystemChrome.", 0) == 0) {
    return json_method_success(JsonValue());
  }
  return json_method_error("unimplemented",
                           "Unsupported flutter/platform method: " +
                               call->method);
}

}  // namespace

void register_system_channels(ChannelRegistry* registry) {
  registry->register_channel(
      "flutter/lifecycle",
      [](const FlutterPlatformMessage&, const PlatformResponder& responder) {
        responder(lifecycle_response());
      });
  registry->register_channel(
      "flutter/settings",
      [](const FlutterPlatformMessage&, const PlatformResponder& responder) {
        responder(json_method_success(JsonValue(JsonValue::Object{
            {"textScaleFactor", 1.0},
            {"platformBrightness", "light"},
            {"alwaysUse24HourFormat", false},
        })));
      });
  registry->register_channel(
      "flutter/platform",
      [registry](const FlutterPlatformMessage& message,
                 const PlatformResponder& responder) {
        responder(platform_response(registry, message));
      });
  registry->register_channel(
      "flutter/mousecursor",
      [](const FlutterPlatformMessage&, const PlatformResponder& responder) {
        responder(PlatformResponse{});
      });
  registry->register_channel(
      "flutter/accessibility",
      [](const FlutterPlatformMessage&, const PlatformResponder& responder) {
        responder(PlatformResponse{});
      });
}

}  // namespace pluto
