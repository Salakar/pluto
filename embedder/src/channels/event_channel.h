#ifndef PLUTO_CHANNELS_EVENT_CHANNEL_H_
#define PLUTO_CHANNELS_EVENT_CHANNEL_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "channels/channel_registry.h"

namespace pluto {

// Transmits an already-encoded platform message to the Dart side of
// `channel`. EngineHost installs a sender backed by
// FlutterEngineSendPlatformMessage. Flutter requires platform-channel sends on
// its platform thread; producers may encode elsewhere but must hand the final
// sender call back to that runner.
using EventSender =
    std::function<void(const std::string& channel,
                       const std::vector<uint8_t>& message)>;

// Embedder half of the Flutter EventChannel contract. Dart's
// EventChannel.receiveBroadcastStream sends StandardMethodCodec `listen` /
// `cancel` method calls on the channel; events flow back as standard
// success/error envelopes pushed on the same channel (empty message ends the
// stream). listen/cancel handlers run on the platform thread. The methods are
// internally synchronized, but EventSender executes on the caller, so a Flutter
// sender still needs the platform-thread handoff described above.
class EventStreamChannel {
 public:
  explicit EventStreamChannel(std::string name);

  EventStreamChannel(const EventStreamChannel&) = delete;
  EventStreamChannel& operator=(const EventStreamChannel&) = delete;

  const std::string& name() const { return name_; }

  // Receives the arguments Dart passed to receiveBroadcastStream.
  void set_listen_handler(std::function<void(const StandardValue&)> handler);
  void set_cancel_handler(std::function<void()> handler);

  void register_with(ChannelRegistry* registry);
  void set_sender(EventSender sender);

  bool has_listener() const;
  // Lock-free listener identity for producers that must never wait behind a
  // slow EventSender. Zero means no active listener; every listen call gets a
  // fresh non-zero token so delayed work from an older subscription cannot be
  // delivered into a later one.
  uint64_t listener_token() const {
    return listener_token_.load(std::memory_order_acquire);
  }

  // Dropped silently while no listener is attached.
  void send_event(const StandardValue& event);
  // Sends an envelope encoded off the platform thread only when `token` still
  // names the current listener. The EventSender itself runs on the
  // caller/platform thread and is serialized with listen/cancel so delayed pen
  // work cannot cross a subscription boundary.
  void send_encoded_event_for_listener(uint64_t token,
                                       std::vector<uint8_t> message);
  void send_error(const std::string& code, const std::string& message);
  void send_end_of_stream();

 private:
  PlatformResponse handle_call(const MethodCall& call);
  void transmit(std::vector<uint8_t> message);
  void transmit_for_listener(uint64_t token, std::vector<uint8_t> message);

  const std::string name_;
  mutable std::mutex mutex_;
  bool has_listener_ = false;
  std::atomic<uint64_t> listener_token_{0};
  uint64_t next_listener_token_ = 1;
  EventSender sender_;
  std::function<void(const StandardValue&)> listen_handler_;
  std::function<void()> cancel_handler_;
};

}  // namespace pluto

#endif  // PLUTO_CHANNELS_EVENT_CHANNEL_H_
