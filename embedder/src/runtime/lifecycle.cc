#include "runtime/lifecycle.h"

namespace pluto {

bool LifecycleStateMachine::transition_to(LifecycleState next) {
  if (state_ == next) {
    return true;
  }
  switch (state_) {
    case LifecycleState::kDetached:
      if (next == LifecycleState::kResumed || next == LifecycleState::kPaused) {
        state_ = next;
        return true;
      }
      return false;
    case LifecycleState::kResumed:
      if (next == LifecycleState::kInactive ||
          next == LifecycleState::kDetached) {
        state_ = next;
        return true;
      }
      return false;
    case LifecycleState::kInactive:
      if (next == LifecycleState::kResumed || next == LifecycleState::kPaused ||
          next == LifecycleState::kDetached) {
        state_ = next;
        return true;
      }
      return false;
    case LifecycleState::kPaused:
      if (next == LifecycleState::kInactive ||
          next == LifecycleState::kDetached) {
        state_ = next;
        return true;
      }
      return false;
  }
  return false;
}

std::string_view LifecycleStateMachine::channel_value() const {
  switch (state_) {
    case LifecycleState::kDetached:
      return "AppLifecycleState.detached";
    case LifecycleState::kResumed:
      return "AppLifecycleState.resumed";
    case LifecycleState::kInactive:
      return "AppLifecycleState.inactive";
    case LifecycleState::kPaused:
      return "AppLifecycleState.paused";
  }
  return "AppLifecycleState.detached";
}

}  // namespace pluto
