#ifndef PLUTO_COMPOSITOR_BACKING_STORE_POOL_H_
#define PLUTO_COMPOSITOR_BACKING_STORE_POOL_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include "flutter/embedder.h"
#include "pluto/presenter.h"

namespace pluto {

class BackingStorePool {
 public:
  explicit BackingStorePool(size_t cap = 3,
                            PlutoPixelFormat format = kPlutoPixelFormatRgb565);
  BackingStorePool(const BackingStorePool&) = delete;
  BackingStorePool& operator=(const BackingStorePool&) = delete;
  ~BackingStorePool();

  bool create(const FlutterBackingStoreConfig* config,
              FlutterBackingStore* backing_store_out);
  bool collect(const FlutterBackingStore* backing_store);

  void set_format(PlutoPixelFormat format) { format_ = format; }
  PlutoPixelFormat format() const { return format_; }
  size_t cap() const { return cap_; }
  size_t allocated_count() const { return slots_.size(); }
  size_t active_count() const;

 private:
  struct Slot {
    void* allocation = nullptr;
    size_t allocation_size = 0;
    size_t row_bytes = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    PlutoPixelFormat format = kPlutoPixelFormatRgb565;
    bool in_use = false;
  };

  static void destruction_callback(void* user_data);
  Slot* find_slot(uint32_t width, uint32_t height, size_t row_bytes);
  Slot* allocate_slot(uint32_t width, uint32_t height, size_t row_bytes);

  size_t cap_ = 3;
  PlutoPixelFormat format_ = kPlutoPixelFormatRgb565;
  std::vector<std::unique_ptr<Slot>> slots_;
};

size_t bytes_per_pixel(PlutoPixelFormat format);
FlutterSoftwarePixelFormat to_flutter_pixel_format(PlutoPixelFormat format);

}  // namespace pluto

#endif  // PLUTO_COMPOSITOR_BACKING_STORE_POOL_H_
