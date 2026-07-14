#include "channels/channel_registry.h"

#include <utility>

namespace pluto {

void ChannelRegistry::register_channel(std::string name, PlatformHandler handler) {
  handlers_[std::move(name)] = std::move(handler);
}

void ChannelRegistry::register_standard_method_channel(
    std::string name,
    std::function<PlatformResponse(const MethodCall&)> handler) {
  register_channel(
      std::move(name),
      [handler = std::move(handler)](const FlutterPlatformMessage& message,
                                     const PlatformResponder& responder) {
        std::optional<MethodCall> call =
            StandardMethodCodec::decode_method_call(message.message,
                                                    message.message_size);
        if (!call.has_value()) {
          responder(standard_error("bad-args", "Malformed method call"));
          return;
        }
        responder(handler(*call));
      });
}

void ChannelRegistry::handle_message(
    const FlutterPlatformMessage& message,
    const PlatformResponder& responder) const {
  bool responded = false;
  const PlatformResponder once = [&responded, &responder](const PlatformResponse& data) {
    if (responded) {
      return;
    }
    responded = true;
    responder(data);
  };

  const std::string channel = message.channel == nullptr ? "" : message.channel;
  const auto it = handlers_.find(channel);
  if (it == handlers_.end()) {
    once(PlatformResponse{});
    return;
  }
  it->second(message, once);
  if (!responded) {
    once(PlatformResponse{});
  }
}

PlatformResponse standard_success(const StandardValue& value) {
  return StandardMethodCodec::encode_success_envelope(value);
}

PlatformResponse standard_error(const std::string& code,
                                const std::string& message,
                                const StandardValue& details) {
  return StandardMethodCodec::encode_error_envelope(
      MethodError{code, message, details});
}

PlatformResponse standard_unimplemented(const std::string& method) {
  return standard_error("unimplemented",
                        "Host method is not implemented: " + method);
}

}  // namespace pluto
