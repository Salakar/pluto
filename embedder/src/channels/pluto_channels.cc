#include "channels/channel_registry.h"
#include "channels/service_channels.h"

namespace pluto {
namespace {

PlatformResponse handle_refresh(ChannelRegistry* registry,
                                const MethodCall& call) {
  if (call.method == "requestFullRefresh") {
    const auto& callback = registry->context().request_full_refresh;
    if (!callback) {
      return standard_error("unavailable", "Renderer is not initialized");
    }
    if (!callback()) {
      return standard_error("not-ready",
                            "No settled Flutter frame is available yet");
    }
    return standard_success(make_map({{"accepted", true}}));
  }
  if (call.method == "requestGhostControl") {
    const auto& callback = registry->context().request_ghost_control;
    if (!callback) {
      return standard_error("unavailable", "Renderer is not initialized");
    }
    const std::string* mode = call.arguments.string();
    if (mode == nullptr) {
      return standard_error("invalid-argument",
                            "Ghost control mode must be a string");
    }
    if (*mode != "blinkNow" && *mode != "blinkLater" &&
        *mode != "bleachNow" && *mode != "factoryReset") {
      return standard_error("invalid-argument",
                            "Unknown ghost control mode: " + *mode);
    }
    if (!callback(*mode)) {
      return standard_error("not-ready",
                            "No settled Flutter frame is available yet");
    }
    return standard_success(
        make_map({{"accepted", true}, {"mode", *mode}}));
  }
  if (call.method == "requestRefresh") {
    // Ordinary region hints remain unnecessary: the compositor derives exact
    // damage and refresh class automatically for every Flutter frame.
    return standard_unimplemented(call.method);
  }
  if (call.method == "getDisplayInfo") {
    return standard_error("unavailable",
                          "Display info is not connected before presenter init");
  }
  return standard_unimplemented(call.method);
}

PlatformResponse control_stub(const MethodCall& call) {
  return standard_unimplemented(call.method);
}

}  // namespace

void register_pluto_channels(ChannelRegistry* registry) {
  registry->register_standard_method_channel(
      "pluto/refresh", [registry](const MethodCall& call) {
        return handle_refresh(registry, call);
      });
  // Replaced with the live PenService when EngineHost wires input.
  registry->register_standard_method_channel("pluto/pen", control_stub);
  // pluto/core, pluto/device, pluto/paths, pluto/session,
  // pluto/settings, and pluto/apps.
  register_service_channels(registry, service_paths_from_env());
}

}  // namespace pluto
