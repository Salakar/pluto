#ifndef PLUTO_RUNTIME_LIFECYCLE_H_
#define PLUTO_RUNTIME_LIFECYCLE_H_

#include <string_view>

namespace pluto {

enum class LifecycleState {
  kDetached,
  kResumed,
  kInactive,
  kPaused,
};

class LifecycleStateMachine {
 public:
  LifecycleState state() const { return state_; }
  bool transition_to(LifecycleState next);
  std::string_view channel_value() const;

 private:
  LifecycleState state_ = LifecycleState::kDetached;
};

}  // namespace pluto

#endif  // PLUTO_RUNTIME_LIFECYCLE_H_
