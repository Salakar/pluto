#ifndef PLUTO_SRC_INPUT_CALIBRATE_H_
#define PLUTO_SRC_INPUT_CALIBRATE_H_

#include <optional>
#include <vector>

#include "input/transform.h"

namespace pluto {

struct CalibrationPoint {
  Point raw;
  Point panel;
};

struct CalibrationResidual {
  float mean_px = 0.0f;
  float max_px = 0.0f;
};

struct CalibrationModel {
  AffineTransform affine;
  CalibrationResidual residual;
};

std::vector<Point> l_shape_corner_targets(float panel_width, float panel_height,
                                          float inset_px);

std::optional<CalibrationModel>
solve_affine_calibration(const std::vector<CalibrationPoint> &points);

std::optional<CalibrationModel>
solve_l_shape_corner_calibration(const std::vector<Point> &raw_medians,
                                 float panel_width, float panel_height,
                                 float inset_px);

} // namespace pluto

#endif // PLUTO_SRC_INPUT_CALIBRATE_H_
