#include "channels/event_channel.h"

#include <utility>

namespace pluto {

EventStreamChannel::EventStreamChannel(std::string name)
    : name_(std::move(name)) {}

void EventStreamChannel::set_listen_handler(
    std::function<void(const StandardValue&)> handler) {
  std::lock_guard<std::mutex> lock(mutex_);
  listen_handler_ = std::move(handler);
}

void EventStreamChannel::set_cancel_handler(std::function<void()> handler) {
  std::lock_guard<std::mutex> lock(mutex_);
  cancel_handler_ = std::move(handler);
}

void EventStreamChannel::register_with(ChannelRegistry* registry) {
  registry->register_standard_method_channel(
      name_, [this](const MethodCall& call) { return handle_call(call); });
}

void EventStreamChannel::set_sender(EventSender sender) {
  std::lock_guard<std::mutex> lock(mutex_);
  sender_ = std::move(sender);
}

bool EventStreamChannel::has_listener() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return has_listener_;
}

PlatformResponse EventStreamChannel::handle_call(const MethodCall& call) {
  if (call.method == "listen") {
    std::function<void(const StandardValue&)> on_listen;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      has_listener_ = true;
      uint64_t token = next_listener_token_++;
      if (token == 0) {
        token = next_listener_token_++;
      }
      listener_token_.store(token, std::memory_order_release);
      on_listen = listen_handler_;
    }
    // Invoked unlocked so the handler may push an initial event.
    if (on_listen) {
      on_listen(call.arguments);
    }
    return standard_success();
  }
  if (call.method == "cancel") {
    std::function<void()> on_cancel;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      has_listener_ = false;
      listener_token_.store(0, std::memory_order_release);
      on_cancel = cancel_handler_;
    }
    if (on_cancel) {
      on_cancel();
    }
    return standard_success();
  }
  return standard_unimplemented(call.method);
}

void EventStreamChannel::send_event(const StandardValue& event) {
  transmit(StandardMethodCodec::encode_success_envelope(event));
}

void EventStreamChannel::send_encoded_event_for_listener(
    uint64_t token,
    std::vector<uint8_t> message) {
  transmit_for_listener(token, std::move(message));
}

void EventStreamChannel::send_error(const std::string& code,
                                    const std::string& message) {
  transmit(StandardMethodCodec::encode_error_envelope(
      MethodError{code, message, StandardValue()}));
}

void EventStreamChannel::send_end_of_stream() {
  transmit(std::vector<uint8_t>{});
}

void EventStreamChannel::transmit(std::vector<uint8_t> message) {
  EventSender sender;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!has_listener_ || !sender_) {
      return;
    }
    sender = sender_;
  }
  sender(name_, message);
}

void EventStreamChannel::transmit_for_listener(
    uint64_t token,
    std::vector<uint8_t> message) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (token == 0 || !has_listener_ || !sender_ ||
      listener_token_.load(std::memory_order_acquire) != token) {
    return;
  }
  // The pen observer runs on a normal-priority worker and its producer reads
  // listener_token_ atomically, so holding this lock across the send cannot
  // block the SCHED_FIFO input loop. It does make cancel/listen a strict wire
  // boundary: the old token is fully sent or fully rejected before it changes.
  sender_(name_, message);
}

}  // namespace pluto
