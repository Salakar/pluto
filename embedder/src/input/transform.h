#ifndef PLUTO_SRC_INPUT_TRANSFORM_H_
#define PLUTO_SRC_INPUT_TRANSFORM_H_

#include <cstdint>

namespace pluto {

struct Point {
  float x = 0.0f;
  float y = 0.0f;
};

struct Size {
  float width = 0.0f;
  float height = 0.0f;
};

enum class Orientation : uint16_t {
  kDeg0 = 0,
  kDeg90 = 90,
  kDeg180 = 180,
  kDeg270 = 270,
};

struct AffineTransform {
  float a = 1.0f;
  float b = 0.0f;
  float c = 0.0f;
  float d = 0.0f;
  float e = 1.0f;
  float f = 0.0f;

  Point apply(Point raw) const;
};

constexpr float kMovePanelWidth = 954.0f;
constexpr float kMovePanelHeight = 1696.0f;

AffineTransform default_digitizer_to_panel(float panel_width,
                                           float panel_height,
                                           int32_t abs_x_min,
                                           int32_t abs_x_max,
                                           int32_t abs_y_min,
                                           int32_t abs_y_max);

Size logical_size(float panel_width, float panel_height, Orientation orientation);
Point panel_to_logical(Point panel,
                       float panel_width,
                       float panel_height,
                       Orientation orientation);
Point logical_to_panel(Point logical,
                       float panel_width,
                       float panel_height,
                       Orientation orientation);
Point rotate_tilt(Point tilt, Orientation orientation);
uint16_t orientation_degrees(Orientation orientation);

}  // namespace pluto

#endif  // PLUTO_SRC_INPUT_TRANSFORM_H_
