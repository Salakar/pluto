#include "input/transform.h"

#include <algorithm>

namespace pluto {

Point AffineTransform::apply(Point raw) const {
  return Point{
      .x = a * raw.x + b * raw.y + c,
      .y = d * raw.x + e * raw.y + f,
  };
}

AffineTransform default_digitizer_to_panel(float panel_width,
                                           float panel_height,
                                           int32_t abs_x_min,
                                           int32_t abs_x_max,
                                           int32_t abs_y_min,
                                           int32_t abs_y_max) {
  const float x_span = static_cast<float>(std::max(1, abs_x_max - abs_x_min));
  const float y_span = static_cast<float>(std::max(1, abs_y_max - abs_y_min));
  return AffineTransform{
      .a = panel_width / x_span,
      .b = 0.0f,
      .c = -static_cast<float>(abs_x_min) * panel_width / x_span,
      .d = 0.0f,
      .e = panel_height / y_span,
      .f = -static_cast<float>(abs_y_min) * panel_height / y_span,
  };
}

Size logical_size(float panel_width, float panel_height, Orientation orientation) {
  if (orientation == Orientation::kDeg90 || orientation == Orientation::kDeg270) {
    return Size{.width = panel_height, .height = panel_width};
  }
  return Size{.width = panel_width, .height = panel_height};
}

Point panel_to_logical(Point panel,
                       float panel_width,
                       float panel_height,
                       Orientation orientation) {
  switch (orientation) {
    case Orientation::kDeg0:
      return panel;
    case Orientation::kDeg90:
      return Point{.x = panel.y, .y = panel_width - panel.x};
    case Orientation::kDeg180:
      return Point{.x = panel_width - panel.x, .y = panel_height - panel.y};
    case Orientation::kDeg270:
      return Point{.x = panel_height - panel.y, .y = panel.x};
  }
  return panel;
}

Point logical_to_panel(Point logical,
                       float panel_width,
                       float panel_height,
                       Orientation orientation) {
  switch (orientation) {
    case Orientation::kDeg0:
      return logical;
    case Orientation::kDeg90:
      return Point{.x = panel_width - logical.y, .y = logical.x};
    case Orientation::kDeg180:
      return Point{.x = panel_width - logical.x, .y = panel_height - logical.y};
    case Orientation::kDeg270:
      return Point{.x = logical.y, .y = panel_height - logical.x};
  }
  return logical;
}

Point rotate_tilt(Point tilt, Orientation orientation) {
  switch (orientation) {
    case Orientation::kDeg0:
      return tilt;
    case Orientation::kDeg90:
      return Point{.x = tilt.y, .y = -tilt.x};
    case Orientation::kDeg180:
      return Point{.x = -tilt.x, .y = -tilt.y};
    case Orientation::kDeg270:
      return Point{.x = -tilt.y, .y = tilt.x};
  }
  return tilt;
}

uint16_t orientation_degrees(Orientation orientation) {
  return static_cast<uint16_t>(orientation);
}

}  // namespace pluto
