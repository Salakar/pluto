#include "input/calibrate.h"

#include <array>
#include <cmath>
#include <optional>

namespace pluto {
namespace {

std::optional<std::array<float, 3>> solve_3x3(float matrix[3][4]) {
  for (int col = 0; col < 3; ++col) {
    int pivot = col;
    for (int row = col + 1; row < 3; ++row) {
      if (std::fabs(matrix[row][col]) > std::fabs(matrix[pivot][col])) {
        pivot = row;
      }
    }
    if (std::fabs(matrix[pivot][col]) < 1e-6f) {
      return std::nullopt;
    }
    if (pivot != col) {
      for (int k = col; k < 4; ++k) {
        std::swap(matrix[pivot][k], matrix[col][k]);
      }
    }
    const float divisor = matrix[col][col];
    for (int k = col; k < 4; ++k) {
      matrix[col][k] /= divisor;
    }
    for (int row = 0; row < 3; ++row) {
      if (row == col) {
        continue;
      }
      const float factor = matrix[row][col];
      for (int k = col; k < 4; ++k) {
        matrix[row][k] -= factor * matrix[col][k];
      }
    }
  }
  return std::array<float, 3>{matrix[0][3], matrix[1][3], matrix[2][3]};
}

std::optional<std::array<float, 3>>
solve_coefficients(const std::vector<CalibrationPoint> &points, bool solve_x) {
  float ata[3][3] = {};
  float atb[3] = {};
  for (const CalibrationPoint &point : points) {
    const float row[3] = {point.raw.x, point.raw.y, 1.0f};
    const float target = solve_x ? point.panel.x : point.panel.y;
    for (int r = 0; r < 3; ++r) {
      atb[r] += row[r] * target;
      for (int c = 0; c < 3; ++c) {
        ata[r][c] += row[r] * row[c];
      }
    }
  }
  float augmented[3][4] = {};
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c) {
      augmented[r][c] = ata[r][c];
    }
    augmented[r][3] = atb[r];
  }
  return solve_3x3(augmented);
}

float distance(Point a, Point b) {
  const float dx = a.x - b.x;
  const float dy = a.y - b.y;
  return std::sqrt(dx * dx + dy * dy);
}

} // namespace

std::vector<Point> l_shape_corner_targets(float panel_width, float panel_height,
                                          float inset_px) {
  return {
      Point{.x = inset_px, .y = inset_px},
      Point{.x = panel_width - inset_px, .y = inset_px},
      Point{.x = panel_width - inset_px, .y = panel_height - inset_px},
      Point{.x = inset_px, .y = panel_height - inset_px},
      Point{.x = panel_width * 0.5f, .y = panel_height * 0.5f},
  };
}

std::optional<CalibrationModel>
solve_affine_calibration(const std::vector<CalibrationPoint> &points) {
  if (points.size() < 3) {
    return std::nullopt;
  }
  const auto x_coefficients = solve_coefficients(points, true);
  const auto y_coefficients = solve_coefficients(points, false);
  if (!x_coefficients || !y_coefficients) {
    return std::nullopt;
  }
  CalibrationModel model;
  model.affine = AffineTransform{
      .a = (*x_coefficients)[0],
      .b = (*x_coefficients)[1],
      .c = (*x_coefficients)[2],
      .d = (*y_coefficients)[0],
      .e = (*y_coefficients)[1],
      .f = (*y_coefficients)[2],
  };

  float total = 0.0f;
  float max = 0.0f;
  for (const CalibrationPoint &point : points) {
    const float residual = distance(model.affine.apply(point.raw), point.panel);
    total += residual;
    if (residual > max) {
      max = residual;
    }
  }
  model.residual = CalibrationResidual{
      .mean_px = total / static_cast<float>(points.size()),
      .max_px = max,
  };
  return model;
}

std::optional<CalibrationModel>
solve_l_shape_corner_calibration(const std::vector<Point> &raw_medians,
                                 float panel_width, float panel_height,
                                 float inset_px) {
  const std::vector<Point> targets =
      l_shape_corner_targets(panel_width, panel_height, inset_px);
  if (raw_medians.size() != targets.size()) {
    return std::nullopt;
  }
  std::vector<CalibrationPoint> points;
  points.reserve(targets.size());
  for (size_t i = 0; i < targets.size(); ++i) {
    points.push_back(
        CalibrationPoint{.raw = raw_medians[i], .panel = targets[i]});
  }
  return solve_affine_calibration(points);
}

} // namespace pluto
