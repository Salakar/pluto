#ifndef PLUTO_RENDERER_REFRESH_CLASS_H_
#define PLUTO_RENDERER_REFRESH_CLASS_H_

#include <array>
#include <cstddef>
#include <cstdint>

#include "pluto/presenter.h"

namespace pluto {

inline constexpr size_t k_refresh_class_count = 4;
inline constexpr std::array<uint8_t, k_refresh_class_count> k_default_rect_caps{
    4, 6, 4, 1};

inline bool refresh_class_valid(PlutoRefreshClass cls) {
  return cls == kPlutoRefreshFast || cls == kPlutoRefreshUi ||
         cls == kPlutoRefreshText || cls == kPlutoRefreshFull;
}

inline size_t refresh_class_index(PlutoRefreshClass cls) {
  return static_cast<size_t>(cls);
}

inline const char* refresh_class_name(PlutoRefreshClass cls) {
  switch (cls) {
    case kPlutoRefreshFast:
      return "fast";
    case kPlutoRefreshUi:
      return "ui";
    case kPlutoRefreshText:
      return "text";
    case kPlutoRefreshFull:
      return "full";
  }
  return "unknown";
}

inline PlutoRefreshClass promote_refresh_class(PlutoRefreshClass a,
                                                 PlutoRefreshClass b) {
  return static_cast<int>(a) >= static_cast<int>(b) ? a : b;
}

}  // namespace pluto

#endif  // PLUTO_RENDERER_REFRESH_CLASS_H_
