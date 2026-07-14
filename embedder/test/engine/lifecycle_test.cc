#include "runtime/lifecycle.h"

#include "gtest/gtest.h"

namespace {

TEST(LifecycleStateMachine, AllowsExpectedForegroundBackgroundTransitions) {
  pluto::LifecycleStateMachine lifecycle;
  EXPECT_EQ(lifecycle.channel_value(), "AppLifecycleState.detached");
  EXPECT_TRUE(lifecycle.transition_to(pluto::LifecycleState::kResumed));
  EXPECT_EQ(lifecycle.channel_value(), "AppLifecycleState.resumed");
  EXPECT_TRUE(lifecycle.transition_to(pluto::LifecycleState::kInactive));
  EXPECT_TRUE(lifecycle.transition_to(pluto::LifecycleState::kPaused));
  EXPECT_EQ(lifecycle.channel_value(), "AppLifecycleState.paused");
}

TEST(LifecycleStateMachine, RejectsInvalidDirectTransitions) {
  pluto::LifecycleStateMachine lifecycle;
  EXPECT_FALSE(lifecycle.transition_to(pluto::LifecycleState::kInactive));
  EXPECT_TRUE(lifecycle.transition_to(pluto::LifecycleState::kResumed));
  EXPECT_FALSE(lifecycle.transition_to(pluto::LifecycleState::kPaused));
}

}  // namespace
