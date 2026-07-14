#include "input/transform.h"

#include <gtest/gtest.h>

#include <cmath>

namespace {

void expect_near(float actual, float expected, float epsilon) {
  EXPECT_TRUE(std::fabs(actual - expected) <= epsilon)
      << "actual=" << actual << " expected=" << expected;
}

void expect_point_near(pluto::Point actual, pluto::Point expected) {
  expect_near(actual.x, expected.x, 0.0001f);
  expect_near(actual.y, expected.y, 0.0001f);
}

}  // namespace

TEST(PlutoTransformTest, PanelToLogicalGoldensMatchDoc04) {
  constexpr float w = 954.0f;
  constexpr float h = 1696.0f;
  const pluto::Point p{.x = 10.0f, .y = 20.0f};

  expect_point_near(pluto::panel_to_logical(p, w, h, pluto::Orientation::kDeg0),
                    {.x = 10.0f, .y = 20.0f});
  expect_point_near(pluto::panel_to_logical(p, w, h, pluto::Orientation::kDeg90),
                    {.x = 20.0f, .y = 944.0f});
  expect_point_near(
      pluto::panel_to_logical(p, w, h, pluto::Orientation::kDeg180),
      {.x = 944.0f, .y = 1676.0f});
  expect_point_near(
      pluto::panel_to_logical(p, w, h, pluto::Orientation::kDeg270),
      {.x = 1676.0f, .y = 10.0f});
}

TEST(PlutoTransformTest, LogicalRoundTripForAllOrientations) {
  constexpr float w = 954.0f;
  constexpr float h = 1696.0f;
  const pluto::Point panel{.x = 321.25f, .y = 999.5f};
  const pluto::Orientation orientations[] = {
      pluto::Orientation::kDeg0,
      pluto::Orientation::kDeg90,
      pluto::Orientation::kDeg180,
      pluto::Orientation::kDeg270,
  };
  for (pluto::Orientation orientation : orientations) {
    const pluto::Point logical =
        pluto::panel_to_logical(panel, w, h, orientation);
    expect_point_near(pluto::logical_to_panel(logical, w, h, orientation), panel);
  }
}

TEST(PlutoTransformTest, TiltVectorRotatesWithOrientation) {
  const pluto::Point tilt{.x = 3.0f, .y = 4.0f};
  expect_point_near(pluto::rotate_tilt(tilt, pluto::Orientation::kDeg0),
                    {.x = 3.0f, .y = 4.0f});
  expect_point_near(pluto::rotate_tilt(tilt, pluto::Orientation::kDeg90),
                    {.x = 4.0f, .y = -3.0f});
  expect_point_near(pluto::rotate_tilt(tilt, pluto::Orientation::kDeg180),
                    {.x = -3.0f, .y = -4.0f});
  expect_point_near(pluto::rotate_tilt(tilt, pluto::Orientation::kDeg270),
                    {.x = -4.0f, .y = 3.0f});
}

TEST(PlutoTransformTest, LogicalSizeSwapsOnlyAtRightAngleOrientations) {
  const pluto::Size portrait =
      pluto::logical_size(954.0f, 1696.0f, pluto::Orientation::kDeg0);
  const pluto::Size landscape =
      pluto::logical_size(954.0f, 1696.0f, pluto::Orientation::kDeg90);
  EXPECT_EQ(static_cast<int>(portrait.width), 954);
  EXPECT_EQ(static_cast<int>(portrait.height), 1696);
  EXPECT_EQ(static_cast<int>(landscape.width), 1696);
  EXPECT_EQ(static_cast<int>(landscape.height), 954);
}
