#include "input/calibrate.h"

#include <gtest/gtest.h>

#include <cmath>
#include <vector>

namespace {

void expect_near(float actual, float expected, float epsilon) {
  EXPECT_TRUE(std::fabs(actual - expected) <= epsilon)
      << "actual=" << actual << " expected=" << expected;
}

}  // namespace

TEST(PlutoCalibrationTest, SolverRecoversKnownAffineFromCornerTargets) {
  const pluto::AffineTransform truth{
      .a = 0.14f, .b = 0.001f, .c = 2.0f, .d = -0.0005f, .e = 0.142f, .f = -1.0f};
  const std::vector<pluto::CalibrationPoint> points = {
      {.raw = {0.0f, 0.0f}, .panel = truth.apply({0.0f, 0.0f})},
      {.raw = {6760.0f, 0.0f}, .panel = truth.apply({6760.0f, 0.0f})},
      {.raw = {6760.0f, 11960.0f}, .panel = truth.apply({6760.0f, 11960.0f})},
      {.raw = {0.0f, 11960.0f}, .panel = truth.apply({0.0f, 11960.0f})},
      {.raw = {3380.0f, 5980.0f}, .panel = truth.apply({3380.0f, 5980.0f})},
  };

  const auto solved = pluto::solve_affine_calibration(points);
  ASSERT_TRUE(solved.has_value());
  expect_near(solved->affine.a, truth.a, 0.00001f);
  expect_near(solved->affine.b, truth.b, 0.00001f);
  expect_near(solved->affine.c, truth.c, 0.01f);
  expect_near(solved->affine.d, truth.d, 0.00001f);
  expect_near(solved->affine.e, truth.e, 0.00001f);
  expect_near(solved->affine.f, truth.f, 0.01f);
  EXPECT_TRUE(solved->residual.max_px <= 0.01f);
}

TEST(PlutoCalibrationTest, LShapeHelperUsesFourCornersAndCenter) {
  const std::vector<pluto::Point> targets =
      pluto::l_shape_corner_targets(954.0f, 1696.0f, 60.0f);
  ASSERT_EQ(targets.size(), 5u);
  EXPECT_EQ(static_cast<int>(targets[0].x), 60);
  EXPECT_EQ(static_cast<int>(targets[0].y), 60);
  EXPECT_EQ(static_cast<int>(targets[4].x), 477);
  EXPECT_EQ(static_cast<int>(targets[4].y), 848);

  std::vector<pluto::Point> raw;
  for (const pluto::Point& target : targets) {
    raw.push_back(pluto::Point{.x = target.x * 2.0f, .y = target.y * 3.0f});
  }
  const auto solved =
      pluto::solve_l_shape_corner_calibration(raw, 954.0f, 1696.0f, 60.0f);
  ASSERT_TRUE(solved.has_value());
  expect_near(solved->affine.a, 0.5f, 0.00001f);
  expect_near(solved->affine.e, 1.0f / 3.0f, 0.00001f);
}

TEST(PlutoCalibrationTest, SerializationRoundTripsAffineFields) {
  pluto::CalibrationModel model;
  model.affine = {.a = 0.1f, .b = 0.2f, .c = 0.3f,
                  .d = 0.4f, .e = 0.5f, .f = 0.6f};
  model.residual = {.mean_px = 1.25f, .max_px = 2.5f};

  const std::string encoded = pluto::serialize_calibration(model);
  const auto decoded = pluto::deserialize_calibration(encoded);
  ASSERT_TRUE(decoded.has_value());
  expect_near(decoded->affine.a, model.affine.a, 0.00001f);
  expect_near(decoded->affine.f, model.affine.f, 0.00001f);
  expect_near(decoded->residual.mean_px, 1.25f, 0.00001f);
  expect_near(decoded->residual.max_px, 2.5f, 0.00001f);
}

TEST(PlutoCalibrationTest, DefaultTransformMapsMeasuredMoveCorners) {
  const pluto::AffineTransform pen =
      pluto::default_digitizer_to_panel(954.0f, 1696.0f, 0, 6760, 0, 11960);
  pluto::Point origin = pen.apply({0.0f, 0.0f});
  pluto::Point far = pen.apply({6760.0f, 11960.0f});
  expect_near(origin.x, 0.0f, 0.001f);
  expect_near(origin.y, 0.0f, 0.001f);
  expect_near(far.x, 954.0f, 0.001f);
  expect_near(far.y, 1696.0f, 0.001f);
}
