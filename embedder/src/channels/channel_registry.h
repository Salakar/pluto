#ifndef PLUTO_CHANNELS_CHANNEL_REGISTRY_H_
#define PLUTO_CHANNELS_CHANNEL_REGISTRY_H_

#include <cstdint>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

#include "channels/standard_codec.h"
#include "flutter/embedder.h"

namespace pluto {

using PlatformResponse = std::vector<uint8_t>;
using PlatformResponder = std::function<void(const PlatformResponse&)>;
using PlatformHandler = std::function<void(const FlutterPlatformMessage&,
                                           const PlatformResponder&)>;

struct ChannelContext {
  // Stable pluto_device wire identity, populated from immutable hardware
  // evidence by EngineHost. Unknown hardware must never masquerade as Move.
  std::string device_model = "unknown";
  std::string device_codename;
  int32_t panel_width = 954;
  int32_t panel_height = 1696;
  int32_t dpi = 264;
  bool is_color = true;
  int32_t rotation = 0;
  // Wire name of the panel-space pixel format ("rgb565" or "gray8").
  std::string pixel_format = "rgb565";
  std::string presenter_name = "null";
  std::function<void()> request_shutdown;
  // Release/profile app handoffs keep the Dart isolate alive after native
  // display/input ownership has been quiesced. Absent for debug and special
  // one-shot processes, which retain the cold-shutdown behavior.
  std::function<void()> request_hibernate;
  // Queues a full-screen quality pass of the current settled frame. Returns
  // false until the renderer has accepted at least one Flutter frame.
  std::function<bool()> request_full_refresh;
  // Stock-compatible ghost control mode names: blinkNow, blinkLater,
  // bleachNow, factoryReset.
  std::function<bool(const std::string&)> request_ghost_control;
  // Reveals a deferred launcher system surface only after Flutter has routed
  // to the switcher/status UI and produced a fresh frame. This keeps the
  // launcher's previously retained Home frame off the panel during handoff.
  std::function<bool()> system_ui_ready;
  std::function<void(int32_t)> set_rotation;
};

class ChannelRegistry {
 public:
  void set_context(ChannelContext context) { context_ = std::move(context); }
  const ChannelContext& context() const { return context_; }

  void register_channel(std::string name, PlatformHandler handler);
  void register_standard_method_channel(
      std::string name,
      std::function<PlatformResponse(const MethodCall&)> handler);

  void handle_message(const FlutterPlatformMessage& message,
                      const PlatformResponder& responder) const;

 private:
  ChannelContext context_;
  std::unordered_map<std::string, PlatformHandler> handlers_;
};

void register_system_channels(ChannelRegistry* registry);
void register_pluto_channels(ChannelRegistry* registry);

PlatformResponse standard_success(const StandardValue& value = {});
PlatformResponse standard_error(const std::string& code,
                                const std::string& message,
                                const StandardValue& details = {});
PlatformResponse standard_unimplemented(const std::string& method);

}  // namespace pluto

#endif  // PLUTO_CHANNELS_CHANNEL_REGISTRY_H_
